package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import yjson.*
import yjson_support.*

// One actual original test bank across the whole concrete contract frame.
// Large producer DOMs return after each closed assertion helper. The few copied
// scalar decision records remain paid until the full test frame has returned.
private var planTestReadFrame204: ?PlanTestReadFrame204 = None<PlanTestReadFrame204>

class PlanTestReadFrame204 {
    let bank = LogicalJsonOwnerBudget()
    let original: LogicalJsonOwnerReservation
    private let copies = ArrayList<LogicalJsonOwnerReservation>()
    private let decisions = ArrayList<PlanStepDecision>()
    init() { original = bank.acquire(131072) }
    func allocate(bytes: Int64): LogicalJsonOwnerReservation {
        let child = original.deriveRetainedLease()
        try { child.ensureRetainedPeak(bytes); child }
        catch (error: Exception) { child.close(); throw error }
    }
    func copyDecision(owner: PlanExecutionReadOwner204, loan: PlanExecutionReadConsumer204): PlanStepDecision {
        original.ensureRetainedPeak(131072 + (copies.size + 1) * 4096)
        let copy = owner.deriveRetainedAllocation204(131072)
        copies.add(copy)
        let value = copyPlanTestDecisionFrame204(loan, copy)
        decisions.add(value); value
    }
    func closeAfterContractFrame(): Unit {
        decisions.clear()
        for (copy in copies) { copy.close() }
        copies.clear(); original.close()
        expect(bank.usage()[0] == 0 && bank.usage()[1] == 0, "complete concrete plan contract frame returns every original-bank allocation")
    }
}

func beginPlanTestReadFrame204(): Unit {
    expect(planTestReadFrame204.isNone(), "plan test frames are not reentrant")
    planTestReadFrame204 = Some(PlanTestReadFrame204())
}
func finishPlanTestReadFrame204(): Unit {
    let frame = planTestReadFrame204.getOrThrow()
    planTestReadFrame204 = None<PlanTestReadFrame204>
    frame.closeAfterContractFrame()
}
func planTestOriginal204(): LogicalJsonOwnerReservation { planTestReadFrame204.getOrThrow().original }
func planTestAllocate204(bytes: Int64): LogicalJsonOwnerReservation { planTestReadFrame204.getOrThrow().allocate(bytes) }
func paidPlanTestStore204(database: SqliteDatabase): DurablePlanExecutionStore {
    DurablePlanExecutionStore(database, knownParentAllocation: Some({ bytes => planTestAllocate204(bytes) }))
}
func paidPlanOperationStore204(database: SqliteDatabase): DurableOperationStore {
    DurableOperationStore(database, documentPayloadAllocation: Some({ bytes => planTestAllocate204(bytes) }))
}
func paidPlanSink204(database: SqliteDatabase): SqliteThreadCommitSink {
    SqliteThreadCommitSink(database, knownParentAllocation: Some({ bytes => planTestAllocate204(bytes) }))
}
func planTestObserve204(plans: DurablePlanExecutionStore, run: RunId, operation: OperationId): PlanStepDecision {
    let owner = plans.observe204(run, operation, planTestOriginal204()).value().getOrThrow()
    let loan = owner.beginConsumer204()
    let result = planTestReadFrame204.getOrThrow().copyDecision(owner, loan)
    // copyDecision's entire graph/codec consumer has returned. Only its
    // independently prepaid small decision survives in the test frame owner.
    loan.returnConsumerFrame204(); owner.closeAfterCaller204(); result
}
func copyPlanTestDecisionFrame204(loan: PlanExecutionReadConsumer204,
    payment: LogicalJsonOwnerReservation): PlanStepDecision {
    let value = loan.value204()
    let meter = ToolSnapshotMeasure159(payment); meter.addValue159(value); meter.fund159()
    let fallback = value.field("fallback_step_id").getOrThrow()
    PlanStepDecision(planTestTextCopy204(value.field("step_id").getOrThrow().text),
        planTestTextCopy204(value.field("decision").getOrThrow().text),
        planTestTextCopy204(value.field("reason").getOrThrow().text),
        receiptId: planTestTextCopy204(value.field("receipt_id").getOrThrow().text),
        fallbackStepId: if (fallback.unifiedKind == ValueKind.Null) { None<String> }
            else { Some(planTestTextCopy204(fallback.text)) })
}
func planTestTextCopy204(value: String): String { String.fromUtf8(value.toArray()) }
func planTestHasScope204(plans: DurablePlanExecutionStore, session: String): Bool {
    match (plans.openSessionScope204(session, planTestOriginal204()).value().getOrThrow()) {
        case None => false
        case Some(owner) => owner.closeAfterCaller204(); true
    }
}
func planTestInspectBool204(plans: DurablePlanExecutionStore, run: RunId, field: String): Bool {
    let owner = plans.openInspection204(run, planTestOriginal204()).value().getOrThrow()
    let loan = owner.beginConsumer204()
    let result = planTestInspectBoolFrame204(loan, field)
    loan.returnConsumerFrame204(); owner.closeAfterCaller204(); result
}
func planTestInspectBoolFrame204(loan: PlanExecutionReadConsumer204, field: String): Bool {
    let value = loan.value204()
    if (field == "stopped_tools") {
        value.field("recovery_required").getOrThrow().asBool() && value.field("allowed_tools").getOrThrow().items.isEmpty()
    } else if (field == "exhausted") {
        value.field("steps").getOrThrow().items[0].field("actions").getOrThrow().items[0]
            .field("remaining_attempts").getOrThrow().asNumberText() == "0"
    } else { value.field(field).getOrThrow().asBool() }
}
func planTestSessionComplete204(plans: DurablePlanExecutionStore, session: String): Bool {
    let owner = plans.openSessionInspection204(session, planTestOriginal204()).value().getOrThrow()
    let loan = owner.beginConsumer204()
    let result = planTestInspectBoolFrame204(loan, "complete")
    loan.returnConsumerFrame204(); owner.closeAfterCaller204(); result
}
func planTestChildProjection204(plans: DurablePlanExecutionStore, run: RunId): Unit {
    let owner = plans.openInspection204(run, planTestOriginal204()).value().getOrThrow()
    let loan = owner.beginConsumer204()
    planTestChildProjectionFrame204(loan)
    loan.returnConsumerFrame204(); owner.closeAfterCaller204()
}
func planTestChildProjectionFrame204(loan: PlanExecutionReadConsumer204): Unit {
    let value = loan.value204()
    expect(parsePlanContractProjection(value.field("contract_view").getOrThrow()).isOk(),
        "member-filtered contract views remain readable for pure Native action matching")
    for (id in value.field("runnable_action_ids").getOrThrow().items) {
        expect(id.text != "verify-source" && id.text != "write-cdn",
            "immutable delegated allowance does not advertise blocked dependent or dormant fallback actions as runnable")
    }
}
func planTestSnapshotPresent204(plans: DurablePlanExecutionStore, tx: SqliteTransaction, run: RunId): Bool {
    match (plans.inspectSnapshot204(tx, run, planTestOriginal204()).value().getOrThrow()) {
        case None => false
        case Some(owner) => owner.closeAfterCaller204(); true
    }
}
