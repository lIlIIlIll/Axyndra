package shell_native_contract
import std.sync.*

import agent_domain.*
import agent_product.*
import shell_readonly_native_contract.*
import agent_store.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import yjson.*
import yjson_support.*

// Read-only test view. This is deliberately not a ToolResult, Source, grant,
// prepared plan or Receipt. receiptId is the original acquired owner's string.
public class NativeShellObservedResult {
    public let output: AgentValue
    public let receiptId: String
    public let isError: Bool
    public let status: String
    public init(output: AgentValue, receiptId: String, isError: Bool, status: String) {
        this.output=output;this.receiptId=receiptId;this.isError=isError;this.status=status
    }
}

public class NativeShellContractBinding {
    public let product: ProductRuntime
    public let namespace: String
    public let name: String
    public let readOnly: Bool
    private let started=HashSet<String>()
    private let invocations=ArrayList<ProductNativeToolInvocation>()
    public init(product: ProductRuntime, readOnly!: Bool=false, mountReadOnly!: Bool=false,
        capturedOutputBytes!: Int64=0, openFiles!: Int64=64,
        readOnlyMounts!: Array<String>=[], pathEnvironment!: String="") {
        this.product=product;this.readOnly=readOnly
        if(readOnly){
            // An independent ordinary Native read-view Root, not the mutable
            // Shell backend or its startup approval. All old callers retain
            // their own actual canonical command and same-owner ACK.
            let selected=NativeReadonlyShellContractBinding(product)
            this.namespace=selected.namespace;this.name=selected.name
        }else{
        let record=match(product.importLocalPlugin(getVariable("AXYNDRA_SHELL_PLUGIN_PACKAGE").getOrThrow())){
            case PluginRegistryResult.Ok(value)=>supportRegistryRecord96(value);case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        if(supportRegistryDescriptor96(record,"namespace")!="axyndra:shell"){throw IllegalStateException("actual packaged Shell required")}
        match(product.setPluginEnabled(supportRegistryDescriptor96(record,"namespace"),true)){
            case PluginRegistryResult.Ok(discard96)=>supportRegistryDiscard96(discard96);case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        this.namespace=supportRegistryDescriptor96(record,"namespace")
        this.name="plugin."+namespace+".service.stdio."+if(readOnly){"bash_readonly"}else{"bash"}
        let args=ArrayList<AgentValue>([textValue("-u"),textValue(supportRegistryDescriptor96(record,"root")+"/backend/shell_backend.py"),
            textValue("--workspace"),textValue(product.workspace.rootPath()),textValue("--stream-output")])
        if(readOnly){args.add(textValue("--readonly"))}
        if(capturedOutputBytes>0){args.add(textValue("--output-bytes"));args.add(textValue(capturedOutputBytes.toString()))}
        let service=objectValue([
            ValueField("id",textValue("stdio")),ValueField("executable",textValue("/usr/bin/python3")),
            ValueField("arguments",listValue(args.toArray())),
            ValueField("read_only_mounts",listValue(readOnlyMounts.map{value=>textValue(value)})),
            ValueField("workspace_mode",textValue(if(readOnly || mountReadOnly){"workspace_readonly"}else{"workspace_readwrite"})),
            ValueField("network",networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied))),
            ValueField("resources",objectValue([
                ValueField("max_output_bytes",integerValue(16777216)),ValueField("address_space_bytes",integerValue(536870912)),
                ValueField("file_size_bytes",integerValue(1048576)),ValueField("open_files",integerValue(openFiles)),
                ValueField("processes",integerValue(32)),ValueField("cpu_seconds",integerValue(10))])),
            ValueField("lifetime_ms",integerValue(180000)),ValueField("max_input_bytes",integerValue(262144)),
            ValueField("max_output_bytes",integerValue(16777216)),ValueField("startup",objectValue([
                ValueField("timeout_ms",integerValue(30000)),ValueField("max_input_bytes",integerValue(4096)),
                ValueField("max_output_bytes",integerValue(16384)),ValueField("max_writes",integerValue(4))])),
            ValueField("protocol_limits",objectValue([
                ValueField("max_frame_bytes",integerValue(524288)),ValueField("max_input_bytes",integerValue(16384)),
                ValueField("max_prepare_bytes",integerValue(131072)),ValueField("max_result_bytes",integerValue(262144)),
                ValueField("max_directory_bytes",integerValue(65536)),ValueField("max_tools",integerValue(64)),
                ValueField("call_timeout_ms",integerValue(60000))])),
            ValueField("environment",if(pathEnvironment==""){objectValue([])}else{
                objectValue([ValueField("PATH",textValue(pathEnvironment))])}),ValueField("credential_refs",listValue([]))])
        if(readOnly || mountReadOnly){service.put("read_only_tools",listValue([textValue(if(readOnly){"bash_readonly"}else{"bash"})]))}
        let document=objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([
            objectValue([ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),
                ValueField("configuration",objectValue([ValueField("version",integerValue(1)),ValueField("request_timeout_ms",integerValue(60000))])),
                ValueField("max_instances",integerValue(16)),ValueField("services",listValue([service]))])]))])
        if(!exists(Path(product.settingsRoot+"/plugins"))){Directory.create(product.settingsRoot+"/plugins",recursive:true)}
        // Keep other actual installed operator profiles. This fixture only
        // replaces its own exact namespace; it does not recreate their grants.
        let lifecyclePath=product.settingsRoot+"/plugins/lifecycle.json"
        if(exists(Path(lifecyclePath))){
            let original=parseUnifiedJson(String.fromUtf8(File.readFrom(lifecyclePath)),maxBytes:1048576)
            if(original.field("version").getOrThrow().asNumberText()!="1" ||
                original.field("plugins").getOrThrow().unifiedKind!=ValueKind.List){
                throw IllegalStateException("actual operator lifecycle shape")}
            let retained=ArrayList<AgentValue>()
            for(entry in original.field("plugins").getOrThrow().items
                where entry.field("namespace").getOrThrow().text!=namespace){retained.add(entry)}
            retained.add(document.field("plugins").getOrThrow().items[0])
            document.put("plugins",listValue(retained.toArray()))}
        File.writeTo(lifecyclePath,stringifyUnifiedJson(document).toArray())
        let selection=objectValue([ValueField("schema",textValue("axyndra.shell-tools/v1")),ValueField("namespace",textValue(namespace)),
            ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),ValueField("service_id",textValue("stdio")),ValueField("route",textValue("session"))])
        File.writeTo(product.settingsRoot+"/plugins/shell-tools.json",stringifyUnifiedJson(selection).toArray())
        }
    }
    public func start(thread: SessionId): Unit {
        if(started.contains(thread.value)){return}
        if(readOnly){
            if(product.vnext.javascriptPlugins.instanceGeneration(namespace)==0u64 ||
                !product.vnext.javascriptPlugins.toolNames(namespace).contains("exec")){
                throw IllegalStateException("actual readonly package is disabled or no longer ready")}
            started.add(thread.value);return
        }
        let actual=product.startPluginService(thread,namespace,"stdio","session",approvalDecision:ApprovalDecision.Approve,
            budget:ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1))
        match(actual){
            case Result.Ok(ToolInvocationResult.Completed(value))=>
                try{if(value.isError){throw IllegalStateException("actual Shell startup rejected")};started.add(thread.value)}
                finally{value.releasePayload()}
            case Result.Err(error)=>throw IllegalStateException(error.code)
            case _=>throw IllegalStateException("separate explicit startup did not complete")}
    }
    public func invoke(thread: SessionId, arguments: AgentValue): ProductNativeToolInvocation {
        start(thread)
        let input=decodeStoredValue(encodeAgentValue(arguments))
        // Preserve the old whole-main 60-second default under this separately
        // configured actual 60-second operator profile, never silently clamp.
        if(input.field("timeout").isNone() && input.field("timeout_ms").isNone()){input.put("timeout",integerValue(60))}
        let actual=match(product.invokeShellTool(thread,input,readOnly:readOnly)){
            case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
        invocations.add(actual);actual
    }
    // A separate ordinary Root for exactly this artifact. The caller provides
    // its own explicit choice; a Shell/startup/session approval is not reused.
    public func readArtifact(parent: ProductNativeToolInvocation, reference: String, decision: ApprovalDecision): String {
        let actual=parent.beginArtifactRead(reference).value().getOrThrow()
        // The original parent also retains this same actual child owner until
        // its cleanup ACK; this frontend never manufactures a Source or grant.
        invocations.add(actual)
        match(actual.approval()){
            case Some(request)=>actual.decide(request.operationId.value,decision).value().getOrThrow()
            case None=>()}
        let value=actual.output().value().getOrThrow()
        if(actual.receiptId()=="" || encodeAgentValue(value).size>1114112){throw IllegalStateException("actual artifact Root or snapshot failed")}
        if(value.field("returned_bytes").getOrThrow().asNumberText()!=value.field("bytes").getOrThrow().asNumberText()){
            throw IllegalStateException("contract artifact exceeds single bounded page")}
        let text=value.field("content").getOrThrow().text
        actual.close().value().getOrThrow();text
    }
    public func observe(thread: SessionId, actual: ProductNativeToolInvocation,
        readArtifactDecision!: ?ApprovalDecision=None): NativeShellObservedResult {
        if(actual.approval().isSome()){throw IllegalStateException("actual command approval still pending")}
        let envelope=actual.observedOutput().value().getOrThrow()
        if(readOnly){
            if(!httpIntentExactFields(envelope,["exit_code","stdout","stderr","timed_out","truncated"])){
                throw IllegalStateException("actual independent readonly Native worker output shape")}
            if(readArtifactDecision.isSome()){
                throw IllegalStateException("readonly worker has no artifact descriptor to turn into a grant")}
            let view=decodeStoredValue(encodeAgentValue(envelope))
            let result=NativeShellObservedResult(view,actual.receiptId(),actual.failure().isSome(),
                if(actual.failure().isSome()){"failed"}else{"complete"})
            actual.close().value().getOrThrow();return result
        }
        if(envelope.field("schema").getOrThrow().text!="axyndra.service-call-result/v1"){
            throw IllegalStateException("not a correlated native Shell observation")}
        let status=envelope.field("status").getOrThrow().text
        let source=envelope.field("result").getOrThrow()
        let raw=encodeAgentValue(source)
        if(raw.size>1114112){throw IllegalStateException("observed Shell snapshot bound")}
        let value=decodeStoredValue(raw)
        match(readArtifactDecision){
            case Some(decision)=>
                match(value.field("artifacts")){
                    case Some(artifacts)=>for(artifact in artifacts.items){
                        let stream=artifact.field("stream").getOrThrow().text
                        if(!["stdout","stderr"].contains(stream)){throw IllegalStateException("unknown observed stream")}
                        value.put(stream,textValue(readArtifact(actual,artifact.field("ref").getOrThrow().text,decision)))}
                    case None=>()}
            case None=>()}
        let view=objectValue([ValueField("stdout",value.field("stdout").getOrThrow()),ValueField("stderr",value.field("stderr").getOrThrow()),
            ValueField("cwd",value.field("workingDirectory").getOrThrow()),ValueField("exit_code",value.field("exitCode").getOrThrow()),
            ValueField("timed_out",value.field("timedOut").getOrThrow()),ValueField("pty",value.field("pty").getOrThrow()),
            ValueField("truncated",value.field("truncated").getOrThrow())])
        let result=NativeShellObservedResult(view,actual.receiptId(),actual.failure().isSome(),status)
        actual.close().value().getOrThrow();result
    }
    public func observedResult(thread: SessionId, arguments: AgentValue): Result<NativeShellObservedResult> {
        start(thread)
        let actual=match(product.invokeShellTool(thread,arguments,readOnly:readOnly)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        invocations.add(actual)
        if(actual.approval().isSome()){throw IllegalStateException("this result requires its own explicit user choice")}
        match(actual.failure()){
            case Some(error)=>actual.close().value().getOrThrow();return Result.Err(error)
            case None=>Result.Ok(observe(thread,actual))}
    }
    public func count(sql: String, parameters!: Array<SqlParameter> = []): Int64 {
        let database=SqliteDatabase(product.stateRoot+"/state.db")
        try{Int64.parse(database.query(sql,parameters)[0].required(0))}finally{database.close()}
    }
    public func close(): Unit {
        for(actual in invocations){
            let until=MonoTime.now()+Duration.second*10
            while(actual.close().isError() && MonoTime.now()<until){sleep(Duration.millisecond*10)}
            if(actual.close().isError()){throw IllegalStateException("same actual Shell owner retains cleanup")}}
        // Arrays clear only after all fixed ACKs, never while a failure is owed.
        invocations.clear()
    }
}

class NativeShellOwnedContractEntry {
    let root: String
    let readOnly: Bool
    let binding: NativeShellContractBinding
    init(root: String, readOnly: Bool, binding: NativeShellContractBinding){this.root=root;this.readOnly=readOnly;this.binding=binding}
}
public class NativeShellContractScope {
    private let workspace: String
    private let approvalMode: ApprovalMode
    private let mountReadOnly: Bool
    private let capturedOutputBytes: Int64
    private let openFiles: Int64
    private let entries=ArrayList<NativeShellOwnedContractEntry>()
    private let failedOpens=ArrayList<(String,ProductRuntime)>()
    public init(workspace: String, approvalMode!: ApprovalMode=ApprovalMode.Yolo,
        mountReadOnly!: Bool=false,capturedOutputBytes!: Int64=0,openFiles!: Int64=64){
        this.workspace=canonicalize(workspace).toString();this.approvalMode=approvalMode
        this.mountReadOnly=mountReadOnly;this.capturedOutputBytes=capturedOutputBytes;this.openFiles=openFiles}
    public func binding(readOnly!: Bool=false): NativeShellContractBinding {
        for(entry in entries where entry.readOnly==readOnly){return entry.binding}
        let root=Directory.createTemp("/tmp").toString();var opened: ?ProductRuntime=None
        try{
            let product=match(openProduct(config:ProductConfig(workspaceRoot:workspace,settingsRoot:root+"/settings",stateRoot:root+"/state",
                fixture:true,approvalMode:approvalMode,asyncEnabled:false))){
                case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
            opened=Some(product)
            let actual=NativeShellContractBinding(product,readOnly:readOnly,mountReadOnly:mountReadOnly,capturedOutputBytes:capturedOutputBytes,openFiles:openFiles)
            entries.add(NativeShellOwnedContractEntry(root,readOnly,actual));actual
        }catch(error:Exception){
            match(opened){case Some(product)=>
                if(product.close().isOk()){remove(root,recursive:true)}else{failedOpens.add((root,product))}
                case None=>remove(root,recursive:true)}
            throw error}
    }
    // Reopen the same actual durable Store after all original owners have
    // ACKed. No permission row or session grant is copied or synthesized.
    public func reopenBinding(): NativeShellContractBinding {
        if(entries.size!=1 || entries[0].readOnly){throw IllegalStateException("one actual writable Shell scope required")}
        let prior=entries[0];prior.binding.close()
        let until=MonoTime.now()+Duration.second*10;var acknowledged=false
        while(!acknowledged && MonoTime.now()<until){
            acknowledged=prior.binding.product.close().isOk();if(!acknowledged){sleep(Duration.millisecond*10)}}
        if(!acknowledged){throw IllegalStateException("same actual Store cannot reopen before cleanup ACK")}
        entries.clear()
        var opened: ?ProductRuntime=None
        try{
            let actual=match(openProduct(config:ProductConfig(workspaceRoot:workspace,settingsRoot:prior.root+"/settings",
                stateRoot:prior.root+"/state",fixture:true,approvalMode:approvalMode,asyncEnabled:false))){
                case Result.Err(error)=>throw IllegalStateException(error.code);case Result.Ok(value)=>value}
            opened=Some(actual)
            let binding=NativeShellContractBinding(actual,mountReadOnly:mountReadOnly,capturedOutputBytes:capturedOutputBytes,openFiles:openFiles)
            entries.add(NativeShellOwnedContractEntry(prior.root,false,binding));binding
        }catch(error:Exception){
            match(opened){case Some(actual)=>
                if(actual.close().isOk()){remove(prior.root,recursive:true)}else{failedOpens.add((prior.root,actual))}
                case None=>remove(prior.root,recursive:true)}
            throw error}
    }
    public func close(): Unit {
        for(entry in entries){
            entry.binding.close()
            let until=MonoTime.now()+Duration.second*10;var closed=false
            while(!closed && MonoTime.now()<until){closed=entry.binding.product.close().isOk();if(!closed){sleep(Duration.millisecond*10)}}
            if(!closed){throw IllegalStateException("actual Shell Product retains Store and runtime until cleanup")}
            if(exists(Path(entry.root))){remove(entry.root,recursive:true)}}
        entries.clear()
        for((root,product) in failedOpens){
            let until=MonoTime.now()+Duration.second*10;var closed=false
            while(!closed && MonoTime.now()<until){closed=product.close().isOk();if(!closed){sleep(Duration.millisecond*10)}}
            if(!closed){throw IllegalStateException("failed construction retains actual Product cleanup")}
            if(exists(Path(root))){remove(root,recursive:true)}}
        failedOpens.clear()
    }
}

func nativeShellContractCapabilities(): CapabilitySet {
    CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.WorkspaceWrite),
        Capability(CapabilityKind.ProcessSpawn),Capability(CapabilityKind.NetworkAccess),Capability(CapabilityKind.ExtensionInvoke),
        Capability(CapabilityKind.PeerMessage),Capability(CapabilityKind.Delegate)])
}

public func nativeShellObservedCall(binding: NativeShellContractBinding,
    context: ToolInvocationContext, arguments: AgentValue,
    choice!: ?ApprovalDecision=None, artifactChoice!: ?ApprovalDecision=None): NativeShellObservedResult {
    let actual=binding.invoke(context.sessionId,arguments)
    match(actual.approval()){
        case Some(request)=>match(choice){
            case None=>throw IllegalStateException("missing explicit choice for this actual command")
            case Some(decision)=>
                let decided=actual.decide(request.operationId.value,decision)
                if(decided.isError() && actual.approval().isSome()){throw IllegalStateException("actual choice was not consumed")}}
        case None=>()}
    binding.observe(context.sessionId,actual,readArtifactDecision:artifactChoice)
}

// Test consumer DATA only. No copied metadata becomes an installed Source,
// pin, receipt, grant, operation, or replacement public Registry record.
// The source Registry byte carrier pays its complete copied graph before
// allocating an Array/String/DOM. Original configuration/public fixture text
// has no retirement protocol, so those independent loans remain paid.
class SupportRegistryCopyDebt96 {
    let payment:LogicalJsonOwnerReservation
    let previous:?SupportRegistryCopyDebt96
    init(payment:LogicalJsonOwnerReservation,previous:?SupportRegistryCopyDebt96){
        this.payment=payment;this.previous=previous}
}
class SupportRegistryRecordData96 {
    let record:ProductPluginRecord
    private let graph:AgentValue
    private let payment:LogicalJsonOwnerReservation
    private let lock=Mutex()
    private var pending:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    let enabled:Bool
    let explicitlyDisabled:Bool
    let sourceKind:PluginSourceKind
    let scope:PluginInstallScope
    let previous:?SupportRegistryRecordData96
    init(record:ProductPluginRecord,graph:AgentValue,payment:LogicalJsonOwnerReservation,
        enabled:Bool,explicitlyDisabled:Bool,sourceKind:PluginSourceKind,scope:PluginInstallScope,
        previous:?SupportRegistryRecordData96){
        this.record=record;this.graph=graph;this.payment=payment
        this.enabled=enabled;this.explicitlyDisabled=explicitlyDisabled;this.sourceKind=sourceKind
        this.scope=scope;this.previous=previous}
    func text(key:String,descriptor!:Bool=false):String{
        lock.lock();try{
            if(pending.isSome()){throw LogicalJsonPayloadError("same copied metadata keeps its failed occurrence payment")}
            let value=if(descriptor){graph.field("descriptor").getOrThrow().field(key).getOrThrow().text}
                else{graph.field(key).getOrThrow().text}
            let loan=payment.deriveRetainedLease();pending=Some(loan)
            loan.ensureRetainedPeak(supportRegistryInvoice96(value.size,0))
            supportRegistryRetain96(loan);pending=None<LogicalJsonOwnerReservation>;value
        }finally{lock.unlock()}
    }
}
class SupportRegistryCopies96 {
    let lock=Mutex()
    var payments:?SupportRegistryCopyDebt96=None<SupportRegistryCopyDebt96>
    var records:?SupportRegistryRecordData96=None<SupportRegistryRecordData96>
}
let supportRegistryCopies96=SupportRegistryCopies96()
func supportRegistryInvoice96(bytes:Int64,nodes:Int64):Int64{
    if(bytes<0 || nodes<0 || nodes>(134217728-8192)/1024 ||
        bytes>(134217728-8192-nodes*1024)/64){
        throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")}
    bytes*64+nodes*1024+8192
}
func supportRegistryRetain96(payment:LogicalJsonOwnerReservation):Unit{
    supportRegistryCopies96.lock.lock();try{
        supportRegistryCopies96.payments=Some(SupportRegistryCopyDebt96(payment,supportRegistryCopies96.payments))
    }finally{supportRegistryCopies96.lock.unlock()}
}
func supportRegistryText96(result:PluginRegistryResult<OwnedRegistryUtf8>):String{
    let source=match(result){case PluginRegistryResult.Ok(value)=>value
        case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorText96(error))}
    try{
        let size=source.byteCount
        let payment=source.deriveCopiedDataPayment(supportRegistryInvoice96(size,0))
        supportRegistryRetain96(payment)
        let bytes=Array<UInt8>(size,{index=>source.byteAt(index)})
        String.fromUtf8(bytes)
    }finally{source.close()}
}
func supportRegistryErrorText96(error:PluginRegistryOwnedError):String{
        match(error.staticReason){
            case PluginRegistryStaticReason.MetadataCapacity=>"registry metadata cannot fit the original shared capacity"
            case PluginRegistryStaticReason.ExecutionNotCurrent=>"installed execution pin is not current"
            case PluginRegistryStaticReason.InstalledRecordAbsent=>"installed record is absent"
            case PluginRegistryStaticReason.ComponentAliasInvalid=>"initial context configuration or its exact installed binding is unavailable"
            case PluginRegistryStaticReason.NoStaticReason=>supportRegistryText96(error.copyText(PluginRegistryErrorText.Message))}
}
func supportRegistryExclusiveErrorText96(error:PluginRegistryOwnedError):String{
    try{supportRegistryErrorText96(error)}finally{error.close()}
}
func supportRegistryExclusiveErrorCode96(error:PluginRegistryOwnedError):String{
    try{error.code}finally{error.close()}
}
func supportRegistryDiscard96(record:ProductPluginRecord):Unit{record.close()}
func supportRegistryOkay96(result:PluginRegistryResult<ProductPluginRecord>):Bool{
    match(result){case PluginRegistryResult.Ok(record)=>record.close();true
        case PluginRegistryResult.Err(error)=>error.close();false}
}
func supportRegistryData96(record:ProductPluginRecord):SupportRegistryRecordData96{
    supportRegistryCopies96.lock.lock();try{
        var current=supportRegistryCopies96.records
        while(current.isSome()){
            let row=current.getOrThrow()
            if(refEq(row.record,record)){return row};current=row.previous}
    }finally{supportRegistryCopies96.lock.unlock()}
    // Read real immutable scalar data while the actual view is live. State
    // replacement may revoke it later; the test's original metadata stays in
    // this independent same-bank copy instead of resurrecting that view.
    let enabled=record.enabled;let disabled=record.explicitlyDisabled
    let kind=record.sourceKind;let scope=record.scope
    let source=match(record.copyJson()){case PluginRegistryResult.Ok(value)=>value
        case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorText96(error))}
    try{
        let size=source.byteCount
        var quoted=false;var escaped=false;var primitive=false;var nodes:Int64=0
        for(index in 0..size){
            let byte=source.byteAt(index)
            if(quoted){if(escaped){escaped=false}else if(byte==92u8){escaped=true}else if(byte==34u8){quoted=false};continue}
            if(byte==34u8){nodes+=1;quoted=true;primitive=false}
            else if(byte==123u8 || byte==91u8){nodes+=1;primitive=false}
            else if(byte==44u8 || byte==58u8 || byte==125u8 || byte==93u8 || byte<=32u8){primitive=false}
            else if(!primitive){nodes+=1;primitive=true}}
        let payment=source.deriveCopiedDataPayment(supportRegistryInvoice96(size,nodes))
        supportRegistryRetain96(payment)
        let bytes=Array<UInt8>(size,{index=>source.byteAt(index)})
        let graph=parseUnifiedJson(String.fromUtf8(bytes),maxBytes:size)
        supportRegistryCopies96.lock.lock();try{
            let row=SupportRegistryRecordData96(record,graph,payment,enabled,disabled,kind,scope,supportRegistryCopies96.records)
            supportRegistryCopies96.records=Some(row);row
        }finally{supportRegistryCopies96.lock.unlock()}
    }finally{source.close()}
}
func supportRegistryRecord96(record:ProductPluginRecord):ProductPluginRecord{
    let _=supportRegistryData96(record);record
}
func supportRegistryDescriptor96(record:ProductPluginRecord,key:String):String{
    let row=supportRegistryData96(record)
    // Each returned occurrence is separately paid before it can escape into
    // configuration, a path, a fixture field, an exception or another frame.
    row.text(key,descriptor:true)
}
func supportRegistryField96(record:ProductPluginRecord,key:String):String{
    supportRegistryData96(record).text(key)
}
