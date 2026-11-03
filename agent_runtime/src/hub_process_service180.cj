package agent_runtime

import agent_domain.*

// This port extends the authority of an ACTUAL handed-off Derived child to a
// named resource incarnation. It does not create a Model/Managed grant, Source,
// Receipt, Run, or a new budget. The Store reserves once before physical launch
// and subsequently checks the exact original admission and revocation record.
public interface HubDerivedProcessServicePort180 {
    func reserveHubProcessService180(source: OperationRootSource, parent: OperationId,
        child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
        plan: NormalizedOperationPlan): Result<Unit>
    func verifyHubProcessService180(source: OperationRootSource, parent: OperationId,
        child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
        plan: NormalizedOperationPlan): Result<Unit>
    func revokeHubProcessService180(source: OperationRootSource, parent: OperationId,
        child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
        plan: NormalizedOperationPlan): Result<Unit>
}
