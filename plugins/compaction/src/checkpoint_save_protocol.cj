package compaction_plugin

import agent_domain.*
import yjson.*
import yjson_support.*

// Native owns the original report/goal/summary recipe. These are policy DATA;
// an ordinal, a successful check, or an echoed value is never a Source or cut.
func checkpointSavePolicyPhase113(value: AgentValue): AgentValue {
    match (policyText(value, "phase")) {
        case "checkpoint_save_layout" =>
            policyFields(value, ["schema", "phase", "snapshot_digest"])
            objectValue([ValueField("report", textValue("report")), ValueField("goal", textValue("goal"))])
        case "checkpoint_save_validate" => checkpointSavePolicyValidate113(value)
        case "checkpoint_save_check" => checkpointSavePolicyCheck113(value)
        case "checkpoint_save_recipe" => checkpointSavePolicyRecipe113(value)
        case _ => compactionFragmentError()
    }
}

func checkpointSavePolicyValidate113(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "source", "range"])
    checkpointPolicyRange(value.field("range").getOrThrow(), value.field("source").getOrThrow())
    if (structuredInteger(value.field("range").getOrThrow(), "bytes") == 0) {
        return checkpointPolicyError("internal", "tool.rewind_report_missing",
            "persisted rewind result does not contain a report") }
    objectValue([ValueField("valid", boolValue(true))])
}

func checkpointSavePolicyCheck113(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state"])
    let state = value.field("state").getOrThrow(); checkpointPolicyState(state, true)
    if (structuredInteger(state, "offset") != structuredInteger(state, "total")) { compactionFragmentError() }
    if (structuredInteger(state, "checkpoint") < 1) {
        return checkpointPolicyError("conflict", "tool.checkpoint_missing",
            "No active checkpoint. Create a checkpoint before calling rewind.") }
    if (structuredInteger(state, "rewind") < 1) {
        return checkpointPolicyError("recovery_required", "tool.rewind_result_not_canonical",
            "rewind checkpoint cannot be saved before its canonical ToolResult") }
    // The current canonical rewind result makes completed=true. It must not
    // be confused with the pre-execution repeated-rewind rejection rule.
    objectValue([ValueField("valid", boolValue(true))])
}

func checkpointSavePolicyRecipe113(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state", "report", "report_range",
        "goal", "goal_range", "structured", "provenance", "call_id"])
    let state = value.field("state").getOrThrow()
    let check = checkpointSavePolicyCheck113(objectValue([ValueField("schema", value.field("schema").getOrThrow()),
        ValueField("phase", textValue("checkpoint_save_check")), ValueField("snapshot_digest", value.field("snapshot_digest").getOrThrow()),
        ValueField("state", state)]))
    if (check.field("error").isSome()) { return check }
    let report = value.field("report").getOrThrow(); let range = value.field("report_range").getOrThrow()
    checkpointPolicyRange(range, report)
    if (structuredInteger(range, "bytes") == 0) { compactionFragmentError() }
    let goal = value.field("goal").getOrThrow(); let goalRange = value.field("goal_range").getOrThrow()
    checkpointPolicyRange(goalRange, goal)
    let structured = value.field("structured").getOrThrow(); let _ = compactionReferenceBytes(structured)
    let call = value.field("call_id").getOrThrow(); let _ = compactionReferenceBytes(call)
    objectValue([ValueField("through", state.field("rewind").getOrThrow()),
        ValueField("prefix_through", state.field("checkpoint").getOrThrow()),
        ValueField("active_goal", listValue([goalRange])),
        ValueField("projection", objectValue([ValueField("fields", listValue([
            checkpointPolicyTextField("deterministic_summary", [compactionSource(structured),
                compactionLiteral("\n\nCheckpoint investigation report:\n"), range]),
            objectValue([ValueField("name", textValue("structured_policy")), ValueField("kind", textValue("data")),
                ValueField("value", value.field("provenance").getOrThrow())]),
            checkpointPolicyTextField("checkpoint_goal", [goalRange]),
            checkpointPolicyTextField("rewind_call_id", [compactionSource(call)])
        ]))]))])
}
