package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

let MANAGED_ACTUAL_TERMINAL_AUDIT="managed_channel_actual_terminal_v1"
let MANAGED_KNOWN_CANONICAL_AUDIT="managed_channel_known_parent_canonical_v1"

// Complete original StoredValue identity, not JSON escaping or a declared
// Native hash. Every scalar and framing byte is visited under its real owner.
func managedChannelTerminalValueIdentity(value:AgentValue,owner:LogicalJsonOwnerReservation,
    retained:Int64,guard:()->Result<Unit>):AgentValue{
    let extent=livePolicyStoredExtent(value)
    if(retained<0 || extent.nodes>(Int64.Max-1048576)/512){throw IllegalStateException("actual terminal traversal payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(retained,1048576+extent.nodes*512))
    let stream=ManagedTerminalStoredIdentityStream(guard);stream.visit(value,0)
    let identity=stream.finish()
    if(identity[0]!=extent.bytes){throw IllegalStateException("actual complete terminal framing drift")}
    let digest=identity[1]
    owner.ensureRetainedPeak(journalStreamAdd(retained,65536))
    objectValue([ValueField("bytes",integerValue(extent.bytes)),ValueField("sha256",textValue(digest))])
}

// Called only after the actual retained DataOwner and its fixed FD have
// completed the existing terminal proof. This metadata is never an execution
// permit, Source, Receipt or physical ACK. The entire output and response were
// scanned; their hashes do not replace canonical revalidation of every child.
func recordManagedChannelActualTerminalWitness(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,result:ToolResult,descriptor:AgentValue,
    owner:LogicalJsonOwnerReservation,retained:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(!isManagedChannelOwnedParentPlan(plan) || result.callId!=root.callId() || result.receiptId!=parent.value ||
        result.payloadLease.isNone()){throw IllegalStateException("actual terminal witness lost its held parent invocation")}
    owner.ensureRetainedPeak(journalStreamAdd(retained,65536))
    let kind=httpIntentText(descriptor,"terminal_kind")
    let record=if(kind=="protocol"){
        let actual=descriptor.field("protocol_record").getOrThrow()
        let response=managedChannelTerminalValueIdentity(actual.field("response").getOrThrow(),owner,retained,guard)
        objectValue([ValueField("operation_id",actual.field("operation_id").getOrThrow()),
            ValueField("request_key",actual.field("request_key").getOrThrow()),ValueField("response_identity",response)])
    }else{nullValue()}
    let count=tx.query("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id=?",[SqlParameter.Text(parent.value)])
    if(count.size!=1){throw IllegalStateException("actual terminal child inventory is not unique")}
    let witness=objectValue([ValueField("schema",textValue("axyndra.managed-channel-actual-terminal/v1")),
        ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
        ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
        ValueField("root_item_id",textValue(root.itemId().value)),ValueField("root_call_id",textValue(root.callId())),
        ValueField("parent_binding_digest",textValue(plan.bindingDigest)),ValueField("terminal_kind",textValue(kind)),
        ValueField("is_error",boolValue(result.isError)),ValueField("through_sequence",integerValue(journalStreamInteger(count[0].required(0)))),
        ValueField("output_identity",managedChannelTerminalValueIdentity(result.output,owner,retained,guard)),
        ValueField("descriptor_identity",managedChannelTerminalValueIdentity(descriptor,owner,retained,guard)),
        ValueField("protocol_record",record)])
    let extent=livePolicyStoredExtent(witness)
    owner.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*8)))
    let encoded=encodeStoredValue(witness)
    let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind=?"
    let args=[SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(MANAGED_ACTUAL_TERMINAL_AUDIT)]
    let existing=tx.query("SELECT id"+suffix,args)
    if(existing.isEmpty()){
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (?,?,?,?,?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),
             SqlParameter.Text(MANAGED_ACTUAL_TERMINAL_AUDIT),SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])
        requireStoreChanged(tx,"actual terminal witness was not recorded")
    }else{
        if(existing.size!=1){throw IllegalStateException("actual terminal witness cannot have duplicate owners")}
        withLivePolicyStoredValueOwned(tx,"payload",suffix,args,allocate,
            guard,owner,journalStreamAdd(retained,contextReadMetadataRawPeak(encoded.size)),{raw=>
                if(raw!=encoded){throw IllegalStateException("actual terminal witness cannot be replaced by another output/response")}})
    }
    journalStreamCheck(guard)
}

func managedChannelKnownIdentityMatches(identity:AgentValue,value:AgentValue,owner:LogicalJsonOwnerReservation,
    retained:Int64,guard:()->Result<Unit>):Bool{
    if(!httpIntentExactFields(identity,["bytes","sha256"]) || identity.field("bytes").getOrThrow().unifiedKind!=ValueKind.Number ||
        identity.field("sha256").getOrThrow().unifiedKind!=ValueKind.Text){return false}
    let actual=managedChannelTerminalValueIdentity(value,owner,retained,guard)
    identity.field("bytes").getOrThrow().asNumberText()==actual.field("bytes").getOrThrow().asNumberText() &&
        httpIntentText(identity,"sha256")==httpIntentText(actual,"sha256")
}

func requireManagedChannelCanonicalProtocolWrite(tx:SqliteTransaction,record:AgentValue,parent:OperationId,run:RunId):Unit{
    if(!httpIntentExactFields(record,["operation_id","request_key","response_identity"]) ||
        !httpIntentExactFields(record.field("response_identity").getOrThrow(),["bytes","sha256"]) ||
        journalStreamInteger(record.field("response_identity").getOrThrow().field("bytes").getOrThrow().asNumberText())<1 ||
        !httpIntentDigest(httpIntentText(record.field("response_identity").getOrThrow(),"sha256"))){
        throw IllegalStateException("actual protocol witness lost its complete parsed response identity")}
    // The real write Receipt describes the write ACK. The later actual parsed
    // response was witnessed by the same Host fixed-FD owner, and is not that
    // Receipt DTO. Neither the response nor this metadata grants permission.
    livePolicyRequireOne(tx,"SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
        "JOIN operation_receipts r ON r.operation_id=o.id JOIN operation_effect_records e ON e.operation_id=o.id "+
        "WHERE a.operation_id=? AND a.parent_operation_id=? AND a.root_operation_id=? AND a.depth=1 AND a.request_key=? "+
        "AND o.run_id=? AND o.state='committed' AND r.outcome='completed' AND r.id=e.reserved_receipt_id AND e.tool_id=?",
        [SqlParameter.Text(httpIntentText(record,"operation_id")),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),
         SqlParameter.Text(httpIntentText(record,"request_key")),SqlParameter.Text(run.value),SqlParameter.Text(HOST_MANAGED_CHANNEL_WRITE_TOOL)],
        "actual protocol response lost its own precise completed channel write")
}

func withManagedKnownCanonicalParentCommit(tx:SqliteTransaction,transition:ThreadTransition,
    scope:OwnedCanonicalParentCommit,allocate:(Int64)->LogicalJsonOwnerReservation,action:()->Unit):Unit{
    if(!isManagedChannelOwnedParentPlan(scope.plan) || !scope.matches(transition)){
        throw IllegalStateException("managed canonical scope is not the same actual held invocation")}
    let eligibility=LiveKnownCommitEligibility();let guard={=>liveKnownSettlementGuard(scope,eligibility)}
    let owner=allocate(65536)
    try{
        let args=[SqlParameter.Text(scope.operation.value),SqlParameter.Text(scope.run.value),SqlParameter.Text(scope.thread.value),
            SqlParameter.Text(MANAGED_ACTUAL_TERMINAL_AUDIT)]
        let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind=?"
        livePolicyRequireOne(tx,"SELECT 1"+suffix,args,"managed canonical commit has no unique actual terminal witness")
        withLivePolicyStoredValueOwned(tx,"payload",suffix,args,allocate,guard,owner,0,{raw=>
            let witness=decodeStoredValue(raw)
            let retained=journalStreamAdd(65536,contextReadMetadataPeak(raw.size,livePolicyStoredExtent(witness).nodes))
            owner.ensureRetainedPeak(retained)
            if(!httpIntentExactFields(witness,["schema","parent_operation_id","run_id","thread_id","epoch","root_item_id","root_call_id",
                "parent_binding_digest","terminal_kind","is_error","through_sequence","output_identity","descriptor_identity","protocol_record"]) ||
                httpIntentText(witness,"schema")!="axyndra.managed-channel-actual-terminal/v1" ||
                httpIntentText(witness,"parent_operation_id")!=scope.operation.value || httpIntentText(witness,"run_id")!=scope.run.value ||
                httpIntentText(witness,"thread_id")!=scope.thread.value || witness.field("epoch").getOrThrow().asNumberText()!=scope.epoch.toString() ||
                httpIntentText(witness,"root_item_id")!=scope.source.itemId().value || httpIntentText(witness,"root_call_id")!=scope.source.callId() ||
                httpIntentText(witness,"parent_binding_digest")!=scope.plan.bindingDigest ||
                !httpIntentExactFields(witness.field("descriptor_identity").getOrThrow(),["bytes","sha256"])){
                throw IllegalStateException("managed canonical witness changed its complete actual Source/plan/output tuple")}
            let kind=httpIntentText(witness,"terminal_kind")
            if(!["protocol","policy_stop","user_rejected","child_failure","complete"].contains(kind)){
                throw IllegalStateException("managed canonical witness has an unknown actual terminal kind")}
            let count=tx.query("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id=?",[SqlParameter.Text(scope.operation.value)])
            if(count.size!=1 || count[0].required(0)!=witness.field("through_sequence").getOrThrow().asNumberText()){
                throw IllegalStateException("managed canonical commit changed its complete own child sequence")}
            scope.withOutput({result=>
                if(result.callId!=scope.source.callId() || result.receiptId!="receipt-"+scope.operation.value || result.payloadLease.isNone() ||
                    result.isError!=witness.field("is_error").getOrThrow().asBool() ||
                    !managedChannelKnownIdentityMatches(witness.field("output_identity").getOrThrow(),result.output,owner,retained,guard)){
                    throw IllegalStateException("managed canonical commit changed the whole held output")}
                // This ordinary actual source verifier rereads every complete
                // plan, normal approval, handoff and own child Known Receipt.
                // No Host mutex, reconstructed Source or fake FD check runs
                // inside this canonical SQLite transaction.
                let actual=ToolResult(result.callId,result.output,isError:result.isError,receiptId:scope.operation.value,payloadLease:result.payloadLease)
                verifyManagedChannelOwnedParentTerminalInTransaction(tx,scope.source,scope.operation,scope.run,scope.thread,scope.epoch,
                    scope.plan,actual,allocate,guard,terminalKind:kind)
                if(kind=="protocol"){
                    requireManagedChannelCanonicalProtocolWrite(tx,witness.field("protocol_record").getOrThrow(),scope.operation,scope.run)
                }else if(witness.field("protocol_record").getOrThrow().unifiedKind!=ValueKind.Null){
                    throw IllegalStateException("nonprotocol terminal cannot claim a response witness")}
                let immutable=liveKnownHistoryDigest(tx,managedChannelKnownImmutableQueries(scope.operation,scope.run,scope.source.itemId(),scope.plan,owner,retained),owner,retained,guard)
                liveKnownPrepayOriginalCanonicalMutation(tx,transition,scope,owner,retained,guard)
                action()
                liveKnownRequireCanonical(tx,transition,scope,allocate,owner,retained,guard)
                if(immutable!=liveKnownHistoryDigest(tx,managedChannelKnownImmutableQueries(scope.operation,scope.run,scope.source.itemId(),scope.plan,owner,retained),owner,retained,guard)){
                    throw IllegalStateException("managed canonical commit changed its whole immutable Source/child history")}
                journalStreamCheck(guard)
                if(eligibility.witness){
                    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind=?)",
                        [SqlParameter.Text(scope.operation.value),SqlParameter.Text(MANAGED_KNOWN_CANONICAL_AUDIT)],"managed canonical witness cannot be replaced")
                    owner.ensureRetainedPeak(journalStreamAdd(retained,65536))
                    let item=transition.committedItems[0]
                    let canonical=objectValue([ValueField("schema",textValue("axyndra.managed-channel-known-parent-canonical/v1")),
                        ValueField("parent_operation_id",textValue(scope.operation.value)),ValueField("run_id",textValue(scope.run.value)),
                        ValueField("thread_id",textValue(scope.thread.value)),ValueField("epoch",integerValue(scope.epoch)),
                        ValueField("root_item_id",textValue(scope.source.itemId().value)),ValueField("root_call_id",textValue(scope.source.callId())),
                        ValueField("parent_binding_digest",textValue(scope.plan.bindingDigest)),
                        ValueField("canonical_item_id",textValue(item.id.value)),ValueField("canonical_item_ordinal",integerValue(item.ordinal)),
                        ValueField("canonical_receipt_id",textValue(transition.operationReceipt.getOrThrow().receiptId)),
                        ValueField("post_thread_revision",integerValue(transition.after.thread.revision)),
                        ValueField("through_sequence",witness.field("through_sequence").getOrThrow()),
                        ValueField("actual_terminal_audit_id",integerValue(journalStreamInteger(tx.query("SELECT id"+suffix,args)[0].required(0)))),
                        ValueField("immutable_history_sha256",textValue(immutable)),
                        ValueField("canonical_sha256",textValue(liveKnownCanonicalDigest(tx,scope.operation,scope.run,scope.thread,owner,retained,guard)))])
                    let extent=livePolicyStoredExtent(canonical)
                    owner.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*8)))
                    tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (?,?,?,?,?,?)",
                        [SqlParameter.Text(scope.thread.value),SqlParameter.Text(scope.run.value),SqlParameter.Text(scope.operation.value),
                         SqlParameter.Text(MANAGED_KNOWN_CANONICAL_AUDIT),SqlParameter.Text(encodeStoredValue(canonical)),SqlParameter.Int64Value(agentUtcMillis())])
                    requireStoreChanged(tx,"managed canonical witness was not recorded in the same transaction")
                }
            })
        })
    }finally{owner.close()}
}


// Full original length-framed history, not a newest-N prefix or a count/hash
// substitute for the actual Source, ordinary approval and Known proof.
func managedChannelKnownImmutableQueries(parent:OperationId,run:RunId,item:ItemId,plan:NormalizedOperationPlan,
    owner:LogicalJsonOwnerReservation,retained:Int64):Array<LiveKnownHistoryQuery>{
    if(plan.contextReadFacts.size>(Int64.Max-65536)/8192){throw IllegalStateException("actual source history query payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(65536,plan.contextReadFacts.size*8192)))
    let ids=[SqlParameter.Text(parent.value),SqlParameter.Text(run.value)]
    let owned="(e.operation_id=? OR e.operation_id IN (SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?))"
    let all=[SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(run.value)]
    let queries=ArrayList<LiveKnownHistoryQuery>([
        LiveKnownHistoryQuery("o.rowid"," FROM operations o WHERE o.id=? AND o.run_id=?",
            ["o.id","o.run_id","o.tool_call_item_id","o.normalized_plan"],[false,false,false,true],ids),
        LiveKnownHistoryQuery("e.rowid"," FROM operation_effect_records e WHERE "+owned+" AND e.run_id=?",
            ["e.operation_id","e.run_id","e.tool_call_item_id","e.normalized_plan","e.tool_id","e.tool_version",
             "e.implementation_fingerprint","e.schema_digest","e.effective_arguments_digest","e.replay_contract_version",
             "e.replay_disposition","e.reserved_receipt_id","e.reserved_result_item_id","e.created_at_millis"],
            [false,false,false,true,false,false,false,false,false,false,false,false,false,false],all),
        LiveKnownHistoryQuery("a.rowid"," FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id WHERE a.parent_operation_id=? AND o.run_id=?",
            ["a.operation_id","a.parent_operation_id","a.call_sequence","a.request_key","a.request_digest","a.root_operation_id","a.child_call_id","a.depth",
             "o.run_id","o.tool_call_item_id","o.state","o.revision","o.normalized_plan"],
            [false,false,false,false,false,false,false,false,false,false,false,false,true],ids),
        LiveKnownHistoryQuery("r.rowid"," FROM operation_receipts r JOIN operations o ON o.id=r.operation_id WHERE o.run_id=? AND o.id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)",
            ["r.id","r.operation_id","r.outcome","r.detail","r.verification","r.created_at_millis"],
            [false,false,false,true,true,false],[SqlParameter.Text(run.value),SqlParameter.Text(parent.value)]),
        LiveKnownHistoryQuery("s.rowid"," FROM operation_state_registers s JOIN operations o ON o.id=s.operation_id WHERE o.run_id=? AND o.id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)",
            ["s.operation_id","s.state","s.revision"],[false,false,false],[SqlParameter.Text(run.value),SqlParameter.Text(parent.value)]),
        LiveKnownHistoryQuery("a.rowid"," FROM audit_events a WHERE a.run_id=? AND (a.operation_id=? OR a.operation_id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)) AND a.kind<>?",
            ["a.id","a.thread_id","a.run_id","a.operation_id","a.kind","a.payload","a.created_at_millis","a.commit_sequence"],
            [false,false,false,false,false,true,false,false],
            [SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(MANAGED_KNOWN_CANONICAL_AUDIT)]),
        LiveKnownHistoryQuery("a.rowid"," FROM approvals a JOIN operations o ON o.id=a.operation_id WHERE o.run_id=? AND o.id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)",
            ["a.id","a.operation_id","a.operation_digest","a.capability_ceiling","a.decision","a.source","a.expires_at_millis"],
            [false,false,false,true,false,false,false],[SqlParameter.Text(run.value),SqlParameter.Text(parent.value)]),
        LiveKnownHistoryQuery("i.rowid"," FROM items i WHERE i.id=?",
            ["i.id","i.thread_id","i.turn_id","i.ordinal","i.kind","i.payload","i.provenance"],
            [false,false,false,false,false,true,true],[SqlParameter.Text(item.value)])
    ])
    // Every real ContextRead fact is preserved, including its entire Receipt,
    // audit history and both full source/result items. No fake link is used.
    for(read in plan.contextReadFacts){
        queries.add(LiveKnownHistoryQuery("o.rowid"," FROM operations o WHERE o.id=? AND o.run_id=?",
            ["o.id","o.run_id","o.tool_call_item_id","o.state","o.revision","o.normalized_plan"],
            [false,false,false,false,false,true],[SqlParameter.Text(read.operationId.value),SqlParameter.Text(read.runId.value)]))
        queries.add(LiveKnownHistoryQuery("r.rowid"," FROM operation_receipts r WHERE r.operation_id=?",
            ["r.id","r.operation_id","r.outcome","r.detail","r.verification","r.created_at_millis"],
            [false,false,false,true,true,false],[SqlParameter.Text(read.operationId.value)]))
        queries.add(LiveKnownHistoryQuery("a.rowid"," FROM audit_events a WHERE a.operation_id=? AND a.run_id=?",
            ["a.id","a.thread_id","a.run_id","a.operation_id","a.kind","a.payload","a.created_at_millis","a.commit_sequence"],
            [false,false,false,false,false,true,false,false],[SqlParameter.Text(read.operationId.value),SqlParameter.Text(read.runId.value)]))
        for(id in [read.sourceItemId.value,read.resultItemId.value]){
            queries.add(LiveKnownHistoryQuery("i.rowid"," FROM items i WHERE i.id=?",
                ["i.id","i.thread_id","i.turn_id","i.ordinal","i.kind","i.payload","i.provenance"],
                [false,false,false,false,false,true,true],[SqlParameter.Text(id)]))
        }
    }
    let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    if(httpIntentText(binding,"resource_state")=="active"){
        let startup=httpIntentText(binding,"startup_operation_id")
        queries.add(LiveKnownHistoryQuery("o.rowid"," FROM operations o WHERE o.id=?",
            ["o.id","o.run_id","o.tool_call_item_id","o.state","o.revision","o.normalized_plan"],
            [false,false,false,false,false,true],[SqlParameter.Text(startup)]))
        queries.add(LiveKnownHistoryQuery("r.rowid"," FROM operation_receipts r WHERE r.operation_id=?",
            ["r.id","r.operation_id","r.outcome","r.detail","r.verification","r.created_at_millis"],
            [false,false,false,true,true,false],[SqlParameter.Text(startup)]))
        queries.add(LiveKnownHistoryQuery("a.rowid"," FROM audit_events a WHERE a.operation_id=? AND a.kind IN "+
            "('managed_channel_resource_bound_v1','managed_channel_child_prepared_v1','operation_execution_handoff')",
            ["a.id","a.thread_id","a.run_id","a.operation_id","a.kind","a.payload","a.created_at_millis","a.commit_sequence"],
            [false,false,false,false,false,true,false,false],[SqlParameter.Text(startup)]))
    }
    queries.toArray()
}

// Metadata identity may cover both the full output and full correlated
// response. Original business codecs retain their own existing bounds.
private class ManagedTerminalStoredIdentityStream {
    private let hash=SHA256()
    private let guard:()->Result<Unit>
    private var bytes:Int64=0
    private var finished=false
    init(guard:()->Result<Unit>){this.guard=guard}
    private func add(value:Array<Byte>):Unit{
        if(finished || value.size>Int64.Max-bytes){
            throw IllegalStateException("actual complete terminal identity overflows its byte counter")}
        journalStreamCheck(guard);hash.write(value)
        bytes=journalStreamAdd(bytes,value.size);journalStreamCheck(guard)
    }
    private func text(value:String):Unit{
        journalStreamCheck(guard)
        unsafe{
            let raw=value.rawData();var at:Int64=0
            while(at<raw.size){
                let end=min(raw.size,at+65536)
                // The slice is bounded even when the actual scalar is 8 MiB.
                add(raw[at..end]);at=end
            }
        }
        journalStreamCheck(guard)
    }
    private func frame(value:String):Unit{
        text(value.size.toString());add([b':']);text(value)
    }
    func visit(value:AgentValue,depth:Int64):Unit{
        if(depth>64){throw IllegalStateException("stored value exceeds its original depth")}
        journalStreamCheck(guard)
        match(value.unifiedKind){
            case ValueKind.Null=>add([b'n'])
            case ValueKind.Boolean=>add([if(value.asBool()){b't'}else{b'f'}])
            case ValueKind.Number=>
                let raw=value.asNumberText()
                // The original StoredValue meter calls this same constructor.
                let _=numberValue(raw);add([b'd']);frame(raw)
            case ValueKind.Text=>add([b's']);frame(value.text)
            case ValueKind.List=>
                let array=value.asArray()
                if(array.size()>1000000){throw IllegalStateException("stored collection count is out of bounds")}
                add([b'l']);frame(array.size().toString())
                for(index in 0..array.size()){visit(array.get(index).getOrThrow(),depth+1)}
            case ValueKind.Object=>
                let object=value.asObject()
                if(object.size()>1000000){throw IllegalStateException("stored collection count is out of bounds")}
                add([b'o']);frame(object.size().toString())
                for(index in 0..object.size()){
                    frame(object.nameAt(index));visit(object.valueAt(index),depth+1)}
        }
        journalStreamCheck(guard)
    }
    func finish(): (Int64,String){
        if(finished){throw IllegalStateException("stored identity stream is once-only")}
        journalStreamCheck(guard);finished=true
        let digest=hash.finish();let digits="0123456789abcdef"
        let result=Array<Byte>(digest.size*2,repeat:0)
        for(index in 0..digest.size){
            let byte=Int64(digest[index]);result[index*2]=digits[byte/16];result[index*2+1]=digits[byte%16]}
        (bytes,String.fromUtf8(result))
    }
}
