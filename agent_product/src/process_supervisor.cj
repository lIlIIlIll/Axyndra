package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_host_runtime.*
import agent_runtime.*
import tool_runtime.*
import logical_json_payload.LogicalJsonOwnerReservation as ProcessTransientOwner180
import process4cj.*
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
    let networkPolicy: NetworkPolicy
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
        networkPolicy: NetworkPolicy,
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
        this.networkPolicy = networkPolicy
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
    var processHandle: ?DirectProcessHandle = None
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
    var readyLogCursor: Int64 = 0
    var launching = false
    var stopRequested: Bool = false
    var logBaseCursor: Int64 = 0
    var startIdentity: String = ""
    var recoveryRequired: Bool = false
    var stale: Bool = false
    var logPath: String = ""
    var persistenceWarning: String = ""
    var secretValues: Array<String> = []
    // Native's actual private incarnation owns every producer cell. None is
    // the unchanged legacy/Support route; production Native never uses it.
    var service180: ?HostHubDerivedProcessLease180 = None
    var recoveredIncarnation180:?ProcessIncarnationOwner180=None<ProcessIncarnationOwner180>
    var recoveredStopProducer180:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>
    var recoveredStopBusy180=false
    var nativeSpecification180: ?AgentValue = None
    var actualOutput180: ?HostHubProcessProducerCell = None
    var actualError180: ?HostHubProcessProducerCell = None
    var actualMonitor180: ?HostHubProcessProducerCell = None
    var actualLaunchCaller180:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>
    var actualShutdown180:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>
    var nativeLaunchHelperReturned180=false
    var actualReadiness180: ?HostHubProcessProducerCell = None
    var actualClose180: ?HostHubProcessProducerCell = None
    var actualNetworkRelease180: ?HostHubProcessProducerCell = None
    var nativeCleanupReturned180=false
    var actualController180: ?HostHubProcessProducerCell = None
    var nativeGeneration180: Int64 = 0
    var nativeJoinedGeneration180: Int64 = 0
    var nativePid180: Int64 = 0
    var nativeStartIdentity180: String = ""
    var nativeRestartPending180 = false
    // Unknown spawn or process-close failures leave the handle reachable.
    var retainedOpened180: ?DirectProcessHandle = None
    var nativeStartCell180:?DirectOwnedStartCell180=None<DirectOwnedStartCell180>
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
    private let shellNetworkMode: ShellNetworkMode
    private let sandboxCaBundle: String
    private let lock = Mutex()
    private let daemons = ArrayList<ProductDaemonState>()
    private let maxLogBytes: Int64 = 1048576
    private let brokerRoot: String
    private let brokerMode: Bool
    private let brokerRootData180:?ActualProcessBrokerRoot180
    private let persistenceLock = Mutex()
    private let recoveryWarnings = ArrayList<String>()
    private var daemonCounter: Int64 = 0

    init(
        workspace: LocalWorkspace,
        brokerRoot!: String = "",
        sandboxEnabled!: Bool = false,
        allowUnsafeTestBypass!: Bool = false,
        shellNetworkMode!: ShellNetworkMode = ShellNetworkMode.Restricted,
        sandboxCaBundle!: String = "",
        brokerRootData180!: ?ActualProcessBrokerRoot180 = None<ActualProcessBrokerRoot180>
    ) {
        this.workspace = workspace
        this.sandboxEnabled = sandboxEnabled
        this.allowUnsafeTestBypass = allowUnsafeTestBypass
        this.brokerRoot = brokerRoot
        this.brokerMode = brokerRoot != ""
        this.brokerRootData180=brokerRootData180
        this.shellNetworkMode = shellNetworkMode
        this.sandboxCaBundle = sandboxCaBundle.trimAscii()
    }

    func initializeBrokerStorage180(): Unit {
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

    // Observation of real process/recovery owners only. In particular an
    // unresolved restored incarnation is not permission to stop that process.
    func hasOwnerLifetimeDebt180(): Bool {
        lock.lock(); try {
            for (state in daemons) {
                if (state.launching || state.process.isSome() || state.processHandle.isSome() ||
                    state.recoveryRequired || state.recoveredIncarnation180.isSome() ||
                    state.recoveredStopProducer180.isSome() || state.recoveredStopBusy180 ||
                    state.retainedOpened180.isSome() || state.nativeStartCell180.isSome() ||
                    state.actualOutput180.isSome() || state.actualError180.isSome() || state.actualMonitor180.isSome() ||
                    state.actualLaunchCaller180.isSome() || state.actualShutdown180.isSome() || state.actualReadiness180.isSome() ||
                    state.actualClose180.isSome() || state.actualNetworkRelease180.isSome() || state.actualController180.isSome() ||
                    state.nativeRestartPending180) { return true }
            }
            false
        } finally { lock.unlock() }
    }
    func close(): Unit {
        // Only the actual Native records use this owned close. Historical
        // Support entries retain the original stop/timeout/error behavior.
        closeActualNativeOwners180()
        let values = ArrayList<ProductDaemonState>()
        lock.lock()
        try {
            for (state in daemons) { values.add(state) }
        } finally {
            lock.unlock()
        }
        for (state in values) { if(state.service180.isNone()){let _ = stopState(state, 1000)} }
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
        let generation = match (launchState(state, false)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var timedOut = false
        if (hasReadiness(spec)) {
            timedOut = !waitForReady(state, spec.readyTimeoutMillis, generation)
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
        let requestedNetwork = match (call.arguments.field("network")) {
            case Some(_) => match (daemonNetworkPolicy(
                call,
                defaultMode: shellNetworkMode
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            case None => return supervisorError<ToolResult>(
                "network.restart_policy_required",
                "hub.restart must restate the persisted network policy"
            )
        }
        if (!networkPoliciesEqual(requestedNetwork, state.spec.networkPolicy)) {
            return supervisorError<ToolResult>(
                "hub.process_network_policy_changed",
                "restart network policy does not match the persisted service specification"
            )
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
            case Result.Ok(generation) =>
                if (hasReadiness(state.spec)) {
                    let _ = waitForReady(
                        state,
                        state.spec.readyTimeoutMillis,
                        generation
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
        let networkPolicy = match (daemonNetworkPolicy(
            call,
            defaultMode: shellNetworkMode
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
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
                if (ready.field("host").isSome() && readyHost != "127.0.0.1") {
                    return supervisorError<ProductDaemonSpec>(
                        "hub.process_ready_host_invalid",
                        "ready.host must be 127.0.0.1"
                    )
                }
                if (ready.field("port").isSome() &&
                    (readyPort < 1 || readyPort > 65535)) {
                    return supervisorError<ProductDaemonSpec>(
                        "hub.process_ready_port_invalid",
                        "ready.port must be an integer from 1 to 65535"
                    )
                }
                if (readyPort != 0 && networkPolicyModeIsDenied(networkPolicy.mode)) {
                    return supervisorError<ProductDaemonSpec>(
                        "hub.process_ready_network_required",
                        "ready.port requires a non-denied network policy"
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
            networkPolicy,
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

    // The selected Native supplies the exact frozen request. These resource
    // siblings observe the real process; they never call the old Hub parser.
    func observeNativeProcess180(request:AgentValue,owner:String,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        match(lease.validateActualRequest180(request)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let op=processRequestText180(request,"op")
        if(op=="start"){return startNativeProcess180(request.field("spec").getOrThrow(),owner,lease)}
        if(op=="ps"){
            lock.lock()
            try{
                for(state in daemons){fundNativeStateSnapshotLocked180(state,lease)}
                for(warning in recoveryWarnings){lease.retainData180(processInvoice180(warning.size,4,4096),4)}
                lease.retainData180(processInvoice180(daemons.size,4096,4096),daemons.size*4+8)
                let facts=ArrayList<AgentValue>()
                for(state in daemons){facts.add(daemonValueLocked(state))}
                return nativeProcessObservation180(op,objectValue([ValueField("daemons",listValue(facts.toArray())),
                    ValueField("recovery_warnings",processStringListValue(recoveryWarnings.toArray()))]))
            }finally{lock.unlock()}}
        let name=processRequestText180(request,"name")
        let state=match(stateByName(name)){case Some(value)=>value;case None=>return missingDaemon<ToolResult>(name)}
        if(op=="logs"){return nativeProcessLogWindow180(request,state,lease)}
        if(op=="wait"){return nativeProcessWait180(request,state,lease)}
        if(op=="stop" || op=="restart" || op=="send"){
            match(verifyNativeTarget180(request,state,lease)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
        if(op=="stop"){
            match(stopOwnedState180(state,Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText()),lease)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        }else if(op=="restart"){
            lease.fundBorrowedDataBeforeCopy180(request.field("network").getOrThrow())
            let requested=match(parseNetworkPolicy(request.field("network").getOrThrow())){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(!networkPoliciesEqual(requested,state.spec.networkPolicy)){
                return supervisorError<ToolResult>("hub.process_network_policy_changed",
                    "restart network policy does not match the persisted service specification")}
            lock.lock();let recovered=try{state.service180.isNone() && state.recoveryRequired}finally{lock.unlock()}
            match(stopOwnedState180(state,5000,lease)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(recovered){
                // The historical row has no Source. Its exact complete spec
                // was frozen by capture/verify; the actual new canonical
                // restart child, Root ticket and current/effect bridge own the
                // replacement. Nothing recreates the previous start Source.
                match(lease.authorizeRecoveredRestart180(request.field("actual_target").getOrThrow())){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                lock.lock();try{
                    if(state.service180.isSome() || state.process.isSome() || state.launching){
                        return supervisorError<ToolResult>("hub.process_recovery_superseded","actual recovered restart was superseded")}
                    lease.fundBorrowedDataBeforeCopy180(request.field("actual_target").getOrThrow().field("spec").getOrThrow())
                    state.nativeSpecification180=Some(request.field("actual_target").getOrThrow().field("spec").getOrThrow())
                    state.service180=Some(lease);state.stopRequested=false
                }finally{lock.unlock()}
                match(launchOwnedState180(state,true,lease)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(generation)=>
                    if(hasReadiness(state.spec)){let _=waitForReadyOwned180(state,state.spec.readyTimeoutMillis,generation,lease)}}
            }else{
                match(joinNativeIncarnation180(state)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                if(!reapNativeRestartController180(state)){
                    return supervisorError<ToolResult>("hub.process_producers_retained","actual restart controller has not returned")}
                let original=state.service180.getOrThrow()
                match(original.authorizeExplicitRestart180(lease,request.field("actual_target").getOrThrow())){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                lock.lock();try{state.stopRequested=false}finally{lock.unlock()}
                match(launchState(state,true)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(generation)=>
                    if(hasReadiness(state.spec)){let _=waitForReadyOwned180(state,state.spec.readyTimeoutMillis,generation,original)}}
            }
        }else if(op=="send"){
            if(daemonRecoveryRequired(state)){return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "hub.process_recovery_required","process input cannot be recovered after the broker restarted",
                fields:[ErrorField("name",name)]))}
            let process=match(liveProcess(state)){case Some(value)=>value
                case None=>return supervisorError<ToolResult>("hub.process_not_running","process is not running: "+name)}
            match(lease.withPhysicalEffect180({=>
                let signal=processRequestText180(request,"signal")
                if(signal!=""){lease.signalActualOpenedProcess180(process,signal)}
                // Native retains any original post-signal parameter failure.
                // It must be emitted after the actual original signal effect.
                match(request.field("stdin_error")){case Some(value)=>if(value.unifiedKind!=ValueKind.Null){
                    return supervisorError<Unit>(processRequestText180(value,"code"),processRequestText180(value,"message"))}
                    case None=>()}
                let data=processRequestText180(request,"stdin")
                lease.retainData180(processInvoice180(data.size,2,4096),2)
                if(data!=""){process.writeStdin(data.toArray());process.flushInput()}
                Result<Unit>.Ok(())})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        }else if(op!="describe"){
            return supervisorError<ToolResult>("hub.process_op_invalid","unsupported process operation: "+op)}
        lock.lock()
        try{
            fundNativeStateSnapshotLocked180(state,lease)
            let fields=ArrayList<ValueField>([ValueField("daemon",daemonValueLocked(state))])
            if(op=="describe"){
                match(state.nativeSpecification180){case Some(spec)=>lease.fundBorrowedDataBeforeCopy180(spec);case None=>()}
                fields.add(ValueField("spec",daemonSpecValue(state.spec)))}
            nativeProcessObservation180(op,objectValue(fields.toArray()))
        }finally{lock.unlock()}
    }
    func retainsActualNativeService180(lease:HostHubDerivedProcessLease180):Bool{
        lock.lock();try{for(state in daemons){if(state.service180.isSome() && refEq(state.service180.getOrThrow(),lease)){return true}};false}
        finally{lock.unlock()}
    }
    func captureNativeProcessTarget180(request:AgentValue,meter:HostPaidValueProjection151):AgentValue{
        let op=processRequestText180(request,"op")
        if(op=="start" || op=="ps"){return nullValue()}
        lock.lock()
        try{
            let state=match(findLocked(processRequestText180(request,"name"))){case Some(value)=>value;case None=>return nullValue()}
            meter.fundAdditional151(processInvoice180(state.id.size,2,processInvoice180(state.startIdentity.size,2,4096)),8)
            fundNativeSpecTargetBeforeCopy180(state.spec,{bytes,nodes=>meter.fundAdditional151(bytes,nodes)})
            objectValue([ValueField("id",textValue(state.id)),ValueField("generation",integerValue(state.generation)),
                ValueField("pid",integerValue(state.pid)),ValueField("start_identity",textValue(state.startIdentity)),
                ValueField("spec",daemonSpecValue(state.spec))])
        }finally{lock.unlock()}
    }
    private func verifyNativeTarget180(request:AgentValue,state:ProductDaemonState,lease:HostHubDerivedProcessLease180):Result<Unit>{
        match(lease.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let target=request.field("actual_target").getOrThrow()
        lock.lock()
        try{if(target.unifiedKind!=ValueKind.Object || processRequestText180(target,"id")!=state.id ||
                target.field("generation").getOrThrow().asNumberText()!=state.generation.toString() ||
                target.field("pid").getOrThrow().asNumberText()!=state.pid.toString() ||
                processRequestText180(target,"start_identity")!=state.startIdentity){
                return supervisorError<Unit>("hub.process_target_changed","actual process incarnation changed after canonical preparation")}
            // The entire saved command/network/readiness policy is frozen
            // under the same lock as the actual incarnation, before admission.
            fundNativeSpecTargetBeforeCopy180(state.spec,{bytes,nodes=>lease.retainData180(bytes,nodes)})
            lease.fundBorrowedDataBeforeCopy180(target.field("spec").getOrThrow())
            if(canonicalAgentValue(daemonSpecValue(state.spec))!=canonicalAgentValue(target.field("spec").getOrThrow())){
                return supervisorError<Unit>("hub.process_target_changed","actual saved process specification changed after preparation")}
            Result<Unit>.Ok(())}finally{lock.unlock()}
    }
    private func fundNativeSpecTargetBeforeCopy180(spec:ProductDaemonSpec,fund:(Int64,Int64)->Unit):Unit{
        // Borrow every variable extent before the original DOM/codec copies.
        fund(65536,64)
        fund(processInvoice180(spec.name.size,16,4096),4)
        fund(processInvoice180(spec.application.size,16,4096),4)
        fund(processInvoice180(spec.cwd.size,16,4096),4)
        fund(processInvoice180(spec.readyLog.size,16,4096),4)
        fund(processInvoice180(spec.readyHost.size,16,4096),4)
        fund(processInvoice180(spec.restartPolicy.size,16,4096),4)
        for(value in spec.arguments){fund(processInvoice180(value.size,16,4096),4)}
        for((name,value) in spec.environment){fund(processInvoice180(name.size,16,4096),4);fund(processInvoice180(value.size,16,4096),4)}
        for(value in spec.environmentBindings){fund(processInvoice180(value.target.size,16,4096),4);fund(processInvoice180(value.source.size,16,4096),4)}
        for(rule in spec.networkPolicy.egress){fund(processInvoice180(rule.host.size,16,4096),8)
            for(address in rule.privateAddresses){fund(processInvoice180(address.size,16,4096),4)}}
        fund(processInvoice180(spec.networkPolicy.publish.size,4096,4096),spec.networkPolicy.publish.size*8+8)
    }
    private func fundNativeStateSnapshotLocked180(state:ProductDaemonState,lease:HostHubDerivedProcessLease180):Unit{
        // No list/string/DOM snapshot exists before the exact borrowed extents
        // are paid. Use scalar calls rather than constructing a text array.
        lease.retainData180(65536,64)
        fundNativeText180(lease,state.id);fundNativeText180(lease,state.owner)
        fundNativeText180(lease,state.state);fundNativeText180(lease,state.exitReason)
        fundNativeText180(lease,state.readyMatch);fundNativeText180(lease,state.startIdentity)
        fundNativeText180(lease,state.logPath);fundNativeText180(lease,state.persistenceWarning)
        fundNativeText180(lease,state.spec.name);fundNativeText180(lease,state.spec.application)
        fundNativeText180(lease,state.spec.cwd);fundNativeText180(lease,state.spec.readyLog)
        fundNativeText180(lease,state.spec.readyHost);fundNativeText180(lease,state.spec.restartPolicy)
        for(text in state.spec.arguments){fundNativeText180(lease,text)}
        for((name,value) in state.spec.environment){fundNativeText180(lease,name);fundNativeText180(lease,value)}
        for(binding in state.spec.environmentBindings){fundNativeText180(lease,binding.target);fundNativeText180(lease,binding.source)}
    }
    private func fundNativeText180(lease:HostHubDerivedProcessLease180,text:String):Unit{
        lease.retainData180(processInvoice180(text.size,4,4096),4)
    }
    private func startNativeProcess180(value:AgentValue,owner:String,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        let spec=match(decodeNativeProcessSpec180(value,lease)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
        if(!brokerMode && (spec.persist || spec.detached)){
            return supervisorError<ToolResult>("hub.process_broker_required","persist and detached require the external launch broker")}
        if(brokerMode && !spec.persist){
            return supervisorError<ToolResult>("hub.process_broker_persist_required","the external launch broker only accepts persistent processes")}
        let previous=stateByName(spec.name)
        match(previous){case Some(existing)=>
            if(!daemonTerminal(daemonState(existing))){return supervisorError<ToolResult>("hub.process_exists","process already exists: "+spec.name)}
            // Do not hold the supervisor lock across actual Future.get; the
            // output/monitor producers need that same lock to return.
            match(joinNativeIncarnation180(existing)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(!reapNativeRestartController180(existing)){
                return supervisorError<ToolResult>("hub.process_producers_retained","actual restart controller has not returned")}
            case None=>()}
        let state:ProductDaemonState
        lock.lock()
        try{
            match(findLocked(spec.name)){case Some(existing)=>
                if(previous.isNone() || !refEq(previous.getOrThrow(),existing) || !daemonTerminal(existing.state)){
                    return supervisorError<ToolResult>("hub.process_exists","process already exists: "+spec.name)}
                for(index in 0..daemons.size){if(refEq(daemons[index],existing)){daemons.remove(at:index);break}}
                case None=>()}
            lease.retainData180(processInvoice180(owner.size,2,2097152),32)
            daemonCounter+=1
            state=ProductDaemonState(spec,"daemon-"+nowMillis().toString()+"-"+daemonCounter.toString(),owner,logPath:brokerLogPath(spec.name))
            state.service180=Some(lease);state.nativeSpecification180=Some(value);daemons.add(state)
        }finally{lock.unlock()}
        let generation=match(launchState(state,false)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
        let timedOut=hasReadiness(spec) && !waitForReadyOwned180(state,spec.readyTimeoutMillis,generation,lease)
        lock.lock();try{fundNativeStateSnapshotLocked180(state,lease)
            nativeProcessObservation180("start",objectValue([ValueField("daemon",daemonValueLocked(state)),
                ValueField("ready_timed_out",boolValue(timedOut))]))}finally{lock.unlock()}
    }
    private func decodeNativeProcessSpec180(value:AgentValue,lease:HostHubDerivedProcessLease180):Result<ProductDaemonSpec>{
        lease.fundBorrowedDataBeforeCopy180(value)
        let arguments=ArrayList<String>();let items=value.field("args").getOrThrow().asArray()
        for(index in 0..items.size()){arguments.add(items.get(index).getOrThrow().text)}
        let environment=HashMap<String,String>();let object=value.field("env").getOrThrow().asObject()
        for(index in 0..object.size()){environment[object.nameAt(index)]=object.valueAt(index).text}
        let bindings=ArrayList<DirectEnvironmentBinding>()
        let ordinary=value.field("env_from").getOrThrow().asObject()
        for(index in 0..ordinary.size()){bindings.add(DirectEnvironmentBinding(ordinary.nameAt(index),ordinary.valueAt(index).text))}
        let secret=value.field("secret_env").getOrThrow().asObject()
        for(index in 0..secret.size()){bindings.add(DirectEnvironmentBinding(secret.nameAt(index),secret.valueAt(index).text,secret:true))}
        let network=match(parseNetworkPolicy(value.field("network").getOrThrow())){case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
        let authored=processRequestText180(value,"cwd")
        let cwd=match(workspace.resolve(if(authored==""){workspace.rootPath()}else{authored},allowDirectory:true)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
        let ready=value.field("ready").getOrThrow();let present=ready.unifiedKind!=ValueKind.Null
        Result.Ok(ProductDaemonSpec(processRequestText180(value,"name"),processRequestText180(value,"application"),arguments.toArray(),
            environment,bindings.toArray(),network,cwd,value.field("pty").getOrThrow().asBool(),
            if(present){processRequestText180(ready,"log")}else{""},
            if(present && ready.field("port").getOrThrow().unifiedKind!=ValueKind.Null){Int64.parse(ready.field("port").getOrThrow().asNumberText())}else{0},
            if(present){processRequestText180(ready,"host")}else{"127.0.0.1"},
            if(present){Int64.parse(ready.field("timeoutMs").getOrThrow().asNumberText())}else{30000},processRequestText180(value,"restart"),
            value.field("persist").getOrThrow().asBool(),value.field("detached").getOrThrow().asBool()))
    }
    private func nativeProcessLogWindow180(request:AgentValue,state:ProductDaemonState,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        let cursor=Int64.parse(request.field("cursor").getOrThrow().asNumberText())
        let timeout=Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText());let started=nowMillis();var timedOut=false
        if(request.field("follow").getOrThrow().asBool() && request.field("cursor_present").getOrThrow().asBool()){
            while(true){match(lease.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                lock.lock();let changed=try{state.logBaseCursor+state.output.size>cursor || daemonTerminal(state.state)}finally{lock.unlock()}
                if(changed){break};if(nowMillis()-started>=timeout){timedOut=true;break};sleep(Duration.millisecond*10)}}
        lock.lock()
        try{
            fundNativeStateSnapshotLocked180(state,lease)
            lease.retainData180(processInvoice180(state.output.size,4,65536),16)
            let reset=cursor>=0 && cursor<state.logBaseCursor
            let offset=if(cursor>=0 && !reset){min(state.output.size,cursor-state.logBaseCursor)}else{0}
            let text=safeUtf8(state.output.toArray()[offset..state.output.size])
            nativeProcessObservation180("logs",objectValue([ValueField("name",textValue(state.spec.name)),ValueField("window_text",textValue(text)),
                ValueField("cursor",integerValue(state.logBaseCursor+state.output.size)),ValueField("timed_out",boolValue(timedOut)),
                ValueField("state",textValue(state.state)),ValueField("reset",boolValue(reset))]))
        }finally{lock.unlock()}
    }
    private func nativeProcessWait180(request:AgentValue,state:ProductDaemonState,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        let phase=lease.temporaryDataPhase180()
        try{return nativeProcessWaitBody180(request,state,lease,phase)}finally{phase.close()}
    }
    private func nativeProcessWaitBody180(request:AgentValue,state:ProductDaemonState,lease:HostHubDerivedProcessLease180,
        phase:ProcessTransientOwner180):Result<ToolResult>{
        let ready=processRequestText180(request,"condition")=="ready";let pattern=processRequestText180(request,"pattern")
        phase.ensureRetainedPeak(processInvoice180(pattern.size,16,65536))
        let expression:?Regex=if(pattern==""){None<Regex>}else{Some(Regex(pattern,[]))}
        let timeout=Int64.parse(request.field("timeout_ms").getOrThrow().asNumberText());let started=nowMillis()
        var timedOut=false;var matched=""
        while(true){
            match(lease.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            lock.lock()
            let done=try{
                phase.ensureRetainedPeak(processInvoice180(state.output.size,16,processInvoice180(pattern.size,16,65536)))
                if(state.recoveryRequired){timedOut=true;true}
                else{match(expression){case Some(value)=>match(value.find(safeUtf8(state.output.toArray()))){
                    case Some(found)=>lease.retainData180(processInvoice180(state.output.size,2,4096),4);matched=found.matchString();true
                    case None=>false}
                    case None=>if(ready){if(state.readyAt!=0 || state.state=="ready" || (state.state=="running" && !hasReadiness(state.spec))){true}
                        else if(daemonTerminal(state.state)){timedOut=true;true}else{false}}else{daemonTerminal(state.state)}}}
            }finally{lock.unlock()}
            if(done){break};if(nowMillis()-started>=timeout){timedOut=true;break};sleep(Duration.millisecond*10)}
        lock.lock();try{fundNativeStateSnapshotLocked180(state,lease)
            nativeProcessObservation180("wait",objectValue([ValueField("daemon",daemonValueLocked(state)),
                ValueField("timed_out",boolValue(timedOut)),ValueField("matched",if(matched==""){nullValue()}else{textValue(matched)})]))
        }finally{lock.unlock()}
    }
    private func nativeProcessObservation180(op:String,facts:AgentValue):Result<ToolResult>{
        Result.Ok(ToolResult("actual-process-resource",objectValue([ValueField("schema",textValue("axyndra.hub-process-observation/v1")),
            ValueField("op",textValue(op)),ValueField("facts",facts)])))
    }

    private func closeActualNativeOwners180():Unit{
        var index:Int64=0
        while(true){
            let state:?ProductDaemonState
            lock.lock();try{
                state=if(index<daemons.size){Some(daemons[index])}else{None<ProductDaemonState>}
                index+=1
            }finally{lock.unlock()}
            match(state){case None=>return;case Some(actual)=>
                if(actual.service180.isSome()){closeActualNativeStateWholeHelper180(actual)}}
        }
    }
    private func closeActualNativeStateWholeHelper180(state:ProductDaemonState):Unit{
        let lease:HostHubDerivedProcessLease180
        let cell:HostHubProcessProducerCell
        lock.lock();try{
            lease=state.service180.getOrThrow()
            match(state.actualShutdown180){case Some(previous)=>
                if(!previous.collectReturned() || !previous.retireObservedReturn()){
                    throw HostHubProcessHeldProducerFailure180(previous)}
                state.actualShutdown180=None<HostHubProcessProducerCell>;case None=>()}
            // Stable caller, closure, native frame and original snapshot
            // metadata are all paid BEFORE constructing/invoking that closure.
            lease.retainData180(65536+daemons.size*4096,daemons.size*8+32)
            cell=lease.reserveControlBeforeClosure180();cell.fundProducerFrameBeforeEffect180(524288)
            state.actualShutdown180=Some(cell)
        }finally{lock.unlock()}
        cell.invokeSynchronousHelper180({=>
            closeActualNativeBody180(state,lease,cell)
            match(joinNativeIncarnation180(state)){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}})
        cell.noteSynchronousHelperReturned180()
        if(cell.hasOriginalFailure180() || !cell.retireObservedReturn()){
            throw HostHubProcessHeldProducerFailure180(cell)}
        // Full caller/cleanup frame returned before detaching its registered
        // share. No cancellation request, main exit or count can retire it.
        lock.lock();try{state.actualShutdown180=None<HostHubProcessProducerCell>}finally{lock.unlock()}
    }
    private func closeActualNativeBody180(state:ProductDaemonState,lease:HostHubDerivedProcessLease180,
        cell:HostHubProcessProducerCell):Unit{
        let launch:?DirectOwnedStartCell180
        lock.lock();try{state.stopRequested=true;state.nativeRestartPending180=false;launch=state.nativeStartCell180}
        finally{lock.unlock()}
        match(launch){case Some(actual)=>
            // This is cleanup of the privately retained original incarnation,
            // not a new effect granted after Root/generation revocation.
            if(!actual.nativePhysicalResourcesReturned180()){
                actual.signalOriginalNativeCleanup180("SIGTERM",cell)}
            let started=nowMillis()
            while(!actual.nativePhysicalResourcesReturned180() && nowMillis()-started<1000){sleep(Duration.millisecond*10)}
            if(!actual.nativePhysicalResourcesReturned180()){actual.signalOriginalNativeCleanup180("SIGKILL",cell)}
            let forced=nowMillis()
            while(!actual.nativePhysicalResourcesReturned180() && nowMillis()-forced<1000){sleep(Duration.millisecond*10)}
            if(!actual.nativePhysicalResourcesReturned180()){
                throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                    "hub.process_stop_unconfirmed","owned process did not stop before the force deadline"))}
            case None=>lock.lock();try{if(state.launching){
                throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                    "hub.process_stop_unconfirmed","in-flight launch retains its actual paid owner"))}}
                finally{lock.unlock()}}
        let settled=nowMillis()
        while(!daemonTerminal(daemonState(state)) && nowMillis()-settled<1000){sleep(Duration.millisecond*10)}
        if(!daemonTerminal(daemonState(state))){throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
            "hub.process_stop_unsettled","process stopped but its monitor did not settle"))}
        // Original 1000ms close, force and settle windows are preserved. True
        // join/error ACK is separately required by the outer owner afterward.
    }

    private func launchOwnedState180(state:ProductDaemonState,restarting:Bool,lease:HostHubDerivedProcessLease180,
        expectedGeneration!:Int64=-1):Result<Int64>{
        let caller:HostHubProcessProducerCell
        lock.lock();try{
            match(state.actualLaunchCaller180){case Some(previous)=>
                if(!previous.collectReturned() || !previous.retireObservedReturn()){
                    return supervisorError<Int64>("hub.process_launch_caller_retained","previous launch helper/error is still owned")}
                state.actualLaunchCaller180=None<HostHubProcessProducerCell>
                case None=>()}
            caller=lease.reserveControlBeforeClosure180()
            state.actualLaunchCaller180=Some(caller);state.nativeLaunchHelperReturned180=false
            // Keep the complete original launch scratch invoice in this
            // actual caller, not forever in the daemon's retained DATA. The
            // state/spec/handle and asynchronous producers have separate paid
            // fields; only this whole helper's successful return retires it.
            caller.fundProducerFrameBeforeEffect180(65536 + 2097152 * 8 + 64 * 512 + 4096)
        }finally{lock.unlock()}
        let result=ProductActualLaunchResult180()
        caller.invokeSynchronousHelper180({=>
            match(launchOwnedStateBody180(state,restarting,lease,expectedGeneration:expectedGeneration)){
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(value)=>result.generation=Some(value)}})
        caller.noteSynchronousHelperReturned180()
        lock.lock();try{state.nativeLaunchHelperReturned180=true}finally{lock.unlock()}
        // This outer owner, not a controller counter, observes the entire
        // launch/SQL/spawn helper return. Running/unknown registrations stay
        // live; only a cell that never received an action is safe to retire.
        if(caller.hasOriginalFailure180()){
            try{resumePreparedCleanupAfterLaunchReturn180(state,lease)}
            catch(error:Exception){caller.retainActualCleanupFailure180(error)}
            // Primary remains the original launch failure even if its separate
            // physical cleanup also fails. Both remain in paid custody.
            throw HostHubProcessHeldProducerFailure180(caller)}
        let generation=result.generation.getOrThrow();result.generation=None<Int64>
        if(!caller.retireObservedReturn()){throw HostHubProcessHeldProducerFailure180(caller)}
        lock.lock();try{state.actualLaunchCaller180=None<HostHubProcessProducerCell>}finally{lock.unlock()}
        Result<Int64>.Ok(generation)
    }
    private func launchOwnedStateBody180(state:ProductDaemonState,restarting:Bool,lease:HostHubDerivedProcessLease180,
        expectedGeneration!:Int64=-1):Result<Int64>{
        match(lease.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        try{
            let actual=findLocked(state.spec.name)
            if(actual.isNone() || !refEq(actual.getOrThrow(),state) || state.launching || state.process.isSome() ||
                state.stopRequested || (expectedGeneration>=0 && state.generation!=expectedGeneration)){
                return supervisorError<Int64>("hub.process_launch_superseded","process launch was stopped or superseded")}
            if(state.nativeGeneration180!=0 && state.nativeJoinedGeneration180!=state.nativeGeneration180){
                return supervisorError<Int64>("hub.process_producers_retained","previous actual incarnation producers have not returned")}
            state.launching=true
        }finally{lock.unlock()}
        let generation=match(lease.beginPhysicalLaunch180()){
            case Result.Err(error)=>lock.lock();try{state.launching=false}finally{lock.unlock()};return Result.Err(error)
            case Result.Ok(value)=>value}
        lock.lock();try{state.generation=generation;state.nativeGeneration180=generation}finally{lock.unlock()}
        // Reserve the physical cleanup controller and its fixed Native
        // signal frame BEFORE launch. Bank pressure after a Source failure
        // must not require another allocation merely to stop the opened owner.
        prepareNativeRestartControllerBeforeLaunch180(state,lease)
        // No closure is allocated before its independent same-bank task share.
        // The actual state retains every cell even if a later spawn throws.
        let outCell=lease.reserveProducerBeforeClosure180()
        lock.lock();try{state.actualOutput180=Some(outCell)}finally{lock.unlock()}
        let errCell=lease.reserveProducerBeforeClosure180()
        lock.lock();try{state.actualError180=Some(errCell)}finally{lock.unlock()}
        let monitorCell=lease.reserveProducerBeforeClosure180()
        lock.lock();try{state.actualMonitor180=Some(monitorCell)}finally{lock.unlock()}
        let readyCell=if(hasReadiness(state.spec)){Some(lease.reserveProducerBeforeClosure180())}else{None<HostHubProcessProducerCell>}
        lock.lock();try{state.actualReadiness180=readyCell}finally{lock.unlock()}
        lease.retainData180(4096,8)
        let launchCell=DirectOwnedStartCell180()
        lock.lock();try{state.nativeStartCell180=Some(launchCell)}finally{lock.unlock()}
        let closeCell=lease.reserveProducerBeforeClosure180()
        lock.lock();try{state.actualClose180=Some(closeCell);state.nativeCleanupReturned180=false}finally{lock.unlock()}
        let networkCell=lease.reserveProducerBeforeClosure180()
        lock.lock();try{state.actualNetworkRelease180=Some(networkCell)}finally{lock.unlock()}
        let spec=state.spec
        try{
            var executable=spec.application
            let args=ArrayList<String>()
            if(spec.pty){executable="script";args.add("-qefc")
                args.add("stty rows 40 cols 120 >/dev/null 2>&1 && exec "+shellCommand(spec.application,spec.arguments));args.add("/dev/null")}
            else{args.add(all:spec.arguments)}
            if(!sandboxEnabled){let original=ArrayList<String>();original.add(executable);original.add(all:args)
                args.clear();args.add(all:original);executable="setsid"}
            let opened=match(launchDirectPersistentProcess(workspace.rootPath(),sandboxEnabled,allowUnsafeTestBypass,
                FilesystemIsolationMode.WorkspaceReadWrite,spec.networkPolicy,executable,args.toArray(),spec.cwd,
                bindings:spec.environmentBindings,literalEnvironment:daemonLiteralEnvironment(spec.environment),
                sandboxCaBundle:sandboxCaBundle,errorCode:"hub.process_start_failed",resourceLease180:Some(lease),ownedStartCell180:Some(launchCell))){
                case Result.Err(error)=>return failDaemonLaunch(state,generation,error);case Result.Ok(value)=>value}
            // Publish the actual handle BEFORE allocating/spawning any pump.
            // Unknown registration/launch is never interpreted as absence.
            lock.lock()
            try{state.retainedOpened180=Some(opened);state.processHandle=Some(opened);state.process=Some(opened.process)
                state.pid=opened.process.pid
                state.startIdentity=opened.process.originalOpenedStartTime180().toString()
                state.nativePid180=state.pid;state.nativeStartIdentity180=state.startIdentity
                state.state=if(hasReadiness(spec)){"starting"}else{"running"};state.launching=false
                state.recoveryRequired=false;state.stale=false;state.exitCode=None;state.exitReason=""
                state.startedAt=nowMillis();state.exitedAt=0;state.readyAt=0;state.readyMatch=""
                state.readyLogCursor=state.logBaseCursor+state.output.size;state.secretValues=opened.secretValues
                state.nativeRestartPending180=false
            }finally{lock.unlock()}
            // Start the already paid controller as soon as the exact opened
            // handle is registered, before fallible SQL persistence or pump
            // registration. A later failure cannot leave an opened process
            // with only an unstarted cleanup controller.
            ensureNativeRestartController180(state,lease)
            match(lease.noteActualPhysicalLaunch180(state.id,generation,opened.process.pid,state.nativeStartIdentity180)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(lease.check()){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
            persistState(state)
            outCell.start({=>pump(opened.process.stdout,state,generation,opened.secretValues)})
            errCell.start({=>pump(opened.process.stderr,state,generation,opened.secretValues)})
            monitorCell.start({=>
                let code=launchCell.awaitActualNativeWaitForCleanup180(monitorCell,state.actualController180.getOrThrow())
                if(!outCell.awaitActualReturn180() || !errCell.awaitActualReturn180()){
                    throw IllegalStateException("actual process stream producers have not returned")}
                // The pump get helpers returned. Release is a physical network
                // cleanup, never a DATA acknowledgement or monitor witness.
                closeCell.invokeSynchronousHelper180({=>opened.process.closeOwnedAfterJoin180({bytes=>closeCell.fundSynchronousFrame180(bytes)})})
                closeCell.noteSynchronousHelperReturned180()
                let _=launchCell.admitActualNativeCloseErrors180(closeCell)
                networkCell.invokeSynchronousHelper180({=>match(opened.releaseOwned180()){
                    case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}})
                networkCell.noteSynchronousHelperReturned180()
                if(closeCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(closeCell)}
                if(networkCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(networkCell)}
                // Both complete cleanup helpers returned successfully. This
                // scalar alone cannot retire a producer: the outer join also
                // observes every actual Future and independent cleanup cell.
                lock.lock();try{state.nativeCleanupReturned180=true}finally{lock.unlock()}
                finishOwnedProcess180(state,generation,code)
            })
            match(readyCell){case Some(cell)=>cell.start({=>let _=waitForReadyOwned180(state,spec.readyTimeoutMillis,generation,lease)})
                case None=>()}
            ensureNativeRestartController180(state,lease)
            Result.Ok(generation)
        }catch(error:Exception){
            // A producer may already be running. Keep the actual opened handle,
            // cells and Source payment in the registered record; no blind close
            // of network/Source aliases and no restoration of Created state.
            lock.lock();try{state.recoveryRequired=true;state.state="recovery_required";state.exitReason=error.message}
            finally{lock.unlock()}
            // The outer pre-registered operation producer receives this
            // exact exception while this physical record/Source remain paid.
            throw error
        }
    }
    private func cleanupActualFailedNativeStartWholeHelper180(state:ProductDaemonState,
        actual:DirectOwnedStartCell180,lease:HostHubDerivedProcessLease180):Bool{
        let native=match(actual.nativeCustody180Snapshot()){case Some(value)=>value;case None=>return false}
        let caller=state.actualLaunchCaller180.getOrThrow()
        // A successful fork whose LinuxNativeProcess allocation/arming threw
        // has no waiter. Close its actual journal under the original Source;
        // no replacement wrapper or inferred absence is used.
        let _=native.abortUnwrappedAfterWholeCaller180()
        // Actual errno records are copied to independently retained secondary
        // error inputs before attempting the network producer. A pressure
        // failure preserves both the fixed native journal and caller slot.
        if(!native.admitNativeCleanupErrnos180({op,error=>
            caller.retainActualCleanupFailure180(ProcessError(ProcessErrorKind.Io,
                "actual failed native cleanup op="+op.toString()+" errno="+error.toString()))
            !caller.hasUnregisteredSecondary180()})){return false}
        if(!native.nativeFailedResourcesReturned180()){return false}
        if(!lease.noteActualFailedNativeReturn180(state.nativeGeneration180,native.failedStartReceiptBeforeEffect180())){return false}
        let networkCell=state.actualNetworkRelease180.getOrThrow()
        networkCell.invokeSynchronousHelper180({=>actual.releaseAfterFailedNativeResources180()})
        networkCell.noteSynchronousHelperReturned180()
        if(networkCell.hasOriginalFailure180()){
            caller.retainActualCleanupFailure180(HostHubProcessHeldProducerFailure180(networkCell));return false}
        // These four closures have never been constructed/spawned. Their
        // preinstalled reservations may retire only now, after the actual
        // launching helper returned and the opaque native witness succeeded.
        match(state.actualOutput180){case Some(value)=>if(!value.retireNeverStartedAfterWholeCaller180()){return false};case None=>()}
        match(state.actualError180){case Some(value)=>if(!value.retireNeverStartedAfterWholeCaller180()){return false};case None=>()}
        match(state.actualReadiness180){case Some(value)=>if(!value.retireNeverStartedAfterWholeCaller180()){return false};case None=>()}
        match(state.actualMonitor180){case Some(value)=>if(!value.retireNeverStartedAfterWholeCaller180()){return false};case None=>()}
        match(state.actualClose180){case Some(value)=>if(!value.retireNeverStartedAfterWholeCaller180()){return false};case None=>()}
        lock.lock();try{
            state.nativeCleanupReturned180=true;state.stopRequested=true;state.nativeRestartPending180=false
            // No exit code is invented for a failed launch. The original
            // launch exception stays in its real paid caller; only the actual
            // physical return witness makes this recorded failure terminal.
            state.launching=false;state.state="failed";state.recoveryRequired=false;state.exitedAt=nowMillis()
        }finally{lock.unlock()}
        true
    }
    private func resumePreparedCleanupAfterLaunchReturn180(state:ProductDaemonState,
        lease:HostHubDerivedProcessLease180):Unit{
        var startController=false
        lock.lock()
        let failedStart=try{
            let caller=state.actualLaunchCaller180.getOrThrow()
            if(!state.nativeLaunchHelperReturned180 || !caller.collectReturned()){
                throw IllegalStateException("actual launch helper has not returned")}
            state.nativeStartCell180
        }finally{lock.unlock()}
        // Gateway release and whole native error helpers run outside the
        // Supervisor lock; an unknown IO producer cannot block its queries.
        match(failedStart){case Some(actual)=>
            if(cleanupActualFailedNativeStartWholeHelper180(state,actual,lease)){return}
            case None=>()}
        lock.lock();try{
            let caller=state.actualLaunchCaller180.getOrThrow()
            if(!state.nativeLaunchHelperReturned180 || !caller.collectReturned()){
                throw IllegalStateException("actual launch helper has not returned")}
            // Never call a constructor/retry for an unknown physical start.
            // An actually returned handle is the only accepted cleanup owner.
            if(state.retainedOpened180.isNone()){
                match(state.nativeStartCell180){case Some(actual)=>
                    match(actual.returnedHandle180Snapshot()){case Some(value)=>state.retainedOpened180=Some(value);case None=>()}
                    case None=>()}
            }
            match(state.retainedOpened180){case Some(opened)=>
                match(state.actualOutput180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                    let generation=state.nativeGeneration180
                    cell.start({=>pump(opened.process.stdout,state,generation,opened.secretValues)})};case None=>()}
                match(state.actualError180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                    let generation=state.nativeGeneration180
                    cell.start({=>pump(opened.process.stderr,state,generation,opened.secretValues)})};case None=>()}
                match(state.actualReadiness180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                    if(!cell.retireNeverStartedAfterWholeCaller180()){throw IllegalStateException("prepared readiness cannot retire")}
                    state.actualReadiness180=None<HostHubProcessProducerCell>};case None=>()}
                match(state.actualMonitor180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                    let generation=state.nativeGeneration180
                    cell.start({=>cleanupReturnedLaunchHandleHelper180(state,opened,generation)})};case None=>()}
                state.stopRequested=true;state.nativeRestartPending180=false
                startController=true
                case None=>
                    match(state.nativeStartCell180){case Some(actual)=>
                        if(actual.canResumeUnwrappedNative180()){
                            let generation=state.nativeGeneration180
                            let pid=actual.originalUnwrappedPid180();let start=actual.originalUnwrappedStart180()
                            if(pid<=0 || start<=0){throw IllegalStateException("actual unwrapped incarnation identity is unknown")}
                            state.nativePid180=pid;state.nativeStartIdentity180=start.toString();state.pid=pid;state.startIdentity=state.nativeStartIdentity180
                            match(lease.noteActualPhysicalLaunch180(state.id,generation,pid,state.nativeStartIdentity180)){
                                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
                            match(state.actualOutput180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                                cell.start({=>pumpActualUnwrappedNativeStream180(state,actual,generation,false)})};case None=>()}
                            match(state.actualError180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                                cell.start({=>pumpActualUnwrappedNativeStream180(state,actual,generation,true)})};case None=>()}
                            match(state.actualReadiness180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                                if(!cell.retireNeverStartedAfterWholeCaller180()){throw IllegalStateException("actual unwrapped readiness remains held")}
                                state.actualReadiness180=None<HostHubProcessProducerCell>};case None=>()}
                            match(state.actualMonitor180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                                cell.start({=>cleanupActualUnwrappedNativeWholeHelper180(state,actual,generation,lease)})};case None=>()}
                            state.stopRequested=true;state.nativeRestartPending180=false;startController=true
                        }else if(actual.hasActualOpened180()){
                        // No wrapper is reconstructed under pressure. The
                        // original returned ManagedProcess, prepared secrets
                        // and original gateway token remain in the launch cell.
                        let process=actual.actualProcess()
                        let started=process.originalOpenedStartTime180()
                        if(started<1){throw IllegalStateException("actual partial-open start identity is unavailable")}
                        state.process=Some(process);state.pid=process.pid
                        state.startIdentity=started.toString();state.nativePid180=process.pid
                        state.nativeStartIdentity180=state.startIdentity
                        let generation=state.nativeGeneration180
                        match(lease.noteActualPhysicalLaunch180(state.id,generation,process.pid,state.nativeStartIdentity180)){
                            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
                        match(state.actualOutput180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                            cell.start({=>pumpActualPartialOpenedStream180(state,actual,generation,false)})};case None=>()}
                        match(state.actualError180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                            cell.start({=>pumpActualPartialOpenedStream180(state,actual,generation,true)})};case None=>()}
                        match(state.actualReadiness180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                            if(!cell.retireNeverStartedAfterWholeCaller180()){throw IllegalStateException("prepared readiness cannot retire")}
                            state.actualReadiness180=None<HostHubProcessProducerCell>};case None=>()}
                        match(state.actualMonitor180){case Some(cell)=>if(cell.isPreparedBeforeSpawn180()){
                            cell.start({=>cleanupActualPartialOpenedWholeHelper180(state,actual,generation)})};case None=>()}
                        state.stopRequested=true;state.nativeRestartPending180=false;startController=true
                    };case None=>()}
                    // Unknown start has no absence/return witness and stays
                    // in its existing paid launch holder without reconstruction.
                    state.recoveryRequired=true;state.state="recovery_required"}
        }finally{lock.unlock()}
        if(startController){ensureNativeRestartController180(state,lease)}
    }
    private func pumpActualUnwrappedNativeStream180(state:ProductDaemonState,actual:DirectOwnedStartCell180,
        generation:Int64,errorStream:Bool):Unit{
        let secrets=actual.actualOpenedSecrets180()
        actual.withActualUnwrappedStream180(errorStream,{stream=>pump(stream,state,generation,secrets)})
    }
    private func cleanupActualUnwrappedNativeWholeHelper180(state:ProductDaemonState,
        actual:DirectOwnedStartCell180,generation:Int64,lease:HostHubDerivedProcessLease180):Unit{
        let code=actual.awaitActualNativeWaitForCleanup180(state.actualMonitor180.getOrThrow(),state.actualController180.getOrThrow())
        if(!state.actualOutput180.getOrThrow().awaitActualReturn180() || !state.actualError180.getOrThrow().awaitActualReturn180()){
            throw IllegalStateException("actual unwrapped stream Futures have not returned")}
        let closeCell=state.actualClose180.getOrThrow();let networkCell=state.actualNetworkRelease180.getOrThrow()
        closeCell.invokeSynchronousHelper180({=>actual.closeUnwrappedNativeAfterJoined180({bytes=>closeCell.fundSynchronousFrame180(bytes)})})
        closeCell.noteSynchronousHelperReturned180()
        let _=actual.admitActualNativeCloseErrors180(closeCell)
        networkCell.invokeSynchronousHelper180({=>actual.releaseAfterActualOpenedJoin180()})
        networkCell.noteSynchronousHelperReturned180()
        if(closeCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(closeCell)}
        if(networkCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(networkCell)}
        lock.lock();try{state.nativeCleanupReturned180=true}finally{lock.unlock()}
        finishOwnedProcess180(state,generation,code)
    }
    private func pumpActualPartialOpenedStream180(state:ProductDaemonState,actual:DirectOwnedStartCell180,
        generation:Int64,errorStream:Bool):Unit{
        let process=actual.actualProcess()
        let secrets=actual.actualOpenedSecrets180()
        pump(if(errorStream){process.stderr}else{process.stdout},state,generation,secrets)
    }
    private func cleanupActualPartialOpenedWholeHelper180(state:ProductDaemonState,actual:DirectOwnedStartCell180,
        generation:Int64):Unit{
        let process=actual.actualProcess()
        let code=actual.awaitActualNativeWaitForCleanup180(state.actualMonitor180.getOrThrow(),state.actualController180.getOrThrow())
        let outCell=state.actualOutput180.getOrThrow();let errCell=state.actualError180.getOrThrow()
        if(!outCell.awaitActualReturn180() || !errCell.awaitActualReturn180()){
            throw IllegalStateException("actual partial-open stream Futures have not returned")}
        let closeCell=state.actualClose180.getOrThrow();let networkCell=state.actualNetworkRelease180.getOrThrow()
        closeCell.invokeSynchronousHelper180({=>process.closeOwnedAfterJoin180({bytes=>closeCell.fundSynchronousFrame180(bytes)})})
        closeCell.noteSynchronousHelperReturned180()
        let _=actual.admitActualNativeCloseErrors180(closeCell)
        networkCell.invokeSynchronousHelper180({=>actual.releaseAfterActualOpenedJoin180()})
        networkCell.noteSynchronousHelperReturned180()
        if(closeCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(closeCell)}
        if(networkCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(networkCell)}
        lock.lock();try{state.nativeCleanupReturned180=true}finally{lock.unlock()}
        finishOwnedProcess180(state,generation,code)
    }
    private func cleanupReturnedLaunchHandleHelper180(state:ProductDaemonState,
        opened:DirectProcessHandle,generation:Int64):Unit{
        let code=state.nativeStartCell180.getOrThrow().awaitActualNativeWaitForCleanup180(
            state.actualMonitor180.getOrThrow(),state.actualController180.getOrThrow())
        let outCell=state.actualOutput180.getOrThrow();let errCell=state.actualError180.getOrThrow()
        if(!outCell.awaitActualReturn180() || !errCell.awaitActualReturn180()){
            throw IllegalStateException("actual cleanup stream Future has not returned")}
        let closeCell=state.actualClose180.getOrThrow();let networkCell=state.actualNetworkRelease180.getOrThrow()
        closeCell.invokeSynchronousHelper180({=>opened.process.closeOwnedAfterJoin180({bytes=>closeCell.fundSynchronousFrame180(bytes)})})
        closeCell.noteSynchronousHelperReturned180()
        let _=state.nativeStartCell180.getOrThrow().admitActualNativeCloseErrors180(closeCell)
        // Network cleanup is a distinct producer even when physical close
        // reports a real failure; preserve both exact errors independently.
        networkCell.invokeSynchronousHelper180({=>match(opened.releaseOwned180()){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}})
        networkCell.noteSynchronousHelperReturned180()
        if(closeCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(closeCell)}
        if(networkCell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(networkCell)}
        lock.lock();try{state.nativeCleanupReturned180=true}finally{lock.unlock()}
        finishOwnedProcess180(state,generation,code)
    }
    private func finishOwnedProcess180(state:ProductDaemonState,generation:Int64,code:Int64):Unit{
        lock.lock()
        try{if(state.generation!=generation){return}
            // Keep nativePid/startIdentity and retainedOpened until the actual
            // monitor Future itself, readiness and both stream helpers return.
            state.process=None;state.processHandle=None;state.exitCode=Some(code);state.exitedAt=nowMillis();state.pid=0
            let failed=code!=0
            state.nativeRestartPending180=!state.stopRequested && (state.spec.restartPolicy=="always" ||
                (state.spec.restartPolicy=="on-failure" && failed))
            if(state.nativeRestartPending180){state.restartCount+=1;state.consecutiveFailures+=1
                state.readyAt=0;state.readyMatch="";state.state="restarting"}
            else{state.consecutiveFailures=0;state.state=if(failed && !state.stopRequested){"failed"}else{"exited"}}
        }finally{lock.unlock()}
        persistState(state)
        // The real independent controller, not this monitor, owns restart.
        // It must observe this whole action through actual Future.get first.
    }
    private func prepareNativeRestartControllerBeforeLaunch180(state:ProductDaemonState,lease:HostHubDerivedProcessLease180):Unit{
        lock.lock();try{
            if(state.actualController180.isSome()){return}
            let cell=lease.reserveControlBeforeClosure180();state.actualController180=Some(cell)
            cell.fundProducerFrameBeforeEffect180(524288)
        }finally{lock.unlock()}
    }
    private func ensureNativeRestartController180(state:ProductDaemonState,lease:HostHubDerivedProcessLease180):Unit{
        lock.lock();try{
            let cell=state.actualController180.getOrThrow()
            // A successful old incarnation is not a witness for this newly
            // prepaid controller. The actual cell itself distinguishes the
            // never-spawned state from the existing live policy controller.
            if(!cell.isPreparedBeforeSpawn180()){return}
            cell.start({=>nativeRestartControllerBody180(state,lease,cell)})
        }finally{lock.unlock()}
    }
    private func nativeRestartControllerBody180(state:ProductDaemonState,lease:HostHubDerivedProcessLease180,
        controller:HostHubProcessProducerCell):Unit{
        while(true){
            let monitor=actualNativeMonitor180(state)
            while(!monitor.collectReturned()){
                if(actualFailedLaunchHelperReturned180(state)){
                    cleanupActualOpenedIncarnation180(state,lease,controller)}
                else{verifySourceOrCleanupActualOwner180(state,lease,controller)}
                sleep(Duration.millisecond*10)
            }
            match(actualNativeReadiness180(state)){case Some(cell)=>if(!cell.awaitActualReturn180()){return};case None=>()}
            // All get aliases above are confined to helpers that have returned.
            match(joinNativeIncarnation180(state)){case Result.Err(_)=>return;case Result.Ok(_)=>()}
            lock.lock()
            let restart=try{state.nativeRestartPending180 && !state.stopRequested}finally{lock.unlock()}
            if(!restart){return}
            let exponent=min(state.consecutiveFailures,5);var delay:Int64=1000
            for(_ in 0..exponent){delay*=2};sleep(Duration.millisecond*min(delay,30000))
            match(lease.check()){case Result.Err(_)=>return;case Result.Ok(_)=>()}
            lock.lock();let current=try{!state.stopRequested && state.nativeRestartPending180}finally{lock.unlock()}
            if(!current){return}
            match(launchState(state,true,expectedGeneration:state.generation)){case Result.Err(_)=>return;case Result.Ok(_)=>()}
        }
    }
    private func actualFailedLaunchHelperReturned180(state:ProductDaemonState):Bool{
        lock.lock();try{
            if(!state.nativeLaunchHelperReturned180){return false}
            match(state.actualLaunchCaller180){case Some(value)=>
                value.collectReturned() && value.hasOriginalFailure180();case None=>false}
        }finally{lock.unlock()}
    }
    private func verifySourceOrCleanupActualOwner180(state:ProductDaemonState,lease:HostHubDerivedProcessLease180,
        controller:HostHubProcessProducerCell):Unit {
        try{match(lease.check()){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(_)=>()}}
        catch(error:Exception){
            // The already reserved controller retains both producer errors;
            // cleanup cannot allocate a fresh bank or hide the Source error.
            controller.retainFailureBeforeCleanup180(error)
            cleanupActualOpenedIncarnation180(state,lease,controller)
            throw error
        }
    }
    private func cleanupActualOpenedIncarnation180(state:ProductDaemonState,lease:HostHubDerivedProcessLease180,
        controller:HostHubProcessProducerCell):Unit {
        let launch:DirectOwnedStartCell180
        lock.lock()
        try{
            if(state.service180.isNone() || !refEq(state.service180.getOrThrow(),lease) || state.nativeGeneration180==0){
                throw IllegalStateException("original opened process custody is unavailable")}
            launch=state.nativeStartCell180.getOrThrow()
            if(launch.originalUnwrappedPid180()!=state.nativePid180 || state.nativeStartIdentity180=="" ||
                state.nativeGeneration180!=state.generation){
                throw IllegalStateException("original physical incarnation changed")}
            state.stopRequested=true;state.nativeRestartPending180=false
        }finally{lock.unlock()}
        // The private retained platform also survives ManagedProcess wrapper
        // failure. Main-command Exit is not a supervisor/adopted-tree return.
        // Cleanup always addresses this original opened incarnation, without
        // granting arbitrary PID authority or revalidating revoked Source.
        if(!launch.nativePhysicalResourcesReturned180()){
            launch.signalOriginalNativeCleanup180("SIGKILL",controller)}
        // A signal acceptance is not a join; the monitor and both streams
        // remain retained until their actual Future helpers return.
    }
    private func actualNativeMonitor180(state:ProductDaemonState):HostHubProcessProducerCell{
        lock.lock();try{state.actualMonitor180.getOrThrow()}finally{lock.unlock()}
    }
    private func actualNativeReadiness180(state:ProductDaemonState):?HostHubProcessProducerCell{
        lock.lock();try{state.actualReadiness180}finally{lock.unlock()}
    }
    private func joinNativeIncarnation180(state:ProductDaemonState):Result<Unit>{
        let lease=match(state.service180){case Some(value)=>value;case None=>return supervisorError<Unit>(
            "hub.process_legacy_producers_retained","legacy process producers have no actual Future retirement witness")}
        lock.lock()
        try{if(state.nativeJoinedGeneration180==state.nativeGeneration180 && state.nativeGeneration180!=0 &&
                state.nativePid180==0 && state.actualOutput180.isNone() && state.actualError180.isNone() &&
                state.actualMonitor180.isNone() && state.actualReadiness180.isNone() && state.actualClose180.isNone() && state.actualNetworkRelease180.isNone()){
                return Result<Unit>.Ok(())}}
        finally{lock.unlock()}
        match(state.actualMonitor180){case Some(value)=>if(!value.collectReturned()){return supervisorError<Unit>(
            "hub.process_producers_retained","actual process monitor has not returned")};case None=>return supervisorError<Unit>(
            "hub.process_producers_retained","actual process monitor registration is unknown")}
        match(state.actualReadiness180){case Some(value)=>if(!value.collectReturned()){return supervisorError<Unit>(
            "hub.process_producers_retained","actual readiness producer has not returned")};case None=>()}
        lock.lock();let cleanupReturned=try{state.nativeCleanupReturned180}finally{lock.unlock()}
        if(!cleanupReturned){return supervisorError<Unit>("hub.process_cleanup_retained",
            "actual process/network cleanup helpers have not successfully returned")}
        match(state.actualClose180){case Some(value)=>if(!value.retireObservedReturn()){
            return supervisorError<Unit>("hub.process_cleanup_retained","actual close error remains paid")};case None=>()}
        match(state.actualNetworkRelease180){case Some(value)=>if(!value.retireObservedReturn()){
            return supervisorError<Unit>("hub.process_cleanup_retained","actual network release error remains paid")};case None=>()}
        match(state.actualLaunchCaller180){case Some(caller)=>
            if(!caller.collectReturned() || !caller.retireObservedReturn()){
                return supervisorError<Unit>("hub.process_launch_caller_retained","original launch error/caller is still paid")}
            case None=>()}
        if(!lease.noteJoinedIncarnation180(state.nativeGeneration180,state.nativePid180,state.nativeStartIdentity180)){
            return supervisorError<Unit>("hub.process_producers_retained","actual stream/monitor/readiness producer remains retained")}
        lock.lock()
        try{match(state.nativeStartCell180){case Some(cell)=>if(!cell.clearAfterActualIncarnationJoin180()){
                return supervisorError<Unit>("hub.process_native_copies_retained","original native/network copies remain paid")};case None=>()}
            state.nativeStartCell180=None<DirectOwnedStartCell180>;state.actualLaunchCaller180=None<HostHubProcessProducerCell>
            state.retainedOpened180=None;state.actualOutput180=None;state.actualError180=None;state.actualMonitor180=None
            state.actualReadiness180=None;state.actualClose180=None;state.actualNetworkRelease180=None;state.nativePid180=0;state.nativeStartIdentity180=""
            state.nativeJoinedGeneration180=state.nativeGeneration180}
        finally{lock.unlock()}
        Result<Unit>.Ok(())
    }
    private func reapNativeRestartController180(state:ProductDaemonState):Bool{
        let cell=actualNativeController180(state)
        match(cell){case None=>true;case Some(value)=>
            if(!value.collectReturned()){return false}
            // collectReturned has completely returned before retiring its
            // independent task share and clearing the exact record alias.
            if(!value.retireObservedReturn()){return false}
            lock.lock();try{if(state.actualController180.isSome() && refEq(state.actualController180.getOrThrow(),value)){
                    state.actualController180=None};true}finally{lock.unlock()}}
    }
    private func actualNativeController180(state:ProductDaemonState):?HostHubProcessProducerCell{
        lock.lock();try{state.actualController180}finally{lock.unlock()}
    }
    private func waitForReadyOwned180(state:ProductDaemonState,timeoutMillis:Int64,generation:Int64,
        lease:HostHubDerivedProcessLease180):Bool{
        let phase=lease.temporaryDataPhase180()
        try{waitForReadyOwnedBody180(state,timeoutMillis,generation,lease,phase)}finally{phase.close()}
    }
    private func waitForReadyOwnedBody180(state:ProductDaemonState,timeoutMillis:Int64,generation:Int64,
        lease:HostHubDerivedProcessLease180,phase:ProcessTransientOwner180):Bool{
        let started=nowMillis()
        while(true){
            match(lease.check()){case Result.Err(_)=>return false;case Result.Ok(_)=>()}
            if(readyProbeOwned180(state,generation,lease,phase)){persistState(state);return true}
            lock.lock();let done=try{state.generation!=generation || state.stopRequested || daemonTerminal(state.state)}finally{lock.unlock()}
            if(done || nowMillis()-started>=timeoutMillis){return false};sleep(Duration.millisecond*20)}
        false
    }
    private func readyProbeOwned180(state:ProductDaemonState,generation:Int64,lease:HostHubDerivedProcessLease180,
        phase:ProcessTransientOwner180):Bool{
        let output:String
        lock.lock()
        try{if(state.generation!=generation || state.stopRequested || (state.state!="starting" && state.state!="ready")){return false}
            if(state.state=="ready"){return true}
            phase.ensureRetainedPeak(processInvoice180(state.output.size,16,processInvoice180(state.spec.readyLog.size,16,65536)))
            let offset=max(0,state.readyLogCursor-state.logBaseCursor);output=safeUtf8(state.output.toArray()[offset..])
        }finally{lock.unlock()}
        var logReady=state.spec.readyLog=="";var matched=""
        if(!logReady){match(Regex(state.spec.readyLog,[]).find(output)){case Some(value)=>
            lease.retainData180(processInvoice180(output.size,2,4096),4);logReady=true;matched=value.matchString();case None=>()}}
        let portReady=state.spec.readyPort==0 || tcpReady(state.spec.readyHost,state.spec.readyPort)
        if(!logReady || !portReady){return false}
        lock.lock()
        try{if(state.generation!=generation || state.stopRequested || (state.state!="starting" && state.state!="ready")){return false}
            if(state.state=="starting"){state.state="ready";state.readyAt=nowMillis();state.readyMatch=matched};true
        }finally{lock.unlock()}
    }

    private func stopActualUnwrappedNative180(state:ProductDaemonState,actual:DirectOwnedStartCell180,
        timeoutMillis:Int64,lease:HostHubDerivedProcessLease180):Result<Unit>{
        // verifyNativeTarget180 already bound the actual canonical request to
        // all five target fields. The new stop Source is separate from the
        // original retained platform; it cannot reconstruct that old Source.
        let control=lease.reserveControlBeforeClosure180()
        control.fundProducerFrameBeforeEffect180(524288)
        control.invokeSynchronousHelper180({=>match(lease.withPhysicalEffect180({=>
            if(!actual.nativePhysicalResourcesReturned180()){actual.signalOriginalNativeCleanup180("SIGTERM",control)}
            Result<Unit>.Ok(())})){
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}})
        control.noteSynchronousHelperReturned180()
        if(control.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(control)}
        if(!control.retireObservedReturn()){throw HostHubProcessHeldProducerFailure180(control)}
        let started=nowMillis()
        while(!actual.nativePhysicalResourcesReturned180() && nowMillis()-started<timeoutMillis){sleep(Duration.millisecond*10)}
        if(!actual.nativePhysicalResourcesReturned180()){
            let force=lease.reserveControlBeforeClosure180();force.fundProducerFrameBeforeEffect180(524288)
            force.invokeSynchronousHelper180({=>match(lease.withPhysicalEffect180({=>
                actual.signalOriginalNativeCleanup180("SIGKILL",force);Result<Unit>.Ok(())})){
                    case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}})
            force.noteSynchronousHelperReturned180()
            if(!force.retireObservedReturn()){throw HostHubProcessHeldProducerFailure180(force)}}
        let forceStarted=nowMillis()
        while(!actual.nativePhysicalResourcesReturned180() && nowMillis()-forceStarted<1000){sleep(Duration.millisecond*10)}
        if(!actual.nativePhysicalResourcesReturned180()){
            lock.lock();try{state.state="recovery_required";state.recoveryRequired=true;state.stale=true
                state.exitReason="owned process did not stop before the force deadline"}finally{lock.unlock()}
            persistState(state)
            return supervisorError<Unit>("hub.process_stop_unconfirmed","owned process did not stop before the force deadline")}
        let settleStarted=nowMillis()
        while(!daemonTerminal(daemonState(state)) && nowMillis()-settleStarted<1000){sleep(Duration.millisecond*10)}
        persistState(state)
        if(!daemonTerminal(daemonState(state))){return supervisorError<Unit>("hub.process_stop_unsettled","process stopped but its monitor did not settle")}
        // A physical signal/reap alone never consumes the original launch,
        // monitor, close or gateway error. Full actual join preserves those.
        joinNativeIncarnation180(state)
    }
    private func stopOwnedState180(
        state: ProductDaemonState,
        timeoutMillis: Int64,
        lease: HostHubDerivedProcessLease180
    ): Result<Unit> {
        let process: ?ManagedProcess
        let recoveredPid: Int64
        let recoveredIdentity: String
        let recovered: Bool
        let pendingLaunch: Bool
        lock.lock()
        try {
            state.stopRequested = true
            process = state.process
            recoveredPid = state.pid
            recoveredIdentity = state.startIdentity
            recovered = state.recoveryRequired
            pendingLaunch = state.launching
            if (process.isSome()) { state.state = "stopping" }
            else if (!recovered) {
                state.generation += 1
                state.state = if (pendingLaunch) { "stopping" } else { "exited" }
                if (!pendingLaunch) { state.exitedAt = nowMillis() }
                state.readyAt = 0
                state.readyMatch = ""
                state.exitReason = "stopped before restart"
            }
        } finally {
            lock.unlock()
        }
        match (process) {
            case None =>
                if (pendingLaunch) {
                    let started = nowMillis()
                    while (true) {
                        lock.lock()
                        let pending = try { state.launching } finally { lock.unlock() }
                        if (!pending) { break }
                        if (nowMillis() - started >= timeoutMillis + 1000) {
                            lock.lock()
                            try {
                                if (!state.launching) { break }
                                state.state = "recovery_required"
                                state.recoveryRequired = true
                                state.exitReason = "in-flight launch did not finish cleanup before stop deadline"
                            } finally { lock.unlock() }
                            persistState(state)
                            return supervisorError<Unit>("hub.process_stop_unconfirmed", state.exitReason)
                        }
                        sleep(Duration.millisecond * 10)
                    }
                }
                lock.lock()
                let unwrapped=try{state.nativeStartCell180}finally{lock.unlock()}
                match(unwrapped){case Some(actual)=>if(actual.canResumeUnwrappedNative180() || actual.nativePhysicalResourcesReturned180()){
                    return stopActualUnwrappedNative180(state,actual,timeoutMillis,lease)};case None=>()}
                if (recovered) {
                    return stopRecoveredOwnedState180(state,recoveredPid,recoveredIdentity,timeoutMillis,lease)
                }
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
                if(value.ownedPhysicalResourcesReturned180()){
                    // No effect is repeated after actual close/reap. Original
                    // monitor/event/error aliases are checked by the join.
                    return joinNativeIncarnation180(state)}
                match (signalOwnedProcess180(lease,value,"SIGTERM")) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let started = nowMillis()
                while (!value.ownedPhysicalResourcesReturned180() &&
                    nowMillis() - started < timeoutMillis) {
                    sleep(Duration.millisecond * 10)
                }
                if (!value.ownedPhysicalResourcesReturned180()) {
                    match (signalOwnedProcess180(lease,value,"SIGKILL")) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    // The exact Native owned-tree signal already includes
                    // descendants that changed session. Do not invoke the
                    // legacy group fallback and swallow its real Exception.
                }
                let forceStarted = nowMillis()
                while (!value.ownedPhysicalResourcesReturned180() &&
                    nowMillis() - forceStarted < 1000) {
                    sleep(Duration.millisecond * 10)
                }
                if (!value.ownedPhysicalResourcesReturned180()) {
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
    private func stopRecoveredOwnedState180(state:ProductDaemonState,pid:Int64,identity:String,
        timeoutMillis:Int64,lease:HostHubDerivedProcessLease180):Result<Unit>{
        // History is only the frozen target. A new actual canonical lease is
        // verified by the caller and holds every physical signalling window.
        match(lease.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        let cell:HostHubProcessProducerCell
        try{
            if(!brokerMode || !state.recoveryRequired || state.process.isSome() || state.recoveredStopBusy180){
                return supervisorError<Unit>("hub.process_recovery_superseded","actual recovered stop was superseded")}
            match(state.recoveredIncarnation180){case Some(previous)=>
                if(!previous.descriptorReturned180()){
                    throw HostHubProcessHeldProducerFailure180(state.recoveredStopProducer180.getOrThrow())}
                case None=>()}
            match(state.recoveredStopProducer180){case Some(previous)=>
                if(!previous.collectReturned() || !previous.retireObservedReturn()){
                    throw HostHubProcessHeldProducerFailure180(previous)}
                state.recoveredStopProducer180=None<HostHubProcessProducerCell>
                case None=>()}
            cell=lease.reserveControlBeforeClosure180()
            state.recoveredStopProducer180=Some(cell)
            cell.fundSynchronousFrame180(65536)
            if(pid>0){
                let started=Int64.parse(identity)
                if(started<1){throw IllegalStateException("actual recovered start identity is unavailable")}
                let actual=ProcessIncarnationOwner180(pid,started)
                state.recoveredIncarnation180=Some(actual)
            }
            state.recoveredStopBusy180=true
        }finally{lock.unlock()}
        try{
            cell.invokeSynchronousHelper180({=>stopRecoveredOwnedWholeHelper180(state,timeoutMillis,lease,cell)})
            cell.noteSynchronousHelperReturned180()
            if(cell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(cell)}
            if(!cell.retireObservedReturn()){throw HostHubProcessHeldProducerFailure180(cell)}
            // No owner/FD alias leaves the private whole helper. This removal
            // occurs only after that helper and the actual error loan returned.
            lock.lock();try{
                state.recoveredIncarnation180=None<ProcessIncarnationOwner180>
                state.recoveredStopProducer180=None<HostHubProcessProducerCell>
            }finally{lock.unlock()}
            Result<Unit>.Ok(())
        }finally{lock.lock();try{state.recoveredStopBusy180=false}finally{lock.unlock()}}
    }
    private func recoveredIncarnationLoanHelper180(state:ProductDaemonState):?ProcessIncarnationOwner180{
        lock.lock();try{state.recoveredIncarnation180}finally{lock.unlock()}
    }
    private func stopRecoveredOwnedWholeHelper180(state:ProductDaemonState,
        timeoutMillis:Int64,lease:HostHubDerivedProcessLease180,cell:HostHubProcessProducerCell):Unit{
        // The owner alias exists only in this private whole helper. The outer
        // collector receives no pidfd/data object, only a returned cell result.
        match(recoveredIncarnationLoanHelper180(state)){case Some(actual)=>
            let exact=actual.openExact180({bytes=>cell.fundSynchronousFrame180(bytes)})
            if(exact){
                match(lease.withPhysicalEffect180({=>actual.signalTree180(15,{bytes=>cell.fundSynchronousFrame180(bytes)});Result<Unit>.Ok(())})){
                    case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
                let started=nowMillis()
                while(!actual.exited180() && nowMillis()-started<timeoutMillis){sleep(Duration.millisecond*10)}
                if(!actual.exited180()){
                    match(lease.withPhysicalEffect180({=>actual.signalTree180(9,{bytes=>cell.fundSynchronousFrame180(bytes)});Result<Unit>.Ok(())})){
                        case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
                    let forced=nowMillis()
                    while(!actual.exited180() && nowMillis()-forced<1000){sleep(Duration.millisecond*10)}
                }
                if(!actual.exited180()){throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                    "hub.process_stop_unconfirmed","recovered process did not stop"))}
            }else if(!actual.expectedIncarnationMissing180()){
                throw IllegalStateException("actual recovered process identity remains unknown")}
            actual.closeAfterObservedExit180()
            if(!actual.descriptorReturned180()){throw IllegalStateException("actual incarnation descriptor remains retained")}
            case None=>()}
        lock.lock();try{
            state.pid=0;state.state="exited";state.recoveryRequired=false;state.stale=false
            state.exitedAt=nowMillis();state.exitReason="stopped after broker recovery"
        }finally{lock.unlock()}
        // Original persistence is itself covered by this registered producer;
        // its complete SQL exception is not substituted or silently ignored.
        persistState(state)
    }
    private func launchState(
        state: ProductDaemonState,
        restarting: Bool,
        expectedGeneration!: Int64 = -1
    ): Result<Int64> {
        match (state.service180) {
            case Some(lease) => return launchOwnedState180(state, restarting, lease,
                expectedGeneration: expectedGeneration)
            case None => ()
        }
        let generation: Int64
        lock.lock()
        try {
            let registered = findLocked(state.spec.name)
            if (registered.isNone() || registered.getOrThrow().id != state.id ||
                state.launching || state.process.isSome() || state.stopRequested ||
                (expectedGeneration >= 0 && state.generation != expectedGeneration)) {
                return supervisorError<Int64>("hub.process_launch_superseded", "process launch was stopped or superseded")
            }
            state.generation += 1
            generation = state.generation
            state.launching = true
        } finally { lock.unlock() }
        var openedForCleanup: ?DirectProcessHandle = None
        try {
            let spec = state.spec
            lock.lock()
            let admitted = try {
                let current = state.generation == generation && !state.stopRequested
                if (current && brokerMode && !restarting && state.logPath != "") {
                    File.writeTo(state.logPath, [])
                }
                current
            } finally { lock.unlock() }
            if (!admitted) {
                return failDaemonLaunch(state, generation, AgentError(AgentErrorKind.Cancelled,
                    "hub.process_launch_superseded", "process launch was stopped or superseded"))
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
                spec.networkPolicy,
                launchExecutable,
                launchArguments.toArray(),
                spec.cwd,
                bindings: spec.environmentBindings,
                literalEnvironment: daemonLiteralEnvironment(spec.environment),
                sandboxCaBundle: sandboxCaBundle,
                errorCode: "hub.process_start_failed"
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return failDaemonLaunch(state, generation, error)
            }
            openedForCleanup = Some(opened)
            let process = opened.process
            lock.lock()
            try {
                if (state.generation != generation || state.stopRequested) {
                    lock.unlock()
                    try { let _ = process.close() } finally {
                        opened.release()
                        lock.lock()
                    }
                    settleStoppedLaunchLocked(state)
                    lock.unlock()
                    try { persistState(state) } finally { lock.lock() }
                    return supervisorError<Int64>("hub.process_launch_superseded", "process launch was stopped or superseded")
                }
                state.launching = false
                state.process = Some(process)
                state.processHandle = Some(opened)
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
                state.readyLogCursor = state.logBaseCursor + state.output.size
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
                try { let _ = process.close() } catch (_: Exception) {}
                opened.release()
                finishProcess(state, generation, code)
            }
            let _ = monitor
            if (hasReadiness(spec)) {
                let ready = spawn { let _ = waitForReady(state, spec.readyTimeoutMillis, generation) }
                let _ = ready
            }
            Result.Ok(generation)
        } catch (error: Exception) {
            match (openedForCleanup) {
                case Some(opened) =>
                    try { let _ = opened.process.close() } catch (_: Exception) {}
                    opened.release()
                case None => ()
            }
            failDaemonLaunch(state, generation, AgentError(
                AgentErrorKind.Transport, "hub.process_start_failed", error.message))
        }
    }

    private func failDaemonLaunch(
        state: ProductDaemonState,
        generation: Int64,
        error: AgentError
    ): Result<Int64> {
        lock.lock()
        try {
            if (state.generation == generation) {
                state.launching = false
                state.state = "failed"
                state.exitReason = error.message
                state.exitedAt = nowMillis()
            } else {
                settleStoppedLaunchLocked(state)
            }
        } finally { lock.unlock() }
        persistState(state)
        Result.Err(error)
    }

    private func settleStoppedLaunchLocked(state: ProductDaemonState): Unit {
        if (state.launching && state.stopRequested) {
            state.launching = false
            state.state = "exited"
            state.recoveryRequired = false
            state.exitedAt = nowMillis()
            state.exitReason = "in-flight launch stopped before publication"
        }
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
            state.processHandle = None
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
            let _ = launchState(state, true, expectedGeneration: generation)
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
        timeoutMillis: Int64,
        generation: Int64
    ): Bool {
        let started = nowMillis()
        while (true) {
            let output: String
            let currentState: String
            lock.lock()
            try {
                if (state.generation != generation || state.stopRequested ||
                    (state.state != "starting" && state.state != "ready")) { return false }
                if (state.state == "ready") { return true }
                let offset = max(0, state.readyLogCursor - state.logBaseCursor)
                output = safeUtf8(state.output.toArray()[offset..])
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
                    if (state.generation != generation || state.stopRequested ||
                        (state.state != "starting" && state.state != "ready")) { return false }
                    if (state.state == "starting") {
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
        let pendingLaunch: Bool
        lock.lock()
        try {
            state.stopRequested = true
            process = state.process
            recoveredPid = state.pid
            recoveredIdentity = state.startIdentity
            recovered = state.recoveryRequired
            pendingLaunch = state.launching
            if (process.isSome()) { state.state = "stopping" }
            else if (!recovered) {
                state.generation += 1
                state.state = if (pendingLaunch) { "stopping" } else { "exited" }
                if (!pendingLaunch) { state.exitedAt = nowMillis() }
                state.readyAt = 0
                state.readyMatch = ""
                state.exitReason = "stopped before restart"
            }
        } finally {
            lock.unlock()
        }
        match (process) {
            case None =>
                if (pendingLaunch) {
                    let started = nowMillis()
                    while (true) {
                        lock.lock()
                        let pending = try { state.launching } finally { lock.unlock() }
                        if (!pending) { break }
                        if (nowMillis() - started >= timeoutMillis + 1000) {
                            lock.lock()
                            try {
                                if (!state.launching) { break }
                                state.state = "recovery_required"
                                state.recoveryRequired = true
                                state.exitReason = "in-flight launch did not finish cleanup before stop deadline"
                            } finally { lock.unlock() }
                            persistState(state)
                            return supervisorError<Unit>("hub.process_stop_unconfirmed", state.exitReason)
                        }
                        sleep(Duration.millisecond * 10)
                    }
                }
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
            ValueField("network", networkPolicyCanonicalValue(spec.networkPolicy)),
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
                let registered = findLocked(state.spec.name)
                if (registered.isNone() || registered.getOrThrow().id != state.id) { return }
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
        match(brokerRootData180){case Some(actual)=>restoreActualBrokerStates180(root,actual);return;case None=>()}
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

    private func restoreActualBrokerStates180(path:String,root:ActualProcessBrokerRoot180):Unit {
        let cell=root.registerActualInputBeforeConstruction180()
        try {
            restoreActualBrokerStatesHelper180(path,root,cell)
            if(!cell.retireAfterReturnedInputHelper180()){
                throw IllegalStateException("actual directory close/payment remains retained")}
        }catch(error:Exception){cell.retainOriginal180(error);throw error}
    }
    private func restoreActualBrokerStatesHelper180(path:String,root:ActualProcessBrokerRoot180,
        cell:ActualProcessBrokerInput180):Unit {
        cell.open180(path,directory:true)
        while(cell.withNextName180({name=>
            if(!name.endsWith(".json")){return}
            root.retainRootData180(processInvoice180(name.size,4,65536))
            match(restoreBrokerState(path,name)){case Some(state)=>daemonCounter+=1;daemons.add(state);case None=>()}
        })){}
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
                match(brokerRootData180){case Some(root)=>readActualProcessBrokerFile180(path,1048576,root)
                    case None=>String.fromUtf8(File.readFrom(path))},
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
        match(brokerRootData180){case Some(root)=>
            root.retainRootData180(processInvoice180(file.size,4,processInvoice180(reason.size,4,4096)))
            case None=>()}
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
            let bytes = match(brokerRootData180){case Some(root)=>
                let text=readActualProcessBrokerFile180(state.logPath,maxLogBytes,root)
                root.retainRootData180(text.size*2+4096);text.toArray()
                case None=>File.readFrom(state.logPath)}
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
    let networkPolicy = match (daemonRecordNetworkPolicy(value)) {
        case Some(policy) => policy
        case None => return None
    }
    let ready = value.field("ready")
    var readyLog = ""
    var readyPort: Int64 = 0
    var readyHost = "127.0.0.1"
    var readyHostProvided = false
    var readyTimeoutMillis: Int64 = 30000
    match (ready) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Object) {
                readyLog = daemonRecordText(item, "log")
                readyPort = daemonRecordInteger(item, "port", 0)
                let host = daemonRecordText(item, "host")
                if (host != "") {
                    readyHost = host
                    readyHostProvided = true
                }
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
    if (readyHostProvided && readyHost != "127.0.0.1") {
        return None
    }
    if (readyPort < 0 || readyPort > 65535 ||
        readyTimeoutMillis < 1 || readyTimeoutMillis > 3600000) {
        return None
    }
    if (readyPort != 0 && networkPolicyModeIsDenied(networkPolicy.mode)) { return None }
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
        networkPolicy,
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
            try { Int64.parse(field.asNumberText()) } catch (_: Exception) { fallback }
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
            try { Some(Int64.parse(field.asNumberText())) } catch (_: Exception) { None }
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
            if (field.unifiedKind == ValueKind.Boolean) { field.asBool() } else { fallback }
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
                Int64.parse(value.asNumberText())
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
                Int64.parse(field.asNumberText())
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
                value.asBool()
            } else {
                fallback
            }
        case None => fallback
    }
}
func daemonNetworkPolicy(
    call: ToolCall,
    defaultMode!: ShellNetworkMode = ShellNetworkMode.Restricted
): Result<NetworkPolicy> {
    match (call.arguments.field("network")) {
        case None =>
            Result.Ok(match (defaultMode) {
                case ShellNetworkMode.Restricted => NetworkPolicy(NetworkPolicyMode.Denied)
                case ShellNetworkMode.Proxy => NetworkPolicy(NetworkPolicyMode.Mediated)
                case ShellNetworkMode.TrustedHost => NetworkPolicy(NetworkPolicyMode.HostNetwork)
            })
        case Some(value) =>
            let policy = match (parseNetworkPolicy(value)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (defaultMode == ShellNetworkMode.Proxy &&
                networkPolicyModeIsHost(policy.mode)) {
                return Result.Err(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "network.mode_denied",
                    "proxy shell mode forbids HostNetwork",
                    retryable: false,
                    fallbackAllowed: false
                ))
            }
            if (networkPolicyModeIsMediated(policy.mode) && !policy.publish.isEmpty()) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "network.publish_not_supported",
                    "the mediated network gateway does not support published ports",
                    retryable: false,
                    fallbackAllowed: false
                ))
            }
            Result.Ok(policy)
    }
}

func daemonRecordNetworkPolicy(value: AgentValue): ?NetworkPolicy {
    match (value.field("network")) {
        case None => Some(NetworkPolicy(NetworkPolicyMode.Denied))
        case Some(raw) =>
            match (parseNetworkPolicy(raw)) {
                case Result.Ok(policy) => Some(policy)
                case Result.Err(_) => None
            }
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

class ProcessTreeTarget {
    let pid: Int64
    let startIdentity: String
    let processGroup: Int64

    init(
        pid: Int64,
        startIdentity: String,
        processGroup: Int64
    ) {
        this.pid = pid
        this.startIdentity = startIdentity
        this.processGroup = processGroup
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
    // A sandbox wrapper re-sessions its descendants (bwrap --new-session),
    // so the launch group does not cover them, and PDEATHSIG does not
    // cascade through every bubblewrap build. Capture each descendant's
    // identity before signaling, then signal the launch group first. The
    // group result tells the sweep which descendants still need a signal.
    let groupCoversDescendants = processGroupId(pid) == pid
    let descendants = processDescendantTargets(pid)
    let (groupCode, _, groupError) = executeWithOutput(
        "kill",
        ["-" + suffix, "--", "-" + pid.toString()]
    )
    var descendantSignalled = false
    for (descendant in descendants) {
        // Re-read both the start token and process group immediately before
        // signaling. This rejects a reused PID and avoids explicitly
        // signaling a descendant already covered by a successful group kill.
        let currentGroup = processTreeTargetGroup(descendant)
        if (currentGroup == 0 ||
            (groupCode == 0 && groupCoversDescendants &&
                currentGroup == pid)) {
            continue
        }
        let (descendantCode, _, _) = executeWithOutput(
            "kill",
            ["-" + suffix, "--", descendant.pid.toString()]
        )
        if (descendantCode == 0) {
            descendantSignalled = true
        }
    }
    if (groupCode == 0 || descendantSignalled) {
        Result.Ok(())
    } else {
        // A sandbox wrapper can own the child without being a process-group
        // leader in the host namespace. Signal the already-owned root PID as
        // a fail-closed fallback.
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

func processTreeTargetGroup(target: ProcessTreeTarget): Int64 {
    match (linuxProcessStatTail(
        "/proc/" + target.pid.toString() + "/stat"
    )) {
        case Some(fields) =>
            if (fields[19] != target.startIdentity) { return 0 }
            decimalOrZero(fields[2])
        case None => 0
    }
}

func processGroupId(pid: Int64): Int64 {
    match (linuxProcessStatTail("/proc/" + pid.toString() + "/stat")) {
        case Some(fields) =>
            if (fields.size <= 2) { return 0 }
            decimalOrZero(fields[2])
        case None => 0
    }
}

func processDescendantTargets(root: Int64): Array<ProcessTreeTarget> {
    let childrenOf = HashMap<Int64, ArrayList<ProcessTreeTarget>>()
    try {
        for (entry in Directory.readFrom("/proc")) {
            let name = entry.name
            var allDigits = name.size > 0
            for (byte in name.toArray()) {
                if (byte < b'0' || byte > b'9') {
                    allDigits = false
                    break
                }
            }
            if (!allDigits) { continue }
            let fields = match (
                linuxProcessStatTail("/proc/" + name + "/stat")
            ) {
                case Some(value) => value
                case None => continue
            }
            let parsedPid = decimalOrZero(name)
            let parsedParent = decimalOrZero(fields[1])
            let parsedGroup = decimalOrZero(fields[2])
            let startIdentity = fields[19]
            if (parsedPid == 0 || parsedParent == 0 ||
                parsedGroup == 0 || startIdentity == "") {
                continue
            }
            let target = ProcessTreeTarget(
                parsedPid,
                startIdentity,
                parsedGroup
            )
            match (childrenOf.get(parsedParent)) {
                case Some(list) => list.add(target)
                case None =>
                    let list = ArrayList<ProcessTreeTarget>()
                    list.add(target)
                    childrenOf.add(parsedParent, list)
            }
        }
    } catch (_: Exception) {
        // A partial view is acceptable; the group signal still runs.
    }
    let descendants = ArrayList<ProcessTreeTarget>()
    let pending = ArrayList<Int64>()
    pending.add(root)
    while (!pending.isEmpty()) {
        let current = pending.remove(at: pending.size - 1)
        match (childrenOf.get(current)) {
            case Some(children) =>
                for (child in children) {
                    descendants.add(child)
                    pending.add(child.pid)
                }
            case None => ()
        }
    }
    descendants.toArray()
}

func linuxProcessStatTail(path: String): ?Array<String> {
    let statText = try {
        String.fromUtf8(File.readFrom(path)).trimAscii()
    } catch (_: Exception) {
        ""
    }
    if (statText == "") { return None }
    let closing = match (statText.lastIndexOf(")")) {
        case Some(index) => index
        case None => return None
    }
    let fields = statText[closing + 1..].trimAscii().split(" ")
    if (fields.size <= 19) { None } else { Some(fields) }
}

func decimalOrZero(value: String): Int64 {
    var result: Int64 = 0
    for (byte in value.toArray()) {
        if (byte < b'0' || byte > b'9') { return 0 }
        result = result * 10 + Int64(byte - b'0')
        if (result > 4194304) { return 0 }
    }
    result
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

// Borrowed scalar extents: no temporary text array precedes payment.
func processInvoice180(count:Int64,multiplier:Int64,base:Int64):Int64{
    if(count<0 || multiplier<0 || base<0 || multiplier==0 || count>(Int64.Max-base)/multiplier){
        throw LogicalJsonPayloadError("actual process invoice overflow")}
    base+count*multiplier
}
func processRequestText180(value:AgentValue,name:String):String{
    match(value.field(name)){case Some(item)=>if(item.unifiedKind==ValueKind.Text){item.text}else{""};case None=>""}
}
func signalOwnedProcess180(lease:HostHubDerivedProcessLease180,process:ManagedProcess,signal:String):Result<Unit>{
    lease.withPhysicalEffect180({=>lease.signalActualOpenedProcess180(process,signal);Result<Unit>.Ok(())})
}
