package workflow_plugin

import agent_domain.*
import agent_sdk.PLUGIN_VIEW_PROTOCOL
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

func workflowPlanReviewView(name: String, query: AgentValue): AgentValue {
    if (name != "plan_review" || httpIntentText(query, "schema") != "axyndra.view-query/v1") {
        throw PureProviderError("workflow.view_unknown", "no matching versioned workflow View")
    }
    let context = query.field("context") ?? nullValue()
    let primary = context.field("primary") ?? nullValue()
    let available = primary.field("available") ?? nullValue()
    let ready = httpIntentText(context, "work_mode") == "plan" &&
        available.unifiedKind == UnifiedJsonKind.Boolean && available.asBool() &&
        httpIntentText(primary, "kind") == "plan" && httpIntentText(primary, "sha256").size == 64
    if (!ready) {
        return objectValue([ValueField("schema", textValue(PLUGIN_VIEW_PROTOCOL)),
            ValueField("title", textValue("Plan review")),
            ValueField("summary", textValue("Plan review requires plan mode and a current recorded plan.")),
            ValueField("status", textValue("input_required")), ValueField("interaction", textValue("optional")),
            ValueField("nodes", listValue([objectValue([ValueField("id", textValue("requirements")),
                ValueField("kind", textValue("status")), ValueField("status", textValue("input_required")),
                ValueField("text", textValue("Record a plan before reviewing it."))])])),
            ValueField("actions", listValue([]))])
    }
    let actions = listValue([
        workflowPlanViewAction("approve_fresh", "Approve with fresh context"),
        workflowPlanViewAction("approve_compact", "Approve with compacted context"),
        workflowPlanViewAction("approve_keep", "Approve keeping context"),
        workflowPlanViewAction("save", "Save reviewed plan"),
        workflowPlanViewAction("refine", "Request plan changes"),
        workflowPlanViewAction("continue", "Continue planning"),
        workflowPlanViewAction("reject", "Reject this plan")])
    objectValue([ValueField("schema", textValue(PLUGIN_VIEW_PROTOCOL)),
        ValueField("title", textValue("Plan review")),
        ValueField("summary", textValue("Review the recorded plan, edit it or provide feedback, then choose the next step. A plan decision never approves a Tool operation.")),
        ValueField("status", textValue("input_required")), ValueField("interaction", textValue("required")),
        ValueField("nodes", listValue([
            objectValue([ValueField("id", textValue("business_status")), ValueField("kind", textValue("status")),
                ValueField("status", textValue("input_required")),
                ValueField("text", textValue("Draft plan awaiting a user decision. Security approvals remain Host-owned."))]),
            objectValue([ValueField("id", textValue("plan")), ValueField("kind", textValue("input")),
                ValueField("label", textValue("Recorded plan")), ValueField("source", textValue("primary")),
                ValueField("multiline", boolValue(true))]),
            objectValue([ValueField("id", textValue("feedback")), ValueField("kind", textValue("input")),
                ValueField("label", textValue("Review feedback")), ValueField("text", textValue("")),
                ValueField("multiline", boolValue(true))])])),
        ValueField("actions", actions)])
}

private func workflowPlanViewAction(action: String, label: String): AgentValue {
    objectValue([ValueField("id", textValue(action)), ValueField("label", textValue(label)),
        ValueField("command", textValue("plan_review")),
        ValueField("input", objectValue([ValueField("action", textValue(action))]))])
}

func workflowPlanReviewCommand(raw: AgentValue): AgentValue {
    workflowFields(raw, ["command_args"])
    let input = parseUnifiedJson(workflowText(raw, "command_args"), maxBytes: 65536, maxDepth: 32)
    if (!httpIntentExactFields(input, ["schema", "view", "input", "event"]) ||
        httpIntentText(input, "schema") != "axyndra.view-command/v1") {
        throw PureProviderError("workflow.review_user_scope_required", "plan review requires an actual frontend View action")
    }
    let view = input.field("view").getOrThrow()
    let arguments = input.field("input").getOrThrow()
    let action = httpIntentText(arguments, "action")
    let hash = httpIntentText(view, "primary_hash")
    if (httpIntentText(view, "name") != "plan_review" || hash.size != 64 ||
        !httpIntentExactFields(arguments, ["action"]) ||
        !["approve_fresh", "approve_compact", "approve_keep", "save", "refine", "continue", "reject"].contains(action)) {
        throw PureProviderError("workflow.review_action_invalid", "plan review action has no matching displayed plan")
    }
    // A typed request, not a Tool proposal, approval fact, Receipt or execution.
    // Only the Host can resolve these field references against the actual user
    // event and revalidate its current canonical plan before acting.
    objectValue([ValueField("schema", textValue("axyndra.user-control-request/v1")),
        ValueField("control", objectValue([ValueField("kind", textValue("plan_review")),
            ValueField("action", textValue(action)), ValueField("content_hash", textValue(hash)),
            ValueField("plan_field", textValue("plan")), ValueField("feedback_field", textValue("feedback"))]))])
}
