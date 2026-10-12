package workspace_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func workspaceParameterExact(value: JsonNode, names: Array<String>): Bool {
    if (value.unifiedKind != UnifiedJsonKind.Object || value.fields.size != names.size) { return false }
    let seen = HashSet<String>()
    for (field in value.fields) {
        if (!names.contains(field.name) || seen.contains(field.name)) { return false }; seen.add(field.name) }
    true
}
func workspaceParameterDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) { if (!(byte >= b'0' && byte <= b'9') && !(byte >= b'a' && byte <= b'f')) { return false } }
    true
}
func workspaceParameterInteger(value: JsonNode, field: String): Int64 {
    let number = value.field(field) ?? jsonNull()
    if (number.unifiedKind != UnifiedJsonKind.Number) { throw WorkspaceFailure("workspace.prepare_invalid", "Parameter size must be a canonical integer") }
    let parsed = try { Int64.parse(number.asNumberText()) } catch (_: Exception) { -1 }
    if (parsed < 0 || parsed.toString() != number.asNumberText()) { throw WorkspaceFailure("workspace.prepare_invalid", "Parameter size is invalid") }
    parsed
}
func workspaceParameterText(node: JsonNode): (Int64, ?String) {
    let hasValue = node.field("value").isSome()
    if (!workspaceParameterExact(node, if (hasValue) { ["type", "utf8_bytes", "sha256", "has_nul", "value"] }
        else { ["type", "utf8_bytes", "sha256", "has_nul"] }) || wsText(node, "type") != "text" ||
        !workspaceParameterDigest(wsText(node, "sha256")) ||
        (node.field("has_nul") ?? jsonNull()).unifiedKind != UnifiedJsonKind.Boolean) {
        throw WorkspaceFailure("workspace.prepare_invalid", "Text metadata has invalid fields") }
    if (node.field("has_nul").getOrThrow().asBool()) { throw WorkspaceFailure("workspace.argument", "Text arguments must be NUL-free strings") }
    let bytes = workspaceParameterInteger(node, "utf8_bytes")
    if (hasValue) {
        let value = node.field("value").getOrThrow()
        if (value.unifiedKind != UnifiedJsonKind.Text || value.text.contains("\u{0000}") || value.text.size != bytes ||
            modelPolicySha256Text(value.text) != wsText(node, "sha256") || stringifyUnifiedJson(value).size > 8192) {
            throw WorkspaceFailure("workspace.prepare_invalid", "Small scalar does not match its complete metadata") }
        return (bytes, Some(value.text))
    }
    // Any omitted string necessarily exceeds the transport's small scalar
    // allowance. Full content is checked again by wsValidate during execution.
    if (bytes < 1366) { throw WorkspaceFailure("workspace.prepare_invalid", "Omitted scalar cannot exceed the declared small-value bound") }
    (bytes, None)
}
func workspacePrepareReferenced(invocation: JsonNode): Unit {
    let envelope = invocation.field("arguments") ?? jsonNull()
    if (!workspaceParameterExact(envelope, ["schema", "reference"]) ||
        wsText(envelope, "schema") != "axyndra.read-view-parameter-input/v1" || wsText(invocation, "tool") != "write") {
        throw WorkspaceFailure("workspace.prepare_invalid", "This contribution does not support parameter-reference preparation") }
    let reference = envelope.field("reference").getOrThrow()
    if (!workspaceParameterExact(reference, ["binding", "input_bytes", "input_sha256", "metadata"]) ||
        !workspaceParameterDigest(wsText(reference, "input_sha256")) || workspaceParameterInteger(reference, "input_bytes") > WORKSPACE_WRITE_INPUT_BYTES) {
        throw WorkspaceFailure("workspace.prepare_invalid", "Original input reference has invalid fields") }
    let binding = reference.field("binding").getOrThrow()
    if (!workspaceParameterExact(binding, ["thread_id", "run_id", "epoch", "call_id", "tool_name", "plugin", "contribution",
        "package_digest", "generation", "configuration_digest"]) ||
        wsText(binding, "thread_id") != wsText(invocation, "thread_id") || wsText(binding, "run_id") != wsText(invocation, "run_id") ||
        stringifyUnifiedJson(binding.field("epoch").getOrThrow()) != stringifyUnifiedJson(invocation.field("epoch").getOrThrow()) ||
        wsText(binding, "call_id") != wsText(invocation, "call_id") || wsText(binding, "plugin") != wsText(invocation, "extension_id") ||
        wsText(binding, "contribution") != "write" || wsText(binding, "tool_name") != "plugin." + wsText(invocation, "extension_id") + ".write" ||
        wsText(binding, "generation") != stringifyUnifiedJson(invocation.field("generation").getOrThrow()) ||
        !httpServicePackageDigest(wsText(binding, "package_digest")) || !workspaceParameterDigest(wsText(binding, "configuration_digest"))) {
        throw WorkspaceFailure("workspace.prepare_invalid", "Parameter reference belongs to another invocation") }
    let metadata = reference.field("metadata").getOrThrow()
    if (!workspaceParameterExact(metadata, ["type", "fields"]) || wsText(metadata, "type") != "object" ||
        (metadata.field("fields") ?? jsonNull()).unifiedKind != UnifiedJsonKind.List) {
        throw WorkspaceFailure("workspace.argument", "Write input must be an object") }
    let seen = HashSet<String>(); var authored: ?String = None; var contentFound = false
    for (field in metadata.field("fields").getOrThrow().items) {
        let name = wsText(field, "name")
        if (!workspaceParameterExact(field, ["name", "node"]) || !["path", "content"].contains(name) || seen.contains(name)) {
            throw WorkspaceFailure("workspace.argument", "Unsupported or repeated workspace argument") }
        seen.add(name)
        let (bytes, small) = workspaceParameterText(field.field("node").getOrThrow())
        if (name == "content") {
            if (bytes > WORKSPACE_WRITE_CONTENT_BYTES) { throw WorkspaceFailure("write.content_too_large", "Write content exceeds 32768 UTF-8 bytes") }
            contentFound = true
        } else {
            match (small) { case Some(value) => authored = Some(value); case None => throw WorkspaceFailure("workspace.path_unsupported", "Preparation requires the complete bounded target") }
        }
    }
    if (!contentFound || authored.isNone() || authored.getOrThrow().trimAscii() == "") {
        throw WorkspaceFailure("workspace.argument", "Write requires a path and content") }
    let path = authored.getOrThrow()
    let resource = if (readViewResourceReference(path)) { workspaceViewResource(path, "target", "opaque_reference") }
        else { let relative = workspaceViewRelative(path); workspaceViewResource(relative, relative, "optional_file") }
    let request = jsonObject([JsonObjectEntry("executable", jsonString("bin/workspace-plugin")),
        JsonObjectEntry("arguments", wsStringArray(["--view-worker-file", "write"])), JsonObjectEntry("timeout_ms", jsonNumber("30000")),
        JsonObjectEntry("input_reference", reference)])
    workspaceReply(invocation, jsonObject([JsonObjectEntry("intents", jsonArray([jsonObject([
        JsonObjectEntry("id", jsonString("workspace-query-1")), JsonObjectEntry("request", request),
        JsonObjectEntry("resources", jsonArray([resource]))])]))]), true)
}
