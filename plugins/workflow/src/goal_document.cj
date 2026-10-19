package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func workflowGoalDocumentProposal(input: AgentValue): AgentValue {
    let snapshot = workflowDocumentSnapshot(input, "goal")
    let raw = httpIntentText(snapshot, "json")
    if (raw == "" || modelPolicySha256Text(raw) != httpIntentText(snapshot, "sha256")) {
        throw PureProviderError("workflow.document_fact_invalid", "goal bytes differ from the canonical observation") }
    if(httpIntentText(input,"op")=="migrate_legacy"){return workflowGoalLegacyMigration(input,raw)}
    let data = input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow()
    let observation = data.field("observation") ?? nullValue()
    if (observation.unifiedKind == ValueKind.Null) {
        throw PureProviderError("workflow.goal_observation_missing", "actual Host statistics provider is required") }
    workflowFields(observation, ["schema", "thread_id", "run_id", "observed_at_millis", "input_tokens", "output_tokens"])
    if (workflowText(observation, "schema") != "axyndra.document-observation/v1" ||
        workflowText(observation, "thread_id") == "" || workflowText(observation, "run_id") == "") {
        throw PureProviderError("workflow.goal_observation_missing", "goal requires the actual canonical usage observation") }
    let now = workflowNonnegative(observation, "observed_at_millis")
    let inputTokens = workflowNonnegative(observation, "input_tokens")
    let outputTokens = workflowNonnegative(observation, "output_tokens")
    if (inputTokens > 9223372036854775807 - outputTokens) {
        throw PureProviderError("workflow.goal_observation_invalid", "observed usage cannot be represented") }
    let requestDigest = workflowText(data, "request_digest")
    if (!httpIntentDigest(requestDigest)) { throw PureProviderError("workflow.goal_observation_invalid", "canonical request digest required") }
    let arguments = objectValue(input.fields.toArray().filter { field =>
        field.name != CONTEXT_READ_INPUT_FIELD && field.name != "method" }.map { field => ValueField(field.name, field.value) })
    let method = if (input.field("method").isSome()) { workflowText(input, "method") } else { "tool" }
    let query = objectValue([ValueField("schema", textValue("axyndra.workflow-policy/v1")),
        ValueField("action", textValue("goal")), ValueField("source_digest", textValue(workflowText(snapshot, "sha256"))),
        ValueField("method", textValue(method)), ValueField("session_id", textValue(workflowText(observation, "thread_id"))),
        ValueField("document", parseUnifiedJson(raw, maxBytes: 8388608, maxDepth: 32)), ValueField("arguments", arguments),
        ValueField("facts", objectValue([ValueField("now_millis", integerValue(now)),
            ValueField("total_tokens", integerValue(inputTokens + outputTokens)),
            ValueField("proposed_goal_id", textValue("goal-" + requestDigest))]))])
    if (input.field("command_args").isSome()) {
        workflowFields(input, ["command_args", CONTEXT_READ_INPUT_FIELD])
        return workflowGoalSlash(query, workflowText(input, "command_args"))
    }
    let result = workflowGoal(query)
    let failure = result.field("failure").getOrThrow()
    objectValue([ValueField("changed", result.field("changed").getOrThrow()),
        ValueField("document", result.field("document").getOrThrow()),
        ValueField("is_error", boolValue(failure.unifiedKind != ValueKind.Null)),
        ValueField("output", if (failure.unifiedKind == ValueKind.Null) { result.field("output").getOrThrow() }
            else { objectValue([ValueField("error", failure)]) })])
}

func workflowGoalCommand(input: AgentValue): AgentValue {
    workflowFields(input, ["command_args"])
    let raw = workflowText(input, "command_args").trimAscii()
    if(raw == "migrate" || raw.startsWith("migrate ")) {
        if(!raw.startsWith("migrate ")) {
            throw PureProviderError("goal.legacy_payload_required", "Use the selected /goal migrate frontend to freeze preserved legacy bytes.") }
        let payload=parseUnifiedJson(raw[8..],maxBytes:16384,maxDepth:8)
        workflowFields(payload,["legacy_document","legacy_sha256"])
        let frozen=workflowText(payload,"legacy_document")
        let digest=workflowText(payload,"legacy_sha256")
        if(!httpIntentDigest(digest) || modelPolicySha256Text(frozen)!=digest) {
            throw PureProviderError("goal.legacy_digest_invalid", "Legacy migration bytes changed.") }
        return objectValue([ValueField("schema",textValue("axyndra.command-proposal/v1")),
            ValueField("local_tool",textValue("goal")),ValueField("input",objectValue([
                ValueField("op",textValue("migrate_legacy")),ValueField("legacy_document",textValue(frozen)),
                ValueField("legacy_sha256",textValue(digest))]))])
    }
    // Static lexical/usage checks are pure. Existence, state and the final
    // continuation proposal are decided only after the actual canonical read.
    let _ = workflowGoalSlashArguments(raw)
    objectValue([ValueField("schema", textValue("axyndra.command-proposal/v1")),
        ValueField("local_tool", textValue("goal")),
        ValueField("input", objectValue([ValueField("command_args", textValue(raw))]))])
}

func workflowGoalDocumentTool(): AgentValue {
    objectValue([ValueField("name", textValue("goal")),
        ValueField("description", textValue("Create, inspect, complete, resume, or drop a durable goal. User continuation authority is separate.")),
        ValueField("input_schema", objectValue([ValueField("type", textValue("object")),
            ValueField("properties", objectValue([
                ValueField("command_args", objectValue([ValueField("type", textValue("string"))])),
                ValueField("op", objectValue([ValueField("type", textValue("string")),
                    ValueField("enum", listValue([textValue("create"), textValue("get"), textValue("complete"), textValue("resume"), textValue("drop"), textValue("migrate_legacy")]))])),
                ValueField("legacy_document", objectValue([ValueField("type", textValue("string"))])),
                ValueField("legacy_sha256", objectValue([ValueField("type", textValue("string"))])),
                ValueField("objective", objectValue([ValueField("type", textValue("string"))])),
                ValueField("token_budget", objectValue([ValueField("type", textValue("integer"))])),
                ValueField("method", objectValue([ValueField("type", textValue("string"))]))]))]))])
}
