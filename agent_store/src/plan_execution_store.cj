package agent_store

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.fs.*
import agent_domain.*
import agent_runtime.*

func planExecutionMigration(): Array<String> {
    [
        "CREATE TABLE plan_executions (approval_sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,session_id TEXT NOT NULL,contract TEXT NOT NULL,sealed INTEGER NOT NULL DEFAULT 0 CHECK(sealed IN (0,1)))",
        "CREATE TABLE plan_execution_members (execution_id TEXT NOT NULL REFERENCES plan_executions(id),session_id TEXT NOT NULL,parent_run_id TEXT REFERENCES runs(id),parent_operation_id TEXT REFERENCES operations(id),allowed_actions TEXT NOT NULL,PRIMARY KEY(execution_id,session_id))",
        "CREATE TABLE plan_execution_sessions (session_id TEXT PRIMARY KEY,execution_id TEXT NOT NULL REFERENCES plan_executions(id))",
        "CREATE TABLE plan_execution_runs (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,session_id TEXT NOT NULL,execution_id TEXT NOT NULL REFERENCES plan_executions(id))",
        "CREATE TABLE plan_action_admissions (admission_sequence INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL UNIQUE REFERENCES operations(id),execution_id TEXT NOT NULL REFERENCES plan_executions(id),step_id TEXT NOT NULL,action_id TEXT NOT NULL,attempt_no INTEGER NOT NULL CHECK(attempt_no>0),binding_digest TEXT NOT NULL,UNIQUE(execution_id,action_id,attempt_no))",
        "CREATE TABLE plan_step_decisions (receipt_id TEXT PRIMARY KEY REFERENCES operation_receipts(id),execution_id TEXT NOT NULL REFERENCES plan_executions(id),step_id TEXT NOT NULL,decision TEXT NOT NULL)",
        "CREATE INDEX plan_action_execution ON plan_action_admissions(execution_id,action_id)"
    ]
}

// Reservations reference canonical Operations; decisions reference canonical
// receipts. Neither table stores another copy of tool outcomes or tool state.
public class DurablePlanExecutionStore <: PlanExecutionPort & PlanExecutionDataPort204 & PlanExecutionReadDataPort204 & PlanExecutionSessionPresence204 {
    private let database: SqliteDatabase
    private let knownParentAllocation: ?(Int64)->LogicalJsonOwnerReservation
    public init(database: SqliteDatabase,
        knownParentAllocation!: ?(Int64)->LogicalJsonOwnerReservation = None) {
        this.database = database; this.knownParentAllocation = knownParentAllocation
    }

    public func activate(executionId: String, sessionId: String, contract: PlanContract): Result<Unit> {
        match (validatePlanContract(contract)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        if (executionId.trimAscii() == "" || sessionId.trimAscii() == "") {
            return planExecutionError("plan.binding_invalid", "execution and session identities are required")
        }
        let encoded = encodeStoredValue(planContractValue(contract))
        try {
            database.transaction { tx =>
                let inherited = tx.query("SELECT e.session_id,s.execution_id FROM plan_execution_sessions s JOIN plan_executions e ON e.id=s.execution_id WHERE s.session_id=?",
                    [SqlParameter.Text(sessionId)])
                if (!inherited.isEmpty() && inherited[0].required(0) != sessionId) {
                    throw IllegalStateException("inherited child cannot replace its parent execution or reset shared budgets")
                }
                if (!inherited.isEmpty() && inherited[0].required(1) != executionId) {
                    // Reapproval revokes active descendants of the old plan;
                    // immutable membership/history remains available to inspect.
                    tx.execute("DELETE FROM plan_execution_sessions WHERE execution_id=?", [SqlParameter.Text(inherited[0].required(1))])
                }
                let existing = tx.query("SELECT session_id,contract,sealed FROM plan_executions WHERE id=?",
                    [SqlParameter.Text(executionId)])
                if (existing.isEmpty()) {
                    tx.execute("INSERT INTO plan_executions(id,session_id,contract) VALUES(?,?,?)",
                        [SqlParameter.Text(executionId), SqlParameter.Text(sessionId), SqlParameter.Text(encoded)])
                } else if (existing[0].required(0) != sessionId || existing[0].required(1) != encoded || existing[0].required(2) != "0") {
                    throw IllegalStateException("approved execution identity already has another immutable contract")
                }
                let members = tx.query("SELECT parent_operation_id FROM plan_execution_members WHERE execution_id=? AND session_id=?",
                    [SqlParameter.Text(executionId), SqlParameter.Text(sessionId)])
                if (members.isEmpty()) {
                    tx.execute("INSERT INTO plan_execution_members(execution_id,session_id,parent_run_id,parent_operation_id,allowed_actions) VALUES(?,?,NULL,NULL,?)",
                        [SqlParameter.Text(executionId), SqlParameter.Text(sessionId),
                            SqlParameter.Text(encodeStoredValue(stringValues(planAllActionIds(contract))))])
                } else if (members[0][0].isSome()) { throw IllegalStateException("owner binding conflicts with inherited membership") }
                tx.execute("INSERT INTO plan_execution_sessions(session_id,execution_id) VALUES(?,?) " +
                    "ON CONFLICT(session_id) DO UPDATE SET execution_id=excluded.execution_id",
                    [SqlParameter.Text(sessionId), SqlParameter.Text(executionId)])
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.activation_conflict", "approved execution could not be activated without changing existing facts")
        }
    }

    public func bind(executionId: String, sessionId: String, runId: RunId, contract: PlanContract): Result<Unit> {
        match (activate(executionId, sessionId, contract)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => bindRun(executionId, sessionId, runId)
        }
    }

    // Any mapping, including an inconsistent sealed mapping, prevents an
    // ownerless caller from silently dropping approved scope. This closed
    // scalar query never loads the execution identity or contract.
    public func sessionHasExecution204(sessionId: String): Result<Bool> {
        try {
            Result.Ok(database.readTransaction<Bool> { tx: SqliteTransaction =>
                let rows = tx.query("SELECT EXISTS(SELECT 1 FROM plan_execution_sessions WHERE session_id=?)",
                    [SqlParameter.Text(sessionId)])
                if (rows.size != 1) { throw IllegalStateException("session presence result is invalid") }
                let value = rows[0].required(0)
                if (value != "0" && value != "1") { throw IllegalStateException("session presence result is invalid") }
                value == "1"
            })
        } catch (_: Exception) {
            planExecutionError("plan.session_presence_unavailable", "Approved scope presence could not be checked")
        }
    }

    public func executionForSession(sessionId: String): Result<?String> {
        try {
            let rows = database.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=?",
                [SqlParameter.Text(sessionId)])
            Result.Ok(if (rows.isEmpty()) { None } else { Some(rows[0].required(0)) })
        } catch (_: Exception) {
            planExecutionError("plan.session_lookup_failed", "approved plan session binding could not be loaded")
        }
    }

    public func contractForSession(sessionId: String): Result<?PlanContract> {
        match (executionForSession(sessionId)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(None) => Result.Ok(None<PlanContract>)
            case _ => planExecutionError("plan.paid_read_required", "approved contract requires a paid scope or inspection owner")
        }
    }

    public func executionForRun(runId: RunId): Result<?String> {
        try {
            let rows = database.query("SELECT execution_id FROM plan_execution_runs WHERE run_id=?",
                [SqlParameter.Text(runId.value)])
            Result.Ok(if (rows.isEmpty()) { None } else { Some(rows[0].required(0)) })
        } catch (_: Exception) {
            planExecutionError("plan.run_lookup_failed", "approved plan Run binding could not be loaded")
        }
    }

    public func bindRun(executionId: String, sessionId: String, runId: RunId): Result<Unit> {
        try {
            database.transaction { tx =>
                let runOwner = tx.query("SELECT thread_id FROM runs WHERE id=?", [SqlParameter.Text(runId.value)])
                if (runOwner.size != 1 || runOwner[0].required(0) != sessionId) {
                    throw IllegalStateException("Run does not belong to the binding session")
                }
                let execution = tx.query("SELECT id FROM plan_executions WHERE id=?",
                    [SqlParameter.Text(executionId)])
                if (execution.size != 1) { throw IllegalStateException("execution belongs to another session") }
                let active = tx.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=?",
                    [SqlParameter.Text(sessionId)])
                if (active.size != 1 || active[0].required(0) != executionId) {
                    throw IllegalStateException("execution is not the approved active session contract")
                }
                let rows = tx.query("SELECT execution_id,session_id FROM plan_execution_runs WHERE run_id=?",
                    [SqlParameter.Text(runId.value)])
                if (rows.isEmpty()) {
                    tx.execute("INSERT INTO plan_execution_runs(run_id,session_id,execution_id) VALUES(?,?,?)",
                        [SqlParameter.Text(runId.value), SqlParameter.Text(sessionId), SqlParameter.Text(executionId)])
                } else if (rows[0].required(0) != executionId || rows[0].required(1) != sessionId) {
                    throw IllegalStateException("Run already bound to another approved execution")
                }
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.run_binding_conflict", "Run cannot bind to the requested approved execution")
        }
    }

    public func admit(runId: RunId, operationId: OperationId, stepId: String,
        actionId: String, plan: NormalizedOperationPlan): Result<Unit> {
        let owner = try { PlanExecutionReadOwner204(knownParentAllocation.getOrThrow()(131072)) }
            catch (_: Exception) { return planExecutionError("plan.read_capacity", "action admission requires its original paid bank") }
        let result = admitReadFrame204(runId, operationId, stepId, actionId, plan, owner)
        owner.closeAfterCaller204(); result
    }
    private func admitReadFrame204(runId: RunId, operationId: OperationId, stepId: String,
        actionId: String, plan: NormalizedOperationPlan, owner: PlanExecutionReadOwner204): Result<Unit> {
        try {
            database.transaction { tx =>
                let execution = planRunExecution(tx, runId)
                fundPlanAdmissionSnapshot204(tx, execution, runId, operationId, owner)
                planRequireUnsealed(tx, execution)
                planRequireNoUnknown(tx, execution)
                let contract = planLoadContract(tx, execution)
                let binding = tx.query("SELECT session_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(runId.value)])
                let allowed = planMemberActions(tx, execution, binding[0].required(0))
                let active = tx.query("SELECT s.execution_id FROM plan_execution_sessions s JOIN plan_executions e ON e.session_id=s.session_id WHERE e.id=?",
                    [SqlParameter.Text(execution)])
                if (active.size != 1 || active[0].required(0) != execution) {
                    throw IllegalStateException("approved execution has been superseded")
                }
                let operation = tx.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
                    [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
                if (operation.size != 1 || operation[0].required(0) != encodeOperationPlan(plan)) {
                    throw IllegalStateException("admission requires the canonical immutable Operation plan")
                }
                let existing = tx.query("SELECT execution_id,step_id,action_id,binding_digest FROM plan_action_admissions WHERE operation_id=?",
                    [SqlParameter.Text(operationId.value)])
                if (existing.isEmpty() && stepId == "" && actionId == "") {
                    requireApprovedDerivedPlanAdmission(tx, operationId, runId, plan.bindingDigest,
                        documentAllocation: Some({ bytes: Int64 => owner.deriveRetainedAllocation204(bytes) }))
                    return ()
                }
                if (!existing.isEmpty()) {
                    if (existing[0].required(0) != execution || (stepId != "" && existing[0].required(1) != stepId) ||
                        (actionId != "" && existing[0].required(2) != actionId) || existing[0].required(3) != plan.bindingDigest) {
                        throw IllegalStateException("Operation reservation cannot be rebound")
                    }
                    if (!planContains(allowed, existing[0].required(2))) { throw IllegalStateException("inherited action is outside the immutable delegation") }
                    let approvedStep = planFindStep(contract, existing[0].required(1))
                    let approvedAction = planFindAction(approvedStep, existing[0].required(2))
                    if (!planActionAllows(contract, approvedAction, plan)) {
                        throw IllegalStateException("prepared Operation no longer matches its approved action")
                    }
                    planRequireDependencies(contract, planReadFacts(tx, execution), approvedStep)
                } else {
                    if (!planContains(allowed, actionId)) { throw IllegalStateException("action was not delegated to this session") }
                    let step = planFindStep(contract, stepId)
                    let action = planFindAction(step, actionId)
                    if (!planActionAllows(contract, action, plan)) {
                        throw IllegalStateException("Operation exceeds the approved action bounds")
                    }
                    let facts = planReadFacts(tx, execution)
                    if (action.evidence == "exit_zero") {
                        for (fact in facts where fact.mutating && fact.receipt.isNone()) {
                            throw IllegalStateException("verification cannot start while a source mutation has an unresolved outcome")
                        }
                    }
                    let status = planProjectedStep(contract, facts, stepId, [])
                    if (status != "runnable") {
                        throw IllegalStateException("step is not runnable: " + status)
                    }
                    let actionState = planActionState(action, facts)
                    if (actionState.state != "runnable" && actionState.state != "retry") {
                        throw IllegalStateException("action has pending, terminal, or missing evidence")
                    }
                    if (actionState.attempts >= action.maxAttempts) {
                        throw IllegalStateException("approved action attempt budget is exhausted")
                    }
                    tx.execute("INSERT INTO plan_action_admissions(operation_id,execution_id,step_id,action_id,attempt_no,binding_digest) VALUES(?,?,?,?,?,?)",
                        [SqlParameter.Text(operationId.value), SqlParameter.Text(execution),
                            SqlParameter.Text(stepId), SqlParameter.Text(actionId),
                            SqlParameter.Int64Value(actionState.attempts + 1), SqlParameter.Text(plan.bindingDigest)])
                }
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.admission_denied", "Operation is not admissible under the approved plan, dependency, evidence, or attempt budget")
        }
    }

    public func observe(runId: RunId, operationId: OperationId): Result<PlanStepDecision> {
        planExecutionError("plan.paid_read_required", "canonical plan decisions require a paid observation owner")
    }
    public func observe204(runId: RunId, operationId: OperationId,
        payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204> {
        let owner = try { newPlanReadOwner204(payer) } catch (_: Exception) {
            return planExecutionError("plan.read_capacity", "plan observation could not reserve the original bank") }
        match (observeReadFrame204(runId, operationId, owner)) {
            case Result.Err(error) => owner.closeAfterCaller204(); Result.Err(error)
            case Result.Ok(value) =>
                owner.installProducerData204(planStepDecisionValue(value)); Result.Ok(owner)
        }
    }
    private func observeReadFrame204(runId: RunId, operationId: OperationId,
        owner: PlanExecutionReadOwner204): Result<PlanStepDecision> {
        try {
            let decision = database.transaction { tx =>
                let execution = planRunExecution(tx, runId)
                fundPlanClosedObservation204(tx, execution, runId, operationId, owner)
                let contract = planLoadContract(tx, execution)
                let rows = tx.query("SELECT a.step_id,r.id,r.outcome,r.detail,o.retry_disposition FROM operations o LEFT JOIN plan_action_admissions a ON a.operation_id=o.id AND a.execution_id=? " +
                    "LEFT JOIN operation_receipts r ON r.operation_id=o.id WHERE o.id=? AND o.run_id=?",
                    [SqlParameter.Text(execution), SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
                if (rows.size != 1) { throw IllegalStateException("Operation does not belong to this Run") }
                let stepId = match (rows[0][0]) {
                    case Some(value) => value
                    case None => return PlanStepDecision("", "not_dispatched", "preparation_rejected",
                        receiptId: rows[0][1].getOrDefault({ => "" }))
                }
                let receiptId = match (rows[0][1]) {
                    case Some(value) => value
                    case None => ""
                }
                let facts = planReadFacts(tx, execution)
                let step = planFindStep(contract, stepId)
                let status = planProjectedStep(contract, facts, stepId, [])
                var decisionName = status
                if (receiptId != "") {
                    let outcome = planParseOutcome(rows[0].required(2))
                    let detail = decodeStoredValue(rows[0].required(3))
                    let error = planReceiptErrorDetail(detail)
                    let failureClass = planOptionalText(error, "failure_class")
                    let noTarget = planTargetNotStarted(error) &&
                        (failureClass == "infrastructure_unavailable" || failureClass == "dependency_unavailable")
                    if (outcome == OperationOutcome.Unknown) { decisionName = "recovery_required" }
                    else if (outcome == OperationOutcome.Cancelled) { decisionName = "cancelled" }
                    else if (outcome == OperationOutcome.Rejected && !noTarget) { decisionName = "policy_denied" }
                    else if (status == "blocked") {
                        let retry = parseStoreRetry(rows[0].required(4))
                        let safe = noTarget || ((retry == OperationRetryDisposition.Safe ||
                            retry == OperationRetryDisposition.ByIdempotencyKey) &&
                            (failureClass == "command_failed" || failureClass == "timeout" ||
                            detail.field("exit_code").isSome() || outcome == OperationOutcome.TimedOut))
                        if (safe && planHasIndependentRunnable(contract, facts, stepId)) {
                            decisionName = "continue_independent"
                        }
                    }
                }
                for (fact in facts) {
                    match (fact.receipt) {
                        case Some(receipt) => if (receipt.outcome == OperationOutcome.Unknown) { decisionName = "recovery_required" }
                        case None => ()
                    }
                }
                if (planExecutionHasUnknown(tx, execution)) { decisionName = "recovery_required" }
                let selected = PlanStepDecision(stepId, decisionName,
                    planDecisionReason(decisionName), receiptId: receiptId,
                    fallbackStepId: if (decisionName == "fallback") { step.fallbackStepId } else { None })
                if (receiptId != "") {
                    // The receipt is the idempotency key. Re-observation never
                    // consumes another budget or changes a previous decision.
                    let saved = tx.query("SELECT decision FROM plan_step_decisions WHERE receipt_id=?",
                        [SqlParameter.Text(receiptId)])
                    if (saved.isEmpty()) {
                        tx.execute("INSERT INTO plan_step_decisions(receipt_id,execution_id,step_id,decision) VALUES(?,?,?,?)",
                            [SqlParameter.Text(receiptId), SqlParameter.Text(execution), SqlParameter.Text(stepId),
                                SqlParameter.Text(encodeStoredValue(planStepDecisionValue(selected)))])
                        selected
                    } else if (decisionName == "recovery_required") {
                        // Keep the historical receipt decision immutable, but
                        // never revive a continuation after a later shared Unknown.
                        selected
                    } else { planStoredDecision(decodeStoredValue(saved[0].required(0))) }
                } else { selected }
            }
            Result.Ok(decision)
        } catch (_: Exception) {
            planExecutionError("plan.observation_failed", "canonical plan receipt could not be observed")
        }
    }

    public func admitOwnedPlan204(runId: RunId, operationId: OperationId, stepId: String,
        actionId: String, value: PreparedPlanUtf8Owner204): Result<Unit> {
        let phase = openPreparedPlanCopy204(value)
        try {
            phase.copyAndDecodeFrame204()
            phase.sourceCopyReturned204()
            let result = phase.admitFrame204(this, runId, operationId, stepId, actionId)
            match (result) {
                case Result.Err(error) => phase.holdError204(error)
                case Result.Ok(_) => returnPreparedPlanCopy204(phase)
            }
            result
        } catch (error: Exception) {
            phase.holdException204(error); throw error
        }
    }

    // Use the caller's exact read snapshot for an inspection page. A missing
    // binding is ordinary absence, while corrupt approved history is an error.
    public func inspectSnapshot(tx: SqliteTransaction, runId: RunId): Result<?AgentValue> {
        let rows = tx.query("SELECT execution_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(runId.value)])
        if (rows.isEmpty()) { Result.Ok(None<AgentValue>) }
        else { planExecutionError("plan.paid_read_required", "inspection requires a paid snapshot owner") }
    }
    public func inspectSnapshot204(tx: SqliteTransaction, runId: RunId,
        payer: LogicalJsonOwnerReservation): Result<?PlanExecutionReadOwner204> {
        let owner = try { newPlanReadOwner204(payer) } catch (_: Exception) {
            return planExecutionError("plan.read_capacity", "inspection snapshot could not reserve the original bank") }
        match (fillInspectionSnapshot204(tx, runId, owner)) {
            case Result.Err(error) => owner.closeAfterCaller204(); Result.Err(error)
            case Result.Ok(false) => owner.closeAfterCaller204(); Result.Ok(None<PlanExecutionReadOwner204>)
            case Result.Ok(true) => Result.Ok(Some(owner))
        }
    }
    private func fillInspectionSnapshot204(tx: SqliteTransaction, runId: RunId,
        owner: PlanExecutionReadOwner204): Result<Bool> {
        try {
            let rows = tx.query("SELECT session_id,execution_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(runId.value)])
            if (rows.isEmpty()) { return Result.Ok(false) }
            if (rows.size != 1) { throw IllegalStateException("ambiguous approved execution") }
            let peak = fundPlanReadSnapshot204(tx, rows[0].required(1), owner, true)
            let state = planInspect(tx, rows[0].required(1), memberSession: rows[0].required(0))
            let _ = owner.fundProducerGraphWork204(state, peak)
            owner.installProducerData204(state)
            Result.Ok(true)
        } catch (_: Exception) { planExecutionError("plan.read_capacity", "inspection snapshot could not be paid or verified") }
    }

    // A closed scalar admission used by the real instruction collector. It
    // exports no approved contract graph or borrowed metadata ownership.
    public func validateContextResource(runId: RunId, source: String): Result<Unit> {
        try {
            if (database.readTransaction<Bool> { tx: SqliteTransaction => planContextExecution(tx, runId) == "" }) {
                return Result.Ok(())
            }
            let payer = knownParentAllocation.getOrThrow()(131072)
            let result = validateContextResource204(runId, source, payer)
            payer.close(); result
        } catch (_: Exception) {
            planExecutionError("plan.context_source_outside_scope", "approved context scope requires its original paid bank")
        }
    }
    public func validateContextResource204(runId: RunId, source: String,
        payer: LogicalJsonOwnerReservation): Result<Unit> {
        let owner = try { newPlanReadOwner204(payer) } catch (_: Exception) {
            return planExecutionError("plan.read_capacity", "context scope could not reserve the original bank") }
        let result = validateContextResourceFrame204(runId, source, owner)
        owner.closeAfterCaller204(); result
    }
    private func validateContextResourceFrame204(runId: RunId, source: String,
        owner: PlanExecutionReadOwner204): Result<Unit> {
        try {
            let allowed = database.readTransaction<Bool> { tx: SqliteTransaction =>
                let binding = planContextExecution(tx, runId)
                if (binding == "") { return true }
                let contractPeak = fundPlanClosedContract204(tx, binding, owner)
                if (source.size > (Int64.Max - 131072) / 64) { throw LogicalJsonPayloadError("context path invoice overflow") }
                owner.ensureProducerPeak204(checkedPlanReadSum204(contractPeak, 131072 + source.size * 64))
                let path = canonicalPlanContextPath(source)
                let contract = planLoadContract(tx, binding)
                planPathInRoots(path, contract.targetRoots) || planPathInRoots(path, contract.participatingRepositories)
            }
            if (allowed) { Result.Ok(()) } else {
                planExecutionError("plan.context_source_outside_scope", "context source is outside the immutable approved read scope") }
        } catch (_: Exception) {
            planExecutionError("plan.context_source_outside_scope", "context source could not be paid and verified inside the approved scope") }
    }
    public func inspect(runId: RunId): Result<AgentValue> {
        planExecutionError("plan.paid_read_required", "approved execution requires a paid inspection owner")
    }
    public func inspectForSession(sessionId: String): Result<AgentValue> {
        planExecutionError("plan.paid_read_required", "approved session requires a paid inspection owner")
    }

    public func isPlanOwner(runId: RunId): Result<Bool> {
        try {
            let rows = database.query("SELECT e.session_id,b.session_id FROM plan_execution_runs b JOIN plan_executions e ON e.id=b.execution_id WHERE b.run_id=?",
                [SqlParameter.Text(runId.value)])
            if (rows.size != 1) { return planExecutionError("plan.binding_missing", "Run has no approved plan binding") }
            Result.Ok(rows[0].required(0) == rows[0].required(1))
        } catch (_: Exception) {
            planExecutionError("plan.owner_lookup_failed", "approved plan owner could not be loaded")
        }
    }
    public func inherit(parentRunId: RunId, childSessionId: String, parentOperationId: OperationId): Result<Unit> {
        let owner = try { PlanExecutionReadOwner204(knownParentAllocation.getOrThrow()(131072)) }
            catch (_: Exception) { return planExecutionError("plan.read_capacity", "delegation requires its original paid bank") }
        let result = inheritReadFrame204(parentRunId, childSessionId, parentOperationId, owner)
        owner.closeAfterCaller204(); result
    }
    private func inheritReadFrame204(parentRunId: RunId, childSessionId: String, parentOperationId: OperationId, owner: PlanExecutionReadOwner204): Result<Unit> {
        if (childSessionId.trimAscii() == "") {
            return planExecutionError("plan.child_session_invalid", "child session identity is required")
        }
        try {
            database.transaction { tx =>
                let execution = planRunExecution(tx, parentRunId)
                fundPlanClosedInheritance204(tx, execution, parentRunId, parentOperationId, childSessionId, owner)
                planRequireUnsealed(tx, execution)
                planRequireNoUnknown(tx, execution)
                let contract = planLoadContract(tx, execution)
                let active = tx.query("SELECT s.execution_id FROM plan_execution_sessions s JOIN plan_executions e ON e.session_id=s.session_id WHERE e.id=?",
                    [SqlParameter.Text(execution)])
                if (active.size != 1 || active[0].required(0) != execution) {
                    throw IllegalStateException("parent execution is no longer active")
                }
                let parent = tx.query("SELECT b.session_id,a.step_id,a.action_id,o.normalized_plan,o.state,r.outcome FROM plan_execution_runs b " +
                    "JOIN operations o ON o.run_id=b.run_id AND o.id=? JOIN plan_action_admissions a ON a.operation_id=o.id AND a.execution_id=b.execution_id " +
                    "LEFT JOIN operation_receipts r ON r.operation_id=o.id WHERE b.run_id=? AND b.execution_id=?",
                    [SqlParameter.Text(parentOperationId.value), SqlParameter.Text(parentRunId.value), SqlParameter.Text(execution)])
                if (parent.size != 1) { throw IllegalStateException("delegation requires the exact admitted parent task Operation") }
                let parentSession = parent[0].required(0)
                let action = planFindAction(planFindStep(contract, parent[0].required(1)), parent[0].required(2))
                let operation = decodeOperationPlan(parent[0].required(3))
                var delegates = false
                for (capability in operation.requiredCapabilities where capability.kind == CapabilityKind.Delegate) { delegates = true }
                if (!planContains(["task", "plugin.axyndra:workflow.task"], operation.toolName) ||
                    !delegates || !action.exactArguments || action.delegatedActionIds.isEmpty()) {
                    throw IllegalStateException("parent action does not authorize child delegation")
                }
                let handoff = tx.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND kind='operation_execution_handoff' LIMIT 1",
                    [SqlParameter.Text(parentOperationId.value), SqlParameter.Text(parentRunId.value)])
                let completed = parent[0][5].getOrDefault({ => "" }) == "completed"
                if (handoff.isEmpty() || (parent[0].required(4) != "executing" && !completed)) {
                    throw IllegalStateException("parent task never reached a successful or live canonical handoff")
                }
                let parentAllowed = planMemberActions(tx, execution, parentSession)
                let delegated = ArrayList<String>()
                for (id in action.delegatedActionIds where planContains(parentAllowed, id)) { delegated.add(id) }
                if (delegated.isEmpty()) { throw IllegalStateException("delegation intersection is empty") }
                let encodedAllowed = encodeStoredValue(stringValues(delegated.toArray()))
                let members = tx.query("SELECT parent_run_id,parent_operation_id,allowed_actions FROM plan_execution_members WHERE execution_id=? AND session_id=?",
                    [SqlParameter.Text(execution), SqlParameter.Text(childSessionId)])
                if (members.isEmpty()) {
                    tx.execute("INSERT INTO plan_execution_members(execution_id,session_id,parent_run_id,parent_operation_id,allowed_actions) VALUES(?,?,?,?,?)",
                        [SqlParameter.Text(execution), SqlParameter.Text(childSessionId), SqlParameter.Text(parentRunId.value),
                            SqlParameter.Text(parentOperationId.value), SqlParameter.Text(encodedAllowed)])
                } else if (members[0][0].getOrDefault({ => "" }) != parentRunId.value ||
                    members[0][1].getOrDefault({ => "" }) != parentOperationId.value || members[0].required(2) != encodedAllowed) {
                    throw IllegalStateException("child delegation lineage cannot be rebound or expanded")
                }
                let existing = tx.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=?",
                    [SqlParameter.Text(childSessionId)])
                if (existing.isEmpty()) {
                    tx.execute("INSERT INTO plan_execution_sessions(session_id,execution_id) VALUES(?,?)",
                        [SqlParameter.Text(childSessionId), SqlParameter.Text(execution)])
                } else if (existing[0].required(0) != execution) {
                    throw IllegalStateException("child session already belongs to another approved execution")
                }
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.inheritance_denied", "child session cannot inherit this immutable admitted task delegation")
        }
    }
    public func abandonUnstartedChild204(parentRunId: RunId, childSessionId: String,
        parentOperationId: OperationId): Result<Unit> {
        try {
            database.transaction { tx =>
                // This scalar proof is necessary in addition to the trusted
                // caller's actual pre-registration producer fence. It is not
                // a claim that a queued/started worker has stopped.
                let rows = tx.query("SELECT m.execution_id FROM plan_execution_members m " +
                    "JOIN plan_execution_runs b ON b.execution_id=m.execution_id AND b.run_id=m.parent_run_id " +
                    "JOIN plan_action_admissions a ON a.execution_id=b.execution_id AND a.operation_id=m.parent_operation_id " +
                    "JOIN operations o ON o.id=a.operation_id AND o.run_id=b.run_id " +
                    "WHERE b.run_id=? AND m.session_id=? AND m.parent_operation_id=?",
                    [SqlParameter.Text(parentRunId.value), SqlParameter.Text(childSessionId), SqlParameter.Text(parentOperationId.value)])
                if (rows.size != 1 || !tx.query("SELECT 1 FROM runs WHERE thread_id=? LIMIT 1", [SqlParameter.Text(childSessionId)]).isEmpty() ||
                    !tx.query("SELECT 1 FROM plan_execution_runs WHERE session_id=? LIMIT 1", [SqlParameter.Text(childSessionId)]).isEmpty()) {
                    throw IllegalStateException("child cleanup lacks exact immutable lineage or already has canonical Run history") }
                let active = tx.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=?", [SqlParameter.Text(childSessionId)])
                if (active.size > 1 || (active.size == 1 && active[0].required(0) != rows[0].required(0))) {
                    throw IllegalStateException("child active approval binding changed") }
                tx.execute("DELETE FROM plan_execution_sessions WHERE session_id=? AND execution_id=?",
                    [SqlParameter.Text(childSessionId), SqlParameter.Text(rows[0].required(0))])
                // Never delete member provenance, Thread data, Operations,
                // receipts, attempts, or another approval's active mapping.
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.child_cleanup_denied", "only an exact fresh unstarted child membership can be revoked")
        }
    }
    public func finish(runId: RunId): Result<Unit> {
        try {
            database.transaction { tx =>
                let owner = tx.query("SELECT e.session_id,b.session_id FROM plan_execution_runs b JOIN plan_executions e ON e.id=b.execution_id WHERE b.run_id=?", [SqlParameter.Text(runId.value)])
                if (owner.size != 1 || owner[0].required(0) != owner[0].required(1)) {
                    throw IllegalStateException("only the original owner may confirm global plan completion")
                }
                let state = tx.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(runId.value)])
                if (state.size != 1 || state[0].required(0) != "completed") {
                    throw IllegalStateException("plan completion requires successful canonical Run settlement")
                }
                sealApprovedPlanCompletion(tx, runId, knownParentAllocation)
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.finish_denied", "approved plan cannot finish before canonical owner settlement and complete evidence")
        }
    }
    public func finish204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<Unit> {
        try {
            database.transaction { tx =>
                let owner = tx.query("SELECT e.session_id,b.session_id,r.state FROM plan_execution_runs b JOIN plan_executions e ON e.id=b.execution_id JOIN runs r ON r.id=b.run_id WHERE b.run_id=?",
                    [SqlParameter.Text(runId.value)])
                if (owner.size != 1 || owner[0].required(0) != owner[0].required(1) || owner[0].required(2) != "completed") {
                    throw IllegalStateException("plan completion requires the original canonical Completed owner") }
                sealApprovedPlanCompletion(tx, runId, Some({ bytes => planReadAllocation204(payer, bytes) }))
            }
            Result.Ok(())
        } catch (_: Exception) { planExecutionError("plan.finish_denied", "canonical plan completion could not be paid or verified") }
    }
    public func openInspection204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204> {
        openRead204(runId.value, false, false, payer)
    }
    public func openSessionInspection204(sessionId: String, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204> {
        openRead204(sessionId, true, false, payer)
    }
    public func openRunScope204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204> {
        openRead204(runId.value, false, true, payer)
    }
    public func openSessionScope204(sessionId: String, payer: LogicalJsonOwnerReservation): Result<?PlanExecutionReadOwner204> {
        match (executionForSession(sessionId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(None) => return Result.Ok(None<PlanExecutionReadOwner204>)
            case _ => ()
        }
        match (openRead204(sessionId, true, true, payer)) {
            case Result.Ok(owner) => Result.Ok(Some(owner))
            case Result.Err(error) => Result.Err(error)
        }
    }
    public func openRequest204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204> {
        openDispatch204(runId, payer, true)
    }
    public func openBinding204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204> {
        openDispatch204(runId, payer, false)
    }
    private func openDispatch204(runId: RunId, payer: LogicalJsonOwnerReservation,
        request: Bool): Result<PlanExecutionReadOwner204> {
        let owner = try { newPlanReadOwner204(payer) } catch (_: Exception) {
            return planExecutionError("plan.read_capacity", "dispatch graph requires its original paid bank") }
        match (fillDispatch204(runId, owner, request)) {
            case Result.Err(error) => owner.closeAfterCaller204(); Result.Err(error)
            case Result.Ok(_) => Result.Ok(owner)
        }
    }
    private func fillDispatch204(runId: RunId, owner: PlanExecutionReadOwner204,
        request: Bool): Result<Unit> {
        try {
            database.readTransaction<Unit> { tx: SqliteTransaction =>
                let rows = tx.query("SELECT execution_id,session_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(runId.value)])
                if (rows.size != 1) { throw IllegalStateException("dispatch graph has no exact approved Run") }
                let execution = rows[0].required(0)
                let peak = fundPlanDispatchGraph204(tx, execution, runId, owner)
                let state = planProjection204(tx, execution, rows[0].required(1),
                    if (request) { "request" } else { "binding" }, Some(owner), peak)
                owner.installProducerData204(state)
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.read_capacity", "dispatch graph could not be paid and verified from the original bank")
        }
    }
    private func openRead204(identity: String, session: Bool, scope: Bool,
        payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204> {
        let owner = try { newPlanReadOwner204(payer) } catch (_: Exception) {
            return planExecutionError("plan.read_capacity", "approved plan read could not reserve the caller's original bank") }
        // This helper returns completely before failed unpublished DATA is
        // retired. No SQL/codec/error frame or raw alias crosses the boundary.
        match (fillRead204(owner, identity, session, scope)) {
            case Result.Ok(_) => Result.Ok(owner)
            case Result.Err(error) => owner.closeAfterCaller204(); Result.Err(error)
        }
    }
    private func fillRead204(owner: PlanExecutionReadOwner204, identity: String,
        session: Bool, scope: Bool): Result<Unit> {
        try {
            database.readTransaction<Unit> { tx: SqliteTransaction =>
                let binding = if (session) {
                    tx.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=?", [SqlParameter.Text(identity)])
                } else {
                    tx.query("SELECT execution_id,session_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(identity)])
                }
                var execution = ""
                var member = identity
                if (binding.size == 1) {
                    execution = binding[0].required(0)
                    if (!session) { member = binding[0].required(1) }
                } else if (session && !scope && binding.isEmpty()) {
                    let historical = tx.query("SELECT e.id FROM plan_executions e LEFT JOIN plan_execution_members m ON m.execution_id=e.id " +
                        "WHERE e.session_id=? OR m.session_id=? ORDER BY e.approval_sequence DESC LIMIT 1",
                        [SqlParameter.Text(identity), SqlParameter.Text(identity)])
                    if (historical.size != 1) { throw IllegalStateException("session has no approved plan history") }
                    execution = historical[0].required(0)
                } else { throw IllegalStateException("approved plan binding is missing or ambiguous") }
                if (scope) {
                    let _ = fundPlanClosedContract204(tx, execution, owner)
                    owner.installProducerData204(planReadScopeValue204(tx, execution))
                } else {
                    let peak = fundPlanReadSnapshot204(tx, execution, owner, true)
                    let state = planInspect(tx, execution, memberSession: member)
                    let _ = owner.fundProducerGraphWork204(state, peak)
                    owner.installProducerData204(state)
                }
            }
            Result.Ok(())
        } catch (_: Exception) {
            planExecutionError("plan.read_capacity", "approved plan read exceeded capacity or canonical history could not be verified")
        }
    }
    public func canContinue204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<Bool> {
        paidPlanScalar204(runId, payer, false)
    }
    public func requireComplete204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<Unit> {
        match (paidPlanScalar204(runId, payer, true)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(true) => Result.Ok(())
            case Result.Ok(false) => planExecutionError("plan.evidence_incomplete", "required plan steps do not have verified canonical evidence")
        }
    }
    private func paidPlanScalar204(runId: RunId, payer: LogicalJsonOwnerReservation, complete: Bool): Result<Bool> {
        let owner = try { newPlanReadOwner204(payer) } catch (_: Exception) {
            return planExecutionError("plan.read_capacity", "approved plan scalar read could not reserve the original bank") }
        let result = paidPlanScalarFrame204(runId, owner, complete)
        owner.closeAfterCaller204()
        result
    }
    private func paidPlanScalarFrame204(runId: RunId, owner: PlanExecutionReadOwner204, complete: Bool): Result<Bool> {
        try {
            Result.Ok(database.readTransaction<Bool> { tx: SqliteTransaction =>
                let rows = tx.query("SELECT execution_id,session_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(runId.value)])
                if (rows.size != 1) { throw IllegalStateException("Run has no approved execution") }
                let execution = rows[0].required(0)
                let _ = fundPlanClosedFacts204(tx, execution, runId, owner)
                if (complete) { planReadComplete204(tx, execution) }
                else { planReadCanContinue204(tx, execution, rows[0].required(1)) }
            })
        } catch (_: Exception) {
            planExecutionError("plan.read_capacity", "approved plan scalar projection could not be paid or verified")
        }
    }

    public func requireComplete(runId: RunId): Result<Unit> {
        try {
            let payer = knownParentAllocation.getOrThrow()(131072)
            let result = requireComplete204(runId, payer)
            payer.close(); result
        } catch (_: Exception) { planExecutionError("plan.read_capacity", "completion requires the original paid bank") }
    }

}

class PlanActionFact {
    let actionId: String
    let receipt: ?VNextOperationReceipt
    let retryDisposition: OperationRetryDisposition
    let sequence: Int64
    let mutating: Bool
    let operation: NormalizedOperationPlan
    init(actionId: String, receipt: ?VNextOperationReceipt, retryDisposition: OperationRetryDisposition,
        sequence: Int64, mutating: Bool, operation: NormalizedOperationPlan) {
        this.actionId = actionId
        this.receipt = receipt
        this.retryDisposition = retryDisposition
        this.sequence = sequence
        this.mutating = mutating
        this.operation = operation
    }
}
class PlanActionProjection {
    let state: String
    let attempts: Int64
    init(state: String, attempts: Int64) { this.state = state; this.attempts = attempts }
}
func planRunExecution(tx: SqliteTransaction, runId: RunId): String {
    let rows = tx.query("SELECT execution_id FROM plan_execution_runs WHERE run_id=?",
        [SqlParameter.Text(runId.value)])
    if (rows.size != 1) { throw IllegalStateException("Run has no approved plan binding") }
    rows[0].required(0)
}
func planLoadContract(tx: SqliteTransaction, execution: String): PlanContract {
    let rows = tx.query("SELECT contract FROM plan_executions WHERE id=?", [SqlParameter.Text(execution)])
    if (rows.size != 1) { throw IllegalStateException("execution contract is missing") }
    match (parsePlanContract(decodeStoredValue(rows[0].required(0)))) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("execution contract is invalid")
    }
}
func planFindStep(contract: PlanContract, id: String): PlanExecutionStep {
    for (step in contract.steps where step.id.value == id) { return step }
    throw IllegalStateException("unknown plan step")
}
func planFindAction(step: PlanExecutionStep, id: String): PlanAction {
    for (action in step.actions where action.id == id) { return action }
    throw IllegalStateException("unknown step action")
}
func planReadFacts(tx: SqliteTransaction, execution: String): Array<PlanActionFact> {
    let rows = tx.query("SELECT a.action_id,a.operation_id,r.id,r.outcome,r.detail,r.verification,r.created_at_millis,o.retry_disposition,a.admission_sequence,o.effect_class,o.normalized_plan " +
        "FROM plan_action_admissions a JOIN operations o ON o.id=a.operation_id LEFT JOIN operation_receipts r ON r.operation_id=o.id " +
        "WHERE a.execution_id=? ORDER BY a.action_id,a.attempt_no", [SqlParameter.Text(execution)])
    let facts = ArrayList<PlanActionFact>()
    for (row in rows) {
        let receipt: ?VNextOperationReceipt = match (row[2]) {
            case Some(id) => Some(VNextOperationReceipt(id, OperationId(row.required(1)),
                planParseOutcome(row.required(3)), decodeStoredValue(row.required(4)),
                planRegisteredArtifactVerification(tx, decodeStoredValue(row.required(5))), Int64.parse(row.required(6))))
            case None => None
        }
        // The trusted task executor mutates coordination metadata; source
        // effects are represented by the delegated child's own Operations.
        let operation = decodeOperationPlan(row.required(10))
        facts.add(PlanActionFact(row.required(0), receipt, parseStoreRetry(row.required(7)),
            Int64.parse(row.required(8)), row.required(9) != "read_only" && !planContains(["task", "plugin.axyndra:workflow.task"], operation.toolName), operation))
    }
    facts.toArray()
}
func planRegisteredArtifactVerification(tx: SqliteTransaction, verification: AgentValue): AgentValue {
    match (verification.field("artifact_digest")) {
        case Some(digest) =>
            if (digest.unifiedKind != ValueKind.Text) { return objectValue([]) }
            let rows = tx.query("SELECT hash FROM artifacts WHERE hash=?", [SqlParameter.Text(digest.text)])
            if (rows.size != 1) { return objectValue([]) }
        case None => ()
    }
    verification
}
func planParseOutcome(value: String): OperationOutcome {
    match (value) {
        case "completed" => OperationOutcome.Completed
        case "rejected" => OperationOutcome.Rejected
        case "cancelled" => OperationOutcome.Cancelled
        case "timed_out" => OperationOutcome.TimedOut
        case "failed" => OperationOutcome.Failed
        case _ => OperationOutcome.Unknown
    }
}
func planActionState(action: PlanAction, facts: Array<PlanActionFact>): PlanActionProjection {
    var attempts: Int64 = 0
    var verified = false
    var pending = false
    var stopped = false
    var fallback = false
    var retry = false
    var stale = false
    for (fact in facts where fact.actionId == action.id) {
        attempts += 1
        match (fact.receipt) {
            case None => pending = true
            case Some(receipt) =>
                if (planReceiptEvidence(action, receipt)) {
                    if (planEvidenceCurrent(action, fact, facts)) { verified = true }
                    else { stale = true }
                    continue
                }
                if (receipt.outcome == OperationOutcome.Completed) { stopped = true; continue }
                if (receipt.outcome == OperationOutcome.Unknown || receipt.outcome == OperationOutcome.Cancelled) {
                    stopped = true; continue
                }
                let error = planReceiptErrorDetail(receipt.detail)
                let failureClass = planOptionalText(error, "failure_class")
                if (failureClass == "policy_denied" || failureClass == "cancelled") {
                    stopped = true; continue
                }
                // Infrastructure rejection has an explicit no-target-started
                // diagnostic. Command nonzero is a dependency probe failure
                // only for read-only/safe-to-replay canonical Operations.
                let safe = fact.retryDisposition == OperationRetryDisposition.Safe ||
                    fact.retryDisposition == OperationRetryDisposition.ByIdempotencyKey
                let infra = failureClass == "infrastructure_unavailable" || failureClass == "dependency_unavailable"
                let command = receipt.detail.field("exit_code").isSome()
                let timedOut = receipt.outcome == OperationOutcome.TimedOut
                fallback = planCertifiedProbeFallback(action, fact, receipt) || (infra && planTargetNotStarted(error)) ||
                    (safe && (command || timedOut || failureClass == "command_failed" || failureClass == "timeout"))
                retry = safe && (planOptionalBool(error, "retryable") || timedOut || failureClass == "timeout")
                if (!fallback && !retry) { stopped = true }
        }
    }
    PlanActionProjection(if (pending) { "pending" } else if (verified) { "verified" }
        else if (stopped) { "blocked" } else if (stale) {
            if (attempts < action.maxAttempts) { "retry" } else { "blocked" }
        } else if (attempts == 0) { "runnable" }
        else if (retry && attempts < action.maxAttempts) { "retry" }
        else if (fallback) { "fallback" } else { "blocked" }, attempts)
}
// Test execution proves the version it ran against. A later mutation or an
// earlier mutation still completing afterwards invalidates exit-zero evidence.
// The original attempt remains spent; rerunning needs approved budget.
func planEvidenceCurrent(action: PlanAction, fact: PlanActionFact, facts: Array<PlanActionFact>): Bool {
    if (action.evidence != "exit_zero") { return true }
    let verified = fact.receipt.getOrThrow()
    for (other in facts where other.mutating && other.actionId != fact.actionId) {
        if (other.sequence > fact.sequence) { return false }
        match (other.receipt) {
            case Some(receipt) => if (receipt.observedAtMillis > verified.observedAtMillis) { return false }
            case None => return false
        }
    }
    true
}
func planRawStep(step: PlanExecutionStep, facts: Array<PlanActionFact>): String {
    var allVerified = true
    var pending = false
    var blocked = false
    var fallback = false
    for (action in step.actions) {
        let state = planActionState(action, facts).state
        if (state != "verified") { allVerified = false }
        if (state == "pending") { pending = true }
        if (state == "blocked") { blocked = true }
        if (state == "fallback") { fallback = true }
    }
    if (pending) { "pending" } else if (allVerified) { "verified" }
    else if (blocked) { "blocked" } else if (fallback) { "fallback" } else { "runnable" }
}
class PlanStatusEntry {
    let id: String
    let state: String
    init(id: String, state: String) { this.id = id; this.state = state }
}
func planProjectedStep(contract: PlanContract, facts: Array<PlanActionFact>, id: String,
    visited: Array<String>): String {
    planProjectCached(contract, facts, id, visited, ArrayList<PlanStatusEntry>())
}
func planProjectCached(contract: PlanContract, facts: Array<PlanActionFact>, id: String,
    visited: Array<String>, cache: ArrayList<PlanStatusEntry>): String {
    for (entry in cache where entry.id == id) { return entry.state }
    let state = planComputeProjectedStep(contract, facts, id, visited, cache)
    cache.add(PlanStatusEntry(id, state))
    state
}
func planComputeProjectedStep(contract: PlanContract, facts: Array<PlanActionFact>, id: String,
    visited: Array<String>, cache: ArrayList<PlanStatusEntry>): String {
    if (planContains(visited, id)) { return "blocked" }
    let seen = ArrayList<String>()
    for (item in visited) { seen.add(item) }
    seen.add(id)
    let step = planFindStep(contract, id)
    let raw = planRawStep(step, facts)
    var fallbackTarget = false
    var activated = false
    for (source in contract.steps) {
        match (source.fallbackStepId) {
            case Some(target) => if (target == id) {
                fallbackTarget = true
                if (planRawStep(source, facts) == "fallback") { activated = true }
            }
            case None => ()
        }
    }
    if (fallbackTarget && !activated) { return "dormant" }
    for (dependency in step.dependencies) {
        let state = planProjectCached(contract, facts, dependency, seen.toArray(), cache)
        if (state != "verified" && state != "fallback_verified") {
            return if (state == "blocked") { "blocked" } else { "waiting_dependency" }
        }
    }
    if (raw == "fallback") {
        match (step.fallbackStepId) {
            case Some(target) =>
                let state = planProjectCached(contract, facts, target, seen.toArray(), cache)
                if (state == "verified" || state == "fallback_verified") { return "fallback_verified" }
                if (state == "blocked") { return "blocked" }
                return "fallback"
            case None => return "blocked"
        }
    }
    raw
}
func planInspect(tx: SqliteTransaction, execution: String, memberSession!: String = ""): AgentValue {
    planProjection204(tx, execution, memberSession, "public", None<PlanExecutionReadOwner204>, 131072)
}
// All views share this single canonical fold. Binding skips progress DOMs;
// request builds only progress+runnable action data, never a full inspection.
func planProjection204(tx: SqliteTransaction, execution: String, memberSession: String,
    view: String, owner: ?PlanExecutionReadOwner204, peak: Int64): AgentValue {
    let contract = planLoadContract(tx, execution)
    let facts = planReadFacts(tx, execution)
    let allowedActions = if (memberSession == "") { planAllActionIds(contract) }
        else { planMemberActions(tx, execution, memberSession) }
    let visibleContract = if (memberSession == "") { contract } else { planMemberContractFrom204(contract, allowedActions) }
    let steps = ArrayList<AgentValue>()
    let allowedTools = ArrayList<String>()
    let runnableActions = ArrayList<String>()
    let active = !tx.query("SELECT s.execution_id FROM plan_execution_sessions s JOIN plan_executions e ON e.session_id=s.session_id WHERE e.id=? AND s.execution_id=e.id",
        [SqlParameter.Text(execution)]).isEmpty()
    let sealing = tx.query("SELECT sealed FROM plan_executions WHERE id=?", [SqlParameter.Text(execution)])
    let sealed = sealing.size == 1 && sealing[0].required(0) == "1"
    var complete = true
    var recoveryRequired = planExecutionHasUnknown(tx, execution)
    if (recoveryRequired) { complete = false }
    for (fact in facts) {
        match (fact.receipt) {
            case Some(receipt) => if (receipt.outcome == OperationOutcome.Unknown) { complete = false; recoveryRequired = true }
            case None => complete = false
        }
    }
    for (step in contract.steps) {
        let state = planProjectedStep(contract, facts, step.id.value, [])
        if (step.required && state != "verified" && state != "fallback_verified" && state != "dormant") {
            complete = false
        }
        let actions = ArrayList<AgentValue>()
        let stepReceipts = ArrayList<String>()
        for (action in step.actions) {
            let projection = planActionState(action, facts)
            if (projection.state == "pending") { complete = false }
            if (active && !recoveryRequired && planContains(allowedActions, action.id) && state == "runnable" && (projection.state == "runnable" || projection.state == "retry")) {
                runnableActions.add(action.id)
                for (tool in action.toolNames where !planContains(allowedTools.toArray(), tool)) { allowedTools.add(tool) }
            }
            if (!planContains(allowedActions, action.id) || view == "binding") { continue }
            let receiptIds = ArrayList<String>()
            for (fact in facts where fact.actionId == action.id) {
                match (fact.receipt) {
                    case Some(receipt) =>
                        receiptIds.add(receipt.receiptId)
                        stepReceipts.add(receipt.receiptId)
                    case None => ()
                }
            }
            actions.add(objectValue([ValueField("action_id", textValue(action.id)),
                ValueField("state", textValue(projection.state)),
                ValueField("attempts", integerValue(projection.attempts)),
                ValueField("remaining_attempts", integerValue(action.maxAttempts - projection.attempts)),
                ValueField("reason", textValue(planActionReason(action, facts, projection))),
                ValueField("receipt_ids", stringValues(receiptIds.toArray()))]))
        }
        if (view != "binding") { steps.add(objectValue([ValueField("step_id", textValue(step.id.value)),
            ValueField("state", textValue(state)), ValueField("required", boolValue(step.required)),
            ValueField("reason", textValue(planDecisionReason(state))),
            ValueField("receipt_ids", stringValues(stepReceipts.toArray())),
            ValueField("actions", listValue(actions.toArray()))])) }
    }
    if (view == "binding") {
        return objectValue([ValueField("contract_view", planContractValue(visibleContract)),
            ValueField("runnable_action_ids", stringValues(runnableActions.toArray())),
            ValueField("allowed_tools", stringValues(allowedTools.toArray()))])
    }
    if (view == "request") {
        let paid = owner.getOrThrow()
        let digest = planRequestContractDigestFrame204(visibleContract, paid, peak)
        let details = ArrayList<AgentValue>()
        for (step in visibleContract.steps) {
            for (action in step.actions where planContains(runnableActions.toArray(), action.id)) {
                details.add(planRequestActionFrame204(step.id.value, action, paid, peak))
            }
        }
        return objectValue([ValueField("execution_id", textValue(execution)), ValueField("active", boolValue(active)),
            ValueField("complete", boolValue(complete)), ValueField("sealed", boolValue(sealed)),
            ValueField("recovery_required", boolValue(recoveryRequired)), ValueField("steps", listValue(steps.toArray())),
            ValueField("allowed_tools", stringValues(allowedTools.toArray())), ValueField("contract_digest", textValue(digest)),
            ValueField("target_roots", stringValues(contract.targetRoots)),
            ValueField("participating_repositories", stringValues(contract.participatingRepositories)),
            ValueField("runnable_actions", listValue(details.toArray()))])
    }
    objectValue([ValueField("execution_id", textValue(execution)), ValueField("active", boolValue(active)), ValueField("sealed", boolValue(sealed)), ValueField("complete", boolValue(complete)),
        ValueField("recovery_required", boolValue(recoveryRequired)),
        ValueField("steps", listValue(steps.toArray())), ValueField("allowed_tools", stringValues(allowedTools.toArray())),
        ValueField("contract_view", planContractValue(visibleContract)),
        ValueField("allowed_action_ids", stringValues(allowedActions)),
        ValueField("runnable_action_ids", stringValues(runnableActions.toArray()))])
}
func planDecisionReason(state: String): String {
    match (state) {
        case "verified" => "canonical Operation receipts satisfy the approved evidence requirements"
        case "fallback_verified" => "the approved fallback satisfies this step"
        case "fallback" => "eligible dependency failure selected the approved fallback"
        case "runnable" => "dependencies satisfied and approved attempts remain"
        case "retry" => "known safe failure or stale verification permits another approved attempt"
        case "pending" => "reserved Operation has no terminal canonical receipt; recovery is required"
        case "waiting_dependency" => "a required dependency has not been verified"
        case "recovery_required" => "the approved execution contains an unknown Operation outcome; explicit reconciliation is required"
        case "cancelled" => "the observed Operation was cancelled; task continuation is not authorized"
        case "policy_denied" => "the observed Operation was denied by policy or approval"
        case "continue_independent" => "a known safe failure blocks this step, while approved independent work remains runnable"
        case "dormant" => "fallback has not been selected"
        case _ => "permission, cancellation, unknown outcome, exhausted budget, or missing evidence prevents progress"
    }
}
func planStoredDecision(value: AgentValue): PlanStepDecision {
    let fallback = value.field("fallback_step_id").getOrThrow()
    PlanStepDecision(value.field("step_id").getOrThrow().text,
        value.field("decision").getOrThrow().text, value.field("reason").getOrThrow().text,
        receiptId: value.field("receipt_id").getOrThrow().text,
        fallbackStepId: if (fallback.unifiedKind == ValueKind.Null) { None } else { Some(fallback.text) })
}
func planOptionalText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(raw) => if (raw.unifiedKind == ValueKind.Text) { raw.text } else { "" }
        case None => ""
    }
}
func planOptionalBool(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(raw) => raw.unifiedKind == ValueKind.Boolean && raw.asBool()
        case None => false
    }
}

func planTargetNotStarted(error: AgentValue): Bool {
    match (error.field("started")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Boolean && !value.asBool()) { return true }
        case None => ()
    }
    match (error.field("fields")) {
        case Some(fields) => if (fields.unifiedKind == ValueKind.List) {
            for (field in fields.items where planOptionalText(field, "name") == "started") {
                return planOptionalText(field, "value") == "false"
            }
        }
        case None => ()
    }
    false
}

func planHasIndependentRunnable(contract: PlanContract, facts: Array<PlanActionFact>, failedStep: String): Bool {
    for (step in contract.steps where step.id.value != failedStep) {
        if (planProjectedStep(contract, facts, step.id.value, []) == "runnable") { return true }
    }
    false
}

func planRequireDependencies(contract: PlanContract, facts: Array<PlanActionFact>, step: PlanExecutionStep): Unit {
    for (dependency in step.dependencies) {
        let state = planProjectedStep(contract, facts, dependency, [])
        if (state != "verified" && state != "fallback_verified") {
            throw IllegalStateException("approved execution prerequisite evidence is no longer current")
        }
    }
}

// Called inside the canonical Operation writer transaction immediately before
// executor handoff; never executes tools and never creates another attempt.
func requirePlanExecutionPreconditions(tx: SqliteTransaction, runId: RunId, operationId: OperationId): Unit {
    let bindings = tx.query("SELECT b.execution_id,a.step_id,a.action_id,b.session_id,o.normalized_plan FROM plan_execution_runs b JOIN operations o ON o.run_id=b.run_id AND o.id=? JOIN plan_action_admissions a " +
        "ON a.execution_id=b.execution_id AND a.operation_id=? WHERE b.run_id=?",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (bindings.size != 1) { throw IllegalStateException("approved action reservation is missing") }
    let execution = bindings[0].required(0)
    planRequireUnsealed(tx, execution)
    planRequireNoUnknown(tx, execution)
    let contract = planLoadContract(tx, execution)
    if (!planContains(planMemberActions(tx, execution, bindings[0].required(3)), bindings[0].required(2))) {
        throw IllegalStateException("prepared action exceeds immutable member delegation")
    }
    let step = planFindStep(contract, bindings[0].required(1))
    let action = planFindAction(step, bindings[0].required(2))
    if (!planActionAllows(contract, action, decodeOperationPlan(bindings[0].required(4)))) {
        throw IllegalStateException("prepared Operation write scope or action constraints drifted")
    }
    planRequireDependencies(contract, planReadFacts(tx, execution), step)
}

func planAllActionIds(contract: PlanContract): Array<String> {
    let ids = ArrayList<String>()
    for (step in contract.steps) { for (action in step.actions) { ids.add(action.id) } }
    ids.toArray()
}
func planMemberActions(tx: SqliteTransaction, execution: String, sessionId: String): Array<String> {
    let rows = tx.query("SELECT allowed_actions FROM plan_execution_members WHERE execution_id=? AND session_id=?",
        [SqlParameter.Text(execution), SqlParameter.Text(sessionId)])
    if (rows.size != 1) { throw IllegalStateException("execution member is missing") }
    let allowed = storeStringItems(decodeStoredValue(rows[0].required(0)))
    var ancestor = sessionId
    let seen = ArrayList<String>()
    for (_ in 0..128) {
        if (planContains(seen.toArray(), ancestor)) { throw IllegalStateException("delegation ancestry is cyclic") }
        seen.add(ancestor)
        let member = tx.query("SELECT parent_run_id,parent_operation_id FROM plan_execution_members WHERE execution_id=? AND session_id=?",
            [SqlParameter.Text(execution), SqlParameter.Text(ancestor)])
        if (member.size != 1) { throw IllegalStateException("delegation ancestor is missing") }
        if (member[0][0].isNone() && member[0][1].isNone()) {
            let owner = tx.query("SELECT session_id FROM plan_executions WHERE id=?", [SqlParameter.Text(execution)])
            if (owner.size != 1 || owner[0].required(0) != ancestor) { throw IllegalStateException("delegation does not terminate at the approved owner") }
            return allowed
        }
        let parentRun = member[0].required(0)
        let parentOperation = member[0].required(1)
        let parent = tx.query("SELECT b.session_id,o.state,r.outcome FROM plan_execution_runs b JOIN operations o ON o.run_id=b.run_id AND o.id=? " +
            "LEFT JOIN operation_receipts r ON r.operation_id=o.id WHERE b.run_id=? AND b.execution_id=? " +
            "AND EXISTS (SELECT 1 FROM audit_events h WHERE h.operation_id=o.id AND h.run_id=b.run_id AND h.kind='operation_execution_handoff')",
            [SqlParameter.Text(parentOperation), SqlParameter.Text(parentRun), SqlParameter.Text(execution)])
        if (parent.size != 1) { throw IllegalStateException("delegation parent lacks canonical execution provenance") }
        match (parent[0][2]) {
            case Some(outcome) => if (outcome != "completed") { throw IllegalStateException("delegation ancestor did not complete successfully") }
            case None => if (parent[0].required(1) != "executing") { throw IllegalStateException("delegation ancestor is no longer live") }
        }
        ancestor = parent[0].required(0)
    }
    throw IllegalStateException("delegation ancestry exceeds the supported depth")
}
func planMemberContract(tx: SqliteTransaction, execution: String, sessionId: String): PlanContract {
    let contract = planLoadContract(tx, execution)
    let allowed = planMemberActions(tx, execution, sessionId)
    planMemberContractFrom204(contract, allowed)
}
func planMemberContractFrom204(contract: PlanContract, allowed: Array<String>): PlanContract {
    let steps = ArrayList<PlanExecutionStep>()
    for (step in contract.steps) {
        let actions = ArrayList<PlanAction>()
        for (action in step.actions where planContains(allowed, action.id)) { actions.add(action) }
        if (!actions.isEmpty()) { steps.add(PlanExecutionStep(step.id, step.dependencies, step.required,
            actions.toArray(), fallbackStepId: step.fallbackStepId)) }
    }
    PlanContract(contract.targetRoots, steps.toArray(), participatingRepositories: contract.participatingRepositories)
}

func planActionReason(action: PlanAction, facts: Array<PlanActionFact>, projection: PlanActionProjection): String {
    if (projection.state == "blocked" || projection.state == "retry") {
        for (fact in facts where fact.actionId == action.id) {
            match (fact.receipt) {
                case Some(receipt) =>
                    if (receipt.outcome == OperationOutcome.Unknown) { return "canonical outcome is unknown; explicit recovery is required" }
                    if (receipt.outcome == OperationOutcome.Cancelled) { return "canonical Operation was cancelled" }
                case None => ()
            }
        }
        for (fact in facts where fact.actionId == action.id) {
            match (fact.receipt) {
                case Some(receipt) => if (receipt.outcome == OperationOutcome.Completed && planReceiptEvidence(action, receipt) &&
                    !planEvidenceCurrent(action, fact, facts)) { return "source mutation invalidated prior verification; a new approved attempt is required" }
                case None => ()
            }
        }
    }
    if (projection.state == "blocked" && projection.attempts >= action.maxAttempts) {
        return "approved attempt budget is exhausted without sufficient canonical evidence"
    }
    planDecisionReason(projection.state)
}

func planRequireUnsealed(tx: SqliteTransaction, execution: String): Unit {
    let rows = tx.query("SELECT sealed FROM plan_executions WHERE id=?", [SqlParameter.Text(execution)])
    if (rows.size != 1 || rows[0].required(0) != "0") {
        throw IllegalStateException("approved execution is sealed and cannot admit further work")
    }
}

// An unknown external effect stops dispatch across every member Run, not only
// the Run that observed it. Canonical recovery facts remain untouched.
func planRequireNoUnknown(tx: SqliteTransaction, execution: String): Unit {
    if (planExecutionHasUnknown(tx, execution)) {
        throw IllegalStateException("execution has an unknown Operation outcome; canonical reconciliation is required before further dispatch")
    }
}
func planExecutionHasUnknown(tx: SqliteTransaction, execution: String): Bool {
    !tx.query("SELECT 1 FROM plan_action_admissions a JOIN operation_receipts r ON r.operation_id=a.operation_id " +
        "WHERE a.execution_id=? AND r.outcome='unknown' UNION ALL " +
        "SELECT 1 FROM derived_operation_admissions child JOIN plan_action_admissions a ON a.operation_id=(" + planDerivedRootCandidateSql204("child") + ") " +
        "JOIN operation_receipts r ON r.operation_id=child.operation_id WHERE a.execution_id=? AND r.outcome='unknown' LIMIT 1",
        [SqlParameter.Text(execution), SqlParameter.Text(execution)]).isEmpty()
}

// Recoverable ToolResults retain a legacy string error for presentation. Only
// typed object metadata is interpreted; arbitrary message text is never parsed.
func planReceiptErrorDetail(detail: AgentValue): AgentValue {
    match (detail.field("error_detail")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Object) { return value }
        case None => ()
    }
    match (detail.field("error")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Object) { return value }
        case None => ()
    }
    detail
}

// Plan review is a host-selected read-only control plane. The marker is bound
// into the canonical Operation, never read from model tool arguments.
func allowPlanReviewControlOperation(tx: SqliteTransaction, runId: RunId,
    operationId: OperationId, bindingDigest: String, payer: LogicalJsonOwnerReservation): Bool {
    let rows = tx.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (rows.size != 1) { throw IllegalStateException("canonical Operation plan is missing") }
    let plan = decodeOperationPlan(rows[0].required(0))
    if (plan.policyVersion != "tool-policy-plan-review-v1") { return false }
    if (plan.bindingDigest != bindingDigest ||
        plan.effectClass != OperationEffectClass.ReadOnly ||
        plan.networkPolicy.mode != NetworkPolicyMode.Denied || !plan.resolvedHosts.isEmpty() || !plan.approvedWriteRoots.isEmpty()) {
        throw IllegalStateException("plan review Operation violates the frozen read-only control policy")
    }
    if (!planReviewFrozenIdentity204(tx, runId, plan, payer)) {
        throw IllegalStateException("plan review marker lacks its exact trusted frozen catalog identity")
    }
    if (!planReviewCapabilitiesAllowed(plan)) {
        throw IllegalStateException("plan review Operation requires a forbidden capability")
    }
    if (!tx.query("SELECT run_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(runId.value)]).isEmpty()) {
        throw IllegalStateException("an execution-bound Run cannot switch to plan review control")
    }
    true
}

// This certificate is emitted by the controlled network probe adapter only.
// It describes a stopped, bounded attempt, not proof of zero mutations and
// never grants a retry. A model message/stdout cannot create these fields.
func planCertifiedProbeFallback(action: PlanAction, fact: PlanActionFact, receipt: VNextOperationReceipt): Bool {
    if (fact.operation.toolName != "command_probe" || fact.operation.networkPolicy.mode == NetworkPolicyMode.Denied ||
        (receipt.outcome != OperationOutcome.Failed && receipt.outcome != OperationOutcome.TimedOut) ||
        !planOptionalBool(receipt.detail, "fallback_allowed") || !planOptionalBool(receipt.detail, "target_stopped")) { return false }
    let pin = action.toolIdentities.field("command_probe").getOrDefault({ => objectValue([]) })
    if (planOptionalText(pin, "version") != fact.operation.implementation.toolVersion ||
        planOptionalText(pin, "fingerprint") != fact.operation.implementation.implementationFingerprint ||
        planOptionalText(pin, "schema_digest") != fact.operation.implementation.schemaDigest) { return false }
    let started = receipt.detail.field("started")
    let completed = receipt.detail.field("completed")
    let timedOut = receipt.detail.field("timed_out")
    let code = receipt.detail.field("exit_code")
    match ((started, completed, timedOut, code)) {
        case (Some(start), Some(done), Some(timeout), Some(exit)) =>
            if (start.unifiedKind != ValueKind.Boolean || done.unifiedKind != ValueKind.Boolean ||
                timeout.unifiedKind != ValueKind.Boolean || exit.unifiedKind != ValueKind.Number || !start.asBool()) { return false }
            let exitCode = try { Int64.parse(exit.asNumberText()) } catch (_: Exception) { return false }
            if (timeout.asBool()) { return !done.asBool() }
            done.asBool() && exitCode != 0
        case _ => false
    }
}

// Runs and plan completion publish together. The canonical settlement caller
// has already enforced the original owned-work/continuation/Operation barrier.
func sealApprovedPlanCompletion(tx: SqliteTransaction, runId: RunId,
    allocate: ?(Int64)->LogicalJsonOwnerReservation): Unit {
    let rows = tx.query("SELECT e.id,e.sealed,e.session_id,b.session_id FROM plan_execution_runs b JOIN plan_executions e ON e.id=b.execution_id WHERE b.run_id=?",
        [SqlParameter.Text(runId.value)])
    if (rows.isEmpty()) { return }
    if (rows.size != 1) { throw IllegalStateException("ambiguous approved execution") }
    if (rows[0].required(2) != rows[0].required(3) || rows[0].required(1) == "1") { return }
    let payment = allocate.getOrThrow()(131072)
    let owner = PlanExecutionReadOwner204(payment)
    try { sealApprovedPlanCompletionFrame204(tx, runId, owner) }
    finally { owner.closeAfterCaller204() }
}
func sealApprovedPlanCompletionFrame204(tx: SqliteTransaction, runId: RunId,
    readOwner: PlanExecutionReadOwner204): Unit {
    let owner = tx.query("SELECT e.id,e.session_id,b.session_id,e.sealed FROM plan_execution_runs b " +
        "JOIN plan_executions e ON e.id=b.execution_id WHERE b.run_id=?", [SqlParameter.Text(runId.value)])
    if (owner.isEmpty()) { return }
    if (owner.size != 1) { throw IllegalStateException("Run has ambiguous approved execution") }
    if (owner[0].required(1) != owner[0].required(2)) { return }
    let execution = owner[0].required(0)
    if (owner[0].required(3) == "1") { return }
    let active = tx.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=?",
        [SqlParameter.Text(owner[0].required(1))])
    if (active.size != 1 || active[0].required(0) != execution) {
        throw IllegalStateException("approved execution is no longer active")
    }
    let _ = fundPlanClosedFacts204(tx, execution, runId, readOwner)
    if (!planReadComplete204(tx, execution)) {
        throw IllegalStateException("required canonical plan evidence is incomplete")
    }
    let unresolved = tx.query("SELECT a.operation_id FROM plan_action_admissions a LEFT JOIN operation_receipts r " +
        "ON r.operation_id=a.operation_id WHERE a.execution_id=? AND (r.id IS NULL OR r.outcome='unknown') LIMIT 1",
        [SqlParameter.Text(execution)])
    if (!unresolved.isEmpty()) { throw IllegalStateException("pending or unknown Operations prevent execution sealing") }
    tx.execute("UPDATE plan_executions SET sealed=1 WHERE id=? AND sealed=0", [SqlParameter.Text(execution)])
    tx.execute("DELETE FROM plan_execution_sessions WHERE execution_id=?", [SqlParameter.Text(execution)])
}

// A compiled Host child is already part of its admitted root action. Reuse
// only the immutable canonical derived identity, never a caller-supplied
// parent string or a second attempt ledger. Existing Host intent/source
// checks still run independently at both concrete pre-effect transitions.
func requireApprovedDerivedPlanAdmission(tx: SqliteTransaction, operationId: OperationId,
    runId: RunId, bindingDigest: String,
    documentAllocation!: ?(Int64)->LogicalJsonOwnerReservation = None): Unit {
    let rows = tx.query("SELECT root.id,child.normalized_plan,root.normalized_plan,root.state,a.execution_id," +
        "d.root_operation_id,d.child_call_id,d.depth,d.request_digest,child.tool_call_item_id,root.tool_call_item_id " +
        "FROM derived_operation_admissions d JOIN operations child ON child.id=d.operation_id " +
        "JOIN operations root ON root.id=(" + planDerivedRootCandidateSql204("d") + ") AND root.run_id=child.run_id " +
        "JOIN plan_action_admissions a ON a.operation_id=root.id JOIN plan_execution_runs b ON b.run_id=root.run_id AND b.execution_id=a.execution_id " +
        "WHERE child.id=? AND child.run_id=?", [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (rows.size != 1) { throw IllegalStateException("derived Operation lacks its exact admitted canonical root") }
    let child = decodeOperationPlan(rows[0].required(1))
    let parent = decodeOperationPlan(rows[0].required(2))
    if (child.bindingDigest != bindingDigest || rows[0].required(3) != "executing") {
        throw IllegalStateException("derived Operation or its live root changed")
    }
    if (rows[0].required(5) == "") {
        if (rows[0].required(6) != "" || rows[0].required(7) != "0" ||
            rows[0].required(8) != child.bindingDigest || rows[0].required(9) != rows[0].required(10) ||
            !isExactServiceChildPlan(child)) {
            throw IllegalStateException("legacy derived candidate is not an exact canonical Host service child")
        }
        requireExactParentIntentInTransaction204(tx, operationId, runId, child,
            documentPayloadAllocation: documentAllocation)
        if (parent.toolName == "plugin.axyndra:workflow.task" && !pluginChildParentAllows111(parent, child)) {
            throw IllegalStateException("Native child does not match its frozen canonical parent intent")
        }
    }
    let rootId = OperationId(rows[0].required(0))
    requirePlanExecutionPreconditions(tx, runId, rootId)
    if (tx.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND kind='operation_execution_handoff' LIMIT 1",
        [SqlParameter.Text(rootId.value), SqlParameter.Text(runId.value)]).isEmpty() ||
        !tx.query("SELECT id FROM operation_receipts WHERE operation_id=?", [SqlParameter.Text(rootId.value)]).isEmpty()) {
        throw IllegalStateException("derived Operation requires its still-live canonical root handoff")
    }
    let contract = planLoadContract(tx, rows[0].required(4))
    for (path in child.resolvedPaths) {
        if (!planPathInRoots(path, contract.targetRoots) && !(child.effectClass == OperationEffectClass.ReadOnly &&
            planPathInRoots(path, contract.participatingRepositories))) { throw IllegalStateException("derived child path exceeds approved scope") }
    }
    for (capability in child.requiredCapabilities) {
        if ((capability.kind == CapabilityKind.WorkspaceRead || capability.kind == CapabilityKind.WorkspaceWrite) &&
            capability.resource.startsWith("/") && !planPathInRoots(capability.resource, contract.targetRoots) &&
            !(child.effectClass == OperationEffectClass.ReadOnly && capability.kind == CapabilityKind.WorkspaceRead &&
                planPathInRoots(capability.resource, contract.participatingRepositories))) {
            throw IllegalStateException("derived read/write capability exceeds approved path scope")
        }
    }
    if (child.networkPolicy.mode != parent.networkPolicy.mode) {
        throw IllegalStateException("derived child cannot change the approved root network mode")
    }
    if (child.toolName == "bash" || child.toolName == "command_probe" || child.toolName == "host.process.readonly") {
        if (child.cwd == "" || !planPathInRoots(child.cwd, contract.targetRoots) || child.approvedWriteRoots.isEmpty() ||
            canonicalAgentValue(stringValues(child.approvedWriteRoots)) != canonicalAgentValue(stringValues(contract.targetRoots))) {
            throw IllegalStateException("derived process cannot exceed approved write mounts")
        }
    } else if (child.effectClass != OperationEffectClass.ReadOnly && child.resolvedPaths.isEmpty()) {
        // The official Task consumer performs only the existing Kernel child
        // coordination contract; every real child Run has its own admission.
        if (parent.toolName != "plugin.axyndra:workflow.task" || !pluginChildParentAllows111(parent, child)) {
            throw IllegalStateException("opaque mutating child has no approved filesystem scope")
        }
    }
}

func planContextExecution(tx: SqliteTransaction, runId: RunId): String {
    let bound = tx.query("SELECT execution_id FROM plan_execution_runs WHERE run_id=?", [SqlParameter.Text(runId.value)])
    if (bound.size == 1) { return bound[0].required(0) }
    if (bound.size > 1) { throw IllegalStateException("context Run has ambiguous approved execution") }
    let active = tx.query("SELECT s.execution_id FROM runs r JOIN plan_execution_sessions s ON s.session_id=r.thread_id WHERE r.id=?",
        [SqlParameter.Text(runId.value)])
    if (active.size > 1) { throw IllegalStateException("context session has ambiguous approved execution") }
    if (active.isEmpty()) { "" } else { active[0].required(0) }
}

// Initialization is not a model action. This branch requires the existing
// private Runtime seal's canonical origin+admission enclosure; a tool name,
// public DTO, review marker, or WorkspaceRead capability cannot authorize it.
// Existing live sealed-source and permission checks still precede the actual
// executor. No budget reservation or duplicate operation state is created.
func allowPlanInitializationRead(tx: SqliteTransaction, operationId: OperationId,
    runId: RunId, bindingDigest: String): Bool {
    let execution = planContextExecution(tx, runId)
    if (execution == "") { return false }
    let rows = tx.query("SELECT o.tool_call_item_id,i.provenance FROM operations o JOIN items i ON i.id=o.tool_call_item_id " +
        "JOIN runs r ON r.id=o.run_id JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id " +
        "WHERE o.id=? AND o.run_id=? AND r.state='running' AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id " +
        "AND turn.active_run_id=r.id AND turn.state='active'", [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (rows.size != 1) { return false }
    let origin = match (decodeStoredProvenance(rows[0].required(1)).directOrigin) {
        case Some(DirectCallOrigin.ContextRead(value)) => value
        case _ => return false
    }
    if (origin.parentCallItemId != "" || origin.parentKind != "" || origin.parentOperationId != "" ||
        origin.parentDecisionId != "" || origin.parentScopedCallId != "") { return false }
    let stored = tx.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (stored.size != 1) { throw IllegalStateException("initialization read lost its canonical plan") }
    let plan = decodeOperationPlan(stored[0].required(0))
    if (!isContextReadPlan(plan) || plan.bindingDigest != bindingDigest ||
        !plan.approvedWriteRoots.isEmpty() || !plan.networkPolicy.egress.isEmpty() || !plan.networkPolicy.publish.isEmpty() ||
        !plan.relevantEnvironment.isEmpty() || plan.idempotencyKey != "") { return false }
    for (capability in plan.requiredCapabilities where capability.kind != CapabilityKind.WorkspaceRead) { return false }
    requireContextReadPlan(tx, ItemId(rows[0].required(0)), plan)
    requireContextReadOriginBinding(tx, operationId, runId, ItemId(rows[0].required(0)), false)
    // Explicit operator-selected review may examine a replacement scope.
    // The marker alone is insufficient: the exact private-seal enclosure
    // above binds it through contextReadPlanDigest before this branch.
    if (plan.policyVersion == "tool-policy-plan-review-v1") { return true }
    planRequireUnsealed(tx, execution)
    planRequireNoUnknown(tx, execution)
    let contract = planLoadContract(tx, execution)
    for (path in plan.resolvedPaths) {
        if (!planPathInRoots(path, contract.targetRoots) && !planPathInRoots(path, contract.participatingRepositories)) {
            throw IllegalStateException("initialization read exceeds approved read scope")
        }
    }
    requireContextReadPlan(tx, ItemId(rows[0].required(0)), plan)
    requireContextReadOriginBinding(tx, operationId, runId, ItemId(rows[0].required(0)), false)
    true
}

// Optional sources are inspected by the Host collector after this scope gate.
// Resolve the real ancestor before appending missing components, so absence
// metadata is allowed inside scope without following a symlink outside it.
func canonicalPlanContextPath(source: String): String {
    if (!Path(source).isAbsolute() || source.contains("\u{0000}")) {
        throw IllegalArgumentException("context resource requires an absolute path")
    }
    var current = Path(source)
    let suffix = ArrayList<String>()
    while (!exists(current)) {
        let parent = current.parent
        if (parent.toString() == current.toString() || parent.toString() == "") {
            throw IllegalArgumentException("context resource has no canonical ancestor")
        }
        suffix.add(current.fileName)
        current = parent
    }
    var resolved = canonicalize(current)
    var index = suffix.size
    while (index > 0) { index -= 1; resolved = resolved.join(suffix[index]) }
    resolved.normalize().toString()
}

// Review's read-only mounted service is an exact compiled child of the
// host-selected frozen review root, and cannot invent its own review flag.
func allowPlanReviewDerivedOperation(tx: SqliteTransaction, runId: RunId,
    operationId: OperationId, bindingDigest: String, payer: LogicalJsonOwnerReservation): Bool {
    let rows = tx.query("SELECT d.root_operation_id,child.normalized_plan,root.normalized_plan,root.state FROM derived_operation_admissions d " +
        "JOIN operations child ON child.id=d.operation_id JOIN operations root ON root.id=d.root_operation_id AND root.run_id=child.run_id " +
        "WHERE child.id=? AND child.run_id=?", [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)])
    if (rows.size != 1) { return false }
    let root = decodeOperationPlan(rows[0].required(2))
    if (root.policyVersion != "tool-policy-plan-review-v1") { return false }
    let rootId = OperationId(rows[0].required(0))
    if (!allowPlanReviewControlOperation(tx, runId, rootId, root.bindingDigest, payer)) { return false }
    let child = decodeOperationPlan(rows[0].required(1))
    if (child.bindingDigest != bindingDigest || !readViewServiceChildAllowed(root, child) ||
        child.effectClass != OperationEffectClass.ReadOnly || child.networkPolicy.mode != NetworkPolicyMode.Denied ||
        !child.approvedWriteRoots.isEmpty() || rows[0].required(3) != "executing") {
        throw IllegalStateException("compiled review child exceeds its exact trusted read-only root")
    }
    for (capability in child.requiredCapabilities where capability.kind != CapabilityKind.WorkspaceRead) {
        throw IllegalStateException("compiled review child has a forbidden capability")
    }
    if (tx.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND kind='operation_execution_handoff' LIMIT 1",
        [SqlParameter.Text(rootId.value), SqlParameter.Text(runId.value)]).isEmpty() ||
        !tx.query("SELECT id FROM operation_receipts WHERE operation_id=?", [SqlParameter.Text(rootId.value)]).isEmpty()) {
        throw IllegalStateException("compiled review child lost its exact live canonical root")
    }
    true
}
