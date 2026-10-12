package agent_product

import agent_domain.*
import agent_extension_runtime.{PluginEntryKind}
import agent_runtime.*
import agent_plugin_registry.*
import agent_sdk.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

// This config selects an actual installed contribution. It grants no access.
class ProductWorkspaceSelection {
    let runtime: ProductRuntime
    let session: SessionId
    let path: String
    let configDigest: String
    let namespace: String
    let packageDigest: String
    let generation: UInt64
    let tool: String
    let version: String
    let fingerprint: String
    init(runtime: ProductRuntime, session: SessionId, path: String, configDigest: String,
        namespace: String, packageDigest: String, generation: UInt64, tool: String,
        version: String, fingerprint: String) {
        this.runtime=runtime;this.session=session;this.path=path;this.configDigest=configDigest
        this.namespace=namespace;this.packageDigest=packageDigest;this.generation=generation
        this.tool=tool;this.version=version;this.fingerprint=fingerprint
    }
    func current(): Result<Unit> {
        try {
            let info=FileInfo(Path(path))
            if(!info.isRegular() || info.isSymbolicLink() || info.size>16384 ||
                modelPolicySha256Text(String.fromUtf8(File.readFrom(path)))!=configDigest){return productWorkspaceError("workspace.selection_changed")}
            let descriptor=match(runtime.vnext.javascriptPlugins.servicePackage(namespace,generation)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try{
            let published=match(runtime.vnext.publishedToolIdentity(tool,threadId:Some(ThreadId(session.value)))){
                case None=>return productWorkspaceError("workspace.tool_unprovided");case Some(value)=>value}
            if(!descriptor.textEquals(PluginDescriptorText.ContentDigest,packageDigest) || published.implementationVersion!=version ||
                published.implementationFingerprint!=fingerprint){return productWorkspaceError("workspace.selection_changed")}
            Result.Ok(())
            }finally{descriptor.close()}
        }catch(_:Exception){productWorkspaceError("workspace.selection_changed")}
    }
}

func selectProductWorkspaceTool(runtime: ProductRuntime, session: SessionId, contribution: String): Result<ProductWorkspaceSelection> {
    if(!["read","grep","glob","edit","write"].contains(contribution)){return productWorkspaceError("workspace.contribution_invalid")}
    try {
        let path=Path(runtime.settingsRoot).join("plugins/workspace-tools.json")
        let info=FileInfo(path)
        if(!info.isRegular() || info.isSymbolicLink() || info.size>16384 ||
            canonicalize(path).toString()!=canonicalize(Path(runtime.settingsRoot)).join("plugins/workspace-tools.json").toString()){
            return productWorkspaceError("workspace.selection_unprovided")}
        let source=String.fromUtf8(File.readFrom(path))
        let config=parseUnifiedJson(source,maxBytes:16384,maxDepth:8)
        if(!httpIntentExactFields(config,["schema","namespace","package_digest"]) ||
            httpIntentText(config,"schema")!="axyndra.workspace-tools/v1" ||
            !httpServicePluginNamespace(httpIntentText(config,"namespace")) ||
            !httpServicePackageDigest(httpIntentText(config,"package_digest"))){return productWorkspaceError("workspace.selection_invalid")}
        let namespace=httpIntentText(config,"namespace");let digest=httpIntentText(config,"package_digest")
        let enabled=productRegistryHasEnabledRecord139(runtime.pluginSnapshots(),namespace,digest)
        if(!enabled){return productWorkspaceError("workspace.tool_unprovided")}
        let generation=runtime.vnext.javascriptPlugins.instanceGeneration(namespace)
        let descriptor=match(runtime.vnext.javascriptPlugins.servicePackage(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
        if(!descriptor.textEquals(PluginDescriptorText.ContentDigest,digest) || descriptor.entryKind!=PluginEntryKind.NativeExecutable ||
            !descriptor.hasCapability("process.readview")){return productWorkspaceError("workspace.selection_invalid")}
        let declared=descriptor.hasContribution(PluginContributionKind.Tool,contribution)
        let name="plugin."+namespace+"."+contribution
        let published=match(runtime.vnext.publishedToolIdentity(name,threadId:Some(ThreadId(session.value)))){
            case None=>return productWorkspaceError("workspace.tool_unprovided");case Some(value)=>value}
        if(!declared || published.implementationFingerprint!=namespace+":"+digest){return productWorkspaceError("workspace.selection_invalid")}
        let selection=ProductWorkspaceSelection(runtime,session,path.toString(),modelPolicySha256Text(source),namespace,digest,generation,name,
            published.implementationVersion,published.implementationFingerprint)
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(selection)
        }finally{descriptor.close()}
    }catch(_:Exception){productWorkspaceError("workspace.selection_unprovided")}
}

// Created only from this actual native Root and retained real user owner.
// Serialized proposal data or a Receipt string cannot reconstruct this object.
public class ProductWorkspaceInvocation {
    private let product: ProductRuntime
    private let selection: ProductWorkspaceSelection
    private let cancellation: CancellationSource
    private let owner: ProductDirectPreparationOwner
    private let resourceTool: String
    private let lock = Mutex()
    private var completed: ?ToolResult = None
    private var frozenOutput = ""
    private var resourceStarted = false
    private var closed = false
    private var closing = false
    private var closeFailure: ?AgentError = None
    private var closingPayload: ?ToolResult = None
    init(product: ProductRuntime, selection: ProductWorkspaceSelection, resourceTool!: String = "") {
        let actualCancellation=CancellationSource()
        let actualSelection=selection
        this.product=product;this.selection=selection;this.resourceTool=resourceTool
        this.cancellation=actualCancellation
        owner=ProductDirectPreparationOwner({=>
            match(actualCancellation.token.check()){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>actualSelection.current()}})
    }
    func start(arguments: AgentValue): Result<Unit> {
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        consume(product.vnext.executeDeferredCanonicalTool(selection.session,
            if(resourceTool==""){CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.ExtensionInvoke)])}
                else if(resourceTool=="read_resource"){CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)])}
                else{CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.WorkspaceWrite)])},
            ToolCall("workspace-"+product.nextWorkspaceCallId(),if(resourceTool==""){selection.tool}else{resourceTool},arguments),owner,cancellation.token,
            budget:ExecutionBudget(maxToolCalls:if(resourceTool==""){3}else{1},maxConcurrentTools:1)))
    }
    public func approval(): ?ApprovalRequest { owner.approval() }
    public func decide(operationId: String, decision: ApprovalDecision): Result<Unit> {
        if(isClosed()){return productWorkspaceError("workspace.invocation_closed")}
        consume(owner.decide(operationId,decision))
    }
    private func consume(result: Result<ToolInvocationResult>): Result<Unit> {
        match(result){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>Result.Ok(())
            case Result.Ok(ToolInvocationResult.Denied(value))=>Result.Err(value.reason)
            case Result.Ok(ToolInvocationResult.Completed(value))=>
                if(value.isError){try{return Result.Err(productToolResultError(value))}finally{value.releasePayload()}}
                var retained=false
                try{
                    // The native result stays charged while its defensive copy
                    // is made. Resource pages still contain at most 1 MiB of
                    // UTF-8 data; only their worst-case JSON copy needs 8 MiB.
                    let encoded=stringifyUnifiedJson(value.output)
                    if(encoded.size>copyLimit()){return productWorkspaceError("workspace.output_limit")}
                    lock.lock()
                    try{
                        if(closed || closing || closeFailure.isSome() || completed.isSome()){return productWorkspaceError("workspace.invocation_closed")}
                        completed=Some(value);frozenOutput=encoded;retained=true;Result.Ok(())
                    }finally{lock.unlock()}
                }catch(_:Exception){productWorkspaceError("workspace.output_invalid")}
                finally{if(!retained){value.releasePayload()}}
        }
    }
    private func copyLimit(): Int64 { if(resourceTool==""){262144}else{8388608} }
    public func output(): Result<AgentValue> {
        lock.lock();try{
            if(closed || completed.isNone()){return productWorkspaceError("workspace.output_pending")}
            Result.Ok(parseUnifiedJson(frozenOutput,maxBytes:copyLimit(),maxDepth:32))
        }finally{lock.unlock()}
    }
    // Submitting this new Root is separate from deciding its actual approval.
    // The caller receives this Root's retained owner and frozen review first.
    public func beginResource(): Result<ProductWorkspaceInvocation> {
        if(resourceTool!=""){return productWorkspaceError("workspace.resource_unavailable")}
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        let request=try{
            if(closed || closing || closeFailure.isSome() || completed.isNone() || resourceStarted){return productWorkspaceError("workspace.resource_unavailable")}
            let output=parseUnifiedJson(frozenOutput,maxBytes:262144,maxDepth:32)
            let request=match(output.field("resource_request")){
                case Some(value)=>value
                case None=>
                    let plan=match(output.field("application_plan")){case None=>return productWorkspaceError("workspace.resource_unavailable");case Some(value)=>value}
                    if(plan.unifiedKind!=ValueKind.Object || !isProductArtifactReference(httpIntentText(plan,"plan_ref")) ||
                        !httpIntentDigest(httpIntentText(plan,"plan_digest"))){return productWorkspaceError("workspace.resource_invalid")}
                    objectValue([ValueField("schema",textValue("axyndra.resource-request/v1")),ValueField("tool",textValue("apply_file_plan")),
                        ValueField("arguments",objectValue([ValueField("plan_ref",plan.field("plan_ref").getOrThrow()),ValueField("plan_digest",plan.field("plan_digest").getOrThrow())]))])
                
            }
            if(!httpIntentExactFields(request,["schema","tool","arguments"]) || httpIntentText(request,"schema")!="axyndra.resource-request/v1" ||
                !["read_resource","write_resource","export_artifact","apply_file_plan"].contains(httpIntentText(request,"tool")) ||
                request.field("arguments").getOrThrow().unifiedKind!=ValueKind.Object){return productWorkspaceError("workspace.resource_invalid")}
            resourceStarted=true;request
        }finally{lock.unlock()}
        let invocation=ProductWorkspaceInvocation(product,selection,resourceTool:httpIntentText(request,"tool"))
        match(invocation.start(request.field("arguments").getOrThrow())){
            case Result.Err(error)=>let _=invocation.close();Result.Err(error)
            case Result.Ok(_)=>Result.Ok(invocation)}
    }
    private func isClosed(): Bool { lock.lock();try{closed || closing || closeFailure.isSome()}finally{lock.unlock()} }
    public func close(): Result<Unit> {
        lock.lock()
        let previousFailure = try{
            if(closed){return Result.Ok(())}
            if(closing){return productWorkspaceError("workspace.cleanup_pending")}
            closing=true;closeFailure
        }finally{lock.unlock()}
        var failure=previousFailure
        if(previousFailure.isNone()){
            let _=cancellation.cancel()
            if(owner.approval().isSome()){
                match(owner.cancel()){
                    case Result.Err(error)=>failure=Some(error)
                    case Result.Ok(ToolInvocationResult.Completed(value))=>
                        lock.lock();try{closingPayload=Some(value)}finally{lock.unlock()}
                    case Result.Ok(_)=>()}}}
        // None on approval(), an error code, or a terminal-looking DTO is not
        // an ACK. This probe is fixed by the actual original gateway binding.
        match(owner.closeAcknowledgement()){
            case Result.Err(error)=>
                let original=match(failure){case Some(value)=>value;case None=>error}
                lock.lock();try{closeFailure=Some(original);closing=false}finally{lock.unlock()}
                return Result.Err(original)
            case Result.Ok(_)=>()}
        lock.lock()
        let payloads=try{
            let result=(completed,closingPayload)
            completed=None;closingPayload=None;frozenOutput="";closed=true;closing=false;closeFailure=None;result
        }finally{lock.unlock()}
        try{
            match(payloads[0]){case Some(value)=>value.releasePayload();case None=>()}
            match(payloads[1]){case Some(value)=>value.releasePayload();case None=>()}
            Result.Ok(())
        }finally{cancellation.close()}
    }
}

func productWorkspaceError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Configuration,code,"Workspace requires its current explicitly selected native contribution or independent resource Root"))
}
