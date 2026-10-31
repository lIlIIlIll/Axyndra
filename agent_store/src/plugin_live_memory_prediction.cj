package agent_store

import agent_domain.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

class LiveMemoryActualAppend303 {
    let eventId:Int64
    let event:LiveMemoryProposalEvent298
    init(eventId:Int64,event:LiveMemoryProposalEvent298){this.eventId=eventId;this.event=event}
}

private func liveMemoryPredictedCell303(hash:SHA256,kind:String,bytes:Int64,digest:String):Unit{
    let observed=objectValue([ValueField("type",textValue(kind)),ValueField("bytes",integerValue(bytes)),
        ValueField("sha256",textValue(digest))])
    hash.write(journalStreamFrame(canonicalAgentValue(observed)).toArray())
}

// Complete ORIGINAL v3 ignored event-cell fence, before the first mutation.
// Existing rows retain exact SQLite types/bytes/SHA and signed rowid order.
// Future entries describe their real intended SQL types and full event bytes.
// No cache, memories content, sqlite_sequence or inaccessible decoded body is
// read here. The real Source separately authorizes the actual event journal.
func liveMemoryPredictPrivateEventFence303(tx:SqliteTransaction,entries:Array<LiveMemoryActualAppend303>,
    owner:LogicalJsonOwnerReservation,retainedPeak:Int64,guard:()->Result<Unit>):JournalLatestStreamFence{
    owner.ensureRetainedPeak(journalStreamAdd(retainedPeak,1048576))
    let hash=SHA256();hash.write("axyndra.event-cells-private-fence/v3".toArray())
    var after:?Int64=None;var count:Int64=0
    while(true){
        journalStreamCheck(guard)
        let rows=match(after){
            case None=>tx.query("SELECT id FROM memory_events ORDER BY id LIMIT 1")
            case Some(previous)=>tx.query("SELECT id FROM memory_events WHERE id>? ORDER BY id LIMIT 1",[SqlParameter.Int64Value(previous)])}
        if(rows.isEmpty()){break};if(rows.size!=1){throw IllegalStateException("actual private event order is ambiguous")}
        let rowid=journalStreamInteger(rows[0].required(0));after=Some(rowid)
        hash.write(journalStreamFrame(rowid.toString()).toArray())
        for(cell in [JournalOpaqueCell.EventMemoryId,JournalOpaqueCell.EventRevision,JournalOpaqueCell.EventOperation,
            JournalOpaqueCell.EventPayload,JournalOpaqueCell.EventCreatedAt]){
            let cursor=tx.openJournalOpaqueCellOwned(cell,rowid,None,false,guard,owner,journalStreamAdd(retainedPeak,1048576))
            let value=try{while(!cursor.next().isEmpty()){};cursor.finish()}finally{cursor.close()}
            liveMemoryPredictedCell303(hash,value.sqliteType,value.bytes,value.digest)
        }
        count=journalStreamAdd(count,1)
    }
    for(entry in entries){
        journalStreamCheck(guard)
        match(after){case Some(last)=>if(entry.eventId<=last){throw IllegalStateException("actual appended event ID does not follow original signed order")};case None=>()}
        after=Some(entry.eventId)
        let record=entry.event.record.getOrThrow()
        hash.write(journalStreamFrame(entry.eventId.toString()).toArray())
        liveMemoryPredictedCell303(hash,"text",record.id.size,modelPolicySha256Text(record.id))
        let revision=record.revision.toString()
        liveMemoryPredictedCell303(hash,"integer",revision.size,modelPolicySha256Text(revision))
        let operation=entry.event.operation.getOrThrow().text
        liveMemoryPredictedCell303(hash,"text",operation.size,modelPolicySha256Text(operation))
        liveMemoryPredictedCell303(hash,"text",entry.event.rawEnd-entry.event.rawStart,entry.event.digest)
        let created=record.updatedAt.toString()
        liveMemoryPredictedCell303(hash,"integer",created.size,modelPolicySha256Text(created))
        count=journalStreamAdd(count,1)
    }
    hash.write(journalStreamFrame(count.toString()).toArray());journalStreamCheck(guard)
    JournalLatestStreamFence(count,logicalJsonEncodeHex(hash.finish()))
}
