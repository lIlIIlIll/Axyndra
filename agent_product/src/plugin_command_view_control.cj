package agent_product

import agent_domain.*
import yjson.*
import yjson_support.*

enum ProductPluginCommandRequest {
    ToolProposal(ProductCommandProposal)
    | UserControl(ProductPluginViewControl)
}

// Data requested by one actual Command scope. This is not a ToolCall,
// Prepared invocation, approval, continuation grant or canonical operation.
// Application must match it to its own current displayed View and user event.
class ProductPluginViewControl {
    let binding: ProductCommandBinding
    let action: String
    let contentHash: String
    let planField: String
    let feedbackField: String
    let sourceDigest: String
    init(binding: ProductCommandBinding, action: String, contentHash: String,
        planField: String, feedbackField: String, sourceDigest: String) {
        this.binding = binding; this.action = action; this.contentHash = contentHash
        this.planField = planField; this.feedbackField = feedbackField; this.sourceDigest = sourceDigest
    }
}

func productCommandRequestDigest(value: AgentValue, binding: ProductCommandBinding,
    sessionId: SessionId, commandId: String, argumentsDigest: String): String {
    modelPolicySha256Text(canonicalAgentValue(objectValue([
        ValueField("thread_id", textValue(sessionId.value)),
        ValueField("namespace", textValue(binding.namespace)), ValueField("contribution", textValue(binding.contribution)),
        ValueField("generation", textValue(binding.generation.toString())), ValueField("package_digest", textValue(binding.digest)),
        ValueField("command_id", textValue(commandId)), ValueField("arguments_digest", textValue(argumentsDigest)),
        ValueField("proposal", value)])))
}

func parseProductPluginCommandRequest(value: AgentValue, binding: ProductCommandBinding,
    sessionId: SessionId, commandId: String, argumentsDigest: String): Result<ProductPluginCommandRequest> {
    if (httpIntentText(value, "schema") != "axyndra.user-control-request/v1") {
        return match (parseProductCommandProposal(value, binding, sessionId, commandId, argumentsDigest)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(proposal) => Result.Ok(ProductPluginCommandRequest.ToolProposal(proposal))
        }
    }
    if (!httpIntentExactFields(value, ["schema", "control"])) {
        return commandControlError("plugin.command_control_invalid") }
    let control = value.field("control").getOrThrow()
    if (!httpIntentExactFields(control, ["kind", "action", "content_hash", "plan_field", "feedback_field"]) ||
        httpIntentText(control, "kind") != "plan_review") {
        return commandControlError("plugin.command_control_invalid") }
    if (!binding.allowsControl("plan_review")) { return commandControlError("plugin.command_control_not_declared") }
    let action = httpIntentText(control, "action")
    let hash = httpIntentText(control, "content_hash")
    let plan = httpIntentText(control, "plan_field")
    let feedback = httpIntentText(control, "feedback_field")
    if (!["approve_fresh", "approve_compact", "approve_keep", "save", "refine", "continue", "reject"].contains(action) ||
        hash.size != 64 || !httpIntentIdentifier(plan) || !httpIntentIdentifier(feedback) || plan == feedback) {
        return commandControlError("plugin.command_control_invalid") }
    for (index in 0..hash.size) {
        let byte = hash[index]
        if (!((byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102))) {
            return commandControlError("plugin.command_control_invalid") }
    }
    Result.Ok(ProductPluginCommandRequest.UserControl(ProductPluginViewControl(binding, action, hash, plan, feedback,
        productCommandRequestDigest(value, binding, sessionId, commandId, argumentsDigest))))
}
