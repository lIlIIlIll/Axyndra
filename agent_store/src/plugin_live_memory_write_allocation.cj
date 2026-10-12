package agent_store

import agent_domain.*

// Fixed internal numeric WRITE allocator metadata. This is not a v3 read
// fact, cache/read grant, public sequence, Native field or reusable Source.
// The one-shot actual live write proof invokes it only after the original
// Executing/approval/handoff/fullSource and actual fixed namespace append ACL.
class LiveMemoryWriteAllocation309 {
    let first:Int64
    let count:Int64
    let sequenceRow:?Int64
    let fits:Bool
    init(first:Int64,count:Int64,sequenceRow:?Int64,fits:Bool){
        this.first=first;this.count=count;this.sequenceRow=sequenceRow;this.fits=fits}
}
// Carries the exception from the actual original SQLite statement. No parsed
// error message or predicted code creates a SQLite failure or a Known state.
class LiveMemoryActualSqliteWriteFailure311 <: Exception {
    let original:Exception
    init(original:Exception){super(original.message);this.original=original}
}
func liveMemoryActualAppend311(tx:SqliteTransaction,event:LiveMemoryProposalEvent298,operation:String):Unit{
    let record=event.record.getOrThrow();let count=event.rawEnd-event.rawStart
    try{
        tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) "+
            "VALUES(?,?,?,CAST(zeroblob(?) AS TEXT),?)",[SqlParameter.Text(record.id),
            SqlParameter.Int64Value(record.revision),SqlParameter.Text(operation),SqlParameter.Int64Value(count),SqlParameter.Int64Value(record.updatedAt)])
    }catch(error:Exception){throw LiveMemoryActualSqliteWriteFailure311(error)}
}
func liveMemoryActualWriteAllocation309(tx:SqliteTransaction,count:Int64,owner:LogicalJsonOwnerReservation,
    peak:Int64,guard:()->Result<Unit>):LiveMemoryWriteAllocation309{
    if(count<1){throw IllegalStateException("original actual append has no events")}
    owner.ensureRetainedPeak(journalStreamAdd(peak,65536));journalStreamCheck(guard)
    // CAST selects only SQLite's actual signed integer conversion, never a
    // materialized raw String containing the private sequence cell. Count and
    // rowid establish its unique actual table relation under this same TX.
    let table=tx.query("SELECT MAX(id) FROM memory_events")
    let sequence=tx.query("SELECT rowid,CAST(seq AS INTEGER) FROM sqlite_sequence WHERE name='memory_events' LIMIT 2")
    if(table.size!=1 || sequence.size>1){throw IllegalStateException("actual SQLite append allocator relation is ambiguous")}
    let maximum=match(table[0][0]){case None=>0;case Some(value)=>journalStreamInteger(value)}
    let previous=if(sequence.isEmpty()){0}else{match(sequence[0][1]){case None=>0;case Some(value)=>journalStreamInteger(value)}}
    let greatest=max(0,max(maximum,previous))
    let fits=greatest<Int64.Max && count<=Int64.Max-greatest
    let row=if(sequence.isEmpty()){None<Int64>}else{Some(journalStreamInteger(sequence[0].required(0)))}
    // The zero sentinel is never emitted as an ID or used in a success fence.
    // A non-fitting original group must run its real failing INSERT within
    // the authorized TX after full input/CAS/before validation, then rollback.
    journalStreamCheck(guard);LiveMemoryWriteAllocation309(if(fits){greatest+1}else{0},count,row,fits)
}
func liveMemoryRequireActualWriteAllocation309(tx:SqliteTransaction,allocation:LiveMemoryWriteAllocation309,
    guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    if(!allocation.fits){throw IllegalStateException("non-fitting allocator cannot certify a committed group")}
    let expected=journalStreamAdd(allocation.first,allocation.count-1)
    let rows=tx.query("SELECT CAST(seq AS INTEGER) FROM sqlite_sequence WHERE name='memory_events' LIMIT 2")
    if(rows.size!=1 || journalStreamInteger(rows[0].required(0))!=expected){
        throw IllegalStateException("actual original AUTOINCREMENT post-state differs from its pre-write allocator")}
    journalStreamCheck(guard)
}
