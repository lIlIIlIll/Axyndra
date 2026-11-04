package agent_history

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Independent DATA copy. A page may take this payment; a closed callback
// consumer returns it only after its entire borrowed helper has returned.
public class CopiedPlanInspection204 {
    private var data: ?AgentValue
    private var payment: ?LogicalJsonOwnerReservation
    init(data: AgentValue, payment: LogicalJsonOwnerReservation) { this.data = Some(data); this.payment = Some(payment) }
    public func takeForPage204(): (AgentValue, LogicalJsonOwnerReservation) {
        let value = (data.getOrThrow(), payment.getOrThrow())
        data = None<AgentValue>; payment = None<LogicalJsonOwnerReservation>
        value
    }
    public func withView204(consume: (AgentValue) -> Result<Unit>): Result<Unit> { consume(data.getOrThrow()) }
    public func closeAfterConsumer204(): Unit {
        data = None<AgentValue>
        let returned = payment; payment = None<LogicalJsonOwnerReservation>
        match (returned) { case Some(value) => value.close(); case None => () }
    }
}

public func copyRedactedPlanInspection204(owner: PlanExecutionReadOwner204): Result<CopiedPlanInspection204> {
    let consumer = owner.beginConsumer204()
    try {
        let copied = copyRedactedPlanInspectionFrame204(owner, consumer)
        consumer.returnConsumerFrame204()
        owner.closeAfterCaller204()
        Result.Ok(copied)
    } catch (_: LogicalJsonPayloadError) {
        owner.holdUnknownConsumer204()
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plan.inspection_copy_capacity",
            "Plan inspection cannot fit the original caller data budget"))
    } catch (_: Exception) {
        owner.holdUnknownConsumer204()
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plan.inspection_copy_failed",
            "The paid canonical plan projection could not be copied"))
    }
}

private func copyRedactedPlanInspectionFrame204(owner: PlanExecutionReadOwner204,
    consumer: PlanExecutionReadConsumer204): CopiedPlanInspection204 {
    let source = consumer.value204()
    let payment = owner.deriveRetainedAllocation204(planInspectionCopyInvoice204(source))
    CopiedPlanInspection204(redactProductPlanInspection(source), payment)
}

func inspectionPlanScalarCopy204(value: AgentValue): AgentValue {
    match (value.unifiedKind) {
        case ValueKind.Text => textValue(String.fromUtf8(value.text.toArray()))
        case ValueKind.Number => integerValue(Int64.parse(value.asNumberText()))
        case ValueKind.Boolean => boolValue(value.asBool())
        case _ => nullValue()
    }
}

private func planInspectionCopyAdd204(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > 1073741824 - right) {
        throw LogicalJsonPayloadError("plan inspection copied data extent exceeds its bound") }
    left + right
}
private func planInspectionScalarInvoice204(source: AgentValue, names: Array<String>): Int64 {
    var invoice: Int64 = 4096
    for (name in names) {
        match (source.field(name)) {
            case Some(value) =>
                if (value.unifiedKind == ValueKind.Text) {
                    if (value.text.size > 1073741824 / 256) { throw LogicalJsonPayloadError("plan inspection text extent exceeds its bound") }
                    invoice = planInspectionCopyAdd204(invoice, value.text.size * 256 + 4096)
                } else if (value.unifiedKind == ValueKind.Number || value.unifiedKind == ValueKind.Boolean) {
                    invoice = planInspectionCopyAdd204(invoice, 4096)
                }
            case None => ()
        }
    }
    match (source.field("receipt_ids")) {
        case Some(values) => if (values.unifiedKind == ValueKind.List) {
            var count: Int64 = 0
            for (value in values.items where count < 256 && value.unifiedKind == ValueKind.Text) {
                if (value.text.size > 1073741824 / 256) { throw LogicalJsonPayloadError("plan receipt reference extent exceeds its bound") }
                invoice = planInspectionCopyAdd204(invoice, value.text.size * 256 + 4096); count++
            }
        }
        case None => ()
    }
    invoice
}
private func planInspectionCopyInvoice204(source: AgentValue): Int64 {
    var invoice = planInspectionScalarInvoice204(source, ["execution_id", "active", "complete", "sealed", "recovery_required"])
    match (source.field("steps")) {
        case Some(steps) => if (steps.unifiedKind == ValueKind.List) {
            var count: Int64 = 0
            for (step in steps.items where count < 128) {
                invoice = planInspectionCopyAdd204(invoice, planInspectionScalarInvoice204(step,
                    ["step_id", "state", "required", "decision", "reason", "receipt_id", "fallback_step_id"]))
                match (step.field("actions")) {
                    case Some(actions) => if (actions.unifiedKind == ValueKind.List) {
                        var actionCount: Int64 = 0
                        for (action in actions.items where actionCount < 256) {
                            invoice = planInspectionCopyAdd204(invoice, planInspectionScalarInvoice204(action,
                                ["action_id", "state", "attempts", "remaining_attempts", "decision", "reason", "receipt_id"]))
                            actionCount++
                        }
                    }
                    case None => ()
                }
                count++
            }
        }
        case None => ()
    }
    planInspectionCopyAdd204(invoice, 16384)
}
