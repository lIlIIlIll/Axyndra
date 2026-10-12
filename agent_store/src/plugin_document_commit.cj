package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*

// Constructed only after exact ParentIntent verification and the real child
// Receipt INSERT in the same transaction. A retained object cannot reopen a
// later transaction or authorize another document/Run/control action.
public class SqlitePluginDocumentCommitProof <: PluginDocumentCommitProof {
    private let transaction: SqliteTransaction
    private let lock = Mutex()
    private var active = true
    private let actualRun: RunId
    private let actualParent: OperationId
    private let actualOperation: OperationId
    private let planEncoded: String
    private let receiptId: String
    private let detailEncoded: String
    private let verificationEncoded: String
    private let observedAt: Int64
    public prop runId: RunId { get() { actualRun } }
    public prop parentOperationId: OperationId { get() { actualParent } }
    public prop operationId: OperationId { get() { actualOperation } }

    init(transaction: SqliteTransaction, run: RunId, parent: OperationId, plan: NormalizedOperationPlan,
        receipt: VNextOperationReceipt) {
        this.transaction = transaction; this.actualRun = run; this.actualParent = parent; this.actualOperation = receipt.operationId
        this.planEncoded = encodeOperationPlan(plan); this.receiptId = receipt.receiptId
        this.detailEncoded = encodeStoredValue(receipt.detail); this.verificationEncoded = encodeStoredValue(receipt.verification)
        this.observedAt = receipt.observedAtMillis
    }
    public func plan(): NormalizedOperationPlan { decodeOperationPlan(planEncoded) }
    public func receipt(): VNextOperationReceipt {
        VNextOperationReceipt(receiptId, actualOperation, OperationOutcome.Completed,
            decodeStoredValue(detailEncoded), decodeStoredValue(verificationEncoded), observedAt)
    }
    public func withTransaction(action: (SqliteTransaction) -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (!active) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "plugin.document_commit_window_closed", "document transaction proof has expired")) }
            // One trusted participant may consume this window once. Merely
            // retaining the interface or rereading a getter cannot reset it.
            active = false
            action(transaction)
        } finally { lock.unlock() }
    }
    func close(): Unit { lock.lock(); try { active = false } finally { lock.unlock() } }
}
