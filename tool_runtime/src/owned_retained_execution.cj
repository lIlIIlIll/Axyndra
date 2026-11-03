package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*

// A real installed typed executor receives the already verified actual parent
// and SAME invocation custody from Kernel. Neither is reconstructed from IDs.
public interface RetainedOwnedToolEffectExecutor {
    func executeRetainedEffect(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,custody:LiveToolExecutionCustody):OwnedRetainedToolEffectOutcome
}
public class OwnedRetainedToolEffectOutcome {
    public let execution:ToolExecutionOutcome
    public let dataOwner:AcknowledgedOperationTerminalDataOwner
    public let cleanupLease:?ToolResultPayloadLease
    public init(execution:ToolExecutionOutcome,dataOwner:AcknowledgedOperationTerminalDataOwner,
        cleanupLease!:?ToolResultPayloadLease=None<ToolResultPayloadLease>){
        this.execution=execution;this.dataOwner=dataOwner;this.cleanupLease=cleanupLease
    }
}

// Allocation/resource ownership only. Constructor is private to this package;
// only the independently verified actual Pipeline may transfer a known output.
class OwnedRetainedOutputState <: OwnedRetainedCleanupResource {
    private let lock=Mutex()
    private var result:?ToolResult
    private var owner:?AcknowledgedOperationTerminalDataOwner
    private var canonicalBacking:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    private let lease:ToolResultPayloadLease
    private var borrowed=false
    private var consumed=false
    private var closing=false
    private var outputAcknowledged=false
    private var acknowledged=false
    private var afterOutputClose:?(() -> Result<Unit>)=None<(() -> Result<Unit>)>
    init(result:ToolResult,owner:AcknowledgedOperationTerminalDataOwner){
        this.result=Some(result);this.owner=Some(owner);lease=result.payloadLease.getOrThrow()
    }
    func prepareCanonicalBacking():Result<Unit>{
        lock.lock()
        let actual:AcknowledgedOperationTerminalDataOwner=try{
            if(canonicalBacking.isSome()){return Result.Ok(())}
            if(borrowed || closing || acknowledged || result.isNone() || owner.isNone()){
                return retainedOutputError("tool.retained_canonical_backing_unavailable")}
            borrowed=true;owner.getOrThrow()
        }finally{lock.unlock()}
        let retained:Result<LogicalJsonOwnerReservation>=try{actual.retainCanonicalBacking(lease)}
            catch(_:Exception){Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.retained_canonical_backing_unavailable","same actual decoded backing could not be retained"))}
        let paid:Result<Unit>=match(retained){case Result.Err(error)=>Result<Unit>.Err(error)
            case Result.Ok(payment)=>try{
                // The original output DOM/backing charge remains pinned by
                // the shared ledger. Add envelope/transition/item/result
                // wrapper cells before the original canonical consumer.
                payment.ensureRetainedPeak(8192)
                lock.lock();try{canonicalBacking=Some(payment)}finally{lock.unlock()}
                Result.Ok(())
            }catch(_:Exception){payment.close();retainedOutputError("tool.retained_canonical_backing_capacity")}}
        lock.lock();try{borrowed=false}finally{lock.unlock()}
        paid
    }
    func isCanonicalBackingRetained():Bool{lock.lock();try{canonicalBacking.isSome()}finally{lock.unlock()}}
    func withOutput(consume:(ToolResult)->Result<Unit>):Result<Unit>{
        lock.lock()
        var actual:?ToolResult=try{
            if(borrowed || closing || acknowledged || result.isNone()){
                return retainedOutputError("tool.retained_output_unavailable")}
            borrowed=true;Some(result.getOrThrow())
        }finally{lock.unlock()}
        let returned=try{consume(actual.getOrThrow())}catch(_:Exception){retainedOutputError("tool.retained_output_consumer_failed")}
        actual=None<ToolResult>
        lock.lock();try{borrowed=false;consumed=true}finally{lock.unlock()}
        returned
    }
    func appendActualCustodyClose(close:()->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(borrowed || closing || acknowledged || afterOutputClose.isSome()){
                return retainedOutputError("tool.retained_custody_changed")}
            afterOutputClose=Some(close);Result.Ok(())
        }finally{lock.unlock()}
    }
    func closeAfterConsumption():Result<Unit>{
        lock.lock()
        let actual:?AcknowledgedOperationTerminalDataOwner=try{
            if(acknowledged){return Result.Ok(())}
            if(borrowed || closing || !consumed){return retainedOutputError("tool.retained_output_borrowed")}
            // This is the last Kernel large ToolResult handle. Caller callback
            // and all its temporary canonical consumer frames already ended.
            result=None<ToolResult>;closing=true;owner
        }finally{lock.unlock()}
        let closed:Result<Unit>=try{
            let released=if(outputAcknowledged){Result<Unit>.Ok(())}else{
                actual.getOrThrow().closeRetainedOutput(lease)}
            match(released){case Result.Err(error)=>Result<Unit>.Err(error)
                case Result.Ok(_)=>
                    // Unit bookkeeping follows the checked SAME physical ACK;
                    // its one-shot released flag is never the acknowledgement.
                    lock.lock();try{outputAcknowledged=true}finally{lock.unlock()}
                    lease.close()
                    match(afterOutputClose){case Some(close)=>close();case None=>Result.Ok(())}
            }
        }catch(_:Exception){retainedOutputError("tool.retained_output_cleanup_pending")}
        lock.lock();try{
            closing=false
            match(closed){case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>owner=None<AcknowledgedOperationTerminalDataOwner>
                    afterOutputClose=None<(() -> Result<Unit>)>;acknowledged=true;Result.Ok(())}
        }finally{lock.unlock()}
    }
    public func closeAfterFailure():Result<Unit>{
        lock.lock();try{
            if(borrowed || closing){return retainedOutputError("tool.retained_output_borrowed")}
            consumed=true
        }finally{lock.unlock()}
        closeAfterConsumption()
    }
    public func isAcknowledged():Bool{lock.lock();try{acknowledged}finally{lock.unlock()}}
}
public class OwnedToolRetainedChildExecution {
    private let output:OwnedRetainedOutputState
    func failureResource():OwnedRetainedCleanupResource{output}
    init(result:ToolResult,owner:AcknowledgedOperationTerminalDataOwner){output=OwnedRetainedOutputState(result,owner)}
    public func withOutput(consume:(ToolResult)->Result<Unit>):Result<Unit>{output.withOutput(consume)}
    public func closeAfterConsumption():Result<Unit>{output.closeAfterConsumption()}
    public func isAcknowledged():Bool{output.isAcknowledged()}
}
public class OwnedToolRetainedParentExecution {
    private let output:OwnedRetainedOutputState
    init(result:ToolResult,owner:AcknowledgedOperationTerminalDataOwner){output=OwnedRetainedOutputState(result,owner)}
    public func withOutput(consume:(ToolResult)->Result<Unit>):Result<Unit>{output.withOutput(consume)}
    public func closeAfterConsumption():Result<Unit>{output.closeAfterConsumption()}
    public func isAcknowledged():Bool{output.isAcknowledged()}
    public func prepareCanonicalBacking():Result<Unit>{output.prepareCanonicalBacking()}
    public func isCanonicalBackingRetained():Bool{output.isCanonicalBackingRetained()}
    func appendActualCustodyClose(close:()->Result<Unit>):Result<Unit>{output.appendActualCustodyClose(close)}
}
class OwnedRetainedChildRequest {
    let parent:PreparedToolInvocation
    let custody:LiveToolExecutionCustody
    private var owner:?AcknowledgedOperationTerminalDataOwner=None<AcknowledgedOperationTerminalDataOwner>
    private var cleanupLease:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    private var unverified:?ToolResult=None<ToolResult>
    private var completed:?OwnedToolRetainedChildExecution=None<OwnedToolRetainedChildExecution>
    private var handed:?OwnedToolRetainedChildExecution=None<OwnedToolRetainedChildExecution>
    private var failed:?OwnedRetainedCleanupResource=None<OwnedRetainedCleanupResource>
    private var outerError333:?PluginLivePolicyOuterErrorDataOwner331=None<PluginLivePolicyOuterErrorDataOwner331>
    init(parent:PreparedToolInvocation,custody:LiveToolExecutionCustody){this.parent=parent;this.custody=custody}
    func execute(executor:RetainedOwnedToolEffectExecutor,context:ToolInvocationContext,
        actualParent:PreparedToolInvocation,child:PreparedToolInvocation):ToolExecutionOutcome{
        if(!refEq(parent,actualParent) || owner.isSome()){
            return ToolExecutionOutcome(Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "tool.retained_parent_changed","actual retained child parent cannot be replaced")))}
        let actual=match(executor as RetainedOwnedToolOuterErrorEffectExecutor331){
            case None=>executor.executeRetainedEffect(context,parent,child,custody)
            case Some(typed)=>match(invokeOwnedOuterErrorFrame334(typed,context,parent,child,custody)){
                case OwnedRetainedOuterErrorEffectOutcome331.Existing(value)=>value
                case OwnedRetainedOuterErrorEffectOutcome331.Failed(data,physical)=>
                    owner=Some(physical);outerError333=Some(data)
                    // A control signal only. The full error never enters old
                    // raw Result/describe paths; its actual owner travels with
                    // the same unacknowledged failure resource to Core.
                    return ToolExecutionOutcome(ownedOuterErrorConsumerError333<ToolResult>(
                        "tool.owned_outer_error_pending"))}}
        owner=Some(actual.dataOwner);cleanupLease=actual.cleanupLease
        match(actual.execution.result){case Result.Ok(value)=>retainUnverified(value);case Result.Err(_)=>()}
        actual.execution
    }
    func outerErrorData333():?PluginLivePolicyOuterErrorDataOwner331{outerError333}
    func retainUnverified(output:ToolResult):Unit{
        unverified=Some(output)
        if(output.payloadLease.isSome()){cleanupLease=output.payloadLease}
    }
    func capture(output:ToolResult):Result<Unit>{
        if(owner.isNone() || completed.isSome() || output.payloadLease.isNone()){
            return retainedOutputError("tool.retained_child_owner_missing")}
        completed=Some(OwnedToolRetainedChildExecution(output,owner.getOrThrow()))
        owner=None<AcknowledgedOperationTerminalDataOwner>;cleanupLease=None<ToolResultPayloadLease>;unverified=None<ToolResult>
        Result.Ok(())
    }
    func take():Result<OwnedToolRetainedChildExecution>{
        let value=match(completed){case Some(actual)=>actual;case None=>return Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,"tool.retained_child_output_missing","actual child returned no retained terminal output"))}
        completed=None<OwnedToolRetainedChildExecution>;handed=Some(value);Result.Ok(value)
    }
    func failureResource():?OwnedRetainedCleanupResource{
        match(failed){case Some(value)=>return Some(value);case None=>()}
        let returned=match(handed){case Some(value)=>Some(value);case None=>completed}
        match(returned){case Some(value)=>
            if(value.isAcknowledged()){return None<OwnedRetainedCleanupResource>}
            let resource=value.failureResource();failed=Some(resource);return Some(resource)
            case None=>()}
        // Even an exception before an output exists keeps the SAME actual
        // custody. No output/lease/Receipt is manufactured for this failure.
        let resource=OwnedRetainedUnpublishedState(unverified,owner,cleanupLease,custody)
        unverified=None<ToolResult>;owner=None<AcknowledgedOperationTerminalDataOwner>;cleanupLease=None<ToolResultPayloadLease>
        failed=Some(resource);Some(resource)
    }
}
func retainedOutputError(code:String):Result<Unit>{Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
    code,"same actual output/data owner retains its unacknowledged cleanup debt"))}
