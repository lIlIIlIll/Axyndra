package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import std.collection.*

// Public inspection keeps every existing field and its own retained owner.
// Measure complete raw cells and actual framed shapes before decoding; later
// pay actual exported graph/canonical/copy work before handing it to a caller.
func fundPlanReadSnapshot204(tx: SqliteTransaction, execution: String,
    owner: PlanExecutionReadOwner204, facts: Bool): Int64 {
    if (!facts) { return fundPlanClosedContract204(tx, execution, owner) }
    let query = "SELECT contract AS cell FROM plan_executions WHERE id=? UNION ALL " +
        "SELECT o.normalized_plan FROM plan_action_admissions a JOIN operations o ON o.id=a.operation_id WHERE a.execution_id=? UNION ALL " +
        "SELECT r.detail FROM plan_action_admissions a JOIN operation_receipts r ON r.operation_id=a.operation_id WHERE a.execution_id=? UNION ALL " +
        "SELECT r.verification FROM plan_action_admissions a JOIN operation_receipts r ON r.operation_id=a.operation_id WHERE a.execution_id=? UNION ALL " +
        "SELECT allowed_actions FROM plan_execution_members WHERE execution_id=?"
    let base = fundPlanClosedCells204(tx, query, [SqlParameter.Text(execution), SqlParameter.Text(execution),
        SqlParameter.Text(execution), SqlParameter.Text(execution), SqlParameter.Text(execution)], owner, 131072)
    let scalars = tx.query("SELECT COALESCE(SUM(length(CAST(a.action_id AS BLOB))+length(CAST(a.operation_id AS BLOB))+COALESCE(length(CAST(r.id AS BLOB)),0)),0) " +
        "FROM plan_action_admissions a LEFT JOIN operation_receipts r ON r.operation_id=a.operation_id WHERE a.execution_id=?", [SqlParameter.Text(execution)])[0]
    let members = tx.query("SELECT COALESCE(SUM(length(CAST(session_id AS BLOB))+COALESCE(length(CAST(parent_run_id AS BLOB)),0)+" +
        "COALESCE(length(CAST(parent_operation_id AS BLOB)),0)),0) FROM plan_execution_members WHERE execution_id=?", [SqlParameter.Text(execution)])[0]
    let scalarPeak = planGuardRawPeak204(checkedPlanReadSum204(Int64.parse(scalars.required(0)), Int64.parse(members.required(0))))
    let total = fundPlanProjectedGraphCopies204(tx, execution, owner, checkedPlanReadSum204(base, scalarPeak))
    total
}

func checkedPlanReadSum204(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > Int64.Max - right) {
        throw LogicalJsonPayloadError("approved plan read invoice overflow") }
    left + right
}

func newPlanReadOwner204(payer: LogicalJsonOwnerReservation): PlanExecutionReadOwner204 {
    let payment = payer.deriveRetainedLease()
    try {
        payment.ensureRetainedPeak(131072)
        PlanExecutionReadOwner204(payment)
    } catch (error: Exception) { payment.close(); throw error }
}

func planReadScopeValue204(tx: SqliteTransaction, execution: String): AgentValue {
    let contract = planLoadContract(tx, execution)
    objectValue([ValueField("execution_id", textValue(execution)),
        ValueField("target_roots", stringValues(contract.targetRoots)),
        ValueField("participating_repositories", stringValues(contract.participatingRepositories))])
}

func planReadComplete204(tx: SqliteTransaction, execution: String): Bool {
    if (planExecutionHasUnknown(tx, execution)) { return false }
    let contract = planLoadContract(tx, execution)
    let facts = planReadFacts(tx, execution)
    for (fact in facts) {
        match (fact.receipt) {
            case Some(receipt) => if (receipt.outcome == OperationOutcome.Unknown) { return false }
            case None => return false
        }
    }
    for (step in contract.steps where step.required) {
        let state = planProjectedStep(contract, facts, step.id.value, [])
        if (state != "verified" && state != "fallback_verified" && state != "dormant") { return false }
    }
    true
}

func planReadCanContinue204(tx: SqliteTransaction, execution: String, sessionId: String): Bool {
    let active = tx.query("SELECT sealed FROM plan_executions WHERE id=? AND EXISTS " +
        "(SELECT 1 FROM plan_execution_sessions s WHERE s.execution_id=plan_executions.id)", [SqlParameter.Text(execution)])
    if (active.size != 1 || active[0].required(0) != "0" || planExecutionHasUnknown(tx, execution)) { return false }
    let contract = planLoadContract(tx, execution)
    let facts = planReadFacts(tx, execution)
    let allowed = planMemberActions(tx, execution, sessionId)
    for (step in contract.steps where planProjectedStep(contract, facts, step.id.value, []) == "runnable") {
        for (action in step.actions where planContains(allowed, action.id)) {
            let state = planActionState(action, facts).state
            if (state == "runnable" || state == "retry") { return true }
        }
    }
    false
}

func planReadAllocation204(payer: LogicalJsonOwnerReservation, bytes: Int64): LogicalJsonOwnerReservation {
    let payment = payer.deriveRetainedLease()
    try { payment.ensureRetainedPeak(bytes); payment }
    catch (error: Exception) { payment.close(); throw error }
}


// Same-TX extra cells actually used by the pre-effect guard. Admitted plans
// and admitted derived roots already belong to the full facts invoice. They
// must not be charged again merely because their row is queried a second time.
// In particular, this query never selects or prices runs.lane_snapshot.
func planGuardExtraQuery204(lengths: Bool): String {
    let own = "CASE WHEN EXISTS(SELECT 1 FROM plan_action_admissions a WHERE a.execution_id=? AND a.operation_id=o.id) THEN NULL ELSE o.normalized_plan END"
    let parent = "CASE WHEN EXISTS(SELECT 1 FROM plan_action_admissions a WHERE a.execution_id=? AND a.operation_id=o.id) OR EXISTS(SELECT 1 FROM plan_action_admissions a WHERE a.execution_id=? AND a.operation_id=p.id) THEN NULL ELSE p.normalized_plan END"
    let cells = ["i.provenance", own, parent]
    let fields = ArrayList<String>()
    for (cell in cells) { fields.add(if (lengths) { "COALESCE(length(CAST((" + cell + ") AS BLOB)),0)" } else { cell }) }
    "SELECT " + fields[0] + "," + fields[1] + "," + fields[2] +
        " FROM operations o JOIN items i ON i.id=o.tool_call_item_id LEFT JOIN derived_operation_admissions d ON d.operation_id=o.id " +
        "LEFT JOIN operations p ON p.id=(" + planDerivedRootCandidateSql204("d") + ") AND p.run_id=o.run_id WHERE o.id=? AND o.run_id=?"
}
func fundPlanGuardExtra204(tx: SqliteTransaction, execution: String, operation: OperationId,
    run: RunId, payment: LogicalJsonOwnerReservation): Unit {
    let parameters = [SqlParameter.Text(execution), SqlParameter.Text(execution), SqlParameter.Text(execution),
        SqlParameter.Text(operation.value), SqlParameter.Text(run.value)]
    let sizes = tx.query(planGuardExtraQuery204(true), parameters)
    if (sizes.size != 1) { throw IllegalStateException("approved operation is missing") }
    var bytes: Int64 = 0
    for (index in 0..3) { bytes = checkedPlanReadSum204(bytes, Int64.parse(sizes[0].required(index))) }
    let raw = planGuardRawPeak204(bytes)
    payment.ensureRetainedPeak(raw)
    // The raw rows and scanner's private byte copies are already prepaid.
    // No DOM/Plan allocation occurs until the actual complete shape is funded.
    let cells = tx.query(planGuardExtraQuery204(false), parameters)
    if (cells.size != 1) { throw IllegalStateException("approved operation changed inside its transaction") }
    var decoded: Int64 = 0
    for (index in 0..3) {
        match (cells[0][index]) {
            case None => if (sizes[0].required(index) != "0") { throw IllegalStateException("approved cell extent changed") }
            case Some(value) =>
                let buffer = value.toArray()
                if (buffer.size != Int64.parse(sizes[0].required(index))) { throw IllegalStateException("approved cell extent changed") }
                decoded = checkedPlanReadSum204(decoded, preparedFramedValueCopyPeak204(buffer))
        }
    }
    payment.ensureRetainedPeak(checkedPlanReadSum204(raw, decoded))
}
func planGuardRawPeak204(bytes: Int64): Int64 {
    if (bytes < 0 || bytes > (1073741824 - 131072) / 4) {
        throw LogicalJsonPayloadError("approved raw read exceeds the original bank extent") }
    131072 + bytes * 4
}

// Only the real trusted Review branch may read the complete frozen Lane.
// Its original source and all original codec/identity predicates are retained.
// The fixed byte invoice covers raw copies; actual framed nodes determine the
// DOM/ModelLane peak before either decoder runs, without changing shape bounds.
func planReviewFrozenIdentity204(tx: SqliteTransaction, run: RunId,
    plan: NormalizedOperationPlan, payer: LogicalJsonOwnerReservation): Bool {
    let sizes = tx.query("SELECT length(CAST(lane_snapshot AS BLOB)) FROM runs WHERE id=?", [SqlParameter.Text(run.value)])
    if (sizes.size != 1) { throw IllegalStateException("plan review Run has no frozen catalog") }
    let bytes = Int64.parse(sizes[0].required(0))
    let raw = planGuardRawPeak204(bytes)
    let payment = planReadAllocation204(payer, raw)
    try { planReviewFrozenIdentityFrame204(tx, run, plan, payment, bytes, raw) }
    finally { payment.close() }
}
func planReviewFrozenIdentityFrame204(tx: SqliteTransaction, run: RunId,
    plan: NormalizedOperationPlan, payment: LogicalJsonOwnerReservation, bytes: Int64, raw: Int64): Bool {
    let lanes = tx.query("SELECT lane_snapshot FROM runs WHERE id=?", [SqlParameter.Text(run.value)])
    if (lanes.size != 1) { throw IllegalStateException("plan review Run has no frozen catalog") }
    let buffer = lanes[0].required(0).toArray()
    if (buffer.size != bytes) { throw IllegalStateException("plan review frozen catalog extent changed") }
    payment.ensureRetainedPeak(checkedPlanReadSum204(raw, preparedFramedValueCopyPeak204(buffer)))
    let lane = modelLaneFromSnapshotValue(decodeStoredValue(lanes[0].required(0)))
    var trusted = false
    for (entry in lane.toolSet.entries where entry.name == plan.toolName) {
        trusted = entry.planReviewSafe && entry.availableAtSnapshot && entry.hasCompleteIdentity() &&
            entry.executorVersion == plan.implementation.toolVersion &&
            entry.implementationFingerprint == plan.implementation.implementationFingerprint &&
            entry.schemaDigest == plan.implementation.schemaDigest
    }
    trusted
}


// Closed control/scalar reads do not produce public contract projections or
// rendered model text. These invoices cover their actual complete decoder
// cells, copied values and row metadata, paid from the same original owner.
func fundPlanClosedCells204(tx: SqliteTransaction, query: String, parameters: Array<SqlParameter>,
    owner: PlanExecutionReadOwner204, base: Int64): Int64 {
    let sizes = tx.query("SELECT COALESCE(SUM(length(CAST(cell AS BLOB))),0),COUNT(*) FROM (" + query + ")", parameters)
    if (sizes.size != 1) { throw IllegalStateException("closed plan read extent is missing") }
    let bytes = Int64.parse(sizes[0].required(0)); let count = Int64.parse(sizes[0].required(1))
    if (count == 0) { return base }
    if (count < 0 || count > (Int64.Max - 131072) / 32768) {
        throw LogicalJsonPayloadError("closed plan row invoice overflow") }
    let raw = checkedPlanReadSum204(planGuardRawPeak204(bytes), count * 32768)
    owner.ensureProducerPeak204(checkedPlanReadSum204(base, raw))
    let cells = tx.query(query, parameters)
    if (cells.size != count) { throw IllegalStateException("closed plan cells changed inside their transaction") }
    var decoded: Int64 = 0; var actualBytes: Int64 = 0
    for (row in cells) {
        let buffer = row.required(0).toArray()
        actualBytes = checkedPlanReadSum204(actualBytes, buffer.size)
        decoded = checkedPlanReadSum204(decoded, preparedFramedValueCopyPeak204(buffer))
    }
    if (actualBytes != bytes) { throw IllegalStateException("closed plan cell extent changed") }
    let total = checkedPlanReadSum204(checkedPlanReadSum204(base, raw), decoded)
    owner.ensureProducerPeak204(total)
    total
}
func fundPlanClosedContract204(tx: SqliteTransaction, execution: String,
    owner: PlanExecutionReadOwner204): Int64 {
    fundPlanClosedCells204(tx, "SELECT contract AS cell FROM plan_executions WHERE id=?",
        [SqlParameter.Text(execution)], owner, 131072)
}
func fundPlanClosedFacts204(tx: SqliteTransaction, execution: String, run: RunId,
    owner: PlanExecutionReadOwner204): Int64 {
    fundPlanGuardSnapshot204(tx, execution, run, None<OperationId>,
        { bytes => owner.ensureProducerPeak204(bytes) })
}
func fundPlanClosedObservation204(tx: SqliteTransaction, execution: String, run: RunId,
    operation: OperationId, owner: PlanExecutionReadOwner204): Unit {
    let base = fundPlanClosedFacts204(tx, execution, run, owner)
    // The selected receipt detail is decoded while the complete facts remain
    // live, and an existing immutable decision has its own decoder copy.
    let query = "SELECT r.detail AS cell FROM operations o JOIN operation_receipts r ON r.operation_id=o.id WHERE o.id=? AND o.run_id=? UNION ALL " +
        "SELECT d.decision FROM operations o JOIN operation_receipts r ON r.operation_id=o.id JOIN plan_step_decisions d ON d.receipt_id=r.id WHERE o.id=? AND o.run_id=?"
    let total = fundPlanClosedCells204(tx, query, [SqlParameter.Text(operation.value), SqlParameter.Text(run.value),
        SqlParameter.Text(operation.value), SqlParameter.Text(run.value)], owner, base)
    // Small returned decision object, encoding, static reason and receipt-ID
    // references remain owned until the caller's concrete consumer returns.
    owner.ensureProducerPeak204(checkedPlanReadSum204(total, 131072))
}
func fundPlanClosedInheritance204(tx: SqliteTransaction, execution: String, parentRun: RunId,
    parentOperation: OperationId, childSession: String, owner: PlanExecutionReadOwner204): Unit {
    let base = fundPlanClosedContract204(tx, execution, owner)
    let query = "SELECT o.normalized_plan AS cell FROM operations o WHERE o.id=? AND o.run_id=? UNION ALL " +
        "SELECT m.allowed_actions FROM plan_execution_members m JOIN plan_execution_runs b ON b.session_id=m.session_id AND b.execution_id=m.execution_id WHERE m.execution_id=? AND b.run_id=? UNION ALL " +
        "SELECT allowed_actions FROM plan_execution_members WHERE execution_id=? AND session_id=?"
    let total = fundPlanClosedCells204(tx, query, [SqlParameter.Text(parentOperation.value), SqlParameter.Text(parentRun.value),
        SqlParameter.Text(execution), SqlParameter.Text(parentRun.value), SqlParameter.Text(execution), SqlParameter.Text(childSession)], owner, base)
    let metadata = tx.query("SELECT COALESCE(SUM(length(CAST(session_id AS BLOB))+COALESCE(length(CAST(parent_run_id AS BLOB)),0)+" +
        "COALESCE(length(CAST(parent_operation_id AS BLOB)),0)),0),COUNT(*) FROM plan_execution_members WHERE execution_id=?", [SqlParameter.Text(execution)])[0]
    let bytes = Int64.parse(metadata.required(0)); let rows = Int64.parse(metadata.required(1))
    if (rows < 0 || rows > (Int64.Max - 131072) / 32768) { throw LogicalJsonPayloadError("delegation row invoice overflow") }
    owner.ensureProducerPeak204(checkedPlanReadSum204(total,
        checkedPlanReadSum204(planGuardRawPeak204(bytes), rows * 32768)))
}


// Dispatch directly folds the already-paid typed contract/facts/member state.
// Its actual progress/action wrappers are prepaid before graph production;
// request digest temporaries and the independent consumer remain paid too.
func fundPlanDispatchGraph204(tx: SqliteTransaction, execution: String, run: RunId,
    owner: PlanExecutionReadOwner204): Int64 {
    let base = fundPlanClosedFacts204(tx, execution, run, owner)
    // No second contract decode, full private inspection or full-state
    // serialization is produced by dispatch. The preflight helper returns
    // completely before the one shared fold starts.
    fundPlanProjectionNodes204(tx, execution, owner, base)
}
func fundPlanProjectedGraphCopies204(tx: SqliteTransaction, execution: String,
    owner: PlanExecutionReadOwner204, base: Int64): Int64 {
    let copies = fundPlanClosedCells204(tx,
        "SELECT contract AS cell FROM plan_executions WHERE id=? UNION ALL SELECT contract FROM plan_executions WHERE id=?",
        [SqlParameter.Text(execution), SqlParameter.Text(execution)], owner, base)
    fundPlanProjectionNodes204(tx, execution, owner, copies)
}
func fundPlanProjectionNodes204(tx: SqliteTransaction, execution: String,
    owner: PlanExecutionReadOwner204, base: Int64): Int64 {
    // The one already-paid contract decoder measures fixed-size wrapper/node
    // counts. This complete preflight frame returns before graph production.
    let contract = planLoadContract(tx, execution)
    var actions: Int64 = 0
    for (step in contract.steps) { actions = checkedPlanReadSum204(actions, step.actions.size) }
    let receipts = tx.query("SELECT COUNT(*) FROM plan_action_admissions a JOIN operation_receipts r ON r.operation_id=a.operation_id WHERE a.execution_id=?",
        [SqlParameter.Text(execution)])[0]
    let receiptCount = Int64.parse(receipts.required(0))
    if (actions > (Int64.Max - 262144) / 65536 || contract.steps.size > (Int64.Max - 262144) / 32768 ||
        receiptCount < 0 || receiptCount > (Int64.Max - 262144) / 16384) {
        throw LogicalJsonPayloadError("dispatch graph node invoice overflow") }
    let nodes = checkedPlanReadSum204(262144, checkedPlanReadSum204(actions * 65536,
        checkedPlanReadSum204(contract.steps.size * 32768, receiptCount * 16384)))
    let total = checkedPlanReadSum204(base, nodes)
    owner.ensureProducerPeak204(total)
    total
}


// The unchanged full member-contract digest is computed in a bounded private
// temporary frame, not in a public contract_view graph. The temporary header
// graph is prepaid by the projection node invoice; its canonical/hash working
// copies are funded BEFORE hashing. Only its fixed digest escapes this helper.
func planRequestContractDigestFrame204(contract: PlanContract, owner: PlanExecutionReadOwner204,
    peak: Int64): String {
    let value = planContractValue(contract)
    let _ = owner.fundProducerGraphWork204(value, peak)
    modelPolicySha256Text(canonicalAgentValue(value))
}
func planRequestActionFrame204(stepId: String, action: PlanAction,
    owner: PlanExecutionReadOwner204, peak: Int64): AgentValue {
    let value = planActionValue(action)
    let _ = owner.fundProducerGraphWork204(value, peak)
    approvedPlanRunnableActionValue204(stepId, value)
}
