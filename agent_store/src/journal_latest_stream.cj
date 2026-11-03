package agent_store

import agent_domain.*
import std.collection.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

class JournalLatestStreamFence {
    let events:Int64
    let digest:String
    init(events:Int64,digest:String){this.events=events;this.digest=digest}
    func same(other:JournalLatestStreamFence):Bool{events==other.events && digest==other.digest}
}

// The full ignored SQL metadata fence is private to Store. It is not a public
// AgentValue and cannot be placed in a stream header/result by this type.
// Read facts describe history and its mechanically derived latest view. A
// touched-cache write must obtain its separate actually authorized cache fact;
// neither cache decoding nor sqlite_sequence participates in these reads.
class JournalLatestStreamStorage {
    private let access:RowJournalStructuralAccess
    private let view:RowJournalLatestView
    private let latest:JournalLatestViewStorage
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    init(access:RowJournalStructuralAccess,view:RowJournalLatestView,workspace:String,
        allocate:(Int64)->LogicalJsonOwnerReservation){
        this.access=access;this.view=view;this.allocate=allocate
        this.latest=JournalLatestViewStorage(access,view,workspace,allocate)
    }
    private func next(tx:SqliteTransaction,after:?Int64):?Int64{
        let rows=match(after){
            case None=>tx.query("SELECT id FROM memory_events ORDER BY id LIMIT 1")
            case Some(previous)=>tx.query("SELECT id FROM memory_events WHERE id>? ORDER BY id LIMIT 1",[SqlParameter.Int64Value(previous)])}
        if(rows.isEmpty()){return None}
        if(rows.size!=1){throw IllegalStateException("fixed actual journal event order is ambiguous")}
        Some(journalStreamInteger(rows[0].required(0)))
    }
    func fence(tx:SqliteTransaction,guard:()->Result<Unit>):JournalLatestStreamFence{
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576)
            let hash=SHA256();hash.write("axyndra.event-cells-private-fence/v3".toArray())
            var after:?Int64=None;var count:Int64=0
            while(true){
                journalStreamCheck(guard)
                let following=next(tx,after);if(following.isNone()){break}
                let rowid=following.getOrThrow();after=Some(rowid)
                hash.write(journalStreamFrame(rowid.toString()).toArray())
                for(cell in [JournalOpaqueCell.EventMemoryId,JournalOpaqueCell.EventRevision,
                    JournalOpaqueCell.EventOperation,JournalOpaqueCell.EventPayload,JournalOpaqueCell.EventCreatedAt]){
                    let observed=latest.opaque(tx,cell,rowid,false,guard)
                    let value=objectValue([ValueField("type",textValue(observed.sqliteType)),
                        ValueField("bytes",integerValue(observed.bytes)),ValueField("sha256",textValue(observed.digest))])
                    hash.write(journalStreamFrame(canonicalAgentValue(value)).toArray())
                }
                count=journalStreamAdd(count,1)
            }
            hash.write(journalStreamFrame(count.toString()).toArray());journalStreamCheck(guard)
            JournalLatestStreamFence(count,logicalJsonEncodeHex(hash.finish()))
        }finally{owner.close()}
    }
    // Full original cell/type/row-order/hash/current/EOF semantics; only
    // the physical ownership transport shares this real lexical reservation.
    func fenceOwned(tx:SqliteTransaction,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):JournalLatestStreamFence{
        if(extraRetained<0){throw IllegalStateException("full fence retained peak is negative")}
        let retained=journalStreamAdd(extraRetained,1048576)
        try{
            owner.ensureRetainedPeak(retained)
            let hash=SHA256();hash.write("axyndra.event-cells-private-fence/v3".toArray())
            var after:?Int64=None;var count:Int64=0
            while(true){
                journalStreamCheck(guard)
                let following=next(tx,after);if(following.isNone()){break}
                let rowid=following.getOrThrow();after=Some(rowid)
                hash.write(journalStreamFrame(rowid.toString()).toArray())
                for(cell in [JournalOpaqueCell.EventMemoryId,JournalOpaqueCell.EventRevision,
                    JournalOpaqueCell.EventOperation,JournalOpaqueCell.EventPayload,JournalOpaqueCell.EventCreatedAt]){
                    let cursor=tx.openJournalOpaqueCellOwned(cell,rowid,None,false,guard,owner,retained)
                    let observed=try{while(!cursor.next().isEmpty()){};cursor.finish()}finally{cursor.close()}
                    let value=objectValue([ValueField("type",textValue(observed.sqliteType)),
                        ValueField("bytes",integerValue(observed.bytes)),ValueField("sha256",textValue(observed.digest))])
                    hash.write(journalStreamFrame(canonicalAgentValue(value)).toArray())
                }
                count=journalStreamAdd(count,1)
            }
            hash.write(journalStreamFrame(count.toString()).toArray());journalStreamCheck(guard)
            JournalLatestStreamFence(count,logicalJsonEncodeHex(hash.finish()))
        }finally{}
    }

    // Same original actual events-derived latest relation; no business
    // retrieval/ranking/reducer algorithm and no caller-selected backend.
    func withActualLatest304(tx:SqliteTransaction,thread:String,guard:()->Result<Unit>,
        consume:(JournalLatestViewEntry,JournalLatestViewObserved)->Unit):Unit{
        latest.latest(tx,thread,guard,consume)
    }

    private func raw(tx:SqliteTransaction,rowid:Int64,payload:JournalOpaqueCellObservation,
        guard:()->Result<Unit>,emitter:JournalStreamV2Emitter):Unit{
        let cursor=tx.openJournalOpaqueCell(JournalOpaqueCell.EventPayload,rowid,Some(payload),true,guard,allocate)
        try{
            while(true){let bytes=cursor.next();if(bytes.isEmpty()){break};emitter.write(bytes)}
            let _=cursor.finish()
        }finally{cursor.close()}
    }
    private func event(tx:SqliteTransaction,rowid:Int64,ordinal:Int64,observed:JournalLatestViewObserved,
        guard:()->Result<Unit>,emitter:JournalStreamV2Emitter):Unit{
        if(observed.readable){
            emitter.header(objectValue([ValueField("kind",textValue("event")),ValueField("ordinal",integerValue(ordinal)),
                ValueField("visibility",textValue("raw")),ValueField("body_bytes",integerValue(observed.payload.bytes)),
                ValueField("body_sha256",textValue(observed.payload.digest))]))
            raw(tx,rowid,observed.payload,guard,emitter)
        }else{
            let body=stringifyUnifiedJson(observed.projection.value)
            if(body.size<1 || body.size>16384){throw IllegalStateException("approved structural event projection exceeds its fixed header bound")}
            emitter.header(objectValue([ValueField("kind",textValue("event")),ValueField("ordinal",integerValue(ordinal)),
                ValueField("visibility",textValue("projection")),ValueField("body_bytes",integerValue(body.size)),
                ValueField("body_sha256",textValue(modelPolicySha256Text(body)))]))
            emitter.write(body.toArray())
        }
    }
    func emit(tx:SqliteTransaction,thread:String,request:AgentValue,annotations:AgentValue,
        observedFence:JournalLatestStreamFence,guard:()->Result<Unit>,consume:?(Int64,Array<Byte>)->Unit):FixedJournalCellObservation{
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576)
            let emitter=JournalStreamV2Emitter(consume,guard)
            emitter.write("AXYNDRJ3\n".toArray())
            // Public revision is based only on the complete event projections
            // which this actual read purpose explicitly authorizes. No cache,
            // ignored-column hash, private group association or seq leaks out.
            emitter.header(objectValue([ValueField("kind",textValue("start")),
                ValueField("schema",textValue("axyndra.row-journal-frames/v3")),ValueField("body_bytes",integerValue(0)),
                ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
                ValueField("access_policy_digest",textValue(access.digest)),ValueField("view_policy_digest",textValue(view.digest)),
                ValueField("revision",integerValue(journalStreamAdd(observedFence.events,1))),ValueField("annotations",annotations)]))
            var after:?Int64=None;var ordinal:Int64=0;var rawEvents:Int64=0
            while(true){
                journalStreamCheck(guard)
                let following=next(tx,after);if(following.isNone()){break}
                let rowid=following.getOrThrow();after=Some(rowid)
                let observed=latest.observe(tx,rowid,thread,guard)
                try{
                    event(tx,rowid,ordinal,observed,guard,emitter)
                    if(observed.readable){rawEvents=journalStreamAdd(rawEvents,1)}
                    ordinal=journalStreamAdd(ordinal,1)
                }finally{observed.close()}
            }
            if(ordinal!=observedFence.events){throw IllegalStateException("public history lost one actually authorized structural event")}
            let rows=JournalLatestStreamRowCounter()
            latest.latest(tx,thread,guard,{entry,observed=>
                emitter.header(objectValue([ValueField("kind",textValue("row")),ValueField("ordinal",integerValue(rows.value)),
                    ValueField("visibility",textValue("raw")),ValueField("body_bytes",integerValue(observed.payload.bytes)),
                    ValueField("body_sha256",textValue(observed.payload.digest))]))
                raw(tx,entry.lastRowid,observed.payload,guard,emitter)
                rows.value=journalStreamAdd(rows.value,1)})
            emitter.header(objectValue([ValueField("kind",textValue("end")),ValueField("body_bytes",integerValue(0)),
                ValueField("events",integerValue(ordinal)),ValueField("rows",integerValue(rows.value)),
                ValueField("raw_events",integerValue(rawEvents))]))
            journalStreamCheck(guard)
            // All columns, not a Native-provided scalar/hash/identity, recheck
            // the same actual TX after every public byte has been produced.
            if(!observedFence.same(fence(tx,guard))){throw IllegalStateException("actual private journal fence changed during emission")}
            FixedJournalCellObservation(emitter.bytes,emitter.digest())
        }finally{owner.close()}
    }
}
class JournalLatestStreamRowCounter {var value:Int64=0}
