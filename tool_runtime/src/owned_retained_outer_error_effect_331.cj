package tool_runtime

import agent_domain.*
import agent_runtime.*

// New trusted in-process DATA carrier. Original retained effect methods and
// their old default routes remain unchanged. Kernel must independently use
// the existing actual Source/normal approval/handoff/execution checks first.
// A Failed value owns complete error DATA only; never a Known/Receipt proof.
public interface RetainedOwnedToolOuterErrorEffectExecutor331 {
    func executeRetainedOuterErrorEffect331(context:ToolInvocationContext,
        parent:PreparedToolInvocation,child:PreparedToolInvocation,
        custody:LiveToolExecutionCustody):OwnedRetainedOuterErrorEffectOutcome331
}
public enum OwnedRetainedOuterErrorEffectOutcome331 {
    Existing(OwnedRetainedToolEffectOutcome)
    | Failed(PluginLivePolicyOuterErrorDataOwner331,AcknowledgedOperationTerminalDataOwner)
}
// Failed contains NO public raw AgentError/Result.Err/Prepared getter. Its
// real Store owner exposes a lexical borrowed error and remains default
// closed/paid until actual Core registry/event/caller aliases are funded and
// retired. No private retirement-token issuer is invented here.
