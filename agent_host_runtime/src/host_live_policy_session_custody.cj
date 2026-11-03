package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.sync.*

// One mechanical ownership lock, no registry, lookup, effect or Source
// dispatcher. It never encloses SQL, a worker invocation or effect execution.
private let hostLivePolicyOutputOwnership=Mutex()

// Constructed only by the actual same-Session private writer decoder below.
// The output may contain only policy metadata/references; its large data stays
// in the original Artifact/Native owners. No value or reservation escapes a
// Unit metadata consumer. The actual Pipeline separately proves every Source.
class HostLivePolicySessionCustody <: LiveToolExecutionCustody {
    private var session:?HostDocumentDataSession
    private var physical:?HostLiveExecutionCustody
    private var output:?AgentValue
    private var consumed=false
    private var capturedMetadata=false
    private var metadataBorrowed=false
    private var transferred=false
    private var successorPending291=false
    private var closed=false
    private var cleanupDebt:?HostLiveExecutionCustody=None
    init(session:HostDocumentDataSession,physical:HostLiveExecutionCustody,output:AgentValue){
        this.session=Some(session);this.physical=Some(physical);this.output=Some(output)
    }
    // Trusted Host-private metadata parsing only. Prepare/execute/SQL/native
    // actions happen after this callback. An untrusted IPC callback never runs
    // here and cannot ACK, replace or close the actual owner.
    func consumeOutput(consume:(AgentValue)->Result<Unit>):Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        try{
            if(closed || transferred || consumed || output.isNone() || session.isNone() || cleanupDebt.isSome()){
                return hostPluginResourceError("plugin.live_output_consumed","live policy output is already consumed or still owns cleanup debt")}
            let actual=session.getOrThrow()
            if(!actual.livePolicyTransientResourcesReleased() || !actual.livePolicyPrivateOutputRetained()){
                return hostPluginResourceError("plugin.live_output_owner_changed","actual private output owner changed before consumption")}
            match(consume(output.getOrThrow())){
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>consumed=true;Result.Ok(())}
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }
    // Opt-in promotion into the original Session metadata reservation. This
    // mutex encloses only bounded copying/consumption and the actual output
    // ACK; no SQL, worker, prepare or effect callback can run here.
    func capturePaidMetadata(consume:(AgentValue)->Result<Unit>):Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        try{
            if(closed || transferred || consumed || capturedMetadata || metadataBorrowed ||
                output.isNone() || session.isNone() || cleanupDebt.isSome()){
                return hostPluginResourceError("plugin.live_metadata_capture_changed","same original output cannot be promoted again")}
            let actual=session.getOrThrow()
            if(!actual.livePolicyTransientResourcesReleased() || !actual.livePolicyPrivateOutputRetained()){
                return hostPluginResourceError("plugin.live_metadata_capture_changed","actual output or physical transient ACK changed before capture")}
            match(actual.captureFinishedLivePolicyMetadata(output.getOrThrow(),consume)){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            // No reference to the old decoder's DOM survives its own ACK.
            // The small independently copied DOM belongs to metadata, whose
            // original executionPending/collector identity remains held.
            output=None<AgentValue>;consumed=true;capturedMetadata=true
            actual.acknowledgeOutput()
            if(!actual.livePolicyCapturedMetadataRetained()){
                return hostPluginResourceError("plugin.live_metadata_capture_changed","captured metadata or original result ACK changed")}
            Result<Unit>.Ok(())
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }
    // Claim/Source verification remains in Pipeline. This is only one short
    // data loan from the actual retained Session, never another registry.
    // Close cannot drop the owner while this synchronous borrower is active.
    // The same actual custody, not a second owner registry, loans its
    // retained Session metadata to a short synchronous Store phase. The
    // physical cleanup debt and original executionPending flag stay owned.
    func withPaidMetadataOwner(retained:AgentValue,
        consume:(LogicalJsonOwnerReservation,Int64)->Unit):Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        let actual:HostDocumentDataSession=try{
            if(closed || transferred || !consumed || !capturedMetadata || metadataBorrowed ||
                cleanupDebt.isSome() || session.isNone()){
                return hostPluginResourceError("plugin.live_metadata_borrowed","same captured metadata custody is unavailable")}
            let current=session.getOrThrow()
            if(!current.livePolicyCapturedMetadataRetained()){
                return hostPluginResourceError("plugin.live_metadata_owner_changed","same captured metadata lacks its actual retained owner")}
            metadataBorrowed=true;current
        }finally{hostLivePolicyOutputOwnership.unlock()}
        try{actual.withCapturedLivePolicyMetadataOwner(retained,consume)}
        finally{
            hostLivePolicyOutputOwnership.lock()
            try{metadataBorrowed=false}finally{hostLivePolicyOutputOwnership.unlock()}
        }
    }

    // One synchronous data-only call on the actual captured Session. The
    // private identity and physical owner are held throughout Store before /
    // after checks; close cannot consume a debt while this borrower is active.
    func captureKnownChildLedger(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,previous:AgentValue,result:?ToolResult,guard:()->Result<Unit>,
        consume:(AgentValue)->Unit):Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        let actual:?HostDocumentDataSession=try{
            if(closed || transferred || !consumed || !capturedMetadata || metadataBorrowed ||
                cleanupDebt.isSome() || session.isNone()){
                None<HostDocumentDataSession>
            }else{metadataBorrowed=true;session}
        }finally{hostLivePolicyOutputOwnership.unlock()}
        let retained=match(actual){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.live_known_child_owner_missing",
                "same actual captured Session must retain the original ledger")}
        try{retained.captureKnownLivePolicyChildLedger(context,parent,child,previous,result,guard,consume)}
        finally{hostLivePolicyOutputOwnership.lock();try{metadataBorrowed=false}finally{hostLivePolicyOutputOwnership.unlock()}}
    }

    // Called only after a new actual Session has prepaid the transferred
    // original ledger, and the driver has dropped every old step alias.
    // It keeps this custody's private identity for the waiting continuation.
    func retireCapturedMetadataForSuccessor291():Result<Unit>{
        hostLivePolicyOutputOwnership.lock();try{
            if(closed || transferred || successorPending291 || !consumed || !capturedMetadata || metadataBorrowed ||
                cleanupDebt.isSome() || session.isNone() || physical.isNone()){
                return hostPluginResourceError("plugin.live_successor_owner_changed","same captured metadata custody cannot retire an active borrower or physical debt")}
            let previous=session.getOrThrow()
            if(!previous.livePolicyTransientResourcesReleased() || !previous.livePolicyCapturedMetadataRetained()){
                return hostPluginResourceError("plugin.live_successor_owner_changed","same original metadata lacks its actual completed transient proof")}
            output=None<AgentValue>;previous.acknowledgeCapturedLivePolicyMetadata();capturedMetadata=false
            let retained=physical.getOrThrow()
            match(retained.close()){
                case Result.Err(error)=>cleanupDebt=Some(retained);return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            session=None<HostDocumentDataSession>;physical=None<HostLiveExecutionCustody>
            successorPending291=true;Result<Unit>.Ok(())
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }

    func retainCapturedSuccessorPin336(previous:AgentValue,next:AgentValue):Result<HostLiveCapturedMetadataPin336>{
        hostLivePolicyOutputOwnership.lock()
        let actual:HostDocumentDataSession=try{
            if(closed || transferred || successorPending291 || !consumed || !capturedMetadata || metadataBorrowed ||
                cleanupDebt.isSome() || session.isNone()){
                return hostPluginResourceError<HostLiveCapturedMetadataPin336>("plugin.live_successor_owner_changed","same actual completed captured step required")}
            metadataBorrowed=true;session.getOrThrow()
        }finally{hostLivePolicyOutputOwnership.unlock()}
        try{actual.retainLivePolicyCapturedSuccessorBacking336(previous,next)}
        finally{hostLivePolicyOutputOwnership.lock();try{metadataBorrowed=false}finally{hostLivePolicyOutputOwnership.unlock()}}
    }
    func createPaidDataSuccessorSession336(pin:HostLiveCapturedMetadataPin336):Result<HostDocumentDataSession>{
        hostLivePolicyOutputOwnership.lock()
        let actual:HostDocumentDataSession=try{
            if(closed || transferred || successorPending291 || !capturedMetadata || metadataBorrowed || cleanupDebt.isSome() || session.isNone()){
                return hostPluginResourceError<HostDocumentDataSession>("plugin.live_successor_owner_changed","actual original captured step is unavailable")}
            metadataBorrowed=true;session.getOrThrow()
        }finally{hostLivePolicyOutputOwnership.unlock()}
        try{actual.createPaidDataSuccessorSession336(pin)}
        finally{hostLivePolicyOutputOwnership.lock();try{metadataBorrowed=false}finally{hostLivePolicyOutputOwnership.unlock()}}
    }
    func retireCapturedPhysicalForPaidSuccessor336(pin:HostLiveCapturedMetadataPin336):Result<Unit>{
        hostLivePolicyOutputOwnership.lock();try{
            if(closed || transferred || successorPending291 || !consumed || !capturedMetadata || metadataBorrowed ||
                cleanupDebt.isSome() || session.isNone() || physical.isNone()){
                return hostPluginResourceError("plugin.live_successor_physical_fields_live","same actual old physical fields required")}
            let previous=session.getOrThrow()
            match(previous.clearCapturedLivePolicyPhysicalFields336(pin)){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            output=None<AgentValue>;capturedMetadata=false
            let retained=physical.getOrThrow()
            match(retained.close()){
                case Result.Err(error)=>cleanupDebt=Some(retained);return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            session=None<HostDocumentDataSession>;physical=None<HostLiveExecutionCustody>
            successorPending291=true;Result<Unit>.Ok(())
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }
    // Actual successor output has completed its own run/worker/FD/writer ACK.
    // Adopt its real private fields once; no decoded DTO can construct them.
    // No worker, SQL or effect executes under this mechanical ownership lock.
    func adoptMetadataSuccessor291(next:HostLivePolicySessionCustody):Result<Unit>{
        hostLivePolicyOutputOwnership.lock();try{
            if(refEq(this,next) || closed || transferred || !successorPending291 || metadataBorrowed || capturedMetadata ||
                cleanupDebt.isSome() || session.isSome() || physical.isSome() || output.isSome() ||
                next.closed || next.transferred || next.successorPending291 || next.consumed || next.capturedMetadata || next.metadataBorrowed ||
                next.cleanupDebt.isSome() || next.session.isNone() || next.physical.isNone() || next.output.isNone()){
                return hostPluginResourceError("plugin.live_successor_owner_changed","same retired custody requires one fresh actual output successor")}
            let retained=next.session.getOrThrow()
            if(!retained.livePolicyTransientResourcesReleased() || !retained.livePolicyPrivateOutputRetained()){
                return hostPluginResourceError("plugin.live_successor_owner_changed","successor lacks its actual output allocation and physical transient ACK")}
            session=next.session;physical=next.physical;output=next.output;consumed=false;successorPending291=false
            next.session=None<HostDocumentDataSession>;next.physical=None<HostLiveExecutionCustody>;next.output=None<AgentValue>;next.transferred=true
            Result<Unit>.Ok(())
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }

    // Host-private resource hook for the new actual mutable Tools pending
    // holder. Old immutable publication paths never call it or retire a pin.
    // No SQL, worker, prepare or approval occurs under this ownership lock.
    func retainPendingPreparedBacking315(additionalPeak:Int64):Result<LogicalJsonOwnerReservation>{
        hostLivePolicyOutputOwnership.lock()
        let actual:?HostDocumentDataSession=try{
            if(closed || transferred || successorPending291 || !consumed || !capturedMetadata || metadataBorrowed ||
                cleanupDebt.isSome() || session.isNone()){
                None<HostDocumentDataSession>
            }else{metadataBorrowed=true;session}
        }finally{hostLivePolicyOutputOwnership.unlock()}
        let original=match(actual){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.live_pending_backing_owner_changed",
                "same actual captured metadata custody is required for pending input")}
        try{original.retainLivePolicyPendingPreparedBacking315(additionalPeak)}
        finally{hostLivePolicyOutputOwnership.lock();try{metadataBorrowed=false}finally{hostLivePolicyOutputOwnership.unlock()}}
    }

    func withPaidMetadata(consume:(AgentValue)->Result<Unit>):Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        let actual:?HostDocumentDataSession=try{
            if(closed || transferred || !capturedMetadata || metadataBorrowed || session.isNone() || cleanupDebt.isSome()){
                None<HostDocumentDataSession>
            }else{metadataBorrowed=true;session}
        }finally{hostLivePolicyOutputOwnership.unlock()}
        let retained=match(actual){case Some(value)=>value
            case None=>return hostPluginResourceError("plugin.live_metadata_borrow_changed","only the same retained metadata custody can be borrowed")}
        try{retained.withCapturedLivePolicyMetadata(consume)}
        finally{hostLivePolicyOutputOwnership.lock();try{metadataBorrowed=false}finally{hostLivePolicyOutputOwnership.unlock()}}
    }

    public func releaseTransient():Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        try{
            if(closed || transferred || cleanupDebt.isSome() || session.isNone()){
                return hostPluginResourceError("plugin.live_transient_cleanup_pending","same live custody cannot publish after transfer or cleanup failure")}
            let actual=session.getOrThrow()
            if(capturedMetadata){
                if(metadataBorrowed || !actual.livePolicyTransientResourcesReleased() || !actual.livePolicyCapturedMetadataRetained()){
                    return hostPluginResourceError("plugin.live_transient_cleanup_pending","same captured metadata or its actual physical transient ACK changed")}
                return Result<Unit>.Ok(())}
            if(!actual.livePolicyTransientResourcesReleased() || !actual.livePolicyPrivateOutputRetained()){
                return hostPluginResourceError("plugin.live_transient_cleanup_pending","actual worker, stream, writer or paid output remains unacknowledged")}
            Result.Ok(())
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }
    // A successor preserves this exact custody identity. Both actually paid
    // Sessions coexist before adoption; the shared aggregate accounts for that
    // peak. Do not prepare a new step while old metadata is still unconsumed.
    func replaceConsumedOutput(next:HostLivePolicySessionCustody):Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        try{
            if(refEq(this,next) || closed || transferred || !consumed || capturedMetadata || metadataBorrowed || cleanupDebt.isSome() || session.isNone() || physical.isNone() ||
                next.closed || next.transferred || next.consumed || next.cleanupDebt.isSome() || next.session.isNone() || next.physical.isNone() || next.output.isNone()){
                return hostPluginResourceError("plugin.live_output_owner_changed","live successor cannot replace an unconsumed or foreign cleanup owner")}
            let nextSession=next.session.getOrThrow()
            if(!nextSession.livePolicyTransientResourcesReleased() || !nextSession.livePolicyPrivateOutputRetained()){
                return hostPluginResourceError("plugin.live_transient_cleanup_pending","successor lacks its actual private output and physical ACK")}
            // Drop our actual DOM reference before acknowledging its paid
            // output. Any failure keeps this same original Session as debt;
            // the successor stays wholly owned by its original object.
            let previous=session.getOrThrow()
            output=None
            previous.acknowledgeOutput()
            let previousPhysical=physical.getOrThrow()
            match(previousPhysical.close()){
                case Result.Err(error)=>cleanupDebt=Some(previousPhysical);return Result.Err(error)
                case Result.Ok(_)=>()}
            session=next.session;physical=next.physical;output=next.output;consumed=false
            next.session=None;next.physical=None;next.output=None;next.transferred=true
            Result.Ok(())
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }
    public func close():Result<Unit>{
        hostLivePolicyOutputOwnership.lock()
        try{
            if(closed || transferred){return Result.Ok(())}
            if(metadataBorrowed){return hostPluginResourceError("plugin.live_metadata_ack_pending","active same-owner data borrower must finish before actual disposal")}
            if(capturedMetadata){match(session){case Some(actual)=>actual.acknowledgeCapturedLivePolicyMetadata();case None=>()};capturedMetadata=false}
            // A consumer may discard a pending output on cancellation/drop.
            // Its only retained DOM is removed before the real consumer ACK.
            output=None;consumed=true
            match(cleanupDebt){case Some(debt)=>match(debt.close()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>cleanupDebt=None}
                case None=>()}
            match(session){case Some(actual)=>
                actual.acknowledgeOutput()
                let actualPhysical=physical.getOrThrow()
                match(actualPhysical.close()){
                    case Result.Err(error)=>cleanupDebt=Some(actualPhysical);return Result.Err(error)
                    case Result.Ok(_)=>session=None;physical=None}
                case None=>()}
            closed=true;Result.Ok(())
        }finally{hostLivePolicyOutputOwnership.unlock()}
    }
}

// The actual Host session factory must retain this Session in its existing
// collector before entry. A Native Node cannot construct this resource result:
// a same-owner private file is completed, hashed, decoded, and physically
// cleaned by the original run() before this actual custody is returned.
func hostRunLivePolicyPaidSession(session:HostDocumentDataSession,
    produce:(HostDocumentDataSession)->Result<HostServiceArtifactWriter>,maximum:Int64,
    current:()->Result<Unit>):Result<HostLivePolicySessionCustody>{
    // The original Host collector has already adopted this inert Session.
    // Retain the existing execution custody before any callback/FD/worker.
    let physical=match(session.retainExecutionCustody()){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    var decoded=session.run({actual=>
        match(current()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        let writer=match(produce(actual)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        actual.readPrivateContextValue(writer,maximum,current)
    })
    let result:Result<HostLivePolicySessionCustody>=match(decoded){
        case Result.Err(error)=>Result.Err(error)
        case Result.Ok(value)=>
            if(!session.livePolicyTransientResourcesReleased() || !session.livePolicyPrivateOutputRetained()){
                hostPluginResourceError<HostLivePolicySessionCustody>("plugin.live_output_owner_changed",
                    "private output was not retained by its actual completed Session")
            }else{Result.Ok(HostLivePolicySessionCustody(session,physical,value))}
    }
    // The match value's lexical scope has ended. Drop the local Result's
    // final DOM reference before any failed-transfer output ACK/payment close.
    // On success the same DOM stays in its same real resultReservation, while
    // the original executionPending owner retains metadata in the collector.
    decoded=hostPluginResourceError<AgentValue>("plugin.live_output_transferred","local private output reference was consumed")
    if(result.isError()){
        session.acknowledgeOutput()
        // Failure never forgets a worker/writer/FD: original close retains its
        // executionPending flag and the same actual collector owns the retry.
        let _=physical.close()
    }
    result
}

// Checked cleanup variant for the distinct unused312 entry only.
func hostRunLivePolicyPaidSession312(session:HostDocumentDataSession,
    produce:(HostDocumentDataSession)->Result<HostServiceArtifactWriter>,maximum:Int64,
    current:()->Result<Unit>):Result<HostLivePolicySessionCustody>{
    // The original Host collector has already adopted this inert Session.
    // Retain the existing execution custody before any callback/FD/worker.
    let physical=match(session.retainExecutionCustody()){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    var decoded=session.run({actual=>
        match(current()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        let writer=match(produce(actual)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        actual.readPrivateContextValue(writer,maximum,current)
    })
    var result:Result<HostLivePolicySessionCustody>=match(decoded){
        case Result.Err(error)=>Result.Err(error)
        case Result.Ok(value)=>
            if(!session.livePolicyTransientResourcesReleased() || !session.livePolicyPrivateOutputRetained()){
                hostPluginResourceError<HostLivePolicySessionCustody>("plugin.live_output_owner_changed",
                    "private output was not retained by its actual completed Session")
            }else{Result.Ok(HostLivePolicySessionCustody(session,physical,value))}
    }
    // The match value's lexical scope has ended. Drop the local Result's
    // final DOM reference before any failed-transfer output ACK/payment close.
    // On success the same DOM stays in its same real resultReservation, while
    // the original executionPending owner retains metadata in the collector.
    decoded=hostPluginResourceError<AgentValue>("plugin.live_output_transferred","local private output reference was consumed")
    if(result.isError()){
        session.acknowledgeOutput()
        // Failure never forgets a worker/writer/FD: original close retains its
        // executionPending flag and the same actual collector owns the retry.
        match(physical.close()){case Result.Err(error)=>result=Result<HostLivePolicySessionCustody>.Err(error);case Result.Ok(_)=>()}
    }
    result
}


// Distinct FIRST-run entry. Reuses the exact physical custody retained by
// the collector before Tools paid the full Prepared walk. No second Session
// or retainExecutionCustody is created, and no failure refunds that debt.
func hostRunLivePolicyPaidInitialSession332(session:HostDocumentDataSession,
    physical:HostLiveExecutionCustody,actual:OwnedKernelPreparedReferenceCustody,debt:OwnedKernelPreparedReferenceDebt,
    produce:(HostDocumentDataSession)->Result<HostServiceArtifactWriter>,maximum:Int64,
    current:()->Result<Unit>):Result<HostLivePolicySessionCustody>{
    match(session.requireLivePolicyInitialPreparedExecution332(actual,physical,debt)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    var decoded=session.run({owner=>
        match(current()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        let writer=match(produce(owner)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(value)=>value}
        owner.readPrivateContextValue(writer,maximum,current)
    })
    let result:Result<HostLivePolicySessionCustody>=match(decoded){
        case Result.Err(error)=>Result.Err(error)
        case Result.Ok(value)=>
            if(!session.livePolicyTransientResourcesReleased() || !session.livePolicyPrivateOutputRetained()){
                hostPluginResourceError<HostLivePolicySessionCustody>("plugin.live_output_owner_changed",
                    "initial private output requires the same actual completed paid Session")
            }else{Result.Ok(HostLivePolicySessionCustody(session,physical,value))}}
    decoded=hostPluginResourceError<AgentValue>("plugin.live_output_transferred","local first output reference was consumed")
    // Full Prepared/Source aliases and the original custody survive errors.
    // The collector keeps this same physical debt; no cleanup return claims
    // those independent fields or error consumer frames have retired.
    result
}
