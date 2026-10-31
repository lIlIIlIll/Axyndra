package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*

// Opt-in synchronous assembly interface. A Native value cannot implement
// this interface or construct its control. The existing ToolExecutor entry
// stays separate and must reject owned-entry-required for this family.
public interface OwnedToolExecutor {
    func executeOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>
    func resumeOwned(context:ToolInvocationContext,pending:OwnedToolExecutionContinuation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>
    func rejectOwned(context:ToolInvocationContext,parent:PreparedToolInvocation,
        decision:ApprovalDecision,control:OwnedToolExecutionControl):Result<OwnedToolExecutionProgress>
}

// A child effect has an independent precise Prepared invocation. Ordinary
// executeObserved/admitDerived cannot be used to widen its old contract.
public interface OwnedToolEffectExecutor {
    func executeLiveEffect(context:ToolInvocationContext,child:PreparedToolInvocation):ToolExecutionOutcome
}

// Constructor and callbacks are package-private. Each call goes back to the
// actual Pipeline; none accepts a plugin claim as Source or approval. The
// control expires at the end of this ONE synchronous executor invocation.
public class OwnedToolExecutionControl {
    private let lock=Mutex()
    private var active=true
    private var pending=false
    private var terminalCaptured=false
    private var preparedInputMode=false
    private var preparedInputChild:?PreparedToolInvocation=None<PreparedToolInvocation>
    private let terminalIdentity=OwnedToolTerminalIdentity()
    private var retainedChild:?OwnedToolRetainedChildExecution=None<OwnedToolRetainedChildExecution>
    private var references:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>
    private let legacyExecuteRetained:?((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)
    private let legacyRetainedResources:?OwnedRetainedInvocationResources
    private var referenceResources:?OwnedRetainedInvocationResources=None<OwnedRetainedInvocationResources>
    private let legacyTerminalParent:?PreparedToolInvocation
    private let legacyResumed:?PreparedToolInvocation
    private let legacyCheck:()->Result<Unit>
    private let legacyPrepare:(ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>
    private let legacyCapture:(PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>
    private let legacyExecute:(ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>
    private prop retainedResources:?OwnedRetainedInvocationResources{get(){if(references.isSome()){referenceResources}else{legacyRetainedResources}}}
    private prop executeRetained:?((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>){get(){match(references){case Some(value)=>value.actualRetained();case None=>legacyExecuteRetained}}}
    private prop terminalParent:?PreparedToolInvocation{get(){match(references){case Some(value)=>value.actualParent();case None=>legacyTerminalParent}}}
    private prop resumed:?PreparedToolInvocation{get(){match(references){case Some(value)=>value.actualResumed();case None=>legacyResumed}}}
    private prop check:()->Result<Unit>{get(){match(references){case Some(value)=>value.actualCheck();case None=>legacyCheck}}}
    private prop prepare:(ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>{get(){match(references){case Some(value)=>value.actualPrepare();case None=>legacyPrepare}}}
    private prop capture:(PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>{get(){match(references){case Some(value)=>value.actualCapture();case None=>legacyCapture}}}
    private prop execute:(ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>{get(){match(references){case Some(value)=>value.actualExecute();case None=>legacyExecute}}}
    init(resumed:?PreparedToolInvocation,check:()->Result<Unit>,prepare:(ToolInvocationContext,ToolCall,String)->Result<ToolPreparation>,
        capture:(PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolExecutionContinuation>,
        execute:(ToolInvocationContext,PreparedToolInvocation)->Result<ToolInvocationResult>,
        terminalParent!:?PreparedToolInvocation=None<PreparedToolInvocation>,
        retainedResources!:?OwnedRetainedInvocationResources=None<OwnedRetainedInvocationResources>,
        executeRetained!:?((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)=None<((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)>,
        referenceDebt!:?OwnedKernelPreparedReferenceDebt=None<OwnedKernelPreparedReferenceDebt>){
        this.references=referenceDebt
        this.legacyRetainedResources=if(referenceDebt.isNone()){retainedResources}else{None<OwnedRetainedInvocationResources>}
        this.referenceResources=if(referenceDebt.isSome()){retainedResources}else{None<OwnedRetainedInvocationResources>}
        // All constructor members are initialized before callbacks are
        // installed in the external paid frame. Ordinary values are exact.
        this.legacyResumed=if(referenceDebt.isNone()){resumed}else{None<PreparedToolInvocation>}
        this.legacyTerminalParent=if(referenceDebt.isNone()){terminalParent}else{None<PreparedToolInvocation>}
        this.legacyExecuteRetained=if(referenceDebt.isNone()){executeRetained}else{
            None<((ToolInvocationContext,PreparedToolInvocation,LiveToolExecutionCustody)->Result<OwnedToolRetainedChildExecution>)>}
        this.legacyCheck=if(referenceDebt.isNone()){check}else{{=>ownedControlError<Unit>()}}
        this.legacyPrepare=if(referenceDebt.isNone()){prepare}else{{_,_,_=>ownedControlError<ToolPreparation>()}}
        this.legacyCapture=if(referenceDebt.isNone()){capture}else{{_,_=>ownedControlError<OwnedToolExecutionContinuation>()}}
        this.legacyExecute=if(referenceDebt.isNone()){execute}else{{_,_=>ownedControlError<ToolInvocationResult>()}}
        // Old fields in the opted route contain only closed no-capture
        // functions; no immutable duplicate retains the real callbacks.
        match(referenceDebt){case Some(value)=>value.install(check,prepare,capture,execute,executeRetained);case None=>()}
    }
    private func available():Result<Unit>{
        // Caller holds this invocation-local lock through the actual action.
        // close waits for every admitted callback before expiring the control.
        if(!active || pending || terminalCaptured){return ownedControlError<Unit>()}
        match(retainedChild){case Some(value)=>if(!value.isAcknowledged()){return retainedOutputError("tool.retained_child_ack_pending")};case None=>()}
        check()
    }
    // Only this invocation's actual durable approved pending child is exposed.
    // The old immutable ApprovalRequired object is never silently reauthorized.
    public func approvedPendingChild():Result<?PreparedToolInvocation>{
        lock.lock();try{
            match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            Result.Ok(resumed)
        }finally{lock.unlock()}
    }
    func enterPreparedInputMode(child:?PreparedToolInvocation):Result<Unit>{
        lock.lock();try{
            match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(references.isNone() || preparedInputMode){return ownedControlError<Unit>()}
            preparedInputMode=true;preparedInputChild=child;Result.Ok(())
        }finally{lock.unlock()}
    }
    func preparedInputActionAcknowledged():Result<Unit>{
        lock.lock();try{
            if(!preparedInputMode || !active){return ownedControlError<Unit>()}
            match(preparedInputChild){case Some(_)=>
                match(retainedChild){case Some(value)=>if(!value.isAcknowledged()){
                    return retainedOutputError("tool.prepared_input_ack_pending")}
                    case None=>return retainedOutputError("tool.prepared_input_known_child_missing")}
                case None=>if(retainedChild.isSome()){
                    return retainedOutputError("tool.prepared_rejection_effect_changed")}}
            match(referenceResources){case Some(value)=>if(value.failure().isSome()){
                return retainedOutputError("tool.prepared_input_resources_pending")};case None=>()}
            Result.Ok(())
        }finally{lock.unlock()}
    }
    func preparedControlFieldsWitness():Result<OwnedKernelPreparedControlFieldsWitness>{
        match(references){case Some(value)=>value.controlFieldsWitness()
            case None=>ownedPreparedWaitingError<OwnedKernelPreparedControlFieldsWitness>("tool.prepared_waiting_paid_control_required")}
    }
    public func prepareChild(context:ToolInvocationContext,call:ToolCall,requestKey:String):Result<ToolPreparation>{
        lock.lock();try{
        match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(preparedInputMode){return ownedPreparedWaitingError<ToolPreparation>("tool.prepared_input_action_only")}
        match(references){case Some(value)=>
            let paid=value.prepayPreparation(prepare(context,call,requestKey))
            if(paid.isError()){pending=true};return paid
            case None=>()}
        prepare(context,call,requestKey)}finally{lock.unlock()}
    }
    public func executeChild(context:ToolInvocationContext,child:PreparedToolInvocation):Result<ToolInvocationResult>{
        lock.lock();try{
        match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(references.isSome()){return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "tool.prepared_reference_retained_entry_required","paid reference execution requires the actual checked retained-output entrypoint"))}
        execute(context,child)}finally{lock.unlock()}
    }
    public func executeRetainedChild(context:ToolInvocationContext,child:PreparedToolInvocation,
        custody:LiveToolExecutionCustody):Result<OwnedToolRetainedChildExecution>{
        lock.lock();try{
            match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(preparedInputMode && (preparedInputChild.isNone() || !refEq(preparedInputChild.getOrThrow(),child))){
                return ownedPreparedWaitingError<OwnedToolRetainedChildExecution>("tool.prepared_input_exact_child_changed")}

            match(references){case Some(value)=>match(value.prepayChildReference(child,false)){
                case Result.Err(error)=>pending=true;return Result.Err(error);case Result.Ok(_)=>()};case None=>()}
            let actual=match(executeRetained){case Some(value)=>value;case None=>return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,"tool.retained_child_executor_unavailable","this control has no actual retained child entrypoint"))}
            // Fail closed after admitting this precise effect even if it
            // returns an outer Err; an unknown write cannot be prepared again.
            pending=true
            match(actual(context,child,custody)){case Result.Err(error)=>Result.Err(error)
                case Result.Ok(value)=>retainedChild=Some(value);pending=false;Result.Ok(value)}
        }finally{lock.unlock()}
    }
    public func awaitChild(child:PreparedToolInvocation,custody:LiveToolExecutionCustody):Result<OwnedToolExecutionProgress>{
        lock.lock()
        try{
        match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(preparedInputMode){return ownedPreparedWaitingError<OwnedToolExecutionProgress>("tool.prepared_input_action_only")}
        match(references){case Some(value)=>match(value.prepayChildReference(child,true)){
            case Result.Err(error)=>pending=true;return Result.Err(error);case Result.Ok(_)=>()};case None=>()}
        pending=true
        // Once a precise pending child is selected this invocation can never
        // prepare/execute a later effect, including after capture failure.
        match(capture(child,custody)){case Result.Err(error)=>Result.Err(error)
            case Result.Ok(value)=>Result.Ok(OwnedToolExecutionProgress.Waiting(value))}
        }finally{lock.unlock()}
    }
    // NEW data-holder route. Legacy awaitChild/public immutable Waiting is
    // unchanged. Only actual paid custody, complete invoice and the SAME
    // original private Kernel capture/current Source gate admit this holder.
    public func awaitPreparedPhase(child:PreparedToolInvocation,
        custody:OwnedKernelPreparedReferenceCustody):Result<OwnedPreparedWaitingPhase>{
        lock.lock();try{
            match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(preparedInputMode){return ownedPreparedWaitingError<OwnedPreparedWaitingPhase>("tool.prepared_input_action_only")}
            let debt=match(references){case Some(value)=>value;case None=>return ownedPreparedWaitingError<OwnedPreparedWaitingPhase>(
                "tool.prepared_waiting_paid_control_required")}
            if(!debt.matchesCustody(custody)){
                return ownedPreparedWaitingError<OwnedPreparedWaitingPhase>("tool.prepared_waiting_custody_changed")}
            match(debt.prepayChildReference(child,true)){
                case Result.Err(error)=>pending=true;return Result.Err(error);case Result.Ok(_)=>()}
            pending=true
            // The captured raw proof stays private in the mutable holder;
            // no ordinary public continuation or Prepared getter escapes.
            // Its fields remain fully paid by the adopted same-bank debt.
            match(capture(child,custody)){
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(actual)=>
                    if(!actual.sameCustody(custody) || !refEq(actual.child,child) ||
                        !refEq(actual.parent,debt.actualParent().getOrThrow())){
                        return ownedPreparedWaitingError<OwnedPreparedWaitingPhase>("tool.prepared_waiting_capture_changed")}
                    Result.Ok(OwnedPreparedWaitingPhase(actual,debt,custody))}
        }finally{lock.unlock()}
    }
    // A captured terminal prevents later child preparation/execution even
    // before the Pipeline performs the independent SQL/FD terminal proof.
    public func completeParent(result:ToolResult,dataOwner:OperationTerminalDataOwner):Result<OwnedToolExecutionProgress>{
        lock.lock();try{
            match(available()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(preparedInputMode){return ownedPreparedWaitingError<OwnedToolExecutionProgress>("tool.prepared_input_action_only")}
            let parent=match(terminalParent){case Some(value)=>value;case None=>return ownedControlError<OwnedToolExecutionProgress>()}
            if(result.callId!=parent.call.callId || result.receiptId!=parent.operationId.value || result.payloadLease.isNone()){
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"tool.live_terminal_capture_changed",
                    "terminal output must retain this invocation's actual parent allocation"))}
            match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            terminalCaptured=true
            Result.Ok(OwnedToolExecutionProgress.Terminal(OwnedToolTerminalCompletion(parent,result,dataOwner,terminalIdentity)))
        }finally{lock.unlock()}
    }
    func ownsTerminal(value:OwnedToolTerminalCompletion,parent:PreparedToolInvocation):Bool{
        lock.lock();try{terminalCaptured && value.capturedBy(terminalIdentity,parent)}finally{lock.unlock()}
    }
    func retainedFailure():?OwnedToolRetainedFailureExecution{
        match(retainedResources){case Some(actual)=>actual.failure();case None=>None<OwnedToolRetainedFailureExecution>}
    }
    func close():Unit{lock.lock();try{active=false
        if(preparedInputMode){preparedInputChild=None<PreparedToolInvocation>}
        match(references){case Some(value)=>
            // Only actual typed output/cleanup acknowledgement can remove
            // these other Kernel fields. Unknown effects retain collector
            // debt and cannot mint even the limited control-fields witness.
            let childRetired=match(retainedChild){case Some(child)=>child.isAcknowledged();case None=>true}
            let resourcesRetired=match(referenceResources){case Some(resources)=>resources.failure().isNone();case None=>true}
            if(childRetired && resourcesRetired){
                retainedChild=None<OwnedToolRetainedChildExecution>
                referenceResources=None<OwnedRetainedInvocationResources>}
            value.clearAfterInvocation(childRetired && resourcesRetired)
            case None=>()}
    }finally{lock.unlock()}}
}
func ownedControlError<T>():Result<T>{
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"tool.live_control_closed",
        "owned synchronous execution control is no longer available"))
}
