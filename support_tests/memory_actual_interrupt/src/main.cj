package memory_actual_interrupt
import std.sync.*

import agent_domain.*
import agent_product.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.time.*
import yjson.*
import yjson_support.*

func requireFixture(value:Bool,message:String):Unit{if(!value){throw IllegalStateException(message)}}
func opened<T>(value:Result<T>):T{match(value){case Result.Ok(item)=>item;case Result.Err(error)=>throw IllegalStateException(error.code+": "+error.message)}}
func completed(value:Result<ToolInvocationResult>):ToolResult{
    match(opened(value)){case ToolInvocationResult.Completed(item)=>
        requireFixture(!item.isError,"actual Native result is an error");item
        case _=>throw IllegalStateException("actual Native call did not complete")}
}
func capabilities():CapabilitySet{CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),
    Capability(CapabilityKind.WorkspaceWrite),Capability(CapabilityKind.ExtensionInvoke)])}
func configure(product:ProductRuntime,root:String):ProductPluginRecord{
    let record=match(product.importLocalPlugin(getVariable("AXYNDRA_MEMORY_PLUGIN_PACKAGE").getOrThrow())){
        case PluginRegistryResult.Ok(value)=>supportRegistryRecord96(value);case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
    let tools=ArrayList<AgentValue>()
    for(name in ["retain","recall","reflect","memory_edit","learn","manage_skill","memory_context"]){
        tools.add(objectValue([ValueField("name",textValue(name)),ValueField("documents",listValue([
            objectValue([ValueField("key",textValue("journal")),ValueField("read",boolValue(true)),ValueField("write",boolValue(true))])])),
            ValueField("preparation_provider",textValue("prepare_window_document")),ValueField("payload_references",boolValue(true)),ValueField("read_windows",boolValue(true)),
            ValueField("effect_from_intents",boolValue(true)),ValueField("tool_payload_limits",OrdinaryToolPayloadLimits(name).value())]))}
    Directory.create(root+"/settings/plugins",recursive:true)
    File.writeTo(root+"/settings/plugins/documents.json",stringifyUnifiedJson(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(supportRegistryDescriptor96(record,"namespace"))),ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),
            ValueField("tools",listValue(tools.toArray())),ValueField("backends",listValue([objectValue([
                ValueField("key",textValue("journal")),ValueField("layout",textValue("opaque-fact-events-v3"))])]))])]))])).toArray())
    match(product.setPluginEnabled(supportRegistryDescriptor96(record,"namespace"),true)){
        case PluginRegistryResult.Ok(discard96)=>supportRegistryDiscard96(discard96);case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorCode96(error))}
    record
}
func actualCall(product:ProductRuntime,namespace:String,thread:String,name:String,input:AgentValue):ToolResult{
    completed(product.vnext.executeCanonicalTool(SessionId(thread),capabilities(),ToolCall("actual-memory-"+name,
        "plugin."+namespace+"."+name,input),budget:ExecutionBudget(maxToolCalls:10,maxConcurrentTools:1)))
}
main():Int64{
    let root=getVariable("AXYNDRA_MEMORY_INTERRUPT_ROOT").getOrThrow()
    let action=getVariable("AXYNDRA_MEMORY_INTERRUPT_ACTION").getOrThrow()
    let statePath=root+"/fixture-identity.json"
    let state=if(action=="seed"){objectValue([])}else{parseUnifiedJson(String.fromUtf8(File.readFrom(statePath)))}
    let monitor:?(SqliteTransaction)->Unit=if(action=="interrupt"){Some({tx=>
        // The barrier is reached only after this actual Derived settlement
        // wrote both original events, both rows and its Completed Receipt.
        // The observer neither writes SQL nor alters Source/admission/plan.
        let count=tx.query("SELECT COUNT(*) FROM memory_events")[0].required(0)
        let changed=tx.query("SELECT revision FROM memories WHERE id=?",[SqlParameter.Text(httpIntentText(state,"id"))])
        if(count=="3" && changed.size==1 && changed[0].required(0)=="2"){
            let receipt=tx.query("SELECT r.id,r.operation_id,o.state FROM operation_receipts r "+
                "JOIN operations o ON o.id=r.operation_id JOIN derived_operation_admissions a ON a.operation_id=o.id "+
                "WHERE r.outcome='completed' AND o.run_id IN (SELECT id FROM runs WHERE thread_id='memory-interrupted')")
            if(receipt.size==1){
                File.writeTo(root+"/before-commit-barrier.json",stringifyUnifiedJson(objectValue([
                    ValueField("schema",textValue("axyndra.actual-transaction-barrier-fixture/v1")),
                    ValueField("event_count",integerValue(3)),ValueField("row_revision",integerValue(2)),
                    ValueField("receipt_id",textValue(receipt[0].required(0))),ValueField("operation_id",textValue(receipt[0].required(1))),
                    ValueField("operation_state",textValue(receipt[0].required(2)))])).toArray())
                while(true){sleep(Duration.millisecond*10)}
            }
        }
    })}else{None}
    let product=opened(openProduct(config:ProductConfig(workspaceRoot:root,settingsRoot:root+"/settings",stateRoot:root+"/state",
        fixture:true,approvalMode:ApprovalMode.Yolo,fixtureTransactionCommitMonitor:monitor)))
    try{
        if(action=="seed"){
            let record=configure(product,root)
            let result=actualCall(product,supportRegistryDescriptor96(record,"namespace"),"memory-seed","retain",objectValue([
                ValueField("items",listValue([objectValue([ValueField("content",textValue("original before actual transaction interruption")),
                    ValueField("kind",textValue("preference")),ValueField("scope",textValue("workspace"))])]))]))
            File.writeTo(statePath,stringifyUnifiedJson(objectValue([ValueField("id",result.output.field("ids").getOrThrow().items[0]),
                ValueField("namespace",textValue(supportRegistryDescriptor96(record,"namespace"))),ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest")))])).toArray())
        }else if(action=="interrupt" || action=="retry"){
            let result=actualCall(product,httpIntentText(state,"namespace"),if(action=="interrupt"){"memory-interrupted"}else{"memory-retry"},
                "memory_edit",objectValue([ValueField("op",textValue("correct")),ValueField("id",state.field("id").getOrThrow()),
                    ValueField("content",textValue("actual retry replacement"))]))
            requireFixture(action=="retry","actual interruption missed its precommit barrier")
            requireFixture(result.output.unifiedKind==ValueKind.Object,"actual retry did not return its frozen result")
        }else{throw IllegalArgumentException("unknown actual interrupt fixture action")}
        println("actual Product Native fixture action completed: "+action)
        0
    }finally{let _=product.close()}
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
