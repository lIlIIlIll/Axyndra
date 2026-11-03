package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// New caller result for the opt-in 331 executor. Existing AgentRunner and
// Result<AgentRunOutcome> signatures are unchanged. Pending is complete paid
// error data with publication debt, not a fabricated successful Run outcome.
public enum OwnedAgentRunResult333 {
    Existing(Result<AgentRunOutcome>)
    | Failed(OwnedOuterErrorFailure333)
    | Pending(OwnedOuterErrorPending333)
    // No owner/error/string alias escapes if even wrapper capture cannot be
    // funded. The actual Core registry still retains the complete paid debt.
    | Held
}

func coreOwnedOuterErrorSource333(output:OwnedToolRetainedFailureExecution):?PluginLivePolicyPaidOuterErrorSource333{
    match(output.outerErrorData333()){
        case Some(value)=>value as PluginLivePolicyPaidOuterErrorSource333
        case None=>None<PluginLivePolicyPaidOuterErrorSource333>}
}
func coreOwnedOuterErrorPayAlias333(source:PluginLivePolicyPaidOuterErrorSource333,error:AgentError):Result<Unit>{
    source.withPaidError333({_,fund=>fund(ownedOuterErrorRetainedPeak333(error))})
}
func coreOwnedOuterErrorPending333():AgentError{
    AgentError(AgentErrorKind.RecoveryRequired,"run.owned_outer_error_pending",
        "actual outer error is retained in the same Run's paid typed failure owner")
}
