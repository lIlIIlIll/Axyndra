package agent_product

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Advisory checks are intentionally separate from contract structural
// validation and from executed verification evidence. Matching a known risky
// expression never proves that a general natural-language plan is correct.
public class PlanReviewAdvisory {
    public let code: String
    public let message: String
    public let evidenceRequirement: String

    public init(code: String, message: String, evidenceRequirement: String) {
        this.code = code
        this.message = message
        this.evidenceRequirement = evidenceRequirement
    }
}

public func reviewProductPlanAdvisories(plan: String): Array<PlanReviewAdvisory> {
    let compact = plan.replace(" ", "").replace("\n", "").replace("\t", "").replace("\r", "")
    productPlanReviewCompactAdvisories204(compact)
}
private func productPlanReviewCompactAdvisories204(compact: String): Array<PlanReviewAdvisory> {
    let result = ArrayList<PlanReviewAdvisory>()
    if (compact.contains("Math.sign(layer)*4)%4") ||
        compact.contains("(sign*4)%4")) {
        result.add(PlanReviewAdvisory(
            "plan.review.zero_quarter_turns",
            "A signed quarter-turn multiplied by four and reduced modulo four becomes zero.",
            "Execute a move-contract test proving each face changes state and four turns restore it."
        ))
    }
    if (compact.contains("rotVec(") && compact.contains("quarterTurns") &&
        (compact.contains(",axis,angle)") || compact.contains(",axis,radians)"))) {
        result.add(PlanReviewAdvisory(
            "plan.review.rotation_units",
            "The plan appears to pass a continuous animation angle to a discrete quarter-turn helper.",
            "Verify separate integer state rotation and floating-point render interpolation."
        ))
    }
    if (compact.contains("queue.clear()") && compact.contains("state.reset()") &&
        (compact.contains("animateMove") || compact.contains("state.applyMove(move)"))) {
        result.add(PlanReviewAdvisory(
            "plan.review.animation_lifecycle",
            "Clearing pending moves may leave an active animation able to commit after reset.",
            "Execute deterministic reset, scramble, and undo interleavings using cancellation or a generation guard."
        ))
    }
    result.toArray()
}

public func productPlanReviewAdvisoriesValue(plan: String): AgentValue {
    productPlanReviewAdvisoryValues204(reviewProductPlanAdvisories(plan))
}
// Only the internal paid hash path uses this bounded compaction. Removing
// these same four ASCII bytes preserves every other UTF-8 byte and all of the
// public advisory predicates; it avoids String.replace's input-sized Int64
// match-position table, including on a body with no matching whitespace.
func productPlanReviewBoundedAdvisoriesValue204(plan: String): AgentValue {
    let bytes = Array<Byte>(plan.size, repeat: 0)
    var size: Int64 = 0
    for (index in 0..plan.size) {
        let byte = plan[index]
        if (byte != 32u8 && byte != 10u8 && byte != 9u8 && byte != 13u8) {
            bytes[size] = byte; size++
        }
    }
    let compact = String.fromUtf8(bytes[..size])
    productPlanReviewAdvisoryValues204(productPlanReviewCompactAdvisories204(compact))
}
private func productPlanReviewAdvisoryValues204(advisories: Array<PlanReviewAdvisory>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (advisory in advisories) {
        values.add(objectValue([
            ValueField("kind", textValue("advisory")),
            ValueField("code", textValue(advisory.code)),
            ValueField("message", textValue(advisory.message)),
            ValueField("required_verification", textValue(advisory.evidenceRequirement)),
            ValueField("executed", boolValue(false))
        ]))
    }
    listValue(values.toArray())
}

// The caller supplies a projection from canonical plan/Operation storage.
// Rendering cannot mutate steps, reserve budgets, or assert completion.
public func renderPlanExecutionInspection(value: AgentValue): String {
    if (value.unifiedKind != ValueKind.Object) { return "Plan execution: unavailable" }
    var output = "Plan execution (canonical projection):"
    for (name in ["execution_id", "plan_hash", "status", "active", "complete", "sealed", "recovery_required", "current_step", "remaining_attempts",
        "fallback_reason", "blocked_reason"]) {
        match (value.field(name)) {
            case Some(item) => if (item.unifiedKind == ValueKind.Text) {
                output += "\n  " + name + "=" + item.text
            } else if (item.unifiedKind == ValueKind.Number) {
                output += "\n  " + name + "=" + item.asNumberText()
            } else if (item.unifiedKind == ValueKind.Boolean) {
                output += "\n  " + name + "=" + item.asBool().toString()
            }
            case None => ()
        }
    }
    match (value.field("steps")) {
        case Some(steps) => if (steps.unifiedKind == ValueKind.List) {
            for (step in steps.items) {
                output += "\n  step"
                for (name in ["step_id", "status", "state", "attempts_used", "attempt_limit", "decision", "reason"]) {
                    match (step.field(name)) {
                        case Some(item) => if (item.unifiedKind == ValueKind.Text) {
                            output += " " + name + "=" + item.text
                        } else if (item.unifiedKind == ValueKind.Number) {
                            output += " " + name + "=" + item.asNumberText()
                        }
                        case None => ()
                    }
                }
                output += planInspectionReceiptSummary(step)
                match (step.field("actions")) {
                    case Some(actions) => if (actions.unifiedKind == ValueKind.List) {
                        for (action in actions.items) {
                            output += "\n    action"
                            for (name in ["action_id", "state", "attempts", "remaining_attempts", "reason"]) {
                                match (action.field(name)) {
                                    case Some(item) => if (item.unifiedKind == ValueKind.Text) {
                                        output += " " + name + "=" + item.text
                                    } else if (item.unifiedKind == ValueKind.Number) {
                                        output += " " + name + "=" + item.asNumberText()
                                    }
                                    case None => ()
                                }
                            }
                            output += planInspectionReceiptSummary(action)
                        }
                    }
                    case None => ()
                }
            }
        }
        case None => ()
    }
    output
}

func planInspectionReceiptSummary(value: AgentValue): String {
    var output = ""
    match (value.field("receipt_ids")) {
        case Some(items) => if (items.unifiedKind == ValueKind.List && !items.items.isEmpty()) {
            output = " receipts="
            var first = true
            for (item in items.items where item.unifiedKind == ValueKind.Text) {
                if (!first) { output += "," }
                first = false
                output += item.text
            }
        }
        case None => ()
    }
    output
}
