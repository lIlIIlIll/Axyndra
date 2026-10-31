package workspace_plugin

import process4cj.*
import process4cj as ws_process
import std.collection.*
import std.convert.*
import std.fs.*
import std.math.*
import std.time.*
import yjson.*
import yjson_support.*

func wsGlob(value: String): Bool {
    for (part in ["*", "?", "[", "]", "{", "}"]) { if (value.contains(part)) { return true } }
    false
}

func wsSearch(tool: String, input: JsonNode, root: String, executable: String): JsonNode {
    let glob = tool == "glob"
    let pattern = wsText(input, "pattern")
    let skip = wsInteger(input, "skip", 0)
    if (skip < 0) { throw WorkspaceFailure("workspace.argument", "skip must not be negative") }
    let requested = wsInteger(input, "limit", 200)
    if (requested < 1) { throw WorkspaceFailure("workspace.argument", "limit must be positive") }
    let limit = if (glob) { min(requested, 200) } else { 1000 }
    let args = ArrayList<String>(["--no-config", "--sort", "path", "--color", "never"])
    let paths = ArrayList<String>()
    if (glob) {
        args.add("--files")
        if (wsBool(input, "hidden")) { args.add("--hidden") }
        if (pattern != ".") { args.add("--glob"); args.add(pattern) }
    } else {
        args.add(all: ["--line-number", "--no-heading"])
        if (wsBool(input, "count")) { args.add(all: ["-c", "--with-filename"]) }
        if (!wsBool(input, "case")) { args.add("--ignore-case") }
        let selection = wsText(input, "path", fallback: ".")
        if (selection.size > 4096 || selection.split(";").size > 32) { throw WorkspaceFailure("workspace.argument", "Search path selection exceeds its limit") }
        for (part in selection.split(";")) {
            let path = part.trimAscii()
            if (path == "") { continue }
            if (wsGlob(path)) {
                args.add("--glob"); args.add(path)
            } else {
                let absolute = wsResolve(root, path)
                paths.add(if (absolute == root) { "." } else { absolute[root.size + 1..] })
            }
        }
    }
    if (!wsBool(input, "gitignore", fallback: true)) { args.add("--no-ignore") }
    // This package does not implement the separately authorized sensitive-read
    // facility. Negative globs follow positive selectors and cannot be undone.
    for (excluded in ["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/id_rsa", "**/id_dsa", "**/id_ecdsa", "**/id_ed25519",
        "**/.ssh/**", "**/.gnupg/**", "**/.aws/**", "**/credentials{,/**}", "**/keychain/**", "**/cookies{,/**}"]) {
        args.add("--iglob"); args.add("!" + excluded)
    }
    if (!glob) {
        args.add("--"); args.add(pattern)
        args.add(all: if (paths.isEmpty()) { ["."] } else { paths.toArray() })
    }
    let engine = canonicalize(Path(executable)).parent.join("rg").toString()
    let deadline = ws_process.CancellationSource(deadlineMillis: DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + 15000)
    var output = ""
    var found = false
    try {
        let result = runProcess(ProcessCommand(engine, arguments: args.toArray(), workingDirectory: root,
            maxOutputBytes: 16777216, terminateProcessTree: true), cancellation: deadline.token)
        if (deadline.token.isCancelled()) { throw WorkspaceFailure("tool.search_timeout", "Workspace search timed out") }
        if (result.truncated) { throw WorkspaceFailure("workspace.output_limit", "Search engine output exceeds 16 MiB; narrow the pattern or paths") }
        if (result.status.code != 0 && result.status.code != 1) { throw WorkspaceFailure("tool.search_failed", "Search engine rejected the pattern or paths") }
        output = String.fromUtf8(result.stdout); found = result.status.code == 0
    } finally { deadline.close() }
    let lines = ArrayList<String>()
    for (line in output.split("\n") where line != "") { lines.add(line) }
    if (!glob && wsBool(input, "count")) {
        let files = ArrayList<JsonNode>()
        var total: Int64 = 0
        var matchedFiles: Int64 = 0
        for (line in lines) {
            let separator = match (line.lastIndexOf(":")) { case Some(value) => value; case None => continue }
            let count = try { Int64.parse(line[separator + 1..]) } catch (_: Exception) { -1 }
            if (separator > 0 && count >= 0) {
                matchedFiles++; total += count
                if (files.size < limit) {
                    files.add(jsonObject([JsonObjectEntry("path", jsonString(line[..separator])), JsonObjectEntry("count", jsonNumber(count.toString()))]))
                }
            }
        }
        return jsonObject([JsonObjectEntry("files", jsonArray(files.toArray())), JsonObjectEntry("total", jsonNumber(total.toString())),
            JsonObjectEntry("truncated", jsonBool(matchedFiles > files.size))])
    }
    let start = if (glob) { 0 } else { min(skip, lines.size) }
    let end = min(lines.size, start + limit)
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry(if (glob) { "paths" } else { "matches" }, jsonString(joinLines(lines.toArray()[start..end]))),
        JsonObjectEntry("count", jsonNumber((end - start).toString())), JsonObjectEntry("truncated", jsonBool(end < lines.size))])
    if (!glob) { fields.add(JsonObjectEntry("found", jsonBool(found))) }
    jsonObject(fields.toArray())
}
