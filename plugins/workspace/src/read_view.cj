package workspace_plugin

import agent_domain.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

func workspaceViewRelative(path: String): String {
    let normalized = Path(path).normalize().toString()
    if (normalized == "" || normalized == "." || normalized.startsWith("/") || normalized.contains("\\") || normalized.contains(":") ||
        normalized == ".." || normalized.startsWith("../")) {
        throw WorkspaceFailure("workspace.path_unsupported", "Edit and write proposals require a workspace-relative file path")
    }
    normalized
}

// Pure grammar only: no stat, directory listing, file contents, subprocess or
// host callback. The host selects actual objects, classifications and budgets.
func workspacePrepare(invocation: JsonNode): Unit {
    let envelope = invocation.field("arguments") ?? jsonNull()
    if (envelope.field("schema").isSome()) { workspacePrepareReferenced(invocation); return }
    if (envelope.unifiedKind != UnifiedJsonKind.Object || envelope.fields.size != 1 || envelope.field("input").isNone()) {
        throw WorkspaceFailure("workspace.prepare_invalid", "Preparation expects original input only")
    }
    let tool = wsText(invocation, "tool")
    let input = wsValidate(tool, envelope.field("input").getOrThrow())
    let resources = ArrayList<JsonNode>()
    if (tool == "read") {
        let target = parseReadTarget(wsText(input, "path"))
        resources.add(workspaceViewResource(target.path, "target", if (readViewResourceReference(target.path)) { "opaque_reference" } else { "auto" }))
    } else if (tool == "edit") {
        let sections = match (splitHashlineSections(wsText(input, "input"))) {
            case Result.Ok(value) => value; case Result.Err(error) => throw WorkspaceFailure(error.code, error.message)
        }
        if (sections.size > 32) { throw WorkspaceFailure("workspace.edit_limit", "At most 32 edit resources are supported") }
        let paths = HashSet<String>()
        for (section in sections) {
            let parsed = match (parseHashline(section)) { case Result.Ok(value) => value; case Result.Err(error) => throw WorkspaceFailure(error.code, error.message) }
            let path = workspaceViewRelative(parsed.path)
            if (paths.contains(path)) { throw WorkspaceFailure("edit.invalid_hashline", "Edit repeats a normalized resource path") }
            paths.add(path); resources.add(workspaceViewResource(path, path, "file"))
        }
    } else if (tool == "write") {
        let authored = wsText(input, "path")
        if (readViewResourceReference(authored)) {
            resources.add(workspaceViewResource(authored, "target", "opaque_reference"))
        } else {
            let path = workspaceViewRelative(authored)
            resources.add(workspaceViewResource(path, path, "optional_file"))
        }
    } else {
        // Search grammar/globs stay in the package. The host's directory view
        // excludes sensitive objects independently of rg flags or this input.
        resources.add(workspaceViewResource(".", ".", "directory"))
    }
    let argv = if (tool == "read" && workspacePayloadProfile.isSome()) {
        ["--view-worker-profile", tool, stringifyUnifiedJson(input), stringifyUnifiedJson(workspacePayloadProfile.getOrThrow().value())]
    } else if (tool == "write") { ["--view-worker-file", tool] } else { ["--view-worker", tool, stringifyUnifiedJson(input)] }
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("executable", jsonString("bin/workspace-plugin")),
        JsonObjectEntry("arguments", wsStringArray(argv)), 
        JsonObjectEntry("timeout_ms", jsonNumber("30000"))])
    if (tool == "write") { fields.add(JsonObjectEntry("input", input)) }
    let request = jsonObject(fields.toArray())
    workspaceReply(invocation, jsonObject([JsonObjectEntry("intents", jsonArray([
        jsonObject([JsonObjectEntry("id", jsonString("workspace-query-1")), JsonObjectEntry("request", request),
            JsonObjectEntry("resources", jsonArray(resources.toArray()))])]))]), true)
}

func workspaceViewResource(source: String, path: String, mode: String): JsonNode {
    jsonObject([JsonObjectEntry("source", jsonString(source)), JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("mode", jsonString(mode))])
}
