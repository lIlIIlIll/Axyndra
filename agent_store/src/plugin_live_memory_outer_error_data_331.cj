package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.collection.*

// Exact Store operationStoreError mapping only: all eight AgentError fields
// survive. That original mapper sets both attachments None. No arbitrary
// attachment getter/writer/stringification or new size/schema cap is used.
class SqliteLiveMemoryOuterErrorData331 <: PluginLivePolicyPaidOuterErrorSource333 {
    private let lock=Mutex()
    private let payment:LogicalJsonOwnerReservation
    private var data:?AgentError
    private var borrowed=false
    private let consumers333=ArrayList<SqliteLiveMemoryOuterErrorConsumer333>()
    private var physicalFrame334:?PluginLivePolicyOuterErrorFrame334=None<PluginLivePolicyOuterErrorFrame334>
    private let cleanupData334=ArrayList<SqliteLiveMemoryOuterErrorData331>()
    init(payment:LogicalJsonOwnerReservation,error:AgentError){
        this.payment=payment;this.data=Some(error)
    }
    func retainPhysicalFrame334(frame:PluginLivePolicyOuterErrorFrame334):Unit{
        lock.lock();try{
            if(physicalFrame334.isSome() || !frame.isInvoking()){
                throw IllegalStateException("actual copied error cannot change its original invoking frame")}
            physicalFrame334=Some(frame)
        }finally{lock.unlock()}
    }
    func retainCleanupData334(actual:SqliteLiveMemoryOuterErrorData331):Unit{
        lock.lock();try{cleanupData334.add(actual)}finally{lock.unlock()}
    }
    func mappedError331():AgentError{lock.lock();try{data.getOrThrow()}finally{lock.unlock()}}
    public func matchesError(actual:AgentError):Bool{lock.lock();try{
        match(data){case Some(value)=>refEq(value,actual);case None=>false}
    }finally{lock.unlock()}}
    private func errorFrame331(consume:(AgentError)->Result<Unit>):Result<Unit>{
        try{consume(data.getOrThrow())}
        catch(_:Exception){liveMemoryOuterErrorDebt331("plugin.live_error_consumer_failed")}
    }
    public func withError(consume:(AgentError)->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(borrowed || data.isNone()){
                return liveMemoryOuterErrorDebt331("plugin.live_error_borrow_pending")}
            borrowed=true
        }finally{lock.unlock()}
        let returned=errorFrame331(consume)
        lock.lock();try{borrowed=false}finally{lock.unlock()}
        // Caller may still hold error.message, fields, raw Result, snapshots,
        // describe() output or emitted events. Returning proves no retirement.
        returned
    }
    public func withPaidError333(consume:(AgentError,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>{
        lock.lock()
        let actual:SqliteLiveMemoryOuterErrorConsumer333=try{
            if(borrowed || data.isNone()){
                return ownedOuterErrorConsumerError333("run.owned_outer_error_borrow_pending")}
            // Publish the same-bank child before user code can retain aliases.
            // Neither success nor throw below removes it from this real owner.
            let value=retainLiveMemoryOuterErrorConsumer333(data.getOrThrow(),payment)
            consumers333.add(value);value
        }catch(_:Exception){return ownedOuterErrorConsumerError333("run.owned_outer_error_capacity")}
        finally{lock.unlock()}
        actual.consume(consume)
    }
    public func isConsumerRetired():Bool{false}
    public func closeAfterConsumerRetirement():Result<Unit>{
        // No issuer or Boolean acknowledgement exists in this SOURCE_ONLY
        // hook. The actual payment/data stay held by Store+Host+Kernel debt.
        liveMemoryOuterErrorDebt331("plugin.live_error_external_aliases_pending")
    }
}

func liveMemoryOuterErrorDebt331(code:String):Result<Unit>{Result.Err(AgentError(
    AgentErrorKind.RecoveryRequired,code,"complete mapped outer error aliases retain their actual original-bank payment"))}

func copyLiveMemoryMappedOuterError331(original:Exception,parent:OperationId,
    loan:LogicalJsonOwnerReservation):SqliteLiveMemoryOuterErrorData331{
    let code="plugin.live_parent_transaction_unverified"
    // Measure original typed backing BEFORE mapper trim or copy. Four live
    // full scalar backings cover trim temporary, mapper input, copied Byte
    // array and copied String; original exception/backend loan stays separate.
    // Every field string/array/owner/borrow/carrier cell is summed, not maxed.
    let bytes=journalStreamAdd(original.message.size,journalStreamAdd(code.size,
        journalStreamAdd(parent.value.size,256)))
    let invoice=journalStreamAdd(8192,liveMemoryMultiply297(bytes,4))
    let payment=loan.deriveRetainedLease()
    var transferred=false
    try{
        payment.ensureRetainedPeak(invoice)
        let mapped=match(operationStoreError<Unit>(code,parent,original)){
            case Result.Err(value)=>value
            case Result.Ok(_)=>throw IllegalStateException("actual original error mapper must remain an error")}
        if(mapped.attemptFailure.isSome() || mapped.observation.isSome()){
            throw IllegalStateException("original Store error mapping unexpectedly has an attachment")}
        // Each complete copied String is independent of the original SQLite
        // Exception backing. Payment remains alive throughout this helper.
        let fields=Array<ErrorField>(mapped.fields.size,{i=>ErrorField(
            String.fromUtf8(mapped.fields[i].name.toArray()),
            String.fromUtf8(mapped.fields[i].value.toArray()))})
        let copied=AgentError(mapped.kind,String.fromUtf8(mapped.code.toArray()),
            String.fromUtf8(mapped.message.toArray()),retryable:mapped.retryable,
            fallbackAllowed:mapped.fallbackAllowed,fields:fields,
            attemptFailure:mapped.attemptFailure,observation:mapped.observation)
        let result=SqliteLiveMemoryOuterErrorData331(payment,copied)
        transferred=true;result
    }finally{
        // This failure means no copied error/owner was published. Original
        // DB debt is latched before this helper and cannot ACK/refund instead.
        if(!transferred){payment.close()}
    }
}
