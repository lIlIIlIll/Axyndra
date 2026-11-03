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

let AST_EDIT_MAX_FILES: Int64 = 32
let AST_EDIT_MAX_REPLACEMENTS: Int64 = 1000

func validatedAstEditInput(input: JsonNode): JsonNode {
    if (input.unifiedKind != UnifiedJsonKind.Object) { throw AstPluginFailure("tool.ast_edit_argument", "AST edit input must be an object") }
    for (entry in input.fields where entry.name != "ops" && entry.name != "paths") {
        throw AstPluginFailure("tool.ast_edit_argument", "unknown AST edit argument")
    }
    let ops = input.field("ops") ?? jsonNull()
    let paths = input.field("paths") ?? jsonNull()
    if (ops.unifiedKind != UnifiedJsonKind.List || ops.items.isEmpty() || ops.items.size > 32 ||
        paths.unifiedKind != UnifiedJsonKind.List || paths.items.isEmpty() || paths.items.size > 32) {
        throw AstPluginFailure("tool.ast_edit_argument", "ops and paths must each contain 1 to 32 entries")
    }
    let patterns = ArrayList<String>()
    for (op in ops.items) {
        if (op.unifiedKind != UnifiedJsonKind.Object || op.fields.size != 2 ||
            (op.field("pat") ?? jsonNull()).unifiedKind != UnifiedJsonKind.Text ||
            (op.field("out") ?? jsonNull()).unifiedKind != UnifiedJsonKind.Text) {
            throw AstPluginFailure("tool.ast_edit_argument", "each rewrite must contain only pat and out strings")
        }
        let pattern = astText(op, "pat")
        let replacement = astText(op, "out")
        if (pattern.trimAscii() == "" || pattern.size > 8192 || replacement.size > 8192 ||
            pattern.contains("\u{0000}") || replacement.contains("\u{0000}")) {
            throw AstPluginFailure("tool.ast_edit_argument", "rewrite strings must be bounded and NUL-free, with a non-empty pattern")
        }
        if (patterns.contains(pattern)) { throw AstPluginFailure("tool.ast_edit_duplicate", "duplicate rewrite pattern") }
        patterns.add(pattern)
    }
    var selections: Int64 = 0
    for (path in paths.items) {
        if (path.unifiedKind != UnifiedJsonKind.Text || path.text.trimAscii() == "" ||
            path.text.size > 4096 || path.text.contains("\u{0000}")) {
            throw AstPluginFailure("tool.ast_edit_argument", "paths must be bounded, non-empty, NUL-free strings")
        }
        selections += path.text.split(";").size
        if (selections > 32) { throw AstPluginFailure("tool.ast_edit_argument", "AST edit supports at most 32 path selections") }
    }
    jsonObject([JsonObjectEntry("ops", ops), JsonObjectEntry("paths", paths)])
}

class AstRewrite {
    let path: String
    let start: Int64
    let end: Int64
    let before: String
    let after: String
    init(path: String, start: Int64, end: Int64, before: String, after: String) {
        this.path = path; this.start = start; this.end = end; this.before = before; this.after = after
    }
}

func appendAstRewrites(changes: ArrayList<AstRewrite>, encoded: String, root: String): Unit {
    let values = parseUnifiedJson(encoded, maxBytes: 16777216, maxDepth: 64)
    if (values.unifiedKind != UnifiedJsonKind.List) { throw AstPluginFailure("tool.ast_edit_protocol", "AST engine returned a non-array rewrite result") }
    if (values.items.size > AST_EDIT_MAX_REPLACEMENTS - changes.size) {
        throw AstPluginFailure("tool.ast_edit_limit", "AST edit exceeds 1000 replacements; narrow paths or patterns")
    }
    for (item in values.items) {
        let absolute = astResolve(root, astText(item, "file"))
        if (!absolute.startsWith(root + "/")) { throw AstPluginFailure("workspace.path_escape", "AST rewrite must target a workspace file") }
        let offsets = (item.field("range") ?? jsonObject([])).field("byteOffset") ?? jsonObject([])
        let start = astInteger(offsets, "start", -1)
        let end = astInteger(offsets, "end", -1)
        if (start < 0 || end < start ||
            (item.field("text") ?? jsonNull()).unifiedKind != UnifiedJsonKind.Text ||
            (item.field("replacement") ?? jsonNull()).unifiedKind != UnifiedJsonKind.Text) {
            throw AstPluginFailure("tool.ast_edit_protocol", "AST engine returned an invalid rewrite range")
        }
        changes.add(AstRewrite(absolute[root.size + 1..], start, end, astText(item, "text"), astText(item, "replacement")))
    }
}

func astEditRead(root: String, path: String): String {
    let absolute = astResolve(root, path)
    let info = FileInfo(Path(absolute))
    if (!info.isRegular() || info.size > AST_PLUGIN_RESULT_BYTES) {
        throw AstPluginFailure("tool.ast_edit_limit", "AST edit source must be a regular file within the 64 KiB proposal budget")
    }
    let bytes = ArrayList<Byte>()
    let file = File(absolute, OpenMode.Read)
    try {
        let buffer = Array<Byte>(8192, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            if (bytes.size + count > AST_PLUGIN_RESULT_BYTES) { throw AstPluginFailure("tool.ast_edit_limit", "AST edit source exceeds its bounded read") }
            bytes.add(all: buffer[..count])
        }
    } finally { file.close() }
    let content = String.fromUtf8(bytes.toArray())
    if (content.contains("\u{0000}")) { throw AstPluginFailure("tool.ast_edit_argument", "AST edit source must be NUL-free UTF-8") }
    content
}

func astOrderedRewrites(changes: Array<AstRewrite>, path: String): Array<AstRewrite> {
    let ordered = ArrayList<AstRewrite>()
    let selected = ArrayList<Int64>()
    while (true) {
        var best: Int64 = -1
        for (index in 0..changes.size where changes[index].path == path && !selected.contains(index)) {
            if (best < 0 || changes[index].start > changes[best].start) { best = index }
        }
        if (best < 0) { break }
        selected.add(best); ordered.add(changes[best])
    }
    ordered.toArray()
}

func astEditProposal(changes: Array<AstRewrite>, root: String, diagnostics: Array<String>): JsonNode {
    let paths = ArrayList<String>()
    for (change in changes where !paths.contains(change.path)) {
        paths.add(change.path)
        if (paths.size > AST_EDIT_MAX_FILES) { throw AstPluginFailure("tool.ast_edit_limit", "AST edit proposal exceeds 32 files") }
    }
    let operations = ArrayList<JsonNode>()
    let counts = ArrayList<JsonNode>()
    for (path in paths) {
        let expected = astEditRead(root, path)
        var replacement = expected
        var previousStart = expected.size
        let ordered = astOrderedRewrites(changes, path)
        for (change in ordered) {
            if (change.end > expected.size || change.start > expected.size) {
                throw AstPluginFailure("tool.ast_edit_stale", "AST rewrite range no longer matches source")
            }
            if (change.end > previousStart) { throw AstPluginFailure("tool.ast_edit_overlap", "AST rewrite operations overlap") }
            if (expected[change.start..change.end] != change.before) {
                throw AstPluginFailure("tool.ast_edit_stale", "AST source changed during preview")
            }
            replacement = replacement[..change.start] + change.after + replacement[change.end..]
            if (replacement.size > AST_PLUGIN_RESULT_BYTES) { throw AstPluginFailure("tool.ast_edit_limit", "AST replacement exceeds the proposal budget") }
            previousStart = change.start
        }
        operations.add(jsonObject([
            JsonObjectEntry("kind", jsonString("replace")), JsonObjectEntry("path", jsonString(path)),
            JsonObjectEntry("expected_content", jsonString(expected)), JsonObjectEntry("content", jsonString(replacement))
        ]))
        counts.add(jsonObject([JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("count", jsonNumber(ordered.size.toString()))]))
    }
    let fields = ArrayList<JsonObjectEntry>([
        JsonObjectEntry("content", jsonString(if (changes.isEmpty()) { "No replacements made" } else { "AST edit proposal prepared; files have not been modified." })),
        JsonObjectEntry("total_replacements", jsonNumber(changes.size.toString())),
        JsonObjectEntry("files_touched", jsonNumber(paths.size.toString())), JsonObjectEntry("applied", jsonBool(false)),
        JsonObjectEntry("files", astStringArray(paths.toArray())), JsonObjectEntry("file_replacements", jsonArray(counts.toArray())),
        JsonObjectEntry("parse_errors", astStringArray(diagnostics))
    ])
    if (!operations.isEmpty()) {
        let proposal = jsonObject([
            JsonObjectEntry("schema", jsonString("axyndra.file-change-proposal/v1")),
            JsonObjectEntry("operations", jsonArray(operations.toArray()))
        ])
        if (stringifyUnifiedJson(proposal).size > AST_PLUGIN_RESULT_BYTES) { throw AstPluginFailure("tool.ast_edit_limit", "AST proposal exceeds 64 KiB; narrow paths or patterns") }
        fields.add(JsonObjectEntry("proposal", proposal))
    }
    jsonObject(fields.toArray())
}

func runAstEdit(authored: JsonNode, workspace: String, executable: String): JsonNode {
    let input = validatedAstEditInput(authored)
    let root = canonicalize(Path(workspace)).toString()
    let engine = canonicalize(Path(executable)).parent.join("ast-grep").toString()
    let changes = ArrayList<AstRewrite>()
    let diagnostics = ArrayList<String>()
    let deadline = ast_process.CancellationSource(deadlineMillis: DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 30000)
    try {
        for (op in input.field("ops").getOrThrow().items) {
            for (path in input.field("paths").getOrThrow().items) {
                for (part in path.text.split(";")) {
                    let target = astGlobTarget(part.trimAscii())
                    let args = ArrayList<String>(["run", "--pattern", astText(op, "pat"), "--rewrite", astText(op, "out"), "--json=compact", "--color", "never"])
                    match (target.glob) { case Some(glob) => args.add("--globs"); args.add(glob); case None => () }
                    args.add(astResolve(root, target.base))
                    let result = runProcess(ProcessCommand(engine, arguments: args.toArray(), workingDirectory: root,
                        maxOutputBytes: 16777216, terminateProcessTree: true), cancellation: deadline.token)
                    if (result.truncated) { throw AstPluginFailure("tool.ast_edit_limit", "AST engine rewrite output exceeds its limit") }
                    if (result.status.code != 0 && result.status.code != 1) { throw AstPluginFailure("tool.ast_edit_failed", String.fromUtf8(result.stderr).trimAscii()) }
                    appendAstRewrites(changes, String.fromUtf8(result.stdout), root)
                    for (line in String.fromUtf8(result.stderr).split("\n")) {
                        let message = line.trimAscii()
                        if (message != "" && diagnostics.size < 20 && !diagnostics.contains(message)) { diagnostics.add(message) }
                    }
                }
            }
        }
    } catch (error: Exception) {
        if (deadline.token.isCancelled()) { throw AstPluginFailure("tool.ast_edit_timeout", "AST edit preview timed out") }
        throw error
    } finally { deadline.close() }
    astEditProposal(changes.toArray(), root, diagnostics.toArray())
}
