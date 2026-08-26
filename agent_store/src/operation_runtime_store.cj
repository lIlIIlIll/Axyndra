package agent_store

import yjson_support.*

import yjson.*

import std.collection.*
import agent_domain.*
import agent_runtime.*

// DurableOperationStore owns the persisted pre-effect state machine. The
// executor receives a plan only after markExecutionHandoff() commits; recovery
// therefore treats every handed-off mutation without a Receipt as Unknown.
public class DurableOperationStore <: OperationRuntimePort {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    // Programmatic Runs produce their own canonical ToolCall Items rather
    // than Model Decision blocks. They still use the same immutable effect
    // record, state register, handoff and Receipt tables.
    public func prepareProgramSubOperation(
        operationId: OperationId,
        runId: RunId,
        toolCallItemId: ItemId,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        let encodedPlan = encodeOperationPlan(plan)
        try {
            database.transaction { transaction =>
                requireStoreRow(
                    transaction,
                    "SELECT runs.id FROM runs JOIN items ON items.id=" +
                        sqliteText(toolCallItemId.value) +
                        " AND items.thread_id=runs.thread_id AND items.turn_id=runs.turn_id " +
                        "JOIN threads ON threads.id=runs.thread_id WHERE runs.id=" +
                        sqliteText(runId.value) +
                        " AND items.kind='tool_call' AND runs.state='running' " +
                        "AND threads.active_turn_id=runs.turn_id",
                    [runId.value],
                    "Program Operation does not own a canonical ToolCall"
                )
                transaction.execute(
                    "INSERT INTO operations " +
                        "(id,run_id,tool_call_item_id,normalized_plan,capability_requirement," +
                        "resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) " +
                        "VALUES (?,?,?,?,?,?,?,?,?,'prepared',1)",
                    [
                        SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
                        SqlParameter.Text(toolCallItemId.value), SqlParameter.Text(encodedPlan),
                        SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities)),
                        SqlParameter.Text(encodeResourceScope(plan)),
                        SqlParameter.Text(storeEffectName(plan.effectClass)),
                        SqlParameter.Text(storeRetryName(plan.retryDisposition)),
                        if (plan.idempotencyKey == "") {
                            SqlParameter.Null
                        } else {
                            SqlParameter.Text(plan.idempotencyKey)
                        }
                    ]
                )
                insertOperationEffectRecord(
                    transaction, operationId, runId, toolCallItemId, plan, encodedPlan
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.program_prepare_failed", operationId, error)
        }
    }

    public func prepare(
        operationId: OperationId,
        runId: RunId,
        toolCall: CommittedToolCallRef,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        let encodedPlan = encodeOperationPlan(plan)
        try {
            database.transaction { transaction =>
                requireStoreRow(
                    transaction,
                    "SELECT runs.id FROM runs JOIN items ON items.id=" +
                        sqliteText(toolCall.canonicalItemId.value) + " AND items.turn_id=runs.turn_id " +
                        "AND items.thread_id=runs.thread_id JOIN threads ON threads.id=runs.thread_id " +
                        "JOIN canonical_decision_items c ON c.item_id=items.id " +
                        "JOIN model_decision_blocks b ON b.id=c.decision_block_id " +
                        "JOIN model_decisions d ON d.id=c.decision_id " +
                        "WHERE runs.id=" + sqliteText(runId.value) +
                        " AND items.kind='tool_call' AND threads.active_turn_id=runs.turn_id " +
                        "AND runs.state IN ('running','waiting_external') " +
                        "AND d.id=" + sqliteText(toolCall.decisionId.value) +
                        " AND d.validation_status='validated' " +
                        "AND d.canonical_committed_at_millis IS NOT NULL " +
                        "AND b.scoped_tool_call_id=" + sqliteText(toolCall.scopedToolCallId.value),
                    [runId.value],
                    "Operation preparation does not own a durable ToolCall"
                )
                let existing = transaction.query(
                    "SELECT id,run_id,normalized_plan FROM operations WHERE tool_call_item_id=" +
                        sqliteText(toolCall.canonicalItemId.value)
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO operations " +
                            "(id,run_id,tool_call_item_id,normalized_plan,capability_requirement," +
                            "resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) VALUES (" +
                            sqliteText(operationId.value) + "," + sqliteText(runId.value) + "," +
                            sqliteText(toolCall.canonicalItemId.value) + "," + sqliteText(encodedPlan) + "," +
                            sqliteText(encodeCapabilities(plan.requiredCapabilities)) + "," +
                            sqliteText(encodeResourceScope(plan)) + "," +
                            sqliteText(storeEffectName(plan.effectClass)) + "," +
                            sqliteText(storeRetryName(plan.retryDisposition)) + "," +
                            optionalSqliteText(plan.idempotencyKey) + ",'prepared',1)"
                    )
                    insertOperationEffectRecord(
                        transaction, operationId, runId,
                        toolCall.canonicalItemId, plan, encodedPlan
                    )
                    transaction.execute(
                        "INSERT INTO decision_operations " +
                            "(decision_id,scoped_tool_call_id,operation_id) VALUES (" +
                            sqliteText(toolCall.decisionId.value) + "," +
                            sqliteText(toolCall.scopedToolCallId.value) + "," +
                            sqliteText(operationId.value) + ")"
                    )
                } else if (existing.size != 1 || existing[0].required(0) != operationId.value ||
                    existing[0].required(1) != runId.value || existing[0].required(2) != encodedPlan) {
                    throw IllegalStateException("ToolCall already has a different Operation plan")
                } else {
                    requireStoreRow(
                        transaction,
                        "SELECT operation_id FROM decision_operations WHERE decision_id=" +
                            sqliteText(toolCall.decisionId.value) +
                            " AND scoped_tool_call_id=" +
                            sqliteText(toolCall.scopedToolCallId.value),
                        [operationId.value],
                        "Operation source binding drift"
                    )
                    requireStoreRow(
                        transaction,
                        "SELECT normalized_plan FROM operation_effect_records WHERE operation_id=" +
                            sqliteText(operationId.value),
                        [encodedPlan],
                        "immutable Operation effect record drift"
                    )
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.prepare_failed", operationId, error)
        }
    }

    public func waitForApproval(operationId: OperationId, runId: RunId): Result<Unit> {
        transitionOperation(operationId, runId, "prepared", "waiting_approval")
    }

    public func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String
    ): Result<Unit> {
        recordApproval(
            approvalId, operationId, runId, reviewedPlan,
            capabilityCeiling, approved, source, None
        )
    }

    public func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String,
        expiresAtMillis: ?Int64
    ): Result<Unit> {
        if (approvalId.trimAscii() == "" ||
            source.trimAscii() == "" || match (expiresAtMillis) {
                case Some(value) => value < 0
                case None => false
            }) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "operation.approval_invalid",
                "approval identity, digest and source are required"
            ))
        }
        if (approved && !capabilitySetAllowsPlan(capabilityCeiling, reviewedPlan)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied, "operation.approval_ceiling_insufficient",
                "approval capability ceiling does not cover the reviewed Operation"
            ))
        }
        let encodedPlan = encodeOperationPlan(reviewedPlan)
        let encodedCeiling = encodeCapabilities(capabilityCeiling.values)
        let expectedDecision = if (approved) { "approved" } else { "rejected" }
        let expectedExpiry = match (expiresAtMillis) {
            case Some(value) => value.toString()
            case None => "-1"
        }
        try {
            database.transaction { transaction =>
                let operation = transaction.query(
                    "SELECT run_id,state,normalized_plan FROM operations WHERE id=" +
                        sqliteText(operationId.value)
                )
                if (operation.size != 1 || operation[0].required(0) != runId.value ||
                    operation[0].required(2) != encodedPlan) {
                    throw IllegalStateException(
                        "approval does not own the exact reviewed Operation"
                    )
                }
                let existing = transaction.query(
                    "SELECT id,operation_id,operation_digest,capability_ceiling,decision,source," +
                        "COALESCE(expires_at_millis,-1) FROM approvals WHERE operation_id=" +
                        sqliteText(operationId.value)
                )
                if (existing.isEmpty()) {
                    if (operation[0].required(1) != "waiting_approval") {
                        throw IllegalStateException(
                            "new approval no longer owns a waiting Operation"
                        )
                    }
                    transaction.execute(
                        "INSERT INTO approvals " +
                            "(id,operation_id,operation_digest,capability_ceiling,decision,source,expires_at_millis) VALUES (" +
                            sqliteText(approvalId.trimAscii()) + "," + sqliteText(operationId.value) + "," +
                            sqliteText(reviewedPlan.bindingDigest) + "," +
                            sqliteText(encodedCeiling) + "," + sqliteText(expectedDecision) + "," +
                            sqliteText(source.trimAscii()) + "," + optionalSqliteInt(expiresAtMillis) + ")"
                    )
                    transaction.execute(
                        "UPDATE operations SET state=" +
                            sqliteText(if (approved) { "prepared" } else { "rejected" }) +
                            ",revision=revision+1 WHERE id=" + sqliteText(operationId.value) +
                            " AND state='waiting_approval'"
                    )
                    requireStoreChanged(transaction, "approval lost its Operation owner")
                    mirrorOperationState(
                        transaction, operationId,
                        if (approved) { "prepared" } else { "rejected" }
                    )
                } else {
                    let expected = [
                        approvalId.trimAscii(), operationId.value,
                        reviewedPlan.bindingDigest, encodedCeiling,
                        expectedDecision, source.trimAscii(), expectedExpiry
                    ]
                    if (existing.size != 1 || existing[0].size != expected.size) {
                        throw IllegalStateException("Operation has ambiguous approval evidence")
                    }
                    for (index in 0..expected.size where
                        existing[0].required(index) != expected[index]) {
                        throw IllegalStateException(
                            "approval replay differs from durable approval evidence"
                        )
                    }
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.approval_commit_failed", operationId, error)
        }
    }

    // executionPlan is freshly normalized immediately before execution. The
    // canonical encoded value must match every reviewed field (arguments,
    // paths, hosts, cwd, environment, effects and capabilities), not merely a
    // caller-supplied digest string.
    public func markExecuting(
        operationId: OperationId,
        runId: RunId,
        executionPlan: NormalizedOperationPlan,
        nowMillis: Int64,
        approvalRequired: Bool
    ): Result<Unit> {
        if (nowMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "operation.execution_metadata_invalid",
                "execution timestamp must not be negative"
            ))
        }
        let encodedPlan = encodeOperationPlan(executionPlan)
        try {
            database.transaction { transaction =>
                let rows = transaction.query(
                    "SELECT run_id,state,normalized_plan FROM operations WHERE id=" +
                        sqliteText(operationId.value)
                )
                if (rows.size != 1 || rows[0].required(0) != runId.value ||
                    rows[0].required(1) != "prepared" ||
                    rows[0].required(2) != encodedPlan) {
                    throw IllegalStateException("normalized Operation changed before execution")
                }
                if (approvalRequired) {
                    let approvals = transaction.query(
                        "SELECT decision,operation_digest,expires_at_millis FROM approvals WHERE operation_id=" +
                            sqliteText(operationId.value)
                    )
                    if (approvals.size != 1 || approvals[0].required(0) != "approved" ||
                        approvals[0].required(1) != executionPlan.bindingDigest ||
                        approvalExpired(approvals[0][2], nowMillis)) {
                        throw IllegalStateException("exact approval is absent, expired, or drifted")
                    }
                }
                transaction.execute(
                    "UPDATE operations SET state='executing',revision=revision+1 WHERE id=" +
                        sqliteText(operationId.value) + " AND state='prepared'"
                )
                requireStoreChanged(transaction, "Operation execution lost its owner")
                mirrorOperationState(transaction, operationId, "executing")
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.execution_prepare_failed", operationId, error)
        }
    }

    // This marker is the last durable write before calling the executor. A
    // crash after it is intentionally classified as possibly side-effecting.
    public func markExecutionHandoff(
        operationId: OperationId,
        runId: RunId,
        threadId: ThreadId,
        observedAtMillis: Int64
    ): Result<Unit> {
        if (observedAtMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "operation.handoff_timestamp_invalid",
                "execution handoff timestamp must not be negative"
            ))
        }
        try {
            database.transaction { transaction =>
                requireStoreRow(
                    transaction,
                    "SELECT operations.run_id,operations.state FROM operations JOIN runs " +
                        "ON runs.id=operations.run_id WHERE operations.id=" +
                        sqliteText(operationId.value) + " AND runs.thread_id=" +
                        sqliteText(threadId.value),
                    [runId.value, "executing"],
                    "execution handoff does not own an executing Operation"
                )
                let existing = transaction.query(
                    "SELECT id FROM audit_events WHERE operation_id=" + sqliteText(operationId.value) +
                        " AND kind='operation_execution_handoff'"
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO audit_events " +
                            "(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (" +
                            sqliteText(threadId.value) + "," + sqliteText(runId.value) + "," +
                            sqliteText(operationId.value) + ",'operation_execution_handoff'," +
                            sqliteText(encodeStoredValue(objectValue([]))) + "," +
                            observedAtMillis.toString() + ")"
                    )
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.handoff_commit_failed", operationId, error)
        }
    }

    public func loadPlan(
        operationId: OperationId,
        runId: RunId
    ): Result<NormalizedOperationPlan> {
        try {
            let rows = database.query(
                "SELECT normalized_plan FROM operations WHERE id=" +
                    sqliteText(operationId.value) + " AND run_id=" + sqliteText(runId.value)
            )
            if (rows.size != 1) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "operation.not_found",
                    "Operation plan was not found"
                ))
            }
            Result.Ok(decodeOperationPlan(rows[0].required(0)))
        } catch (error: Exception) {
            operationStoreError("operation.plan_load_failed", operationId, error)
        }
    }

    private func transitionOperation(
        operationId: OperationId,
        runId: RunId,
        from: String,
        to: String
    ): Result<Unit> {
        try {
            database.transaction { transaction =>
                transaction.execute(
                    "UPDATE operations SET state=" + sqliteText(to) +
                        ",revision=revision+1 WHERE id=" + sqliteText(operationId.value) +
                        " AND run_id=" + sqliteText(runId.value) + " AND state=" + sqliteText(from)
                )
                requireStoreChanged(transaction, "Operation transition lost its owner")
                mirrorOperationState(transaction, operationId, to)
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.transition_failed", operationId, error)
        }
    }
}

func insertOperationEffectRecord(
    transaction: SqliteTransaction,
    operationId: OperationId,
    runId: RunId,
    toolCallItemId: ItemId,
    plan: NormalizedOperationPlan,
    encodedPlan: String
): Unit {
    transaction.execute(
        "INSERT INTO operation_effect_records(" +
            "operation_id,run_id,tool_call_item_id,normalized_plan,tool_id,tool_version," +
            "implementation_fingerprint,schema_digest,effective_arguments_digest," +
            "replay_contract_version,replay_disposition,reserved_receipt_id," +
            "reserved_result_item_id,created_at_millis) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)",
        [
            SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
            SqlParameter.Text(toolCallItemId.value), SqlParameter.Text(encodedPlan),
            SqlParameter.Text(plan.implementation.toolId),
            SqlParameter.Text(plan.implementation.toolVersion),
            SqlParameter.Text(plan.implementation.implementationFingerprint),
            SqlParameter.Text(plan.implementation.schemaDigest),
            SqlParameter.Text(plan.implementation.effectiveArgumentsDigest),
            SqlParameter.Int64Value(Int64(plan.implementation.replayContractVersion)),
            SqlParameter.Text(encodeStoredValue(replayDispositionValue(plan.replayDisposition))),
            SqlParameter.Text("receipt-" + operationId.value),
            SqlParameter.Text("result-" + operationId.value)
        ]
    )
    transaction.execute(
        "INSERT INTO operation_state_registers(operation_id,state,revision) VALUES (?,'prepared',1)",
        [SqlParameter.Text(operationId.value)]
    )
}

public func mirrorOperationState(
    transaction: SqliteTransaction,
    operationId: OperationId,
    state: String
): Unit {
    let existing = transaction.query(
        "SELECT revision FROM operation_state_registers WHERE operation_id=?",
        [SqlParameter.Text(operationId.value)]
    )
    if (existing.isEmpty()) {
        transaction.execute(
            "INSERT OR IGNORE INTO operation_effect_records(" +
                "operation_id,run_id,tool_call_item_id,normalized_plan,tool_id,tool_version," +
                "implementation_fingerprint,schema_digest,effective_arguments_digest," +
                "replay_contract_version,replay_disposition,reserved_receipt_id," +
                "reserved_result_item_id,created_at_millis) SELECT id,run_id,tool_call_item_id," +
                "normalized_plan,'legacy','legacy-v1',normalized_plan,normalized_plan," +
                "normalized_plan,1,'never_replay','legacy-receipt-'||id," +
                "'legacy-result-'||id,0 FROM operations WHERE id=?",
            [SqlParameter.Text(operationId.value)]
        )
        transaction.execute(
            "INSERT INTO operation_state_registers(operation_id,state,revision) " +
                "SELECT id,?,revision FROM operations WHERE id=?",
            [SqlParameter.Text(state), SqlParameter.Text(operationId.value)]
        )
        requireStoreChanged(transaction, "Operation state register is missing")
        return
    }
    transaction.execute(
        "UPDATE operation_state_registers SET state=?,revision=revision+1 WHERE operation_id=?",
        [SqlParameter.Text(state), SqlParameter.Text(operationId.value)]
    )
    requireStoreChanged(transaction, "Operation state register is missing")
}

// Read-only deterministic recovery planner for crash boundaries C1-C7.
public class OperationRecoveryPlanner {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func inspect(threadId: ThreadId): Array<RecoveryAction> {
        let snapshot = SqliteThreadCommitSink(database).loadThread(threadId)
        let activeTurnId = match (snapshot.thread.activeTurnId) {
            case Some(value) => value
            case None => return []
        }
        let activeRunId = snapshot.activeRunId.getOrThrow()
        let results = ArrayList<OperationId>()
        for (item in snapshot.items where item.turnId.value == activeTurnId.value) {
            match (item.content) {
                case ThreadItemContent.ToolResult(_, operationId, _, _, _) => results.add(operationId)
                case _ => ()
            }
        }
        let actions = ArrayList<RecoveryAction>()
        for (item in snapshot.items where item.turnId.value == activeTurnId.value) {
            match (item.content) {
                case ThreadItemContent.ToolCall(_, _, _) => inspectCall(
                    threadId, activeTurnId, activeRunId, item.id, results, actions
                )
                case _ => ()
            }
        }
        actions.toArray()
    }

    private func inspectCall(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        callItemId: ItemId,
        results: ArrayList<OperationId>,
        actions: ArrayList<RecoveryAction>
    ): Unit {
        let rows = database.query(
            "SELECT id,state,effect_class FROM operations WHERE run_id=" + sqliteText(runId.value) +
                " AND tool_call_item_id=" + sqliteText(callItemId.value)
        )
        if (rows.isEmpty()) {
            actions.add(recoveryAction(
                RecoveryActionKind.CreateOrReconcileOperation,
                threadId, turnId, runId, callItemId, reason: "ToolCall has no Operation"
            ))
            return
        }
        if (rows.size != 1) {
            throw IllegalStateException("ToolCall has multiple durable Operations")
        }
        let operationId = OperationId(rows[0].required(0))
        let state = rows[0].required(1)
        let hasResult = containsOperation(results, operationId)
        let receiptCount = database.scalarInt(
            "SELECT COUNT(*) FROM operation_receipts WHERE operation_id=" +
                sqliteText(operationId.value)
        )
        if (hasResult) {
            let runState = database.query(
                "SELECT state FROM runs WHERE id=" + sqliteText(runId.value)
            )[0].required(0)
            if (runState == "waiting_external") {
                actions.add(recoveryAction(
                    RecoveryActionKind.AdvanceRunWithoutDuplicate,
                    threadId, turnId, runId, callItemId,
                    operationId: Some(operationId), reason: "ToolResult exists before Run advance"
                ))
            }
            return
        }
        // A Receipt is durable evidence regardless of the Operation state
        // committed in the same transaction. In particular,
        // recordOperationReceipt() moves known failures to `failed` and
        // ambiguous effects to `recovery_required`; a crash before the
        // canonical ToolResult append must still resume at C5 rather than
        // silently treating the ToolCall as complete.
        if (receiptCount > 0 && state != "committed") {
            actions.add(recoveryAction(
                RecoveryActionKind.FinalizeFromReceipt,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "Receipt exists before ToolResult commit"
            ))
            return
        }
        if (state == "waiting_approval") {
            let approvals = database.scalarInt(
                "SELECT COUNT(*) FROM approvals WHERE operation_id=" + sqliteText(operationId.value)
            )
            let continuationRows = database.query(
                "SELECT payload FROM run_continuations WHERE run_id=" +
                    sqliteText(runId.value)
            )
            let continuationPersisted = if (continuationRows.size == 1) {
                let continuation = decodeDurableRunContinuation(
                    continuationRows[0].required(0)
                )
                runExecutionPhaseName(continuation.phase) == "waiting_approval" &&
                    continuation.pendingOperationId.isSome() &&
                    continuation.pendingOperationId.getOrThrow().value == operationId.value &&
                    hasRunContinuationProjection(continuation)
            } else { false }
            if (approvals == 0 && continuationPersisted) {
                // This is a stable user-decision boundary, not a crash gap.
                // The canonical register carries the immutable legacy
                // projection needed to present/settle the same ApprovalRequest.
                return
            }
            actions.add(recoveryAction(
                if (approvals == 0) {
                    RecoveryActionKind.RequestApprovalOnce
                } else {
                    RecoveryActionKind.ExecuteByRetryPolicy
                },
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "prepared Operation is incomplete"
            ))
        } else if (state == "rejected") {
            actions.add(recoveryAction(
                RecoveryActionKind.FinalizeRejectedApproval,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId),
                reason: "rejected approval exists before ToolResult commit"
            ))
        } else if (state == "prepared") {
            actions.add(recoveryAction(
                RecoveryActionKind.ExecuteByRetryPolicy,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "prepared Operation is ready"
            ))
        } else if (state == "executing") {
            let handedOff = database.scalarInt(
                "SELECT COUNT(*) FROM audit_events WHERE operation_id=" +
                    sqliteText(operationId.value) + " AND kind='operation_execution_handoff'"
            ) > 0
            let mutating = rows[0].required(2) != "read_only"
            actions.add(recoveryAction(
                if (handedOff && mutating) {
                    RecoveryActionKind.RequireUnknownOutcomeReconciliation
                } else {
                    RecoveryActionKind.ExecuteByRetryPolicy
                },
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId),
                reason: if (handedOff && mutating) {
                    "executor may have observed the Operation"
                } else if (handedOff) {
                    "read-only Operation may be retried according to policy"
                } else {
                    "executor handoff is durably absent"
                }
            ))
        } else if (state == "committed") {
            actions.add(recoveryAction(
                RecoveryActionKind.AppendToolResultOnce,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "Operation committed before ToolResult"
            ))
        }
    }
}

func recoveryAction(
    kind: RecoveryActionKind,
    threadId: ThreadId,
    turnId: SemanticTurnId,
    runId: RunId,
    callItemId: ItemId,
    operationId!: ?OperationId = None,
    reason!: String = ""
): RecoveryAction {
    RecoveryAction(
        kind, threadId, turnId, runId, callItemId,
        operationId: operationId, reason: reason
    )
}

func containsOperation(values: ArrayList<OperationId>, target: OperationId): Bool {
    for (value in values where value.value == target.value) { return true }
    false
}

func encodeOperationPlan(plan: NormalizedOperationPlan): String {
    encodeStoredValue(objectValue([
        ValueField("tool", textValue(plan.toolName)),
        ValueField("arguments", plan.canonicalArguments),
        ValueField("capabilities", capabilityValues(plan.requiredCapabilities)),
        ValueField("paths", stringValues(plan.resolvedPaths)),
        ValueField("hosts", stringValues(plan.resolvedHosts)),
        ValueField("cwd", textValue(plan.cwd)),
        ValueField("environment", objectValue(plan.relevantEnvironment)),
        ValueField("effect", textValue(storeEffectName(plan.effectClass))),
        ValueField("retry", textValue(storeRetryName(plan.retryDisposition))),
        ValueField("replay", replayDispositionValue(plan.replayDisposition)),
        ValueField("idempotency_key", textValue(plan.idempotencyKey)),
        ValueField("digest", textValue(plan.bindingDigest)),
        ValueField("tool_version", textValue(plan.implementation.toolVersion)),
        ValueField("implementation_fingerprint", textValue(
            plan.implementation.implementationFingerprint
        )),
        ValueField("schema_digest", textValue(plan.implementation.schemaDigest)),
        ValueField("effective_arguments_digest", textValue(
            plan.implementation.effectiveArgumentsDigest
        )),
        ValueField("replay_contract_version", integerValue(
            Int64(plan.implementation.replayContractVersion)
        ))
    ]))
}

func decodeOperationPlan(encoded: String): NormalizedOperationPlan {
    let value = decodeStoredValue(encoded)
    let capabilities = ArrayList<Capability>()
    for (item in value.field("capabilities").getOrThrow().items) {
        capabilities.add(Capability(
            parseStoreCapability(item.field("kind").getOrThrow().text),
            resource: item.field("resource").getOrThrow().text
        ))
    }
    let environment = ArrayList<ValueField>()
    for (field in value.field("environment").getOrThrow().fields) {
        environment.add(ValueField(field.name, field.value))
    }
    let bindingDigest = value.field("digest").getOrThrow().text
    NormalizedOperationPlan(
        value.field("tool").getOrThrow().text,
        value.field("arguments").getOrThrow(),
        capabilities.toArray(),
        parseStoreEffect(value.field("effect").getOrThrow().text),
        parseStoreRetry(value.field("retry").getOrThrow().text),
        bindingDigest,
        resolvedPaths: storeStringItems(value.field("paths").getOrThrow()),
        resolvedHosts: storeStringItems(value.field("hosts").getOrThrow()),
        cwd: value.field("cwd").getOrThrow().text,
        relevantEnvironment: environment.toArray(),
        idempotencyKey: value.field("idempotency_key").getOrThrow().text,
        replayDisposition: match (value.field("replay")) {
            case Some(raw) => Some(parseReplayDisposition(raw))
            case None => None
        },
        toolVersion: optionalStoreText(value, "tool_version", "legacy-v1"),
        implementationFingerprint: optionalStoreText(
            value, "implementation_fingerprint", bindingDigest
        ),
        schemaDigest: optionalStoreText(value, "schema_digest", bindingDigest),
        effectiveArgumentsDigest: optionalStoreText(
            value, "effective_arguments_digest", bindingDigest
        ),
        replayContractVersion: storedReplayContractVersion(value)
    )
}

func replayDispositionValue(value: ReplayDisposition): AgentValue {
    match (value) {
        case ReplayDisposition.Pure => objectValue([ValueField("kind", textValue("pure"))])
        case ReplayDisposition.SafeReplay => objectValue([
            ValueField("kind", textValue("safe_replay"))
        ])
        case ReplayDisposition.Idempotent(key) => objectValue([
            ValueField("kind", textValue("idempotent")),
            ValueField("key", textValue(key))
        ])
        case ReplayDisposition.RecoverByProbe(probe) => objectValue([
            ValueField("kind", textValue("recover_by_probe")),
            ValueField("probe_id", textValue(probe.value))
        ])
        case ReplayDisposition.Compensatable(plan) => objectValue([
            ValueField("kind", textValue("compensatable")),
            ValueField("compensation_plan_id", textValue(plan.value))
        ])
        case ReplayDisposition.AtMostOnce => objectValue([
            ValueField("kind", textValue("at_most_once"))
        ])
        case ReplayDisposition.NeverReplay => objectValue([
            ValueField("kind", textValue("never_replay"))
        ])
    }
}

func parseReplayDisposition(value: AgentValue): ReplayDisposition {
    let kind = value.field("kind").getOrThrow().text
    match (kind) {
        case "pure" => ReplayDisposition.Pure
        case "safe_replay" => ReplayDisposition.SafeReplay
        case "idempotent" => ReplayDisposition.Idempotent(
            value.field("key").getOrThrow().text
        )
        case "recover_by_probe" => ReplayDisposition.RecoverByProbe(
            RecoveryProbeId(value.field("probe_id").getOrThrow().text)
        )
        case "compensatable" => ReplayDisposition.Compensatable(
            CompensationPlanId(value.field("compensation_plan_id").getOrThrow().text)
        )
        case "at_most_once" => ReplayDisposition.AtMostOnce
        case "never_replay" => ReplayDisposition.NeverReplay
        case _ => throw IllegalStateException("unknown stored replay disposition")
    }
}

func optionalStoreText(value: AgentValue, name: String, fallback: String): String {
    match (value.field(name)) {
        case Some(raw) => raw.text
        case None => fallback
    }
}

func storedReplayContractVersion(value: AgentValue): UInt32 {
    match (value.field("replay_contract_version")) {
        case Some(raw) => if (raw.unifiedKind == ValueKind.Number && raw.number == "1") {
            1u32
        } else {
            throw IllegalStateException("unsupported replay contract version")
        }
        case None => 1u32
    }
}

func storeStringItems(value: AgentValue): Array<String> {
    let result = ArrayList<String>()
    for (item in value.items) { result.add(item.text) }
    result.toArray()
}

func parseStoreCapability(value: String): CapabilityKind {
    match (value) {
        case "workspace_read" => CapabilityKind.WorkspaceRead
        case "workspace_write" => CapabilityKind.WorkspaceWrite
        case "process_spawn" => CapabilityKind.ProcessSpawn
        case "peer_message" => CapabilityKind.PeerMessage
        case "network_access" => CapabilityKind.NetworkAccess
        case "delegate" => CapabilityKind.Delegate
        case "extension_invoke" => CapabilityKind.ExtensionInvoke
        case _ => throw IllegalStateException("unknown stored capability")
    }
}

func parseStoreEffect(value: String): OperationEffectClass {
    match (value) {
        case "read_only" => OperationEffectClass.ReadOnly
        case "workspace_mutation" => OperationEffectClass.WorkspaceMutation
        case "external_mutation" => OperationEffectClass.ExternalMutation
        case _ => throw IllegalStateException("unknown stored Operation effect")
    }
}

func parseStoreRetry(value: String): OperationRetryDisposition {
    match (value) {
        case "safe" => OperationRetryDisposition.Safe
        case "by_idempotency_key" => OperationRetryDisposition.ByIdempotencyKey
        case "verify_then_retry" => OperationRetryDisposition.VerifyThenRetry
        case "never" => OperationRetryDisposition.Never
        case _ => throw IllegalStateException("unknown stored Operation retry disposition")
    }
}

func encodeCapabilities(capabilities: Array<Capability>): String {
    encodeStoredValue(capabilityValues(capabilities))
}

func capabilityValues(capabilities: Array<Capability>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (capability in capabilities) {
        values.add(objectValue([
            ValueField("kind", textValue(storeCapabilityName(capability.kind))),
            ValueField("resource", textValue(capability.resource))
        ]))
    }
    listValue(values.toArray())
}

func capabilitySetAllowsPlan(ceiling: CapabilitySet, plan: NormalizedOperationPlan): Bool {
    for (required in plan.requiredCapabilities where
        !ceiling.allows(required.kind, resource: required.resource)) {
        return false
    }
    true
}

func encodeResourceScope(plan: NormalizedOperationPlan): String {
    encodeStoredValue(objectValue([
        ValueField("paths", stringValues(plan.resolvedPaths)),
        ValueField("hosts", stringValues(plan.resolvedHosts)),
        ValueField("cwd", textValue(plan.cwd)),
        ValueField("environment", objectValue(plan.relevantEnvironment))
    ]))
}

func stringValues(values: Array<String>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) { result.add(textValue(value)) }
    listValue(result.toArray())
}

func storeCapabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func storeEffectName(effect: OperationEffectClass): String {
    match (effect) {
        case OperationEffectClass.ReadOnly => "read_only"
        case OperationEffectClass.WorkspaceMutation => "workspace_mutation"
        case OperationEffectClass.ExternalMutation => "external_mutation"
    }
}

func storeRetryName(retry: OperationRetryDisposition): String {
    match (retry) {
        case OperationRetryDisposition.Safe => "safe"
        case OperationRetryDisposition.ByIdempotencyKey => "by_idempotency_key"
        case OperationRetryDisposition.VerifyThenRetry => "verify_then_retry"
        case OperationRetryDisposition.Never => "never"
    }
}

func optionalSqliteText(value: String): String {
    if (value == "") { "NULL" } else { sqliteText(value) }
}

func optionalSqliteInt(value: ?Int64): String {
    match (value) {
        case Some(item) => item.toString()
        case None => "NULL"
    }
}

func approvalExpired(value: ?String, nowMillis: Int64): Bool {
    match (value) {
        case Some(item) => parseStoreInt(item, "approval expiry") < nowMillis
        case None => false
    }
}

func operationStoreError<T>(
    code: String,
    operationId: OperationId,
    error: Exception
): Result<T> {
    let message = if (error.message.trimAscii() == "") {
        "durable Operation state is corrupt or incomplete"
    } else {
        error.message
    }
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired, code, message,
        fields: [ErrorField("operation_id", operationId.value)]
    ))
}
