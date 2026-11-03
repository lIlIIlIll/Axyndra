package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

class CoreRetainedCanonicalCommitFlag {var committed=false}
class CoreRetainedToolCompletion {
    let work:CorePreparedTool
    let output:OwnedToolRetainedParentExecution
    let remaining:CoreToolBatchPreparation
    let handoffStarted:Bool
    let settlementError:?AgentError
    init(work:CorePreparedTool,output:OwnedToolRetainedParentExecution,
        remaining:CoreToolBatchPreparation,handoffStarted:Bool,settlementError:?AgentError){
        this.work=work;this.output=output;this.remaining=remaining
        this.handoffStarted=handoffStarted;this.settlementError=settlementError
    }
}
class CoreRetainedResultAckDebt {
    let output:OwnedToolRetainedParentExecution
    var canonicalCommitted=false
    init(output:OwnedToolRetainedParentExecution){this.output=output}
}
class CoreRetainedFailureCleanupDebt {
    let output:OwnedToolRetainedFailureExecution
    init(output:OwnedToolRetainedFailureExecution){this.output=output}
}
class CoreRetainedFailureCompletion {
    let output:OwnedToolRetainedFailureExecution
    let error:AgentError
    let outerSettlement333:?AgentError
    let outerSettlementBlocked333:Bool
    init(output:OwnedToolRetainedFailureExecution,error:AgentError,outerSettlement333!:?AgentError=None<AgentError>,
        outerSettlementBlocked333!:Bool=false){
        this.output=output;this.error=error;this.outerSettlement333=outerSettlement333
        this.outerSettlementBlocked333=outerSettlementBlocked333}
}
