package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*

// No public reservation, close, refund or caller-supplied ACK. The original
// Store error owner retains every published consumer, even after its lexical
// callback ended or its caller no longer retains this wrapper.
class SqliteLiveMemoryOuterErrorConsumer333 {
    private let lock=Mutex()
    private let allocation:LogicalJsonOwnerReservation
    private let basePeak:Int64
    private let error:AgentError
    private var additionalPeak:Int64=0
    init(allocation:LogicalJsonOwnerReservation,basePeak:Int64,error:AgentError){
        this.allocation=allocation;this.basePeak=basePeak;this.error=error
    }
    func ensureAdditional(bytes:Int64):Result<Unit>{
        lock.lock();try{
            allocation.ensureRetainedPeak(ownedOuterErrorAdd333(basePeak,bytes))
            additionalPeak=max(additionalPeak,bytes);Result.Ok(())
        }catch(_:Exception){ownedOuterErrorConsumerError333("run.owned_outer_error_capacity")}
        finally{lock.unlock()}
    }
    func consume(action:(AgentError,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>{
        try{match(action(error,{bytes=>ensureAdditional(bytes)})){
            case Result.Ok(_)=>Result.Ok(())
            case Result.Err(failure)=>lock.lock();try{
                let extra=ownedOuterErrorAdd333(additionalPeak,ownedOuterErrorRetainedPeak333(failure))
                allocation.ensureRetainedPeak(ownedOuterErrorAdd333(basePeak,extra));additionalPeak=extra
                Result<Unit>.Err(ownedOuterErrorCopy333(failure))
            }finally{lock.unlock()}}}
        catch(_:Exception){ownedOuterErrorConsumerError333("run.owned_outer_error_consumer_failed")}
    }
}

func retainLiveMemoryOuterErrorConsumer333(source:AgentError,
    payment:LogicalJsonOwnerReservation):SqliteLiveMemoryOuterErrorConsumer333{
    // The actual operationStoreError mapper in 331 has no attachments. Do
    // not silently drop a future Some value or fall back to a smaller codec.
    if(source.attemptFailure.isSome() || source.observation.isSome()){
        throw IllegalStateException("actual Store outer error mapping changed")}
    let peak=ownedOuterErrorAdd333(16384,ownedOuterErrorAdd333(
        ownedOuterErrorMultiply333(ownedOuterErrorScalarBytes333(source),4),
        ownedOuterErrorMultiply333(source.fields.size,1024)))
    let loan=payment.deriveRetainedLease();var transferred=false
    try{
        loan.ensureRetainedPeak(peak)
        // A fresh fields array prevents a borrower from mutating another
        // consumer's view. All original eight fields and full strings remain.
        let fields=Array<ErrorField>(source.fields.size,{i=>ErrorField(source.fields[i].name,source.fields[i].value)})
        let copy=AgentError(source.kind,source.code,source.message,retryable:source.retryable,
            fallbackAllowed:source.fallbackAllowed,fields:fields,
            attemptFailure:source.attemptFailure,observation:source.observation)
        let value=SqliteLiveMemoryOuterErrorConsumer333(loan,peak,copy)
        transferred=true;value
    }finally{if(!transferred){loan.close()}}
}
