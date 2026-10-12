package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*

// Resource cleanup only. These objects cannot be used as a Known result,
// Source, approval, terminal proof or canonical receipt.
interface OwnedRetainedCleanupResource {
    func closeAfterFailure():Result<Unit>
    func isAcknowledged():Bool
}
class OwnedRetainedUnpublishedState <: OwnedRetainedCleanupResource {
    private let lock=Mutex()
    private var result:?ToolResult
    private var owner:?AcknowledgedOperationTerminalDataOwner
    private let lease:?ToolResultPayloadLease
    private let custody:LiveToolExecutionCustody
    private var closing=false
    private var ownerAcknowledged=false
    private var acknowledged=false
    init(result:?ToolResult,owner:?AcknowledgedOperationTerminalDataOwner,
        lease:?ToolResultPayloadLease,custody:LiveToolExecutionCustody){
        this.result=result;this.owner=owner;this.lease=lease;this.custody=custody
        ownerAcknowledged=owner.isNone() && lease.isNone()
    }
    public func closeAfterFailure():Result<Unit>{
        lock.lock();try{
            if(acknowledged){return Result.Ok(())}
            if(closing){return retainedOutputError("tool.retained_failure_close_pending")}
            result=None<ToolResult>;closing=true
        }finally{lock.unlock()}
        let closed:Result<Unit>=try{
            let released=if(ownerAcknowledged){Result<Unit>.Ok(())}else{
                match(owner){case None=>retainedOutputError("tool.retained_failure_owner_missing")
                    case Some(actual)=>match(lease){
                        case Some(allocation)=>actual.closeRetainedOutput(allocation)
                        case None=>actual.closeUnpublishedOutput()}}}
            match(released){case Result.Err(error)=>Result<Unit>.Err(error)
                case Result.Ok(_)=>
                    lock.lock();try{ownerAcknowledged=true}finally{lock.unlock()}
                    match(lease){case Some(allocation)=>allocation.close();case None=>()}
                    custody.close()}
        }catch(_:Exception){retainedOutputError("tool.retained_failure_cleanup_pending")}
        lock.lock();try{closing=false
            match(closed){case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>owner=None<AcknowledgedOperationTerminalDataOwner>;acknowledged=true;Result.Ok(())}
        }finally{lock.unlock()}
    }
    public func isAcknowledged():Bool{lock.lock();try{acknowledged}finally{lock.unlock()}}
}
class OwnedRetainedCallbackCleanup <: OwnedRetainedCleanupResource {
    private let close:()->Result<Unit>
    private let lock=Mutex()
    private var acknowledged=false
    init(close:()->Result<Unit>){this.close=close}
    public func closeAfterFailure():Result<Unit>{lock.lock();try{
        if(acknowledged){return Result.Ok(())}
        match(close()){case Result.Err(error)=>Result.Err(error)
            case Result.Ok(_)=>acknowledged=true;Result.Ok(())}
    }finally{lock.unlock()}}
    public func isAcknowledged():Bool{lock.lock();try{acknowledged}finally{lock.unlock()}}
}
public class OwnedToolRetainedFailureExecution {
    private let resources:ArrayList<OwnedRetainedCleanupResource>
    private let outerError333:?PluginLivePolicyOuterErrorDataOwner331
    init(resources:Array<OwnedRetainedCleanupResource>,outerError333!:?PluginLivePolicyOuterErrorDataOwner331=None<PluginLivePolicyOuterErrorDataOwner331>){
        this.resources=ArrayList<OwnedRetainedCleanupResource>(resources);this.outerError333=outerError333}
    public func outerErrorData333():?PluginLivePolicyOuterErrorDataOwner331{outerError333}
    func appendActualCustodyClose(close:()->Result<Unit>):Unit{resources.add(OwnedRetainedCallbackCleanup(close))}
    public func closeAfterFailure():Result<Unit>{
        var error:?AgentError=None<AgentError>
        for(resource in resources){
            let closed=try{resource.closeAfterFailure()}catch(_:Exception){retainedOutputError("tool.retained_failure_cleanup_pending")}
            match(closed){case Result.Err(value)=>if(error.isNone()){error=Some(value)};case Result.Ok(_)=>()}}
        match(error){case Some(value)=>Result.Err(value);case None=>Result.Ok(())}
    }
    public func isAcknowledged():Bool{
        for(resource in resources where !resource.isAcknowledged()){return false};true
    }
}
class OwnedRetainedInvocationResources {
    private let requests=ArrayList<OwnedRetainedChildRequest>()
    func admit(request:OwnedRetainedChildRequest):Unit{requests.add(request)}
    func failure():?OwnedToolRetainedFailureExecution{
        let resources=ArrayList<OwnedRetainedCleanupResource>()
        var outer:?PluginLivePolicyOuterErrorDataOwner331=None<PluginLivePolicyOuterErrorDataOwner331>
        for(request in requests){
            match(request.failureResource()){case Some(value)=>resources.add(value);case None=>()}
            match(request.outerErrorData333()){case Some(value)=>if(outer.isNone()){outer=Some(value)};case None=>()}}
        if(resources.isEmpty()){None<OwnedToolRetainedFailureExecution>}else{
            Some(OwnedToolRetainedFailureExecution(resources.toArray(),outerError333:outer))}
    }
}
