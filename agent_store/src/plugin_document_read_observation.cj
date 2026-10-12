package agent_store

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_runtime.*
import std.sync.*

// Created only after private-source/current-Run/complete-plan/handoff checks
// in readPluginDocuments, while its original transaction is still active.
public class SqlitePluginDocumentReadProof <: PluginDocumentReadProof {
    private let transaction: SqliteTransaction
    private let lock = Mutex()
    private var active = true
    private let actualThread: ThreadId
    private let actualRun: RunId
    private let actualOperation: OperationId
    private let actualLane: LaneId
    private let encodedPlan: String
    public prop threadId: ThreadId { get() { actualThread } }
    public prop runId: RunId { get() { actualRun } }
    public prop operationId: OperationId { get() { actualOperation } }
    public prop laneId: LaneId { get() { actualLane } }

    init(transaction: SqliteTransaction, source: DirectToolCallRef, plan: NormalizedOperationPlan) {
        this.transaction = transaction; this.actualThread = source.threadId
        this.actualRun = source.runId; this.actualOperation = source.operationId
        this.actualLane = LaneId(httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(), "lane_id"))
        this.encodedPlan = encodeOperationPlan(plan)
    }
    public func plan(): NormalizedOperationPlan { decodeOperationPlan(encodedPlan) }
    public func withTransaction(action: (SqliteTransaction) -> Result<AgentValue>): Result<AgentValue> {
        lock.lock()
        try {
            if (!active) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "plugin.document_read_window_closed", "document observation transaction has expired")) }
            active = false
            action(transaction)
        } finally { lock.unlock() }
    }
    func close(): Unit { lock.lock(); try { active = false } finally { lock.unlock() } }
}
