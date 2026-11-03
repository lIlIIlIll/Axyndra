package agent_store

import agent_domain.*
import agent_runtime.*

// Invoked only while the actual DB debt mutex owns the original exception.
// Successful copies have their own original-bank child; failure leaves both
// the first original cleanup exception and allocation failure latched.
func copyLiveMemoryCleanupError334(original:Exception,
    loan:LogicalJsonOwnerReservation):SqliteLiveMemoryOuterErrorData331{
    let code="plugin.live_database_cleanup_pending"
    let identity=OperationId("native-abort-cleanup")
    let guarded=match(original as PluginDocumentGuardFailure){case Some(value)=>Some(value.failure);case None=>None<AgentError>}
    let peak=match(guarded){case Some(value)=>ownedOuterErrorRetainedPeak333(value)
        case None=>ownedOuterErrorAdd333(16384,ownedOuterErrorMultiply333(
            ownedOuterErrorAdd333(original.message.size,ownedOuterErrorAdd333(code.size,identity.value.size+256)),4))}
    let payment=loan.deriveRetainedLease();var transferred=false
    try{
        payment.ensureRetainedPeak(peak)
        let mapped=match(guarded){case Some(value)=>value
            case None=>match(operationStoreError<Unit>(code,identity,original)){
                case Result.Err(value)=>value;case Result.Ok(_)=>throw IllegalStateException("actual cleanup mapper must remain an error")}}
        let fields=Array<ErrorField>(mapped.fields.size,{i=>ErrorField(
            String.fromUtf8(mapped.fields[i].name.toArray()),String.fromUtf8(mapped.fields[i].value.toArray()))})
        // Attachments are immutable data; their complete retention is charged
        // by ownedOuterErrorRetainedPeak333, not parsed or shortened here.
        let copied=AgentError(mapped.kind,String.fromUtf8(mapped.code.toArray()),String.fromUtf8(mapped.message.toArray()),
            retryable:mapped.retryable,fallbackAllowed:mapped.fallbackAllowed,fields:fields,
            attemptFailure:mapped.attemptFailure,observation:mapped.observation)
        let result=SqliteLiveMemoryOuterErrorData331(payment,copied);transferred=true;result
    }finally{if(!transferred){payment.close()}}
}
