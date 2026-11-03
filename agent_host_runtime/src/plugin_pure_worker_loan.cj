package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Only the actual captured host method constructs a loan. It has no registry,
// Host generation, Runtime, Source, file, SQL, permission or callback API.
// Escaped references are revoked before the outer owner releases its locks.
public class HostPluginPureDataLoanReply {
    public let value:AgentValue
    private let charge:LogicalJsonOwnerReservation
    private let native:JavaScriptHostInvocationResult
    private let releaseLock=Mutex()
    private var released=false
    init(value:AgentValue,charge:LogicalJsonOwnerReservation,native:JavaScriptHostInvocationResult){
        this.value=value;this.charge=charge;this.native=native}
    public func close():Unit{
        releaseLock.lock()
        try{if(!released){released=true;try{native.releasePayload()}finally{charge.close()}}}
        finally{releaseLock.unlock()}}
    func isClosed():Bool{releaseLock.lock();try{released}finally{releaseLock.unlock()}}
}

public class HostPluginPureDataLoan {
    private let invoke:(String,Int64)->JavaScriptHostResult<JavaScriptHostInvocationResult>
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let current:()->Result<Unit>
    private let deadline:MonoTime
    private let callerUnbounded:Bool
    private let maximumExchanges:Int64
    private let lock=Mutex()
    private let active=AtomicBool(true)
    private var pending:?HostPluginPureDataLoanReply=None
    private var exchanges:Int64=0
    init(invoke:(String,Int64)->JavaScriptHostResult<JavaScriptHostInvocationResult>,
        allocate:(Int64)->LogicalJsonOwnerReservation,current:()->Result<Unit>,deadline:MonoTime,maximumExchanges:Int64,callerUnbounded!:Bool=false){
        this.invoke=invoke;this.allocate=allocate;this.current=current;this.deadline=deadline;this.maximumExchanges=maximumExchanges;this.callerUnbounded=callerUnbounded}
    public func exchange(request:AgentValue):Result<HostPluginPureDataLoanReply>{
        lock.lock()
        try{
            if(!active.load() || exchanges>=maximumExchanges){
                return hostPluginResourceError<HostPluginPureDataLoanReply>("plugin.pure_loan_closed","pure loan is closed or exhausted its original worker quota")}
            match(pending){case Some(value)=>if(!value.isClosed()){
                return hostPluginResourceError<HostPluginPureDataLoanReply>("plugin.pure_loan_reply_pending","previous paid reply has not been acknowledged")};case None=>()}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let remaining=if(callerUnbounded){5000}else{min(5000,(deadline-MonoTime.now()).toMilliseconds())}
            if(remaining<1){return hostPluginResourceError<HostPluginPureDataLoanReply>("plugin.pure_loan_deadline","actual caller deadline expired")}
            // The request is only bounded pure transport. The caller separately
            // supplies a private actual-Store materialization proof for bytes.
            let input=logicalJsonWriteReservationBytes(request,196608)
            if(input>196608){return hostPluginResourceError<HostPluginPureDataLoanReply>("plugin.pure_loan_request","pure loan request exceeds its original ordinary preparation ceiling")}
            let charge=allocate(196608);var transferred=false
            try{
                charge.ensureRetainedPeak(1048576+input*8)
                let encoded=stringifyUnifiedJson(request)
                if(encoded.size>196608){return hostPluginResourceError<HostPluginPureDataLoanReply>("plugin.pure_loan_request","complete request differs from its paid extent")}
                match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                exchanges+=1
                let native=match(invoke(encoded,remaining)){
                    case JavaScriptHostResult.Err(error)=>return Result.Err(hostJavascriptPluginAgentError(error))
                    case JavaScriptHostResult.Ok(value)=>value}
                var retained=false
                try{
                    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    if(!active.load() || native.isError || native.resultJson.size<1 || native.resultJson.size>196608){
                        return hostPluginResourceError<HostPluginPureDataLoanReply>("plugin.pure_loan_reply","pure data reply was rejected or exceeds its fixed transport ceiling")}
                    let nodes=logicalJsonNodeCount(native.resultJson)
                    charge.ensureRetainedPeak(1048576+input*8+native.resultJson.size*8+nodes*512)
                    charge.ensureDecoded(native.resultJson.size,nodes)
                    let value=parseUnifiedJson(native.resultJson,maxBytes:196608,maxDepth:32)
                    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let reply=HostPluginPureDataLoanReply(value,charge,native)
                    pending=Some(reply);retained=true;transferred=true;Result.Ok(reply)
                }finally{if(!retained){native.releasePayload()}}
            }finally{if(!transferred){charge.close()}}
        }catch(_:Exception){hostPluginResourceError<HostPluginPureDataLoanReply>("plugin.pure_loan_failed","bounded pure loan exchange failed")}
        finally{lock.unlock()}}
    func close():Unit{
        // Closing first makes every escaped exchange inert; no replacement
        // process or widened deadline is installed on cancellation or failure.
        active.store(false);lock.lock()
        try{match(pending){case Some(reply)=>reply.close();pending=None;case None=>()}}
        finally{lock.unlock()}
    }
}

// This package-private owner records actual Session adoption. Merely closing
// a selected worker never acknowledges another session's preexisting debt.
class HostPluginPureWorkerDebt {
    private let owner:HostDocumentDataSession
    private let adopted=AtomicBool(false)
    init(owner:HostDocumentDataSession){this.owner=owner}
    func adopt(cleanup:()->Bool):Result<Unit>{
        if(adopted.load()){return hostPluginResourceError<Unit>("plugin.pure_loan_adopted","worker cleanup was already adopted")}
        match(owner.retainWorkerCleanup(cleanup)){
            case Result.Err(error)=>Result<Unit>.Err(error)
            case Result.Ok(_)=>adopted.store(true);Result<Unit>.Ok(())}
    }
    func acknowledgeIfCollected(collected:Bool):Unit{
        if(adopted.load() && collected){owner.acknowledgeWorkerRelease();adopted.store(false)}
    }
}
