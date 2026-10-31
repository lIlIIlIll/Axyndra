package ast_plugin

import agent_domain.*
import process4cj.*
import process4cj as ast_process
import std.collection.*
import std.convert.*
import std.fs.*
import std.time.*
import yjson.*
import yjson_support.*

class AstMatch {
    let path: String
    let line: Int64
    let column: Int64
    let text: String
    let meta: String
    init(path: String, line: Int64, column: Int64, text: String, meta: String) {
        this.path = path; this.line = line; this.column = column
        this.text = text; this.meta = meta
    }
}

class AstTarget {
    let base: String
    let glob: ?String
    init(base: String, glob!: ?String = None) { this.base = base; this.glob = glob }
}

func astInteger(value: JsonNode, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case None => fallback
        case Some(field) =>
            if (field.unifiedKind != UnifiedJsonKind.Number) {
                throw AstPluginFailure("tool.ast_grep_argument", name + " must be an integer")
            }
            try { Int64.parse(field.asNumberText()) } catch (_: Exception) {
                throw AstPluginFailure("tool.ast_grep_argument", name + " must be an integer")
            }
    }
}

func validatedAstInput(input: JsonNode): JsonNode {
    if (input.unifiedKind != UnifiedJsonKind.Object) {
        throw AstPluginFailure("tool.ast_grep_argument", "AST input must be an object")
    }
    for (entry in input.fields) {
        if (entry.name != "pat" && entry.name != "path" && entry.name != "skip") {
            throw AstPluginFailure("tool.ast_grep_argument", "unknown AST argument: " + entry.name)
        }
        if ((entry.name == "pat" || entry.name == "path") && entry.value.unifiedKind != UnifiedJsonKind.Text) {
            throw AstPluginFailure("tool.ast_grep_argument", entry.name + " must be a string")
        }
    }
    let pattern = astText(input, "pat").trimAscii()
    let path = astText(input, "path", fallback: ".")
    let skip = astInteger(input, "skip", 0)
    if (pattern.contains("\u{0000}") || path.contains("\u{0000}")) {
        throw AstPluginFailure("tool.ast_grep_argument", "AST pattern and path must be NUL-free")
    }
    if (pattern == "" || pattern.size > 8192) {
        throw AstPluginFailure("tool.ast_grep_pattern", "pat must contain 1 to 8192 bytes")
    }
    if (skip < 0 || skip > Int64.Max - 50) {
        throw AstPluginFailure("tool.ast_grep_skip", "skip must be a bounded non-negative integer")
    }
    if (path.size > 4096 || path.split(";").size > 32) {
        throw AstPluginFailure("tool.ast_grep_path_limit", "AST path selection exceeds its limit")
    }
    jsonObject([
        JsonObjectEntry("pat", jsonString(pattern)), JsonObjectEntry("path", jsonString(path)),
        JsonObjectEntry("skip", jsonNumber(skip.toString()))
    ])
}

func astResolve(root: String, authored: String): String {
    if (authored.trimAscii() == "") { throw AstPluginFailure("tool.ast_path_empty", "AST path entries must not be empty") }
    let candidate = if (authored.startsWith("/")) { Path(authored).normalize() } else { Path(root).join(authored).normalize() }
    let lexical = candidate.toString()
    if (lexical != root && !lexical.startsWith(root + "/")) {
        throw AstPluginFailure("workspace.path_escape", "AST path escapes the workspace")
    }
    let resolved = if (exists(candidate)) { canonicalize(candidate).toString() } else {
        if (!exists(candidate.parent)) { throw AstPluginFailure("workspace.parent_missing", "AST path parent does not exist") }
        canonicalize(candidate.parent).join(candidate.fileName).toString()
    }
    if (resolved != root && !resolved.startsWith(root + "/")) {
        throw AstPluginFailure("workspace.path_escape", "AST path escapes the workspace")
    }
    resolved
}

func astGlobTarget(value: String): AstTarget {
    let bytes = value.toArray()
    var globStart: Int64 = -1
    for (index in 0..bytes.size) {
        if (bytes[index] == b'*' || bytes[index] == b'?' || bytes[index] == b'[' || bytes[index] == b'{') {
            globStart = index; break
        }
    }
    if (globStart < 0) { return AstTarget(value) }
    var slash: Int64 = -1
    for (index in 0..globStart) { if (bytes[index] == b'/') { slash = index } }
    if (slash < 0) { return AstTarget(".", glob: Some(value)) }
    AstTarget(if (slash == 0) { "/" } else { value[..slash] }, glob: Some(value[slash + 1..]))
}

func runAstQuery(authored: JsonNode, workspace: String, executable: String): JsonNode {
    let input = validatedAstInput(authored)
    let root = canonicalize(Path(workspace)).toString()
    let engine = canonicalize(Path(executable)).parent.join("ast-grep").toString()
    let matches = ArrayList<AstMatch>()
    let diagnostics = ArrayList<String>()
    let deadline = ast_process.CancellationSource(deadlineMillis: DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 30000)
    try {
        for (part in astText(input, "path").split(";")) {
            let target = astGlobTarget(part.trimAscii())
            let base = astResolve(root, target.base)
            let args = ArrayList<String>(["run", "--pattern", astText(input, "pat"), "--json=compact", "--color", "never"])
            match (target.glob) {
                case Some(glob) => args.add("--globs"); args.add(glob)
                case None => ()
            }
            args.add(base)
            let result = runProcess(ProcessCommand(engine, arguments: args.toArray(), workingDirectory: root,
                maxOutputBytes: 16777216, terminateProcessTree: true), cancellation: deadline.token)
            if (result.truncated) { throw AstPluginFailure("tool.ast_grep_output_limit", "AST engine output exceeds its limit; narrow path or pattern") }
            if (result.status.code != 0 && result.status.code != 1) {
                throw AstPluginFailure("tool.ast_grep_failed", String.fromUtf8(result.stderr).trimAscii())
            }
            appendAstMatches(matches, String.fromUtf8(result.stdout), root)
            for (line in String.fromUtf8(result.stderr).split("\n")) {
                let message = line.trimAscii()
                if (message != "" && diagnostics.size < 20 && !diagnostics.contains(message)) { diagnostics.add(message) }
            }
        }
    } catch (error: Exception) {
        if (deadline.token.isCancelled()) { throw AstPluginFailure("tool.ast_grep_timeout", "AST query timed out") }
        throw error
    } finally { deadline.close() }
    let skip = astInteger(input, "skip", 0)
    let visible = ArrayList<AstMatch>()
    for (index in skip..min(matches.size, skip + 50)) { visible.add(matches[index]) }
    let files = ArrayList<String>()
    for (value in matches) { if (!files.contains(value.path)) { files.add(value.path) } }
    let encoded = ArrayList<JsonNode>()
    for (value in visible) {
        encoded.add(jsonObject([
            JsonObjectEntry("path", jsonString(value.path)), JsonObjectEntry("line", jsonNumber(value.line.toString())),
            JsonObjectEntry("column", jsonNumber(value.column.toString())), JsonObjectEntry("text", jsonString(value.text)),
            JsonObjectEntry("meta", jsonString(value.meta))
        ]))
    }
    jsonObject([
        JsonObjectEntry("content", jsonString(if (visible.isEmpty()) { "No matches found" } else { renderAstMatches(visible.toArray(), root) })),
        JsonObjectEntry("match_count", jsonNumber(matches.size.toString())), JsonObjectEntry("visible_count", jsonNumber(visible.size.toString())),
        JsonObjectEntry("file_count", jsonNumber(files.size.toString())), JsonObjectEntry("limit_reached", jsonBool(matches.size > skip + 50)),
        JsonObjectEntry("scope_path", jsonString(astText(input, "path"))), JsonObjectEntry("files", astStringArray(files.toArray())),
        JsonObjectEntry("parse_errors", astStringArray(diagnostics.toArray())), JsonObjectEntry("matches", jsonArray(encoded.toArray()))
    ])
}

func astStringArray(values: Array<String>): JsonNode {
    let output = ArrayList<JsonNode>()
    for (value in values) { output.add(jsonString(value)) }
    jsonArray(output.toArray())
}

func appendAstMatches(matches: ArrayList<AstMatch>, source: String, root: String): Unit {
    let decoded = parseUnifiedJson(source, maxBytes: 16777216, maxDepth: 64)
    if (decoded.unifiedKind != UnifiedJsonKind.List) { throw AstPluginFailure("tool.ast_grep_protocol", "AST engine returned a non-array result") }
    if (decoded.items.size > 100000 - matches.size) { throw AstPluginFailure("tool.ast_grep_match_limit", "AST query exceeds 100000 matches; narrow path or pattern") }
    for (item in decoded.items) {
        let path = astResolve(root, astText(item, "file"))
        let relative = if (path.startsWith(root + "/")) { path[root.size + 1..] } else { path }
        let range = item.field("range") ?? jsonObject([])
        let start = range.field("start") ?? jsonObject([])
        let captures = (item.field("metaVariables") ?? jsonObject([])).field("single") ?? jsonObject([])
        var meta = ""
        for (capture in captures.fields) {
            if (meta != "") { meta += ", " }
            meta += capture.name + "=" + astText(capture.value, "text")
        }
        matches.add(AstMatch(relative, astInteger(start, "line", 0) + 1, astInteger(start, "column", 0) + 1, astText(item, "text"), meta))
    }
}

func astHeader(root: String, relative: String): String {
    try {
        let path = astResolve(root, relative)
        let info = FileInfo(Path(path))
        if (!info.isRegular() || info.size > 16777216) { return "[" + relative + "]" }
        let file = File(path, OpenMode.Read)
        let bytes = ArrayList<Byte>()
        try {
            let buffer = Array<Byte>(8192, repeat: 0)
            while (true) {
                let count = file.read(buffer)
                if (count == 0) { break }
                if (bytes.size + count > 16777216) { return "[" + relative + "]" }
                bytes.add(all: buffer[..count])
            }
        } finally { file.close() }
        "[" + relative + "#" + normalizedContentTag(String.fromUtf8(bytes.toArray())) + "]"
    } catch (_: Exception) { "[" + relative + "]" }
}

func renderAstMatches(matches: Array<AstMatch>, root: String): String {
    var output = ""
    var path = ""
    for (value in matches) {
        if (value.path != path) {
            if (output != "") { output += "\n" }
            path = value.path; output += astHeader(root, path) + "\n"
        }
        let lines = value.text.split("\n")
        for (index in 0..lines.size) {
            output += (if (index == 0) { "*" } else { " " }) + (value.line + index).toString() + ":" + lines[index] + "\n"
        }
        if (value.meta != "") { output += "  meta: " + value.meta + "\n" }
        if (output.size > AST_PLUGIN_RESULT_BYTES) { throw AstPluginFailure("tool.ast_grep_output_limit", "AST display exceeds its limit; narrow pattern") }
    }
    output.trimAscii()
}
