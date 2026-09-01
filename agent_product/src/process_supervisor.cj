package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import process4cj.*
import model_adapters.*
import sandbox4cj.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.io.*
import std.net.*
import std.process.*
import std.regex.*
import std.sync.*

class ProductDaemonSpec {
    let name: String
    let application: String
    let arguments: Array<String>
    let environment: HashMap<String, String>
    let environmentBindings: Array<DirectEnvironmentBinding>
    let networkAllowed: Bool
    let cwd: String
    let pty: Bool
    let readyLog: String
    let readyPort: Int64
    let readyHost: String
    let readyTimeoutMillis: Int64
    let restartPolicy: String
    let persist: Bool
    let detached: Bool

    init(
        name: String,
        application: String,
        arguments: Array<String>,
        environment: HashMap<String, String>,
        environmentBindings: Array<DirectEnvironmentBinding>,
        networkAllowed: Bool,
        cwd: String,
        pty: Bool,
        readyLog: String,
        readyPort: Int64,
        readyHost: String,
        readyTimeoutMillis: Int64,
        restartPolicy: String,
        persist: Bool,
        detached: Bool
    ) {
        this.name = name
        this.application = application
        this.arguments = arguments
        this.environment = environment
        this.environmentBindings = environmentBindings
        this.networkAllowed = networkAllowed
        this.cwd = cwd
        this.pty = pty
        this.readyLog = readyLog
        this.readyPort = readyPort
        this.readyHost = readyHost
        this.readyTimeoutMillis = readyTimeoutMillis
        this.restartPolicy = restartPolicy
        this.persist = persist
        this.detached = detached
    }
}

class ProductDaemonState {
    let spec: ProductDaemonSpec
    let id: String
    let owner: String
    let createdAt: Int64
    var process: ?ManagedProcess = None
    var state: String = "starting"
    var pid: Int64 = 0
    var exitCode: ?Int64 = None
    var exitReason: String = ""
    var startedAt: Int64 = nowMillis()
    var exitedAt: Int64 = 0
    var readyAt: Int64 = 0
    var readyMatch: String = ""
    var restartCount: Int64 = 0
    var consecutiveFailures: Int64 = 0
    var generation: Int64 = 0
    var stopRequested: Bool = false
    var logBaseCursor: Int64 = 0
    var startIdentity: String = ""
    var recoveryRequired: Bool = false
    var stale: Bool = false
    var logPath: String = ""
    var persistenceWarning: String = ""
    var secretValues: Array<String> = []
    let output = ArrayList<Byte>()

    init(
        spec: ProductDaemonSpec,
        id: String,
        owner: String,
        createdAt!: Int64 = 0,
        logPath!: String = ""
    ) {
        this.spec = spec
        this.id = id
        this.owner = owner
        this.createdAt = if (createdAt <= 0) { nowMillis() } else { createdAt }
        this.logPath = logPath
    }
}

class ProductProcessSupervisor {
    private let workspace: LocalWorkspace
    private let sandboxEnabled: Bool
    private let allowUnsafeTestBypass: Bool
    private let lock = Mutex()
    private let daemons = ArrayList<ProductDaemonState>()
    private let maxLogBytes: Int64 = 1048576
    private let brokerRoot: String
    private let brokerMode: Bool
    private let persistenceLock = Mutex()
    private let recoveryWarnings = ArrayList<String>()
    private var daemonCounter: Int64 = 0

    init(
        workspace: LocalWorkspace,
        brokerRoot!: String = "",
        sandboxEnabled!: Bool = false,
        allowUnsafeTestBypass!: Bool = false
    ) {
        this.workspace = workspace
        this.sandboxEnabled = sandboxEnabled
        this.allowUnsafeTestBypass = allowUnsafeTestBypass
        this.brokerRoot = brokerRoot
        this.brokerMode = brokerRoot != ""
        if (brokerMode) {
            let daemonsRoot = brokerRoot + "/daemons"
            let logsRoot = brokerRoot + "/logs"
            if (!exists(Path(daemonsRoot))) {
                Directory.create(daemonsRoot, recursive: true)
            }
            if (!exists(Path(logsRoot))) {
                Directory.create(logsRoot, recursive: true)
            }
            restoreBrokerStates()
        }
    }

    func contains(name: String): Bool {
        lock.lock()
        try { findLocked(name).isSome() } finally { lock.unlock() }
    }

    func close(): Unit {
        let values = ArrayList<ProductDaemonState>()
        lock.lock()
        try {
            for (state in daemons) { values.add(state) }
        } finally {
            lock.unlock()
        }
        for (state in values) { let _ = stopState(state, 1000) }
    }

    func execute(
        call: ToolCall,
        op: String,
        owner: String
    ): Result<ToolResult> {
        match (op) {
            case "start" => start(call, owner)
            case "ps" => list(call)
            case "logs" => logs(call)
            case "stop" => stop(call)
            case "restart" => restart(call)
            case "describe" => describe(call)
            case "send" => send(call)
            case "wait" => wait(call)
            case _ => supervisorError<ToolResult>(
                "hub.process_op_invalid",
                "unsupported process operation: " + op
            )
        }
    }

    private func start(
        call: ToolCall,
        owner: String
    ): Result<ToolResult> {
        let spec = match (parseSpec(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let state: ProductDaemonState
        lock.lock()
        try {
            for (index in 0..daemons.size) {
                let existing = daemons[index]
                if (existing.spec.name != spec.name) { continue }
                if (!daemonTerminal(existing.state)) {
                    return supervisorError<ToolResult>(
                        "hub.process_exists",
                        "process already exists: " + spec.name
                    )
                }
                daemons.remove(at: index)
                break
            }
            daemonCounter += 1
            state = ProductDaemonState(
                spec,
                "daemon-" + nowMillis().toString() + "-" +
                    daemonCounter.toString(),
                owner,
                logPath: brokerLogPath(spec.name)
            )
            daemons.add(state)
        } finally {
            lock.unlock()
        }
        match (launchState(state, false)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        var timedOut = false
        if (hasReadiness(spec)) {
            timedOut = !waitForReady(state, spec.readyTimeoutMillis)
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField("op", textValue("start")),
                ValueField("daemon", daemonValue(state)),
                ValueField("readyTimedOut", boolValue(timedOut))
            ]),
            isError: state.state == "failed"
        ))
    }

    private func list(call: ToolCall): Result<ToolResult> {
        let values = ArrayList<AgentValue>()
        lock.lock()
        try {
            for (state in daemons) { values.add(daemonValueLocked(state)) }
        } finally {
            lock.unlock()
        }
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("op", textValue("ps")))
        fields.add(ValueField("daemons", listValue(values.toArray())))
        if (!recoveryWarnings.isEmpty()) {
            fields.add(ValueField(
                "recoveryWarnings",
                processStringListValue(recoveryWarnings.toArray())
            ))
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue(fields.toArray())
        ))
    }

    private func logs(call: ToolCall): Result<ToolResult> {
        let name = match (requiredDaemonName(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var lines = daemonInteger(call, "lines", 100)
        if (lines < 1) { lines = 1 }
        if (lines > 1000) { lines = 1000 }
        let head = daemonBoolean(call, "head", false)
        let follow = daemonBoolean(call, "follow", false)
        let cursorField = call.arguments.field("cursor")
        let cursor = daemonInteger(call, "cursor", -1)
        let timeout = secondsToMillis(
            daemonInteger(call, "timeout", 30),
            30
        )
        let started = nowMillis()
        var timedOut = false
        if (follow && cursorField.isSome()) {
            while (true) {
                let snapshot = logSnapshot(name)
                let current = match (snapshot) {
                    case Some(value) => value
                    case None =>
                        return missingDaemon<ToolResult>(name)
                }
                if (current.cursor > cursor ||
                    daemonTerminal(current.state)) {
                    break
                }
                if (nowMillis() - started >= timeout) {
                    timedOut = true
                    break
                }
                sleep(Duration.millisecond * 10)
            }
        }
        let snapshot = match (logSnapshot(name)) {
            case Some(value) => value
            case None => return missingDaemon<ToolResult>(name)
        }
        let reset = cursor >= 0 && cursor < snapshot.baseCursor
        var text = if (cursor >= 0 && !reset) {
            let offset = min(
                snapshot.bytes.size,
                cursor - snapshot.baseCursor
            )
            safeUtf8(snapshot.bytes[offset..snapshot.bytes.size])
        } else {
            safeUtf8(snapshot.bytes)
        }
        let grep = daemonText(call, "grep")
        if (grep != "") {
            text = match (filterLogLines(text, grep)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        }
        text = selectLogLines(text, lines, head)
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField("op", textValue("logs")),
                ValueField("name", textValue(name)),
                ValueField("text", textValue(text)),
                ValueField("cursor", integerValue(snapshot.cursor)),
                ValueField("timedOut", boolValue(timedOut)),
                ValueField("state", textValue(snapshot.state)),
                ValueField("reset", boolValue(reset))
            ])
        ))
    }

    private func stop(call: ToolCall): Result<ToolResult> {
        let name = match (requiredDaemonName(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let timeout = secondsToMillis(
            daemonInteger(call, "timeout", 5),
            5
        )
        let state = match (stateByName(name)) {
            case Some(value) => value
            case None => return missingDaemon<ToolResult>(name)
        }
        match (stopState(state, timeout)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField("op", textValue("stop")),
                ValueField("daemon", daemonValue(state))
            ])
        ))
    }

    private func restart(call: ToolCall): Result<ToolResult> {
        let name = match (requiredDaemonName(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let state = match (stateByName(name)) {
            case Some(value) => value
            case None => return missingDaemon<ToolResult>(name)
        }
        match (stopState(state, 5000)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        lock.lock()
        try {
            state.stopRequested = false
        } finally {
            lock.unlock()
        }
        match (launchState(state, true)) {
            case Result.Ok(_) =>
                if (hasReadiness(state.spec)) {
                    let _ = waitForReady(
                        state,
                        state.spec.readyTimeoutMillis
                    )
                }
                Result.Ok(ToolResult(
                    call.callId,
                    objectValue([
                        ValueField("op", textValue("restart")),
                        ValueField("daemon", daemonValue(state))
                    ])
                ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func describe(call: ToolCall): Result<ToolResult> {
        let name = match (requiredDaemonName(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let state = match (stateByName(name)) {
            case Some(value) => value
            case None => return missingDaemon<ToolResult>(name)
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField("op", textValue("describe")),
                ValueField("daemon", daemonValue(state)),
                ValueField("spec", daemonSpecValue(state.spec))
            ])
        ))
    }

    private func send(call: ToolCall): Result<ToolResult> {
        let name = match (requiredDaemonName(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let state = match (stateByName(name)) {
            case Some(value) => value
            case None => return missingDaemon<ToolResult>(name)
        }
        if (daemonRecoveryRequired(state)) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "hub.process_recovery_required",
                "process input cannot be recovered after the broker restarted",
                fields: [ErrorField("name", name)]
            ))
        }
        let process = match (liveProcess(state)) {
            case Some(value) => value
            case None =>
                return supervisorError<ToolResult>(
                    "hub.process_not_running",
                    "process is not running: " + name
                )
        }
        let signal = daemonText(call, "signal")
        if (signal != "") {
            match (signalProcessTree(process.pid, signal)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        var data = daemonText(call, "text")
        if (data != "" && daemonBoolean(call, "enter", true)) {
            data += "\r"
        }
        let keys = match (daemonStringList(call, "keys")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (key in keys) {
            let encoded = match (launchKey(key)) {
                case Some(value) => value
                case None =>
                    return supervisorError<ToolResult>(
                        "hub.process_key_invalid",
                        "Unsupported launch key " + key
                    )
            }
            data += encoded
        }
        if (data != "") {
            try {
                process.writeStdin(data.toArray())
                process.flushInput()
            } catch (error: Exception) {
                return supervisorError<ToolResult>(
                    "hub.process_send_failed",
                    error.message
                )
            }
        }
        if (signal == "" && data == "") {
            return supervisorError<ToolResult>(
                "hub.process_send_empty",
                "send requires text, keys, or signal"
            )
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField("op", textValue("send")),
                ValueField("daemon", daemonValue(state))
            ])
        ))
    }

    private func wait(call: ToolCall): Result<ToolResult> {
        let name = match (requiredDaemonName(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let condition = daemonText(call, "for")
        let pattern = daemonText(call, "pattern")
        let timeout = secondsToMillis(
            daemonInteger(call, "timeout", 30),
            30
        )
        let regex: ?Regex = if (pattern == "") {
            None
        } else {
            try {
                Some(Regex(pattern, []))
            } catch (error: Exception) {
                return supervisorError<ToolResult>(
                    "hub.process_pattern_invalid",
                    error.message
                )
            }
        }
        let started = nowMillis()
        var timedOut = false
        var matched = ""
        while (true) {
            let state = match (stateByName(name)) {
                case Some(value) => value
                case None => return missingDaemon<ToolResult>(name)
            }
            if (daemonRecoveryRequired(state)) {
                timedOut = true
                break
            }
            match (regex) {
                case Some(value) =>
                    let output = daemonOutput(state)
                    match (value.find(output)) {
                        case Some(found) =>
                            matched = found.matchString()
                            break
                        case None => ()
                    }
                case None =>
                    if (condition == "ready") {
                        if (state.readyAt != 0 ||
                            state.state == "ready" ||
                            (state.state == "running" &&
                                !hasReadiness(state.spec))) {
                            break
                        }
                        if (daemonTerminal(state.state)) {
                            timedOut = true
                            break
                        }
                    }
                    if (condition != "ready" &&
                        daemonTerminal(state.state)) {
                        break
                    }
            }
            if (nowMillis() - started >= timeout) {
                timedOut = true
                break
            }
            sleep(Duration.millisecond * 10)
        }
        let state = stateByName(name).getOrThrow()
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField("op", textValue("wait")),
                ValueField("daemon", daemonValue(state)),
                ValueField("timedOut", boolValue(timedOut)),
                ValueField(
                    "matched",
                    if (matched == "") {
                        nullValue()
                    } else {
                        textValue(matched)
                    }
                )
            ])
        ))
    }

    private func parseSpec(
        call: ToolCall
    ): Result<ProductDaemonSpec> {
        let name = match (requiredDaemonName(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let application = daemonText(call, "application")
        if (application == "") {
            return supervisorError<ProductDaemonSpec>(
                "hub.process_application_required",
                "start requires application"
            )
        }
        let detached = daemonBoolean(call, "detached", false)
        let persist = daemonBoolean(call, "persist", false) || detached
        if (!brokerMode && (persist || detached)) {
            return supervisorError<ProductDaemonSpec>(
                "hub.process_broker_required",
                "persist and detached require the external launch broker"
            )
        }
        if (brokerMode && !persist) {
            return supervisorError<ProductDaemonSpec>(
                "hub.process_broker_persist_required",
                "the external launch broker only accepts persistent processes"
            )
        }
        let arguments = match (daemonStringList(call, "args")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let environment = match (daemonEnvironment(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let environmentBindings = match (daemonEnvironmentBindings(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let networkAllowed = daemonBoolean(call, "network", false)
        let authoredCwd = daemonText(call, "cwd")
        let cwd = match (workspace.resolve(
            if (authoredCwd == "") {
                workspace.rootPath()
            } else {
                authoredCwd
            },
            allowDirectory: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var readyLog = ""
        var readyPort: Int64 = 0
        var readyHost = "127.0.0.1"
        var readyTimeout: Int64 = 30000
        match (call.arguments.field("ready")) {
            case Some(ready) =>
                if (ready.unifiedKind != ValueKind.Object) {
                    return supervisorError<ProductDaemonSpec>(
                        "hub.process_ready_invalid",
                        "ready must be an object"
                    )
                }
                readyLog = daemonValueText(ready, "log")
                readyPort = daemonValueInteger(ready, "port", 0)
                readyHost = daemonValueText(ready, "host")
                if (readyHost == "") { readyHost = "127.0.0.1" }
                readyTimeout = secondsToMillis(
                    daemonValueInteger(ready, "timeout", 30),
                    30
                )
                if (readyLog == "" && readyPort == 0) {
                    return supervisorError<ProductDaemonSpec>(
                        "hub.process_ready_empty",
                        "ready requires log or port"
                    )
                }
                if (ready.field("port").isSome() &&
                    (readyPort < 1 || readyPort > 65535)) {
                    return supervisorError<ProductDaemonSpec>(
                        "hub.process_ready_port_invalid",
                        "ready.port must be an integer from 1 to 65535"
                    )
                }
                if (readyPort != 0 && !networkAllowed) {
                    return supervisorError<ProductDaemonSpec>(
                        "hub.process_ready_network_required",
                        "ready.port requires network: true and NetworkAccess authorization"
                    )
                }
                if (readyLog != "") {
                    try {
                        let _ = Regex(readyLog, [])
                    } catch (error: Exception) {
                        return supervisorError<ProductDaemonSpec>(
                            "hub.process_ready_log_invalid",
                            error.message
                        )
                    }
                }
            case None => ()
        }
        let restartPolicy = daemonText(call, "restart")
        let normalizedRestart = if (restartPolicy == "") {
            "no"
        } else {
            restartPolicy
        }
        if (normalizedRestart != "no" &&
            normalizedRestart != "on-failure" &&
            normalizedRestart != "always") {
            return supervisorError<ProductDaemonSpec>(
                "hub.process_restart_invalid",
                "restart must be no, on-failure, or always"
            )
        }
        Result.Ok(ProductDaemonSpec(
            name,
            application,
            arguments,
            environment,
            environmentBindings,
            networkAllowed,
            cwd,
            if (detached) {
                false
            } else {
                daemonBoolean(call, "pty", true)
            },
            readyLog,
            readyPort,
            readyHost,
            readyTimeout,
            normalizedRestart,
            persist,
            detached
        ))
    }

    private func launchState(
        state: ProductDaemonState,
        restarting: Bool
    ): Result<Unit> {
        try {
            let spec = state.spec
            if (brokerMode && !restarting && state.logPath != "") {
                File.writeTo(state.logPath, [])
            }
            var launchExecutable = spec.application
            let launchArguments = ArrayList<String>()
            if (spec.pty) {
                launchExecutable = "script"
                launchArguments.add("-qefc")
                launchArguments.add(
                    "stty rows 40 cols 120 >/dev/null 2>&1 && exec " +
                        shellCommand(spec.application, spec.arguments)
                )
                launchArguments.add("/dev/null")
            } else {
                launchArguments.add(all: spec.arguments)
            }
            if (!sandboxEnabled) {
                let hostArguments = ArrayList<String>()
                hostArguments.add(launchExecutable)
                hostArguments.add(all: launchArguments)
                launchArguments.clear()
                launchArguments.add(all: hostArguments)
                launchExecutable = "setsid"
            }
            let opened = match (launchDirectPersistentProcess(
                workspace.rootPath(),
                sandboxEnabled,
                allowUnsafeTestBypass,
                FilesystemIsolationMode.WorkspaceReadWrite,
                spec.networkAllowed,
                launchExecutable,
                launchArguments.toArray(),
                spec.cwd,
                bindings: spec.environmentBindings,
                literalEnvironment: daemonLiteralEnvironment(spec.environment),
                errorCode: "hub.process_start_failed"
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return failDaemonLaunch(state, error)
            }
            let process = opened.process
            let generation: Int64
            lock.lock()
            try {
                state.generation += 1
                generation = state.generation
                state.process = Some(process)
                state.state = if (hasReadiness(spec)) {
                    "starting"
                } else {
                    "running"
                }
                state.pid = process.pid
                state.startIdentity = linuxProcessStartToken(
                    "/proc/" + process.pid.toString() + "/stat"
                )
                state.recoveryRequired = false
                state.stale = false
                state.exitCode = None
                state.exitReason = ""
                state.startedAt = nowMillis()
                state.exitedAt = 0
                state.readyAt = 0
                state.readyMatch = ""
                state.secretValues = opened.secretValues
                if (!restarting) { state.stopRequested = false }
            } finally {
                lock.unlock()
            }
            persistState(state)
            let output = spawn {
                pump(
                    process.stdout,
                    state,
                    generation,
                    opened.secretValues
                )
            }
            let error = spawn {
                pump(
                    process.stderr,
                    state,
                    generation,
                    opened.secretValues
                )
            }
            let monitor = spawn {
                let code = process.wait().code
                output.get()
                error.get()
                let _ = process.close()
                finishProcess(state, generation, code)
            }
            let _ = monitor
            Result.Ok(())
        } catch (error: Exception) {
            lock.lock()
            try {
                state.state = "failed"
                state.exitReason = error.message
                state.exitedAt = nowMillis()
            } finally {
                lock.unlock()
            }
            persistState(state)
            supervisorError<Unit>(
                "hub.process_start_failed",
                error.message
            )
        }
    }

    private func failDaemonLaunch(
        state: ProductDaemonState,
        error: AgentError
    ): Result<Unit> {
        lock.lock()
        try {
            state.state = "failed"
            state.exitReason = error.message
            state.exitedAt = nowMillis()
        } finally {
            lock.unlock()
        }
        persistState(state)
        Result.Err(error)
    }

    private func finishProcess(
        state: ProductDaemonState,
        generation: Int64,
        code: Int64
    ): Unit {
        var shouldRestart = false
        lock.lock()
        try {
            if (state.generation != generation) { return }
            state.process = None
            state.exitCode = Some(code)
            state.exitedAt = nowMillis()
            state.pid = 0
            let failed = code != 0
            shouldRestart = !state.stopRequested &&
                (state.spec.restartPolicy == "always" ||
                    (state.spec.restartPolicy == "on-failure" &&
                        failed))
            if (shouldRestart) {
                state.restartCount += 1
                state.consecutiveFailures += 1
                state.readyAt = 0
                state.readyMatch = ""
                state.state = "restarting"
            } else {
                state.consecutiveFailures = 0
                state.state = if (failed && !state.stopRequested) {
                    "failed"
                } else {
                    "exited"
                }
            }
        } finally {
            lock.unlock()
        }
        persistState(state)
        if (shouldRestart) {
            let exponent = min(state.consecutiveFailures, 5)
            var delay: Int64 = 1000
            for (_ in 0..exponent) { delay *= 2 }
            sleep(Duration.millisecond * min(delay, 30000))
            lock.lock()
            try {
                if (state.stopRequested || state.generation != generation) {
                    return
                }
            } finally {
                lock.unlock()
            }
            let _ = launchState(state, true)
        }
    }

    private func pump(
        stream: InputStream,
        state: ProductDaemonState,
        generation: Int64,
        secretValues: Array<String>
    ): Unit {
        let redactor = ProductDaemonByteRedactor(secretValues)
        let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = try {
                stream.read(buffer)
            } catch (_: Exception) {
                appendDaemonOutput(state, generation, redactor.finish())
                return
            }
            if (count <= 0) {
                appendDaemonOutput(state, generation, redactor.finish())
                return
            }
            appendDaemonOutput(
                state,
                generation,
                redactor.push(buffer[0..count])
            )
        }
    }

    private func appendDaemonOutput(
        state: ProductDaemonState,
        generation: Int64,
        bytes: Array<Byte>
    ): Unit {
        if (bytes.isEmpty()) { return }
        lock.lock()
        try {
            if (state.generation != generation) { return }
            for (byte in bytes) { state.output.add(byte) }
            var truncated = false
            while (state.output.size > maxLogBytes) {
                state.output.remove(at: 0)
                state.logBaseCursor += 1
                truncated = true
            }
            if (brokerMode && state.logPath != "") {
                try {
                    if (truncated) {
                        File.writeTo(state.logPath, state.output.toArray())
                    } else {
                        File.appendTo(state.logPath, bytes)
                    }
                } catch (_: Exception) {}
            }
        } finally {
            lock.unlock()
        }
    }

    private func waitForReady(
        state: ProductDaemonState,
        timeoutMillis: Int64
    ): Bool {
        let started = nowMillis()
        while (true) {
            let output: String
            let currentState: String
            lock.lock()
            try {
                output = safeUtf8(state.output.toArray())
                currentState = state.state
            } finally {
                lock.unlock()
            }
            var logReady = state.spec.readyLog == ""
            var matchText = ""
            if (!logReady) {
                match (Regex(state.spec.readyLog, []).find(output)) {
                    case Some(value) =>
                        logReady = true
                        matchText = value.matchString()
                    case None => ()
                }
            }
            let portReady = state.spec.readyPort == 0 ||
                tcpReady(
                    state.spec.readyHost,
                    state.spec.readyPort
                )
            if (logReady && portReady) {
                lock.lock()
                try {
                    if (!daemonTerminal(state.state)) {
                        state.state = "ready"
                        state.readyAt = nowMillis()
                        state.readyMatch = matchText
                    }
                } finally {
                    lock.unlock()
                }
                persistState(state)
                return true
            }
            if (daemonTerminal(currentState)) { return false }
            if (nowMillis() - started >= timeoutMillis) { return false }
            sleep(Duration.millisecond * 20)
        }
        false
    }

    private func stopState(
        state: ProductDaemonState,
        timeoutMillis: Int64
    ): Result<Unit> {
        let process: ?ManagedProcess
        let recoveredPid: Int64
        let recoveredIdentity: String
        let recovered: Bool
        lock.lock()
        try {
            state.stopRequested = true
            process = state.process
            recoveredPid = state.pid
            recoveredIdentity = state.startIdentity
            recovered = state.recoveryRequired
            if (process.isSome()) { state.state = "stopping" }
        } finally {
            lock.unlock()
        }
        match (process) {
            case None =>
                if (recovered) {
                    if (recoveredPid > 0) {
                        stopRecoveredProcess(
                            state,
                            recoveredPid,
                            recoveredIdentity,
                            timeoutMillis
                        )
                    } else {
                        // Recovery already proved the recorded identity is not
                        // live. An explicit stop is the reconciliation action:
                        // no signal is safe or necessary, and the stale record
                        // can become a terminal fact without guessing.
                        lock.lock()
                        try {
                            state.state = "exited"
                            state.recoveryRequired = false
                            state.stale = true
                            state.exitedAt = nowMillis()
                            state.exitReason = "stale process record dismissed by explicit stop"
                        } finally {
                            lock.unlock()
                        }
                    }
                }
                persistState(state)
                if (daemonState(state) == "recovery_required") {
                    return supervisorError<Unit>(
                        "hub.process_stop_unconfirmed",
                        "recovered process did not stop"
                    )
                }
                return Result.Ok(())
            case Some(value) =>
                let _ = signalProcessTree(value.pid, "SIGTERM")
                let started = nowMillis()
                while (value.isAlive() &&
                    nowMillis() - started < timeoutMillis) {
                    sleep(Duration.millisecond * 10)
                }
                if (value.isAlive()) {
                    let _ = signalProcessTree(value.pid, "SIGKILL")
                    // A sandbox wrapper is not necessarily the leader of the
                    // process group visible to the host. Always terminate the
                    // owned SubProcess as the final enforcement boundary.
                    try {
                        value.terminate(force: true)
                    } catch (_: Exception) {}
                }
                let forceStarted = nowMillis()
                while (value.isAlive() &&
                    nowMillis() - forceStarted < 1000) {
                    sleep(Duration.millisecond * 10)
                }
                if (value.isAlive()) {
                    lock.lock()
                    try {
                        state.state = "recovery_required"
                        state.recoveryRequired = true
                        state.stale = true
                        state.exitReason = "owned process did not stop before the force deadline"
                    } finally {
                        lock.unlock()
                    }
                    persistState(state)
                    return supervisorError<Unit>(
                        "hub.process_stop_unconfirmed",
                        "owned process did not stop before the force deadline"
                    )
                }
                let settleStarted = nowMillis()
                while (!daemonTerminal(daemonState(state)) &&
                    nowMillis() - settleStarted < 1000) {
                    sleep(Duration.millisecond * 10)
                }
                persistState(state)
                if (!daemonTerminal(daemonState(state))) {
                    return supervisorError<Unit>(
                        "hub.process_stop_unsettled",
                        "process stopped but its monitor did not settle"
                    )
                }
                Result.Ok(())
        }
    }

    private func stateByName(
        name: String
    ): ?ProductDaemonState {
        lock.lock()
        try { findLocked(name) } finally { lock.unlock() }
    }

    private func findLocked(name: String): ?ProductDaemonState {
        for (state in daemons where state.spec.name == name) {
            return Some(state)
        }
        None
    }

    private func liveProcess(
        state: ProductDaemonState
    ): ?ManagedProcess {
        lock.lock()
        try {
            match (state.process) {
                case Some(value) =>
                    if (value.isAlive()) { Some(value) } else { None }
                case None => None
            }
        } finally {
            lock.unlock()
        }
    }

    private func daemonValue(
        state: ProductDaemonState
    ): AgentValue {
        lock.lock()
        try { daemonValueLocked(state) } finally { lock.unlock() }
    }

    private func daemonValueLocked(
        state: ProductDaemonState
    ): AgentValue {
        let value = objectValue([
            ValueField("name", textValue(state.spec.name)),
            ValueField("id", textValue(state.id)),
            ValueField("state", textValue(state.state)),
            ValueField(
                "pid",
                if (state.pid == 0) {
                    nullValue()
                } else {
                    integerValue(state.pid)
                }
            ),
            ValueField(
                "exitCode",
                match (state.exitCode) {
                    case Some(value) => integerValue(value)
                    case None => nullValue()
                }
            ),
            ValueField("exitReason", textValue(state.exitReason)),
            ValueField("createdAt", integerValue(state.createdAt)),
            ValueField("startedAt", integerValue(state.startedAt)),
            ValueField(
                "exitedAt",
                if (state.exitedAt == 0) {
                    nullValue()
                } else {
                    integerValue(state.exitedAt)
                }
            ),
            ValueField(
                "readyAt",
                if (state.readyAt == 0) {
                    nullValue()
                } else {
                    integerValue(state.readyAt)
                }
            ),
            ValueField("readyMatch", textValue(state.readyMatch)),
            ValueField(
                "restartCount",
                integerValue(state.restartCount)
            ),
            ValueField(
                "outputBytes",
                integerValue(state.logBaseCursor + state.output.size)
            ),
            ValueField("owner", textValue(state.owner)),
            ValueField(
                "readyPending",
                readinessPendingValue(state)
            ),
            ValueField("persist", boolValue(state.spec.persist)),
            ValueField("detached", boolValue(state.spec.detached)),
            ValueField("recoveryRequired", boolValue(state.recoveryRequired)),
            ValueField("stale", boolValue(state.stale)),
            ValueField("startIdentity", textValue(state.startIdentity))
        ])
        if (state.persistenceWarning == "") { return value }
        let fields = ArrayList<ValueField>()
        fields.add(all: value.fields)
        fields.add(ValueField(
            "persistenceWarning",
            textValue(state.persistenceWarning)
        ))
        objectValue(fields.toArray())
    }

    private func daemonSpecValue(spec: ProductDaemonSpec): AgentValue {
        objectValue([
            ValueField("name", textValue(spec.name)),
            ValueField("application", textValue(spec.application)),
            ValueField(
                "args",
                processStringListValue(spec.arguments)
            ),
            ValueField("cwd", textValue(spec.cwd)),
            ValueField("pty", boolValue(spec.pty)),
            ValueField("env", processEnvironmentValue(spec.environment)),
            ValueField(
                "env_from",
                processEnvironmentBindingsValue(
                    spec.environmentBindings,
                    false
                )
            ),
            ValueField(
                "secret_env",
                processEnvironmentBindingsValue(
                    spec.environmentBindings,
                    true
                )
            ),
            ValueField("network", boolValue(spec.networkAllowed)),
            ValueField("ready", daemonReadyValue(spec)),
            ValueField("restart", textValue(spec.restartPolicy)),
            ValueField("persist", boolValue(spec.persist)),
            ValueField("detached", boolValue(spec.detached))
        ])
    }

    private func daemonOutput(state: ProductDaemonState): String {
        lock.lock()
        try { safeUtf8(state.output.toArray()) } finally { lock.unlock() }
    }

    private func daemonState(state: ProductDaemonState): String {
        lock.lock()
        try { state.state } finally { lock.unlock() }
    }

    private func daemonRecoveryRequired(state: ProductDaemonState): Bool {
        lock.lock()
        try { state.recoveryRequired } finally { lock.unlock() }
    }

    private func logSnapshot(name: String): ?ProductDaemonLogSnapshot {
        lock.lock()
        try {
            let state = match (findLocked(name)) {
                case Some(value) => value
                case None => return None
            }
            Some(ProductDaemonLogSnapshot(
                state.output.toArray(),
                state.logBaseCursor,
                state.logBaseCursor + state.output.size,
                state.state
            ))
        } finally {
            lock.unlock()
        }
    }

    private func brokerLogPath(name: String): String {
        if (!brokerMode) { return "" }
        brokerRoot + "/logs/" + name + ".log"
    }

    private func brokerRecordPath(name: String): String {
        brokerRoot + "/daemons/" + name + ".json"
    }

    private func persistState(state: ProductDaemonState): Unit {
        if (!brokerMode) { return }
        // Acquire the persistence lock before taking the snapshot. Otherwise
        // an older snapshot can stall, let a newer snapshot commit first, and
        // then overwrite that newer state when it eventually gets the lock.
        persistenceLock.lock()
        try {
            let encoded: String
            let path: String
            lock.lock()
            try {
                encoded = encodeAgentValue(daemonRecordValueLocked(state))
                path = brokerRecordPath(state.spec.name)
            } finally {
                lock.unlock()
            }
            if (encoded.size > 1048576) {
                setPersistenceWarning(
                    state,
                    "persistent process metadata exceeds the 1 MiB record limit"
                )
                return
            }
            match (atomicBrokerWrite(path, encoded, "600")) {
                case Result.Ok(_) => setPersistenceWarning(state, "")
                case Result.Err(error) => setPersistenceWarning(
                    state,
                    "persistent process state was not durably written: " +
                        error.message
                )
            }
        } finally {
            persistenceLock.unlock()
        }
    }

    private func setPersistenceWarning(
        state: ProductDaemonState,
        warning: String
    ): Unit {
        lock.lock()
        try { state.persistenceWarning = warning } finally { lock.unlock() }
    }

    private func daemonRecordValueLocked(state: ProductDaemonState): AgentValue {
        objectValue([
            ValueField("version", integerValue(2)),
            ValueField("id", textValue(state.id)),
            ValueField("owner", textValue(state.owner)),
            ValueField("createdAt", integerValue(state.createdAt)),
            ValueField("state", textValue(state.state)),
            ValueField("pid", integerValue(state.pid)),
            ValueField("startIdentity", textValue(state.startIdentity)),
            ValueField(
                "exitCode",
                match (state.exitCode) {
                    case Some(value) => integerValue(value)
                    case None => nullValue()
                }
            ),
            ValueField("exitReason", textValue(state.exitReason)),
            ValueField("startedAt", integerValue(state.startedAt)),
            ValueField("exitedAt", integerValue(state.exitedAt)),
            ValueField("readyAt", integerValue(state.readyAt)),
            ValueField("readyMatch", textValue(state.readyMatch)),
            ValueField("restartCount", integerValue(state.restartCount)),
            ValueField("generation", integerValue(state.generation)),
            ValueField("logBaseCursor", integerValue(state.logBaseCursor)),
            ValueField("spec", daemonSpecValue(state.spec))
        ])
    }

    private func restoreBrokerStates(): Unit {
        let root = brokerRoot + "/daemons"
        if (!exists(Path(root))) { return }
        try {
            for (entry in Directory.readFrom(root)) {
                if (!entry.name.endsWith(".json")) { continue }
                match (restoreBrokerState(root, entry.name)) {
                    case Some(state) =>
                        daemonCounter += 1
                        daemons.add(state)
                    case None => ()
                }
            }
        } catch (error: Exception) {
            addBrokerRecoveryWarning("daemons", error.message)
        }
    }

    private func restoreBrokerState(
        root: String,
        file: String
    ): ?ProductDaemonState {
        try {
            let path = Path(root).join(file).toString()
            let info = FileInfo(Path(path))
            if (!info.isRegular() || info.isSymbolicLink() ||
                info.size < 1 || info.size > 1048576) {
                addBrokerRecoveryWarning(file, "record is not a safe bounded regular file")
                return None
            }
            let value = match (decodeAgentValue(
                String.fromUtf8(File.readFrom(path)),
                maxBytes: 1048576
            )) {
                case Result.Ok(decoded) => decoded
                case Result.Err(error) =>
                    addBrokerRecoveryWarning(file, error.message)
                    return None
            }
            if (value.unifiedKind != ValueKind.Object ||
                daemonRecordInteger(value, "version", 0) != 2) {
                addBrokerRecoveryWarning(file, "record version is invalid")
                return None
            }
            let specValue = match (value.field("spec")) {
                case Some(item) => item
                case None =>
                    addBrokerRecoveryWarning(file, "record has no process specification")
                    return None
            }
            let spec = match (decodeDaemonSpecRecord(specValue, workspace)) {
                case Some(item) => item
                case None =>
                    addBrokerRecoveryWarning(file, "record process specification is invalid")
                    return None
            }
            let name = spec.name
            if (!safeDaemonName(name) || file != name + ".json") {
                addBrokerRecoveryWarning(file, "record name does not match its safe filename")
                return None
            }
            let id = daemonRecordText(value, "id")
            if (id == "") {
                addBrokerRecoveryWarning(file, "record has no process id")
                return None
            }
            let state = ProductDaemonState(
                spec,
                id,
                daemonRecordText(value, "owner"),
                createdAt: daemonRecordInteger(value, "createdAt", nowMillis()),
                logPath: brokerLogPath(name)
            )
            state.startedAt = daemonRecordInteger(value, "startedAt", state.createdAt)
            state.exitedAt = daemonRecordInteger(value, "exitedAt", 0)
            state.readyAt = daemonRecordInteger(value, "readyAt", 0)
            state.readyMatch = daemonRecordText(value, "readyMatch")
            state.restartCount = daemonRecordInteger(value, "restartCount", 0)
            state.generation = daemonRecordInteger(value, "generation", 0)
            state.startIdentity = daemonRecordText(value, "startIdentity")
            state.exitReason = daemonRecordText(value, "exitReason")
            state.exitCode = daemonRecordOptionalInteger(value, "exitCode")
            state.logBaseCursor = daemonRecordInteger(value, "logBaseCursor", 0)
            restoreBrokerLog(state)

            let recordedState = daemonRecordText(value, "state")
            let recordedPid = daemonRecordInteger(value, "pid", 0)
            if (daemonTerminal(recordedState)) {
                state.state = recordedState
                state.pid = 0
            } else {
                let live = brokerProcessIdentityMatches(
                    recordedPid,
                    state.startIdentity
                )
                state.state = "recovery_required"
                state.recoveryRequired = true
                state.stale = !live
                state.pid = if (live) { recordedPid } else { 0 }
                state.exitReason = if (live) {
                    "broker restarted; process ownership requires reconciliation"
                } else {
                    "recorded process identity is stale"
                }
            }
            Some(state)
        } catch (error: Exception) {
            addBrokerRecoveryWarning(file, error.message)
            None
        }
    }

    private func addBrokerRecoveryWarning(
        file: String,
        reason: String
    ): Unit {
        recoveryWarnings.add(
            "process recovery warning: file=" + file + " reason=" + reason
        )
    }

    private func restoreBrokerLog(state: ProductDaemonState): Unit {
        if (state.logPath == "" || !exists(Path(state.logPath))) { return }
        try {
            let info = FileInfo(Path(state.logPath))
            if (!info.isRegular() || info.size > maxLogBytes) {
                state.logBaseCursor += max(0, info.size)
                return
            }
            let bytes = File.readFrom(state.logPath)
            for (byte in bytes) { state.output.add(byte) }
        } catch (_: Exception) {}
    }

    private func stopRecoveredProcess(
        state: ProductDaemonState,
        pid: Int64,
        identity: String,
        timeoutMillis: Int64
    ): Unit {
        if (!brokerProcessIdentityMatches(pid, identity)) {
            lock.lock()
            try {
                state.pid = 0
                state.stale = true
                state.state = "recovery_required"
                state.exitReason = "recorded process identity is stale"
            } finally {
                lock.unlock()
            }
            return
        }
        let _ = signalProcessTree(pid, "SIGTERM")
        let started = nowMillis()
        while (brokerProcessIdentityMatches(pid, identity) &&
            nowMillis() - started < timeoutMillis) {
            sleep(Duration.millisecond * 10)
        }
        if (brokerProcessIdentityMatches(pid, identity)) {
            let _ = signalProcessTree(pid, "SIGKILL")
            let killStarted = nowMillis()
            while (brokerProcessIdentityMatches(pid, identity) &&
                nowMillis() - killStarted < 1000) {
                sleep(Duration.millisecond * 10)
            }
        }
        lock.lock()
        try {
            let stillLive = brokerProcessIdentityMatches(pid, identity)
            state.pid = if (stillLive) { pid } else { 0 }
            state.stale = stillLive
            state.recoveryRequired = stillLive
            state.state = if (stillLive) { "recovery_required" } else { "exited" }
            state.exitedAt = if (stillLive) { 0 } else { nowMillis() }
            state.exitReason = if (stillLive) {
                "recovered process did not stop"
            } else {
                "stopped after broker recovery"
            }
        } finally {
            lock.unlock()
        }
    }
}

class ProductDaemonLogSnapshot {
    let bytes: Array<Byte>
    let baseCursor: Int64
    let cursor: Int64
    let state: String

    init(
        bytes: Array<Byte>,
        baseCursor: Int64,
        cursor: Int64,
        state: String
    ) {
        this.bytes = bytes
        this.baseCursor = baseCursor
        this.cursor = cursor
        this.state = state
    }
}

func decodeDaemonSpecRecord(
    value: AgentValue,
    workspace: LocalWorkspace
): ?ProductDaemonSpec {
    if (value.unifiedKind != ValueKind.Object) { return None }
    let name = daemonRecordText(value, "name")
    let application = daemonRecordText(value, "application")
    if (!safeDaemonName(name) || application == "") { return None }
    let cwd = daemonRecordText(value, "cwd")
    let resolvedCwd = match (workspace.resolve(
        cwd,
        allowDirectory: true
    )) {
        case Result.Ok(item) => item
        case Result.Err(_) => return None
    }
    if (resolvedCwd != cwd) { return None }
    let arguments = match (daemonRecordStringList(value, "args")) {
        case Some(items) => items
        case None => return None
    }
    let environment = match (daemonRecordEnvironment(value, "env")) {
        case Some(items) => items
        case None => return None
    }
    let environmentBindings = match (daemonRecordEnvironmentBindings(value)) {
        case Some(items) => items
        case None => return None
    }
    let networkAllowed = daemonRecordBoolean(value, "network", false)
    let ready = value.field("ready")
    var readyLog = ""
    var readyPort: Int64 = 0
    var readyHost = "127.0.0.1"
    var readyTimeoutMillis: Int64 = 30000
    match (ready) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Object) {
                readyLog = daemonRecordText(item, "log")
                readyPort = daemonRecordInteger(item, "port", 0)
                let host = daemonRecordText(item, "host")
                if (host != "") { readyHost = host }
                readyTimeoutMillis = daemonRecordInteger(
                    item,
                    "timeoutMs",
                    30000
                )
            } else if (item.unifiedKind != ValueKind.Null) {
                return None
            }
        case None => ()
    }
    if (readyPort < 0 || readyPort > 65535 ||
        readyTimeoutMillis < 1 || readyTimeoutMillis > 3600000) {
        return None
    }
    if (readyPort != 0 && !networkAllowed) { return None }
    if (readyLog != "") {
        try {
            let _ = Regex(readyLog, [])
        } catch (_: Exception) {
            return None
        }
    }
    let restartPolicy = daemonRecordText(value, "restart")
    if (restartPolicy != "no" && restartPolicy != "on-failure" &&
        restartPolicy != "always") {
        return None
    }
    let persist = daemonRecordBoolean(value, "persist", false)
    let detached = daemonRecordBoolean(value, "detached", false)
    if (!persist && !detached) { return None }
    Some(ProductDaemonSpec(
        name,
        application,
        arguments,
        environment,
        environmentBindings,
        networkAllowed,
        cwd,
        if (detached) { false } else {
            daemonRecordBoolean(value, "pty", false)
        },
        readyLog,
        readyPort,
        readyHost,
        readyTimeoutMillis,
        restartPolicy,
        true,
        detached
    ))
}

func daemonRecordText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func daemonRecordInteger(
    value: AgentValue,
    name: String,
    fallback: Int64
): Int64 {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind != ValueKind.Number) { return fallback }
            try { Int64.parse(field.number) } catch (_: Exception) { fallback }
        case None => fallback
    }
}

func daemonRecordOptionalInteger(
    value: AgentValue,
    name: String
): ?Int64 {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind != ValueKind.Number) { return None }
            try { Some(Int64.parse(field.number)) } catch (_: Exception) { None }
        case None => None
    }
}

func daemonRecordBoolean(
    value: AgentValue,
    name: String,
    fallback: Bool
): Bool {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Boolean) { field.boolean } else { fallback }
        case None => fallback
    }
}

func daemonRecordStringList(
    value: AgentValue,
    name: String
): ?Array<String> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return Some([])
    }
    if (field.unifiedKind != ValueKind.List) { return None }
    let values = ArrayList<String>()
    for (item in field.items) {
        if (item.unifiedKind != ValueKind.Text) { return None }
        values.add(item.text)
    }
    Some(values.toArray())
}

func daemonRecordEnvironment(
    value: AgentValue,
    name: String
): ?HashMap<String, String> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return Some(HashMap<String, String>())
    }
    if (field.unifiedKind != ValueKind.Object) { return None }
    let result = HashMap<String, String>()
    for (item in field.fields) {
        if (!validEnvironmentName(item.name) ||
            directSecretName(item.name) ||
            item.value.unifiedKind != ValueKind.Text ||
            item.value.text.contains("\u{0000}")) {
            return None
        }
        result[item.name] = item.value.text
    }
    Some(result)
}

func daemonRecordEnvironmentBindings(
    value: AgentValue
): ?Array<DirectEnvironmentBinding> {
    let bindings = ArrayList<DirectEnvironmentBinding>()
    let targets = ArrayList<String>()
    for (section in ["env_from", "secret_env"]) {
        let field = match (value.field(section)) {
            case Some(item) => item
            case None => continue
        }
        if (field.unifiedKind != ValueKind.Object) { return None }
        for (item in field.fields) {
            if (item.value.unifiedKind != ValueKind.Text ||
                directContains(targets, item.name)) {
                return None
            }
            let binding = try {
                DirectEnvironmentBinding(
                    item.name,
                    item.value.text,
                    secret: section == "secret_env"
                )
            } catch (_: Exception) {
                return None
            }
            targets.add(item.name)
            bindings.add(binding)
        }
    }
    let literals = match (daemonRecordEnvironment(value, "env")) {
        case Some(items) => items
        case None => return None
    }
    for ((name, _) in literals) {
        if (directContains(targets, name)) { return None }
    }
    Some(bindings.toArray())
}

func brokerProcessIdentityMatches(pid: Int64, expected: String): Bool {
    if (pid <= 0 || expected == "") { return false }
    let current = linuxProcessStartToken(
        "/proc/" + pid.toString() + "/stat"
    )
    current != "" && current == expected
}

func requiredDaemonName(call: ToolCall): Result<String> {
    let name = daemonText(call, "name")
    if (name == "" || name.size > 48 || !safeDaemonName(name)) {
        return supervisorError<String>(
            "hub.process_name_invalid",
            "process name must contain 1-48 letters, digits, '-', '_' or '.'"
        )
    }
    Result.Ok(name)
}

func safeDaemonName(value: String): Bool {
    let bytes = unsafe { value.rawData() }
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (index == 0 &&
            !((byte >= b'a' && byte <= b'z') ||
                (byte >= b'A' && byte <= b'Z') ||
                (byte >= b'0' && byte <= b'9'))) {
            return false
        }
        if (!((byte >= b'a' && byte <= b'z') ||
            (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') ||
            byte == b'-' || byte == b'_' || byte == b'.')) {
            return false
        }
    }
    true
}

func daemonText(call: ToolCall, name: String): String {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                value.text.trimAscii()
            } else {
                ""
            }
        case None => ""
    }
}

func daemonValueText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) {
                field.text.trimAscii()
            } else {
                ""
            }
        case None => ""
    }
}

func daemonInteger(
    call: ToolCall,
    name: String,
    fallback: Int64
): Int64 {
    match (call.arguments.field(name)) {
        case Some(value) =>
            try {
                Int64.parse(value.number)
            } catch (_: Exception) {
                fallback
            }
        case None => fallback
    }
}

func daemonValueInteger(
    value: AgentValue,
    name: String,
    fallback: Int64
): Int64 {
    match (value.field(name)) {
        case Some(field) =>
            try {
                Int64.parse(field.number)
            } catch (_: Exception) {
                fallback
            }
        case None => fallback
    }
}

func daemonBoolean(
    call: ToolCall,
    name: String,
    fallback: Bool
): Bool {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Boolean) {
                value.boolean
            } else {
                fallback
            }
        case None => fallback
    }
}

func daemonStringList(
    call: ToolCall,
    name: String
): Result<Array<String>> {
    match (call.arguments.field(name)) {
        case None => Result.Ok([])
        case Some(value) =>
            if (value.unifiedKind != ValueKind.List) {
                return supervisorError<Array<String>>(
                    "hub.process_string_list_invalid",
                    name + " must be a string array"
                )
            }
            let values = ArrayList<String>()
            for (item in value.items) {
                if (item.unifiedKind != ValueKind.Text) {
                    return supervisorError<Array<String>>(
                        "hub.process_string_list_invalid",
                        name + " must be a string array"
                    )
                }
                values.add(item.text)
            }
            Result.Ok(values.toArray())
    }
}

func daemonEnvironment(
    call: ToolCall
): Result<HashMap<String, String>> {
    let result = HashMap<String, String>()
    match (call.arguments.field("env")) {
        case None => Result.Ok(result)
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Object) {
                return supervisorError<HashMap<String, String>>(
                    "hub.process_env_invalid",
                    "env must be an object of string values"
                )
            }
            for (field in value.fields) {
                if (field.value.unifiedKind != ValueKind.Text ||
                    !validEnvironmentName(field.name) ||
                    directSecretName(field.name) ||
                    field.value.text.contains("\u{0000}")) {
                    return supervisorError<HashMap<String, String>>(
                        "hub.process_env_invalid",
                        "env accepts only non-secret literal values; use secret_env for credentials"
                    )
                }
                result[field.name] = field.value.text
            }
            Result.Ok(result)
    }
}

func daemonEnvironmentBindings(
    call: ToolCall
): Result<Array<DirectEnvironmentBinding>> {
    let bindings = ArrayList<DirectEnvironmentBinding>()
    let targets = ArrayList<String>()
    for (section in ["env_from", "secret_env"]) {
        match (call.arguments.field(section)) {
            case None => ()
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Object) {
                    return supervisorError<Array<DirectEnvironmentBinding>>(
                        "hub.process_env_binding_invalid",
                        section + " must map target names to host source names"
                    )
                }
                for (field in value.fields) {
                    if (field.value.unifiedKind != ValueKind.Text ||
                        directContains(targets, field.name)) {
                        return supervisorError<Array<DirectEnvironmentBinding>>(
                            "hub.process_env_binding_invalid",
                            "environment targets must be unique string mappings"
                        )
                    }
                    let binding = try {
                        DirectEnvironmentBinding(
                            field.name,
                            field.value.text,
                            secret: section == "secret_env"
                        )
                    } catch (error: Exception) {
                        return supervisorError<Array<DirectEnvironmentBinding>>(
                            "hub.process_env_binding_invalid",
                            error.message
                        )
                    }
                    targets.add(field.name)
                    bindings.add(binding)
                }
        }
    }
    for ((name, _) in match (daemonEnvironment(call)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }) {
        if (directContains(targets, name)) {
            return supervisorError<Array<DirectEnvironmentBinding>>(
                "hub.process_env_binding_invalid",
                "environment target is declared more than once"
            )
        }
    }
    Result.Ok(bindings.toArray())
}

func hasReadiness(spec: ProductDaemonSpec): Bool {
    spec.readyLog != "" || spec.readyPort != 0
}

func daemonTerminal(state: String): Bool {
    state == "exited" || state == "failed"
}

func secondsToMillis(value: Int64, fallback: Int64): Int64 {
    let seconds = if (value <= 0) { fallback } else { value }
    min(3600, seconds) * 1000
}

func tcpReady(host: String, port: Int64): Bool {
    if (port < 1 || port > 65535) { return false }
    let socket = try {
        TcpSocket(host, UInt16(port))
    } catch (_: Exception) {
        return false
    }
    try {
        socket.connect(timeout: Some(Duration.millisecond * 100))
        socket.close()
        true
    } catch (_: Exception) {
        socket.close()
        false
    }
}

func signalProcessTree(pid: Int64, signal: String): Result<Unit> {
    let suffix = match (signal) {
        case "SIGINT" => "INT"
        case "SIGTERM" => "TERM"
        case "SIGHUP" => "HUP"
        case "SIGQUIT" => "QUIT"
        case "SIGKILL" => "KILL"
        case _ =>
            return supervisorError<Unit>(
                "hub.process_signal_invalid",
                "unsupported signal: " + signal
            )
    }
    let (groupCode, _, groupError) = executeWithOutput(
        "kill",
        ["-" + suffix, "--", "-" + pid.toString()]
    )
    if (groupCode == 0) {
        Result.Ok(())
    } else {
        // A sandbox wrapper can own the child without being a process-group
        // leader in the host namespace. Signal the already-owned root PID as
        // a fail-closed fallback; bwrap's --die-with-parent then tears down
        // the isolated descendants. Report failure only when neither target
        // accepted the signal.
        let (rootCode, _, rootError) = executeWithOutput(
            "kill",
            ["-" + suffix, "--", pid.toString()]
        )
        if (rootCode == 0) {
            Result.Ok(())
        } else {
            supervisorError<Unit>(
                "hub.process_signal_failed",
                String.fromUtf8(groupError).trimAscii() + "; root: " +
                    String.fromUtf8(rootError).trimAscii()
            )
        }
    }
}

func shellCommand(
    application: String,
    arguments: Array<String>
): String {
    var result = shellQuote(application)
    for (argument in arguments) {
        result += " " + shellQuote(argument)
    }
    result
}

func launchKey(key: String): ?String {
    match (key.trimAscii()) {
        case "ENTER" | "enter" => Some("\r")
        case "TAB" | "tab" => Some("\t")
        case "ESCAPE" | "escape" => Some("\u{1b}")
        case "CTRL_C" | "ctrl_c" => Some("\u{3}")
        case "CTRL_D" | "ctrl_d" => Some("\u{4}")
        case "UP" | "up" => Some("\u{1b}[A")
        case "DOWN" | "down" => Some("\u{1b}[B")
        case "RIGHT" | "right" => Some("\u{1b}[C")
        case "LEFT" | "left" => Some("\u{1b}[D")
        case _ => None
    }
}

func readinessPendingValue(state: ProductDaemonState): AgentValue {
    if (state.state != "starting") { return listValue([]) }
    let values = ArrayList<AgentValue>()
    if (state.spec.readyLog != "" && state.readyMatch == "") {
        values.add(textValue("log"))
    }
    if (state.spec.readyPort != 0 && state.readyAt == 0) {
        values.add(textValue("port"))
    }
    listValue(values.toArray())
}

func processEnvironmentValue(
    environment: HashMap<String, String>
): AgentValue {
    let fields = ArrayList<ValueField>()
    for ((name, value) in environment) {
        fields.add(ValueField(name, textValue(value)))
    }
    objectValue(fields.toArray())
}

func processEnvironmentBindingsValue(
    bindings: Array<DirectEnvironmentBinding>,
    secret: Bool
): AgentValue {
    let fields = ArrayList<ValueField>()
    for (binding in bindings where binding.secret == secret) {
        fields.add(ValueField(binding.target, textValue(binding.source)))
    }
    objectValue(fields.toArray())
}

func daemonLiteralEnvironment(
    environment: HashMap<String, String>
): Array<SandboxEnvironmentEntry> {
    let entries = ArrayList<SandboxEnvironmentEntry>()
    for ((name, value) in environment) {
        entries.add(SandboxEnvironmentEntry(name, value))
    }
    entries.toArray()
}

// Stream redaction must retain a tail so a credential split across two pipe
// reads is never persisted or exposed through hub logs.
class ProductDaemonByteRedactor {
    private let patterns = ArrayList<Array<Byte>>()
    private let carry = ArrayList<Byte>()
    private let marker = "[REDACTED]".toArray()
    private var maximum: Int64 = 0

    init(secretValues: Array<String>) {
        for (value in secretValues) {
            let bytes = value.toArray()
            if (bytes.size < 4 || containsPattern(bytes)) { continue }
            patterns.add(bytes)
            maximum = max(maximum, bytes.size)
        }
    }

    func push(bytes: Array<Byte>): Array<Byte> {
        if (maximum == 0) { return bytes }
        let combined = ArrayList<Byte>()
        combined.add(all: carry)
        combined.add(all: bytes)
        carry.clear()
        let boundary = max(0, combined.size - (maximum - 1))
        redactPrefix(combined.toArray(), boundary)
    }

    func finish(): Array<Byte> {
        if (carry.isEmpty()) { return [] }
        let input = carry.toArray()
        carry.clear()
        redactAll(input)
    }

    private func redactPrefix(input: Array<Byte>, boundary: Int64): Array<Byte> {
        let output = ArrayList<Byte>()
        var index: Int64 = 0
        while (index < boundary) {
            let matched = longestMatch(input, index)
            if (matched > 0) {
                output.add(all: marker)
                index += matched
            } else {
                output.add(input[index])
                index += 1
            }
        }
        for (position in index..input.size) { carry.add(input[position]) }
        output.toArray()
    }

    private func redactAll(input: Array<Byte>): Array<Byte> {
        let output = ArrayList<Byte>()
        var index: Int64 = 0
        while (index < input.size) {
            let matched = longestMatch(input, index)
            if (matched > 0) {
                output.add(all: marker)
                index += matched
            } else {
                output.add(input[index])
                index += 1
            }
        }
        output.toArray()
    }

    private func longestMatch(input: Array<Byte>, start: Int64): Int64 {
        var best: Int64 = 0
        for (pattern in patterns) {
            if (pattern.size <= best || start + pattern.size > input.size) {
                continue
            }
            var equal = true
            for (offset in 0..pattern.size) {
                if (input[start + offset] != pattern[offset]) {
                    equal = false
                    break
                }
            }
            if (equal) { best = pattern.size }
        }
        best
    }

    private func containsPattern(candidate: Array<Byte>): Bool {
        for (pattern in patterns) {
            if (pattern.size != candidate.size) { continue }
            var equal = true
            for (index in 0..pattern.size) {
                if (pattern[index] != candidate[index]) {
                    equal = false
                    break
                }
            }
            if (equal) { return true }
        }
        false
    }
}

func daemonReadyValue(spec: ProductDaemonSpec): AgentValue {
    if (!hasReadiness(spec)) { return nullValue() }
    objectValue([
        ValueField(
            "log",
            if (spec.readyLog == "") {
                nullValue()
            } else {
                textValue(spec.readyLog)
            }
        ),
        ValueField(
            "port",
            if (spec.readyPort == 0) {
                nullValue()
            } else {
                integerValue(spec.readyPort)
            }
        ),
        ValueField("host", textValue(spec.readyHost)),
        ValueField(
            "timeoutMs",
            integerValue(spec.readyTimeoutMillis)
        )
    ])
}

func filterLogLines(
    source: String,
    pattern: String
): Result<String> {
    let regex = try {
        Regex(pattern, [])
    } catch (error: Exception) {
        return supervisorError<String>(
            "hub.process_grep_invalid",
            error.message
        )
    }
    let selected = ArrayList<String>()
    for (line in source.split("\n")) {
        if (regex.find(line).isSome()) { selected.add(line) }
    }
    Result.Ok(joinDaemonLines(selected.toArray()))
}

func selectLogLines(
    source: String,
    limit: Int64,
    head: Bool
): String {
    let lines = source.split("\n")
    if (lines.size <= limit) { return source }
    if (head) {
        joinDaemonLines(lines[0..limit])
    } else {
        joinDaemonLines(lines[lines.size - limit..lines.size])
    }
}

func joinDaemonLines(lines: Array<String>): String {
    var result = ""
    for (line in lines) {
        if (result != "") { result += "\n" }
        result += line
    }
    result
}

func processStringListValue(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) { items.add(textValue(value)) }
    listValue(items.toArray())
}

func supervisorError<T>(
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        code,
        message
    ))
}

func missingDaemon<T>(name: String): Result<T> {
    supervisorError<T>(
        "hub.process_not_found",
        "unknown process: " + name
    )
}
