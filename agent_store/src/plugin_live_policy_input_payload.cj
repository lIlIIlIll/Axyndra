package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Data retention only. Neither this encoder nor the GC pin mints a Source,
// approval, child admission, address grant, callback or effect permission.
let LIVE_POLICY_INPUT_PIN_KIND="plugin_live_policy_input_payload_prepared"
let LIVE_POLICY_INPUT_PIN_SCHEMA="axyndra.plugin-live-policy-input-payload-prepared/v1"

// Exact UTF-8 output extent of the pinned c91859... writer. String bytes are
// inspected in place, including every object name. No escaped copy is made.
// The concrete array/object checks and non-open scalar getters mirror yjson;
// custom nodes and invalid numbers still reach the ORIGINAL whole writer.
private class LivePolicyInputJsonExtent {
    let options:JsonWriteOptions
    let owner:LogicalJsonOwnerReservation
    let ancestors=ArrayList<JsonNode>()
    var bytes:Int64=0
    var nodes:Int64=0
    init(options:JsonWriteOptions,owner:LogicalJsonOwnerReservation){this.options=options;this.owner=owner}
    func add(amount:Int64):Unit{bytes=journalStreamAdd(bytes,amount)}
    func stringBytes(value:String):Unit{
        add(2)
        unsafe{
            let raw=value.rawData()
            for(index in 0..raw.size){
                let byte=Int64(raw[index])
                if(byte==34 || byte==92 || byte==8 || byte==9 || byte==10 || byte==12 || byte==13){add(2)}
                else if(byte<32 || (options.htmlSafe && (byte==38 || byte==39 || byte==60 || byte==61 || byte==62))){add(6)}
                else{add(1)}
            }
        }
    }
    func enter(value:JsonNode):Bool{
        for(ancestor in ancestors){if(refEq(value,ancestor)){return false}}
        if(ancestors.size>=options.maxDepth){return false}
        ancestors.add(value);true
    }
    func entryPrefix(depth:Int64):Unit{
        if(!options.indent.isEmpty()){
            if(depth>Int64.Max/options.indent.size){throw IllegalStateException("JSON indentation extent overflow")}
            add(journalStreamAdd(1,depth*options.indent.size))}
    }
    func scalarBytes(value:JsonNode):Bool{
        // Scalar formatting and its original errors occur only after payment.
        // Numeric literal text is already retained by the caller. Formatting
        // built-in integers/floats and unknown-type errors fit the fixed floor.
        owner.ensureRetainedPeak(1048576)
        let numeric:?String=try{Some(value.asNumberText())}catch(_:JsonException){None<String>}
        // Capacity failures must propagate; they are never a serialization
        // fallback that could retry the same bytes without their payment.
        match(numeric){case Some(text)=>owner.ensureRetainedPeak(contextReadMetadataRawPeak(text.size));case None=>()}
        try{
            let encoded=value.toJson(options:options)
            add(encoded.size);true
        }catch(_:JsonException){false}
    }
    func visit(value:JsonNode):Bool{
        nodes=journalStreamAdd(nodes,1)
        match(value){
            case array:JsonArray=>
                if(!enter(array)){return false}
                try{
                    add(2)
                    for(index in 0..array.size()){
                        if(index!=0){add(1)};entryPrefix(ancestors.size)
                        if(!visit(array.get(index).getOrThrow())){return false}}
                    if(array.size()!=0){entryPrefix(ancestors.size-1)}
                    true
                }finally{ancestors.remove(at:ancestors.size-1)}
            case object:JsonObject=>
                if(!enter(object)){return false}
                try{
                    add(2)
                    for(index in 0..object.size()){
                        if(index!=0){add(1)};entryPrefix(ancestors.size)
                        stringBytes(object.nameAt(index));add(1)
                        if(!options.indent.isEmpty()){add(1)}
                        if(!visit(object.valueAt(index))){return false}}
                    if(object.size()!=0){entryPrefix(ancestors.size-1)}
                    true
                }finally{ancestors.remove(at:ancestors.size-1)}
            case _=>
                let text:?String=try{Some(value.asString())}catch(_:JsonException){None<String>}
                match(text){case Some(actual)=>stringBytes(actual);true;case None=>scalarBytes(value)}
        }
    }
}

private func livePolicyInputEncodeOwned(input:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    // Freeze the real writer before examining any node, as its original call
    // does. The immutable defaults are read rather than assumed by a shortcut.
    let _=JsonNode.nullValue.toJson()
    let fields=match(input as JsonObject){case Some(value)=>value.size();case None=>0}
    if(fields>Int64.Max/2048){throw IllegalStateException("business projection wrapper payment overflow")}
    let wrapperPeak=journalStreamAdd(1048576,fields*2048)
    owner.ensureRetainedPeak(wrapperPeak)
    let business=contextReadBusinessInput(input)
    let extent=LivePolicyInputJsonExtent(JsonWriteOptions.defaults,owner)
    let exact=extent.visit(business)
    owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),fields*2048))
    // On unsupported nodes, cycles, depth or numeric errors this call throws
    // the original whole-writer error. A successfully measured value keeps
    // the original six-field payload reference's 8 MiB content limit.
    if(exact && extent.bytes>PLUGIN_DOCUMENT_MAX_BYTES){throw IllegalStateException("input payload exceeds its original document bound")}
    let encoded=encodeAgentValue(business)
    if(!exact || encoded.size!=extent.bytes){throw IllegalStateException("original input JSON extent changed")}
    if(encoded.size>PLUGIN_DOCUMENT_MAX_BYTES){throw IllegalStateException("input payload exceeds its original document bound")}
    journalStreamCheck(guard);consume(encoded);journalStreamCheck(guard)
}

// The trusted callback consumes the complete original business input while
// its SAME aggregate owner is live. It returns Unit and retains no raw bytes.
// Host private writers may synchronously copy paid 16 KiB slices and finish;
// pin/SQL validation follows after this function returns and releases copies.
public func withPluginLivePolicyInputPayloadEncoding(input:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    let owner=allocate(65536)
    try{livePolicyInputEncodeOwned(input,owner,guard,consume)}finally{owner.close()}
}

private func livePolicyInputStructureOwned(arguments:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):Unit{
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    let extent=livePolicyStoredExtent(arguments)
    if(extent.bytes>8388608){throw IllegalStateException("input preparation exceeds its original durable codec")}
    if(extent.nodes>Int64.Max/512){throw IllegalStateException("input structure payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(1048576,extent.nodes*512))
    if(!pluginLivePolicyParentValueValid(arguments)){throw IllegalStateException("input pin requires the exact closed parent shape")}
    let host=arguments.field("host_plan").getOrThrow()
    let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
    if(links.size!=1){throw IllegalStateException("input pin requires its sole actual Tool12 read")}
    let input=arguments.field("input").getOrThrow()
    match(input.field(CONTEXT_READ_INPUT_FIELD)){
        case Some(projection)=>
            let data=projection.field("data")??projection
            let count=LivePolicyInputJsonExtent(JsonWriteOptions.defaults,owner)
            let exact=count.visit(data)
            owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(count.bytes,count.nodes),extent.nodes*512))
            if(!exact){let _=encodeAgentValue(data);throw IllegalStateException("input projection has unsupported original JSON")}
        case None=>()
    }
    journalStreamCheck({=>validateContextReadInputProjection(input,links)})
    journalStreamCheck(guard)
}
private func livePolicyInputRequireStructure(arguments:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let owner=allocate(65536)
    try{livePolicyInputStructureOwned(arguments,owner,guard)}finally{owner.close()}
}

private func livePolicyInputStoredDigestOwned(arguments:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):String{
    owner.ensureRetainedPeak(1048576)
    let extent=livePolicyStoredExtent(arguments)
    if(extent.bytes>8388608){throw IllegalStateException("input preparation exceeds its original durable codec")}
    owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
    journalStreamCheck(guard)
    let encoded=encodeStoredValue(arguments)
    if(encoded.size!=extent.bytes){throw IllegalStateException("input preparation framing extent changed")}
    let meter=StoredValuePaymentMeter(encoded,owner);let _=meter.complete()
    let digest=modelPolicySha256Text(encoded);journalStreamCheck(guard);digest
}
private func livePolicyInputStoredDigest(arguments:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):String{
    let owner=allocate(65536)
    // Only the bounded 64-byte hash survives this phase. The caller's metadata
    // owner prepays it; every encoder/UTF-8 array and meter leaves the frame.
    try{livePolicyInputStoredDigestOwned(arguments,owner,guard)}finally{owner.close()}
}
private func livePolicyInputBindingDigestOwned(binding:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):String{
    owner.ensureRetainedPeak(1048576)
    let extent=livePolicyStoredExtent(binding)
    owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
    journalStreamCheck(guard);let digest=modelPolicySha256Text(canonicalAgentValue(binding))
    journalStreamCheck(guard);digest
}
private func livePolicyInputBindingDigest(binding:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):String{
    let owner=allocate(65536)
    try{livePolicyInputBindingDigestOwned(binding,owner,guard)}finally{owner.close()}
}

private class LivePolicyInputParentData {
    var parent:String=""
    var run:String=""
    var item:String=""
    var fact:?AgentValue=None
    var request:?AgentValue=None
    init(){}
}

private func livePolicyInputReadProjectionOwned(input:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):Unit{
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    let extent=livePolicyStoredExtent(input)
    if(extent.bytes>8388608 || extent.nodes>Int64.Max/512){throw IllegalStateException("input binding data exceeds its original durable codec")}
    owner.ensureRetainedPeak(journalStreamAdd(1048576,extent.nodes*512))
    let envelope=input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
    let rawLinks=envelope.field("facts").getOrThrow()
    if(rawLinks.unifiedKind!=ValueKind.List || rawLinks.asArray().size()!=1){throw IllegalStateException("input binding data requires its sole actual fact")}
    let links=contextReadFactLinksFromValue(rawLinks)
    let counter=LivePolicyInputJsonExtent(JsonWriteOptions.defaults,owner)
    let exact=counter.visit(envelope.field("data").getOrThrow())
    owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(counter.bytes,counter.nodes),extent.nodes*512))
    if(!exact){let _=encodeAgentValue(envelope.field("data").getOrThrow());throw IllegalStateException("input binding projection has unsupported original JSON")}
    journalStreamCheck({=>validateContextReadInputProjection(input,links)});journalStreamCheck(guard)
}
private func livePolicyInputRequireReadProjection(input:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let owner=allocate(65536)
    try{livePolicyInputReadProjectionOwned(input,owner,guard)}finally{owner.close()}
}
private func livePolicyInputReadOriginalRequest(tx:SqliteTransaction,parentTool:String,input:AgentValue,
    links:Array<ContextReadFactLink>,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    data:LivePolicyInputParentData):Unit{
    let payment=ContextReadCompletedMetadataPayment(tx,links[0],allocate,guard)
    try{
        let read=payment.plan();let request=read.canonicalArguments;let binding=request.field("binding").getOrThrow()
        if(!pluginDocumentLatestJournalStreamReadAuthority(read) || pluginDocumentContextLatestJournalStreamReadAuthority(read) ||
            httpIntentText(binding,"contribution")!=parentTool){throw IllegalStateException("input data has no original bounded Tool12 read request")}
        let fact=payment.fact()
        if(!livePolicyInputSameValue(fact.reference(),links[0].toValue(),0) ||
            !pluginDocumentLatestJournalStreamReadResultValid(fact.output(),request) ||
            fact.runId.value!=httpIntentText(binding,"run_id") || fact.origin.parentCallItemId=="" ||
            fact.origin.ownerNamespace!=httpIntentText(binding,"namespace") || fact.origin.packageDigest!=httpIntentText(binding,"package_digest") ||
            fact.origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
            fact.origin.projectionDigest!=httpIntentText(request,"projection_digest")){
            throw IllegalStateException("input data changed its complete original read request/fact")}
        let projected=input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow();let projectedData=projected.field("data").getOrThrow()
        let actualOutput=if(httpIntentText(projected,"schema")==CONTEXT_READ_SEQUENCE_INPUT_SCHEMA){projectedData.asArray().get(0).getOrThrow()}else{projectedData}
        if(!livePolicyInputSameValue(actualOutput,fact.output(),0)){throw IllegalStateException("input projection differs from its complete actual read output")}
        data.parent=documentPayloadParentOperation(fact).value;data.run=fact.runId.value;data.item=fact.origin.parentCallItemId
        // Only this original <=16 KiB six-field request and the small fixed
        // fact reference survive into the caller's already-paid metadata owner.
        data.request=Some(request);data.fact=Some(fact.reference());journalStreamCheck(guard)
    }finally{payment.close()}
}
private func livePolicyInputReadWaitingPinOwned(tx:SqliteTransaction,parentTool:String,input:AgentValue,
    binding:AgentValue,links:Array<ContextReadFactLink>,data:LivePolicyInputParentData,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let parent=OperationId(data.parent);let run=RunId(data.run);let item=ItemId(data.item)
    livePolicyInputRequireWaitingState(tx,parent,run,item,binding)
    let suffix=" FROM operations WHERE id=? AND run_id=? AND tool_call_item_id=?"
    let parameters=[SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value)]
    let cell=contextReadMetadataMeasure(tx,"normalized_plan",suffix,parameters,allocate,guard)
    let owner=allocate(65536)
    try{
        // One owner pays the original plan DOM AND its temporary argument
        // hash encoding. No second large encoder owner is nested here.
        owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(cell.bytes,cell.nodes),cell.bytes*4))
        journalStreamCheck(guard)
        livePolicyInputReadWaitingPinBody(tx,parentTool,input,binding,links,data,suffix,parameters,cell,allocate,guard,owner)
    }finally{owner.close()}
    // The complete call is a separate phase after the plan/temporary encoder
    // frame has returned. Actual pin reuse remains a separate Host step too.
    livePolicyInputRequireBusinessCall(tx,item,parentTool,input,binding,allocate,guard)
    livePolicyInputRequireWaitingState(tx,parent,run,item,binding);journalStreamCheck(guard)
}
private func livePolicyInputReadWaitingPinBody(tx:SqliteTransaction,parentTool:String,input:AgentValue,
    binding:AgentValue,links:Array<ContextReadFactLink>,data:LivePolicyInputParentData,suffix:String,parameters:Array<SqlParameter>,
    cell:ContextReadMetadataCell,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation):Unit{
    let rows=tx.query("SELECT normalized_plan"+suffix,parameters)
    if(rows.size!=1 || rows[0].required(0).size!=cell.bytes){throw IllegalStateException("waiting plan data extent changed")}
    let raw=rows[0].required(0);let rawMeter=StoredValuePaymentMeter(raw,owner);let rawNodes=rawMeter.complete()
    owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(raw.size,rawNodes),raw.size*4))
    let plan=decodeOperationPlan(raw)
    let parent=OperationId(data.parent);let run=RunId(data.run);let item=ItemId(data.item)
    if(!isPluginLivePolicyParentPlan(plan) || plan.toolName!=parentTool || plan.contextReadFacts.size!=1 ||
        !livePolicyInputSameValue(plan.contextReadFacts[0].toValue(),links[0].toValue(),0) ||
        !livePolicyInputSameValue(plan.canonicalArguments.field("input").getOrThrow(),input,0) ||
        !livePolicyInputSameValue(plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow(),binding,0)){
        throw IllegalStateException("waiting binding data changed its complete actual prepared plan/input")}
    livePolicyInputRequireWaitingPrepared(tx,parent,run,item,binding,links,plan,raw,allocate,guard)
    let argumentsExtent=livePolicyStoredExtent(plan.canonicalArguments)
    let arguments=encodeStoredValue(plan.canonicalArguments)
    if(arguments.size!=argumentsExtent.bytes){throw IllegalStateException("waiting argument framing extent changed")}
    let meter=StoredValuePaymentMeter(arguments,owner);let _=meter.complete()
    let host=plan.canonicalArguments.field("host_plan").getOrThrow()
    let payload=parsePluginDocumentPayloadReference(host.field("input_payload").getOrThrow()).value().getOrThrow()
    let evidence=livePolicyInputPinEvidence(parent,run,item,parentTool,binding,modelPolicySha256Text(arguments),
        modelPolicySha256Text(canonicalAgentValue(binding)),data.fact.getOrThrow(),host.field("input_payload").getOrThrow())
    let encoded=encodeStoredValue(evidence)
    livePolicyInputRequirePin(tx,parent,run,httpIntentText(binding,"thread_id"),encoded)
    livePolicyInputRequireMetadata(tx,payload,guard);journalStreamCheck(guard)
}
private func livePolicyInputReadBindingOwned(tx:SqliteTransaction,parentTool:String,input:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(AgentValue)->Unit,
    owner:LogicalJsonOwnerReservation):Unit{
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    livePolicyInputRequireReadProjection(input,allocate,guard)
    let links=contextReadFactLinksFromValue(input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("facts").getOrThrow())
    let data=LivePolicyInputParentData();livePolicyInputReadOriginalRequest(tx,parentTool,input,links,allocate,guard,data)
    let request=data.request.getOrThrow();let binding=request.field("binding").getOrThrow()
    let waiting=tx.query("SELECT count(*) FROM runs WHERE id=? AND thread_id=? AND epoch=? AND state='waiting_approval' "+
        "AND finished_at_millis IS NULL",[SqlParameter.Text(data.run),SqlParameter.Text(httpIntentText(binding,"thread_id")),
            SqlParameter.Int64Value(journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText()))])
    if(waiting.size!=1){throw IllegalStateException("binding data lost its actual current run")}
    if(waiting[0].required(0)=="1"){
        livePolicyInputReadWaitingPinOwned(tx,parentTool,input,binding,links,data,allocate,guard)
    }else{
        let current=LivePolicyInputParentData();livePolicyInputReadParent(tx,parentTool,binding,links,allocate,guard,current)
        if(current.parent!=data.parent || current.run!=data.run || current.item!=data.item){throw IllegalStateException("read binding data changed its actual parent")}
        livePolicyInputRequireBusinessCall(tx,ItemId(data.item),parentTool,input,binding,allocate,guard)
    }
    journalStreamCheck(guard);consume(request);journalStreamCheck(guard)
}
// Bounded original read-request DATA only (six fields, including binding12,
// key/projection/access/view digests, original <=16384 JSON bytes). The Host
// copies this small descriptor under its existing 16 MiB metadata owner, then
// checks actual current configuration/package/generation and independently
// reuses the pin. No large plan/input/fact DOM, Source or grant may escape.
public func withPluginLivePolicyInputReadBinding(tx:SqliteTransaction,parentTool:String,input:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(AgentValue)->Unit):Unit{
    let owner=allocate(65536)
    try{livePolicyInputReadBindingOwned(tx,parentTool,input,allocate,guard,consume,owner)}finally{owner.close()}
}
private func livePolicyInputReadParent(tx:SqliteTransaction,parentTool:String,binding:AgentValue,
    links:Array<ContextReadFactLink>,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    data:LivePolicyInputParentData):Unit{
    if(links.size!=1 || httpIntentText(binding,"contribution")!=parentTool){
        throw IllegalStateException("input pin changed its original Tool contribution")}
    let payment=ContextReadCompletedMetadataPayment(tx,links[0],allocate,guard)
    try{
        let plan=payment.plan()
        if(!pluginDocumentLatestJournalStreamReadAuthority(plan) || pluginDocumentContextLatestJournalStreamReadAuthority(plan)){
            throw IllegalStateException("input pin cannot use parentless or older read facts")}
        let fact=payment.fact()
        let _=latestJournalInputRequireFact(tx,links[0],binding,fact.output(),payment)
        if(fact.origin.parentCallItemId=="" || fact.runId.value!=httpIntentText(binding,"run_id")){
            throw IllegalStateException("input pin lost its actual completed parent")}
        data.parent=documentPayloadParentOperation(fact).value;data.run=fact.runId.value
        data.item=fact.origin.parentCallItemId;data.fact=Some(fact.reference())
        journalStreamCheck(guard)
    }finally{payment.close()}
}
private func livePolicyInputRequireCall(tx:SqliteTransaction,parent:OperationId,run:RunId,parentItem:ItemId,
    parentTool:String,arguments:AgentValue,binding:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let thread=httpIntentText(binding,"thread_id")
    let epoch=journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText())
    livePolicyRequireOne(tx,"SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id "+
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id JOIN items call "+
        "ON call.id=? AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id "+
        "WHERE r.id=? AND r.thread_id=? AND r.epoch=? AND call.kind='tool_call' AND r.state='running' "+
        "AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active'",
        [SqlParameter.Text(parentItem.value),SqlParameter.Text(run.value),SqlParameter.Text(thread),SqlParameter.Int64Value(epoch)],
        "input retention lost its same actual current run/turn/item")
    if(requirePluginDocumentLane(tx,ThreadId(thread),run,epoch).value!=httpIntentText(binding,"lane_id")){
        throw IllegalStateException("input retention lost its actual current lane")}
    let suffix=" FROM items WHERE id=? AND thread_id=? AND kind='tool_call'"
    withLivePolicyStoredValue(tx,"payload",suffix,[SqlParameter.Text(parentItem.value),SqlParameter.Text(thread)],allocate,guard,{raw=>
        match(decodeStoredThreadContent(raw)){
            case ThreadItemContent.ToolCall(call,name,original)=>
                if(call.value!=httpIntentText(binding,"parent_call_id") || name!=parentTool ||
                    canonicalAgentValue(original)!=canonicalAgentValue(contextReadBusinessInput(arguments.field("input").getOrThrow()))){
                    throw IllegalStateException("input payload differs from its complete original canonical ToolCall")}
            case _=>throw IllegalStateException("input retention requires its complete original ToolCall")
        }
    })
    journalStreamCheck(guard)
}
private func livePolicyInputRequireMetadata(tx:SqliteTransaction,payload:PluginDocumentPayloadReference,
    guard:()->Result<Unit>):Unit{
    let rows=tx.query("SELECT length(CAST(metadata AS BLOB)),length(CAST(mime AS BLOB)),length(CAST(relative_path AS BLOB)),length(CAST(size AS BLOB)) "+
        "FROM artifacts WHERE hash=?",[SqlParameter.Text(payload.digest)])
    if(rows.size!=1 || journalStreamInteger(rows[0].required(0))<1 || journalStreamInteger(rows[0].required(0))>4096 ||
        journalStreamInteger(rows[0].required(1))>128 || journalStreamInteger(rows[0].required(2))>256 ||
        journalStreamInteger(rows[0].required(3))<1 || journalStreamInteger(rows[0].required(3))>20){
        throw IllegalStateException("input artifact changed its fixed original metadata bounds")}
    requireDocumentPayloadMetadata(tx,payload);journalStreamCheck(guard)
}
private func livePolicyInputRequireStageZero(tx:SqliteTransaction,parent:OperationId,parentItem:ItemId):Unit{
    livePolicyRequireOne(tx,"SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM operations WHERE id=? OR tool_call_item_id=?) THEN 1 ELSE 0 END",
        [SqlParameter.Text(parent.value),SqlParameter.Text(parentItem.value)],"input pin must precede actual parent preparation")
}
private func livePolicyInputCheckEncoded(encoded:String,payload:PluginDocumentPayloadReference):Unit{
    if(encoded.size!=payload.bytes || modelPolicySha256Text(encoded)!=payload.digest){
        throw IllegalStateException("input Blob identity differs from all original business argument bytes")}
}
private func livePolicyInputPinEvidence(parent:OperationId,run:RunId,parentItem:ItemId,parentTool:String,
    binding:AgentValue,argumentsDigest:String,bindingDigest:String,fact:AgentValue,payload:AgentValue):AgentValue{
    objectValue([ValueField("schema",textValue(LIVE_POLICY_INPUT_PIN_SCHEMA)),
        ValueField("parent_item_id",textValue(parentItem.value)),ValueField("parent_operation_id",textValue(parent.value)),
        ValueField("parent_call_id",textValue(httpIntentText(binding,"parent_call_id"))),ValueField("parent_tool",textValue(parentTool)),
        ValueField("binding_sha256",textValue(bindingDigest)),ValueField("parent_arguments_sha256",textValue(argumentsDigest)),
        ValueField("fact",fact),ValueField("input_payload",payload)])
}
private func livePolicyInputRequirePin(tx:SqliteTransaction,parent:OperationId,run:RunId,thread:String,encoded:String):Unit{
    let parameters=[SqlParameter.Text(parent.value),SqlParameter.Text(LIVE_POLICY_INPUT_PIN_KIND)]
    let counts=tx.query("SELECT count(*),COALESCE(max(length(CAST(payload AS BLOB))),0) FROM audit_events WHERE operation_id=? AND kind=?",parameters)
    if(counts.size!=1 || counts[0].required(0)!="1" || counts[0].required(1)!=encoded.size.toString()){
        throw IllegalStateException("input pin is missing, repeated or changed in extent")}
    let rows=tx.query("SELECT payload FROM audit_events WHERE operation_id=? AND kind=? AND thread_id=? AND run_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(LIVE_POLICY_INPUT_PIN_KIND),SqlParameter.Text(thread),SqlParameter.Text(run.value)])
    if(rows.size!=1 || rows[0].required(0)!=encoded){
        throw IllegalStateException("input pin differs from its complete original data evidence")}
}

// Exact equivalence of the ORIGINAL canonicalAgentValue grammar without
// constructing two simultaneous copies of the complete argument strings.
// Only data equality: object order is ignored, every name/value is compared,
// list order and the original numeric spelling are retained. The original
// paid StoredValue scanner has already enforced depth/EOF before this call.
func livePolicyInputSameValue(left:AgentValue,right:AgentValue,depth:Int64):Bool{
    if(depth>64){throw IllegalStateException("input data equality exceeds its original stored depth")}
    if(left.unifiedKind!=right.unifiedKind){return false}
    match(left.unifiedKind){
        case ValueKind.Null=>true
        case ValueKind.Boolean=>left.asBool()==right.asBool()
        case ValueKind.Number=>left.asNumberText()==right.asNumberText()
        case ValueKind.Text=>left.text==right.text
        case ValueKind.List=>
            let a=left.asArray();let b=right.asArray()
            if(a.size()!=b.size()){return false}
            for(index in 0..a.size()){
                if(!livePolicyInputSameValue(a.get(index).getOrThrow(),b.get(index).getOrThrow(),depth+1)){return false}}
            true
        case ValueKind.Object=>
            let a=left.asObject();let b=right.asObject()
            if(a.size()!=b.size()){return false}
            for(index in 0..a.size()){
                match(b.get(a.nameAt(index))){
                    case Some(value)=>if(!livePolicyInputSameValue(a.valueAt(index),value,depth+1)){return false}
                    case None=>return false}}
            true
    }
}

// Waiting is a narrow read-only DATA route. The original running-only
// origin/current/consumption/lane helpers are deliberately not called or
// widened. Completed read bytes are still reloaded through the real paid
// fact/plan provider. This does not attest a current Source or approval.
private func livePolicyInputReadWaitingParent(tx:SqliteTransaction,parentTool:String,binding:AgentValue,
    links:Array<ContextReadFactLink>,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    data:LivePolicyInputParentData):Unit{
    if(links.size!=1 || httpIntentText(binding,"contribution")!=parentTool){
        throw IllegalStateException("waiting input changed its original Tool contribution")}
    let payment=ContextReadCompletedMetadataPayment(tx,links[0],allocate,guard)
    try{
        let read=payment.plan();let request=read.canonicalArguments;let fact=payment.fact()
        if(!pluginDocumentLatestJournalStreamReadAuthority(read) || pluginDocumentContextLatestJournalStreamReadAuthority(read) ||
            !livePolicyInputSameValue(fact.reference(),links[0].toValue(),0) ||
            !livePolicyInputSameValue(request.field("binding").getOrThrow(),binding,0) ||
            !pluginDocumentLatestJournalStreamReadResultValid(fact.output(),request) ||
            fact.runId.value!=httpIntentText(binding,"run_id") || fact.origin.parentCallItemId=="" ||
            fact.origin.ownerNamespace!=httpIntentText(binding,"namespace") ||
            fact.origin.packageDigest!=httpIntentText(binding,"package_digest") ||
            fact.origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
            fact.origin.projectionDigest!=httpIntentText(request,"projection_digest")){
            throw IllegalStateException("waiting input changed its complete original paid Tool12 fact")}
        data.parent=documentPayloadParentOperation(fact).value;data.run=fact.runId.value
        data.item=fact.origin.parentCallItemId;data.fact=Some(fact.reference());journalStreamCheck(guard)
    }finally{payment.close()}
}
private func livePolicyInputRequireWaitingState(tx:SqliteTransaction,parent:OperationId,run:RunId,item:ItemId,
    binding:AgentValue):Unit{
    let thread=httpIntentText(binding,"thread_id")
    let epoch=journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText())
    livePolicyRequireOne(tx,"SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id "+
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
        "JOIN run_lane_bindings b ON b.run_id=r.id AND b.thread_id=r.thread_id "+
        "JOIN lanes lane ON lane.thread_id=b.thread_id AND lane.lane_id=b.lane_id "+
        "JOIN items call ON call.id=? AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id "+
        "JOIN item_tree_edges edge ON edge.item_id=call.id AND edge.thread_id=call.thread_id AND edge.lane_id=b.lane_id "+
        "WHERE r.id=? AND r.thread_id=? AND r.epoch=? AND b.lane_id=? AND lane.status='open' "+
        "AND call.kind='tool_call' AND r.state='waiting_approval' AND r.finished_at_millis IS NULL "+
        "AND t.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active'",
        [SqlParameter.Text(item.value),SqlParameter.Text(run.value),SqlParameter.Text(thread),SqlParameter.Int64Value(epoch),
            SqlParameter.Text(httpIntentText(binding,"lane_id"))],"waiting reuse lost its same actual current run/turn/lane/item")
    // An untouched waiting parent, OR its genuinely admitted unique waiting
    // child while the same parent is executing. No unknown/cancelled/completed
    // operation or arbitrary same-Run waiting call can take this data route.
    livePolicyRequireOne(tx,"SELECT 1 FROM operations p WHERE p.id=? AND p.run_id=? AND p.tool_call_item_id=? "+
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM items result WHERE result.id='result-'||p.id) "+
        "AND (SELECT count(*) FROM operations pending WHERE pending.run_id=p.run_id AND pending.state='waiting_approval')=1 "+
        "AND ((p.state='waiting_approval' AND NOT EXISTS(SELECT 1 FROM audit_events a WHERE a.operation_id=p.id "+
        "AND a.kind='operation_execution_handoff')) OR (p.state='executing' AND "+
        "(SELECT count(*) FROM derived_operation_admissions a JOIN operations c ON c.id=a.operation_id "+
        "JOIN operation_state_registers s ON s.operation_id=c.id AND s.state=c.state AND s.revision=c.revision "+
        "WHERE a.parent_operation_id=p.id AND a.root_operation_id=p.id AND c.run_id=p.run_id "+
        "AND c.state='waiting_approval' AND typeof(a.call_sequence)='integer' AND a.call_sequence>0 AND a.child_call_id<>'' "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=c.id) "+
        "AND NOT EXISTS(SELECT 1 FROM items result WHERE result.id='result-'||c.id) "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events h WHERE h.operation_id=c.id AND h.kind='operation_execution_handoff'))=1))",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value)],
        "waiting reuse has no unique real prepared parent or admitted waiting child")
}
private func livePolicyInputRequireWaitingPrepared(tx:SqliteTransaction,parent:OperationId,run:RunId,item:ItemId,
    binding:AgentValue,links:Array<ContextReadFactLink>,plan:NormalizedOperationPlan,raw:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireLivePolicyImmutableEffect(tx,parent,run,item,plan,raw)
    let thread=httpIntentText(binding,"thread_id")
    let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_parent_prepared_v1'"
    withLivePolicyStoredValue(tx,"payload",suffix,[SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread)],
        allocate,guard,{markerRaw=>
            let marker=decodeStoredValue(markerRaw);let source=marker.field("source").getOrThrow()
            let origin=links[0].origin
            let sourceSame=if(origin.parentKind=="direct"){
                httpIntentExactFields(source,["kind"]) && httpIntentText(source,"kind")=="user_direct"
            }else{origin.parentKind=="committed" && httpIntentExactFields(source,["kind","decision_id","scoped_tool_call_id"]) &&
                httpIntentText(source,"kind")=="committed" && httpIntentText(source,"decision_id")==origin.parentDecisionId &&
                httpIntentText(source,"scoped_tool_call_id")==origin.parentScopedCallId}
            if(!httpIntentExactFields(marker,["schema","parent_operation_id","run_id","thread_id","epoch","lane_id",
                "projection_digest","root_item_id","root_call_id","parent_plan_sha256","parent_binding_digest","source"]) ||
                httpIntentText(marker,"schema")!="axyndra.plugin-live-policy-parent-prepared/v1" ||
                httpIntentText(marker,"parent_operation_id")!=parent.value || httpIntentText(marker,"run_id")!=run.value ||
                httpIntentText(marker,"thread_id")!=thread || !livePolicyInputSameValue(marker.field("epoch").getOrThrow(),binding.field("epoch").getOrThrow(),0) ||
                httpIntentText(marker,"lane_id")!=httpIntentText(binding,"lane_id") ||
                httpIntentText(marker,"projection_digest")!=origin.projectionDigest || httpIntentText(marker,"root_item_id")!=item.value ||
                httpIntentText(marker,"root_call_id")!=httpIntentText(binding,"parent_call_id") ||
                httpIntentText(marker,"parent_plan_sha256")!=modelPolicySha256Text(raw) ||
                httpIntentText(marker,"parent_binding_digest")!=plan.bindingDigest || !sourceSame){
                throw IllegalStateException("waiting reuse changed its full actual prepared parent marker")}})
    journalStreamCheck(guard)
}
private func livePolicyInputRequireBusinessCall(tx:SqliteTransaction,item:ItemId,parentTool:String,input:AgentValue,
    binding:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    withLivePolicyStoredValue(tx,"payload"," FROM items WHERE id=? AND thread_id=? AND kind='tool_call'",
        [SqlParameter.Text(item.value),SqlParameter.Text(httpIntentText(binding,"thread_id"))],allocate,guard,{raw=>
            match(decodeStoredThreadContent(raw)){
                case ThreadItemContent.ToolCall(call,name,original)=>
                    if(call.value!=httpIntentText(binding,"parent_call_id") || name!=parentTool ||
                        !livePolicyInputSameValue(original,contextReadBusinessInput(input),0)){
                        throw IllegalStateException("input data differs from its complete original business ToolCall")}
                case _=>throw IllegalStateException("input data lost its original business ToolCall")}})
    journalStreamCheck(guard)
}
private func livePolicyInputRequireWaitingCall(tx:SqliteTransaction,parent:OperationId,run:RunId,item:ItemId,
    parentTool:String,arguments:AgentValue,binding:AgentValue,links:Array<ContextReadFactLink>,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    livePolicyInputRequireWaitingState(tx,parent,run,item,binding)
    withLivePolicyStoredValue(tx,"normalized_plan"," FROM operations WHERE id=? AND run_id=? AND tool_call_item_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value)],allocate,guard,{raw=>
            let plan=decodeOperationPlan(raw)
            if(!isPluginLivePolicyParentPlan(plan) || plan.toolName!=parentTool ||
                !livePolicyInputSameValue(plan.canonicalArguments,arguments,0) || plan.contextReadFacts.size!=1 ||
                !livePolicyInputSameValue(plan.contextReadFacts[0].toValue(),links[0].toValue(),0)){
                throw IllegalStateException("waiting reuse changed its complete actual prepared parent plan")}
            livePolicyInputRequireWaitingPrepared(tx,parent,run,item,binding,links,plan,raw,allocate,guard)
            journalStreamCheck(guard)})
    livePolicyInputRequireBusinessCall(tx,item,parentTool,arguments.field("input").getOrThrow(),binding,allocate,guard)
    journalStreamCheck(guard)
}

private func livePolicyInputPinOwned(tx:SqliteTransaction,parentTool:String,arguments:AgentValue,
    expected:?(String,String,String),allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:?()->Result<Unit>,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,waiting!:Bool=false):Unit{
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    livePolicyInputRequireStructure(arguments,allocate,guard)
    let host=arguments.field("host_plan").getOrThrow();let binding=host.field("binding").getOrThrow()
    let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
    let payload=parsePluginDocumentPayloadReference(host.field("input_payload").getOrThrow()).value().getOrThrow()
    let actual=LivePolicyInputParentData()
    if(waiting){
        if(verifyContent.isSome()){throw IllegalStateException("waiting data reuse cannot retain a new input pin")}
        livePolicyInputReadWaitingParent(tx,parentTool,binding,links,allocate,guard,actual)
    }else{livePolicyInputReadParent(tx,parentTool,binding,links,allocate,guard,actual)}
    match(expected){case Some(value)=>
        if(value[0]!=actual.parent || value[1]!=actual.run || value[2]!=actual.item){
            throw IllegalStateException("input pin changed its actual supplied canonical identity")}
        case None=>()}
    let parent=OperationId(actual.parent);let run=RunId(actual.run);let item=ItemId(actual.item)
    let argumentsDigest=livePolicyInputStoredDigest(arguments,allocate,guard)
    let bindingDigest=livePolicyInputBindingDigest(binding,allocate,guard)
    withPluginLivePolicyInputPayloadEncoding(arguments.field("input").getOrThrow(),allocate,guard,
        {raw=>livePolicyInputCheckEncoded(raw,payload)})
    if(waiting){livePolicyInputRequireWaitingCall(tx,parent,run,item,parentTool,arguments,binding,links,allocate,guard)}
    else{livePolicyInputRequireCall(tx,parent,run,item,parentTool,arguments,binding,allocate,guard)}
    livePolicyInputRequireMetadata(tx,payload,guard)
    match(verifyContent){case Some(verify)=>
        livePolicyInputRequireStageZero(tx,parent,item)
        requirePluginLivePolicyReadInputs(tx,parent,run,item,parentTool,binding,links,allocate,guard)
        journalStreamCheck(verify)
        case None=>()}
    let evidence=livePolicyInputPinEvidence(parent,run,item,parentTool,binding,argumentsDigest,bindingDigest,actual.fact.getOrThrow(),
        host.field("input_payload").getOrThrow())
    let extent=livePolicyStoredExtent(evidence)
    owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
    let encoded=encodeStoredValue(evidence)
    if(encoded.size!=extent.bytes){throw IllegalStateException("input pin original framing extent changed")}
    match(verifyContent){case Some(_)=>
        let rows=tx.query("SELECT count(*) FROM audit_events WHERE operation_id=? AND kind=?",
            [SqlParameter.Text(parent.value),SqlParameter.Text(LIVE_POLICY_INPUT_PIN_KIND)])
        if(rows.size!=1){throw IllegalStateException("input pin count is missing")}
        if(rows[0].required(0)=="0"){
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,?,?,?,?)",
                [SqlParameter.Text(httpIntentText(binding,"thread_id")),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),
                    SqlParameter.Text(LIVE_POLICY_INPUT_PIN_KIND),SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])}
        case None=>()}
    livePolicyInputRequirePin(tx,parent,run,httpIntentText(binding,"thread_id"),encoded)
    // None is pure data-pin revalidation after own appends. It deliberately
    // does not replay the initial private event fence. Actual admission MUST
    // still run full ParentSource/current/own-causal-prefix checks separately.
    match(verifyContent){case Some(verify)=>
        livePolicyInputRequireStageZero(tx,parent,item)
        requirePluginLivePolicyReadInputs(tx,parent,run,item,parentTool,binding,links,allocate,guard)
        journalStreamCheck(verify)
        case None=>()}
    livePolicyInputRequireStructure(arguments,allocate,guard)
    if(livePolicyInputStoredDigest(arguments,allocate,guard)!=argumentsDigest ||
        livePolicyInputBindingDigest(binding,allocate,guard)!=bindingDigest){
        throw IllegalStateException("input retention changed its complete frozen preparation")}
    if(waiting){livePolicyInputRequireWaitingCall(tx,parent,run,item,parentTool,arguments,binding,links,allocate,guard)}
    else{livePolicyInputRequireCall(tx,parent,run,item,parentTool,arguments,binding,allocate,guard)}
    livePolicyInputRequireMetadata(tx,payload,guard);journalStreamCheck(guard)
}
private func livePolicyInputPin(tx:SqliteTransaction,parentTool:String,arguments:AgentValue,
    expected:?(String,String,String),allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:?()->Result<Unit>,guard:()->Result<Unit>):Unit{
    let owner=allocate(65536)
    try{livePolicyInputPinOwned(tx,parentTool,arguments,expected,allocate,verifyContent,guard,owner)}finally{owner.close()}
}
private func livePolicyRetainInputPayload(tx:SqliteTransaction,parentTool:String,arguments:AgentValue,
    expected:?(String,String,String),allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:()->Result<Unit>,guard:()->Result<Unit>):Result<Unit>{
    // SQLite's original transaction<T> commits a returned Result.Err. This
    // savepoint keeps an after-INSERT validation failure atomic even for such
    // a caller. Rollback/release failures escape to the original TX rollback.
    tx.execute("SAVEPOINT plugin_live_policy_input_payload_pin")
    try{
        livePolicyInputPin(tx,parentTool,arguments,expected,allocate,Some(verifyContent),guard)
        tx.execute("RELEASE plugin_live_policy_input_payload_pin");Result<Unit>.Ok(())
    }catch(error:Exception){
        tx.execute("ROLLBACK TO plugin_live_policy_input_payload_pin")
        tx.execute("RELEASE plugin_live_policy_input_payload_pin")
        match(error as PluginDocumentGuardFailure){case Some(value)=>Result<Unit>.Err(value.failure)
            case None=>documentPayloadError<Unit>("plugin.live_input_payload_unverified")}
    }
}
public func retainPluginLivePolicyInputPayload(tx:SqliteTransaction,parentTool:String,parentArguments:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>,guard:()->Result<Unit>):Result<Unit>{
    livePolicyRetainInputPayload(tx,parentTool,parentArguments,None<(String,String,String)>,allocate,verifyContent,guard)
}
public func retainPluginLivePolicyInputPayload(tx:SqliteTransaction,parent:OperationId,run:RunId,parentItem:ItemId,
    parentTool:String,parentArguments:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:()->Result<Unit>,guard:()->Result<Unit>):Result<Unit>{
    livePolicyRetainInputPayload(tx,parentTool,parentArguments,Some((parent.value,run.value,parentItem.value)),allocate,verifyContent,guard)
}
// Internal retention verification only: no Source or new read scope. Callers
// perform their full actual ParentSource/current/own-causal-chain validation.
func requirePluginLivePolicyInputPayload(tx:SqliteTransaction,parent:OperationId,run:RunId,parentItem:ItemId,
    parentTool:String,parentArguments:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    livePolicyInputPin(tx,parentTool,parentArguments,Some((parent.value,run.value,parentItem.value)),allocate,None<()->Result<Unit>>,guard)
}

private func livePolicyInputReuseOwned(tx:SqliteTransaction,parentTool:String,arguments:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation):Bool{
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    livePolicyInputRequireStructure(arguments,allocate,guard)
    let host=arguments.field("host_plan").getOrThrow();let binding=host.field("binding").getOrThrow()
    let waiting=tx.query("SELECT count(*) FROM runs WHERE id=? AND thread_id=? AND epoch=? AND state='waiting_approval' "+
        "AND finished_at_millis IS NULL",[SqlParameter.Text(httpIntentText(binding,"run_id")),
            SqlParameter.Text(httpIntentText(binding,"thread_id")),
            SqlParameter.Int64Value(journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText()))])
    if(waiting.size!=1){throw IllegalStateException("input reuse lost its actual run state")}
    if(waiting[0].required(0)=="1"){
        livePolicyInputPinOwned(tx,parentTool,arguments,None<(String,String,String)>,allocate,None<()->Result<Unit>>,guard,owner,waiting:true)
        journalStreamCheck(guard);return true}
    let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
    let actual=LivePolicyInputParentData();livePolicyInputReadParent(tx,parentTool,binding,links,allocate,guard,actual)
    let parent=OperationId(actual.parent);let run=RunId(actual.run);let item=ItemId(actual.item)
    livePolicyInputRequireCall(tx,parent,run,item,parentTool,arguments,binding,allocate,guard)
    let count=tx.query("SELECT count(*) FROM operations WHERE id=?",[SqlParameter.Text(parent.value)])
    if(count.size!=1){throw IllegalStateException("input reuse lost its actual parent count")}
    if(count[0].required(0)=="0"){journalStreamCheck(guard);return false}
    livePolicyRequireOne(tx,"SELECT 1 FROM operations WHERE id=? AND run_id=? AND tool_call_item_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value)],
        "input reuse changed its actual existing parent identity")
    requirePluginLivePolicyInputPayload(tx,parent,run,item,parentTool,arguments,allocate,guard)
    journalStreamCheck(guard);true
}
private func livePolicyInputReuse(tx:SqliteTransaction,parentTool:String,arguments:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Bool{
    let owner=allocate(65536)
    try{livePolicyInputReuseOwned(tx,parentTool,arguments,allocate,guard,owner)}finally{owner.close()}
}
// Only a normalizer's data-routing choice. True avoids repeating Stage0; it
// conveys no Source/current-prefix proof and never authorizes an execution.
public func reusePluginLivePolicyInputPayload(tx:SqliteTransaction,parentTool:String,parentArguments:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Result<Bool>{
    try{Result<Bool>.Ok(livePolicyInputReuse(tx,parentTool,parentArguments,allocate,guard))}
    catch(error:PluginDocumentGuardFailure){Result<Bool>.Err(error.failure)}
    catch(_:Exception){documentPayloadError<Bool>("plugin.live_input_payload_unverified")}
}

private class LivePolicyInputStreamedJsonExtent {
    let options:JsonWriteOptions
    let owner:LogicalJsonOwnerReservation
    let extraRetained:Int64
    let ancestors=ArrayList<JsonNode>()
    var bytes:Int64=0
    var nodes:Int64=0
    init(options:JsonWriteOptions,owner:LogicalJsonOwnerReservation,extraRetained:Int64){this.options=options;this.owner=owner;this.extraRetained=extraRetained}
    func add(amount:Int64):Unit{bytes=journalStreamAdd(bytes,amount)}
    func stringBytes(value:String):Unit{
        add(2)
        unsafe{
            let raw=value.rawData()
            for(index in 0..raw.size){
                let byte=Int64(raw[index])
                if(byte==34 || byte==92 || byte==8 || byte==9 || byte==10 || byte==12 || byte==13){add(2)}
                else if(byte<32 || (options.htmlSafe && (byte==38 || byte==39 || byte==60 || byte==61 || byte==62))){add(6)}
                else{add(1)}
            }
        }
    }
    func enter(value:JsonNode):Bool{
        for(ancestor in ancestors){if(refEq(value,ancestor)){return false}}
        if(ancestors.size>=options.maxDepth){return false}
        ancestors.add(value);true
    }
    func entryPrefix(depth:Int64):Unit{
        if(!options.indent.isEmpty()){
            if(depth>Int64.Max/options.indent.size){throw IllegalStateException("JSON indentation extent overflow")}
            add(journalStreamAdd(1,depth*options.indent.size))}
    }
    func scalarBytes(value:JsonNode):Bool{
        // Scalar formatting and its original errors occur only after payment.
        // Numeric literal text is already retained by the caller. Formatting
        // built-in integers/floats and unknown-type errors fit the fixed floor.
        owner.ensureRetainedPeak(journalStreamAdd(extraRetained,1048576))
        let numeric:?String=try{Some(value.asNumberText())}catch(_:JsonException){None<String>}
        // Capacity failures must propagate; they are never a serialization
        // fallback that could retry the same bytes without their payment.
        match(numeric){case Some(text)=>owner.ensureRetainedPeak(journalStreamAdd(extraRetained,contextReadMetadataRawPeak(text.size)));case None=>()}
        try{
            let encoded=value.toJson(options:options)
            add(encoded.size);true
        }catch(_:JsonException){false}
    }
    func visit(value:JsonNode):Bool{
        nodes=journalStreamAdd(nodes,1)
        match(value){
            case array:JsonArray=>
                if(!enter(array)){return false}
                try{
                    add(2)
                    for(index in 0..array.size()){
                        if(index!=0){add(1)};entryPrefix(ancestors.size)
                        if(!visit(array.get(index).getOrThrow())){return false}}
                    if(array.size()!=0){entryPrefix(ancestors.size-1)}
                    true
                }finally{ancestors.remove(at:ancestors.size-1)}
            case object:JsonObject=>
                if(!enter(object)){return false}
                try{
                    add(2)
                    for(index in 0..object.size()){
                        if(index!=0){add(1)};entryPrefix(ancestors.size)
                        stringBytes(object.nameAt(index));add(1)
                        if(!options.indent.isEmpty()){add(1)}
                        if(!visit(object.valueAt(index))){return false}}
                    if(object.size()!=0){entryPrefix(ancestors.size-1)}
                    true
                }finally{ancestors.remove(at:ancestors.size-1)}
            case _=>
                let text:?String=try{Some(value.asString())}catch(_:JsonException){None<String>}
                match(text){case Some(actual)=>stringBytes(actual);true;case None=>scalarBytes(value)}
        }
    }
}

private func livePolicyInputStructureStreamedOwned(arguments:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,extraRetained:Int64):Unit{
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,1048576));journalStreamCheck(guard)
    let extent=livePolicyStoredExtent(arguments)
    if(extent.bytes>8388608){throw IllegalStateException("input preparation exceeds its original durable codec")}
    if(extent.nodes>Int64.Max/512){throw IllegalStateException("input structure payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,journalStreamAdd(1048576,extent.nodes*512)))
    if(!pluginLivePolicyParentValueValid(arguments)){throw IllegalStateException("input pin requires the exact closed parent shape")}
    let host=arguments.field("host_plan").getOrThrow()
    let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
    if(links.size!=1){throw IllegalStateException("input pin requires its sole actual Tool12 read")}
    let input=arguments.field("input").getOrThrow()
    match(input.field(CONTEXT_READ_INPUT_FIELD)){
        case Some(projection)=>
            let data=projection.field("data")??projection
            let count=LivePolicyInputStreamedJsonExtent(JsonWriteOptions.defaults,owner,extraRetained)
            let exact=count.visit(data)
            owner.ensureRetainedPeak(journalStreamAdd(extraRetained,journalStreamAdd(contextReadMetadataPeak(count.bytes,count.nodes),extent.nodes*512)))
            if(!exact){let _=encodeAgentValue(data);throw IllegalStateException("input projection has unsupported original JSON")}
        case None=>()
    }
    journalStreamCheck({=>validateContextReadInputProjection(input,links)})
    journalStreamCheck(guard)
}
private func livePolicyInputRequireCallStreamed(tx:SqliteTransaction,parent:OperationId,run:RunId,parentItem:ItemId,
    parentTool:String,arguments:AgentValue,binding:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):Unit{
    let thread=httpIntentText(binding,"thread_id")
    let epoch=journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText())
    livePolicyRequireOne(tx,"SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id "+
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id JOIN items call "+
        "ON call.id=? AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id "+
        "WHERE r.id=? AND r.thread_id=? AND r.epoch=? AND call.kind='tool_call' AND r.state='running' "+
        "AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active'",
        [SqlParameter.Text(parentItem.value),SqlParameter.Text(run.value),SqlParameter.Text(thread),SqlParameter.Int64Value(epoch)],
        "input retention lost its same actual current run/turn/item")
    if(requirePluginDocumentLane(tx,ThreadId(thread),run,epoch).value!=httpIntentText(binding,"lane_id")){
        throw IllegalStateException("input retention lost its actual current lane")}
    // Only the shallow business projection is new; original values remain
    // in the actual caller's frozen input owner. Pay all wrapper nodes before
    // construction and retain them through full actual SQL comparison.
    let input=arguments.field("input").getOrThrow()
    let fields=match(input as JsonObject){case Some(value)=>value.size();case None=>0}
    if(fields>(Int64.Max-1048576)/2048){throw IllegalStateException("business comparison wrapper payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,1048576+fields*2048))
    let business=contextReadBusinessInput(input)
    let suffix=" FROM items WHERE id=? AND thread_id=? AND kind='tool_call'"
    withLivePolicyStoredValueOwned(tx,"payload",suffix,[SqlParameter.Text(parentItem.value),SqlParameter.Text(thread)],allocate,guard,owner,journalStreamAdd(extraRetained,1048576+fields*2048),{raw=>
        match(decodeStoredThreadContent(raw)){
            case ThreadItemContent.ToolCall(call,name,original)=>
                if(call.value!=httpIntentText(binding,"parent_call_id") || name!=parentTool ||
                    !livePolicyInputSameValue(original,business,0)){
                    throw IllegalStateException("input payload differs from its complete original canonical ToolCall")}
            case _=>throw IllegalStateException("input retention requires its complete original ToolCall")
        }
    })
    journalStreamCheck(guard)
}

// Opt-in running None revalidation only. Original Stage0, Waiting, public
// encoders/retain/reuse and their ownership remain byte-for-byte above.
// No Source is minted here; the caller MUST still check full actual Parent
// Source/current/own-causal-prefix before and after its terminal callback.
private func livePolicyInputRetainedMetadataPeak(data:LivePolicyInputParentData):Int64{
    let fact=livePolicyStoredExtent(data.fact.getOrThrow())
    var retained=contextReadMetadataPeak(fact.bytes,fact.nodes)
    for(text in [data.parent,data.run,data.item]){
        retained=journalStreamAdd(retained,contextReadMetadataRawPeak(text.size))}
    // Two actual 64-byte SHA strings plus their small holders survive the
    // identity phases. This is additional retained storage, not a new cap.
    journalStreamAdd(retained,1048576+128*4)
}
private func livePolicyInputBindingDigestStreamedOwned(binding:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,extraRetained:Int64):String{
    let extent=livePolicyStoredExtent(binding)
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,contextReadMetadataPeak(extent.bytes,extent.nodes)))
    journalStreamCheck(guard);let digest=modelPolicySha256Text(canonicalAgentValue(binding))
    journalStreamCheck(guard);digest
}
private func livePolicyInputRevalidateOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,item:ItemId,
    parentTool:String,arguments:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,streamedIdentity!:Bool=false):Unit{
    if(!streamedIdentity){
        livePolicyInputPinOwned(tx,parentTool,arguments,Some((parent.value,run.value,item.value)),allocate,None,guard,owner)
        return
    }
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    livePolicyInputStructureStreamedOwned(arguments,owner,guard,0)
    let host=arguments.field("host_plan").getOrThrow();let binding=host.field("binding").getOrThrow()
    let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
    let payload=parsePluginDocumentPayloadReference(host.field("input_payload").getOrThrow()).value().getOrThrow()
    let actual=LivePolicyInputParentData()
    // This ORIGINAL reader checks actual Completed Tool12/Source/Run/lane.
    // It may legitimately reject an aggregate with large simultaneous source
    // cells; its payment is neither lowered nor bypassed by this opt-in.
    livePolicyInputReadParentStreamed(tx,parentTool,binding,links,allocate,guard,actual,owner)
    if(parent.value!=actual.parent || run.value!=actual.run || item.value!=actual.item){
        throw IllegalStateException("input pin changed its actual supplied canonical identity")}
    let retained=livePolicyInputRetainedMetadataPeak(actual)
    owner.ensureRetainedPeak(retained)
    let argumentsDigest=livePolicyInputStoredDigestStreamedOwned(arguments,owner,guard,extraRetained:retained)
    let bindingDigest=livePolicyInputBindingDigestStreamedOwned(binding,owner,guard,retained)
    livePolicyInputPayloadIdentityOwned(arguments.field("input").getOrThrow(),owner,guard,
        {bytes,digest=>if(bytes!=payload.bytes || digest!=payload.digest){
            throw IllegalStateException("input Blob identity differs from all original business argument bytes")}},extraRetained:retained)
    livePolicyInputRequireCallStreamed(tx,parent,run,item,parentTool,arguments,binding,allocate,guard,owner,retained)
    livePolicyInputRequireMetadata(tx,payload,guard)
    let evidence=livePolicyInputPinEvidence(parent,run,item,parentTool,binding,argumentsDigest,bindingDigest,actual.fact.getOrThrow(),
        host.field("input_payload").getOrThrow())
    let extent=livePolicyStoredExtent(evidence)
    owner.ensureRetainedPeak(journalStreamAdd(retained,contextReadMetadataPeak(extent.bytes,extent.nodes)))
    let encoded=encodeStoredValue(evidence)
    if(encoded.size!=extent.bytes){throw IllegalStateException("input pin original framing extent changed")}
    livePolicyInputRequirePin(tx,parent,run,httpIntentText(binding,"thread_id"),encoded)
    // The complete nine-field evidence stays owned through final full pin,
    // call, metadata and frozen-argument checks. No initial fence is replayed
    // after the same parent has appended its known effects.
    let finalRetained=journalStreamAdd(retained,contextReadMetadataPeak(extent.bytes,extent.nodes))
    livePolicyInputStructureStreamedOwned(arguments,owner,guard,finalRetained)
    if(livePolicyInputStoredDigestStreamedOwned(arguments,owner,guard,extraRetained:finalRetained)!=argumentsDigest ||
        livePolicyInputBindingDigestStreamedOwned(binding,owner,guard,finalRetained)!=bindingDigest){
        throw IllegalStateException("input retention changed its complete frozen preparation")}
    livePolicyInputRequireCallStreamed(tx,parent,run,item,parentTool,arguments,binding,allocate,guard,owner,finalRetained)
    livePolicyInputRequireMetadata(tx,payload,guard)
    livePolicyInputRequirePin(tx,parent,run,httpIntentText(binding,"thread_id"),encoded)
    journalStreamCheck(guard)
}
func requirePluginLivePolicyInputPayloadStreamed(tx:SqliteTransaction,parent:OperationId,run:RunId,parentItem:ItemId,
    parentTool:String,parentArguments:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let owner=allocate(65536)
    try{livePolicyInputRevalidateOwned(tx,parent,run,parentItem,parentTool,parentArguments,allocate,guard,owner,streamedIdentity:true)}
    finally{owner.close()}
}

private func livePolicyInputReadParentStreamed(tx:SqliteTransaction,parentTool:String,binding:AgentValue,
    links:Array<ContextReadFactLink>,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    data:LivePolicyInputParentData,owner:LogicalJsonOwnerReservation):Unit{
    if(links.size!=1 || httpIntentText(binding,"contribution")!=parentTool){
        throw IllegalStateException("input pin changed its original Tool contribution")}
    let payment=ContextReadCompletedMetadataPayment(tx,links[0],allocate,guard,phaseOwner:Some(owner),extraRetained:1048576)
    try{
        let plan=payment.plan()
        if(!pluginDocumentLatestJournalStreamReadAuthority(plan) || pluginDocumentContextLatestJournalStreamReadAuthority(plan)){
            throw IllegalStateException("input pin cannot use parentless or older read facts")}
        let fact=payment.fact()
        let _=latestJournalInputRequireFact(tx,links[0],binding,fact.output(),payment)
        if(fact.origin.parentCallItemId=="" || fact.runId.value!=httpIntentText(binding,"run_id")){
            throw IllegalStateException("input pin lost its actual completed parent")}
        data.parent=documentPayloadParentOperation(fact).value;data.run=fact.runId.value
        data.item=fact.origin.parentCallItemId;data.fact=Some(fact.reference())
        journalStreamCheck(guard)
    }finally{payment.close()}
}

// Neutral canonical-commit verifier borrows the real caller phase. Only data
// is validated here; actual Core commit/current/Receipt checks stay mandatory.
func requirePluginLivePolicyInputPayloadForKnownParentOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,item:ItemId,
    parentTool:String,arguments:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,externalRetained:Int64):Unit{
    owner.ensureRetainedPeak(journalStreamAdd(externalRetained,1048576));journalStreamCheck(guard)
    livePolicyInputStructureStreamedOwned(arguments,owner,guard,externalRetained)
    let host=arguments.field("host_plan").getOrThrow();let binding=host.field("binding").getOrThrow()
    let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
    let payload=parsePluginDocumentPayloadReference(host.field("input_payload").getOrThrow()).value().getOrThrow()
    let actual=LivePolicyInputParentData()
    // This ORIGINAL reader checks actual Completed Tool12/Source/Run/lane.
    // It may legitimately reject an aggregate with large simultaneous source
    // cells; its payment is neither lowered nor bypassed by this opt-in.
    livePolicyInputReadParentForKnownParentOwned(tx,parentTool,binding,links,allocate,guard,actual,owner,externalRetained)
    if(parent.value!=actual.parent || run.value!=actual.run || item.value!=actual.item){
        throw IllegalStateException("input pin changed its actual supplied canonical identity")}
    let retained=journalStreamAdd(externalRetained,livePolicyInputRetainedMetadataPeak(actual))
    owner.ensureRetainedPeak(retained)
    let argumentsDigest=livePolicyInputStoredDigestStreamedOwned(arguments,owner,guard,extraRetained:retained)
    let bindingDigest=livePolicyInputBindingDigestStreamedOwned(binding,owner,guard,retained)
    livePolicyInputPayloadIdentityOwned(arguments.field("input").getOrThrow(),owner,guard,
        {bytes,digest=>if(bytes!=payload.bytes || digest!=payload.digest){
            throw IllegalStateException("input Blob identity differs from all original business argument bytes")}},extraRetained:retained)
    livePolicyInputRequireCallStreamed(tx,parent,run,item,parentTool,arguments,binding,allocate,guard,owner,retained)
    livePolicyInputRequireMetadata(tx,payload,guard)
    let evidence=livePolicyInputPinEvidence(parent,run,item,parentTool,binding,argumentsDigest,bindingDigest,actual.fact.getOrThrow(),
        host.field("input_payload").getOrThrow())
    let extent=livePolicyStoredExtent(evidence)
    owner.ensureRetainedPeak(journalStreamAdd(retained,contextReadMetadataPeak(extent.bytes,extent.nodes)))
    let encoded=encodeStoredValue(evidence)
    if(encoded.size!=extent.bytes){throw IllegalStateException("input pin original framing extent changed")}
    livePolicyInputRequirePin(tx,parent,run,httpIntentText(binding,"thread_id"),encoded)
    // The complete nine-field evidence stays owned through final full pin,
    // call, metadata and frozen-argument checks. No initial fence is replayed
    // after the same parent has appended its known effects.
    let finalRetained=journalStreamAdd(retained,contextReadMetadataPeak(extent.bytes,extent.nodes))
    livePolicyInputStructureStreamedOwned(arguments,owner,guard,finalRetained)
    if(livePolicyInputStoredDigestStreamedOwned(arguments,owner,guard,extraRetained:finalRetained)!=argumentsDigest ||
        livePolicyInputBindingDigestStreamedOwned(binding,owner,guard,finalRetained)!=bindingDigest){
        throw IllegalStateException("input retention changed its complete frozen preparation")}
    livePolicyInputRequireCallStreamed(tx,parent,run,item,parentTool,arguments,binding,allocate,guard,owner,finalRetained)
    livePolicyInputRequireMetadata(tx,payload,guard)
    livePolicyInputRequirePin(tx,parent,run,httpIntentText(binding,"thread_id"),encoded)
    journalStreamCheck(guard)
}
private func livePolicyInputReadParentForKnownParentOwned(tx:SqliteTransaction,parentTool:String,binding:AgentValue,
    links:Array<ContextReadFactLink>,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    data:LivePolicyInputParentData,owner:LogicalJsonOwnerReservation,externalRetained:Int64):Unit{
    if(links.size!=1 || httpIntentText(binding,"contribution")!=parentTool){
        throw IllegalStateException("input pin changed its original Tool contribution")}
    let payment=ContextReadCompletedMetadataPayment(tx,links[0],allocate,guard,phaseOwner:Some(owner),extraRetained:journalStreamAdd(externalRetained,1048576),knownCommitStreamingResults:true)
    try{
        let plan=payment.plan()
        if(!pluginDocumentLatestJournalStreamReadAuthority(plan) || pluginDocumentContextLatestJournalStreamReadAuthority(plan)){
            throw IllegalStateException("input pin cannot use parentless or older read facts")}
        let fact=payment.fact()
        let _=latestJournalInputRequireFact(tx,links[0],binding,fact.output(),payment)
        if(fact.origin.parentCallItemId=="" || fact.runId.value!=httpIntentText(binding,"run_id")){
            throw IllegalStateException("input pin lost its actual completed parent")}
        data.parent=documentPayloadParentOperation(fact).value;data.run=fact.runId.value
        data.item=fact.origin.parentCallItemId;data.fact=Some(fact.reference())
        journalStreamCheck(guard)
    }finally{payment.close()}
}
