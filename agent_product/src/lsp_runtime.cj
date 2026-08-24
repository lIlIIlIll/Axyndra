package agent_product

import json4cj.*
import lsp4cj as library
import process4cj.*
import agent_domain.*
import sandbox4cj.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*

class LspServerSpec {
    let name: String
    let executable: String
    let arguments: Array<String>
    let fileTypes: Array<String>
    let languageId: String
    let rootMarkers: Array<String>
    let initializationOptions: JsonValue
    let settings: JsonValue
    let networkAllowed: Bool
    let environment: Array<DirectEnvironmentBinding>

    init(
        name: String,
        executable: String,
        arguments: Array<String>,
        fileTypes: Array<String>,
        languageId: String,
        rootMarkers: Array<String>,
        initializationOptions: JsonValue,
        settings: JsonValue,
        networkAllowed!: Bool = false,
        environment!: Array<DirectEnvironmentBinding> = []
    ) {
        this.name = name
        this.executable = executable
        this.arguments = arguments
        this.fileTypes = fileTypes
        this.languageId = languageId
        this.rootMarkers = rootMarkers
        this.initializationOptions = initializationOptions
        this.settings = settings
        this.networkAllowed = networkAllowed
        this.environment = environment
    }
}

class OpenLspDocument {
    let path: String
    var content: String
    var version: Int64

    init(path: String, content: String, version!: Int64 = 1) {
        this.path = path
        this.content = content
        this.version = version
    }
}

class LspClient {
    let spec: LspServerSpec
    let root: String
    private let workspace: LocalWorkspace
    private var protocol: ?library.LspClient = None
    private let redactor: SecretRedactor
    private let stateLock = Mutex()
    private let documents = ArrayList<OpenLspDocument>()
    private let diagnostics = ArrayList<LspDiagnostics>()
    private let progressTokens = ArrayList<String>()
    private var closed = false
    private var currentRun = ""
    private var currentAllowsEdits = false
    private var projectProgressSeen = false
    private var projectReady = false
    private var capabilities = JsonValue.objectValue([])

    init(
        spec: LspServerSpec,
        workspace: LocalWorkspace,
        process: ManagedProcess,
        redactor: SecretRedactor
    ) {
        this.spec = spec
        this.workspace = workspace
        this.root = workspace.rootPath()
        this.redactor = redactor
        this.protocol = Some(library.LspClient(
            process,
            notificationHandler: { method: String, params: JsonValue =>
                handleServerNotification(method, params)
            },
            requestHandler: { method: String, params: JsonValue =>
                handleServerRequest(method, params)
            }
        ))
    }

    private func protocolClient(): library.LspClient {
        match (protocol) {
            case Some(value) => value
            case None => throw IllegalStateException("LSP protocol client is not initialized")
        }
    }

    func initialize(): Result<Unit> {
        let params = JsonValue.objectValue([])
        params.put("processId", JsonValue.nullValue())
        params.put("rootUri", JsonValue.stringValue(lspFileUri(root)))
        params.put("capabilities", lspClientCapabilities())
        params.put("clientInfo", lspObject([
            JsonField("name", JsonValue.stringValue("axyndra")),
            JsonField("version", JsonValue.stringValue("1"))
        ]))
        params.put("workspaceFolders", JsonValue.arrayValue([
            lspObject([
                JsonField("uri", JsonValue.stringValue(lspFileUri(root))),
                JsonField("name", JsonValue.stringValue(lspBaseName(root)))
            ])
        ]))
        if (spec.initializationOptions.kind != JsonKind.Null) {
            params.put(
                "initializationOptions",
                spec.initializationOptions
            )
        }
        let response = match (protocolClient().initialize(params, timeoutMillis: 30000)) {
            case library.LspResult.Ok(value) => value
            case library.LspResult.Err(error) => return Result.Err(productLspError(error))
        }
        match (response.field("capabilities")) {
            case Some(value) => capabilities = value
            case None => ()
        }
        Result.Ok(())
    }

    func request(
        runId: RunId,
        method: String,
        params: JsonValue,
        timeoutMillis: Int64,
        allowServerEdits!: Bool = false
    ): Result<JsonValue> {
        requestInternal(
            runId.value,
            method,
            params,
            timeoutMillis,
            allowServerEdits
        )
    }

    func open(
        runId: RunId,
        path: String,
        timeoutMillis: Int64
    ): Result<Unit> {
        let content = try {
            String.fromUtf8(File.readFrom(path))
        } catch (error: Exception) {
            return lspError<Unit>(
                AgentErrorKind.InvalidInput,
                "tool.lsp_file_read",
                error.message
            )
        }
        stateLock.lock()
        try {
            for (document in documents where document.path == path) {
                if (document.content == content) { return Result.Ok(()) }
                document.version += 1
                document.content = content
                clearDiagnostics(lspFileUri(path))
                return notify(
                    "textDocument/didChange",
                    lspObject([
                        JsonField(
                            "textDocument",
                            lspObject([
                                JsonField(
                                    "uri",
                                    JsonValue.stringValue(lspFileUri(path))
                                ),
                                JsonField(
                                    "version",
                                    JsonValue.numberValue(
                                        document.version.toString()
                                    )
                                )
                            ])
                        ),
                        JsonField(
                            "contentChanges",
                            JsonValue.arrayValue([
                                lspObject([
                                    JsonField(
                                        "text",
                                        JsonValue.stringValue(content)
                                    )
                                ])
                            ])
                        )
                    ])
                )
            }
            documents.add(OpenLspDocument(path, content))
            clearDiagnostics(lspFileUri(path))
        } finally {
            stateLock.unlock()
        }
        let _ = runId
        let _ = timeoutMillis
        notify(
            "textDocument/didOpen",
            lspObject([
                JsonField(
                    "textDocument",
                    lspObject([
                        JsonField(
                            "uri",
                            JsonValue.stringValue(lspFileUri(path))
                        ),
                        JsonField(
                            "languageId",
                            JsonValue.stringValue(
                                if (spec.languageId == "") {
                                    lspLanguageId(path)
                                } else {
                                    spec.languageId
                                }
                            )
                        ),
                        JsonField("version", JsonValue.numberValue("1")),
                        JsonField(
                            "text",
                            JsonValue.stringValue(content)
                        )
                    ])
                )
            ])
        )
    }

    func diagnosticSnapshot(uri: String): Array<JsonValue> {
        stateLock.lock()
        try {
            for (value in diagnostics where value.uri == uri) {
                return value.values
            }
            []
        } finally {
            stateLock.unlock()
        }
    }

    func waitForDiagnostics(
        runId: RunId,
        path: String,
        timeoutMillis: Int64
    ): Result<Array<JsonValue>> {
        let uri = lspFileUri(path)
        let deadline = lspNowMillis() + timeoutMillis
        while (lspNowMillis() < deadline) {
            match (publishedDiagnostics(uri)) {
                case Some(values) => return Result.Ok(values)
                case None => ()
            }

            // Push-diagnostic servers may publish after the response to the
            // request that opened/indexed the file. Sending another harmless
            // request keeps the protocol reader active so those queued
            // notifications are consumed before we accept an empty result.
            let remaining = deadline - lspNowMillis()
            if (remaining <= 0) { break }
            let requestTimeout = min(remaining, 1000)
            match (request(
                runId,
                "textDocument/hover",
                lspObject([
                    JsonField(
                        "textDocument",
                        lspObject([
                            JsonField(
                                "uri",
                                JsonValue.stringValue(uri)
                            )
                        ])
                    ),
                    JsonField(
                        "position",
                        lspObject([
                            JsonField(
                                "line",
                                JsonValue.numberValue("0")
                            ),
                            JsonField(
                                "character",
                                JsonValue.numberValue("0")
                            )
                        ])
                    )
                ]),
                requestTimeout
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (publishedDiagnostics(uri)) {
                case Some(values) => return Result.Ok(values)
                case None => sleep(Duration.millisecond * 20)
            }
        }
        lspError<Array<JsonValue>>(
            AgentErrorKind.Timeout,
            "tool.lsp_diagnostics_timeout",
            "language server did not publish diagnostics for " +
                lspRelative(path, root) + " before the timeout"
        )
    }

    func waitForProjectReady(
        runId: RunId,
        timeoutMillis: Int64
    ): Result<Unit> {
        let budget = min(timeoutMillis, 15000)
        let deadline = lspNowMillis() + budget
        let noProgressDeadline = lspNowMillis() + 500
        while (lspNowMillis() < deadline) {
            stateLock.lock()
            let (ready, progressSeen) = try {
                (
                    projectReady ||
                        (projectProgressSeen && progressTokens.isEmpty()),
                    projectProgressSeen
                )
            } finally {
                stateLock.unlock()
            }
            if (ready) { return Result.Ok(()) }
            if (!progressSeen &&
                lspNowMillis() >= noProgressDeadline) {
                return Result.Ok(())
            }
            let remaining = deadline - lspNowMillis()
            if (remaining <= 0) { break }
            match (request(
                runId,
                "workspace/symbol",
                lspObject([
                    JsonField("query", JsonValue.stringValue(
                        "__axyndra_project_warmup__"
                    ))
                ]),
                min(remaining, 1000)
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    if (error.code != "tool.lsp_server_error") {
                        return Result.Err(error)
                    }
            }
            sleep(Duration.millisecond * 20)
        }
        // OMP treats project readiness as bounded warmup: servers that do not
        // expose progress still remain usable after the budget expires.
        Result.Ok(())
    }

    func serverCapabilities(): JsonValue { capabilities }

    func notify(method: String, params: JsonValue): Result<Unit> {
        mapLspResult(protocolClient().notify(method, params))
    }

    func cancel(runId: RunId): Bool {
        var shouldClose = false
        stateLock.lock()
        try {
            if (currentRun != runId.value) { return false }
            shouldClose = markClosedLocked()
        } finally {
            stateLock.unlock()
        }
        if (shouldClose) { let _ = protocolClient().close() }
        true
    }

    func close(): Unit {
        var shouldClose = false
        stateLock.lock()
        try { shouldClose = markClosedLocked() } finally { stateLock.unlock() }
        if (shouldClose) { let _ = protocolClient().close() }
    }

    func isAlive(): Bool {
        stateLock.lock()
        try { !closed } finally { stateLock.unlock() }
    }

    private func requestInternal(
        runId: String,
        method: String,
        params: JsonValue,
        timeoutMillis: Int64,
        allowServerEdits: Bool
    ): Result<JsonValue> {
        stateLock.lock()
        try {
            if (closed) {
                return lspError<JsonValue>(
                    AgentErrorKind.Transport,
                    "tool.lsp_client_closed",
                    "language server connection is closed"
                )
            }
            currentRun = runId
            currentAllowsEdits = allowServerEdits
        } finally {
            stateLock.unlock()
        }
        try {
            mapLspResult(protocolClient().request(method, params, timeoutMillis: timeoutMillis))
        } finally {
            stateLock.lock()
            try {
                currentRun = ""
                currentAllowsEdits = false
            } finally {
                stateLock.unlock()
            }
        }
    }

    private func handleServerNotification(method: String, params: JsonValue): Unit {
        if (method == "textDocument/publishDiagnostics") { storeDiagnostics(params) }
        else if (method == "$/progress") { storeProgress(params) }
    }

    private func handleServerRequest(method: String, params: JsonValue): library.LspResult<JsonValue> {
        let message = lspObject([JsonField("params", params)])
        if (method == "workspace/configuration") {
            library.LspResult.Ok(lspConfigurationResult(message, spec.settings))
        } else if (method == "workspace/workspaceFolders") {
            library.LspResult.Ok(JsonValue.arrayValue([lspObject([
                JsonField("uri", JsonValue.stringValue(lspFileUri(root))),
                JsonField("name", JsonValue.stringValue(lspBaseName(root)))
            ])]))
        } else if (method == "workspace/applyEdit") {
            library.LspResult.Ok(applyServerWorkspaceEdit(message))
        } else {
            library.LspResult.Err(library.LspError(
                library.LspErrorKind.Protocol,
                "lsp.method_not_found",
                "unsupported language server request: " + method
            ))
        }
    }

    private func storeDiagnostics(params: JsonValue): Unit {
        let uri = lspJsonText(params, "uri")
        let values: Array<JsonValue> = match (
            params.field("diagnostics")
        ) {
            case Some(value) =>
                if (value.kind == JsonKind.List) { value.items } else { [] }
            case None => []
        }
        stateLock.lock()
        try {
            for (existing in diagnostics where existing.uri == uri) {
                existing.values = values
                return
            }
            diagnostics.add(LspDiagnostics(uri, values))
        } finally {
            stateLock.unlock()
        }
    }

    private func storeProgress(params: JsonValue): Unit {
        let token = match (params.field("token")) {
            case Some(value) => value.stringify()
            case None => return
        }
        let kind = match (params.field("value")) {
            case Some(value) => lspJsonText(value, "kind")
            case None => ""
        }
        stateLock.lock()
        try {
            if (kind == "begin") {
                projectProgressSeen = true
                projectReady = false
                var found = false
                for (existing in progressTokens where existing == token) {
                    found = true
                }
                if (!found) { progressTokens.add(token) }
            } else if (kind == "end") {
                projectProgressSeen = true
                for (index in 0..progressTokens.size) {
                    if (progressTokens[index] == token) {
                        progressTokens.remove(at: index)
                        break
                    }
                }
                if (progressTokens.isEmpty()) { projectReady = true }
            }
        } finally {
            stateLock.unlock()
        }
    }

    private func applyServerWorkspaceEdit(
        message: JsonValue
    ): JsonValue {
        if (!currentAllowsEdits) {
            return lspObject([
                JsonField("applied", JsonValue.boolValue(false)),
                JsonField(
                    "failureReason",
                    JsonValue.stringValue(
                        "workspace/applyEdit is not allowed during a " +
                            "read-only LSP action"
                    )
                )
            ])
        }
        let edit = match (message.field("params")) {
            case Some(params) =>
                match (params.field("edit")) {
                    case Some(value) => value
                    case None =>
                        return lspObject([
                            JsonField(
                                "applied",
                                JsonValue.boolValue(false)
                            ),
                            JsonField(
                                "failureReason",
                                JsonValue.stringValue(
                                    "workspace/applyEdit is missing edit"
                                )
                            )
                        ])
                }
            case None =>
                return lspObject([
                    JsonField("applied", JsonValue.boolValue(false)),
                    JsonField(
                        "failureReason",
                        JsonValue.stringValue(
                            "workspace/applyEdit is missing params"
                        )
                    )
                ])
        }
        let plan = match (planLspWorkspaceEdit(workspace, edit)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return lspObject([
                    JsonField("applied", JsonValue.boolValue(false)),
                    JsonField(
                        "failureReason",
                        JsonValue.stringValue(error.message)
                    )
                ])
        }
        let run = if (currentRun == "") {
            "lsp-server-request"
        } else {
            currentRun
        }
        let context = ToolInvocationContext(
            RunId(run),
            SessionId("lsp-server-request"),
            CapabilitySet(values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite)
            ])
        )
        let requestId = match (message.field("id")) {
            case Some(value) => value.stringify()
            case None => "notification"
        }
        match (applyLspEditPlan(
            workspace,
            context,
            "server-" + requestId,
            plan
        )) {
            case Result.Ok(_) =>
                lspObject([
                    JsonField("applied", JsonValue.boolValue(true))
                ])
            case Result.Err(error) =>
                lspObject([
                    JsonField("applied", JsonValue.boolValue(false)),
                    JsonField(
                        "failureReason",
                        JsonValue.stringValue(error.message)
                    )
                ])
        }
    }

    private func publishedDiagnostics(uri: String): ?Array<JsonValue> {
        stateLock.lock()
        try {
            for (value in diagnostics where value.uri == uri) {
                return Some(value.values)
            }
            None
        } finally {
            stateLock.unlock()
        }
    }

    private func clearDiagnostics(uri: String): Unit {
        for (index in 0..diagnostics.size) {
            if (diagnostics[index].uri == uri) {
                diagnostics.remove(at: index)
                return
            }
        }
    }

    private func markClosedLocked(): Bool {
        if (closed) { return false }
        closed = true
        true
    }

}

func mapLspResult<T>(value: library.LspResult<T>): Result<T> {
    match (value) {
        case library.LspResult.Ok(found) => Result.Ok(found)
        case library.LspResult.Err(error) => Result.Err(productLspError(error))
    }
}

func productLspError(error: library.LspError): AgentError {
    let kind = match (error.kind) {
        case library.LspErrorKind.Cancelled => AgentErrorKind.Cancelled
        case library.LspErrorKind.Deadline => AgentErrorKind.Timeout
        case library.LspErrorKind.Transport => AgentErrorKind.Transport
        case _ => AgentErrorKind.Protocol
    }
    AgentError(kind, "tool." + error.code, error.message)
}

func lspNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

class LspDiagnostics {
    let uri: String
    var values: Array<JsonValue>

    init(uri: String, values: Array<JsonValue>) {
        this.uri = uri
        this.values = values
    }
}

class LspRuntime {
    private let workspace: LocalWorkspace
    private let sandboxEnabled: Bool
    private let allowUnsafeTestBypass: Bool
    private let lock = Mutex()
    private let clients = ArrayList<LspClient>()
    private var specs: Array<LspServerSpec>

    init(
        workspace: LocalWorkspace,
        sandboxEnabled!: Bool = false,
        allowUnsafeTestBypass!: Bool = false
    ) {
        this.workspace = workspace
        this.sandboxEnabled = sandboxEnabled
        this.allowUnsafeTestBypass = allowUnsafeTestBypass
        this.specs = loadLspServerSpecs(workspace.rootPath())
    }

    func clientFor(path: String): Result<LspClient> {
        let spec = match (serverFor(path)) {
            case Some(value) => value
            case None =>
                return lspError<LspClient>(
                    AgentErrorKind.Configuration,
                    "tool.lsp_server_missing",
                    "No language server found for this file"
                )
        }
        lock.lock()
        try {
            for (client in clients where
                 client.spec.name == spec.name &&
                 client.root == workspace.rootPath() &&
                 client.isAlive()) {
                return Result.Ok(client)
            }
            let client = match (startLspClient(
                spec,
                workspace,
                sandboxEnabled,
                allowUnsafeTestBypass
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            clients.add(client)
            Result.Ok(client)
        } finally {
            lock.unlock()
        }
    }

    func status(): String {
        let configured = specs
        if (configured.isEmpty()) {
            return "No language servers configured for this project"
        }
        lock.lock()
        try {
            let labels = ArrayList<String>()
            for (spec in configured) {
                var ready = false
                for (client in clients where
                     client.spec.name == spec.name && client.isAlive()) {
                    ready = true
                }
                labels.add(
                    spec.name + if (ready) {
                        " (ready)"
                    } else {
                        " (configured, not started)"
                    }
                )
            }
            "Language servers: " + joinLspStrings(
                labels.toArray(),
                ", "
            )
        } finally {
            lock.unlock()
        }
    }

    func workspaceClients(): Array<LspClient> {
        let files = ArrayList<String>()
        collectLspProbeFiles(
            workspace.rootPath(),
            files,
            2000,
            specs
        )
        let result = ArrayList<LspClient>()
        for (path in files) {
            let client = match (clientFor(path)) {
                case Result.Ok(value) => value
                case Result.Err(_) => continue
            }
            var found = false
            for (existing in result where
                 existing.spec.name == client.spec.name) {
                found = true
            }
            if (!found) { result.add(client) }
        }
        result.toArray()
    }

    func reloadAll(): Array<LspClient> {
        lock.lock()
        try {
            for (client in clients) { client.close() }
            specs = loadLspServerSpecs(workspace.rootPath())
        } finally {
            lock.unlock()
        }
        workspaceClients()
    }

    func probeFiles(limit: Int64): Array<String> {
        let files = ArrayList<String>()
        collectLspProbeFiles(
            workspace.rootPath(),
            files,
            limit,
            specs
        )
        files.toArray()
    }

    func cancel(runId: RunId): Result<Unit> {
        lock.lock()
        try {
            for (client in clients) {
                let _ = client.cancel(runId)
            }
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    private func serverFor(path: String): ?LspServerSpec {
        for (spec in specs where lspSpecSupports(spec, path)) {
            return Some(spec)
        }
        None
    }
}

func collectLspProbeFiles(
    path: String,
    result: ArrayList<String>,
    limit: Int64,
    specs: Array<LspServerSpec>
): Unit {
    if (result.size >= limit) { return }
    try {
        for (entry in Directory.readFrom(path)) {
            if (result.size >= limit) { return }
            if (entry.name == ".git" || entry.name == "target" ||
                entry.name == "node_modules") {
                continue
            }
            let child = Path(path).join(entry.name).toString()
            if (FileInfo(Path(child)).isDirectory()) {
                collectLspProbeFiles(child, result, limit, specs)
            } else {
                for (spec in specs where lspSpecSupports(spec, child)) {
                    result.add(child)
                    break
                }
            }
        }
    } catch (_: Exception) {}
}

func startLspClient(
    spec: LspServerSpec,
    workspace: LocalWorkspace,
    sandboxEnabled: Bool,
    allowUnsafeTestBypass: Bool
): Result<LspClient> {
    let opened = match (launchDirectPersistentProcess(
        workspace.rootPath(),
        sandboxEnabled,
        allowUnsafeTestBypass,
        FilesystemIsolationMode.WorkspaceReadOnly,
        spec.networkAllowed,
        spec.executable,
        spec.arguments,
        workspace.rootPath(),
        bindings: spec.environment,
        errorCode: "tool.lsp_start"
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let client = LspClient(
            spec,
            workspace,
            opened.process,
            opened.redactor
        )
        match (client.initialize()) {
            case Result.Ok(_) => Result.Ok(client)
            case Result.Err(error) =>
                client.close()
                Result.Err(error)
        }
    } catch (error: Exception) {
        lspError<LspClient>(
            AgentErrorKind.Configuration,
            "tool.lsp_start",
            opened.redactor.redact(
                "failed to start " + spec.name + ": " + error.message
            )
        )
    }
}

func lspConfigurationResult(
    message: JsonValue,
    settings: JsonValue
): JsonValue {
    let count = match (message.field("params")) {
        case Some(params) =>
            match (params.field("items")) {
                case Some(items) =>
                    if (items.kind == JsonKind.List) {
                        items.items.size
                    } else {
                        0
                    }
                case None => 0
            }
        case None => 0
    }
    let result = ArrayList<JsonValue>()
    for (_ in 0..count) {
        result.add(if (settings.kind == JsonKind.Null) {
            JsonValue.objectValue([])
        } else {
            settings
        })
    }
    JsonValue.arrayValue(result.toArray())
}

func lspClientCapabilities(): JsonValue {
    lspObject([
        JsonField(
            "workspace",
            lspObject([
                JsonField("workspaceFolders", JsonValue.boolValue(true)),
                JsonField("applyEdit", JsonValue.boolValue(true)),
                JsonField(
                    "workspaceEdit",
                    lspObject([
                        JsonField(
                            "documentChanges",
                            JsonValue.boolValue(true)
                        ),
                        JsonField(
                            "resourceOperations",
                            JsonValue.arrayValue([
                                JsonValue.stringValue("create"),
                                JsonValue.stringValue("rename"),
                                JsonValue.stringValue("delete")
                            ])
                        ),
                        JsonField(
                            "failureHandling",
                            JsonValue.stringValue(
                                "textOnlyTransactional"
                            )
                        )
                    ])
                ),
                JsonField(
                    "fileOperations",
                    lspObject([
                        JsonField(
                            "willRename",
                            JsonValue.boolValue(true)
                        ),
                        JsonField(
                            "didRename",
                            JsonValue.boolValue(true)
                        )
                    ])
                )
            ])
        ),
        JsonField(
            "textDocument",
            lspObject([
                JsonField("hover", JsonValue.objectValue([])),
                JsonField("definition", JsonValue.objectValue([])),
                JsonField("references", JsonValue.objectValue([])),
                JsonField("documentSymbol", JsonValue.objectValue([])),
                JsonField(
                    "publishDiagnostics",
                    lspObject([
                        JsonField(
                            "relatedInformation",
                            JsonValue.boolValue(true)
                        )
                    ])
                )
            ])
        )
    ])
}

func loadLspServerSpecs(root: String): Array<LspServerSpec> {
    let result = ArrayList<LspServerSpec>()
    if (exists(Path("/usr/bin/pyright-langserver"))) {
        result.add(LspServerSpec(
            "pyright",
            "/usr/bin/pyright-langserver",
            ["--stdio"],
            [".py", ".pyw"],
            "python",
            ["."],
            JsonValue.nullValue(),
            JsonValue.nullValue()
        ))
    }
    if (exists(Path("/usr/bin/clangd"))) {
        result.add(LspServerSpec(
            "clangd",
            "/usr/bin/clangd",
            [],
            [".c", ".h", ".cc", ".cpp", ".cxx", ".hpp"],
            "",
            ["."],
            JsonValue.nullValue(),
            JsonValue.nullValue()
        ))
    }
    if (exists(Path("/usr/lib/rustup/bin/rust-analyzer"))) {
        result.add(LspServerSpec(
            "rust-analyzer",
            "/usr/lib/rustup/bin/rust-analyzer",
            [],
            [".rs"],
            "rust",
            ["."],
            JsonValue.nullValue(),
            JsonValue.nullValue()
        ))
    }
    let paths = [
        Path(root).join(".omp").join("lsp.json").toString(),
        Path(root).join(".lsp.json").toString(),
        Path(root).join("lsp.json").toString()
    ]
    for (path in paths where exists(Path(path))) {
        let configured = loadLspConfigFile(root, path)
        for (spec in configured) {
            var replacement: Int64 = -1
            for (index in 0..result.size
                 where result[index].name == spec.name) {
                replacement = index
            }
            if (replacement >= 0) {
                result.remove(at: replacement)
            }
            result.add(spec)
        }
    }
    result.toArray()
}

func loadLspConfigFile(
    root: String,
    path: String
): Array<LspServerSpec> {
    let result = ArrayList<LspServerSpec>()
    let document = try {
        parseJson(
            String.fromUtf8(File.readFrom(path)),
            maxBytes: 1048576,
            maxDepth: 64
        )
    } catch (_: Exception) {
        return []
    }
    let servers = match (document.field("servers")) {
        case Some(value) => value
        case None => document
    }
    if (servers.kind != JsonKind.Object) { return [] }
    for (member in servers.members) {
        let config = member.value
        if (config.kind != JsonKind.Object ||
            lspJsonBooleanValue(config, "disabled", false)) {
            continue
        }
        let command = lspJsonText(config, "command")
        let fileTypes = lspJsonStringArray(config, "fileTypes")
        let rootMarkers = lspJsonStringArray(config, "rootMarkers")
        if (command == "" || fileTypes.isEmpty() ||
            rootMarkers.isEmpty() ||
            !lspRootMarkersMatch(root, rootMarkers)) {
            continue
        }
        let executable = if (
            command.startsWith("/") ||
            (!command.contains("/") && !command.startsWith("."))
        ) {
            command
        } else {
            Path(root).join(command).normalize().toString()
        }
        if (executable.startsWith("/") &&
            !exists(Path(executable))) {
            continue
        }
        let environment = match (lspJsonEnvironmentBindings(config)) {
            case Some(value) => value
            case None => continue
        }
        result.add(LspServerSpec(
            member.name,
            executable,
            lspJsonStringArray(config, "args"),
            fileTypes,
            lspJsonText(config, "languageId"),
            rootMarkers,
            match (config.field("initOptions")) {
                case Some(value) => value
                case None =>
                    match (config.field("initializationOptions")) {
                        case Some(value) => value
                        case None => JsonValue.nullValue()
                    }
            },
            match (config.field("settings")) {
                case Some(value) => value
                case None => JsonValue.nullValue()
            },
            networkAllowed: lspJsonBooleanValue(
                config,
                "network",
                false
            ),
            environment: environment
        ))
    }
    result.toArray()
}

func lspJsonEnvironmentBindings(
    value: JsonValue
): ?Array<DirectEnvironmentBinding> {
    let result = ArrayList<DirectEnvironmentBinding>()
    let targets = ArrayList<String>()
    for (section in ["env", "secretEnv"]) {
        match (value.field(section)) {
            case None => ()
            case Some(entries) =>
                if (entries.kind != JsonKind.Object) { return None }
                for (member in entries.members) {
                    if (member.value.kind != JsonKind.Text ||
                        member.name == "" || member.value.text == "" ||
                        directContains(targets, member.name)) {
                        return None
                    }
                    let binding = try {
                        DirectEnvironmentBinding(
                            member.name,
                            member.value.text,
                            secret: section == "secretEnv"
                        )
                    } catch (_: Exception) {
                        return None
                    }
                    targets.add(member.name)
                    result.add(binding)
                }
        }
    }
    Some(result.toArray())
}

func lspSpecSupports(spec: LspServerSpec, path: String): Bool {
    let extension = lspExtension(path)
    let fileName = lspBaseName(path)
    for (authored in spec.fileTypes) {
        let normalized = if (authored.startsWith(".")) {
            authored[1..]
        } else {
            authored
        }
        if (normalized == extension || authored == fileName) {
            return true
        }
    }
    false
}

func lspAdditionalCapabilitiesFor(
    workspace: LocalWorkspace,
    call: ToolCall
): Array<Capability> {
    if (optionalString(call, "action", "") == "status") { return [] }
    let required = ArrayList<Capability>()
    required.add(Capability(CapabilityKind.ProcessSpawn))
    let authored = optionalString(call, "file", "")
    let specs = loadLspServerSpecs(workspace.rootPath())
    if (authored == "*") {
        for (spec in specs where spec.networkAllowed) {
            required.add(Capability(CapabilityKind.NetworkAccess))
            break
        }
        return required.toArray()
    }
    let path = match (workspace.resolve(authored)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return required.toArray()
    }
    for (spec in specs where
         spec.networkAllowed && lspSpecSupports(spec, path)) {
        required.add(Capability(CapabilityKind.NetworkAccess))
        break
    }
    required.toArray()
}

func lspRootMarkersMatch(
    root: String,
    markers: Array<String>
): Bool {
    for (marker in markers) {
        if (marker == "." ||
            exists(Path(root).join(marker))) {
            return true
        }
    }
    false
}

func lspJsonStringArray(
    value: JsonValue,
    name: String
): Array<String> {
    let result = ArrayList<String>()
    match (value.field(name)) {
        case Some(items) =>
            if (items.kind == JsonKind.List) {
                for (item in items.items where
                     item.kind == JsonKind.Text &&
                     item.text != "") {
                    result.add(item.text)
                }
            }
        case None => ()
    }
    result.toArray()
}

func lspJsonBooleanValue(
    value: JsonValue,
    name: String,
    fallback: Bool
): Bool {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == JsonKind.Boolean) {
                field.boolean
            } else {
                fallback
            }
        case None => fallback
    }
}

func lspLanguageId(path: String): String {
    match (lspExtension(path)) {
        case "py" | "pyw" => "python"
        case "c" | "h" => "c"
        case "cc" | "cpp" | "cxx" | "hpp" => "cpp"
        case "rs" => "rust"
        case value => value
    }
}

func lspExtension(path: String): String {
    let name = lspBaseName(path)
    match (name.lastIndexOf(".")) {
        case Some(index) =>
            if (index + 1 < name.size) {
                name[index + 1..]
            } else {
                ""
            }
        case None => ""
    }
}

func lspBaseName(path: String): String {
    match (path.lastIndexOf("/")) {
        case Some(index) => path[index + 1..]
        case None => path
    }
}

func lspFileUri(path: String): String {
    "file://" + path
        .replace("%", "%25")
        .replace(" ", "%20")
        .replace("#", "%23")
}

func lspUriPath(uri: String): String {
    if (!uri.startsWith("file://")) { return uri }
    uri[7..]
        .replace("%20", " ")
        .replace("%23", "#")
        .replace("%25", "%")
}

func lspObject(values: Array<JsonField>): JsonValue {
    JsonValue.objectValue(values)
}

func lspJsonText(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == JsonKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func lspJsonInteger(
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

func joinLspStrings(values: Array<String>, separator: String): String {
    var result = ""
    for (value in values) {
        if (result != "") { result += separator }
        result += value
    }
    result
}

func lspError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}
