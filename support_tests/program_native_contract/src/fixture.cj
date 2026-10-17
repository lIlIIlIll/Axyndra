package program_native_contract

import agent_domain.*
import agent_extension_runtime.{PluginEntryKind}
import agent_product.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Descriptive names come from actual installed and ready contributions. This
// lookup performs no admission, authorization, execution or installation.
public func nativeProgramContractToolName(product: ProductRuntime): String {
    nativeContractContributionName(product,"axyndra:program","run")
}
public func nativeWorkspaceContractToolName(product: ProductRuntime, contribution: String): String {
    nativeContractContributionName(product,"axyndra:workspace",contribution)
}
func nativeContractContributionName(product: ProductRuntime, namespace: String, contribution: String): String {
    // The public snapshot list is index-addressed, not an iterator; walk it
    // explicitly and keep the same namespace/enabled/kind filter.
    let snapshots = product.pluginSnapshots()
    for (snapshotIndex in 0..snapshots.size) {
        let record = snapshots.at(snapshotIndex)
        if (!(supportRegistryDescriptor96(record,"namespace")==namespace && supportRegistryData96(record).enabled &&
            !supportRegistryData96(record).explicitlyDisabled && record.descriptor.entryKind==PluginEntryKind.NativeExecutable)) { continue }
        if(product.vnext.javascriptPlugins.instanceGeneration(namespace)!=0u64 &&
            product.vnext.javascriptPlugins.toolNames(namespace).contains(contribution)){
            return "plugin."+supportRegistryDescriptor96(record,"namespace")+"."+contribution}}
    throw IllegalStateException("actual installed ready Native contribution required")
}

// Only a Test fixture for the actual public import/enable/operator path. This
// object is not a Source, grant, Receipt, invocation or substitute executor.
public class NativeProgramContractBinding {
    public let product: ProductRuntime
    public let program: ProductPluginRecord
    public let workspace: ProductPluginRecord
    private let attachInput: Bool

    public init(product: ProductRuntime, filePlanProposals!: Bool=false, inputAttachment!: Bool=true) {
        this.product=product;this.attachInput=inputAttachment
        let resources=match(product.importLocalPlugin(
            getVariable("AXYNDRA_WORKSPACE_PLUGIN_PACKAGE").getOrThrow(),PluginInstallScope.Workspace)){
            case PluginRegistryResult.Ok(value)=>supportRegistryRecord96(value)
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        if(supportRegistryDescriptor96(resources,"namespace")!="axyndra:workspace" || resources.descriptor.entryKind!=PluginEntryKind.NativeExecutable){
            throw IllegalStateException("actual packaged Workspace contribution required")}
        match(product.setPluginEnabled(supportRegistryDescriptor96(resources,"namespace"),true,PluginInstallScope.Workspace)){
            case PluginRegistryResult.Ok(discard96)=>supportRegistryDiscard96(discard96)
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        let installed=match(product.importLocalPlugin(
            getVariable("AXYNDRA_PROGRAM_PLUGIN_PACKAGE").getOrThrow(),PluginInstallScope.Workspace)){
            case PluginRegistryResult.Ok(value)=>supportRegistryRecord96(value)
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        if(supportRegistryDescriptor96(installed,"namespace")!="axyndra:program" || installed.descriptor.entryKind!=PluginEntryKind.NativeExecutable){
            throw IllegalStateException("actual packaged Program contribution required")}
        match(product.setPluginEnabled(supportRegistryDescriptor96(installed,"namespace"),true,PluginInstallScope.Workspace)){
            case PluginRegistryResult.Ok(discard96)=>supportRegistryDiscard96(discard96)
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        this.program=installed;this.workspace=resources
        configure(filePlanProposals)
    }

    public prop name: String { get(){"plugin."+supportRegistryDescriptor96(program,"namespace")+".run"} }
    public func workspaceName(contribution: String): String {
        if(!["read","grep","glob"].contains(contribution)){
            throw IllegalStateException("readonly fixture has no other delegated contribution")}
        "plugin."+supportRegistryDescriptor96(workspace,"namespace")+"."+contribution
    }
    public func input(code: String): AgentValue {objectValue([ValueField("code",textValue(code))])}

    public func configure(filePlanProposals: Bool): Unit {
        let path=product.settingsRoot+"/plugins/services.json"
        let entries=ArrayList<AgentValue>()
        if(exists(Path(path))){
            let previous=parseUnifiedJson(String.fromUtf8(File.readFrom(path)),maxBytes:1048576)
            if(previous.field("version").getOrThrow().asNumberText()!="1" ||
                previous.field("plugins").getOrThrow().unifiedKind!=ValueKind.List){
                throw IllegalStateException("actual operator configuration shape")}
            for(entry in previous.field("plugins").getOrThrow().items where
                entry.field("namespace").getOrThrow().text!=supportRegistryDescriptor96(workspace,"namespace") &&
                entry.field("namespace").getOrThrow().text!=supportRegistryDescriptor96(program,"namespace")){entries.add(entry)}
        }
        let grants=ArrayList<AgentValue>();let targets=ArrayList<AgentValue>()
        for(contribution in ["read","grep","glob"]){
            grants.add(objectValue([ValueField("kind",textValue("tool")),ValueField("name",textValue(contribution)),
                ValueField("effect",textValue("read_only")),ValueField("services",listValue([textValue("process.readview")]))]))
            targets.add(objectValue([ValueField("alias",textValue(contribution)),
                ValueField("plugin",textValue(supportRegistryDescriptor96(workspace,"namespace"))),ValueField("contribution",textValue(contribution))]))}
        entries.add(objectValue([ValueField("namespace",textValue(supportRegistryDescriptor96(workspace,"namespace"))),
            ValueField("package_digest",textValue(supportRegistryDescriptor96(workspace,"content_digest"))),ValueField("configuration",objectValue([])),
            ValueField("requests",listValue([])),ValueField("credentials",listValue([])),ValueField("tool_read_grants",listValue(grants.toArray()))]))
        let delegation=objectValue([ValueField("contribution",textValue("run")),ValueField("max_calls",integerValue(32)),
            ValueField("max_depth",integerValue(2)),ValueField("tools",listValue(targets.toArray()))])
        // Preview permission is an explicit fixture choice. It never creates
        // permission to apply the resulting plan or changes a Run budget.
        if(filePlanProposals){delegation.put("file_plan_proposals",boolValue(true))}
        let actualProgram=objectValue([ValueField("namespace",textValue(supportRegistryDescriptor96(program,"namespace"))),
            ValueField("package_digest",textValue(supportRegistryDescriptor96(program,"content_digest"))),ValueField("configuration",objectValue([])),
            ValueField("requests",listValue([])),ValueField("credentials",listValue([])),ValueField("tool_delegations",listValue([delegation]))])
        if(attachInput){actualProgram.put("tool_input_attachments",listValue([objectValue([
            ValueField("contribution",textValue("run")),ValueField("field",textValue("code")),ValueField("max_bytes",integerValue(262144))])]))}
        entries.add(actualProgram)
        if(!exists(Path(product.settingsRoot+"/plugins"))){Directory.create(product.settingsRoot+"/plugins",recursive:true)}
        File.writeTo(path,stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),
            ValueField("plugins",listValue(entries.toArray()))])).toArray())
    }

    // Read-only evidence checks after real execution. No row is written and
    // no DTO is promoted into an executable Source or permission.
    public func requireCompletedBranches(database: SqliteDatabase, runId: RunId,
        rootOperationId: String, contributions: Array<String>): Unit {
        let store=DurableOperationStore(database)
        let business=database.query("SELECT a.operation_id,a.call_sequence,a.child_call_id,a.request_key,a.request_digest,"+
            "a.root_operation_id,a.depth,o.state,e.tool_id,e.reserved_receipt_id,r.id,r.outcome,o.normalized_plan,e.normalized_plan "+
            "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id "+
            "WHERE a.parent_operation_id=? AND o.run_id=? ORDER BY a.call_sequence",
            [SqlParameter.Text(rootOperationId),SqlParameter.Text(runId.value)])
        if(business.size!=contributions.size){throw IllegalStateException("actual Program business branch inventory")}
        for(i in 0..business.size){
            let row=business[i];let operation=OperationId(row.required(0))
            let actualName=workspaceName(contributions[i])
            if(row.required(1)!=(i+1).toString() || row.required(2)=="" || row.required(3)=="" ||
                row.required(4).size!=64 || row.required(5)!=rootOperationId || row.required(6)!="1" ||
                row.required(7)!="committed" || row.required(8)!=actualName || row.required(9)!=row.required(10) ||
                row.required(11)!="completed" || row.required(12)!=row.required(13)){
                throw IllegalStateException("actual Program branch identity/Source/Receipt enclosure")}
            if(store.loadCall(operation,runId).value().getOrThrow().callId!=row.required(2)){
                throw IllegalStateException("actual business call identity")}
            requireReadonlyPlan(store.loadPlan(operation,runId).value().getOrThrow())
            let worker=database.query("SELECT a.operation_id,a.parent_operation_id,a.root_operation_id,a.depth,a.call_sequence,"+
                "a.child_call_id,a.request_key,a.request_digest,o.state,e.tool_id,e.reserved_receipt_id,r.id,r.outcome,"+
                "o.normalized_plan,e.normalized_plan FROM derived_operation_admissions a "+
                "JOIN operations o ON o.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=o.id "+
                "JOIN operation_receipts r ON r.operation_id=o.id WHERE a.parent_operation_id=? AND o.run_id=?",
                [SqlParameter.Text(operation.value),SqlParameter.Text(runId.value)])
            if(worker.size!=1){throw IllegalStateException("one actual readview child per business branch")}
            let child=worker[0];let childId=OperationId(child.required(0))
            if(child.required(1)!=operation.value || child.required(2)!=rootOperationId || child.required(3)!="2" ||
                child.required(4)!="1" || child.required(5)=="" || child.required(6)=="" || child.required(7).size!=64 ||
                child.required(8)!="committed" || child.required(9)!="host.process.readview" ||
                child.required(10)!=child.required(11) || child.required(12)!="completed" || child.required(13)!=child.required(14)){
                throw IllegalStateException("actual readview child Source/parent/Root/Receipt enclosure")}
            if(store.loadCall(childId,runId).value().getOrThrow().callId!=child.required(5)){
                throw IllegalStateException("actual readview call identity")}
            requireReadonlyPlan(store.loadPlan(childId,runId).value().getOrThrow())
            for(actual in [operation.value,childId.value]){
                let handoffs=database.query("SELECT COUNT(*) FROM audit_events h JOIN runs r ON r.id=h.run_id "+
                    "WHERE h.operation_id=? AND h.run_id=? AND h.thread_id=r.thread_id AND h.kind='operation_execution_handoff'",
                    [SqlParameter.Text(actual),SqlParameter.Text(runId.value)])
                if(handoffs.size!=1 || handoffs[0].required(0)!="1"){
                    throw IllegalStateException("actual canonical execution handoff")}}
        }
    }
    public func requireCompletedReadviewRoot(database: SqliteDatabase, runId: RunId,
        rootId: String, toolName: String): Unit {
        if(![workspaceName("read"),workspaceName("grep"),workspaceName("glob")].contains(toolName)){
            throw IllegalStateException("actual ordinary readview root name")}
        let rows=database.query("SELECT o.state,e.tool_id,e.reserved_receipt_id,r.id,r.outcome,o.normalized_plan,e.normalized_plan "+
            "FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id "+
            "WHERE o.id=? AND o.run_id=? AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)",
            [SqlParameter.Text(rootId),SqlParameter.Text(runId.value)])
        if(rows.size!=1 || rows[0].required(0)!="committed" || rows[0].required(1)!=toolName ||
            rows[0].required(2)!=rows[0].required(3) || rows[0].required(4)!="completed" || rows[0].required(5)!=rows[0].required(6)){
            throw IllegalStateException("actual ordinary root Source/Receipt identity")}
        let store=DurableOperationStore(database)
        requireReadonlyPlan(store.loadPlan(OperationId(rootId),runId).value().getOrThrow())
        let children=database.query("SELECT a.operation_id,a.root_operation_id,a.depth,a.call_sequence,a.child_call_id,a.request_key,a.request_digest,"+
            "o.state,e.tool_id,e.reserved_receipt_id,r.id,r.outcome,o.normalized_plan,e.normalized_plan "+
            "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN operation_receipts r ON r.operation_id=o.id WHERE a.parent_operation_id=? AND o.run_id=?",
            [SqlParameter.Text(rootId),SqlParameter.Text(runId.value)])
        if(children.size!=1){throw IllegalStateException("one actual readview child per ordinary root")}
        let child=children[0];let id=OperationId(child.required(0))
        if(child.required(1)!=rootId || child.required(2)!="1" || child.required(3)!="1" || child.required(4)=="" ||
            child.required(5)=="" || child.required(6).size!=64 || child.required(7)!="committed" || child.required(8)!="host.process.readview" ||
            child.required(9)!=child.required(10) || child.required(11)!="completed" || child.required(12)!=child.required(13) ||
            store.loadCall(id,runId).value().getOrThrow().callId!=child.required(4)){
            throw IllegalStateException("actual root/readview branch Source/Receipt enclosure")}
        requireReadonlyPlan(store.loadPlan(id,runId).value().getOrThrow())
    }

    public func requireGeneratedFilePlan(database: SqliteDatabase, source: AgentValue, summary: AgentValue,
        proposal: AgentValue, code: String): Unit {
        let run=RunId(httpIntentText(source,"run_id"));let root=OperationId(httpIntentText(source,"root_operation_id"))
        let generated=OperationId(httpIntentText(source,"generation_operation_id"));let store=DurableOperationStore(database)
        let parent=store.loadPlan(root,run).value().getOrThrow();let child=store.loadPlan(generated,run).value().getOrThrow()
        let frozen=parent.canonicalArguments.field("host_plan").getOrThrow()
        if(httpIntentText(source,"kind")!="plugin" || root.value==generated.value || parent.toolName!=name ||
            httpIntentText(source,"plugin_namespace")!=supportRegistryDescriptor96(program,"namespace") ||
            httpIntentText(source,"package_digest")!=supportRegistryDescriptor96(program,"content_digest") ||
            httpIntentText(source,"plugin_version")!=supportRegistryDescriptor96(program,"version") ||
            httpIntentText(source,"contribution")!=parent.toolName ||
            httpIntentText(source,"instance_generation")!=httpIntentText(frozen,"generation") ||
            parent.canonicalArguments.field("input").getOrThrow().field("code").getOrThrow().text!=code ||
            child.toolName!="host.file.plan.propose" || !readonlyDelegationFilePlanProposalAllowed(parent,child) ||
            canonicalAgentValue(child.canonicalArguments.field("proposal").getOrThrow())!=canonicalAgentValue(proposal)){
            throw IllegalStateException("actual frozen Native parent/code/proposal identity")}
        let rows=database.query("SELECT a.parent_operation_id,a.root_operation_id,a.depth,a.child_call_id,a.request_key,a.request_digest,"+
            "o.state,e.tool_id,e.reserved_receipt_id,r.id,r.outcome,o.normalized_plan,e.normalized_plan,r.detail "+
            "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN operation_receipts r ON r.operation_id=o.id WHERE a.operation_id=? AND o.run_id=?",
            [SqlParameter.Text(generated.value),SqlParameter.Text(run.value)])
        if(rows.size!=1){throw IllegalStateException("actual generation Receipt required")}
        let row=rows[0]
        if(row.required(0)!=root.value || row.required(1)!=root.value || row.required(2)!="1" || row.required(3)=="" ||
            row.required(4)=="" || row.required(5)!=child.bindingDigest || row.required(6)!="committed" ||
            row.required(7)!="host.file.plan.propose" || row.required(8)!=row.required(9) || row.required(10)!="completed" ||
            row.required(11)!=row.required(12) || store.loadCall(generated,run).value().getOrThrow().callId!=row.required(3)){
            throw IllegalStateException("actual generation Source/Root/Receipt enclosure")}
        let observed=parseUnifiedJson(row.required(13),maxBytes:1048576).field("output").getOrThrow()
        if(canonicalAgentValue(observed)!=canonicalAgentValue(summary)){
            throw IllegalStateException("proposal summary must equal the actual completed generation result")}
    }

    public func readonlyCapabilityAllowed(plan: NormalizedOperationPlan, capability: Capability): Bool {
        if(capability.kind==CapabilityKind.WorkspaceRead){return true}
        if(capability.kind!=CapabilityKind.ExtensionInvoke || capability.resource==""){return false}
        let readonlyNames=[name,workspaceName("read"),workspaceName("grep"),workspaceName("glob")]
        if(!readonlyNames.contains(plan.toolName)){return false}
        capability.resource==plan.toolName || (plan.toolName==name &&
            [workspaceName("read"),workspaceName("grep"),workspaceName("glob")].contains(capability.resource))
    }

    private func requireReadonlyPlan(plan: NormalizedOperationPlan): Unit {
        var hasRead=false
        for(capability in plan.requiredCapabilities){
            if(capability.kind==CapabilityKind.WorkspaceRead){hasRead=true}
            else if(!readonlyCapabilityAllowed(plan,capability)){throw IllegalStateException("readonly branch exceeds its actual QName scope")}}
        if(!hasRead || plan.effectClass!=OperationEffectClass.ReadOnly || plan.networkPolicy.mode!=NetworkPolicyMode.Denied){
            throw IllegalStateException("actual readonly plan and denied network required")}
    }
}

// The existing fixture-only SQL monitor observes actual rows and writes none.
// It gates the second business admission before COMMIT, after the first real
// business/readview branch has its durable completed Receipt.
public class NativeProgramAdmissionCancellationGate {
    private let lock=Mutex()
    private let threadId: String
    private var toolName=""
    private var runId=""
    private var firstOperation=""
    private var secondOperation=""
    private var entered=false
    private var released=false
    private var cancelled=false
    private var observerExecutions: Int64=0

    public init(threadId: String){this.threadId=threadId}
    public func selectActualRead(name: String): Unit {
        lock.lock();try{toolName=name}finally{lock.unlock()}
    }
    public func observe(transaction: SqliteTransaction): Unit {
        lock.lock()
        let selected=try{if(entered){""}else{toolName}}finally{lock.unlock()}
        if(selected==""){return}
        let rows=transaction.query("SELECT second.run_id,first.id,second.id,a.parent_operation_id,a.child_call_id,"+
            "a.request_key,a.request_digest,a.root_operation_id,e.reserved_receipt_id,e.reserved_result_item_id "+
            "FROM derived_operation_admissions a JOIN operations second ON second.id=a.operation_id "+
            "JOIN runs r ON r.id=second.run_id JOIN operation_effect_records e ON e.operation_id=second.id "+
            "JOIN derived_operation_admissions prior ON prior.parent_operation_id=a.parent_operation_id "+
            "AND prior.depth=1 AND prior.call_sequence=1 JOIN operations first ON first.id=prior.operation_id "+
            "JOIN operation_effect_records first_effect ON first_effect.operation_id=first.id "+
            "JOIN operation_receipts receipt ON receipt.operation_id=first.id "+
            "WHERE r.thread_id=? AND a.depth=1 AND a.call_sequence=2 AND second.state='prepared' "+
            "AND e.tool_id=? AND first.state='committed' AND receipt.outcome='completed' "+
            "AND first_effect.reserved_receipt_id=receipt.id AND first_effect.tool_id=? "+
            "AND a.root_operation_id=a.parent_operation_id AND second.normalized_plan=e.normalized_plan",
            [SqlParameter.Text(threadId),SqlParameter.Text(selected),SqlParameter.Text(selected)])
        if(rows.size!=1){return}
        let row=rows[0]
        if(row.required(4)=="" || row.required(5)=="" || row.required(6).size!=64 ||
            row.required(8)=="" || row.required(9)==""){throw IllegalStateException("actual second child reservation required")}
        lock.lock()
        try{if(entered){return};runId=row.required(0);firstOperation=row.required(1)
            secondOperation=row.required(2);entered=true}finally{lock.unlock()}
        while(true){
            lock.lock();let finished=try{released}finally{lock.unlock()}
            if(finished){return};sleep(Duration.millisecond)}
    }
    public func secondCallEntered(): Bool {lock.lock();try{entered}finally{lock.unlock()}}
    public func firstCompletedAtBoundary(): Bool {
        lock.lock();try{entered && firstOperation!="" && firstOperation!=secondOperation}finally{lock.unlock()}}
    public func observeCancellation(actual: RunId): Unit {
        lock.lock();try{if(entered && actual.value==runId){cancelled=true;released=true}}finally{lock.unlock()}}
    public func cancellationWasReceived(): Bool {lock.lock();try{cancelled}finally{lock.unlock()}}
    public func releaseForTest(): Unit {lock.lock();try{released=true}finally{lock.unlock()}}
    public func countUnexpectedExecution(): Unit {lock.lock();try{observerExecutions+=1}finally{lock.unlock()}}
    public func unexpectedExecutions(): Int64 {lock.lock();try{observerExecutions}finally{lock.unlock()}}
}

// Passive observer of the original catalog cancellation broadcast. It is
// control-only, executes no business call, and returns no fake ToolResult.
public class NativeProgramCancellationObserver <: ToolExecutor {
    private let gate: NativeProgramAdmissionCancellationGate
    public init(gate: NativeProgramAdmissionCancellationGate){this.gate=gate}
    public func execute(context: ToolInvocationContext,prepared: PreparedToolInvocation): Result<ToolResult> {
        gate.countUnexpectedExecution()
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"fixture.cancel_observer_invoked","passive cancellation fixture is not an invocation"))
    }
    public func cancel(runId: RunId): Result<Unit> {gate.observeCancellation(runId);Result.Ok(())}
}

// Real filesystem fault after an actual Native read, using only the existing
// fixture monitor. It never writes SQL state, a fake Receipt or a Tool result.
public class NativeProgramPlanArtifactFault {
    private let lock=Mutex()
    private let threadId: String
    private let path: String
    private var toolName=""
    private var applied=false
    public init(threadId: String,path: String){this.threadId=threadId;this.path=path}
    public func selectActualRead(name: String): Unit {lock.lock();try{toolName=name}finally{lock.unlock()}}
    public func observe(transaction: SqliteTransaction): Unit {
        lock.lock();let selected=try{if(applied){""}else{toolName}}finally{lock.unlock()}
        if(selected==""){return}
        let rows=transaction.query("SELECT o.id FROM operations o JOIN runs r ON r.id=o.run_id "+
            "JOIN derived_operation_admissions a ON a.operation_id=o.id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN operation_receipts receipt ON receipt.operation_id=o.id WHERE r.thread_id=? AND a.depth=1 AND a.call_sequence=1 "+
            "AND e.tool_id=? AND o.state='committed' AND receipt.outcome='completed' AND e.reserved_receipt_id=receipt.id",
            [SqlParameter.Text(threadId),SqlParameter.Text(selected)])
        if(rows.size!=1){return}
        lock.lock();try{if(applied){return};applied=true}finally{lock.unlock()}
        if(exists(Path(path))){remove(path,recursive:true)}
        File.writeTo(path,"artifact store unavailable".toArray())
    }
    public func wasApplied(): Bool {lock.lock();try{applied}finally{lock.unlock()}}
    public func restore(): Unit {
        if(exists(Path(path)) && FileInfo(Path(path)).isRegular()){remove(path);Directory.create(path,recursive:true)}
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
