package agent_product

import json4cj.*
import dap4cj as library
import agent_domain.*
import process4cj.*
import sandbox4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*

class DapAdapterSpec {
    let name: String
    let executable: String
    let arguments: Array<String>
    let fileTypes: Array<String>
    let launchDefaults: JsonValue
    let attachDefaults: JsonValue
    let networkAllowed: Bool
    let environment: Array<DirectEnvironmentBinding>

    init(
        name: String,
        executable: String,
        arguments: Array<String>,
        fileTypes: Array<String>,
        launchDefaults: JsonValue,
        attachDefaults: JsonValue,
        networkAllowed!: Bool = false,
        environment!: Array<DirectEnvironmentBinding> = []
    ) {
        this.name = name
        this.executable = executable
        this.arguments = arguments
        this.fileTypes = fileTypes
        this.launchDefaults = launchDefaults
        this.attachDefaults = attachDefaults
        this.networkAllowed = networkAllowed
        this.environment = environment
    }
}

class DapClientSnapshot {
    let status: String
    let threadId: Int64
    let frameId: Int64
    let stopReason: String
    let frameName: String
    let sourcePath: String
    let line: Int64
    let column: Int64
    let instructionPointer: String
    let exitCode: ?Int64
    let initialized: Bool
    let outputBytes: Int64
    let outputTruncated: Bool

    init(
        status: String,
        threadId: Int64,
        frameId: Int64,
        stopReason: String,
        frameName: String,
        sourcePath: String,
        line: Int64,
        column: Int64,
        instructionPointer: String,
        exitCode: ?Int64,
        initialized: Bool,
        outputBytes: Int64,
        outputTruncated: Bool
    ) {
        this.status = status
        this.threadId = threadId
        this.frameId = frameId
        this.stopReason = stopReason
        this.frameName = frameName
        this.sourcePath = sourcePath
        this.line = line
        this.column = column
        this.instructionPointer = instructionPointer
        this.exitCode = exitCode
        this.initialized = initialized
        this.outputBytes = outputBytes
        this.outputTruncated = outputTruncated
    }
}

class DapClient {
    let adapter: DapAdapterSpec
    let cwd: String
    private let workspace: LocalWorkspace
    private let sandboxEnabled: Bool
    private let allowUnsafeTestBypass: Bool
    private var protocol: ?library.DapClient = None
    private let redactor: SecretRedactor
    private let stateLock = Mutex()
    private let debuggeeProcesses = ArrayList<ManagedProcess>()
    private var closed = false
    private var reaped = false
    private var transportError = ""
    private var status = "starting"
    private var initialized = false
    private var stopRevision: Int64 = 0
    private var threadId: Int64 = 0
    private var frameId: Int64 = 0
    private var stopReason = ""
    private var frameName = ""
    private var sourcePath = ""
    private var line: Int64 = 0
    private var column: Int64 = 0
    private var instructionPointer = ""
    private var exitCode: ?Int64 = None
    private var capabilities = JsonValue.objectValue([])
    private var output = ""
    private var outputBytes: Int64 = 0
    private var outputTruncated = false

    init(
        adapter: DapAdapterSpec,
        workspace: LocalWorkspace,
        cwd: String,
        process: ManagedProcess,
        redactor: SecretRedactor,
        sandboxEnabled: Bool,
        allowUnsafeTestBypass: Bool
    ) {
        this.adapter = adapter
        this.workspace = workspace
        this.cwd = cwd
        this.redactor = redactor
        this.sandboxEnabled = sandboxEnabled
        this.allowUnsafeTestBypass = allowUnsafeTestBypass
        this.protocol = Some(library.DapClient(
            process,
            eventHandler: { event: String, body: JsonValue => handleEvent(event, body) },
            reverseRequestHandler: { command: String, arguments: JsonValue =>
                handleReverseRequest(command, arguments)
            }
        ))
    }

    private func protocolClient(): library.DapClient {
        match (protocol) {
            case Some(value) => value
            case None => throw IllegalStateException("DAP protocol client is not initialized")
        }
    }

    func start(): Unit {}

    func initialize(
        runId: RunId,
        timeoutMillis: Int64
    ): Result<JsonValue> {
        let arguments = dapObject([
            JsonField("clientID", JsonValue.stringValue("axyndra")),
            JsonField("clientName", JsonValue.stringValue("axyndra")),
            JsonField(
                "adapterID",
                JsonValue.stringValue(adapter.name)
            ),
            JsonField("locale", JsonValue.stringValue("en-US")),
            JsonField("linesStartAt1", JsonValue.boolValue(true)),
            JsonField("columnsStartAt1", JsonValue.boolValue(true)),
            JsonField("pathFormat", JsonValue.stringValue("path")),
            JsonField(
                "supportsVariableType",
                JsonValue.boolValue(true)
            ),
            JsonField(
                "supportsVariablePaging",
                JsonValue.boolValue(true)
            ),
            JsonField(
                "supportsRunInTerminalRequest",
                JsonValue.boolValue(true)
            ),
            JsonField(
                "supportsMemoryReferences",
                JsonValue.boolValue(true)
            ),
            JsonField(
                "supportsProgressReporting",
                JsonValue.boolValue(true)
            ),
            JsonField(
                "supportsInvalidatedEvent",
                JsonValue.boolValue(true)
            )
        ])
        let _ = runId
        let result = mapDapResult(protocolClient().initialize(arguments, timeoutMillis: timeoutMillis))
        match (result) {
            case Result.Ok(value) =>
                stateLock.lock()
                try {
                    capabilities = value
                    status = "configuring"
                } finally {
                    stateLock.unlock()
                }
                Result.Ok(value)
            case Result.Err(error) => Result.Err(error)
        }
    }

    func request(
        runId: RunId,
        command: String,
        arguments: JsonValue,
        timeoutMillis: Int64
    ): Result<JsonValue> {
        let _ = runId
        let _ = command
        mapDapResult(protocolClient().request(command, arguments, timeoutMillis: timeoutMillis))
    }

    func beginRequest(
        command: String,
        arguments: JsonValue
    ): Result<Int64> {
        mapDapResult(protocolClient().beginRequest(command, arguments))
    }

    func waitResponse(
        runId: RunId,
        requestSequence: Int64,
        command: String,
        timeoutMillis: Int64
    ): Result<JsonValue> {
        let _ = runId
        let _ = command
        mapDapResult(protocolClient().waitResponse(requestSequence, timeoutMillis: timeoutMillis))
    }

    func waitInitialized(timeoutMillis: Int64): Result<Unit> {
        let deadline = dapNowMillis() + timeoutMillis
        while (dapNowMillis() < deadline) {
            stateLock.lock()
            let ready = try { initialized } finally {
                stateLock.unlock()
            }
            if (ready) { return Result.Ok(()) }
            if (!alive()) {
                return dapError<Unit>(
                    AgentErrorKind.Transport,
                    "tool.debug_session_closed",
                    debugTransportMessage()
                )
            }
            sleep(Duration.millisecond * 10)
        }
        dapError<Unit>(
            AgentErrorKind.Timeout,
            "tool.debug_initialized_timeout",
            "debug adapter did not send the initialized event"
        )
    }

    func waitForStop(
        runId: RunId,
        timeoutMillis: Int64
    ): Result<Bool> {
        let deadline = dapNowMillis() + timeoutMillis
        while (dapNowMillis() < deadline) {
            let current = snapshot()
            if (current.status == "stopped" ||
                current.status == "exited" ||
                current.status == "terminated") {
                return Result.Ok(false)
            }
            if (!alive()) { return Result.Ok(false) }
            let _ = runId
            sleep(Duration.millisecond * 10)
        }
        Result.Ok(true)
    }

    func currentStopRevision(): Int64 {
        stateLock.lock()
        try { stopRevision } finally { stateLock.unlock() }
    }

    func waitForStopAfter(
        runId: RunId,
        revision: Int64,
        timeoutMillis: Int64
    ): Result<Bool> {
        let deadline = dapNowMillis() + timeoutMillis
        while (dapNowMillis() < deadline) {
            stateLock.lock()
            let stopped = try {
                stopRevision > revision ||
                    status == "exited" ||
                    status == "terminated"
            } finally {
                stateLock.unlock()
            }
            if (stopped) { return Result.Ok(false) }
            if (!alive()) { return Result.Ok(false) }
            let _ = runId
            sleep(Duration.millisecond * 10)
        }
        Result.Ok(true)
    }

    func supports(name: String): Bool {
        stateLock.lock()
        try {
            dapJsonBoolean(capabilities, name, false)
        } finally {
            stateLock.unlock()
        }
    }

    func snapshot(): DapClientSnapshot {
        stateLock.lock()
        try {
            DapClientSnapshot(
                status,
                threadId,
                frameId,
                stopReason,
                frameName,
                sourcePath,
                line,
                column,
                instructionPointer,
                exitCode,
                initialized,
                outputBytes,
                outputTruncated
            )
        } finally {
            stateLock.unlock()
        }
    }

    func setTopFrame(value: JsonValue): Unit {
        stateLock.lock()
        try {
            frameId = dapJsonInteger(value, "id", frameId)
            frameName = dapJsonText(value, "name")
            line = dapJsonInteger(value, "line", line)
            column = dapJsonInteger(value, "column", column)
            instructionPointer = dapJsonText(
                value,
                "instructionPointerReference"
            )
            match (value.field("source")) {
                case Some(source) =>
                    sourcePath = dapJsonText(source, "path")
                case None => ()
            }
        } finally {
            stateLock.unlock()
        }
    }

    func outputSnapshot(): String {
        stateLock.lock()
        try { output } finally { stateLock.unlock() }
    }

    func markRunning(): Unit {
        stateLock.lock()
        try { status = "running" } finally { stateLock.unlock() }
    }

    func markRunningUnlessStoppedAfter(revision: Int64): Unit {
        stateLock.lock()
        try {
            if (stopRevision <= revision) {
                status = "running"
            }
        } finally {
            stateLock.unlock()
        }
    }

    func markTerminated(): Unit {
        stateLock.lock()
        try { status = "terminated" } finally { stateLock.unlock() }
    }

    func close(): Unit {
        let debuggees: Array<ManagedProcess>
        stateLock.lock()
        try {
            if (reaped) { return }
            reaped = true
            closed = true
            status = "terminated"
            debuggees = debuggeeProcesses.toArray()
            debuggeeProcesses.clear()
        } finally {
            stateLock.unlock()
        }
        for (debuggee in debuggees) {
            try {
                debuggee.terminate(force: true)
            } catch (_: Exception) {}
        }
        for (debuggee in debuggees) {
            try { let _ = debuggee.wait() } catch (_: Exception) {}
        }
        let _ = protocolClient().close()
        for (debuggee in debuggees) {
            try { let _ = debuggee.close() } catch (_: Exception) {}
        }
    }

    private func handleEvent(event: String, body: JsonValue): Unit {
        stateLock.lock()
        try {
            match (event) {
                case "initialized" =>
                    initialized = true
                    status = "configuring"
                case "stopped" =>
                    status = "stopped"
                    stopRevision += 1
                    threadId = dapJsonInteger(
                        body,
                        "threadId",
                        threadId
                    )
                    stopReason = dapJsonText(body, "reason")
                case "continued" =>
                    status = "running"
                    threadId = dapJsonInteger(
                        body,
                        "threadId",
                        threadId
                    )
                case "exited" =>
                    status = "exited"
                    exitCode = Some(dapJsonInteger(
                        body,
                        "exitCode",
                        0
                    ))
                case "terminated" =>
                    status = "terminated"
                case "output" =>
                    appendOutputLocked(dapJsonText(body, "output"))
                case _ => ()
            }
        } finally {
            stateLock.unlock()
        }
    }

    private func handleReverseRequest(
        command: String,
        arguments: JsonValue
    ): library.DapResult<JsonValue> {
        if (command == "runInTerminal") {
            match (runInTerminal(arguments)) {
                case Result.Ok(body) => library.DapResult.Ok(body)
                case Result.Err(error) => library.DapResult.Err(library.DapError(
                    library.DapErrorKind.Protocol, error.code, error.message
                ))
            }
        } else {
            library.DapResult.Err(library.DapError(
                library.DapErrorKind.Protocol,
                "dap.request_unsupported",
                "Unsupported DAP reverse request: " + command
            ))
        }
    }

    private func runInTerminal(
        arguments: JsonValue
    ): Result<JsonValue> {
        let rawArgs = match (arguments.field("args")) {
            case Some(value) => value
            case None =>
                return dapError<JsonValue>(
                    AgentErrorKind.Protocol,
                    "tool.debug_run_in_terminal_args",
                    "runInTerminal request does not contain args"
                )
        }
        if (rawArgs.kind != JsonKind.List || rawArgs.items.isEmpty()) {
            return dapError<JsonValue>(
                AgentErrorKind.Protocol,
                "tool.debug_run_in_terminal_args",
                "runInTerminal args must be a non-empty array"
            )
        }
        let values = ArrayList<String>()
        for (value in rawArgs.items) {
            if (value.kind != JsonKind.Text) {
                return dapError<JsonValue>(
                    AgentErrorKind.Protocol,
                    "tool.debug_run_in_terminal_args",
                    "runInTerminal args must contain strings"
                )
            }
            values.add(value.text)
        }
        let executable = values[0]
        let childArguments = ArrayList<String>()
        for (index in 1..values.size) {
            childArguments.add(values[index])
        }
        let requestedCwd = dapJsonText(arguments, "cwd")
        let childCwd = match (workspace.resolve(
            if (requestedCwd == "") { cwd } else { requestedCwd },
            allowDirectory: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let environment = ArrayList<SandboxEnvironmentEntry>()
        match (arguments.field("env")) {
            case Some(value) =>
                if (value.kind != JsonKind.Object) {
                    return dapError<JsonValue>(
                        AgentErrorKind.Protocol,
                        "tool.debug_run_in_terminal_env",
                        "runInTerminal env must be an object of string literals"
                    )
                }
                for (member in value.members) {
                    if (member.value.kind != JsonKind.Text ||
                        !validEnvironmentName(member.name) ||
                        directSecretName(member.name)) {
                        return dapError<JsonValue>(
                            AgentErrorKind.PermissionDenied,
                            "tool.debug_run_in_terminal_env",
                            "runInTerminal env contains an invalid or secret-like literal"
                        )
                    }
                    try {
                        environment.add(SandboxEnvironmentEntry(
                            member.name,
                            member.value.text
                        ))
                    } catch (error: Exception) {
                        return dapError<JsonValue>(
                            AgentErrorKind.Protocol,
                            "tool.debug_run_in_terminal_env",
                            error.message
                        )
                    }
                }
            case None => ()
        }
        let opened = match (launchDirectPersistentProcess(
            workspace.rootPath(),
            sandboxEnabled,
            allowUnsafeTestBypass,
            FilesystemIsolationMode.WorkspaceReadWrite,
            adapter.networkAllowed,
            executable,
            childArguments.toArray(),
            childCwd,
            bindings: adapter.environment,
            literalEnvironment: environment.toArray(),
            errorCode: "tool.debug_run_in_terminal_start"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(
                directRedactError(error, redactor)
            )
        }
        try {
            let child = opened.process
            var rejected = false
            stateLock.lock()
            try {
                if (closed || reaped) {
                    rejected = true
                } else {
                    debuggeeProcesses.add(child)
                }
            } finally {
                stateLock.unlock()
            }
            if (rejected) {
                try { child.terminate(force: true) } catch (_: Exception) {}
                try { let _ = child.wait() } catch (_: Exception) {}
                return dapError<JsonValue>(
                    AgentErrorKind.Cancelled,
                    "tool.debug_run_in_terminal_cancelled",
                    "debug session closed before runInTerminal could start"
                )
            }
            let stdout = spawn {
                drainDapStream(child.stdout, { value =>
                    appendOutput(value)
                })
            }
            let stderr = spawn {
                drainDapStream(child.stderr, { value =>
                    appendOutput(value)
                })
            }
            let monitor = spawn {
                let _ = child.wait()
                stdout.get()
                stderr.get()
                removeDebuggee(child.pid)
            }
            let _ = monitor
            Result.Ok(dapObject([
                JsonField(
                    "processId",
                    JsonValue.numberValue(child.pid.toString())
                ),
                JsonField(
                    "shellProcessId",
                    JsonValue.numberValue(child.pid.toString())
                )
            ]))
        } catch (error: Exception) {
            dapError<JsonValue>(
                AgentErrorKind.Transport,
                "tool.debug_run_in_terminal_start",
                "failed to start debuggee: " + redactor.redact(error.message)
            )
        }
    }

    private func removeDebuggee(pid: Int64): Unit {
        stateLock.lock()
        try {
            for (index in 0..debuggeeProcesses.size
                 where debuggeeProcesses[index].pid == pid) {
                debuggeeProcesses.remove(at: index)
                break
            }
        } finally {
            stateLock.unlock()
        }
    }

    private func appendOutput(value: String): Unit {
        stateLock.lock()
        try { appendOutputLocked(value) } finally { stateLock.unlock() }
    }

    private func appendOutputLocked(value: String): Unit {
        let safe = redactor.redact(value)
        if (safe == "") { return }
        let byteCount = safe.toArray().size
        outputBytes += byteCount
        output += safe
        let maxBytes: Int64 = 131072
        let currentBytes = output.toArray().size
        if (currentBytes > maxBytes) {
            output = String.fromUtf8(
                dapUtf8Suffix(
                    output.toArray(),
                    maxBytes
                )
            )
            outputTruncated = true
        }
    }

    private func alive(): Bool {
        stateLock.lock()
        let productOpen = try { !closed } finally { stateLock.unlock() }
        productOpen && protocolClient().isAlive()
    }

    private func debugTransportMessage(): String {
        stateLock.lock()
        try {
            if (transportError == "") { protocolClient().stderrSnapshot() } else { transportError }
        } finally {
            stateLock.unlock()
        }
    }
}

class ProductDapSession {
    let id: String
    let adapter: DapAdapterSpec
    let cwd: String
    let program: String
    let client: DapClient
    let launchedAt: Int64
    var lastUsedAt: Int64
    let sourceBreakpoints = ArrayList<DapSourceBreakpoints>()
    let functionBreakpoints = ArrayList<DapFunctionBreakpoint>()
    let instructionBreakpoints = ArrayList<DapInstructionBreakpoint>()
    let dataBreakpoints = ArrayList<DapDataBreakpoint>()

    init(
        id: String,
        adapter: DapAdapterSpec,
        cwd: String,
        program: String,
        client: DapClient
    ) {
        this.id = id
        this.adapter = adapter
        this.cwd = cwd
        this.program = program
        this.client = client
        this.launchedAt = dapNowMillis()
        this.lastUsedAt = launchedAt
    }
}

class DapSourceBreakpoints {
    let path: String
    var values: Array<DapBreakpoint>

    init(path: String, values!: Array<DapBreakpoint> = []) {
        this.path = path
        this.values = values
    }
}

class DapBreakpoint {
    let line: Int64
    let condition: String
    let hitCondition: String

    init(
        line: Int64,
        condition!: String = "",
        hitCondition!: String = ""
    ) {
        this.line = line
        this.condition = condition
        this.hitCondition = hitCondition
    }
}

class DapFunctionBreakpoint {
    let name: String
    let condition: String
    let hitCondition: String

    init(
        name: String,
        condition!: String = "",
        hitCondition!: String = ""
    ) {
        this.name = name
        this.condition = condition
        this.hitCondition = hitCondition
    }
}

class DapInstructionBreakpoint {
    let reference: String
    let offset: Int64
    let condition: String
    let hitCondition: String

    init(
        reference: String,
        offset!: Int64 = 0,
        condition!: String = "",
        hitCondition!: String = ""
    ) {
        this.reference = reference
        this.offset = offset
        this.condition = condition
        this.hitCondition = hitCondition
    }
}

class DapDataBreakpoint {
    let dataId: String
    let accessType: String
    let condition: String
    let hitCondition: String

    init(
        dataId: String,
        accessType!: String = "",
        condition!: String = "",
        hitCondition!: String = ""
    ) {
        this.dataId = dataId
        this.accessType = accessType
        this.condition = condition
        this.hitCondition = hitCondition
    }
}

func startDapClient(
    adapter: DapAdapterSpec,
    workspace: LocalWorkspace,
    cwd: String,
    sandboxEnabled: Bool,
    allowUnsafeTestBypass: Bool
): Result<DapClient> {
    let opened = match (launchDirectPersistentProcess(
        workspace.rootPath(),
        sandboxEnabled,
        allowUnsafeTestBypass,
        FilesystemIsolationMode.WorkspaceReadWrite,
        adapter.networkAllowed,
        adapter.executable,
        adapter.arguments,
        cwd,
        bindings: adapter.environment,
        errorCode: "tool.debug_adapter_start"
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let client = DapClient(
            adapter,
            workspace,
            cwd,
            opened.process,
            opened.redactor,
            sandboxEnabled,
            allowUnsafeTestBypass
        )
        client.start()
        Result.Ok(client)
    } catch (error: Exception) {
        dapError<DapClient>(
            AgentErrorKind.Configuration,
            "tool.debug_adapter_start",
            opened.redactor.redact(
                "failed to start " + adapter.name + ": " + error.message
            )
        )
    }
}

func loadDapAdapters(root: String): Array<DapAdapterSpec> {
    let result = ArrayList<DapAdapterSpec>()
    addBuiltinDapAdapter(
        result,
        "gdb",
        "gdb",
        ["-i", "dap"],
        [
            ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp",
            ".hxx", ".rs"
        ],
        dapObject([
            JsonField("request", JsonValue.stringValue("launch")),
            JsonField("stopOnEntry", JsonValue.boolValue(true)),
            JsonField(
                "stopAtBeginningOfMainSubprogram",
                JsonValue.boolValue(true)
            )
        ]),
        dapObject([
            JsonField("request", JsonValue.stringValue("attach"))
        ])
    )
    addBuiltinDapAdapter(
        result,
        "lldb-dap",
        "lldb-dap",
        [],
        [
            ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".swift",
            ".rs", ".zig"
        ],
        dapObject([
            JsonField("request", JsonValue.stringValue("launch")),
            JsonField("stopOnEntry", JsonValue.boolValue(true))
        ]),
        dapObject([
            JsonField("request", JsonValue.stringValue("attach"))
        ])
    )
    let paths = [
        Path(root).join(".omp").join("dap.json").toString(),
        Path(root).join(".dap.json").toString(),
        Path(root).join("dap.json").toString()
    ]
    for (path in paths where exists(Path(path))) {
        for (spec in loadDapConfig(path)) {
            var replaced = false
            for (index in 0..result.size
                 where result[index].name == spec.name) {
                result.remove(at: index)
                result.add(spec)
                replaced = true
                break
            }
            if (!replaced) { result.add(spec) }
        }
    }
    result.toArray()
}

func addBuiltinDapAdapter(
    result: ArrayList<DapAdapterSpec>,
    name: String,
    command: String,
    arguments: Array<String>,
    fileTypes: Array<String>,
    launchDefaults: JsonValue,
    attachDefaults: JsonValue
): Unit {
    match (resolveDapExecutable(command)) {
        case Some(executable) =>
            result.add(DapAdapterSpec(
                name,
                executable,
                arguments,
                fileTypes,
                launchDefaults,
                attachDefaults
            ))
        case None => ()
    }
}

func loadDapConfig(path: String): Array<DapAdapterSpec> {
    let result = ArrayList<DapAdapterSpec>()
    let document = try {
        parseJson(
            String.fromUtf8(File.readFrom(path)),
            maxBytes: 1048576,
            maxDepth: 64
        )
    } catch (_: Exception) {
        return []
    }
    let adapters = match (document.field("adapters")) {
        case Some(value) =>
            if (value.kind == JsonKind.Object) {
                value
            } else {
                return []
            }
        case None => document
    }
    if (adapters.kind != JsonKind.Object) { return [] }
    for (member in adapters.members) {
        let value = member.value
        if (value.kind != JsonKind.Object) { continue }
        let command = dapJsonText(value, "command")
        if (command == "") { continue }
        let executable = match (resolveDapExecutable(command)) {
            case Some(found) => found
            case None => continue
        }
        let environment = match (dapJsonEnvironmentBindings(value)) {
            case Some(found) => found
            case None => continue
        }
        result.add(DapAdapterSpec(
            member.name,
            executable,
            dapJsonStringArray(value, "args"),
            dapJsonStringArray(value, "fileTypes"),
            match (value.field("launchDefaults")) {
                case Some(defaults) =>
                    if (defaults.kind == JsonKind.Object) {
                        defaults
                    } else {
                        JsonValue.objectValue([])
                    }
                case None => JsonValue.objectValue([])
            },
            match (value.field("attachDefaults")) {
                case Some(defaults) =>
                    if (defaults.kind == JsonKind.Object) {
                        defaults
                    } else {
                        JsonValue.objectValue([])
                    }
                case None => JsonValue.objectValue([])
            },
            networkAllowed: dapJsonBoolean(value, "network", false),
            environment: environment
        ))
    }
    result.toArray()
}

func dapJsonEnvironmentBindings(
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

func resolveDapExecutable(command: String): ?String {
    if (command.contains("/")) {
        return if (exists(Path(command))) { Some(command) } else { None }
    }
    match (getVariable("PATH")) {
        case Some(path) =>
            for (directory in path.split(":")) {
                let candidate = Path(directory).join(command).toString()
                if (exists(Path(candidate))) { return Some(candidate) }
            }
        case None => ()
    }
    None
}

func dapJsonStringArray(
    value: JsonValue,
    name: String
): Array<String> {
    let result = ArrayList<String>()
    match (value.field(name)) {
        case Some(items) =>
            if (items.kind == JsonKind.List) {
                for (item in items.items
                     where item.kind == JsonKind.Text) {
                    result.add(item.text)
                }
            }
        case None => ()
    }
    result.toArray()
}

func dapObject(values: Array<JsonField>): JsonValue {
    JsonValue.objectValue(values)
}

func dapJsonBoolean(
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

func dapJsonText(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == JsonKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func dapJsonInteger(
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

func dapNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func mapDapResult<T>(value: library.DapResult<T>): Result<T> {
    match (value) {
        case library.DapResult.Ok(found) => Result.Ok(found)
        case library.DapResult.Err(error) => Result.Err(productDapError(error))
    }
}

func productDapError(error: library.DapError): AgentError {
    let kind = match (error.kind) {
        case library.DapErrorKind.Cancelled => AgentErrorKind.Cancelled
        case library.DapErrorKind.Deadline => AgentErrorKind.Timeout
        case library.DapErrorKind.Transport => AgentErrorKind.Transport
        case _ => AgentErrorKind.Protocol
    }
    AgentError(kind, "tool." + error.code, error.message)
}

func dapError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

func drainDapStream(
    stream: InputStream,
    sink: (String) -> Unit
): Unit {
    let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = try {
            stream.read(buffer)
        } catch (_: Exception) {
            return
        }
        if (count <= 0) { return }
        let bytes = ArrayList<Byte>()
        for (index in 0..count) { bytes.add(buffer[index]) }
        sink(String.fromUtf8(bytes.toArray()))
    }
}

func dapUtf8Suffix(value: Array<Byte>, limit: Int64): Array<Byte> {
    if (value.size <= limit) { return value }
    var start = value.size - limit
    while (start < value.size &&
        value[start] >= 0x80 && value[start] < 0xc0) {
        start += 1
    }
    let result = ArrayList<Byte>()
    for (index in start..value.size) { result.add(value[index]) }
    result.toArray()
}
