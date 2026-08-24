package agent_runtime

import std.deriving.*
import agent_domain.*

@Derive[Equatable]
public enum RecoveryActionKind {
    CreateOrReconcileOperation
    | RequestApprovalOnce
    | FinalizeRejectedApproval
    | ExecuteByRetryPolicy
    | RequireUnknownOutcomeReconciliation
    | FinalizeFromReceipt
    | AppendToolResultOnce
    | AdvanceRunWithoutDuplicate
}

// RecoveryAction describes the only safe next durable action. It never claims
// that an external effect did or did not happen without persisted evidence.
public class RecoveryAction {
    public let kind: RecoveryActionKind
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let toolCallItemId: ItemId
    public let operationId: ?OperationId
    public let reason: String

    public init(
        kind: RecoveryActionKind,
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        toolCallItemId: ItemId,
        operationId!: ?OperationId = None,
        reason!: String = ""
    ) {
        this.kind = kind
        this.threadId = threadId
        this.turnId = turnId
        this.runId = runId
        this.toolCallItemId = toolCallItemId
        this.operationId = operationId
        this.reason = reason
    }
}
