package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func workflowValidRole(agent: String): Bool {
    agent == "task" || agent == "scout" || agent == "designer" || agent == "reviewer" || agent == "librarian" ||
        agent == "sonic"
}

func workflowRoleDescription(agent: String): String {
    match (agent) {
        case "scout" => "Fast codebase exploration and evidence gathering"
        case "designer" => "Architecture and implementation design"
        case "reviewer" => "Correctness and regression review"
        case "librarian" => "Documentation and source research"
        case "sonic" => "Focused low-latency execution"
        case _ => "General delegated implementation"
    }
}

func workflowRolePrompt(agent: String): String {
    "You are the " + agent + " delegated agent. " + workflowRoleDescription(agent) +
        ". Complete only the assigned task. " +
        "Once the requested evidence is available, stop exploring and immediately use the installed plugin.axyndra:workflow.yield tool for structured " +
        "output; do not continue reasoning or issue redundant tool calls. " +
        "If yield is not appropriate, end with a concise final report."
}


// Role restrictions and routing are proposals. The trusted Host intersects
// them with the actual parent's capabilities and remaining cumulative ledger.
// These values do not grant delegation, start a Run, or name an active owner.
func workflowRoleValue(role: String): AgentValue {
    if (!workflowValidRole(role)) { throw PureProviderError("workflow.role_unknown", "unknown workflow role") }
    let capabilities = ArrayList<AgentValue>([textValue("workspace.read"), textValue("peer.message")])
    if (role == "librarian") { capabilities.add(textValue("network.access")) }
    if (role == "task" || role == "sonic") {
        capabilities.add(textValue("workspace.write")); capabilities.add(textValue("process.spawn")) }
    if (role == "task") {
        capabilities.add(textValue("network.access")); capabilities.add(textValue("extension.invoke")); capabilities.add(textValue("delegate")) }
    objectValue([ValueField("name", textValue(role)), ValueField("description", textValue(workflowRoleDescription(role))),
        ValueField("prompt", textValue(workflowRolePrompt(role))), ValueField("source", textValue("axyndra-subagent-" + role)),
        ValueField("version", textValue("1")), ValueField("blocking", boolValue(role == "scout")), ValueField("capability_ceiling", listValue(capabilities.toArray())),
        ValueField("spawns", textValue(if (role == "task") { "*" } else { "" })),
        ValueField("model_alias", textValue(if (role == "task") { "@task" } else if (role == "sonic") { "@smol" } else { "" })),
        ValueField("thinking", textValue(if (role == "sonic") { "medium" } else { "" })),
        ValueField("requested_limits", objectValue([ValueField("max_output_tokens", integerValue(8000)),
            ValueField("max_model_requests", integerValue(12)), ValueField("max_turns", integerValue(12)),
            ValueField("max_tool_calls", integerValue(24)), ValueField("max_wall_millis", integerValue(300000)),
            ValueField("max_idle_millis", integerValue(90000)), ValueField("max_children", integerValue(8)),
            ValueField("max_depth", integerValue(4)), ValueField("max_concurrent_children", integerValue(4))]))])
}
func workflowRole(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "role", "shared_context"])
    let role = workflowRoleValue(workflowText(input, "role"))
    objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))), ValueField("role", role),
        // Kept outside the stable role prompt. Only the Host's existing prompt
        // builder may label and delimit this actual inherited external data.
        ValueField("shared_context", textValue(workflowText(input, "shared_context").trimAscii()))])
}
func workflowRoles(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest"])
    let roles = ArrayList<AgentValue>()
    for (name in ["designer", "librarian", "reviewer", "scout", "sonic", "task"]) { roles.add(workflowRoleValue(name)) }
    objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))), ValueField("roles", listValue(roles.toArray()))])
}
