package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

private class LiveMemoryObservedRecord304 {
    var record:?LiveMemorySemanticRecord297=None<LiveMemorySemanticRecord297>
    var version:?LiveMemoryScalar297=None<LiveMemoryScalar297>
    var operation:?LiveMemoryScalar297=None<LiveMemoryScalar297>
    let owner:LogicalJsonOwnerReservation
    let peak:()->Int64
    init(owner:LogicalJsonOwnerReservation,peak:()->Int64){this.owner=owner;this.peak=peak}
    func begin(path:Array<String>,kind:String,start:Int64):Unit{
        if(path.isEmpty() && kind!="object"){throw IllegalStateException("original event is not an object")}
        if(path.size==1){
            if(path[0]=="record"){
                if(kind!="object"){throw IllegalStateException("original event record is not an object")}
                record=Some(LiveMemorySemanticRecord297(start,owner,peak))
            }else if(path[0]=="version"){version=Some(LiveMemoryScalar297("version",kind,owner,peak))}
            else if(path[0]=="operation"){operation=Some(LiveMemoryScalar297("operation",kind,owner,peak))}
        }else if(path.size>1 && path[0]=="record"){record.getOrThrow().begin(path,1,kind,start)}
    }
    func scalar(path:Array<String>,kind:String,raw:Array<Byte>):Unit{
        if(path.size==1 && path[0]=="version"){version.getOrThrow().append(raw)}
        else if(path.size==1 && path[0]=="operation"){operation.getOrThrow().append(raw)}
        else if(path.size>1 && path[0]=="record"){record.getOrThrow().scalar(path,1,kind,raw)}
    }
    func end(path:Array<String>,kind:String,start:Int64,end:Int64):Unit{
        if(path.size==1 && path[0]=="record"){record.getOrThrow().finish(end)}
        else if(path.size==1 && path[0]=="version"){version.getOrThrow().finish()}
        else if(path.size==1 && path[0]=="operation"){operation.getOrThrow().finish()}
        else if(path.size>1 && path[0]=="record"){record.getOrThrow().end(path,1,kind,start,end)}
    }
    func finished():LiveMemorySemanticRecord297{
        if(version.isNone() || version.getOrThrow().kind!="number" || version.getOrThrow().integer!=3 ||
            operation.isNone() || operation.getOrThrow().kind!="string" || operation.getOrThrow().text=="" || record.isNone()){
            throw IllegalStateException("original full event version/operation/record changed")}
        record.getOrThrow()
    }
}

// The constructor and SQL state are Store private and belong to this ONE
// actual executing child's transaction. The Host downcasts the real proof;
// neither Native JSON nor a public reference can construct or authorize it.
public class SqlitePluginLiveRowJournalCommitProof304 <: PluginDocumentPayloadCommitProof {
    private let tx:SqliteTransaction
    private let root:OperationRootSource
    private let parent:OperationId
    private let child:OperationId
    private let run:RunId
    private let thread:ThreadId
    private let epoch:Int64
    private let parentPlan:NormalizedOperationPlan
    private let childPlan:NormalizedOperationPlan
    private let requestKey:String
    private let callId:String
    private let expected:?ApprovalRequest
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let guard:()->Result<Unit>
    private let before:JournalLatestStreamFence
    private let backend:SqliteOpaqueRowJournalLatestStreamBackend
    private let backendCurrent:()->Result<Unit>
    private let lock=Mutex()
    private var active=true
    private var applied=false
    private var mutationStarted=false
    private var future:?JournalLatestStreamFence=None<JournalLatestStreamFence>
    public prop runId:RunId{get(){run}}
    public prop parentOperationId:OperationId{get(){parent}}
    public prop operationId:OperationId{get(){child}}
    public func payload():AgentValue{childPlan.canonicalArguments.field("proposal_payload").getOrThrow()}
    init(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
        expected:?ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
        before:JournalLatestStreamFence,backend:SqliteOpaqueRowJournalLatestStreamBackend,backendCurrent:()->Result<Unit>){
        this.tx=tx;this.root=root;this.parent=parent;this.child=child;this.run=run;this.thread=thread;this.epoch=epoch
        this.parentPlan=parentPlan;this.childPlan=childPlan;this.requestKey=requestKey;this.callId=callId;this.expected=expected
        this.allocate=allocate;this.guard=guard;this.before=before;this.backend=backend;this.backendCurrent=backendCurrent
    }
    private func atomicCurrent():Unit{journalStreamCheck(guard);journalStreamCheck(backendCurrent)}
    private func preparedCurrent():Unit{
        atomicCurrent()
        requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,
            expected,LivePolicyChildPhase.Executing,allocate,guard)
        if(!mutationStarted){
            requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
        }
    }
    private func requireMember(reference:PluginDocumentPayloadReference,owner:LogicalJsonOwnerReservation,peak:Int64):Unit{
        preparedCurrent()
        let prior=childPlan.canonicalArguments.field("prior_receipts").getOrThrow()
        let descriptor=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-step-data/v1")),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("parent_binding_digest",textValue(parentPlan.bindingDigest)),
            ValueField("prior_receipts",prior),ValueField("payloads",listValue([reference.value()]))])
        let extent=livePolicyStoredExtent(descriptor)
        owner.ensureRetainedPeak(journalStreamAdd(peak,journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),
            liveMemoryMultiply297(extent.bytes,4))))
        let encoded=encodeStoredValue(descriptor)
        if(encoded.size!=extent.bytes){throw IllegalStateException("original live member pin encoding changed")}
        livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND run_id=? "+
            "AND thread_id=? AND kind='plugin_live_policy_step_data_v1' AND payload=?)=1",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(encoded)],
            "actual child lost its complete original same-parent production pin")
        livePolicyStepPayloadMetadata(tx,reference,allocate,guard);atomicCurrent()
    }
    private func cursor(open:(Array<PluginDocumentPayloadReference>,()->Result<Unit>)->Result<PluginLivePolicyProposalCursor>,
        members:Array<PluginDocumentPayloadReference>,owner:LogicalJsonOwnerReservation,peak:Int64):PluginLivePolicyProposalCursor{
        for(member in members){requireMember(member,owner,peak)}
        match(open(members,{=>atomicCurrent();Result<Unit>.Ok(())})){
            case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(value)=>value}
    }
    private func consumeWhole(actual:PluginLivePolicyProposalCursor,bytes:Int64,digest:String,owner:LogicalJsonOwnerReservation,
        begin:(Array<String>,String,Int64)->Unit,scalar:(Array<String>,String,Array<Byte>)->Unit,
        end:(Array<String>,String,Int64,Int64)->Unit):Unit{
        try{
            let scanner=LiveProposalScanner296(bytes,digest,owner,begin,scalar,end)
            var offset:Int64=0
            while(true){atomicCurrent();let raw=match(actual.next()){
                case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(value)=>value}
                if(raw.isEmpty()){break};scanner.append(offset,raw);offset=journalStreamAdd(offset,raw.size)}
            let _=scanner.finish();journalStreamCheck({=>actual.finish()});atomicCurrent()
        }finally{journalStreamCheck({=>actual.close()})}
    }
    private func currentRecord(entry:JournalLatestViewEntry,owner:LogicalJsonOwnerReservation,peak:Int64):LiveMemorySemanticRecord297{
        let data=LiveMemoryObservedRecord304(owner,{=>peak})
        let raw=tx.openJournalOpaqueCellOwned(JournalOpaqueCell.EventPayload,entry.lastRowid,Some(entry.payload),true,
            guard,owner,journalStreamAdd(peak,4194304))
        consumeWhole(LiveMemorySqliteEventCursor300(raw),entry.payload.bytes,entry.payload.digest,owner,
            {path,kind,start=>data.begin(path,kind,start)},{path,kind,bytes=>data.scalar(path,kind,bytes)},
            {path,kind,start,end=>data.end(path,kind,start,end)})
        data.finished()
    }
    private func compareExpected(group:LiveMemoryProposalGroup298,manifest:AgentValue,members:Array<PluginDocumentPayloadReference>,
        open:(Array<PluginDocumentPayloadReference>,()->Result<Unit>)->Result<PluginLivePolicyProposalCursor>,
        owner:LogicalJsonOwnerReservation,peak:Int64):Unit{
        match(group.expected){case None=>return;case Some(expectedRecord)=>
            let matches=AtomicInt64(0)
            backend.withActualLatest304(tx,thread.value,guard,{entry,observed=>
                // Descriptive extent/SHA merely select candidates. The original
                // private event grouping already compared every decoded ID.
                if(observed.key.kind=="string" && observed.key.bytes==expectedRecord.id.size &&
                    observed.key.digest==modelPolicySha256Text(expectedRecord.id)){
                    let recordOwner=owner.deriveRetainedLease()
                    try{
                        recordOwner.ensureRetainedPeak(journalStreamAdd(peak,4194304))
                        let actual=currentRecord(entry,recordOwner,peak)
                        var same=actual.sameNormalizedNumbers(expectedRecord)
                        for(name in ["id","kind","scopeKind","scopeKey","content","context","source","status",
                            "correctionOf","replacementId","conflictReason","deletionReason","conflictIds"]){
                            let left=cursor(open,members,owner,peak)
                            var right:?PluginLivePolicyProposalCursor=None<PluginLivePolicyProposalCursor>
                            try{
                                right=Some(LiveMemorySqliteEventCursor300(tx.openJournalOpaqueCellOwned(
                                    JournalOpaqueCell.EventPayload,entry.lastRowid,Some(entry.payload),true,guard,recordOwner,
                                    journalStreamAdd(peak,4194304))))
                                let equal=liveMemoryExactFieldEqual300(left,journalStreamInteger(manifest.field("total_bytes").getOrThrow().asNumberText()),
                                    httpIntentText(manifest,"sha256"),["expected_record"],right.getOrThrow(),entry.payload.bytes,
                                    entry.payload.digest,["record"],name,owner,guard)
                                if(!equal){same=false}
                            }finally{
                                // Idempotent checked close also covers construction
                                // failures before the comparison acquired both.
                                let lc=left.close();let rc=match(right){case Some(value)=>value.close();case None=>Result<Unit>.Ok(())}
                                journalStreamCheck({=>lc});journalStreamCheck({=>rc})
                            }
                        }
                        if(same && matches.fetchAdd(1)!=0){throw IllegalStateException("original expected record has more than one actual latest match")}
                    }finally{recordOwner.close()}
                }
            })
            if(matches.load()!=1){throw IllegalStateException("memory expected record changed")}
        }
    }
    private func rangePass(members:Array<PluginDocumentPayloadReference>,manifest:AgentValue,event:LiveMemoryProposalEvent298,
        open:(Array<PluginDocumentPayloadReference>,()->Result<Unit>)->Result<PluginLivePolicyProposalCursor>,
        owner:LogicalJsonOwnerReservation,peak:Int64,send:?(Int64,Array<Byte>)->Unit):String{
        let actual=cursor(open,members,owner,peak)
        try{
            let whole=SHA256();let selected=SHA256();var offset:Int64=0;var copied:Int64=0
            let bytes=journalStreamInteger(manifest.field("total_bytes").getOrThrow().asNumberText())
            while(true){atomicCurrent();let raw=match(actual.next()){
                case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(value)=>value}
                if(raw.isEmpty()){break}
                if(raw.size>65536 || raw.size>bytes-offset){throw IllegalStateException("actual full proposal range lost its complete ordered bytes")}
                whole.write(raw)
                let begin=max(event.rawStart,offset);let end=min(event.rawEnd,journalStreamAdd(offset,raw.size))
                if(end>begin){let fragment=raw[(begin-offset)..(end-offset)];selected.write(fragment)
                    match(send){case Some(consume)=>consume(copied,fragment);case None=>()};copied=journalStreamAdd(copied,fragment.size)}
                offset=journalStreamAdd(offset,raw.size)
            }
            if(offset!=bytes || copied!=event.rawEnd-event.rawStart || logicalJsonEncodeHex(whole.finish())!=httpIntentText(manifest,"sha256")){
                throw IllegalStateException("actual event range did not consume complete proposal EOF/SHA")}
            journalStreamCheck({=>actual.finish()});let digest=logicalJsonEncodeHex(selected.finish());atomicCurrent();digest
        }finally{journalStreamCheck({=>actual.close()})}
    }
    public func materialize(readIndex:LivePolicyHistoricalIndexReader,
        open:(Array<PluginDocumentPayloadReference>,()->Result<Unit>)->Result<PluginLivePolicyProposalCursor>,
        metadataOwner:LogicalJsonOwnerReservation,metadataPeak:Int64):Result<Unit>{
        lock.lock()
        try{
            if(!active || metadataPeak<1){return documentPayloadError("plugin.live_journal_commit_closed")};active=false
            preparedCurrent()
            let reference=parsePluginDocumentPayloadReference(payload()).value().getOrThrow()
            requireMember(reference,metadataOwner,metadataPeak)
            let visits=AtomicInt64(0)
            let copied=match(readIndex(reference,guard,{index=>
                if(visits.fetchAdd(1)!=0){throw IllegalStateException("actual full index was loaned more than once")}
                let manifest=livePolicyHistoricalIndexManifest(index)
                let rows=index.field("payloads").getOrThrow().items
                metadataOwner.ensureRetainedPeak(journalStreamAdd(metadataPeak,journalStreamAdd(8388608,
                    liveMemoryMultiply297(rows.size,8192))))
                let members=rows.toArray().map{row=>parsePluginDocumentPayloadReference(row).value().getOrThrow()}
                let group=LiveMemoryProposalGroup298(metadataOwner,metadataPeak)
                consumeWhole(cursor(open,members,metadataOwner,metadataPeak),
                    journalStreamInteger(manifest.field("total_bytes").getOrThrow().asNumberText()),httpIntentText(manifest,"sha256"),metadataOwner,
                    {path,kind,start=>group.begin(path,kind,start)},{path,kind,bytes=>group.scalar(path,kind,bytes)},
                    {path,kind,start,end=>group.end(path,kind,start,end)})
                let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
                group.finish(sequence);for(member in members){requireMember(member,metadataOwner,metadataPeak)}
                let binding=childPlan.canonicalArguments.field("binding").getOrThrow()
                for(event in group.events){requireRowJournalAppendAccess(tx,binding,httpIntentText(childPlan.canonicalArguments.field("effect").getOrThrow(),"key"),
                    event.record.getOrThrow().accessLabels())}
                compareExpected(group,manifest,members,open,metadataOwner,metadataPeak)
                // This NEW internal seam belongs to the actual independently
                // authorized WRITE proof above. The v3 events-only read never
                // gains sqlite_sequence, cache or another metadata read scope.
                preparedCurrent()
                let allocation=liveMemoryActualWriteAllocation309(tx,group.events.size,metadataOwner,metadataPeak,guard)
                for(event in group.events){event.digest=rangePass(members,manifest,event,open,metadataOwner,metadataPeak,None)}
                if(!before.same(liveMemoryPredictPrivateEventFence303(tx,[],metadataOwner,metadataPeak,guard))){
                    throw IllegalStateException("actual complete before-event fence changed")}
                if(!allocation.fits){
                    // Failure-only lane: every original group byte, grammar,
                    // member closeACK, scope/CAS and complete before fence is
                    // verified already. There is no representable future ID
                    // group. Original INSERTs alone raise SQLite's own error;
                    // their partial rows roll back and can never yield a tip.
                    preparedCurrent();mutationStarted=true
                    for(event in group.events){atomicCurrent();liveMemoryActualAppend311(tx,event,group.operation)}
                    throw IllegalStateException("actual SQLite unexpectedly accepted an exhausted AUTOINCREMENT group")
                }
                var nextId=allocation.first
                let entries=ArrayList<LiveMemoryActualAppend303>()
                for(event in group.events){
                    entries.add(LiveMemoryActualAppend303(nextId,event))
                    if(entries.size<group.events.size){nextId=journalStreamAdd(nextId,1)}
                }
                let predicted=liveMemoryPredictPrivateEventFence303(tx,entries.toArray(),metadataOwner,metadataPeak,guard)
                preparedCurrent();mutationStarted=true
                for(entry in entries){let event=entry.event;let record=event.record.getOrThrow();let count=event.rawEnd-event.rawStart
                    liveMemoryActualAppend311(tx,event,group.operation)
                    requireStoreChanged(tx,"actual live event insertion lost its exact transaction")
                    let actualId=tx.query("SELECT last_insert_rowid()")
                    if(actualId.size!=1 || journalStreamInteger(actualId[0].required(0))!=entry.eventId){
                        throw IllegalStateException("actual original AUTOINCREMENT differs from its pre-write allocator")}
                    let _=tx.writeFixedJournalText(FixedJournalWritableCell.EventPayload,entry.eventId,count,event.digest,guard,allocate,{consume=>
                        let actual=rangePass(members,manifest,event,open,metadataOwner,metadataPeak,Some(consume))
                        if(actual!=event.digest){throw IllegalStateException("actual event bytes changed after prediction")}})
                    // The authorized append performs the original blind cache
                    // replacement. It obtains no cache read/sequence permission.
                    tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,?,CAST(zeroblob(?) AS TEXT),?) "+
                        "ON CONFLICT(id) DO UPDATE SET thread_id=NULL,kind=excluded.kind,payload=excluded.payload,revision=excluded.revision",
                        [SqlParameter.Text(record.id),SqlParameter.Text(record.kind),SqlParameter.Int64Value(count),SqlParameter.Int64Value(record.revision)])
                    requireStoreChanged(tx,"actual live touched-cache write was not applied")
                    let cache=tx.query("SELECT rowid FROM memories WHERE id=?",[SqlParameter.Text(record.id)])
                    if(cache.size!=1){throw IllegalStateException("actual blind touched-cache row is not unique")}
                    let _=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,journalStreamInteger(cache[0].required(0)),
                        count,event.digest,guard,allocate,{consume=>
                            let actual=rangePass(members,manifest,event,open,metadataOwner,metadataPeak,Some(consume))
                            if(actual!=event.digest){throw IllegalStateException("actual cache bytes changed after prediction")}})
                }
                let actual=backend.fullOwned(tx,guard,metadataOwner,metadataPeak)
                if(!actual.same(predicted)){throw IllegalStateException("actual complete post-event cells differ from the pre-write prediction")}
                liveMemoryRequireActualWriteAllocation309(tx,allocation,guard)
                future=Some(predicted);atomicCurrent()
            })){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(value)=>value}
            if(visits.load()!=1 || copied[0]!=reference.bytes || copied[1]!=reference.digest || future.isNone()){
                throw IllegalStateException("actual complete index/FD close acknowledgement changed")}
            requireMember(reference,metadataOwner,metadataPeak);applied=true;Result.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:LiveMemoryActualSqliteWriteFailure311){
            // Preserve the same original transaction error kind, code, text
            // and operation field, not parameter-invalid or synthetic Known.
            operationStoreError("plugin.live_parent_transaction_unverified",parent,error.original)}
        catch(_:Exception){documentPayloadError("plugin.live_journal_append_unverified")}
        finally{lock.unlock()}
    }
    // Explicit unused native-abort materializer; every original full proposal,
    // all nineteen semantic/CAS/access fields, two passes, FD ACK and private
    // five-cell fences are the identical original one-shot algorithm.
    public func materializeForNativeAbortRecovery324(readIndex:LivePolicyHistoricalIndexReader,
        open:(Array<PluginDocumentPayloadReference>,()->Result<Unit>)->Result<PluginLivePolicyProposalCursor>,
        metadataOwner:LogicalJsonOwnerReservation,metadataPeak:Int64):Result<Unit>{
        lock.lock()
        try{
            if(!active || metadataPeak<1){return documentPayloadError("plugin.live_journal_commit_closed")};active=false
            preparedCurrent()
            let reference=parsePluginDocumentPayloadReference(payload()).value().getOrThrow()
            requireMember(reference,metadataOwner,metadataPeak)
            let visits=AtomicInt64(0)
            let copied=match(readIndex(reference,guard,{index=>
                if(visits.fetchAdd(1)!=0){throw IllegalStateException("actual full index was loaned more than once")}
                let manifest=livePolicyHistoricalIndexManifest(index)
                let rows=index.field("payloads").getOrThrow().items
                metadataOwner.ensureRetainedPeak(journalStreamAdd(metadataPeak,journalStreamAdd(8388608,
                    liveMemoryMultiply297(rows.size,8192))))
                let members=rows.toArray().map{row=>parsePluginDocumentPayloadReference(row).value().getOrThrow()}
                let group=LiveMemoryProposalGroup298(metadataOwner,metadataPeak)
                consumeWhole(cursor(open,members,metadataOwner,metadataPeak),
                    journalStreamInteger(manifest.field("total_bytes").getOrThrow().asNumberText()),httpIntentText(manifest,"sha256"),metadataOwner,
                    {path,kind,start=>group.begin(path,kind,start)},{path,kind,bytes=>group.scalar(path,kind,bytes)},
                    {path,kind,start,end=>group.end(path,kind,start,end)})
                let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
                group.finish(sequence);for(member in members){requireMember(member,metadataOwner,metadataPeak)}
                let binding=childPlan.canonicalArguments.field("binding").getOrThrow()
                for(event in group.events){requireRowJournalAppendAccess(tx,binding,httpIntentText(childPlan.canonicalArguments.field("effect").getOrThrow(),"key"),
                    event.record.getOrThrow().accessLabels())}
                compareExpected(group,manifest,members,open,metadataOwner,metadataPeak)
                // This NEW internal seam belongs to the actual independently
                // authorized WRITE proof above. The v3 events-only read never
                // gains sqlite_sequence, cache or another metadata read scope.
                preparedCurrent()
                let allocation=liveMemoryActualWriteAllocation309(tx,group.events.size,metadataOwner,metadataPeak,guard)
                for(event in group.events){event.digest=rangePass(members,manifest,event,open,metadataOwner,metadataPeak,None)}
                if(!before.same(liveMemoryPredictPrivateEventFence303(tx,[],metadataOwner,metadataPeak,guard))){
                    throw IllegalStateException("actual complete before-event fence changed")}
                if(!allocation.fits){
                    // Failure-only lane: every original group byte, grammar,
                    // member closeACK, scope/CAS and complete before fence is
                    // verified already. There is no representable future ID
                    // group. Original INSERTs alone raise SQLite's own error;
                    // their partial rows roll back and can never yield a tip.
                    preparedCurrent();mutationStarted=true
                    for(event in group.events){atomicCurrent();liveMemoryActualAppend311(tx,event,group.operation)}
                    throw IllegalStateException("actual SQLite unexpectedly accepted an exhausted AUTOINCREMENT group")
                }
                var nextId=allocation.first
                let entries=ArrayList<LiveMemoryActualAppend303>()
                for(event in group.events){
                    entries.add(LiveMemoryActualAppend303(nextId,event))
                    if(entries.size<group.events.size){nextId=journalStreamAdd(nextId,1)}
                }
                let predicted=liveMemoryPredictPrivateEventFence303(tx,entries.toArray(),metadataOwner,metadataPeak,guard)
                preparedCurrent();mutationStarted=true
                for(entry in entries){let event=entry.event;let record=event.record.getOrThrow();let count=event.rawEnd-event.rawStart
                    liveMemoryActualAppend311(tx,event,group.operation)
                    requireStoreChanged(tx,"actual live event insertion lost its exact transaction")
                    let actualId=tx.query("SELECT last_insert_rowid()")
                    if(actualId.size!=1 || journalStreamInteger(actualId[0].required(0))!=entry.eventId){
                        throw IllegalStateException("actual original AUTOINCREMENT differs from its pre-write allocator")}
                    let _=tx.writeFixedJournalText(FixedJournalWritableCell.EventPayload,entry.eventId,count,event.digest,guard,allocate,{consume=>
                        let actual=rangePass(members,manifest,event,open,metadataOwner,metadataPeak,Some(consume))
                        if(actual!=event.digest){throw IllegalStateException("actual event bytes changed after prediction")}})
                    // The authorized append performs the original blind cache
                    // replacement. It obtains no cache read/sequence permission.
                    tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,?,CAST(zeroblob(?) AS TEXT),?) "+
                        "ON CONFLICT(id) DO UPDATE SET thread_id=NULL,kind=excluded.kind,payload=excluded.payload,revision=excluded.revision",
                        [SqlParameter.Text(record.id),SqlParameter.Text(record.kind),SqlParameter.Int64Value(count),SqlParameter.Int64Value(record.revision)])
                    requireStoreChanged(tx,"actual live touched-cache write was not applied")
                    let cache=tx.query("SELECT rowid FROM memories WHERE id=?",[SqlParameter.Text(record.id)])
                    if(cache.size!=1){throw IllegalStateException("actual blind touched-cache row is not unique")}
                    let _=tx.writeFixedJournalText(FixedJournalWritableCell.CurrentPayload,journalStreamInteger(cache[0].required(0)),
                        count,event.digest,guard,allocate,{consume=>
                            let actual=rangePass(members,manifest,event,open,metadataOwner,metadataPeak,Some(consume))
                            if(actual!=event.digest){throw IllegalStateException("actual cache bytes changed after prediction")}})
                }
                let actual=backend.fullOwned(tx,guard,metadataOwner,metadataPeak)
                if(!actual.same(predicted)){throw IllegalStateException("actual complete post-event cells differ from the pre-write prediction")}
                liveMemoryRequireActualWriteAllocation309(tx,allocation,guard)
                future=Some(predicted);atomicCurrent()
            })){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(value)=>value}
            if(visits.load()!=1 || copied[0]!=reference.bytes || copied[1]!=reference.digest || future.isNone()){
                throw IllegalStateException("actual complete index/FD close acknowledgement changed")}
            requireMember(reference,metadataOwner,metadataPeak);applied=true;Result.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:LiveMemoryActualSqliteWriteFailure311){
            // New explicit lane only: keep the real original INSERT exception
            // typed through the paid Host frames into SAME locked DB recovery.
            // The ordinary materialize method above remains exactly original.
            throw error}
        catch(_:Exception){documentPayloadError("plugin.live_journal_append_unverified")}
        finally{lock.unlock()}
    }
    func appliedFuture():JournalLatestStreamFence{
        lock.lock();try{if(!applied || future.isNone()){throw IllegalStateException("actual live commit proof did not apply")};future.getOrThrow()}finally{lock.unlock()}}
    func close():Unit{lock.lock();try{active=false}finally{lock.unlock()}}
}
