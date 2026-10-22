package eval_native_contract
import std.sync.*

import agent_domain.*
import agent_product.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import yjson.*
import yjson_support.*

// A support-test frontend for the actual installed native package. It borrows
// the caller's Product/Store/manager. It never owns a subprocess, selects a
// retired executor, constructs a Source, or restores an expired grant.
public class NativeEvalContractBinding {
    public let product: ProductRuntime
    public let namespace: String
    public let name: String
    public let language: String
    private let explicitlyStarted = HashSet<String>()

    public init(product: ProductRuntime, language!: String = "py",
        executable!: String = "/usr/bin/python3", maxOutputBytes!: Int64 = 1048576, startupTimeoutMillis!: Int64 = 30000) {
        this.product = product
        this.language = language
        let record = match (product.importLocalPlugin(getVariable("AXYNDRA_EVAL_PLUGIN_PACKAGE").getOrThrow())) {
            case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
            case PluginRegistryResult.Err(error) => throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))
        }
        if (supportRegistryDescriptor96(record,"namespace") != "axyndra:eval") {
            throw IllegalStateException("actual installed Eval package required")
        }
        match (product.setPluginEnabled(supportRegistryDescriptor96(record,"namespace"), true)) {
            case PluginRegistryResult.Ok(discard96) => supportRegistryDiscard96(discard96)
            case PluginRegistryResult.Err(error) => throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))
        }
        namespace = supportRegistryDescriptor96(record,"namespace")
        name = "plugin." + namespace + ".service.stdio.eval"
        let runner = match (language) {
            case "py" => "python.py"
            case "js" => "javascript.mjs"
            case "rb" => "ruby.rb"
            case "jl" => "julia.jl"
            case _ => throw IllegalArgumentException("unsupported actual Eval profile")
        }
        let runnerPath = supportRegistryDescriptor96(record,"root") + "/runners/" + runner
        if (!exists(Path(runnerPath))) { throw IllegalStateException("installed Eval runner missing") }
        let arguments = ArrayList<AgentValue>()
        if (language == "py") { arguments.add(textValue("-u")) }
        if (language == "jl") {
            arguments.add(textValue("--startup-file=no"))
            arguments.add(textValue("--history-file=no"))
        }
        arguments.add(textValue(runnerPath))
        let service = objectValue([
            ValueField("id", textValue("stdio")), ValueField("executable", textValue(executable)),
            ValueField("arguments", listValue(arguments.toArray())), ValueField("read_only_mounts", listValue([])),
            ValueField("workspace_mode", textValue("workspace_readwrite")),
            ValueField("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied))),
            ValueField("resources", objectValue([
                ValueField("max_output_bytes", integerValue(maxOutputBytes)),
                ValueField("address_space_bytes", integerValue(536870912)),
                ValueField("file_size_bytes", integerValue(1048576)), ValueField("open_files", integerValue(64)),
                ValueField("processes", integerValue(8)), ValueField("cpu_seconds", integerValue(10))])),
            ValueField("lifetime_ms", integerValue(180000)), ValueField("max_input_bytes", integerValue(262144)),
            ValueField("max_output_bytes", integerValue(maxOutputBytes)),
            ValueField("startup", objectValue([
                ValueField("timeout_ms", integerValue(startupTimeoutMillis)), ValueField("max_input_bytes", integerValue(4096)),
                ValueField("max_output_bytes", integerValue(min(16384, maxOutputBytes))), ValueField("max_writes", integerValue(4))])),
            ValueField("environment", objectValue([])), ValueField("credential_refs", listValue([]))
        ])
        let document = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([
            objectValue([ValueField("namespace", textValue(namespace)),
                ValueField("package_digest", textValue(supportRegistryDescriptor96(record,"content_digest"))),
                ValueField("configuration", objectValue([ValueField("version", integerValue(1)),
                    ValueField("language", textValue(language)), ValueField("max_timeout_ms", integerValue(30000))])),
                ValueField("max_instances", integerValue(16)), ValueField("services", listValue([service]))])
        ]))])
        if (!exists(Path(product.settingsRoot + "/plugins"))) {
            Directory.create(product.settingsRoot + "/plugins", recursive: true)
        }
        File.writeTo(product.settingsRoot + "/plugins/lifecycle.json", stringifyUnifiedJson(document).toArray())
    }

    // Each new Thread is explicitly started by the test frontend. call() never
    // starts or restarts a missing/withdrawn service after an unknown outcome.
    public func start(thread: SessionId): Result<ToolInvocationResult> {
        let result = product.startPluginService(thread, namespace, "stdio", "session",
            approvalDecision: ApprovalDecision.Approve,
            budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
        match (result) {
            case Result.Ok(ToolInvocationResult.Completed(value)) =>
                if (!value.isError) { explicitlyStarted.add(thread.value) }
            case _ => ()
        }
        result
    }

    public func wasExplicitlyStarted(thread: SessionId): Bool { explicitlyStarted.contains(thread.value) }

    public func call(thread: SessionId, call: ToolCall,
        capabilities!: CapabilitySet = nativeEvalContractCapabilities()): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(thread, capabilities,
            ToolCall(call.callId, name, call.arguments),
            budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
    }

    public func visible(thread: SessionId): Bool {
        for (definition in product.tools(threadId: Some(ThreadId(thread.value))) where definition.name == name) { return true }
        false
    }

    // Test-only queries of this actual Product's durable database. No row is
    // written and no Source, grant, Root, operation or Receipt is manufactured.
    public func count(sql: String, parameters!: Array<SqlParameter> = []): Int64 {
        let database = SqliteDatabase(product.stateRoot + "/state.db")
        try { Int64.parse(database.query(sql, parameters)[0].required(0)) } finally { database.close() }
    }
    public func childReceipts(): Int64 {
        count("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect " +
            "ON effect.operation_id=receipt.operation_id WHERE effect.tool_id=? AND receipt.outcome='completed'",
            parameters: [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)])
    }
    public func awaitChildReceipt(): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        while (childReceipts() == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (childReceipts() != 1) { throw IllegalStateException("actual cell write Receipt missing") }
    }

    public func waitReleased(): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        while (MonoTime.now() < deadline) {
            var held = false
            for (status in product.pluginServiceStatuses() where !status.field("cleanup_acknowledged").getOrThrow().asBool()) { held = true }
            if (!held) { return }
            sleep(Duration.millisecond * 10)
        }
        throw IllegalStateException("actual Eval cleanup acknowledgement missing")
    }
}

// Only a complete, observed cell has the former flat result view. The exact
// canonical call/Receipt/payload owner and error flag are retained. Unknown,
// denied, pending approval, and transport errors remain unchanged.
public func nativeEvalObservedCellView(result: Result<ToolInvocationResult>): Result<ToolInvocationResult> {
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            if (value.output.field("schema").isNone() ||
                value.output.field("schema").getOrThrow().text != "axyndra.service-call-result/v1" ||
                value.output.field("status").isNone() || value.output.field("status").getOrThrow().text != "complete" ||
                value.output.field("result").isNone()) { return result }
            Result.Ok(ToolInvocationResult.Completed(ToolResult(value.callId,
                value.output.field("result").getOrThrow(), isError: value.isError,
                receiptId: value.receiptId, payloadLease: value.payloadLease)))
        case _ => result
    }
}

// Explicit test consumer ACK: copy only the complete, already observed cell
// into this test's bounded heap and then release its original payload lease.
// This snapshot cannot be submitted as a Source, grant, or executable plan.
public func nativeEvalObservedCellSnapshot(result: Result<ToolInvocationResult>): Result<ToolInvocationResult> {
    let observed = nativeEvalObservedCellView(result)
    match (observed) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            try {
                let raw = encodeAgentValue(value.output)
                if (raw.size > 1048576) { return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "test.eval_observed_snapshot_limit", "observed Eval test result exceeds its allocation bound")) }
                Result.Ok(ToolInvocationResult.Completed(ToolResult(value.callId, decodeStoredValue(raw),
                    isError: value.isError, receiptId: value.receiptId)))
            } finally { value.releasePayload() }
        case _ => observed
    }
}

class NativeEvalOwnedContractEntry {
    let root: String
    let workspace: String
    let language: String
    let executable: String
    let maxOutputBytes: Int64
    let startupTimeoutMillis: Int64
    let binding: NativeEvalContractBinding
    init(root: String, workspace: String, language: String, executable: String,
        maxOutputBytes: Int64, startupTimeoutMillis: Int64, binding: NativeEvalContractBinding) {
        this.root = root; this.workspace = workspace; this.language = language
        this.executable = executable; this.maxOutputBytes = maxOutputBytes
        this.startupTimeoutMillis = startupTimeoutMillis; this.binding = binding
    }
}

// A separate actual Product/Store per workspace/profile permits the former
// profile-isolation fixtures to select py/js/rb without mixing permissions or
// service generations. Every process remains owned by the existing Host
// lifecycle manager; this support package has no launcher or process registry.
public class NativeEvalContractScope {
    private let workspace: String
    private let approvalMode: ApprovalMode
    private let entries = ArrayList<NativeEvalOwnedContractEntry>()
    private let failedOpens = ArrayList<(String, ProductRuntime)>()
    public init(workspace: String, approvalMode!: ApprovalMode = ApprovalMode.Yolo) {
        this.workspace = canonicalize(workspace).toString(); this.approvalMode = approvalMode
    }

    public func binding(language: String, workingDirectory!: String = "",
        executable!: String = "", maxOutputBytes!: Int64 = 1048576,
        startupTimeoutMillis!: Int64 = 30000): NativeEvalContractBinding {
        let actualWorkspace = if (workingDirectory == "") { workspace } else { canonicalize(workingDirectory).toString() }
        let selectedExecutable = if (executable != "") { executable } else {
            let variable = match (language) {
                case "py" => "AXYNDRA_EVAL_PYTHON_EXECUTABLE"
                case "js" => "AXYNDRA_EVAL_JS_EXECUTABLE"
                case "rb" => "AXYNDRA_EVAL_RUBY_EXECUTABLE"
                case "jl" => "AXYNDRA_EVAL_JULIA_EXECUTABLE"
                case _ => throw IllegalArgumentException("unsupported actual Eval profile")
            }
            match (getVariable(variable)) {
                case Some(value) => value
                case None => match (language) {
                    case "py" => "/usr/bin/python3"
                    case "js" => "bun"
                    case "rb" => "ruby"
                    case _ => "julia"
                }
            }
        }
        for (entry in entries where entry.workspace == actualWorkspace && entry.language == language &&
            entry.executable == selectedExecutable && entry.maxOutputBytes == maxOutputBytes &&
            entry.startupTimeoutMillis == startupTimeoutMillis) { return entry.binding }
        let root = Directory.createTemp("/tmp").toString()
        var opened: ?ProductRuntime = None
        try {
            let product = match (openProduct(config: ProductConfig(workspaceRoot: actualWorkspace,
                settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
                approvalMode: approvalMode, asyncEnabled: false))) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.describe())
            }
            opened = Some(product)
            let binding = NativeEvalContractBinding(product, language: language,
                executable: selectedExecutable, maxOutputBytes: maxOutputBytes, startupTimeoutMillis: startupTimeoutMillis)
            entries.add(NativeEvalOwnedContractEntry(root, actualWorkspace, language,
                selectedExecutable, maxOutputBytes, startupTimeoutMillis, binding))
            binding
        } catch (error: Exception) {
            // Never remove the actual owned directory while cleanup is owed.
            match (opened) {
                case Some(product) =>
                    if (product.close().isOk()) { remove(root, recursive: true) }
                    else { failedOpens.add((root, product)) }
                case None => remove(root, recursive: true)
            }
            throw error
        }
    }

    public func call(context: ToolInvocationContext, call: ToolCall): Result<ToolInvocationResult> {
        let language = call.arguments.field("language").getOrThrow().text
        let selected = binding(language)
        if (!selected.wasExplicitlyStarted(context.sessionId)) {
            let startup = selected.start(context.sessionId)
            match (startup) {
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    try {
                        if (value.isError) { return Result.Ok(ToolInvocationResult.Completed(value)) }
                    } finally { if (!value.isError) { value.releasePayload() } }
                case _ => return startup
            }
        }
        nativeEvalObservedCellSnapshot(selected.call(context.sessionId, call))
    }

    public func close(): Unit {
        for (entry in entries) {
            let deadline = MonoTime.now() + Duration.second * 10
            var closed = false
            while (!closed && MonoTime.now() < deadline) {
                closed = entry.binding.product.close().isOk()
                if (!closed) { sleep(Duration.millisecond * 10) }
            }
            if (!closed) { throw IllegalStateException("actual Eval scope retains Host cleanup ownership") }
            if (exists(Path(entry.root))) { remove(entry.root, recursive: true) }
        }
        entries.clear()
        for ((root, product) in failedOpens) {
            let deadline = MonoTime.now() + Duration.second * 10
            var closed = false
            while (!closed && MonoTime.now() < deadline) {
                closed = product.close().isOk()
                if (!closed) { sleep(Duration.millisecond * 10) }
            }
            if (!closed) { throw IllegalStateException("failed Eval construction retains Host cleanup ownership") }
            if (exists(Path(root))) { remove(root, recursive: true) }
        }
        failedOpens.clear()
    }
}

public func executeNativeEvalCall(scope: NativeEvalContractScope,
    context: ToolInvocationContext, call: ToolCall): Result<ToolInvocationResult> {
    scope.call(context, call)
}

// This is the same explicit Product frontend ceiling as Product's existing
// canonical invoke entrypoint. It is never accepted from a plugin payload.
func nativeEvalContractCapabilities(): CapabilitySet {
    CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead), Capability(CapabilityKind.WorkspaceWrite),
        Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.NetworkAccess),
        Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.PeerMessage), Capability(CapabilityKind.Delegate)])
}

public func nativeEvalStartChecked(binding: NativeEvalContractBinding, thread: SessionId): Unit {
    let result = binding.start(thread)
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            try { if (value.isError) { throw IllegalStateException("actual Eval service startup failed") } }
            finally { value.releasePayload() }
        case Result.Err(error) => throw IllegalStateException(error.code)
        case _ => throw IllegalStateException("actual Eval service startup was not completed")
    }
}

public func nativeEvalFailed(result: Result<ToolInvocationResult>): Bool {
    match (result) {
        case Result.Err(_) => true
        case Result.Ok(ToolInvocationResult.Denied(_)) => true
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            try { value.isError } finally { value.releasePayload() }
        case _ => false
    }
}

public func nativeEvalObservedLocalCell(result: Result<ToolResult>): Result<ToolResult> {
    let observed = match (result) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(value) => nativeEvalObservedCellSnapshot(Result.Ok(ToolInvocationResult.Completed(value)))
    }
    match (observed) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => Result.Ok(value)
        case Result.Err(error) => Result.Err(error)
        case _ => throw IllegalStateException("a local completed result changed its actual variant")
    }
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
