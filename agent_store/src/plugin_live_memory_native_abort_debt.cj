package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*

// The DB mutex owns every mutation below. Each pin is derived from its
// ACTUAL original allocation group, never another pool or a guessed fee.
// The same groups stay charged when lexical Host/Store frames unwind.
class SqliteLiveMemoryNativeAbortCleanupDebt326 <: PluginLivePolicySettlementCleanupDebt326 & PluginLivePolicyOuterErrorPhysicalDebt334 {
    private let database:SqliteDatabase
    private var owner:?LogicalJsonOwnerReservation
    private var loan:?LogicalJsonOwnerReservation
    private let peak:Int64
    private var transactions=ArrayList<SqliteTransaction>()
    private var backendPins=ArrayList<LogicalJsonOwnerReservation>()
    private var original:?Exception=None<Exception>
    private var cleanup:?Exception=None<Exception>
    private var retained=false
    private var outerErrorPending331=false
    private var outerErrorData331:?PluginLivePolicyOuterErrorDataOwner331=None<PluginLivePolicyOuterErrorDataOwner331>
    private var outerErrorCopyFailure331:?Exception=None<Exception>
    private var acknowledged=false
    private let frame334:?PluginLivePolicyOuterErrorFrame334
    private var cleanupCopyOriginal334:?Exception=None<Exception>
    private var cleanupCopyFailure334:?Exception=None<Exception>
    init(database:SqliteDatabase,owner:LogicalJsonOwnerReservation,peak:Int64,
        frame!:?PluginLivePolicyOuterErrorFrame334=None<PluginLivePolicyOuterErrorFrame334>){
        match(frame){case Some(value)=>if(!value.isInvoking()){
            throw IllegalStateException("actual database debt requires its invoking paid frame")};case None=>()}
        this.frame334=frame
        this.database=database;this.owner=Some(owner);this.peak=peak
        this.loan=Some(owner.deriveRetainedLease())
    }
    func trackActualTransaction326(actual:SqliteTransaction):Unit{
        if(retained || acknowledged || owner.isNone()){
            throw IllegalStateException("actual native-abort resource scope has ended")}
        owner.getOrThrow().ensureRetainedPeak(journalStreamAdd(peak,
            journalStreamAdd(262144,liveMemoryMultiply297(transactions.size+1,1024))))
        transactions.add(actual)
    }
    func pinBackendBeforeClose326(actual:SqliteTransaction):Unit{
        if(retained || acknowledged || owner.isNone()){
            throw IllegalStateException("actual native-abort backend payment scope has ended")}
        actual.withNativeAbortBackendAllocations326(database,{allocation=>
            owner.getOrThrow().ensureRetainedPeak(journalStreamAdd(peak,
                journalStreamAdd(262144,liveMemoryMultiply297(journalStreamAdd(transactions.size,backendPins.size+1),1024))))
            backendPins.add(allocation.deriveRetainedLease())
        })
    }
    func retainFailure326(failure:Exception):Unit{
        if(retained || acknowledged || owner.isNone()){
            throw IllegalStateException("actual native-abort resource failure was retained twice")}
        // These are original typed exception objects. The complete SQLite
        // primary message was prepaid by325 before its actual witness capture;
        // the fixed cleanup envelope is within the original262KiB scope.
        match(failure as LiveMemoryRollbackCleanupFailure317){
            case Some(pair)=>original=Some(pair.original);cleanup=Some(pair.cleanup)
            case None=>original=Some(failure)
        }
        retained=true
    }
    func beginOuterErrorCopy331():Unit{database.withLiveMemoryOuterErrorDebt331(this,{=>
        if(!retained || acknowledged || outerErrorPending331 || outerErrorData331.isSome()){
            throw IllegalStateException("actual retained native-abort error cannot be copied twice")}
        // Fixed latch/copy-failure envelope belongs to original262KiB scope.
        // This precedes any derive/grow/copy that may fail under real pressure.
        outerErrorPending331=true
    })}
    func adoptOuterErrorData331(actual:PluginLivePolicyOuterErrorDataOwner331):Unit{database.withLiveMemoryOuterErrorDebt331(this,{=>
        if(!outerErrorPending331 || outerErrorData331.isSome() || acknowledged){
            throw IllegalStateException("actual paid copied error cannot substitute another resource owner")}
        match(frame334){case Some(frame)=>match(actual as SqliteLiveMemoryOuterErrorData331){
            case Some(data)=>data.retainPhysicalFrame334(frame)
            case None=>throw IllegalStateException("same actual Store copied data is required")};case None=>()}
        outerErrorData331=Some(actual);outerErrorPending331=false
    })}
    func retainOuterErrorCopyFailure331(actual:Exception):Unit{database.withLiveMemoryOuterErrorDebt331(this,{=>
        if(!outerErrorPending331 || acknowledged || outerErrorCopyFailure331.isSome()){
            throw IllegalStateException("actual error copy pressure cause cannot be substituted")}
        outerErrorCopyFailure331=Some(actual)
    })}
    private func requireOuterErrorConsumerRetirement331():Unit{
        if(outerErrorPending331){
            throw IllegalStateException("actual original error/copy-failure aliases still retain same database loan")}
        match(outerErrorData331){case Some(actual)=>
            if(!actual.isConsumerRetired()){
                throw IllegalStateException("actual complete mapped error consumer aliases are not retired")}
            case None=>()}
    }
    func hasFrame334():Bool{frame334.isSome()}
    func requirePhysicalWindow334():Unit{
        if(!retained || frame334.isNone()){return}
        if(!frame334.getOrThrow().hasReturned() || outerErrorPending331 || outerErrorData331.isNone() ||
            cleanupCopyOriginal334.isSome() || cleanupCopyFailure334.isSome()){
            throw IllegalStateException("actual copied error or returned frame still retains physical debt")}
    }
    func actualReturnedFrameMatches334(frame:PluginLivePolicyOuterErrorFrame334,
        data:PluginLivePolicyOuterErrorDataOwner331):Bool{
        if(frame334.isNone() || !refEq(frame334.getOrThrow(),frame) || !frame.hasReturned() || outerErrorPending331 ||
            outerErrorData331.isNone() || cleanupCopyOriginal334.isSome() || cleanupCopyFailure334.isSome()){return false}
        match(outerErrorData331.getOrThrow() as SqliteLiveMemoryOuterErrorData331){case Some(actual)=>
            match(data as SqliteLiveMemoryOuterErrorData331){case Some(expected)=>refEq(actual,expected);case None=>false}
            case None=>false}
    }
    public func matchesReturnedErrorFrame334(frame:PluginLivePolicyOuterErrorFrame334,
        data:PluginLivePolicyOuterErrorDataOwner331):Bool{
        database.liveMemoryReturnedErrorFrameMatches334(this,frame,data)
    }
    // DB mutex held. All new cleanup error aliases are independently copied
    // into the original error's permanent same-bank data owner BEFORE return.
    func copyCleanupFailure334(failure:Exception):Result<Unit>{
        if(frame334.isNone() || outerErrorPending331 || outerErrorData331.isNone() || loan.isNone() ||
            cleanupCopyOriginal334.isSome() || cleanupCopyFailure334.isSome()){
            return liveMemoryOuterErrorDebt331("plugin.live_cleanup_copy_pending")}
        cleanupCopyOriginal334=Some(failure)
        try{
            let original=match(outerErrorData331.getOrThrow() as SqliteLiveMemoryOuterErrorData331){
                case Some(value)=>value;case None=>throw IllegalStateException("actual complete Store data owner is required")}
            let copied=copyLiveMemoryCleanupError334(failure,loan.getOrThrow())
            original.retainCleanupData334(copied)
            cleanupCopyOriginal334=None<Exception>
            Result<Unit>.Err(copied.mappedError331())
        }catch(error:Exception){
            cleanupCopyFailure334=Some(error)
            // Original exception/copy failure remain under the actual debt;
            // no raw error copy escapes and subsequent cleanup stays closed.
            liveMemoryOuterErrorDebt331("plugin.live_cleanup_copy_pending")
        }
    }
    func closeActualBackends326():Unit{
        for(actual in transactions){
            actual.closeBackendStorage()
            actual.requireClosedNativeAbortBackend324(database)
        }
    }
    func firstError326():Exception{
        original.getOrThrow()
    }
    func retirePaidReferences326():Unit{
        if(retained && frame334.isSome()){requirePhysicalWindow334()}
        else{requireOuterErrorConsumerRetirement331()}
        // Every transaction/closure and original exception handle is cleared
        // BEFORE any actual group pin can be released. The detached ArrayList
        // below contains reservation handles only, never SQL/JSON data.
        transactions=ArrayList<SqliteTransaction>()
        original=None<Exception>;cleanup=None<Exception>;owner=None<LogicalJsonOwnerReservation>
        // Copied data (including subsequent cleanup copies and paid frame)
        // remains independently owned. This is physical-resource ACK only.
        if(frame334.isNone()){outerErrorData331=None<PluginLivePolicyOuterErrorDataOwner331>}
        outerErrorCopyFailure331=None<Exception>
        let pins=backendPins;backendPins=ArrayList<LogicalJsonOwnerReservation>()
        let selected=loan;loan=None<LogicalJsonOwnerReservation>
        for(pin in pins){pin.close()}
        match(selected){case Some(pin)=>pin.close();case None=>()}
        acknowledged=true
    }
    func actualAcknowledged326():Bool{acknowledged}
    public func closeAfterFailure():Result<Unit>{database.acknowledgeLiveMemoryNativeAbortDebt326(this)}
    public func isAcknowledged():Bool{database.liveMemoryNativeAbortDebtAcknowledged326(this)}
}
class LiveMemoryNativeAbortDebtCapture326 {
    var value:?SqliteLiveMemoryNativeAbortCleanupDebt326=None<SqliteLiveMemoryNativeAbortCleanupDebt326>
}
// Only the real DB's paid scope throws this carrier. Store can return the
// identical checked resource owner beside an outerErr; no Known is produced.
class LiveMemoryNativeAbortRetainedFailure326 <: Exception {
    let primary:Exception
    let debt:PluginLivePolicySettlementCleanupDebt326
    init(primary:Exception,debt:PluginLivePolicySettlementCleanupDebt326){
        super(primary.message);this.primary=primary;this.debt=debt
    }
}
