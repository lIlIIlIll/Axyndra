package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

class LivePolicyTerminalJsonExtent {
    let options:JsonWriteOptions
    let owner:LogicalJsonOwnerReservation
    let extraRetained:Int64
    let ancestors=ArrayList<JsonNode>()
    var bytes:Int64=0
    var nodes:Int64=0
    init(options:JsonWriteOptions,owner:LogicalJsonOwnerReservation,extraRetained!:Int64=0){this.options=options;this.owner=owner;this.extraRetained=extraRetained}
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
        owner.ensureRetainedPeak(journalStreamAdd(1048576,extraRetained))
        let numeric:?String=try{Some(value.asNumberText())}catch(_:JsonException){None<String>}
        // Capacity failures must propagate; they are never a serialization
        // fallback that could retry the same bytes without their payment.
        match(numeric){case Some(text)=>owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataRawPeak(text.size),extraRetained));case None=>()}
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

// This callback uses the complete original output JSON. It does not apply
// the input-only business projection or discard any output field. All raw
// copies remain inside the caller's same aggregate reservation.
private func livePolicyTerminalEncodeOwned(output:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    owner.ensureRetainedPeak(1048576);journalStreamCheck(guard)
    let _=JsonNode.nullValue.toJson()
    let extent=LivePolicyTerminalJsonExtent(JsonWriteOptions.defaults,owner)
    let exact=extent.visit(output)
    owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
    if(exact && extent.bytes>PLUGIN_DOCUMENT_MAX_BYTES){
        throw IllegalStateException("terminal output exceeds its original document bound")}
    // Unsupported nodes and malformed numeric literals still reach the
    // original pinned writer, including its original exception behavior.
    let encoded=encodeAgentValue(output)
    if(!exact || encoded.size!=extent.bytes || encoded.size>PLUGIN_DOCUMENT_MAX_BYTES){
        throw IllegalStateException("terminal output differs from its full original JSON extent")}
    journalStreamCheck(guard);consume(encoded);journalStreamCheck(guard)
}
public func withPluginLivePolicyTerminalOutputEncoding(output:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    journalStreamCheck(guard)
    let owner=allocate(65536)
    try{livePolicyTerminalEncodeOwned(output,owner,guard,consume)}finally{owner.close()}
}

// Pay the full descriptor before serialization. The descriptor is data;
// validating it never grants a Source, approval, admission or settlement.
// The borrowed reservation is only payment. The actual Session remains its
// unique closer. Its caller pays every simultaneously retained metadata byte;
// this callback keeps the complete descriptor encoding inside that payment.
private func livePolicyParentTerminalDescriptorOwned(descriptor:AgentValue,parent:OperationId,
    plan:NormalizedOperationPlan,owner:LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(String,Int64,PluginDocumentPayloadReference)->Unit,extraRetained:Int64):Unit{
    owner.ensureRetainedPeak(journalStreamAdd(1048576,extraRetained))
    let extent=livePolicyStoredExtent(descriptor)
    owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extraRetained))
    if(!pluginLivePolicyTerminalDataValid(descriptor,parent.value,plan.bindingDigest)){
        throw IllegalStateException("live parent terminal data changed its exact bounded shape")}
    let through=journalStreamInteger(descriptor.field("prior_receipts").getOrThrow().field("through_sequence").getOrThrow().asNumberText())
    let payload=parsePluginDocumentPayloadReference(descriptor.field("result_payload").getOrThrow()).value().getOrThrow()
    let encoded=encodeStoredValue(descriptor)
    if(encoded.size!=extent.bytes){throw IllegalStateException("live terminal descriptor extent changed")}
    journalStreamCheck(guard);consume(encoded,through,payload);journalStreamCheck(guard)
}

private func withLivePolicyParentTerminalDescriptor(descriptor:AgentValue,parent:OperationId,
    plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String,Int64,PluginDocumentPayloadReference)->Unit,
    retainedDescriptorOwner!:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>,
    retainedDescriptorPeak!:Int64=0):Unit{
    journalStreamCheck(guard)
    match(retainedDescriptorOwner){
        case Some(owner)=>
            if(retainedDescriptorPeak<=0){
                throw IllegalStateException("borrowed descriptor requires actual simultaneous metadata payment")}
            livePolicyParentTerminalDescriptorOwned(descriptor,parent,plan,owner,guard,consume,retainedDescriptorPeak)
        case None=>
            let owner=allocate(65536)
            try{livePolicyParentTerminalDescriptorOwned(descriptor,parent,plan,owner,guard,consume,0)}finally{owner.close()}
    }
}

func requireLivePolicyParentTerminalBlob(tx:SqliteTransaction,payload:PluginDocumentPayloadReference,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>,guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    // Numeric metadata only until the complete original SQL copy is paid.
    // The original decoder retains its 4096-byte metadata boundary.
    let sizes=tx.query("SELECT length(CAST(mime AS BLOB)),length(CAST(size AS BLOB)),"+
        "length(CAST(metadata AS BLOB)),length(CAST(relative_path AS BLOB)) FROM artifacts WHERE hash=?",
        [SqlParameter.Text(payload.digest)])
    if(sizes.size!=1 || sizes[0].size!=4){throw IllegalStateException("terminal output has no unique actual Blob metadata")}
    var bytes:Int64=0
    for(index in 0..4){
        let size=journalStreamInteger(sizes[0].required(index))
        if(size<1){throw IllegalStateException("terminal output metadata cell is empty")}
        bytes=journalStreamAdd(bytes,size)
    }
    if(journalStreamInteger(sizes[0].required(2))>4096){
        throw IllegalStateException("terminal output metadata exceeds its original decoder bound")}
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(contextReadMetadataRawPeak(bytes))
        requireDocumentPayloadMetadata(tx,payload);journalStreamCheck(guard)
        // Host supplies its already adopted exact FD/witness/full EOF hash
        // verifier. A Native pathname or a declared digest cannot open it.
        journalStreamCheck(verifyContent);journalStreamCheck(guard)
        requireDocumentPayloadMetadata(tx,payload);journalStreamCheck(guard)
    }finally{owner.close()}
}

private func withLivePolicyParentTerminalEvidence(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    through:Int64,payload:PluginDocumentPayloadReference,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:()->Result<Unit>,guard:()->Result<Unit>,consume:()->Unit,streamedSource!:Bool=false):Unit{
    if(streamedSource){withLivePolicyParentTerminalEvidenceStreamed(tx,root,parent,run,thread,epoch,plan,descriptor,through,payload,allocate,verifyContent,guard,consume);return}
    let reference=descriptor.field("prior_receipts").getOrThrow()
    let progress=Some(LivePolicyReadProgress(through,reference,None<OperationId>))
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
    requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
    let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    let prefix=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,through,reference,allocate,guard)
    try{
        requireLivePolicyParentTerminalBlob(tx,payload,allocate,verifyContent,guard)
    }finally{prefix.close()}
    journalStreamCheck(guard);consume();journalStreamCheck(guard)
    // Recheck the complete original Source and every causal relationship
        // after the trusted callback, while the same transaction is held.
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
        requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        let after=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,through,reference,allocate,guard)
        try{requireLivePolicyParentTerminalBlob(tx,payload,allocate,verifyContent,guard)}finally{after.close()}
    journalStreamCheck(guard)
}


private func withLivePolicyParentTerminalEvidenceStreamed(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    through:Int64,payload:PluginDocumentPayloadReference,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:()->Result<Unit>,guard:()->Result<Unit>,consume:()->Unit):Unit{
    let reference=descriptor.field("prior_receipts").getOrThrow()
    let progress=Some(LivePolicyReadProgress(through,reference,None<OperationId>))
    requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
    requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
    let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,through,reference,allocate,guard,{owner,retained=>
        requireLivePolicyParentTerminalBlobOwned(tx,payload,owner,retained,verifyContent,guard)})
    journalStreamCheck(guard);consume();journalStreamCheck(guard)
    // Recheck the complete original Source and every causal relationship
        // after the trusted callback, while the same transaction is held.
        requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
        requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,through,reference,allocate,guard,{owner,retained=>
            requireLivePolicyParentTerminalBlobOwned(tx,payload,owner,retained,verifyContent,guard)})
    journalStreamCheck(guard)
}

private func requireLivePolicyParentTerminalAudit(tx:SqliteTransaction,parent:OperationId,
    run:RunId,thread:ThreadId,encoded:String,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT count(*) FROM audit_events WHERE operation_id=? "+
        "AND kind='plugin_live_policy_parent_terminal_v1')=1",
        [SqlParameter.Text(parent.value)],"live parent terminal audit is missing or repeated")
    withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
        "AND kind='plugin_live_policy_parent_terminal_v1'",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
            if(actual!=encoded){throw IllegalStateException("live terminal audit substituted its exact complete descriptor")}})
}

// Must be called inside the actual Host ArtifactStore transaction. Exceptions
// escape to its original rollback. This records only bounded retention data;
// Core alone creates the canonical Parent Receipt and ToolResult afterward.
public func retainPluginLivePolicyParentTerminal(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>,guard:()->Result<Unit>,
    retainedDescriptorOwner!:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>,retainedDescriptorPeak!:Int64=0,streamedSource!:Bool=false):Unit{
    withLivePolicyParentTerminalDescriptor(descriptor,parent,plan,allocate,guard,{encoded,through,payload=>
        withLivePolicyParentTerminalEvidence(tx,root,parent,run,thread,epoch,plan,descriptor,through,payload,
            allocate,verifyContent,guard,{=>
                livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
                    "AND kind='plugin_live_policy_parent_terminal_v1')",[SqlParameter.Text(parent.value)],
                    "live parent terminal retention cannot overwrite an existing terminal")
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                    "VALUES (?,?,?,'plugin_live_policy_parent_terminal_v1',?,?)",
                    [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),
                     SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])
                requireLivePolicyParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
            },streamedSource:streamedSource)
        requireLivePolicyParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
    },retainedDescriptorOwner:retainedDescriptorOwner,retainedDescriptorPeak:retainedDescriptorPeak)
}

// Read-only verification for the real Port's owned Completed path. It keeps
// the Host's same physical Session and result lease alive; it neither closes
// that lease nor acknowledges a worker, file, cleanup or cancellation debt.
public func verifyPluginLivePolicyParentTerminalInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    result:ToolResult,allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>,guard:()->Result<Unit>,
    retainedDescriptorOwner!:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>,retainedDescriptorPeak!:Int64=0,streamedSource!:Bool=false):Unit{
    withLivePolicyParentTerminalDescriptor(descriptor,parent,plan,allocate,guard,{encoded,through,payload=>
        if(result.callId!=root.callId() || result.receiptId!=parent.value || result.payloadLease.isNone() ||
            result.isError!=descriptor.field("is_error").getOrThrow().asBool()){
            throw IllegalStateException("live parent result changed its actual call/operation/leased output")}
        withLivePolicyParentTerminalEvidence(tx,root,parent,run,thread,epoch,plan,descriptor,through,payload,
            allocate,verifyContent,guard,{=>
                requireLivePolicyParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
                withPluginLivePolicyTerminalOutputIdentity(result.output,allocate,guard,{bytes,digest=>
                    if(bytes!=payload.bytes || digest!=payload.digest){
                        throw IllegalStateException("live parent result differs from every frozen output JSON byte")}})
                requireLivePolicyParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
            },streamedSource:streamedSource)
        requireLivePolicyParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
    },retainedDescriptorOwner:retainedDescriptorOwner,retainedDescriptorPeak:retainedDescriptorPeak)
}
