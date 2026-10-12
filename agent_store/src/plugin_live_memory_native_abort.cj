package agent_store

import agent_domain.*

// Package internal resource witness. The private DB slot, actual object
// identity, original allocation and live native TX must all match. Merely
// constructing this type cannot bind that slot or grant Source/settlement.
// It carries the SAME original exception, never a parsed error or Known DTO.
class SqliteLiveMemoryNativeAbortWitness324 {
    private let database:SqliteDatabase
    private var prior:?SqliteTransaction
    private var allocation:?LogicalJsonOwnerReservation
    private var original:?Exception
    private var consumed=false
    private var retired=false
    init(database:SqliteDatabase,prior:SqliteTransaction,allocation:LogicalJsonOwnerReservation,original:Exception){
        this.database=database;this.prior=Some(prior);this.allocation=Some(allocation);this.original=Some(original)
    }
    private func current324(actual:SqliteTransaction,owner:LogicalJsonOwnerReservation):Unit{
        if(retired || prior.isNone() || allocation.isNone() || original.isNone() ||
            refEq(prior.getOrThrow(),actual) || !refEq(allocation.getOrThrow(),owner)){
            throw IllegalStateException("native-abort witness is closed, substituted or replayed outside its actual owner")}
        database.requireLiveMemoryNativeAbortRecovery324(actual,owner,this)
        prior.getOrThrow().requireClosedNativeAbortBackend324(database)
    }
    func consume324(actual:SqliteTransaction,owner:LogicalJsonOwnerReservation,
        consumeOriginal:(Exception)->Unit):Unit{
        current324(actual,owner)
        if(consumed){throw IllegalStateException("actual native-abort resource witness can be consumed only once")}
        consumed=true;consumeOriginal(original.getOrThrow());current324(actual,owner)
    }
    func requireConsumed324(actual:SqliteTransaction,owner:LogicalJsonOwnerReservation):Unit{
        current324(actual,owner)
        if(!consumed){throw IllegalStateException("new actual write transaction did not consume its native-abort resource witness")}
    }
    // Cleanup debt only; this never grants Source or consumes a witness.
    // DB uses it to preserve the first original error if re-authorization,
    // fresh BEGIN/COMMIT or later physical cleanup fails after native abort.
    func originalForCleanup325():Exception{
        if(retired || original.isNone()){throw IllegalStateException("original native-abort exception is no longer retained")}
        original.getOrThrow()
    }
    func retire324():Unit{
        retired=true;original=None<Exception>;prior=None<SqliteTransaction>;allocation=None<LogicalJsonOwnerReservation>
    }
}
class LiveMemoryNativeAbortCapture324 {
    var value:?SqliteLiveMemoryNativeAbortWitness324=None<SqliteLiveMemoryNativeAbortWitness324>
}
