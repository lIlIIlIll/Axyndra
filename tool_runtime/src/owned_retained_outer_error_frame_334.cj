package tool_runtime

import agent_domain.*
import agent_runtime.*

// Trusted opt-in only. The actual Host resolves its private same-Session
// custody before funding; Native data cannot provide a frame or allocation.
public interface RetainedOwnedToolOuterErrorFrameExecutor334 <: RetainedOwnedToolOuterErrorEffectExecutor331 {
    func retainOuterErrorFrame334(parent:PreparedToolInvocation,
        custody:LiveToolExecutionCustody):Result<PluginLivePolicyOuterErrorFrame334>
    func executeRetainedOuterErrorFrame334(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,custody:LiveToolExecutionCustody,
        frame:PluginLivePolicyOuterErrorFrame334):OwnedRetainedOuterErrorEffectOutcome331
}

func invokeOwnedOuterErrorFrame334(executor:RetainedOwnedToolOuterErrorEffectExecutor331,
    context:ToolInvocationContext,parent:PreparedToolInvocation,child:PreparedToolInvocation,
    custody:LiveToolExecutionCustody):OwnedRetainedOuterErrorEffectOutcome331{
    match(executor as RetainedOwnedToolOuterErrorFrameExecutor334){
        case None=>executor.executeRetainedOuterErrorEffect331(context,parent,child,custody)
        case Some(actual)=>
            let frame=match(actual.retainOuterErrorFrame334(parent,custody)){
                case Result.Ok(value)=>value
                case Result.Err(_)=>throw IllegalStateException("actual same-Session frame payment is unavailable")}
            // The old Store catch/mapper, Artifact, Session, effect factory
            // and typed adapter all return before this invocation is marked.
            // Result data is already an independent paid eight-field copy.
            frame.invoke({owned=>actual.executeRetainedOuterErrorFrame334(context,parent,child,custody,owned)})
    }
}
