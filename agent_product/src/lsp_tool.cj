package agent_product

import yjson.*
import yjson_support.*
import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*

class LspTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let runtime: LspRuntime

    init(workspace: LocalWorkspace, runtime: LspRuntime) {
        this.workspace = workspace
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let action = match (requiredString(call, "action")) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result.Err(error)
        }
        if (!validLspAction(action)) {
            return invalidArgument(
                call,
                "action",
                "unknown LSP action: " + action
            )
        }
        let timeoutSeconds = optionalInteger(call, "timeout", 20)
        if (timeoutSeconds < 5 || timeoutSeconds > 300) {
            return invalidArgument(
                call,
                "timeout",
                "timeout must be between 5 and 300 seconds"
            )
        }
        if (action == "status") {
            return Result.Ok(lspToolResult(
                call,
                action,
                runtime.status(),
                true
            ))
        }
        let authored = optionalString(call, "file", "")
        if (authored == "") {
            return Result.Ok(lspToolResult(
                call,
                action,
                "Error: file parameter required. Use `*` for workspace " +
                    "scope where supported.",
                false
            ))
        }
        if (authored == "*") {
            return executeWorkspaceLsp(
                context,
                call,
                action,
                timeoutSeconds * 1000
            )
        }
        if (action == "rename_file") {
            return executeLspRenameFile(
                context,
                call,
                workspace,
                runtime,
                authored,
                timeoutSeconds * 1000
            )
        }
        let path = match (workspace.resolve(authored)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let client = match (runtime.clientFor(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (client.open(context.runId, path, timeoutSeconds * 1000)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (action == "capabilities") {
            return Result.Ok(lspToolResult(
                call,
                action,
                client.spec.name + ":\n  capabilities: " +
                    client.serverCapabilities().stringify()
                        .replace("\n", "\n  "),
                true,
                server: client.spec.name
            ))
        }
        if (action == "diagnostics") {
            return executeLspDiagnostics(
                context,
                call,
                path,
                client,
                timeoutSeconds * 1000
            )
        }
        if (action == "request") {
            return executeRawLspRequest(
                context,
                call,
                path,
                client,
                timeoutSeconds * 1000
            )
        }
        if (action == "reload") {
            client.close()
            let restarted = match (runtime.clientFor(path)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            return Result.Ok(lspToolResult(
                call,
                action,
                "Reloaded " + restarted.spec.name,
                true,
                server: restarted.spec.name
            ))
        }
        let position = match (lspPosition(call, path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (action) {
            case "definition" =>
                executeLocationRequest(
                    context,
                    call,
                    client,
                    path,
                    position,
                    "textDocument/definition",
                    "definition",
                    timeoutSeconds * 1000
                )
            case "type_definition" =>
                executeLocationRequest(
                    context,
                    call,
                    client,
                    path,
                    position,
                    "textDocument/typeDefinition",
                    "type definition",
                    timeoutSeconds * 1000
                )
            case "implementation" =>
                executeLocationRequest(
                    context,
                    call,
                    client,
                    path,
                    position,
                    "textDocument/implementation",
                    "implementation",
                    timeoutSeconds * 1000
                )
            case "references" =>
                executeReferences(
                    context,
                    call,
                    client,
                    path,
                    position,
                    timeoutSeconds * 1000
                )
            case "hover" =>
                executeHover(
                    context,
                    call,
                    client,
                    path,
                    position,
                    timeoutSeconds * 1000
                )
            case "symbols" =>
                executeDocumentSymbols(
                    context,
                    call,
                    client,
                    path,
                    timeoutSeconds * 1000
                )
            case "rename" =>
                executeLspRename(
                    context,
                    call,
                    workspace,
                    client,
                    path,
                    position,
                    timeoutSeconds * 1000
                )
            case "code_actions" =>
                executeLspCodeActions(
                    context,
                    call,
                    workspace,
                    client,
                    path,
                    position,
                    timeoutSeconds * 1000
                )
            case _ =>
                lspError<ToolResult>(
                    AgentErrorKind.Configuration,
                    "tool.lsp_action_not_connected",
                    "LSP action is not connected: " + action
                )
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        runtime.cancel(runId)
    }

    private func executeWorkspaceLsp(
        context: ToolInvocationContext,
        call: ToolCall,
        action: String,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        if (action == "status") {
            return Result.Ok(lspToolResult(
                call,
                action,
                runtime.status(),
                true
            ))
        }
        let clients = if (action == "reload") {
            runtime.reloadAll()
        } else {
            runtime.workspaceClients()
        }
        if (clients.isEmpty()) {
            return Result.Ok(lspToolResult(
                call,
                action,
                "No language server found for this action",
                false
            ))
        }
        if (action == "reload") {
            let names = ArrayList<String>()
            for (client in clients) { names.add(client.spec.name) }
            return Result.Ok(lspToolResult(
                call,
                action,
                "Reloaded " + joinLspStrings(names.toArray(), ", "),
                true,
                server: joinLspStrings(names.toArray(), ", ")
            ))
        }
        if (action == "capabilities") {
            let sections = ArrayList<String>()
            let names = ArrayList<String>()
            for (client in clients) {
                names.add(client.spec.name)
                sections.add(
                    client.spec.name + ":\n  capabilities: " +
                        client.serverCapabilities().stringify()
                            .replace("\n", "\n  ")
                )
            }
            return Result.Ok(lspToolResult(
                call,
                action,
                joinLspStrings(sections.toArray(), "\n"),
                true,
                server: joinLspStrings(names.toArray(), ", ")
            ))
        }
        if (action == "symbols") {
            let query = optionalString(call, "query", "").trimAscii()
            if (query == "") {
                return invalidArgument(
                    call,
                    "query",
                    "query parameter required for workspace symbol search"
                )
            }
            let symbols = ArrayList<String>()
            let names = ArrayList<String>()
            for (client in clients) {
                let response = match (client.request(
                    context.runId,
                    "workspace/symbol",
                    lspObject([
                        JsonObjectEntry(
                            "query",
                            jsonString(query)
                        )
                    ]),
                    timeoutMillis
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => continue
                }
                names.add(client.spec.name)
                appendWorkspaceLspSymbols(
                    symbols,
                    response,
                    client.root
                )
            }
            return Result.Ok(lspToolResult(
                call,
                action,
                if (symbols.isEmpty()) {
                    "No symbols matching \"" + query + "\""
                } else {
                    "Found " + symbols.size.toString() +
                        " symbol(s) matching \"" + query + "\":\n" +
                        joinLspStrings(symbols.toArray(), "\n")
                },
                true,
                server: joinLspStrings(names.toArray(), ", ")
            ))
        }
        if (action == "diagnostics") {
            let files = runtime.probeFiles(200)
            let lines = ArrayList<String>()
            let names = ArrayList<String>()
            for (path in files) {
                let client = match (runtime.clientFor(path)) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => continue
                }
                match (client.open(context.runId, path, timeoutMillis)) {
                    case Result.Ok(_) => ()
                    case Result.Err(_) => continue
                }
                let values = match (client.waitForDiagnostics(
                    context.runId,
                    path,
                    timeoutMillis
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => continue
                }
                for (value in values) {
                    lines.add(formatLspDiagnostic(
                        value,
                        lspRelative(path, workspace.rootPath())
                    ))
                }
                var found = false
                for (name in names where name == client.spec.name) {
                    found = true
                }
                if (!found) { names.add(client.spec.name) }
            }
            return Result.Ok(lspToolResult(
                call,
                action,
                if (lines.isEmpty()) {
                    "Workspace diagnostics: OK"
                } else {
                    "Workspace diagnostics:\n" +
                        joinLspStrings(lines.toArray(), "\n")
                },
                true,
                server: joinLspStrings(names.toArray(), ", ")
            ))
        }
        Result.Ok(lspToolResult(
            call,
            action,
            "Error: workspace scope is not supported for " + action,
            false
        ))
    }
}

class LspPosition {
    let line: Int64
    let character: Int64

    init(line: Int64, character: Int64) {
        this.line = line
        this.character = character
    }

    func json(): JsonNode {
        lspObject([
            JsonObjectEntry("line", jsonNumber(line.toString())),
            JsonObjectEntry(
                "character",
                jsonNumber(character.toString())
            )
        ])
    }
}

func executeLocationRequest(
    context: ToolInvocationContext,
    call: ToolCall,
    client: LspClient,
    path: String,
    position: LspPosition,
    method: String,
    label: String,
    timeoutMillis: Int64
): Result<ToolResult> {
    let value = match (client.request(
        context.runId,
        method,
        lspTextPositionParams(path, position),
        timeoutMillis
    )) {
        case Result.Ok(result) => result
        case Result.Err(error) => return Result.Err(error)
    }
    let locations = normalizeLspLocations(value)
    if (locations.isEmpty()) {
        return Result.Ok(lspToolResult(
            call,
            optionalString(call, "action", ""),
            "No " + label + " found",
            true,
            server: client.spec.name
        ))
    }
    let lines = ArrayList<String>()
    for (location in locations) {
        lines.add(formatLspLocation(location, client.root))
    }
    Result.Ok(lspToolResult(
        call,
        optionalString(call, "action", ""),
        "Found " + locations.size.toString() + " " + label +
            if (locations.size == 1) { ":\n" } else { "s:\n" } +
            joinLspStrings(lines.toArray(), "\n"),
        true,
        server: client.spec.name
    ))
}

func executeReferences(
    context: ToolInvocationContext,
    call: ToolCall,
    client: LspClient,
    path: String,
    position: LspPosition,
    timeoutMillis: Int64
): Result<ToolResult> {
    let params = lspTextPositionParams(path, position)
    params.put("context", lspObject([
        JsonObjectEntry("includeDeclaration", jsonBool(true))
    ]))
    let value = match (client.request(
        context.runId,
        "textDocument/references",
        params,
        timeoutMillis
    )) {
        case Result.Ok(result) => result
        case Result.Err(error) => return Result.Err(error)
    }
    let locations = normalizeLspLocations(value)
    if (locations.isEmpty()) {
        return Result.Ok(lspToolResult(
            call,
            "references",
            "No references found",
            true,
            server: client.spec.name
        ))
    }
    let lines = ArrayList<String>()
    for (location in locations) {
        lines.add(formatLspLocation(location, client.root))
    }
    Result.Ok(lspToolResult(
        call,
        "references",
        "Found " + locations.size.toString() + " reference" +
            if (locations.size == 1) { ":\n" } else { "s:\n" } +
            joinLspStrings(lines.toArray(), "\n"),
        true,
        server: client.spec.name
    ))
}

func executeHover(
    context: ToolInvocationContext,
    call: ToolCall,
    client: LspClient,
    path: String,
    position: LspPosition,
    timeoutMillis: Int64
): Result<ToolResult> {
    let value = match (client.request(
        context.runId,
        "textDocument/hover",
        lspTextPositionParams(path, position),
        timeoutMillis
    )) {
        case Result.Ok(result) => result
        case Result.Err(error) => return Result.Err(error)
    }
    let content = lspHoverText(value)
    Result.Ok(lspToolResult(
        call,
        "hover",
        if (content == "") { "No hover information" } else { content },
        true,
        server: client.spec.name
    ))
}

func executeDocumentSymbols(
    context: ToolInvocationContext,
    call: ToolCall,
    client: LspClient,
    path: String,
    timeoutMillis: Int64
): Result<ToolResult> {
    let value = match (client.request(
        context.runId,
        "textDocument/documentSymbol",
        lspObject([
            JsonObjectEntry(
                "textDocument",
                lspObject([
                    JsonObjectEntry(
                        "uri",
                        jsonString(lspFileUri(path))
                    )
                ])
            )
        ]),
        timeoutMillis
    )) {
        case Result.Ok(result) => result
        case Result.Err(error) => return Result.Err(error)
    }
    let lines = ArrayList<String>()
    appendLspSymbols(lines, value, 0)
    Result.Ok(lspToolResult(
        call,
        "symbols",
        if (lines.isEmpty()) {
            "No symbols found"
        } else {
            "Symbols in " + lspRelative(path, client.root) + ":\n" +
                joinLspStrings(lines.toArray(), "\n")
        },
        true,
        server: client.spec.name
    ))
}

func executeLspDiagnostics(
    context: ToolInvocationContext,
    call: ToolCall,
    path: String,
    client: LspClient,
    timeoutMillis: Int64
): Result<ToolResult> {
    let values = match (client.waitForDiagnostics(
        context.runId,
        path,
        timeoutMillis
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (values.isEmpty()) {
        return Result.Ok(lspToolResult(
            call,
            "diagnostics",
            "OK",
            true,
            server: client.spec.name
        ))
    }
    let lines = ArrayList<String>()
    var errors: Int64 = 0
    var warnings: Int64 = 0
    for (value in values) {
        let severity = lspJsonInteger(value, "severity", 1)
        if (severity == 1) { errors += 1 }
        if (severity == 2) { warnings += 1 }
        lines.add(formatLspDiagnostic(
            value,
            lspRelative(path, client.root)
        ))
    }
    Result.Ok(lspToolResult(
        call,
        "diagnostics",
        errors.toString() + " error" +
            if (errors == 1) { "" } else { "s" } + ", " +
            warnings.toString() + " warning" +
            if (warnings == 1) { "" } else { "s" } + ":\n" +
            joinLspStrings(lines.toArray(), "\n"),
        true,
        server: client.spec.name
    ))
}

func executeRawLspRequest(
    context: ToolInvocationContext,
    call: ToolCall,
    path: String,
    client: LspClient,
    timeoutMillis: Int64
): Result<ToolResult> {
    let method = optionalString(call, "query", "").trimAscii()
    if (method == "") {
        return invalidArgument(
            call,
            "query",
            "action=request requires query to specify the LSP method"
        )
    }
    let payload = optionalString(call, "payload", "")
    let params = if (payload != "") {
        try {
            parseUnifiedJson(payload, maxBytes: 1048576, maxDepth: 64)
        } catch (error: Exception) {
            return invalidArgument(
                call,
                "payload",
                "invalid JSON in payload: " + error.message
            )
        }
    } else {
        lspObject([
            JsonObjectEntry(
                "textDocument",
                lspObject([
                    JsonObjectEntry(
                        "uri",
                        jsonString(lspFileUri(path))
                    )
                ])
            )
        ])
    }
    let value = match (client.request(
        context.runId,
        method,
        params,
        timeoutMillis,
        allowServerEdits: true
    )) {
        case Result.Ok(result) => result
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(lspToolResult(
        call,
        "request",
        client.spec.name + " ← " + method + ":\n" + value.stringify(),
        true,
        server: client.spec.name
    ))
}

func executeLspRename(
    context: ToolInvocationContext,
    call: ToolCall,
    workspace: LocalWorkspace,
    client: LspClient,
    path: String,
    position: LspPosition,
    timeoutMillis: Int64
): Result<ToolResult> {
    let newName = optionalString(call, "new_name", "").trimAscii()
    if (newName == "") {
        return invalidArgument(
            call,
            "new_name",
            "new_name parameter required for rename"
        )
    }
    match (client.waitForProjectReady(
        context.runId,
        timeoutMillis
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let params = lspTextPositionParams(path, position)
    params.put("newName", jsonString(newName))
    let edit = match (client.request(
        context.runId,
        "textDocument/rename",
        params,
        timeoutMillis,
        allowServerEdits: optionalBoolean(call, "apply", true)
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let plan = match (planLspWorkspaceEdit(workspace, edit)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (!optionalBoolean(call, "apply", true)) {
        return Result.Ok(lspToolResult(
            call,
            "rename",
            "Rename preview:\n" + renderLspEditPlan(plan),
            true,
            server: client.spec.name
        ))
    }
    let applied = match (applyLspEditPlan(
        workspace,
        context,
        call.callId,
        plan
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(lspToolResult(
        call,
        "rename",
        "Applied rename:\n" + applied,
        true,
        server: client.spec.name
    ))
}

func executeLspCodeActions(
    context: ToolInvocationContext,
    call: ToolCall,
    workspace: LocalWorkspace,
    client: LspClient,
    path: String,
    position: LspPosition,
    timeoutMillis: Int64
): Result<ToolResult> {
    let params = lspObject([
        JsonObjectEntry(
            "textDocument",
            lspObject([
                JsonObjectEntry(
                    "uri",
                    jsonString(lspFileUri(path))
                )
            ])
        ),
        JsonObjectEntry(
            "range",
            lspObject([
                JsonObjectEntry("start", position.json()),
                JsonObjectEntry("end", position.json())
            ])
        ),
        JsonObjectEntry(
            "context",
            lspObject([
                JsonObjectEntry(
                    "diagnostics",
                    jsonArray(
                        client.diagnosticSnapshot(lspFileUri(path))
                    )
                ),
                JsonObjectEntry("triggerKind", jsonNumber("1"))
            ])
        )
    ])
    let response = match (client.request(
        context.runId,
        "textDocument/codeAction",
        params,
        timeoutMillis,
        allowServerEdits: optionalBoolean(call, "apply", false)
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let actions: Array<JsonNode> = if (
        response.unifiedKind == UnifiedJsonKind.List
    ) {
        response.items
    } else {
        []
    }
    if (actions.isEmpty()) {
        return Result.Ok(lspToolResult(
            call,
            "code_actions",
            "No code actions available",
            true,
            server: client.spec.name
        ))
    }
    let apply = optionalBoolean(call, "apply", false)
    let query = optionalString(call, "query", "").trimAscii()
    if (!apply) {
        let lines = ArrayList<String>()
        for (index in 0..actions.size) {
            lines.add(
                "  [" + index.toString() + "] " +
                    lspJsonText(actions[index], "title")
            )
        }
        return Result.Ok(lspToolResult(
            call,
            "code_actions",
            actions.size.toString() + " code action" +
                if (actions.size == 1) { ":\n" } else { "s:\n" } +
                joinLspStrings(lines.toArray(), "\n"),
            true,
            server: client.spec.name
        ))
    }
    if (query == "") {
        return invalidArgument(
            call,
            "query",
            "query parameter required when apply=true for code_actions"
        )
    }
    var selected: ?JsonNode = None
    try {
        let index = Int64.parse(query)
        if (index >= 0 && index < actions.size) {
            selected = Some(actions[index])
        }
    } catch (_: Exception) {
        let normalized = lspAsciiLower(query)
        for (action in actions where
             lspAsciiLower(lspJsonText(action, "title"))
                .contains(normalized)) {
            selected = Some(action)
            break
        }
    }
    let action = match (selected) {
        case Some(value) => value
        case None =>
            return invalidArgument(
                call,
                "query",
                "no code action matches: " + query
            )
    }
    var resolved = action
    if (action.field("edit").isNone() &&
        action.field("command").isNone() &&
        action.field("data").isSome()) {
        resolved = match (client.request(
            context.runId,
            "codeAction/resolve",
            action,
            timeoutMillis
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let summaries = ArrayList<String>()
    match (resolved.field("edit")) {
        case Some(edit) =>
            let plan = match (planLspWorkspaceEdit(workspace, edit)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let applied = match (applyLspEditPlan(
                workspace,
                context,
                call.callId,
                plan
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            summaries.add("  Workspace edit:\n" + applied)
        case None => ()
    }
    match (resolved.field("command")) {
        case Some(commandValue) =>
            let command = if (commandValue.unifiedKind == UnifiedJsonKind.Text) {
                commandValue.text
            } else {
                lspJsonText(commandValue, "command")
            }
            if (command != "") {
                let arguments = match (commandValue.field("arguments")) {
                    case Some(value) => value
                    case None => jsonArray([])
                }
                let _ = match (client.request(
                    context.runId,
                    "workspace/executeCommand",
                    lspObject([
                        JsonObjectEntry(
                            "command",
                            jsonString(command)
                        ),
                        JsonObjectEntry("arguments", arguments)
                    ]),
                    timeoutMillis,
                    allowServerEdits: true
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                summaries.add("  Executed command: " + command)
            }
        case None => ()
    }
    if (summaries.isEmpty()) {
        return Result.Ok(lspToolResult(
            call,
            "code_actions",
            "Action \"" + lspJsonText(resolved, "title") +
                "\" has no workspace edit or command to apply",
            false,
            server: client.spec.name
        ))
    }
    Result.Ok(lspToolResult(
        call,
        "code_actions",
        "Applied \"" + lspJsonText(resolved, "title") + "\":\n" +
            joinLspStrings(summaries.toArray(), "\n"),
        true,
        server: client.spec.name
    ))
}

func executeLspRenameFile(
    context: ToolInvocationContext,
    call: ToolCall,
    workspace: LocalWorkspace,
    runtime: LspRuntime,
    authoredSource: String,
    timeoutMillis: Int64
): Result<ToolResult> {
    let authoredDestination = optionalString(
        call,
        "new_name",
        ""
    ).trimAscii()
    if (authoredDestination == "") {
        return invalidArgument(
            call,
            "new_name",
            "rename_file requires both file and new_name"
        )
    }
    let source = match (workspace.resolve(
        authoredSource,
        allowDirectory: true
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let destinationRelative = match (lspWorkspaceRelativeAuthored(
        workspace,
        authoredDestination
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let destination = match (lspResolveOperationPath(
        workspace,
        destinationRelative,
        requireExisting: false
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (source == destination) {
        return invalidArgument(
            call,
            "new_name",
            "source and destination paths are identical"
        )
    }
    if (exists(Path(destination))) {
        return invalidArgument(
            call,
            "new_name",
            "destination already exists: " + authoredDestination
        )
    }
    let pairs = ArrayList<LspRenamePair>()
    match (collectLspRenamePairs(source, destination, pairs, 1000)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    if (pairs.isEmpty()) {
        return invalidArgument(call, "file", "no files to rename")
    }
    let client = match (runtime.clientFor(pairs[0].source)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let encodedPairs = ArrayList<JsonNode>()
    for (pair in pairs) {
        encodedPairs.add(lspObject([
            JsonObjectEntry(
                "oldUri",
                jsonString(lspFileUri(pair.source))
            ),
            JsonObjectEntry(
                "newUri",
                jsonString(lspFileUri(pair.destination))
            )
        ]))
    }
    let params = lspObject([
        JsonObjectEntry("files", jsonArray(encodedPairs.toArray()))
    ])
    let edit = match (client.request(
        context.runId,
        "workspace/willRenameFiles",
        params,
        timeoutMillis
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            if (error.kind == AgentErrorKind.Protocol &&
                error.message.contains("-32601")) {
                jsonNull()
            } else {
                return Result.Err(error)
            }
    }
    let plan = match (planLspWorkspaceEdit(workspace, edit)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (!optionalBoolean(call, "apply", true)) {
        return Result.Ok(lspToolResult(
            call,
            "rename_file",
                "Rename preview: " + authoredSource + " → " +
                authoredDestination + "\n" +
                if (plan.operations.isEmpty()) {
                    "  No LSP edits would be applied"
                } else {
                    renderLspEditPlan(plan)
                },
            true,
            server: client.spec.name
        ))
    }
    let applied = match (applyLspEditPlan(
        workspace,
        context,
        call.callId,
        plan,
        retainRollback: true
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let parent = Path(destination).parent
        if (!exists(parent)) { Directory.create(parent, recursive: true) }
        rename(source, to: destination)
    } catch (error: Exception) {
        let rollback = rollbackLspEditPlan(
            workspace,
            context,
            call.callId,
            plan
        )
        return match (rollback) {
            case Result.Ok(_) =>
                lspError<ToolResult>(
                    AgentErrorKind.Internal,
                    "tool.lsp_rename_file",
                    error.message
                )
            case Result.Err(rollbackError) =>
                lspError<ToolResult>(
                    AgentErrorKind.RecoveryRequired,
                    "tool.lsp_rename_file_recovery",
                    error.message + "; rollback failed: " +
                        rollbackError.message
                )
        }
    }
    finalizeLspEditPlan(plan)
    let _ = client.notify(
        "workspace/didRenameFiles",
        params
    )
    Result.Ok(lspToolResult(
        call,
        "rename_file",
        "Renamed " + authoredSource + " → " + authoredDestination +
            if (applied == "") { "" } else { "\n" + applied },
        true,
        server: client.spec.name
    ))
}

class LspRenamePair {
    let source: String
    let destination: String

    init(source: String, destination: String) {
        this.source = source
        this.destination = destination
    }
}

func collectLspRenamePairs(
    source: String,
    destination: String,
    result: ArrayList<LspRenamePair>,
    limit: Int64
): Result<Unit> {
    if (result.size >= limit) {
        return lspError<Unit>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_rename_file_limit",
            "directory contains more than " + limit.toString() +
                " files; rename in smaller batches"
        )
    }
    if (!FileInfo(Path(source)).isDirectory()) {
        result.add(LspRenamePair(source, destination))
        return Result.Ok(())
    }
    try {
        for (entry in Directory.readFrom(source)) {
            let childSource = Path(source).join(entry.name).toString()
            let childDestination = Path(destination)
                .join(entry.name).toString()
            match (collectLspRenamePairs(
                childSource,
                childDestination,
                result,
                limit
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    } catch (error: Exception) {
        lspError<Unit>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_rename_file_scan",
            error.message
        )
    }
}

class LspTextEdit {
    let start: Int64
    let end: Int64
    let text: String

    init(start: Int64, end: Int64, text: String) {
        this.start = start
        this.end = end
        this.text = text
    }
}

class LspEditOperation {
    let kind: String
    let path: String
    let destination: String
    let edits: JsonNode
    let overwrite: Bool
    let ignoreIfExists: Bool
    let recursive: Bool
    let ignoreIfNotExists: Bool

    init(
        kind: String,
        path: String,
        destination: String,
        edits: JsonNode,
        overwrite: Bool,
        ignoreIfExists: Bool,
        recursive: Bool,
        ignoreIfNotExists: Bool
    ) {
        this.kind = kind
        this.path = path
        this.destination = destination
        this.edits = edits
        this.overwrite = overwrite
        this.ignoreIfExists = ignoreIfExists
        this.recursive = recursive
        this.ignoreIfNotExists = ignoreIfNotExists
    }
}

class LspAppliedOperation {
    let kind: String
    let path: String
    let destination: String
    let before: String
    let after: String
    let backup: String
    let existed: Bool

    init(
        kind: String,
        path: String,
        destination: String,
        before: String,
        after: String,
        backup: String,
        existed: Bool
    ) {
        this.kind = kind
        this.path = path
        this.destination = destination
        this.before = before
        this.after = after
        this.backup = backup
        this.existed = existed
    }
}

class LspEditPlan {
    let operations: Array<LspEditOperation>
    let applied = ArrayList<LspAppliedOperation>()

    init(operations: Array<LspEditOperation>) {
        this.operations = operations
    }
}

func planLspWorkspaceEdit(
    workspace: LocalWorkspace,
    value: JsonNode
): Result<LspEditPlan> {
    if (value.unifiedKind == UnifiedJsonKind.Null) {
        return Result.Ok(LspEditPlan([]))
    }
    let operations = ArrayList<LspEditOperation>()
    match (value.field("documentChanges")) {
        case Some(changes) =>
            if (changes.unifiedKind != UnifiedJsonKind.List) {
                return lspError<LspEditPlan>(
                    AgentErrorKind.Protocol,
                    "tool.lsp_edit_shape",
                    "documentChanges must be an array"
                )
            }
            for (change in changes.items) {
                match (change.field("textDocument")) {
                    case Some(textDocument) =>
                        let operation = match (lspTextOperation(
                            workspace,
                            lspJsonText(textDocument, "uri"),
                            match (change.field("edits")) {
                                case Some(entry) => entry
                                case None => jsonArray([])
                            }
                        )) {
                            case Result.Ok(value) => value
                            case Result.Err(error) => return Result.Err(error)
                        }
                        operations.add(operation)
                    case None =>
                        let operation = match (lspResourceOperation(
                            workspace,
                            change
                        )) {
                            case Result.Ok(value) => value
                            case Result.Err(error) => return Result.Err(error)
                        }
                        operations.add(operation)
                }
            }
        case None =>
            match (value.field("changes")) {
                case Some(changes) =>
                    if (changes.unifiedKind != UnifiedJsonKind.Object) {
                        return lspError<LspEditPlan>(
                            AgentErrorKind.Protocol,
                            "tool.lsp_edit_shape",
                            "changes must be an object"
                        )
                    }
                    for (member in changes.fields) {
                        let operation = match (lspTextOperation(
                            workspace,
                            member.name,
                            member.value
                        )) {
                            case Result.Ok(entry) => entry
                            case Result.Err(error) =>
                                return Result.Err(error)
                        }
                        operations.add(operation)
                    }
                case None => ()
            }
    }
    Result.Ok(LspEditPlan(operations.toArray()))
}

func lspTextOperation(
    workspace: LocalWorkspace,
    uri: String,
    edits: JsonNode
): Result<LspEditOperation> {
    let relative = match (lspWorkspaceRelativeUri(workspace, uri)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (edits.unifiedKind != UnifiedJsonKind.List) {
        return lspError<LspEditOperation>(
            AgentErrorKind.Protocol,
            "tool.lsp_edit_shape",
            "language server edits must be an array"
        )
    }
    for (edit in edits.items) {
        match (edit.field("range")) {
            case Some(_) => ()
            case None =>
                return lspError<LspEditOperation>(
                    AgentErrorKind.Protocol,
                    "tool.lsp_edit_shape",
                    "language server edit is missing a range"
                )
        }
        match (edit.field("newText")) {
            case Some(value) =>
                if (value.unifiedKind != UnifiedJsonKind.Text) {
                    return lspError<LspEditOperation>(
                        AgentErrorKind.Protocol,
                        "tool.lsp_edit_shape",
                        "language server newText must be a string"
                    )
                }
            case None =>
                return lspError<LspEditOperation>(
                    AgentErrorKind.Protocol,
                    "tool.lsp_edit_shape",
                    "language server edit is missing newText"
                )
        }
    }
    Result.Ok(LspEditOperation(
        "text",
        relative,
        "",
        edits,
        false,
        false,
        false,
        false
    ))
}

func lspResourceOperation(
    workspace: LocalWorkspace,
    value: JsonNode
): Result<LspEditOperation> {
    let kind = lspJsonText(value, "kind")
    let options = match (value.field("options")) {
        case Some(entry) => entry
        case None => jsonObject([])
    }
    if (kind == "create") {
        let path = match (lspWorkspaceRelativeUri(
            workspace,
            lspJsonText(value, "uri")
        )) {
            case Result.Ok(entry) => entry
            case Result.Err(error) => return Result.Err(error)
        }
        return Result.Ok(LspEditOperation(
            kind,
            path,
            "",
            jsonArray([]),
            lspJsonBoolean(options, "overwrite", false),
            lspJsonBoolean(options, "ignoreIfExists", false),
            false,
            false
        ))
    }
    if (kind == "rename") {
        let source = match (lspWorkspaceRelativeUri(
            workspace,
            lspJsonText(value, "oldUri")
        )) {
            case Result.Ok(entry) => entry
            case Result.Err(error) => return Result.Err(error)
        }
        let destination = match (lspWorkspaceRelativeUri(
            workspace,
            lspJsonText(value, "newUri")
        )) {
            case Result.Ok(entry) => entry
            case Result.Err(error) => return Result.Err(error)
        }
        return Result.Ok(LspEditOperation(
            kind,
            source,
            destination,
            jsonArray([]),
            lspJsonBoolean(options, "overwrite", false),
            lspJsonBoolean(options, "ignoreIfExists", false),
            false,
            false
        ))
    }
    if (kind == "delete") {
        let path = match (lspWorkspaceRelativeUri(
            workspace,
            lspJsonText(value, "uri")
        )) {
            case Result.Ok(entry) => entry
            case Result.Err(error) => return Result.Err(error)
        }
        return Result.Ok(LspEditOperation(
            kind,
            path,
            "",
            jsonArray([]),
            false,
            false,
            lspJsonBoolean(options, "recursive", false),
            lspJsonBoolean(options, "ignoreIfNotExists", false)
        ))
    }
    lspError<LspEditOperation>(
        AgentErrorKind.Protocol,
        "tool.lsp_resource_operation",
        "unsupported LSP resource operation: " +
            if (kind == "") { "<missing>" } else { kind }
    )
}

func orderLspTextEdits(
    source: Array<LspTextEdit>
): Array<LspTextEdit> {
    let result = ArrayList<LspTextEdit>()
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

func applyLspEditPlan(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    plan: LspEditPlan,
    retainRollback!: Bool = false
): Result<String> {
    if (plan.operations.isEmpty()) { return Result.Ok("  No edits") }
    plan.applied.clear()
    for (index in 0..plan.operations.size) {
        let applied = match (applyLspOperation(
            workspace,
            context,
            callId,
            index,
            plan.operations[index]
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return match (rollbackLspEditPlan(
                    workspace,
                    context,
                    callId,
                    plan
                )) {
                    case Result.Ok(_) => Result.Err(error)
                    case Result.Err(rollbackError) =>
                        lspError<String>(
                            AgentErrorKind.RecoveryRequired,
                            "tool.lsp_workspace_edit_recovery",
                            error.message + "; rollback failed: " +
                                rollbackError.message
                        )
                }
        }
        plan.applied.add(applied)
    }
    if (!retainRollback) { finalizeLspEditPlan(plan) }
    Result.Ok(renderLspEditPlan(plan))
}

func rollbackLspEditPlan(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    plan: LspEditPlan
): Result<Unit> {
    var index = plan.applied.size - 1
    while (index >= 0) {
        let applied = plan.applied[index]
        let result = rollbackLspOperation(
            workspace,
            context,
            callId,
            index,
            applied
        )
        match (result) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        index -= 1
    }
    plan.applied.clear()
    Result.Ok(())
}

func renderLspEditPlan(plan: LspEditPlan): String {
    let lines = ArrayList<String>()
    for (operation in plan.operations) {
        match (operation.kind) {
            case "text" =>
                lines.add(
                    "  " + operation.path + ": " +
                        operation.edits.items.size.toString() +
                        if (operation.edits.items.size == 1) {
                            " edit"
                        } else {
                            " edits"
                        }
                )
            case "create" => lines.add("  create " + operation.path)
            case "rename" =>
                lines.add(
                    "  rename " + operation.path + " → " +
                        operation.destination
                )
            case "delete" => lines.add("  delete " + operation.path)
            case _ => ()
        }
    }
    if (lines.isEmpty()) { "  No edits" } else {
        joinLspStrings(lines.toArray(), "\n")
    }
}

func applyLspOperation(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    index: Int64,
    operation: LspEditOperation
): Result<LspAppliedOperation> {
    match (operation.kind) {
        case "text" =>
            applyLspTextOperation(
                workspace,
                context,
                callId,
                index,
                operation
            )
        case "create" =>
            applyLspCreateOperation(
                workspace,
                context,
                callId,
                index,
                operation
            )
        case "rename" =>
            applyLspRenameOperation(
                workspace,
                context,
                callId,
                index,
                operation
            )
        case "delete" =>
            applyLspDeleteOperation(
                workspace,
                context,
                callId,
                index,
                operation
            )
        case _ =>
            lspError<LspAppliedOperation>(
                AgentErrorKind.Protocol,
                "tool.lsp_resource_operation",
                "unsupported planned LSP operation: " + operation.kind
            )
    }
}

func applyLspTextOperation(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    index: Int64,
    operation: LspEditOperation
): Result<LspAppliedOperation> {
    let absolute = match (lspResolveOperationPath(
        workspace,
        operation.path,
        requireExisting: true
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let before = try {
        String.fromUtf8(File.readFrom(absolute))
    } catch (error: Exception) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_file_read",
            error.message
        )
    }
    let after = match (applyLspTextEditsInMemory(
        before,
        operation.edits,
        operation.path
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (workspace.commit(WorkspaceMutation(
        OperationId(lspOperationId(context, callId, index)),
        operation.path,
        before,
        after
    ))) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(LspAppliedOperation(
        "text",
        operation.path,
        "",
        before,
        after,
        "",
        true
    ))
}

func applyLspCreateOperation(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    index: Int64,
    operation: LspEditOperation
): Result<LspAppliedOperation> {
    let absolute = match (lspResolveOperationPath(
        workspace,
        operation.path,
        requireExisting: false
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let existed = exists(Path(absolute))
    if (existed && operation.ignoreIfExists) {
        return Result.Ok(lspNoopApplied())
    }
    if (existed && !operation.overwrite) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.Conflict,
            "tool.lsp_create_exists",
            "cannot create existing path: " + operation.path
        )
    }
    if (existed && FileInfo(Path(absolute)).isDirectory()) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_create_directory",
            "cannot overwrite a directory with a file: " + operation.path
        )
    }
    let before = if (existed) {
        try {
            String.fromUtf8(File.readFrom(absolute))
        } catch (error: Exception) {
            return lspError<LspAppliedOperation>(
                AgentErrorKind.InvalidInput,
                "tool.lsp_file_read",
                error.message
            )
        }
    } else {
        ""
    }
    match (workspace.commit(WorkspaceMutation(
        OperationId(lspOperationId(context, callId, index)),
        operation.path,
        before,
        ""
    ))) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(LspAppliedOperation(
        "create",
        operation.path,
        "",
        before,
        "",
        "",
        existed
    ))
}

func applyLspRenameOperation(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    index: Int64,
    operation: LspEditOperation
): Result<LspAppliedOperation> {
    let source = match (lspResolveOperationPath(
        workspace,
        operation.path,
        requireExisting: true
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let destination = match (lspResolveOperationPath(
        workspace,
        operation.destination,
        requireExisting: false
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (source == destination) { return Result.Ok(lspNoopApplied()) }
    let destinationExists = exists(Path(destination))
    if (destinationExists && operation.ignoreIfExists) {
        return Result.Ok(lspNoopApplied())
    }
    if (destinationExists && !operation.overwrite) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.Conflict,
            "tool.lsp_rename_exists",
            "rename destination already exists: " +
                operation.destination
        )
    }
    let backup = if (destinationExists) {
        lspBackupPath(
            destination,
            context,
            callId,
            index,
            "rename"
        )
    } else {
        ""
    }
    if (backup != "" && exists(Path(backup))) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.Conflict,
            "tool.lsp_backup_exists",
            "temporary LSP backup already exists"
        )
    }
    try {
        let parent = Path(destination).parent
        if (!exists(parent)) { Directory.create(parent, recursive: true) }
        if (backup != "") { rename(destination, to: backup) }
        try {
            rename(source, to: destination)
        } catch (error: Exception) {
            if (backup != "" && exists(Path(backup))) {
                rename(backup, to: destination)
            }
            return lspError<LspAppliedOperation>(
                AgentErrorKind.Internal,
                "tool.lsp_rename",
                error.message
            )
        }
    } catch (error: Exception) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.Internal,
            "tool.lsp_rename",
            error.message
        )
    }
    Result.Ok(LspAppliedOperation(
        "rename",
        operation.path,
        operation.destination,
        "",
        "",
        backup,
        destinationExists
    ))
}

func applyLspDeleteOperation(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    index: Int64,
    operation: LspEditOperation
): Result<LspAppliedOperation> {
    let candidate = match (lspResolveOperationPath(
        workspace,
        operation.path,
        requireExisting: false
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (!exists(Path(candidate))) {
        if (operation.ignoreIfNotExists) {
            return Result.Ok(lspNoopApplied())
        }
        return lspError<LspAppliedOperation>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_delete_missing",
            "cannot delete missing path: " + operation.path
        )
    }
    if (FileInfo(Path(candidate)).isDirectory() &&
        !operation.recursive) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_delete_directory",
            "recursive=true is required to delete a directory"
        )
    }
    let backup = lspBackupPath(
        candidate,
        context,
        callId,
        index,
        "delete"
    )
    if (exists(Path(backup))) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.Conflict,
            "tool.lsp_backup_exists",
            "temporary LSP backup already exists"
        )
    }
    try {
        rename(candidate, to: backup)
    } catch (error: Exception) {
        return lspError<LspAppliedOperation>(
            AgentErrorKind.Internal,
            "tool.lsp_delete",
            error.message
        )
    }
    Result.Ok(LspAppliedOperation(
        "delete",
        operation.path,
        "",
        "",
        "",
        backup,
        true
    ))
}

func rollbackLspOperation(
    workspace: LocalWorkspace,
    context: ToolInvocationContext,
    callId: String,
    index: Int64,
    applied: LspAppliedOperation
): Result<Unit> {
    if (applied.kind == "noop") { return Result.Ok(()) }
    if (applied.kind == "text") {
        return match (workspace.commit(WorkspaceMutation(
            OperationId(
                "lsp-rollback-" +
                    lspOperationId(context, callId, index)
            ),
            applied.path,
            applied.after,
            applied.before
        ))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }
    if (applied.kind == "create") {
        let absolute = match (lspResolveOperationPath(
            workspace,
            applied.path,
            requireExisting: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!applied.existed) {
            try {
                let _ = removeIfExists(absolute, recursive: true)
                return Result.Ok(())
            } catch (error: Exception) {
                return lspError<Unit>(
                    AgentErrorKind.RecoveryRequired,
                    "tool.lsp_rollback_create",
                    error.message
                )
            }
        }
        let current = try {
            String.fromUtf8(File.readFrom(absolute))
        } catch (error: Exception) {
            return lspError<Unit>(
                AgentErrorKind.RecoveryRequired,
                "tool.lsp_rollback_create",
                error.message
            )
        }
        return match (workspace.commit(WorkspaceMutation(
            OperationId(
                "lsp-rollback-" +
                    lspOperationId(context, callId, index)
            ),
            applied.path,
            current,
            applied.before
        ))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }
    if (applied.kind == "rename") {
        let source = match (lspResolveOperationPath(
            workspace,
            applied.path,
            requireExisting: false
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let destination = match (lspResolveOperationPath(
            workspace,
            applied.destination,
            requireExisting: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            rename(destination, to: source)
            if (applied.backup != "" &&
                exists(Path(applied.backup))) {
                rename(applied.backup, to: destination)
            }
            return Result.Ok(())
        } catch (error: Exception) {
            return lspError<Unit>(
                AgentErrorKind.RecoveryRequired,
                "tool.lsp_rollback_rename",
                error.message
            )
        }
    }
    if (applied.kind == "delete") {
        let destination = match (lspResolveOperationPath(
            workspace,
            applied.path,
            requireExisting: false
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            rename(applied.backup, to: destination)
            return Result.Ok(())
        } catch (error: Exception) {
            return lspError<Unit>(
                AgentErrorKind.RecoveryRequired,
                "tool.lsp_rollback_delete",
                error.message
            )
        }
    }
    lspError<Unit>(
        AgentErrorKind.RecoveryRequired,
        "tool.lsp_rollback_unknown",
        "unknown applied LSP operation: " + applied.kind
    )
}

func finalizeLspEditPlan(plan: LspEditPlan): Unit {
    for (applied in plan.applied) {
        if (applied.backup != "") {
            try {
                let _ = removeIfExists(applied.backup, recursive: true)
            } catch (_: Exception) {}
        }
    }
    plan.applied.clear()
}

func applyLspTextEditsInMemory(
    content: String,
    edits: JsonNode,
    path: String
): Result<String> {
    let planned = ArrayList<LspTextEdit>()
    for (edit in edits.items) {
        let range = match (edit.field("range")) {
            case Some(value) => value
            case None =>
                return lspError<String>(
                    AgentErrorKind.Protocol,
                    "tool.lsp_edit_shape",
                    "language server edit is missing a range"
                )
        }
        let startPosition = match (range.field("start")) {
            case Some(value) => value
            case None => jsonObject([])
        }
        let endPosition = match (range.field("end")) {
            case Some(value) => value
            case None => jsonObject([])
        }
        let start = match (lspByteOffset(
            content,
            lspJsonInteger(startPosition, "line", 0),
            lspJsonInteger(startPosition, "character", 0)
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let end = match (lspByteOffset(
            content,
            lspJsonInteger(endPosition, "line", 0),
            lspJsonInteger(endPosition, "character", 0)
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (end < start) {
            return lspError<String>(
                AgentErrorKind.Protocol,
                "tool.lsp_position",
                "language server returned an inverted edit range"
            )
        }
        planned.add(LspTextEdit(
            start,
            end,
            lspJsonText(edit, "newText")
        ))
    }
    let ordered = orderLspTextEdits(planned.toArray())
    var replacement = content
    let bytes = unsafe { content.rawData() }
    var previousStart = bytes.size
    for (edit in ordered) {
        if (edit.end > previousStart) {
            return lspError<String>(
                AgentErrorKind.Conflict,
                "tool.lsp_overlapping_edits",
                "language server returned overlapping edits for " + path
            )
        }
        replacement = replacement[..edit.start] + edit.text +
            replacement[edit.end..]
        previousStart = edit.start
    }
    Result.Ok(replacement)
}

func lspWorkspaceRelativeUri(
    workspace: LocalWorkspace,
    uri: String
): Result<String> {
    if (!uri.startsWith("file://")) {
        return lspError<String>(
            AgentErrorKind.Protocol,
            "tool.lsp_non_file_uri",
            "workspace edits require file:// URIs"
        )
    }
    let absolute = Path(lspUriPath(uri)).normalize().toString()
    let root = workspace.rootPath()
    if (absolute == root || !absolute.startsWith(root + "/")) {
        return lspError<String>(
            AgentErrorKind.PermissionDenied,
            "tool.lsp_edit_outside_workspace",
            "language server edit escapes the workspace: " + absolute
        )
    }
    Result.Ok(absolute[root.size + 1..])
}

func lspWorkspaceRelativeAuthored(
    workspace: LocalWorkspace,
    authored: String
): Result<String> {
    let root = workspace.rootPath()
    let absolute = if (authored.startsWith("/")) {
        Path(authored).normalize().toString()
    } else {
        Path(root).join(authored).normalize().toString()
    }
    if (absolute == root || !absolute.startsWith(root + "/")) {
        return lspError<String>(
            AgentErrorKind.PermissionDenied,
            "tool.lsp_edit_outside_workspace",
            "workspace path escapes the workspace: " + authored
        )
    }
    Result.Ok(absolute[root.size + 1..])
}

func lspResolveOperationPath(
    workspace: LocalWorkspace,
    relative: String,
    requireExisting!: Bool = false
): Result<String> {
    let root = workspace.rootPath()
    let candidate = Path(root).join(relative).normalize()
    let lexical = candidate.toString()
    if (lexical == root || !lexical.startsWith(root + "/")) {
        return lspError<String>(
            AgentErrorKind.PermissionDenied,
            "tool.lsp_edit_outside_workspace",
            "language server edit escapes the workspace: " + lexical
        )
    }
    if (exists(candidate)) {
        return workspace.resolve(relative, allowDirectory: true)
    }
    if (requireExisting) {
        return lspError<String>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_resource_missing",
            "workspace path does not exist: " + relative
        )
    }
    var ancestor = candidate.parent
    while (!exists(ancestor) && ancestor.toString() != "/") {
        ancestor = ancestor.parent
    }
    if (!exists(ancestor)) {
        return lspError<String>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_parent_missing",
            "no existing parent for workspace path: " + relative
        )
    }
    let resolvedAncestor = try {
        canonicalize(ancestor).toString()
    } catch (error: Exception) {
        return lspError<String>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_parent_resolve",
            error.message
        )
    }
    if (resolvedAncestor != root &&
        !resolvedAncestor.startsWith(root + "/")) {
        return lspError<String>(
            AgentErrorKind.PermissionDenied,
            "tool.lsp_edit_outside_workspace",
            "workspace parent resolves outside the workspace"
        )
    }
    Result.Ok(lexical)
}

func lspOperationId(
    context: ToolInvocationContext,
    callId: String,
    index: Int64
): String {
    "lsp-" + context.runId.value + "-" + callId + "-" +
        index.toString()
}

func lspBackupPath(
    path: String,
    context: ToolInvocationContext,
    callId: String,
    index: Int64,
    label: String
): String {
    path + ".axyndra-lsp-" + label + "-" +
        context.runId.value + "-" + callId + "-" + index.toString()
}

func lspNoopApplied(): LspAppliedOperation {
    LspAppliedOperation("noop", "", "", "", "", "", false)
}

func lspJsonBoolean(
    value: JsonNode,
    name: String,
    fallback: Bool
): Bool {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == UnifiedJsonKind.Boolean) {
                field.boolean
            } else {
                fallback
            }
        case None => fallback
    }
}

func lspByteOffset(
    content: String,
    targetLine: Int64,
    targetCharacter: Int64
): Result<Int64> {
    if (targetLine < 0 || targetCharacter < 0) {
        return lspError<Int64>(
            AgentErrorKind.Protocol,
            "tool.lsp_position",
            "language server returned a negative position"
        )
    }
    var line: Int64 = 0
    var character: Int64 = 0
    var offset: Int64 = 0
    for (rune in content.runes()) {
        if (line == targetLine && character == targetCharacter) {
            return Result.Ok(offset)
        }
        let text = rune.toString()
        let bytes = unsafe { text.rawData() }
        if (rune == r'\n') {
            if (line == targetLine) {
                return lspError<Int64>(
                    AgentErrorKind.Protocol,
                    "tool.lsp_position",
                    "language server character exceeds line length"
                )
            }
            line += 1
            character = 0
        } else {
            character += if (bytes.size == 4) { 2 } else { 1 }
        }
        offset += bytes.size
    }
    if (line == targetLine && character == targetCharacter) {
        Result.Ok(offset)
    } else {
        lspError<Int64>(
            AgentErrorKind.Protocol,
            "tool.lsp_position",
            "language server position exceeds file length"
        )
    }
}

func lspAsciiLower(value: String): String {
    let output = ArrayList<Byte>()
    for (byte in unsafe { value.rawData() }) {
        if (byte >= b'A' && byte <= b'Z') {
            output.add(byte + 32)
        } else {
            output.add(byte)
        }
    }
    String.fromUtf8(output.toArray())
}

func lspPosition(call: ToolCall, path: String): Result<LspPosition> {
    let authoredLine = optionalInteger(call, "line", 1)
    if (authoredLine < 1) {
        return invalidArgument(call, "line", "line must be positive")
    }
    let content = try {
        String.fromUtf8(File.readFrom(path))
    } catch (error: Exception) {
        return lspError<LspPosition>(
            AgentErrorKind.InvalidInput,
            "tool.lsp_file_read",
            error.message
        )
    }
    let lines = content.split("\n")
    if (authoredLine > lines.size) {
        return invalidArgument(call, "line", "line exceeds file length")
    }
    let line = lines[authoredLine - 1]
    let symbol = optionalString(call, "symbol", "")
    let character = if (symbol == "") {
        lspFirstContentColumn(line)
    } else {
        match (lspSymbolColumn(line, symbol)) {
            case Some(value) => value
            case None =>
                return invalidArgument(
                    call,
                    "symbol",
                    "symbol not found on line " + authoredLine.toString()
                )
        }
    }
    Result.Ok(LspPosition(authoredLine - 1, character))
}

func lspTextPositionParams(
    path: String,
    position: LspPosition
): JsonNode {
    lspObject([
        JsonObjectEntry(
            "textDocument",
            lspObject([
                JsonObjectEntry(
                    "uri",
                    jsonString(lspFileUri(path))
                )
            ])
        ),
        JsonObjectEntry("position", position.json())
    ])
}

class NormalizedLspLocation {
    let path: String
    let line: Int64
    let column: Int64

    init(path: String, line: Int64, column: Int64) {
        this.path = path
        this.line = line
        this.column = column
    }
}

func normalizeLspLocations(
    value: JsonNode
): Array<NormalizedLspLocation> {
    let source: Array<JsonNode> = if (
        value.unifiedKind == UnifiedJsonKind.List
    ) {
        value.items
    } else if (value.unifiedKind == UnifiedJsonKind.Object) {
        [value]
    } else {
        []
    }
    let result = ArrayList<NormalizedLspLocation>()
    for (item in source) {
        let uri = if (lspJsonText(item, "uri") != "") {
            lspJsonText(item, "uri")
        } else {
            lspJsonText(item, "targetUri")
        }
        let range = match (item.field("range")) {
            case Some(entry) => entry
            case None =>
                match (item.field("targetSelectionRange")) {
                    case Some(entry) => entry
                    case None => jsonObject([])
                }
        }
        let start = match (range.field("start")) {
            case Some(entry) => entry
            case None => jsonObject([])
        }
        if (uri != "") {
            result.add(NormalizedLspLocation(
                lspUriPath(uri),
                lspJsonInteger(start, "line", 0) + 1,
                lspJsonInteger(start, "character", 0) + 1
            ))
        }
    }
    result.toArray()
}

func formatLspLocation(
    value: NormalizedLspLocation,
    root: String
): String {
    let path = lspRelative(value.path, root)
    var context = ""
    if (value.path.startsWith(root + "/")) {
        try {
            let lines = String.fromUtf8(File.readFrom(value.path)).split("\n")
            if (value.line > 0 && value.line <= lines.size) {
                context = ": " + lines[value.line - 1].trimAscii()
            }
        } catch (_: Exception) {}
    }
    "  " + path + ":" + value.line.toString() + ":" +
        value.column.toString() + context
}

func lspHoverText(value: JsonNode): String {
    let contents = match (value.field("contents")) {
        case Some(entry) => entry
        case None => return ""
    }
    lspMarkedText(contents)
}

func lspMarkedText(value: JsonNode): String {
    match (value.unifiedKind) {
        case UnifiedJsonKind.Text => value.text
        case UnifiedJsonKind.List =>
            let values = ArrayList<String>()
            for (item in value.items) {
                let rendered = lspMarkedText(item)
                if (rendered != "") { values.add(rendered) }
            }
            joinLspStrings(values.toArray(), "\n\n")
        case UnifiedJsonKind.Object =>
            let content = lspJsonText(value, "value")
            if (content != "") { content } else { value.stringify() }
        case _ => ""
    }
}

func appendLspSymbols(
    output: ArrayList<String>,
    value: JsonNode,
    depth: Int64
): Unit {
    let items: Array<JsonNode> = if (
        value.unifiedKind == UnifiedJsonKind.List
    ) {
        value.items
    } else {
        []
    }
    for (item in items) {
        let range = match (item.field("selectionRange")) {
            case Some(entry) => entry
            case None =>
                match (item.field("location")) {
                    case Some(location) =>
                        match (location.field("range")) {
                            case Some(entry) => entry
                            case None => jsonObject([])
                        }
                    case None => jsonObject([])
                }
        }
        let start = match (range.field("start")) {
            case Some(entry) => entry
            case None => jsonObject([])
        }
        output.add(
            lspIndent(depth) + lspJsonText(item, "name") +
                " @ line " +
                (lspJsonInteger(start, "line", 0) + 1).toString()
        )
        match (item.field("children")) {
            case Some(children) =>
                appendLspSymbols(output, children, depth + 1)
            case None => ()
        }
    }
}

func appendWorkspaceLspSymbols(
    output: ArrayList<String>,
    value: JsonNode,
    root: String
): Unit {
    if (value.unifiedKind != UnifiedJsonKind.List) { return }
    for (item in value.items) {
        let location = match (item.field("location")) {
            case Some(entry) => entry
            case None => continue
        }
        let uri = lspJsonText(location, "uri")
        let range = match (location.field("range")) {
            case Some(entry) => entry
            case None => jsonObject([])
        }
        let start = match (range.field("start")) {
            case Some(entry) => entry
            case None => jsonObject([])
        }
        output.add(
            "  " + lspJsonText(item, "name") + " — " +
                lspRelative(lspUriPath(uri), root) + ":" +
                (lspJsonInteger(start, "line", 0) + 1).toString() +
                ":" +
                (lspJsonInteger(start, "character", 0) + 1).toString()
        )
    }
}

func formatLspDiagnostic(value: JsonNode, path: String): String {
    let range = match (value.field("range")) {
        case Some(entry) => entry
        case None => jsonObject([])
    }
    let start = match (range.field("start")) {
        case Some(entry) => entry
        case None => jsonObject([])
    }
    let severity = match (lspJsonInteger(value, "severity", 1)) {
        case 1 => "error"
        case 2 => "warning"
        case 3 => "info"
        case _ => "hint"
    }
    path + ":" +
        (lspJsonInteger(start, "line", 0) + 1).toString() + ":" +
        (lspJsonInteger(start, "character", 0) + 1).toString() +
        " [" + severity + "] " + lspJsonText(value, "message")
}

func lspSymbolColumn(line: String, authored: String): ?Int64 {
    var symbol = authored
    var occurrence: Int64 = 1
    match (authored.lastIndexOf("#")) {
        case Some(index) =>
            if (index > 0 && index + 1 < authored.size) {
                try {
                    let parsed = Int64.parse(authored[index + 1..])
                    if (parsed > 0) {
                        symbol = authored[..index]
                        occurrence = parsed
                    }
                } catch (_: Exception) {}
            }
        case None => ()
    }
    var offset: Int64 = 0
    var found: Int64 = 0
    while (offset <= line.size) {
        match (line.indexOf(symbol, offset)) {
            case Some(index) =>
                found += 1
                if (found == occurrence) {
                    return Some(lspUtf16Length(line[..index]))
                }
                offset = index + symbol.size
            case None => return None
        }
    }
    None
}

func lspFirstContentColumn(line: String): Int64 {
    var prefix = ""
    for (rune in line.runes()) {
        if (rune != r' ' && rune != r'\t') { break }
        prefix += rune.toString()
    }
    lspUtf16Length(prefix)
}

func lspUtf16Length(value: String): Int64 {
    var result: Int64 = 0
    for (rune in value.runes()) {
        let text = rune.toString()
        let bytes = unsafe { text.rawData() }
        result += if (bytes.size == 4) { 2 } else { 1 }
    }
    result
}

func lspRelative(path: String, root: String): String {
    if (path.startsWith(root + "/")) {
        path[root.size + 1..]
    } else {
        path
    }
}

func lspIndent(depth: Int64): String {
    var result = ""
    for (_ in 0..depth) { result += "  " }
    result
}

func lspToolResult(
    call: ToolCall,
    action: String,
    content: String,
    success: Bool,
    server!: String = ""
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(content)),
            ValueField("action", textValue(action)),
            ValueField("success", boolValue(success)),
            ValueField("server_name", textValue(server))
        ]),
        isError: !success
    )
}

func validLspAction(value: String): Bool {
    match (value) {
        case "diagnostics" | "definition" | "references" | "hover" |
            "symbols" | "rename" | "rename_file" | "code_actions" |
            "type_definition" | "implementation" | "status" | "reload" |
            "capabilities" | "request" => true
        case _ => false
    }
}
