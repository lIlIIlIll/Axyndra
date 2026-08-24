package agent_product

import json4cj.*
import agent_domain.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*

let AST_EDIT_PREVIEW_NOTICE =
    "Staged as a proposal — files NOT modified yet. To apply: write a " +
    "one-sentence reason to xd://resolve. To discard: write to xd://reject."

class AstGrepTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let processes: ProcessPort

    init(workspace: LocalWorkspace, processes: ProcessPort) {
        this.workspace = workspace
        this.processes = processes
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let pattern = match (requiredString(call, "pat")) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result.Err(error)
        }
        if (pattern == "") {
            return invalidArgument(
                call,
                "pat",
                "`pat` must be a non-empty pattern"
            )
        }
        let skip = optionalInteger(call, "skip", 0)
        if (skip < 0) {
            return invalidArgument(
                call,
                "skip",
                "skip must be a non-negative number"
            )
        }
        let targets = match (resolveAstTargets(
            workspace,
            optionalString(call, "path", ".")
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let matches = ArrayList<AstMatch>()
        let parseErrors = ArrayList<String>()
        for (target in targets) {
            let arguments = ArrayList<String>()
            arguments.add("run")
            arguments.add("--pattern")
            arguments.add(pattern)
            arguments.add("--json=compact")
            arguments.add("--color")
            arguments.add("never")
            match (target.glob) {
                case Some(value) =>
                    arguments.add("--globs")
                    arguments.add(value)
                case None => ()
            }
            arguments.add(target.basePath)
            let result = match (processes.execute(ProcessRequest(
                "/usr/bin/ast-grep",
                operationId: astGrepOperationId(context.runId),
                arguments: arguments.toArray(),
                timeoutMillis: 30000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
            ))) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (result.timedOut) {
                return Result.Err(AgentError(
                    AgentErrorKind.Timeout,
                    "tool.ast_grep_timeout",
                    "AST search timed out"
                ))
            }
            if (result.exitCode != 0 && result.exitCode != 1) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.ast_grep_failed",
                    if (result.stderr.trimAscii() == "") {
                        "AST search failed"
                    } else {
                        result.stderr.trimAscii()
                    }
                ))
            }
            match (decodeAstMatches(
                result.stdout,
                workspace.rootPath()
            )) {
                case Result.Ok(values) => matches.add(all: values)
                case Result.Err(error) => return Result.Err(error)
            }
            appendAstDiagnostics(parseErrors, result.stderr)
        }
        let totalMatches = matches.size
        let visible = ArrayList<AstMatch>()
        let end = min(totalMatches, skip + 50)
        for (index in skip..end) { visible.add(matches[index]) }
        let files = uniqueAstFiles(matches.toArray())
        let content = renderAstMatches(
            visible.toArray(),
            workspace
        )
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField(
                    "content",
                    textValue(if (visible.isEmpty()) {
                        "No matches found"
                    } else {
                        content
                    })
                ),
                ValueField(
                    "match_count",
                    integerValue(totalMatches)
                ),
                ValueField(
                    "visible_count",
                    integerValue(visible.size)
                ),
                ValueField(
                    "file_count",
                    integerValue(files.size)
                ),
                ValueField(
                    "limit_reached",
                    boolValue(totalMatches > skip + 50)
                ),
                ValueField(
                    "scope_path",
                    textValue(optionalString(call, "path", "."))
                ),
                ValueField(
                    "files",
                    textListValue(files)
                ),
                ValueField(
                    "parse_errors",
                    textListValue(parseErrors.toArray())
                ),
                ValueField(
                    "matches",
                    encodeAstMatches(visible.toArray())
                )
            ])
        ))
    }

    public func cancel(runId: RunId): Result<Unit> {
        match (processes.cancel(astGrepOperationId(runId))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) =>
                if (error.code == "process.operation_not_running") {
                    Result.Ok(())
                } else {
                    Result.Err(error)
                }
        }
    }
}

class AstEditRuntime {
    private let workspace: LocalWorkspace
    private let processes: ProcessPort
    private let lock = Mutex()
    private let pending = ArrayList<PendingAstEdit>()

    init(workspace: LocalWorkspace, processes: ProcessPort) {
        this.workspace = workspace
        this.processes = processes
    }

    func preview(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let ops = match (decodeAstEditOps(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let authoredPaths = match (decodeAstEditPaths(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let targets = ArrayList<AstSearchTarget>()
        for (authored in authoredPaths) {
            match (resolveAstTargets(workspace, authored)) {
                case Result.Ok(values) => targets.add(all: values)
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let replacements = ArrayList<AstReplacement>()
        let parseErrors = ArrayList<String>()
        for (op in ops) {
            for (target in targets) {
                let arguments = ArrayList<String>()
                arguments.add("run")
                arguments.add("--pattern")
                arguments.add(op.pattern)
                arguments.add("--rewrite")
                arguments.add(op.output)
                arguments.add("--json=compact")
                arguments.add("--color")
                arguments.add("never")
                match (target.glob) {
                    case Some(value) =>
                        arguments.add("--globs")
                        arguments.add(value)
                    case None => ()
                }
                arguments.add(target.basePath)
                let result = match (processes.execute(ProcessRequest(
                    "/usr/bin/ast-grep",
                    operationId: astEditOperationId(context.runId),
                    arguments: arguments.toArray(),
                    timeoutMillis: 30000,
                    sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
                ))) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (result.timedOut) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Timeout,
                        "tool.ast_edit_timeout",
                        "AST edit preview timed out"
                    ))
                }
                if (result.exitCode != 0 && result.exitCode != 1) {
                    return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "tool.ast_edit_failed",
                        if (result.stderr.trimAscii() == "") {
                            "AST edit preview failed"
                        } else {
                            result.stderr.trimAscii()
                        }
                    ))
                }
                match (decodeAstReplacements(
                    result.stdout,
                    workspace.rootPath()
                )) {
                    case Result.Ok(values) => replacements.add(all: values)
                    case Result.Err(error) => return Result.Err(error)
                }
                appendAstDiagnostics(parseErrors, result.stderr)
            }
        }
        let planned = match (planAstFiles(workspace, replacements.toArray())) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (planned.size > 1000) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "tool.ast_edit_file_limit",
                "AST edit preview exceeds the 1000-file safety limit"
            ))
        }
        var total: Int64 = 0
        for (file in planned) { total += file.changes.size }
        if (total == 0) {
            return Result.Ok(ToolResult(
                call.callId,
                astEditOutput(
                    "No replacements made",
                    planned,
                    total,
                    false,
                    parseErrors.toArray()
                )
            ))
        }
        stage(PendingAstEdit(
            context.sessionId.value,
            planned,
            total
        ))
        Result.Ok(ToolResult(
            call.callId,
            astEditOutput(
                AST_EDIT_PREVIEW_NOTICE + "\n\n" +
                    renderAstEditPreview(planned),
                planned,
                total,
                false,
                parseErrors.toArray()
            )
        ))
    }

    func resolve(
        context: ToolInvocationContext,
        callId: String,
        reason: String
    ): Result<ToolResult> {
        lock.lock()
        try {
            let index = findPending(context.sessionId.value)
            if (index < 0) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.ast_edit_no_pending",
                    "No pending action to apply — xd://resolve is only " +
                        "valid while a staged preview is pending."
                ))
            }
            let value = pending[index]
            let mutations = ArrayList<WorkspaceMutation>()
            for (fileIndex in 0..value.files.size) {
                let file = value.files[fileIndex]
                let current = match (workspace.read(
                    WorkspaceReadRequest(file.path)
                )) {
                    case Result.Ok(read) => read.content
                    case Result.Err(error) => return Result.Err(error)
                }
                if (current != file.expected) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "tool.ast_edit_stale_preview",
                        "Preview is stale / no longer matches; no " +
                            "replacements were applied: " + file.path
                    ))
                }
                mutations.add(WorkspaceMutation(
                    OperationId(
                        "ast-edit-resolve-" + context.runId.value + "-" +
                            callId + "-" + fileIndex.toString()
                    ),
                    file.path,
                    file.expected,
                    file.replacement
                ))
            }
            let receipts = match (workspace.commitAll(mutations.toArray())) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            pending.remove(at: index)
            let freshTags = renderAstEditFreshTags(workspace, value.files)
            var text = "Applied " + value.total.toString() +
                astPlural(value.total, " replacement", " replacements") +
                " in " + value.files.size.toString() +
                astPlural(value.files.size, " file.", " files.")
            if (freshTags != "") { text += "\n" + freshTags }
            Result.Ok(ToolResult(
                callId,
                astEditResolutionOutput(
                    text,
                    value,
                    "apply",
                    reason
                ),
                receiptId: receipts[0].operationId.value
            ))
        } finally {
            lock.unlock()
        }
    }

    func reject(
        context: ToolInvocationContext,
        callId: String,
        reason: String
    ): Result<ToolResult> {
        lock.lock()
        try {
            let index = findPending(context.sessionId.value)
            if (index < 0) {
                return Result.Ok(ToolResult(
                    callId,
                    objectValue([
                        ValueField(
                            "content",
                            textValue(
                                "Nothing to reject; no pending action remains."
                            )
                        ),
                        ValueField("action", textValue("discard")),
                        ValueField("reason", textValue(reason))
                    ])
                ))
            }
            let value = pending[index]
            pending.remove(at: index)
            let label = "AST Edit: " + value.total.toString() +
                astPlural(value.total, " replacement", " replacements") +
                " in " + value.files.size.toString() +
                astPlural(value.files.size, " file", " files")
            Result.Ok(ToolResult(
                callId,
                astEditResolutionOutput(
                    "Discarded: " + label + ". Reason: " + reason,
                    value,
                    "discard",
                    reason
                )
            ))
        } finally {
            lock.unlock()
        }
    }

    func cancel(runId: RunId): Result<Unit> {
        match (processes.cancel(astEditOperationId(runId))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) =>
                if (error.code == "process.operation_not_running") {
                    Result.Ok(())
                } else {
                    Result.Err(error)
                }
        }
    }

    private func stage(value: PendingAstEdit): Unit {
        lock.lock()
        try {
            pending.add(value)
        } finally {
            lock.unlock()
        }
    }

    private func findPending(sessionId: String): Int64 {
        for (index in 0..pending.size
             where pending[index].sessionId == sessionId) {
            return index
        }
        -1
    }
}

class AstEditTool <: ToolExecutor {
    private let runtime: AstEditRuntime
    init(runtime: AstEditRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.preview(context, call)
    }

    public func cancel(runId: RunId): Result<Unit> {
        runtime.cancel(runId)
    }
}

class AstEditOp {
    let pattern: String
    let output: String

    init(pattern: String, output: String) {
        this.pattern = pattern
        this.output = output
    }
}

class AstReplacement {
    let path: String
    let start: Int64
    let end: Int64
    let line: Int64
    let column: Int64
    let before: String
    let after: String

    init(
        path: String,
        start: Int64,
        end: Int64,
        line: Int64,
        column: Int64,
        before: String,
        after: String
    ) {
        this.path = path
        this.start = start
        this.end = end
        this.line = line
        this.column = column
        this.before = before
        this.after = after
    }
}

class PendingAstFile {
    let path: String
    let expected: String
    let replacement: String
    let changes: Array<AstReplacement>

    init(
        path: String,
        expected: String,
        replacement: String,
        changes: Array<AstReplacement>
    ) {
        this.path = path
        this.expected = expected
        this.replacement = replacement
        this.changes = changes
    }
}

class PendingAstEdit {
    let sessionId: String
    let files: Array<PendingAstFile>
    let total: Int64

    init(
        sessionId: String,
        files: Array<PendingAstFile>,
        total: Int64
    ) {
        this.sessionId = sessionId
        this.files = files
        this.total = total
    }
}

class AstSearchTarget {
    let basePath: String
    let glob: ?String

    init(basePath: String, glob!: ?String = None) {
        this.basePath = basePath
        this.glob = glob
    }
}

class AstMatch {
    let path: String
    let line: Int64
    let column: Int64
    let text: String
    let meta: String

    init(
        path: String,
        line: Int64,
        column: Int64,
        text: String,
        meta!: String = ""
    ) {
        this.path = path
        this.line = line
        this.column = column
        this.text = text
        this.meta = meta
    }
}

func resolveAstTargets(
    workspace: LocalWorkspace,
    authored: String
): Result<Array<AstSearchTarget>> {
    let result = ArrayList<AstSearchTarget>()
    let parts = authored.split(";")
    for (part in parts) {
        let value = part.trimAscii()
        if (value == "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "tool.ast_path_empty",
                "AST search path entries must not be empty"
            ))
        }
        let split = astGlobSplit(value)
        let resolved = match (workspace.resolve(
            split.base,
            allowDirectory: true
        )) {
            case Result.Ok(path) => path
            case Result.Err(error) => return Result.Err(error)
        }
        result.add(AstSearchTarget(
            resolved,
            glob: split.glob
        ))
    }
    if (result.isEmpty()) {
        let resolved = match (workspace.resolve(
            ".",
            allowDirectory: true
        )) {
            case Result.Ok(path) => path
            case Result.Err(error) => return Result.Err(error)
        }
        result.add(AstSearchTarget(resolved))
    }
    Result.Ok(result.toArray())
}

class AstGlobSplit {
    let base: String
    let glob: ?String

    init(base: String, glob!: ?String = None) {
        this.base = base
        this.glob = glob
    }
}

func astGlobSplit(value: String): AstGlobSplit {
    let bytes = unsafe { value.rawData() }
    var globStart: Int64 = -1
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (byte == b'*' || byte == b'?' ||
            byte == b'[' || byte == b'{') {
            globStart = index
            break
        }
    }
    if (globStart < 0) { return AstGlobSplit(value) }
    var slash: Int64 = -1
    for (index in 0..globStart) {
        if (bytes[index] == b'/') { slash = index }
    }
    if (slash < 0) {
        return AstGlobSplit(".", glob: Some(value))
    }
    let base = if (slash == 0) { "/" } else { value[..slash] }
    let glob = value[slash + 1..]
    AstGlobSplit(base, glob: Some(glob))
}

func decodeAstMatches(
    source: String,
    workspaceRoot: String
): Result<Array<AstMatch>> {
    let root = try {
        parseJson(source, maxBytes: 16777216, maxDepth: 64)
    } catch (error: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.Transport,
            "tool.ast_grep_protocol",
            error.message
        ))
    }
    if (root.kind != JsonKind.List) {
        return Result.Err(AgentError(
            AgentErrorKind.Transport,
            "tool.ast_grep_protocol",
            "ast-grep returned a non-array result"
        ))
    }
    let result = ArrayList<AstMatch>()
    for (item in root.items) {
        let path = astJsonText(item, "file")
        let text = astJsonText(item, "text")
        let range = match (item.field("range")) {
            case Some(value) => value
            case None => JsonValue.objectValue([])
        }
        let start = match (range.field("start")) {
            case Some(value) => value
            case None => JsonValue.objectValue([])
        }
        result.add(AstMatch(
            astWorkspaceRelative(path, workspaceRoot),
            astJsonInteger(start, "line", 0) + 1,
            astJsonInteger(start, "column", 0) + 1,
            text,
            meta: renderAstMeta(item)
        ))
    }
    Result.Ok(result.toArray())
}

func decodeAstReplacements(
    source: String,
    workspaceRoot: String
): Result<Array<AstReplacement>> {
    let root = try {
        parseJson(source, maxBytes: 33554432, maxDepth: 64)
    } catch (error: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.Transport,
            "tool.ast_edit_protocol",
            error.message
        ))
    }
    if (root.kind != JsonKind.List) {
        return Result.Err(AgentError(
            AgentErrorKind.Transport,
            "tool.ast_edit_protocol",
            "ast-grep returned a non-array rewrite result"
        ))
    }
    let result = ArrayList<AstReplacement>()
    for (item in root.items) {
        let range = match (item.field("range")) {
            case Some(value) => value
            case None => JsonValue.objectValue([])
        }
        let offsets = match (range.field("byteOffset")) {
            case Some(value) => value
            case None => JsonValue.objectValue([])
        }
        let start = match (range.field("start")) {
            case Some(value) => value
            case None => JsonValue.objectValue([])
        }
        let startOffset = astJsonInteger(offsets, "start", -1)
        let endOffset = astJsonInteger(offsets, "end", -1)
        let path = astWorkspaceRelative(
            astJsonText(item, "file"),
            workspaceRoot
        )
        if (path == "" || startOffset < 0 || endOffset < startOffset) {
            return Result.Err(AgentError(
                AgentErrorKind.Transport,
                "tool.ast_edit_protocol",
                "ast-grep returned an invalid rewrite range"
            ))
        }
        result.add(AstReplacement(
            path,
            startOffset,
            endOffset,
            astJsonInteger(start, "line", 0) + 1,
            astJsonInteger(start, "column", 0) + 1,
            astJsonText(item, "text"),
            astJsonText(item, "replacement")
        ))
    }
    Result.Ok(result.toArray())
}

func decodeAstEditOps(call: ToolCall): Result<Array<AstEditOp>> {
    let value = match (call.arguments.field("ops")) {
        case Some(item) => item
        case None =>
            return invalidArgument(
                call,
                "ops",
                "required argument is missing"
            )
    }
    if (value.kind != ValueKind.List || value.items.isEmpty()) {
        return invalidArgument(
            call,
            "ops",
            "ops must be a non-empty array"
        )
    }
    let result = ArrayList<AstEditOp>()
    for (index in 0..value.items.size) {
        let item = value.items[index]
        if (item.kind != ValueKind.Object) {
            return invalidArgument(
                call,
                "ops",
                "ops entries must be objects"
            )
        }
        let pattern = match (item.field("pat")) {
            case Some(field) =>
                if (field.kind == ValueKind.Text) {
                    field.text
                } else {
                    return invalidArgument(
                        call,
                        "ops",
                        "ops[" + index.toString() + "].pat must be a string"
                    )
                }
            case None =>
                return invalidArgument(
                    call,
                    "ops",
                    "ops[" + index.toString() + "].pat is required"
                )
        }
        let output = match (item.field("out")) {
            case Some(field) =>
                if (field.kind == ValueKind.Text) {
                    field.text
                } else {
                    return invalidArgument(
                        call,
                        "ops",
                        "ops[" + index.toString() + "].out must be a string"
                    )
                }
            case None =>
                return invalidArgument(
                    call,
                    "ops",
                    "ops[" + index.toString() + "].out is required"
                )
        }
        if (pattern == "") {
            return invalidArgument(
                call,
                "ops",
                "`ops[" + index.toString() +
                    "].pat` must be a non-empty pattern"
            )
        }
        for (existing in result where existing.pattern == pattern) {
            return invalidArgument(
                call,
                "ops",
                "Duplicate rewrite pattern: " + pattern
            )
        }
        result.add(AstEditOp(pattern, output))
    }
    Result.Ok(result.toArray())
}

func decodeAstEditPaths(call: ToolCall): Result<Array<String>> {
    let value = match (call.arguments.field("paths")) {
        case Some(item) => item
        case None =>
            return invalidArgument(
                call,
                "paths",
                "required argument is missing"
            )
    }
    if (value.kind != ValueKind.List || value.items.isEmpty()) {
        return invalidArgument(
            call,
            "paths",
            "paths must be a non-empty array"
        )
    }
    let result = ArrayList<String>()
    for (index in 0..value.items.size) {
        let item = value.items[index]
        if (item.kind != ValueKind.Text ||
            item.text.trimAscii() == "") {
            return invalidArgument(
                call,
                "paths",
                "paths[" + index.toString() +
                    "] must be a non-empty string"
            )
        }
        result.add(item.text)
    }
    Result.Ok(result.toArray())
}

func planAstFiles(
    workspace: LocalWorkspace,
    replacements: Array<AstReplacement>
): Result<Array<PendingAstFile>> {
    let grouped = ArrayList<MutableAstFile>()
    for (replacement in replacements) {
        let resolved = match (workspace.resolve(replacement.path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var target: ?MutableAstFile = None
        for (file in grouped where file.path == replacement.path) {
            target = Some(file)
        }
        match (target) {
            case Some(file) => file.changes.add(replacement)
            case None =>
                let content = try {
                    String.fromUtf8(File.readFrom(resolved))
                } catch (error: Exception) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Internal,
                        "tool.ast_edit_read",
                        error.message
                    ))
                }
                let file = MutableAstFile(replacement.path, content)
                file.changes.add(replacement)
                grouped.add(file)
        }
    }
    let result = ArrayList<PendingAstFile>()
    for (file in grouped) {
        let ordered = orderAstReplacements(file.changes.toArray())
        var content = file.expected
        let initialBytes = unsafe { content.rawData() }
        var previousStart = initialBytes.size
        for (change in ordered) {
            if (change.end > previousStart) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "tool.ast_edit_overlap",
                    "AST rewrite operations overlap in " + file.path
                ))
            }
            let sourceBytes = unsafe { content.rawData() }
            if (change.end > sourceBytes.size) {
                return Result.Err(AgentError(
                    AgentErrorKind.Transport,
                    "tool.ast_edit_protocol",
                    "AST rewrite range exceeds file content: " + file.path
                ))
            }
            content = content[..change.start] +
                change.after +
                content[change.end..]
            previousStart = change.start
        }
        result.add(PendingAstFile(
            file.path,
            file.expected,
            content,
            ordered
        ))
    }
    Result.Ok(result.toArray())
}

class MutableAstFile {
    let path: String
    let expected: String
    let changes = ArrayList<AstReplacement>()

    init(path: String, expected: String) {
        this.path = path
        this.expected = expected
    }
}

func orderAstReplacements(
    source: Array<AstReplacement>
): Array<AstReplacement> {
    let result = ArrayList<AstReplacement>()
    let selected = ArrayList<Int64>()
    while (selected.size < source.size) {
        var best: Int64 = -1
        for (index in 0..source.size) {
            var used = false
            for (value in selected where value == index) { used = true }
            if (used) { continue }
            if (best < 0 || source[index].start > source[best].start) {
                best = index
            }
        }
        selected.add(best)
        result.add(source[best])
    }
    result.toArray()
}

func renderAstEditPreview(files: Array<PendingAstFile>): String {
    var output = ""
    for (file in files) {
        if (output != "") { output += "\n\n" }
        output += "[" + file.path + "#" +
            hashlineTag(file.expected) + "]"
        for (change in file.changes) {
            output += "\n-" + change.line.toString() + ":" +
                astFirstLine(change.before)
            output += "\n+" + change.line.toString() + ":" +
                astFirstLine(change.after)
        }
    }
    output
}

func renderAstEditFreshTags(
    workspace: LocalWorkspace,
    files: Array<PendingAstFile>
): String {
    var output = ""
    for (file in files) {
        let currentValue: ?String = match (workspace.read(
            WorkspaceReadRequest(file.path)
        )) {
            case Result.Ok(value) => Some(value.content)
            case Result.Err(_) => None
        }
        match (currentValue) {
            case Some(current) =>
                if (output != "") { output += "\n" }
                output += "[" + file.path + "#" +
                    hashlineTag(current) + "]"
            case None => ()
        }
    }
    output
}

func astFirstLine(value: String): String {
    let lines = value.split("\n")
    let first = if (lines.isEmpty()) { "" } else { lines[0] }
    let bytes = unsafe { first.rawData() }
    if (bytes.size <= 120) { first } else { first[..120] }
}

func astEditOutput(
    content: String,
    files: Array<PendingAstFile>,
    total: Int64,
    applied: Bool,
    parseErrors: Array<String>
): AgentValue {
    let paths = ArrayList<String>()
    let replacements = ArrayList<AgentValue>()
    for (file in files) {
        paths.add(file.path)
        replacements.add(objectValue([
            ValueField("path", textValue(file.path)),
            ValueField("count", integerValue(file.changes.size))
        ]))
    }
    objectValue([
        ValueField("content", textValue(content)),
        ValueField("total_replacements", integerValue(total)),
        ValueField("files_touched", integerValue(files.size)),
        ValueField("applied", boolValue(applied)),
        ValueField("limit_reached", boolValue(false)),
        ValueField("files", textListValue(paths.toArray())),
        ValueField(
            "file_replacements",
            listValue(replacements.toArray())
        ),
        ValueField("parse_errors", textListValue(parseErrors))
    ])
}

func astEditResolutionOutput(
    content: String,
    value: PendingAstEdit,
    action: String,
    reason: String
): AgentValue {
    let base = astEditOutput(
        content,
        value.files,
        value.total,
        action == "apply",
        []
    )
    let fields = ArrayList<ValueField>()
    fields.add(all: base.fields)
    fields.add(ValueField("action", textValue(action)))
    fields.add(ValueField("reason", textValue(reason)))
    fields.add(ValueField("source_tool_name", textValue("ast_edit")))
    objectValue(fields.toArray())
}

func astPlural(value: Int64, one: String, many: String): String {
    if (value == 1) { one } else { many }
}

func astJsonText(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == JsonKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func astJsonInteger(
    value: JsonValue,
    name: String,
    fallback: Int64
): Int64 {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == JsonKind.Number) {
                try {
                    Int64.parse(field.text)
                } catch (_: Exception) {
                    fallback
                }
            } else {
                fallback
            }
        case None => fallback
    }
}

func renderAstMeta(value: JsonValue): String {
    let variables = match (value.field("metaVariables")) {
        case Some(item) => item
        case None => return ""
    }
    let single = match (variables.field("single")) {
        case Some(item) => item
        case None => return ""
    }
    let entries = ArrayList<String>()
    for (member in single.members) {
        let captured = astJsonText(member.value, "text")
        entries.add(member.name + "=" + captured)
    }
    joinAstStrings(entries.toArray(), ", ")
}

func astWorkspaceRelative(path: String, root: String): String {
    let prefix = root + "/"
    if (path.startsWith(prefix)) {
        return path[prefix.size..]
    }
    path
}

func renderAstMatches(
    matches: Array<AstMatch>,
    workspace: LocalWorkspace
): String {
    var output = ""
    var currentPath = ""
    for (matchValue in matches) {
        if (matchValue.path != currentPath) {
            if (output != "") { output += "\n" }
            currentPath = matchValue.path
            output += astHashlineHeader(workspace, currentPath) + "\n"
        }
        let lines = matchValue.text.split("\n")
        for (index in 0..lines.size) {
            let marker = if (index == 0) { "*" } else { " " }
            output += marker +
                (matchValue.line + index).toString() + ":" +
                lines[index] + "\n"
        }
        if (matchValue.meta != "") {
            output += "  meta: " + matchValue.meta + "\n"
        }
    }
    output.trimAscii()
}

func astHashlineHeader(
    workspace: LocalWorkspace,
    path: String
): String {
    let resolved = match (workspace.resolve(path)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return "[" + path + "]"
    }
    try {
        let content = String.fromUtf8(File.readFrom(resolved))
        "[" + path + "#" + hashlineTag(content) + "]"
    } catch (_: Exception) {
        "[" + path + "]"
    }
}

func encodeAstMatches(matches: Array<AstMatch>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in matches) {
        result.add(objectValue([
            ValueField("path", textValue(value.path)),
            ValueField("line", integerValue(value.line)),
            ValueField("column", integerValue(value.column)),
            ValueField("text", textValue(value.text)),
            ValueField("meta", textValue(value.meta))
        ]))
    }
    listValue(result.toArray())
}

func uniqueAstFiles(matches: Array<AstMatch>): Array<String> {
    let result = ArrayList<String>()
    for (value in matches) {
        var found = false
        for (existing in result where existing == value.path) {
            found = true
        }
        if (!found) { result.add(value.path) }
    }
    result.toArray()
}

func appendAstDiagnostics(
    values: ArrayList<String>,
    source: String
): Unit {
    for (line in source.split("\n")) {
        let value = line.trimAscii()
        if (value == "" || values.size >= 20) { continue }
        var found = false
        for (existing in values where existing == value) {
            found = true
        }
        if (!found) { values.add(value) }
    }
}

func joinAstStrings(values: Array<String>, separator: String): String {
    var result = ""
    for (value in values) {
        if (result != "") { result += separator }
        result += value
    }
    result
}

func astGrepOperationId(runId: RunId): OperationId {
    OperationId("ast-grep-" + runId.value)
}

func astEditOperationId(runId: RunId): OperationId {
    OperationId("ast-edit-" + runId.value)
}
