package shell_readonly_native_contract
import std.sync.*

import agent_domain.*
import agent_extension_runtime.{PluginEntryKind}
import agent_product.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

// Actual public import/enable and operator recipe. This fixture is descriptive
// composition only; it cannot admit, hand off, approve or resolve operations.
public class NativeReadonlyShellContractBinding {
    public let product: ProductRuntime
    public let record: ProductPluginRecord
    public init(product: ProductRuntime) {
        this.product=product
        let installed=match(product.importLocalPlugin(getVariable("AXYNDRA_SHELL_READONLY_PLUGIN_PACKAGE").getOrThrow(),PluginInstallScope.Workspace)){
            case PluginRegistryResult.Ok(value)=>supportRegistryRecord96(value)
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        if(supportRegistryDescriptor96(installed,"namespace")!="axyndra:shell-readonly" || installed.descriptor.entryKind!=PluginEntryKind.NativeExecutable){
            throw IllegalStateException("actual independent Native readonly Shell package required")}
        this.record=installed
        configure()
        match(product.setPluginEnabled(supportRegistryDescriptor96(installed,"namespace"),true,PluginInstallScope.Workspace)){
            case PluginRegistryResult.Ok(discard96)=>supportRegistryDiscard96(discard96)
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
        if(product.vnext.javascriptPlugins.instanceGeneration(supportRegistryDescriptor96(record,"namespace"))==0u64 ||
            !product.vnext.javascriptPlugins.toolNames(supportRegistryDescriptor96(record,"namespace")).contains("exec")){
            throw IllegalStateException("actual installed ready readonly contribution required")}
    }
    public prop namespace: String {get(){supportRegistryDescriptor96(record,"namespace")}}
    public prop name: String {get(){"plugin."+supportRegistryDescriptor96(record,"namespace")+".exec"}}
    public func configure(): Unit {
        let directory=product.settingsRoot+"/plugins"
        if(!exists(Path(directory))){Directory.create(directory,recursive:true)}
        let path=directory+"/services.json";let entries=ArrayList<AgentValue>()
        if(exists(Path(path))){
            let previous=parseUnifiedJson(String.fromUtf8(File.readFrom(path)),maxBytes:1048576)
            if(previous.field("version").getOrThrow().asNumberText()!="1" || previous.field("plugins").getOrThrow().unifiedKind!=ValueKind.List){
                throw IllegalStateException("actual operator fixture configuration required")}
            for(entry in previous.field("plugins").getOrThrow().items where httpIntentText(entry,"namespace")!=supportRegistryDescriptor96(record,"namespace")){entries.add(entry)}
        }
        let grant=objectValue([ValueField("kind",textValue("tool")),ValueField("name",textValue("exec")),
            ValueField("effect",textValue("read_only")),ValueField("services",listValue([textValue("process.readview")]))])
        entries.add(objectValue([ValueField("namespace",textValue(supportRegistryDescriptor96(record,"namespace"))),
            ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),ValueField("configuration",objectValue([])),
            ValueField("requests",listValue([])),ValueField("credentials",listValue([])),ValueField("tool_read_grants",listValue([grant])),
            ValueField("read_view_parameter_references",listValue([textValue("exec")])),ValueField("read_view_parameter_contexts",listValue([textValue("exec")])),
            ValueField("tool_payload_limits",listValue([OrdinaryToolPayloadLimits("exec",maxInputBytes:229376,
                maxResultBytes:1048576,maxServiceResponseBytes:262144,maxMessageBytes:1056768).value()])),
            ValueField("read_view_deadlines",listValue([objectValue([ValueField("contribution",textValue("exec")),ValueField("maximum_ms",integerValue(600000))])])),
            ValueField("protocol_limits",objectValue([ValueField("max_frame_bytes",integerValue(524288)),ValueField("max_input_bytes",integerValue(16384)),
                ValueField("max_prepare_bytes",integerValue(131072)),ValueField("max_result_bytes",integerValue(262144)),
                ValueField("max_directory_bytes",integerValue(65536)),ValueField("max_tools",integerValue(64)),ValueField("call_timeout_ms",integerValue(600000))]))]))
        File.writeTo(path,stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue(entries.toArray()))])).toArray())
        File.writeTo(directory+"/shell-readonly-tools.json",stringifyUnifiedJson(objectValue([
            ValueField("schema",textValue("axyndra.shell-readonly-tools/v1")),ValueField("namespace",textValue(supportRegistryDescriptor96(record,"namespace"))),
            ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest")))])).toArray())
    }

    // Observe every actual edge and reserved Receipt after real execution.
    // This does not manufacture SQL state or turn loaded data into a Source.
    public func requireCompletedBrokerTree(database: SqliteDatabase, run: RunId, rootId: String): Unit {
        let store=DurableOperationStore(database)
        let rootReceipt=database.query("SELECT e.reserved_receipt_id,r.id,r.outcome,o.normalized_plan,e.normalized_plan FROM operations o "+
            "JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id "+
            "WHERE o.id=? AND o.run_id=?",[SqlParameter.Text(rootId),SqlParameter.Text(run.value)])
        if(rootReceipt.size!=1 || rootReceipt[0].required(0)!=rootReceipt[0].required(1) || rootReceipt[0].required(2)!="completed" ||
            rootReceipt[0].required(3)!=rootReceipt[0].required(4)){throw IllegalStateException("actual outer Root/Receipt/current frozen plan")}
        let business=database.query("SELECT a.operation_id,a.root_operation_id,a.depth,a.call_sequence,a.child_call_id,a.request_key,a.request_digest,"+
            "o.state,e.tool_id,e.reserved_receipt_id,r.id,r.outcome,o.normalized_plan,e.normalized_plan "+
            "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN operation_receipts r ON r.operation_id=o.id WHERE a.parent_operation_id=? AND o.run_id=?",
            [SqlParameter.Text(rootId),SqlParameter.Text(run.value)])
        if(business.size!=1){throw IllegalStateException("actual readonly Native child inventory")}
        let child=business[0];let childId=OperationId(child.required(0))
        if(child.required(1)!=rootId || child.required(2)!="1" || child.required(3)!="1" || child.required(4)=="" ||
            !child.required(5).startsWith("javascript-service:") || child.required(6).size!=64 || child.required(7)!="committed" ||
            child.required(8)!=name || child.required(9)!=child.required(10) || child.required(11)!="completed" ||
            child.required(12)!=child.required(13) || store.loadCall(childId,run).value().getOrThrow().callId!=child.required(4)){
            throw IllegalStateException("actual readonly Native Source/call/Root/Receipt binding")}
        let parent=store.loadPlan(childId,run).value().getOrThrow()
        if(!isReadonlyDelegatedChildPlan(parent)){throw IllegalStateException("actual Native ReadOnly/Denied resource parent")}
        let worker=database.query("SELECT a.operation_id,a.root_operation_id,a.depth,a.call_sequence,a.child_call_id,a.request_key,a.request_digest,"+
            "o.state,e.tool_id,e.reserved_receipt_id,r.id,r.outcome,o.normalized_plan,e.normalized_plan "+
            "FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN operation_receipts r ON r.operation_id=o.id WHERE a.parent_operation_id=? AND o.run_id=?",
            [SqlParameter.Text(childId.value),SqlParameter.Text(run.value)])
        if(worker.size!=1){throw IllegalStateException("actual worker child inventory")}
        let leaf=worker[0];let leafId=OperationId(leaf.required(0))
        if(leaf.required(1)!=rootId || leaf.required(2)!="2" || leaf.required(3)!="1" || leaf.required(4)=="" ||
            !leaf.required(5).startsWith("javascript-service:") || leaf.required(6).size!=64 || leaf.required(7)!="committed" ||
            leaf.required(8)!=HOST_READ_VIEW_TOOL || leaf.required(9)!=leaf.required(10) || leaf.required(11)!="completed" ||
            leaf.required(12)!=leaf.required(13) || store.loadCall(leafId,run).value().getOrThrow().callId!=leaf.required(4)){
            throw IllegalStateException("actual Host worker Derived Source/call/Root/Receipt binding")}
        let plan=store.loadPlan(leafId,run).value().getOrThrow()
        if(!readViewServiceChildAllowed(parent,plan)){
            throw IllegalStateException("actual worker exact ParentIntent and unchanged permission intersection")}
        let rootPlan=store.loadPlan(OperationId(rootId),run).value().getOrThrow()
        let ceiling=CapabilitySet(values:rootPlan.requiredCapabilities)
        for(cap in parent.requiredCapabilities where !ceiling.allows(cap.kind,resource:cap.resource)){
            throw IllegalStateException("actual readonly child exceeds original parent frozen ceiling")}
        if(database.scalarInt("SELECT COUNT(*) FROM operations WHERE run_id=?",[SqlParameter.Text(run.value)])!=3 ||
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operations o ON o.id=r.operation_id WHERE o.run_id=?",[SqlParameter.Text(run.value)])!=3){
            throw IllegalStateException("three actual canonical operations and reserved Receipts, without fabricated business alias")}
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
            case PluginRegistryStaticReason.None=>supportRegistryText96(error.copyText(PluginRegistryErrorText.Message))}
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
