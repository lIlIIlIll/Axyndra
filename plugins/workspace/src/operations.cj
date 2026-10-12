package workspace_plugin

import agent_domain.*
import process4cj.*
import process4cj as ws_process
import std.collection.*
import std.convert.*
import std.fs.*
import std.math.*
import std.time.*
import yjson.*
import yjson_support.*

func wsInteger(input: JsonNode, name: String, fallback: Int64): Int64 {
    let field = input.field(name) ?? jsonNull()
    if (field.unifiedKind == UnifiedJsonKind.Null) { return fallback }
    if (field.unifiedKind == UnifiedJsonKind.Number) {
        try { return Int64.parse(field.asNumberText()) } catch (_: Exception) { () }
    }
    throw WorkspaceFailure("workspace.argument", name + " must be an integer")
}

func wsValidate(tool: String, input: JsonNode): JsonNode {
    let allowed = match (tool) {
        case "read" => ["path", "offset", "limit", "destination"]
        case "grep" => ["pattern", "path", "count", "case", "gitignore", "skip"]
        case "glob" => ["pattern", "hidden", "gitignore", "limit"]
        case "edit" => ["input"]
        case "write" => ["path", "content"]
        case _ => throw WorkspaceFailure("workspace.tool_unknown", "Unknown workspace contribution")
    }
    if (input.unifiedKind != UnifiedJsonKind.Object) { throw WorkspaceFailure("workspace.argument", "Tool input must be an object") }
    for (field in input.fields) {
        if (!allowed.contains(field.name)) { throw WorkspaceFailure("workspace.argument", "Unsupported workspace argument") }
        if (["path", "pattern", "input", "content", "destination"].contains(field.name)) {
            if (field.value.unifiedKind != UnifiedJsonKind.Text || field.value.text.contains("\u{0000}")) {
                throw WorkspaceFailure("workspace.argument", "Text arguments must be NUL-free strings")
            }
        } else if (["count", "case", "gitignore", "hidden"].contains(field.name)) {
            if (field.value.unifiedKind != UnifiedJsonKind.Boolean) { throw WorkspaceFailure("workspace.argument", "Flag arguments must be booleans") }
        } else { let _ = wsInteger(input, field.name, 0) }
    }
    let required = match (tool) { case "read" | "write" => "path"; case "edit" => "input"; case _ => "pattern" }
    if (wsText(input, required).trimAscii() == "") { throw WorkspaceFailure("workspace.argument", required + " is required") }
    if (tool == "write" && (input.field("content") ?? jsonNull()).unifiedKind != UnifiedJsonKind.Text) {
        throw WorkspaceFailure("workspace.argument", "content must be a string")
    }
    if (tool == "write" && wsText(input, "content").toArray().size > WORKSPACE_WRITE_CONTENT_BYTES) {
        throw WorkspaceFailure("write.content_too_large", "Write content exceeds 32768 UTF-8 bytes")
    }
    if (stringifyUnifiedJson(input).size > workspaceInputLimit(tool)) {
        throw WorkspaceFailure("workspace.input_limit", "Workspace arguments exceed their bounded transport limit")
    }
    input
}

// This first package deliberately refuses special targets. Broader reads need a
// host-authorized path service, not a plugin-authored permission declaration.
func wsSensitive(path: String): Bool {
    let lower = path.toAsciiLower()
    let name = Path(lower).fileName
    name == ".env" || name.startsWith(".env.") || name.endsWith(".pem") || name.endsWith(".key") || ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials"].contains(name) ||
        lower.contains("/.ssh/") || lower.contains("/.gnupg/") || lower.contains("/.aws/") ||
        lower.contains("/credentials/") || lower.contains("/keychain/") || lower.contains("/cookies/")
}

func wsResolve(root: String, authored: String): String {
    if (authored == "" || authored.size > 4096 || authored.contains("\u{0000}") || authored.contains("://")) {
        throw WorkspaceFailure("workspace.path_unsupported", "Only bounded workspace filesystem paths are supported")
    }
    let candidate = if (authored.startsWith("/")) { Path(authored).normalize() } else { Path(root).join(authored).normalize() }
    let lexical = candidate.toString()
    if (lexical != root && !lexical.startsWith(root + "/")) { throw WorkspaceFailure("workspace.path_escape", "Path escapes workspace") }
    if (!workspaceHostReadView && wsSensitive(lexical)) { throw WorkspaceFailure("workspace.sensitive_path_unsupported", "Sensitive paths require a separate host authorization service") }
    let resolved = if (exists(candidate)) { canonicalize(candidate).toString() } else {
        if (!exists(candidate.parent)) { throw WorkspaceFailure("workspace.parent_missing", "Target parent does not exist") }
        canonicalize(candidate.parent).join(candidate.fileName).toString()
    }
    if (resolved != root && !resolved.startsWith(root + "/")) { throw WorkspaceFailure("workspace.path_escape", "Resolved path escapes workspace") }
    if (!workspaceHostReadView && wsSensitive(resolved)) { throw WorkspaceFailure("workspace.sensitive_path_unsupported", "Sensitive paths require separate host authorization") }
    resolved
}

func wsReadText(root: String, path: String, maximumBytes!: Int64 = 16777216): String {
    let absolute = wsResolve(root, path)
    let info = FileInfo(Path(absolute))
    if (!info.isRegular()) { throw WorkspaceFailure("tool.read_failed", "Target must be a regular file") }
    if (info.size > maximumBytes) { throw WorkspaceFailure("workspace.file_limit", "File exceeds this operation's bounded snapshot limit") }
    let bytes = ArrayList<Byte>()
    let file = File(absolute, OpenMode.Read)
    try {
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            if (bytes.size + count > maximumBytes) { throw WorkspaceFailure("workspace.file_limit", "File exceeds the snapshot limit") }
            bytes.add(all: buffer[..count])
        }
    } finally { file.close() }
    if (bytes.contains(0)) { throw WorkspaceFailure("tool.read_binary", "Binary files are unsupported") }
    try { String.fromUtf8(bytes.toArray()) }
    catch (_: Exception) { throw WorkspaceFailure("tool.read_binary", "File is not valid UTF-8") }
}

func wsPrefix(source: String, ceiling: Int64): String {
    let bytes = source.toArray()
    var end = min(bytes.size, max(0, ceiling))
    while (end > 0 && end < bytes.size && (bytes[end] & 0xC0) == 0x80) { end-- }
    String.fromUtf8(bytes[..end])
}

func wsInsertSorted(values: ArrayList<String>, value: String): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 && values[index] < values[index - 1]) {
        let previous = values[index - 1]; values[index - 1] = values[index]; values[index] = previous; index--
    }
}

func wsDirectory(root: String, path: String): JsonNode {
    let values = ArrayList<String>()
    var total: Int64 = 0
    let absolute = wsResolve(root, path)
    for (entry in Directory.readFrom(absolute)) {
        total++
        let child = Path(absolute).join(entry.name)
        wsInsertSorted(values, entry.name + if (FileInfo(child).isDirectory()) { "/" } else { "" })
        if (values.size > 2000) { values.remove(at: values.size - 1) }
    }
    var rendered = joinLines(values.toArray())
    var output = jsonNull()
    while (true) {
        output = jsonObject([JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("entries", jsonString(rendered)),
            JsonObjectEntry("count", jsonNumber(values.size.toString())), JsonObjectEntry("total_count", jsonNumber(total.toString())),
            JsonObjectEntry("returned_bytes", jsonNumber(rendered.size.toString())), JsonObjectEntry("truncated", jsonBool(total > values.size))])
        if (stringifyUnifiedJson(output).size <= WORKSPACE_RESULT_BYTES) { return output }
        values.remove(at: values.size - 1); rendered = joinLines(values.toArray())
    }
    output
}

func wsRead(input: JsonNode, root: String): JsonNode {
    wsReadMapped(input, root, parseReadTarget(wsText(input, "path")).path)
}

func wsReadMapped(input: JsonNode, root: String, physical: String): JsonNode {
    let target = parseReadTarget(wsText(input, "path"))
    if (readViewResourceReference(target.path)) {
        let destination = wsText(input, "destination")
        if (destination != "") {
            if (!target.path.startsWith("blob:sha256:") || target.hasRange || target.raw || input.field("offset").isSome() || input.field("limit").isSome()) {
                throw WorkspaceFailure("artifact.export_arguments", "Export requires a complete artifact reference and destination only") }
            let path = workspaceViewRelative(destination)
            return wsResourceProposal("export_artifact", jsonObject([JsonObjectEntry("reference", jsonString(target.path)), JsonObjectEntry("destination", jsonString(path))]))
        }
        let blob = target.path.startsWith("blob:sha256:")
        if (blob && (target.hasRange || target.raw)) { throw WorkspaceFailure("artifact.read_arguments", "Artifact slices use explicit byte offset and limit") }
        let offset = if (target.hasRange) { target.offset } else { wsInteger(input, "offset", if (blob) { 0 } else { 1 }) }
        let limit = if (target.hasRange) { target.limit } else { wsInteger(input, "limit", if (blob) { 1048576 } else { 2000 }) }
        if (offset < (if (blob) { 0 } else { 1 }) || limit < 1 || limit > 1048576) { throw WorkspaceFailure("tool.read_range", "Resource range exceeds its bounded independent Root") }
        return wsResourceProposal("read_resource", jsonObject([JsonObjectEntry("reference", jsonString(target.path)),
            JsonObjectEntry("offset", jsonNumber(offset.toString())), JsonObjectEntry("limit", jsonNumber(limit.toString())),
            JsonObjectEntry("unit", jsonString(if (blob) { "bytes" } else { "lines" }))]))
    }
    if (wsText(input, "destination") != "") { throw WorkspaceFailure("artifact.export_arguments", "Destination applies only to an artifact reference") }
    let absolute = wsResolve(root, physical)
    if (FileInfo(Path(absolute)).isDirectory()) {
        let result = wsDirectory(root, physical); result.put("path", jsonString(target.path)); return result
    }
    let content = wsReadText(root, physical)
    let offset = if (target.hasRange) { target.offset } else { wsInteger(input, "offset", 1) }
    let limit = if (target.hasRange) { target.limit } else { wsInteger(input, "limit", 2000) }
    if (offset < 1 || limit < 1) { throw WorkspaceFailure("tool.read_range", "offset and limit must be positive") }
    let lines = content.split("\n")
    let start = min(offset - 1, lines.size)
    let end = min(lines.size, start + min(limit, 10000))
    let selected = joinLines(lines[start..end])
    var returned = wsPrefix(selected, WORKSPACE_RESULT_BYTES)
    while (true) {
        let rendered = if (target.raw) { returned } else { formatHashlineRange(target.path, content, returned, start + 1) }
        let output = jsonObject([JsonObjectEntry("path", jsonString(target.path)), JsonObjectEntry("content", jsonString(rendered)),
            JsonObjectEntry("bytes", jsonNumber(content.size.toString())), JsonObjectEntry("returned_bytes", jsonNumber(returned.size.toString())),
            JsonObjectEntry("offset", jsonNumber((start + 1).toString())), JsonObjectEntry("truncated", jsonBool(end < lines.size || returned.size < selected.size))])
        if (stringifyUnifiedJson(output).size <= WORKSPACE_RESULT_BYTES) { return output }
        if (returned.size == 0) { throw WorkspaceFailure("workspace.output_limit", "Read metadata exceeds result limit") }
        returned = wsPrefix(returned, returned.size * 3 / 4)
    }
    jsonNull()
}

func wsStringArray(values: Array<String>): JsonNode {
    let output = ArrayList<JsonNode>()
    for (value in values) { output.add(jsonString(value)) }
    jsonArray(output.toArray())
}

func wsProposal(operations: Array<JsonNode>, paths: Array<String>): JsonNode {
    if (operations.size > 32) { throw WorkspaceFailure("workspace.edit_limit", "At most 32 files may be proposed together") }
    let proposal = jsonObject([JsonObjectEntry("schema", jsonString("axyndra.file-change-proposal/v1")), JsonObjectEntry("operations", jsonArray(operations))])
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("paths", wsStringArray(paths)), JsonObjectEntry("files", jsonNumber(paths.size.toString())),
        JsonObjectEntry("changed", jsonBool(!operations.isEmpty())), JsonObjectEntry("applied", jsonBool(false))])
    if (!operations.isEmpty()) { fields.add(JsonObjectEntry("proposal", proposal)) }
    jsonObject(fields.toArray())
}

func wsEdit(input: JsonNode, root: String): JsonNode {
    match (splitHashlineSections(wsText(input, "input"))) {
        case Result.Err(error) => throw WorkspaceFailure(error.code, error.message)
        case Result.Ok(values) => if (values.size > 32) { throw WorkspaceFailure("workspace.edit_limit", "At most 32 file sections are supported") }
    }
    let edits = match (applyHashlineEdits(wsText(input, "input"), {path =>
        try { Result<String>.Ok(wsReadText(root, path, maximumBytes: WORKSPACE_RESULT_BYTES)) }
        catch (error: WorkspaceFailure) { Result<String>.Err(AgentError(AgentErrorKind.InvalidInput, error.code, error.message)) }
    })) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw WorkspaceFailure(error.code, error.message)
    }
    let operations = ArrayList<JsonNode>()
    let paths = ArrayList<String>()
    let resolved = ArrayList<String>()
    for (edit in edits) {
        let absolute = wsResolve(root, edit.path)
        if (resolved.contains(absolute)) { throw WorkspaceFailure("edit.invalid_hashline", "Multiple authored paths alias the same file") }
        resolved.add(absolute)
        if (edit.expected == edit.replacement) { continue }
        let path = absolute[root.size + 1..]
        paths.add(path)
        operations.add(jsonObject([JsonObjectEntry("kind", jsonString("replace")), JsonObjectEntry("path", jsonString(path)),
            JsonObjectEntry("expected_content", jsonString(edit.expected)), JsonObjectEntry("content", jsonString(edit.replacement))]))
    }
    wsProposal(operations.toArray(), paths.toArray())
}

func wsResourceProposal(tool: String, arguments: JsonNode): JsonNode {
    jsonObject([JsonObjectEntry("applied", jsonBool(false)), JsonObjectEntry("resource_request", jsonObject([
        JsonObjectEntry("schema", jsonString("axyndra.resource-request/v1")), JsonObjectEntry("tool", jsonString(tool)),
        JsonObjectEntry("arguments", arguments)])), JsonObjectEntry("content", jsonString("No resource was read, exported, or written. Review this request and submit its independent canonical Root explicitly."))])
}

func wsWrite(input: JsonNode, root: String): JsonNode {
    if (readViewResourceReference(wsText(input, "path"))) {
        if (wsText(input, "path").startsWith("blob:")) { throw WorkspaceFailure("artifact.immutable", "Artifacts are immutable; write a URI or propose a workspace file") }
        return wsResourceProposal("write_resource", jsonObject([JsonObjectEntry("reference", jsonString(wsText(input, "path"))),
            JsonObjectEntry("content", jsonString(wsText(input, "content")))]))
    }
    let absolute = wsResolve(root, wsText(input, "path"))
    if (absolute == root) { throw WorkspaceFailure("workspace.path_unsupported", "Write requires a workspace file") }
    let path = absolute[root.size + 1..]
    let content = wsText(input, "content")
    let present = exists(Path(absolute))
    let before = if (present) { wsReadText(root, path, maximumBytes: WORKSPACE_RESULT_BYTES) } else { "" }
    if (present && before == content) { return wsProposal([], []) }
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("kind", jsonString(if (present) { "replace" } else { "create" })),
        JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("content", jsonString(content))])
    if (present) {
        let textFields=ArrayList<JsonObjectEntry>(fields)
        textFields.add(JsonObjectEntry("expected_content",jsonString(before)))
        if(stringifyUnifiedJson(jsonObject(textFields.toArray())).size<=60000){
            fields.add(JsonObjectEntry("expected_content",jsonString(before)))
        }else{
            fields.add(JsonObjectEntry("expected_sha256",jsonString(modelPolicySha256(before.toArray()))))
            fields.add(JsonObjectEntry("expected_bytes",jsonNumber(before.toArray().size.toString())))
        }
    }
    wsProposal([jsonObject(fields.toArray())], [path])
}

func runWorkspaceTool(tool: String, authored: JsonNode, workspace: String, executable: String): JsonNode {
    let input = wsValidate(tool, authored)
    let root = canonicalize(Path(workspace)).toString()
    match (tool) {
        case "read" => wsRead(input, root)
        case "edit" => wsEdit(input, root)
        case "write" => wsWrite(input, root)
        case _ => wsSearch(tool, input, root, executable)
    }
}
