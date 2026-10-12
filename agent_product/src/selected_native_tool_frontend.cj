package agent_product

import agent_plugin_registry.*

import agent_domain.*
import agent_host_runtime.*
import agent_store.*
import agent_extension_runtime.{PluginEntryKind}
import agent_runtime.*
import agent_sdk.*
import std.fs.*
import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// This is frontend selection metadata, not a second catalog or a grant.
class ProductSelectedNativeTool {
    let product: ProductRuntime
    let session: SessionId
    let selectionPath: String
    let selectionDigest: String
    let namespace: String
    let packageDigest: String
    let generation: UInt64
    let toolName: String
    let version: String
    let fingerprint: String
    let capabilities: CapabilitySet
    let serviceId: String
    let expectedNetwork: String
    let networkConfigurationDigest: String
    let nativeCallTimeoutMillis: Int64
    init(product: ProductRuntime, session: SessionId, selectionPath: String,
        selectionDigest: String, namespace: String, packageDigest: String,
        generation: UInt64, toolName: String, version: String, fingerprint: String,
        capabilities: CapabilitySet, serviceId!: String="", expectedNetwork!: String="", networkConfigurationDigest!: String="", nativeCallTimeoutMillis!: Int64=0) {
        this.product=product;this.session=session;this.selectionPath=selectionPath
        this.selectionDigest=selectionDigest;this.namespace=namespace;this.packageDigest=packageDigest
        this.generation=generation;this.toolName=toolName;this.version=version
        this.fingerprint=fingerprint;this.capabilities=capabilities
        this.serviceId=serviceId;this.expectedNetwork=expectedNetwork;this.networkConfigurationDigest=networkConfigurationDigest;this.nativeCallTimeoutMillis=nativeCallTimeoutMillis
    }
    // Missing timeout is a frontend choice, frozen as an explicit actual
    // canonical argument. Explicit seconds/milliseconds are never clamped.
    func shellArguments(arguments: AgentValue): Result<AgentValue> {
        if(serviceId==""){return Result.Ok(arguments)}
        try{
            let raw=encodeAgentValue(arguments)
            if(raw.size>131072 || arguments.unifiedKind!=ValueKind.Object){return selectedShellArgumentError("shell.argument_invalid")}
            let actual=decodeStoredValue(raw)
            let seconds=actual.field("timeout");let precise=actual.field("timeout_ms")
            if(seconds.isSome() && precise.isSome()){return selectedShellArgumentError("shell.timeout_invalid")}
            var millis: Int64=if(nativeCallTimeoutMillis<10000){nativeCallTimeoutMillis}else{10000}
            match(precise){case Some(value)=>
                if(value.unifiedKind!=ValueKind.Number){return selectedShellArgumentError("shell.timeout_invalid")}
                millis=Int64.parse(value.asNumberText())
                if(millis<1 || millis>600000 || millis.toString()!=value.asNumberText()){return selectedShellArgumentError("shell.timeout_invalid")}
                case None=>match(seconds){case Some(value)=>
                    if(value.unifiedKind!=ValueKind.Number){return selectedShellArgumentError("shell.timeout_invalid")}
                    let count=Int64.parse(value.asNumberText())
                    if(count<0 || count>600 || count.toString()!=value.asNumberText()){return selectedShellArgumentError("shell.timeout_invalid")}
                    millis=if(count==0){600000}else{count*1000}
                    case None=>actual.put("timeout_ms",integerValue(millis))}}
            if(millis>nativeCallTimeoutMillis){return selectedShellArgumentError("shell.timeout_exceeds_service")}
            Result.Ok(actual)
        }catch(_:Exception){selectedShellArgumentError("shell.timeout_invalid")}
    }
    func current(): Result<Unit> {
        try {
            let info=FileInfo(Path(selectionPath))
            if(!info.isRegular() || info.isSymbolicLink() || info.size>16384 ||
                modelPolicySha256Text(String.fromUtf8(File.readFrom(selectionPath)))!=selectionDigest){
                return selectedNativeToolError("plugin.frontend_selection_changed")}
            let enabled=productRegistryHasEnabledRecord139(product.pluginSnapshots(),namespace,packageDigest)
            if(!enabled || product.vnext.javascriptPlugins.instanceGeneration(namespace)!=generation){
                return selectedNativeToolError("plugin.frontend_selection_changed")}
            let descriptor=match(product.vnext.javascriptPlugins.servicePackage(namespace,generation)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try{
            let published=match(product.vnext.publishedToolIdentity(toolName,threadId:Some(ThreadId(session.value)))){
                case None=>return selectedNativeToolError("plugin.frontend_tool_unprovided");case Some(value)=>value}
            if(descriptor.entryKind!=PluginEntryKind.NativeExecutable || !descriptor.textEquals(PluginDescriptorText.ContentDigest,packageDigest) ||
                published.implementationVersion!=version || published.implementationFingerprint!=fingerprint){
                return selectedNativeToolError("plugin.frontend_selection_changed")}
            if(networkConfigurationDigest!=""){
                let actual=match(loadPluginLifecycleConfiguration(product.settingsRoot,namespace,packageDigest,productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Root)))){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                let network=match(actual.serviceNetworkValue(serviceId)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(actual.digest!=networkConfigurationDigest || (expectedNetwork!="" && stringifyUnifiedJson(network)!=expectedNetwork)){
                    return selectedNativeToolError("shell.network_selection_changed")}}
            Result.Ok(())
            }finally{descriptor.close()}
        }catch(_:Exception){selectedNativeToolError("plugin.frontend_selection_changed")}
    }
}

func selectProductNativeFrontendTool(product: ProductRuntime, session: SessionId,
    selector: String, contribution: String, networkPolicy!: ?NetworkPolicy=None): Result<ProductSelectedNativeTool> {
    let shell=selector=="shell"
    let readonlyView=selector=="shell-readonly"
    if((shell && !["bash","bash_readonly"].contains(contribution)) ||
        (!shell && !readonlyView && (selector!="program" || contribution!="run")) || (readonlyView && contribution!="exec")){
        return selectedNativeToolError("plugin.frontend_contribution_invalid")}
    try {
        let relative="plugins/"+selector+"-tools.json"
        let path=Path(product.settingsRoot).join(relative)
        let info=FileInfo(path)
        if(!info.isRegular() || info.isSymbolicLink() || info.size>16384 ||
            canonicalize(path).toString()!=canonicalize(Path(product.settingsRoot)).join(relative).toString()){
            return selectedNativeToolError("plugin.frontend_selection_unprovided")}
        let encoded=String.fromUtf8(File.readFrom(path))
        let config=parseUnifiedJson(encoded,maxBytes:16384,maxDepth:8)
        let fields=if(shell){["schema","namespace","package_digest","service_id","route"]}
            else{["schema","namespace","package_digest"]}
        if(!httpIntentExactFields(config,fields) ||
            httpIntentText(config,"schema")!="axyndra."+selector+"-tools/v1" ||
            !httpServicePluginNamespace(httpIntentText(config,"namespace")) ||
            !httpServicePackageDigest(httpIntentText(config,"package_digest"))){
            return selectedNativeToolError("plugin.frontend_selection_invalid")}
        let namespace=httpIntentText(config,"namespace");let digest=httpIntentText(config,"package_digest")
        let generation=product.vnext.javascriptPlugins.instanceGeneration(namespace)
        let descriptor=match(product.vnext.javascriptPlugins.servicePackage(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
        if(descriptor.entryKind!=PluginEntryKind.NativeExecutable || !descriptor.textEquals(PluginDescriptorText.ContentDigest,digest) ||
            !descriptor.hasCapability(if(shell){"process.channel"}else if(readonlyView){"process.readview"}else{"tool.readonly"})){
            return selectedNativeToolError("plugin.frontend_selection_invalid")}
        let serviceId=if(shell){httpIntentText(config,"service_id")}else{""}
        if(shell && (!channelIntentIdentifier(serviceId) || !channelIntentIdentifier(httpIntentText(config,"route")))){
            return selectedNativeToolError("plugin.frontend_selection_invalid")}
        let declared=descriptor.hasContribution(if(shell){PluginContributionKind.Service}else{PluginContributionKind.Tool},
            if(shell){httpIntentText(config,"route")}else{contribution})
        if(!declared){return selectedNativeToolError("plugin.frontend_contribution_unprovided")}
        let name="plugin."+namespace+if(shell){".service."+serviceId+"."+contribution}else{"."+contribution}
        let published=match(product.vnext.publishedToolIdentity(name,threadId:Some(ThreadId(session.value)))){
            case None=>return selectedNativeToolError("plugin.frontend_tool_unprovided");case Some(value)=>value}
        // Managed publications have their own exact live lease fingerprint.
        // Read that actual identity; do not guess it from a package/name string.
        let capabilities=if(shell){productCapabilities()}else if(readonlyView){CapabilitySet(values:[
            Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.ExtensionInvoke,resource:name)])}else{CapabilitySet(values:[
            Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.ExtensionInvoke)])}
        var expectedNetwork="";var configurationDigest="";var callTimeout: Int64=0
        if(shell){
            let actual=match(loadPluginLifecycleConfiguration(product.settingsRoot,namespace,digest,productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Root)))){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let ceiling=match(actual.serviceMaximumCallMillis(serviceId)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let request=actual.configuration.field("request_timeout_ms").getOrThrow()
            if(request.unifiedKind!=ValueKind.Number){return selectedNativeToolError("shell.configuration_timeout_invalid")}
            let millis=Int64.parse(request.asNumberText())
            if(millis<1 || millis>3600000 || millis.toString()!=request.asNumberText()){
                return selectedNativeToolError("shell.configuration_timeout_invalid")}
            callTimeout=if(millis<ceiling){millis}else{ceiling};configurationDigest=actual.digest
            match(networkPolicy){case Some(requested)=>
                let network=match(actual.serviceNetworkValue(serviceId)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                expectedNetwork=stringifyUnifiedJson(networkPolicyCanonicalValue(requested))
                if(stringifyUnifiedJson(network)!=expectedNetwork){return selectedNativeToolError("shell.network_selection_mismatch")}
                case None=>()}
        }else if(readonlyView){
            if(networkPolicy.isSome() && !networkPolicyModeIsDenied(networkPolicy.getOrThrow().mode)){
                return selectedNativeToolError("shell.network_selection_mismatch")}
            let actual=match(loadHostPluginHttpConfiguration(product.settingsRoot,namespace,digest)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(!actual.ordinaryReadTools.contains(contribution) || !actual.usesReadViewParameterReference(contribution)){
                return selectedNativeToolError("plugin.frontend_selection_invalid")}
        }else if(networkPolicy.isSome()){return selectedNativeToolError("plugin.frontend_selection_invalid")}
        let selection=ProductSelectedNativeTool(product,session,path.toString(),modelPolicySha256Text(encoded),namespace,digest,
            generation,name,published.implementationVersion,published.implementationFingerprint,capabilities,
            serviceId:serviceId,expectedNetwork:expectedNetwork,networkConfigurationDigest:configurationDigest,nativeCallTimeoutMillis:callTimeout)
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(selection)
        }finally{descriptor.close()}
    }catch(_:Exception){selectedNativeToolError("plugin.frontend_selection_unprovided")}
}

// An actual transient user owner, never reconstructed from output/Receipt JSON.
// Service startup has a separate canonical approval; it cannot approve this Tool.
public class ProductNativeToolInvocation {
    private let selection: ProductSelectedNativeTool
    private let cancellation: CancellationSource
    private let owner: ProductDirectPreparationOwner
    private let lock=Mutex()
    private var completed: ?ToolResult=None
    private var closingPayload: ?ToolResult=None
    private var frozenOutput=""
    private var closing=false
    private var closed=false
    private var closeFailure: ?AgentError=None
    private var terminalFailure: ?AgentError=None
    private var started=false
    private var starting=false
    private let artifactReads=ArrayList<ProductNativeToolInvocation>()
    init(selection: ProductSelectedNativeTool) {
        let actualSelection=selection;let actualCancellation=CancellationSource()
        this.selection=selection;this.cancellation=actualCancellation
        this.owner=ProductDirectPreparationOwner({=>
            match(actualCancellation.token.check()){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>actualSelection.current()}})
    }
    func start(arguments: AgentValue, budget: ExecutionBudget, resourceCall!: ?ToolCall=None): Result<Unit> {
        lock.lock()
        try{
            if(closed || closing || started){return selectedNativeToolError("plugin.frontend_invocation_closed")}
            started=true;starting=true
        }finally{lock.unlock()}
        try{
            match(cancellation.token.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let canonicalArguments=if(resourceCall.isSome()){arguments}else{
                match(selection.shellArguments(arguments)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}}
            consume(selection.product.vnext.executeDeferredCanonicalTool(selection.session,selection.capabilities,
                match(resourceCall){case Some(call)=>call;case None=>ToolCall("native-user-"+selection.product.nextWorkspaceCallId(),selection.toolName,canonicalArguments)},owner,cancellation.token,budget:budget))
        }finally{lock.lock();try{starting=false}finally{lock.unlock()}}
    }
    public func approval(): ?ApprovalRequest { owner.approval() }
    public func decide(operationId: String, decision: ApprovalDecision): Result<Unit> {
        lock.lock();let unavailable=try{closed || closing || closeFailure.isSome()}finally{lock.unlock()}
        if(unavailable){return selectedNativeToolError("plugin.frontend_invocation_closed")}
        consume(owner.decide(operationId,decision))
    }
    func recordFailure(error: AgentError): Unit {
        lock.lock();try{if(terminalFailure.isNone()){terminalFailure=Some(error)}}finally{lock.unlock()}
    }
    public func failure(): ?AgentError {
        lock.lock();try{terminalFailure}finally{lock.unlock()}
    }
    private func consume(actual: Result<ToolInvocationResult>): Result<Unit> {
        match(actual){
            case Result.Err(error)=>
                // A mismatched choice has not consumed its actual pending review.
                if(owner.approval().isNone()){recordFailure(error)}
                Result.Err(error)
            case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>Result.Ok(())
            case Result.Ok(ToolInvocationResult.Denied(value))=>recordFailure(value.reason);Result.Err(value.reason)
            case Result.Ok(ToolInvocationResult.Completed(value))=>
                lock.lock()
                let alreadyAcknowledged=try{
                    if(closed){true}else{
                        // Retain the actual result even while close has failed.
                        // A terminal-looking error never releases this ownership.
                        if(completed.isSome()){throw IllegalStateException("Native invocation returned a second result")}
                        completed=Some(value);false}
                }finally{lock.unlock()}
                if(alreadyAcknowledged){value.releasePayload();return selectedNativeToolError("plugin.frontend_invocation_closed")}
                try{
                    let encoded=stringifyUnifiedJson(value.output)
                    if(encoded.size>1114112){
                        let error=AgentError(AgentErrorKind.Protocol,"plugin.frontend_output_limit","Native output exceeds this frontend's bounded copy")
                        recordFailure(error);return Result.Err(error)}
                    lock.lock();try{
                        if(closed){return selectedNativeToolError("plugin.frontend_invocation_closed")}
                        frozenOutput=encoded
                        if(value.isError){let error=productToolResultError(value);terminalFailure=Some(error);Result.Err(error)}
                        else{Result.Ok(())}
                    }finally{lock.unlock()}
                }catch(_:Exception){
                    let error=AgentError(AgentErrorKind.Protocol,"plugin.frontend_output_invalid","Native output cannot be copied within the frontend contract")
                    recordFailure(error);Result.Err(error)}
        }
    }
    public func output(): Result<AgentValue> {
        lock.lock();try{
            if(closed){return selectedNativeToolError("plugin.frontend_output_pending")}
            match(terminalFailure){case Some(error)=>return Result.Err(error);case None=>()}
            if(completed.isNone()){return selectedNativeToolError("plugin.frontend_output_pending")}
            Result.Ok(parseUnifiedJson(frozenOutput,maxBytes:1114112,maxDepth:64))
        }finally{lock.unlock()}
    }
    // Read-only diagnostic view of this exact acquired invocation. Neither
    // an error observation nor an isError result proves success or a new Root.
    public func observedOutput(): Result<AgentValue> {
        lock.lock();try{
            if(closed){return selectedNativeToolError("plugin.frontend_output_pending")}
            if(frozenOutput!=""){return Result.Ok(parseUnifiedJson(frozenOutput,maxBytes:1114112,maxDepth:64))}
            match(terminalFailure){
                case Some(error)=>match(error.observation){
                    case Some(observed)=>Result.Ok(observed.toValue().field("content").getOrThrow())
                    case None=>Result.Err(error)}
                case None=>selectedNativeToolError("plugin.frontend_output_pending")}
        }finally{lock.unlock()}
    }
    // The actual parent holds this independent user Root until its ACK. Only
    // references in this parent's original charged Host result may be selected;
    // the reference is data and cannot supply a Source, grant or approval.
    public func beginArtifactRead(reference: String): Result<ProductNativeToolInvocation> {
        lock.lock()
        let acquired=try{
            if(closed || closing || closeFailure.isSome() || starting || completed.isNone() ||
                completed.getOrThrow().isError || completed.getOrThrow().receiptId==""){
                return selectedNativeToolError<ProductNativeToolInvocation>("plugin.frontend_artifact_unobserved")}
            let actual=parseUnifiedJson(frozenOutput,maxBytes:1114112,maxDepth:64)
            if(httpIntentText(actual,"schema")!="axyndra.service-call-result/v1" || httpIntentText(actual,"status")!="complete"){
                return selectedNativeToolError<ProductNativeToolInvocation>("plugin.frontend_artifact_unobserved")}
            let result=actual.field("result").getOrThrow()
            let artifacts=result.field("artifacts")
            if(artifacts.isNone() || artifacts.getOrThrow().unifiedKind!=ValueKind.List || artifactReads.size>=8){
                return selectedNativeToolError<ProductNativeToolInvocation>("plugin.frontend_artifact_unobserved")}
            var found=false
            for(value in artifacts.getOrThrow().items){if(httpIntentText(value,"ref")==reference){found=true}}
            if(!found || !isProductArtifactReference(reference)){
                return selectedNativeToolError<ProductNativeToolInvocation>("plugin.frontend_artifact_unobserved")}
            match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let child=match(selection.product.acquireNativeFrontendInvocation(selection)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            artifactReads.add(child);child
        }catch(_:Exception){return selectedNativeToolError<ProductNativeToolInvocation>("plugin.frontend_artifact_unobserved")}
        finally{lock.unlock()}
        let arguments=objectValue([ValueField("reference",textValue(reference)),ValueField("offset",integerValue(0)),
            ValueField("limit",integerValue(1048576)),ValueField("unit",textValue("bytes"))])
        // New ordinary canonical Root and finite budget; no parent's decision,
        // prepared source, handoff, Receipt or service-startup grant is passed.
        let call=ToolCall("native-artifact-read-"+selection.product.nextWorkspaceCallId(),"read_resource",arguments)
        match(acquired.start(arguments,ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1),resourceCall:Some(call))){
            case Result.Err(error)=>acquired.recordFailure(error);case Result.Ok(_)=>()}
        // Every post-acquisition error retains this same actual owner for ACK.
        Result.Ok(acquired)
    }
    public func receiptId(): String {
        lock.lock();try{match(completed){case None=>"";case Some(value)=>value.receiptId}}finally{lock.unlock()}
    }
    public func cancel(): Result<Unit> {
        lock.lock();let children=try{artifactReads.toArray()}finally{lock.unlock()}
        for(child in children){let _=child.cancel()}
        let _=cancellation.cancel()
        if(owner.approval().isNone()){return Result.Ok(())}
        let actual=owner.cancel()
        match(actual){
            case Result.Err(error)=>if(error.kind==AgentErrorKind.Cancelled){Result.Ok(())}else{Result.Err(error)}
            case Result.Ok(ToolInvocationResult.Completed(value))=>
                lock.lock();try{closingPayload=Some(value)}finally{lock.unlock()};Result.Ok(())
            case Result.Ok(_)=>Result.Ok(())}
    }
    public func close(): Result<Unit> {
        lock.lock();let prior=try{
            if(closed){return Result.Ok(())}
            if(closing){return selectedNativeToolError("plugin.frontend_cleanup_pending")}
            closing=true;closeFailure
        }finally{lock.unlock()}
        lock.lock();let children=try{artifactReads.toArray()}finally{lock.unlock()}
        for(child in children){
            match(child.close()){
                case Result.Err(error)=>
                    lock.lock();try{closeFailure=Some(error);closing=false}finally{lock.unlock()};return Result.Err(error)
                case Result.Ok(_)=>()}}
        var failure=prior
        if(prior.isNone()){match(cancel()){case Result.Err(error)=>failure=Some(error);case Result.Ok(_)=>()}}
        lock.lock();let active=try{starting}finally{lock.unlock()}
        if(active){lock.lock();try{closing=false}finally{lock.unlock()};return selectedNativeToolError("plugin.frontend_cleanup_pending")}
        match(owner.closeAcknowledgement()){
            case Result.Err(error)=>
                let original=match(failure){case Some(value)=>value;case None=>error}
                lock.lock();try{closeFailure=Some(original);closing=false}finally{lock.unlock()};return Result.Err(original)
            case Result.Ok(_)=>()}
        lock.lock();let values=try{(completed,closingPayload)}finally{lock.unlock()}
        try{
            match(values[0]){case Some(value)=>value.releasePayload();case None=>()}
            match(values[1]){case Some(value)=>value.releasePayload();case None=>()}
            cancellation.close()
        }catch(_:Exception){
            let error=AgentError(AgentErrorKind.RecoveryRequired,"plugin.frontend_cleanup_failed","same acquired owner retains failed cleanup")
            lock.lock();try{closeFailure=Some(error);closing=false}finally{lock.unlock()}
            return Result.Err(error)}
        lock.lock();try{
            completed=None;closingPayload=None;frozenOutput="";terminalFailure=None;artifactReads.clear();closed=true;closing=false;closeFailure=None
        }finally{lock.unlock()}
        selection.product.releaseNativeFrontendInvocation(this)
        Result.Ok(())
    }
}

func selectedShellArgumentError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput,code,"Shell arguments must fit the selected current operator service profile"))
}

func selectedNativeToolError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Configuration,code,
        "An explicitly selected current native contribution and its own actual user approval are required"))
}

// Descriptive compatibility projection from the actual completed native result.
// It cannot publish a Receipt or revive an owner from returned JSON.
func nativeShellProcessResult(output: AgentValue): Result<ProcessResult> {
    try{
        if(httpIntentText(output,"schema")!="axyndra.service-call-result/v1" || httpIntentText(output,"status")!="complete"){
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"shell.native_outcome_unknown","native shell has no complete canonical outcome"))}
        let value=output.field("result").getOrThrow()
        for(name in ["stdout","stderr","workingDirectory"]){
            if(value.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return selectedNativeToolError("shell.native_result_invalid")}}
        for(name in ["timedOut","truncated"]){
            if(value.field(name).getOrThrow().unifiedKind!=ValueKind.Boolean){return selectedNativeToolError("shell.native_result_invalid")}}
        let exit=value.field("exitCode").getOrThrow()
        if(exit.unifiedKind!=ValueKind.Number){return selectedNativeToolError("shell.native_result_invalid")}
        let code=Int64.parse(exit.asNumberText())
        if(code.toString()!=exit.asNumberText()){return selectedNativeToolError("shell.native_result_invalid")}
        Result.Ok(ProcessResult(code,stdout:value.field("stdout").getOrThrow().text,
            stderr:value.field("stderr").getOrThrow().text,timedOut:value.field("timedOut").getOrThrow().asBool(),
            workingDirectory:value.field("workingDirectory").getOrThrow().text,truncated:value.field("truncated").getOrThrow().asBool()))
    }catch(_:Exception){selectedNativeToolError("shell.native_result_invalid")}
}
