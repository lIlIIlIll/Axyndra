package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.net.*
import std.process.*
import std.sync.*
import std.time.*

let PROCESS_BROKER_PROTOCOL: Int64 = 1
let PROCESS_BROKER_MAX_REQUEST_BYTES: Int64 = 1048576
let PROCESS_BROKER_MAX_RESPONSE_BYTES: Int64 = 8388608
let processBrokerSequence = AtomicInt64(0)

class ProductProcessBrokerPaths {
    let runtimeRoot: String
    let socketPath: String
    let tokenPath: String
    let leasePath: String
    let identityPath: String

    init(stateRoot: String, workspace: String) {
        let normalizedState = Path(stateRoot).normalize().toString()
        let scope = stableBrokerScope(normalizedState + "\u{1f}" + workspace)
        this.runtimeRoot = normalizedState + "/runtime/process-broker-" + scope
        this.socketPath = runtimeRoot + "/broker.sock"
        this.tokenPath = runtimeRoot + "/token"
        this.leasePath = runtimeRoot + "/leader.lease"
        this.identityPath = runtimeRoot + "/identity.json"
    }

    func value(): AgentValue {
        objectValue([
            ValueField("runtimeRoot", textValue(runtimeRoot)),
            ValueField("socketPath", textValue(socketPath)),
            ValueField("tokenPath", textValue(tokenPath)),
            ValueField("leasePath", textValue(leasePath)),
            ValueField("identityPath", textValue(identityPath))
        ])
    }
}

class ProductProcessBroker {
    private let stateRoot: String
    private let workspace: String
    private let executable: String
    private let paths: ProductProcessBrokerPaths

    init(stateRoot: String, workspace: String) {
        this.stateRoot = Path(stateRoot).normalize().toString()
        this.workspace = workspace
        this.executable = currentBrokerExecutable()
        this.paths = ProductProcessBrokerPaths(this.stateRoot, workspace)
    }

    func execute(
        call: ToolCall,
        op: String,
        owner: String,
        tokenOverride!: String = ""
    ): Result<ToolResult> {
        let token = match (ensureBroker()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let requestToken = if (tokenOverride == "") { token } else { tokenOverride }
        let requestId = brokerRequestId()
        let request = objectValue([
            ValueField("version", integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId", textValue(requestId)),
            ValueField("token", textValue(requestToken)),
            ValueField("workspace", textValue(workspace)),
            ValueField("kind", textValue("execute")),
            ValueField("op", textValue(op)),
            ValueField("owner", textValue(owner)),
            ValueField("callId", textValue(call.callId)),
            ValueField("tool", textValue(call.name)),
            ValueField("arguments", call.arguments)
        ])
        let response = match (brokerRoundTrip(paths.socketPath, request, requestId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        decodeBrokerToolResult(response)
    }

    func probe(tokenOverride!: String = ""): Result<AgentValue> {
        let token = match (ensureBroker()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        probeWithToken(if (tokenOverride == "") { token } else { tokenOverride })
    }

    func pathsValue(): AgentValue { paths.value() }

    // Listing transient processes must not create an otherwise-unused
    // broker. Once a workspace has broker state, execute() is still allowed
    // to recover a crashed broker and surface recovery_required snapshots.
    func executeIfConfigured(
        call: ToolCall,
        op: String,
        owner: String
    ): ?Result<ToolResult> {
        if (!exists(Path(paths.tokenPath))) { return None }
        Some(execute(call, op, owner))
    }

    private func ensureBroker(): Result<String> {
        match (prepareBrokerRuntime(paths)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let existingToken = readBrokerToken(paths.tokenPath)
        match (existingToken) {
            case Result.Ok(token) =>
                if (token != "") {
                    match (probeWithToken(token)) {
                        case Result.Ok(identity) =>
                            if (brokerLeaseOwnedByIdentity(
                                paths,
                                workspace,
                                identity
                            )) {
                                return Result.Ok(token)
                            }
                        case Result.Err(error) =>
                            if (brokerAuthenticationError(error)) {
                                return Result.Err(error)
                            }
                    }
                }
            case Result.Err(error) => return Result.Err(error)
        }

        let deadline = MonoTime.now() + Duration.millisecond * 10000
        while (MonoTime.now() < deadline) {
            let tokenNow = match (readBrokerToken(paths.tokenPath)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (tokenNow != "") {
                match (probeWithToken(tokenNow)) {
                    case Result.Ok(identity) =>
                        if (brokerLeaseOwnedByIdentity(
                            paths,
                            workspace,
                            identity
                        )) {
                            return Result.Ok(tokenNow)
                        }
                    case Result.Err(error) =>
                        if (brokerAuthenticationError(error)) {
                            return Result.Err(error)
                        }
                }
            }
            let lease = match (tryAcquireBrokerLease(paths, workspace)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (lease) {
                case Some(leaseToken) =>
                    let result = startBrokerAsLeaseLeader(leaseToken)
                    match (result) {
                        case Result.Ok(value) => return Result.Ok(value)
                        case Result.Err(error) =>
                            releaseBrokerLease(paths, leaseToken)
                            return Result.Err(error)
                    }
                case None =>
                    if (brokerLeaseOwnerConfirmedDead(paths, workspace)) {
                        let _ = recoverDeadBrokerLease(paths, workspace)
                    }
            }
            sleep(Duration.millisecond * 20)
        }
        brokerError<String>(
            AgentErrorKind.Timeout,
            "hub.process_broker_start_timeout",
            "timed out waiting for the external process broker"
        )
    }

    private func startBrokerAsLeaseLeader(
        leaseToken: String
    ): Result<String> {
        let currentToken = match (readBrokerToken(paths.tokenPath)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (currentToken != "") {
            match (probeWithToken(currentToken)) {
                case Result.Ok(identity) =>
                    match (assignBrokerLeaseOwner(
                        paths,
                        leaseToken,
                        workspace,
                        identity
                    )) {
                        case Result.Ok(_) => return Result.Ok(currentToken)
                        case Result.Err(error) => return Result.Err(error)
                    }
                case Result.Err(error) =>
                    if (brokerAuthenticationError(error)) {
                        return Result.Err(error)
                    }
            }
        }
        match (prepareBrokerEndpointTakeover(paths, workspace)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let token = match (ensureBrokerToken(paths.tokenPath)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (launchBrokerWorker(leaseToken)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let deadline = MonoTime.now() + Duration.millisecond * 7000
        var lastError: ?AgentError = None
        while (MonoTime.now() < deadline) {
            match (probeWithToken(token)) {
                case Result.Ok(_) => return Result.Ok(token)
                case Result.Err(error) => lastError = Some(error)
            }
            sleep(Duration.millisecond * 20)
        }
        match (lastError) {
            case Some(error) => Result.Err(AgentError(
                AgentErrorKind.Transport,
                "hub.process_broker_start_failed",
                "the external process broker did not become ready: " + error.message,
                fields: [ErrorField("cause", error.code)]
            ))
            case None => brokerError<String>(
                AgentErrorKind.Transport,
                "hub.process_broker_start_failed",
                "the external process broker did not become ready"
            )
        }
    }

    private func launchBrokerWorker(leaseToken: String): Result<Unit> {
        if (executable == "") {
            return brokerError<Unit>(
                AgentErrorKind.Configuration,
                "hub.process_broker_executable_missing",
                "cannot resolve the current axyndra executable"
            )
        }
        try {
            let starter = launch(
                "setsid",
                [
                    "-f",
                    executable,
                    "__process-broker-worker",
                    "--state-root",
                    stateRoot,
                    "--workspace",
                    workspace,
                    "--lease-token",
                    leaseToken
                ],
                workingDirectory: Path(workspace),
                stdIn: ProcessRedirect.Discard,
                stdOut: ProcessRedirect.Discard,
                stdErr: ProcessRedirect.Discard
            )
            let code = starter.wait()
            if (code != 0) {
                return brokerError<Unit>(
                    AgentErrorKind.Transport,
                    "hub.process_broker_launch_failed",
                    "setsid could not launch the process broker"
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            brokerError<Unit>(
                AgentErrorKind.Transport,
                "hub.process_broker_launch_failed",
                error.message
            )
        }
    }

    private func probeWithToken(token: String): Result<AgentValue> {
        let requestId = brokerRequestId()
        let request = objectValue([
            ValueField("version", integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId", textValue(requestId)),
            ValueField("token", textValue(token)),
            ValueField("workspace", textValue(workspace)),
            ValueField("kind", textValue("ping"))
        ])
        let response = match (brokerRoundTrip(paths.socketPath, request, requestId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let identity = match (response.field("identity")) {
            case Some(value) => value
            case None =>
                return brokerError<AgentValue>(
                    AgentErrorKind.Protocol,
                    "hub.process_broker_identity_missing",
                    "broker handshake did not return an identity"
                )
        }
        if (brokerText(identity, "workspace") != workspace ||
            brokerInteger(identity, "protocol", 0) != PROCESS_BROKER_PROTOCOL) {
            return brokerError<AgentValue>(
                AgentErrorKind.Protocol,
                "hub.process_broker_identity_mismatch",
                "broker handshake returned a different workspace or protocol"
            )
        }
        Result.Ok(identity)
    }
}

public func isProductProcessBrokerWorker(
    arguments: Array<String>
): Bool {
    arguments.size > 1 && arguments[1] == "__process-broker-worker"
}

public func isProductProcessBrokerClient(
    arguments: Array<String>
): Bool {
    arguments.size > 1 && arguments[1] == "__process-broker-client"
}

public func runProductProcessBrokerWorker(
    arguments: Array<String>
): Int64 {
    let stateRoot = brokerCliArgument(arguments, "--state-root")
    let authoredWorkspace = brokerCliArgument(arguments, "--workspace")
    let leaseToken = brokerCliArgument(arguments, "--lease-token")
    if (stateRoot == "" || authoredWorkspace == "" || leaseToken == "") {
        return 2
    }
    let workspace = try {
        LocalWorkspace(authoredWorkspace)
    } catch (_: Exception) {
        return 2
    }
    let canonicalWorkspace = workspace.rootPath()
    let paths = ProductProcessBrokerPaths(stateRoot, canonicalWorkspace)
    match (prepareBrokerRuntime(paths)) {
        case Result.Ok(_) => ()
        case Result.Err(_) => return 1
    }
    if (!brokerLeaseOwnedBy(paths, leaseToken, canonicalWorkspace)) {
        return 1
    }
    let token = match (readBrokerToken(paths.tokenPath)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return 1
    }
    if (token == "") { return 1 }
    let identity = brokerIdentity(canonicalWorkspace)
    match (assignBrokerLeaseOwner(
        paths,
        leaseToken,
        canonicalWorkspace,
        identity
    )) {
        case Result.Ok(_) => ()
        case Result.Err(_) => return 1
    }
    let server = try {
        UnixServerSocket(bindAt: paths.socketPath)
    } catch (_: Exception) {
        releaseBrokerLease(paths, leaseToken)
        return 1
    }
    try {
        server.backlogSize = 32
        server.bind()
        match (chmodBrokerPath(paths.socketPath, "600")) {
            case Result.Ok(_) => ()
            case Result.Err(_) =>
                server.close()
                let _ = removeIfExists(paths.socketPath)
                releaseBrokerLease(paths, leaseToken)
                return 1
        }
        match (atomicBrokerWrite(
            paths.identityPath,
            encodeAgentValue(identity),
            "600"
        )) {
            case Result.Ok(_) => ()
            case Result.Err(_) =>
                server.close()
                let _ = removeIfExists(paths.socketPath)
                let _ = removeIfExists(paths.identityPath)
                releaseBrokerLease(paths, leaseToken)
                return 1
        }
        let supervisor = ProductProcessSupervisor(
            workspace,
            brokerRoot: paths.runtimeRoot,
            sandboxEnabled: true
        )
        serveProcessBroker(
            server,
            supervisor,
            token,
            canonicalWorkspace,
            identity
        )
        server.close()
        let _ = removeIfExists(paths.socketPath)
        let _ = removeIfExists(paths.identityPath)
        releaseBrokerLease(paths, leaseToken)
        0
    } catch (_: Exception) {
        server.close()
        let _ = removeIfExists(paths.socketPath)
        let _ = removeIfExists(paths.identityPath)
        releaseBrokerLease(paths, leaseToken)
        1
    }
}

public func runProductProcessBrokerClient(
    arguments: Array<String>
): Int64 {
    let stateRoot = brokerCliArgument(arguments, "--state-root")
    let authoredWorkspace = brokerCliArgument(arguments, "--workspace")
    if (stateRoot == "" || authoredWorkspace == "") {
        println(encodeAgentValue(brokerErrorValue(AgentError(
            AgentErrorKind.InvalidInput,
            "hub.process_broker_cli_arguments",
            "broker client requires --state-root and --workspace"
        ))))
        return 2
    }
    let workspace = try {
        LocalWorkspace(authoredWorkspace).rootPath()
    } catch (error: Exception) {
        println(encodeAgentValue(brokerErrorValue(AgentError(
            AgentErrorKind.InvalidInput,
            "hub.process_broker_workspace_invalid",
            error.message
        ))))
        return 2
    }
    let broker = ProductProcessBroker(stateRoot, workspace)
    if (brokerCliHasArgument(arguments, "--paths")) {
        println(encodeAgentValue(broker.pathsValue()))
        return 0
    }
    let tokenOverride = brokerCliArgument(arguments, "--token")
    if (brokerCliHasArgument(arguments, "--probe")) {
        return printBrokerCliResult(broker.probe(tokenOverride: tokenOverride))
    }
    let source = brokerCliArgument(arguments, "--request")
    if (source == "" || source.size > PROCESS_BROKER_MAX_REQUEST_BYTES) {
        println(encodeAgentValue(brokerErrorValue(AgentError(
            AgentErrorKind.InvalidInput,
            "hub.process_broker_cli_request",
            "broker client requires one bounded --request JSON object"
        ))))
        return 2
    }
    let request = match (decodeAgentValue(
        source,
        maxBytes: PROCESS_BROKER_MAX_REQUEST_BYTES
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            println(encodeAgentValue(brokerErrorValue(error)))
            return 2
    }
    let op = brokerText(request, "op")
    let owner = brokerText(request, "owner")
    let callId = brokerText(request, "callId")
    let argumentsValue = match (request.field("arguments")) {
        case Some(value) => value
        case None => objectValue([])
    }
    if (op == "" || callId == "" || argumentsValue.unifiedKind != ValueKind.Object) {
        println(encodeAgentValue(brokerErrorValue(AgentError(
            AgentErrorKind.InvalidInput,
            "hub.process_broker_cli_request",
            "request requires op, callId, and object arguments"
        ))))
        return 2
    }
    let result = broker.execute(
        ToolCall(callId, "hub", argumentsValue),
        op,
        owner,
        tokenOverride: tokenOverride
    )
    match (result) {
        case Result.Ok(value) =>
            println(encodeAgentValue(brokerToolResultValue(value)))
            0
        case Result.Err(error) =>
            println(encodeAgentValue(brokerErrorValue(error)))
            1
    }
}

func printBrokerCliResult(result: Result<AgentValue>): Int64 {
    match (result) {
        case Result.Ok(value) =>
            println(encodeAgentValue(value))
            0
        case Result.Err(error) =>
            println(encodeAgentValue(brokerErrorValue(error)))
            1
    }
}

func serveProcessBroker(
    server: UnixServerSocket,
    supervisor: ProductProcessSupervisor,
    token: String,
    workspace: String,
    identity: AgentValue
): Unit {
    let active = AtomicInt64(0)
    while (true) {
        let client = try {
            server.accept()
        } catch (_: Exception) {
            if (server.isClosed()) { return }
            continue
        }
        let previous = active.fetchAdd(1)
        if (previous >= 32) {
            active.fetchSub(1)
            try { client.close() } catch (_: Exception) {}
            continue
        }
        let _ = spawn {
            try {
                handleProcessBrokerConnection(
                    client,
                    supervisor,
                    token,
                    workspace,
                    identity
                )
            } finally {
                try { client.close() } catch (_: Exception) {}
                active.fetchSub(1)
            }
        }
    }
}

func handleProcessBrokerConnection(
    socket: UnixSocket,
    supervisor: ProductProcessSupervisor,
    token: String,
    workspace: String,
    identity: AgentValue
): Unit {
    socket.readTimeout = Some(Duration.second * 5)
    socket.writeTimeout = Some(Duration.second * 5)
    let frame = match (readBrokerFrame(
        socket,
        PROCESS_BROKER_MAX_REQUEST_BYTES
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            writeBrokerResponse(socket, brokerResponseError("", error))
            return
    }
    let request = match (decodeAgentValue(
        frame,
        maxBytes: PROCESS_BROKER_MAX_REQUEST_BYTES
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            writeBrokerResponse(socket, brokerResponseError("", AgentError(
                AgentErrorKind.Protocol,
                "hub.process_broker_invalid_json",
                error.message
            )))
            return
    }
    let requestId = brokerText(request, "requestId")
    let validation = validateBrokerRequest(request, token, workspace)
    match (validation) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            writeBrokerResponse(socket, brokerResponseError(requestId, error))
            return
    }
    let kind = brokerText(request, "kind")
    if (kind == "ping") {
        writeBrokerResponse(socket, objectValue([
            ValueField("version", integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId", textValue(requestId)),
            ValueField("ok", boolValue(true)),
            ValueField("identity", identity)
        ]))
        return
    }
    if (kind != "execute") {
        writeBrokerResponse(socket, brokerResponseError(requestId, AgentError(
            AgentErrorKind.Protocol,
            "hub.process_broker_kind_invalid",
            "unsupported broker request kind"
        )))
        return
    }
    let op = brokerText(request, "op")
    let owner = brokerText(request, "owner")
    let callId = brokerText(request, "callId")
    let tool = brokerText(request, "tool")
    let arguments = match (request.field("arguments")) {
        case Some(value) => value
        case None => objectValue([])
    }
    if (callId == "" || tool == "" || arguments.unifiedKind != ValueKind.Object) {
        writeBrokerResponse(socket, brokerResponseError(requestId, AgentError(
            AgentErrorKind.Protocol,
            "hub.process_broker_execute_invalid",
            "broker execute request is incomplete"
        )))
        return
    }
    let result = supervisor.execute(
        ToolCall(callId, tool, arguments),
        op,
        owner
    )
    match (result) {
        case Result.Ok(value) => writeBrokerResponse(socket, objectValue([
            ValueField("version", integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId", textValue(requestId)),
            ValueField("ok", boolValue(true)),
            ValueField("result", brokerToolResultValue(value))
        ]))
        case Result.Err(error) =>
            writeBrokerResponse(socket, brokerResponseError(requestId, error))
    }
}

func validateBrokerRequest(
    request: AgentValue,
    token: String,
    workspace: String
): Result<Unit> {
    if (request.unifiedKind != ValueKind.Object ||
        brokerInteger(request, "version", 0) != PROCESS_BROKER_PROTOCOL) {
        return brokerError<Unit>(
            AgentErrorKind.Protocol,
            "hub.process_broker_protocol_mismatch",
            "unsupported process broker protocol"
        )
    }
    let requestId = brokerText(request, "requestId")
    if (requestId == "" || requestId.size > 128) {
        return brokerError<Unit>(
            AgentErrorKind.Protocol,
            "hub.process_broker_request_id_invalid",
            "broker request id is missing or too long"
        )
    }
    if (!constantTimeBrokerTokenEquals(
        brokerText(request, "token"),
        token
    )) {
        return brokerError<Unit>(
            AgentErrorKind.Authentication,
            "hub.process_broker_auth_failed",
            "process broker authentication failed"
        )
    }
    if (brokerText(request, "workspace") != workspace) {
        return brokerError<Unit>(
            AgentErrorKind.PermissionDenied,
            "hub.process_broker_workspace_mismatch",
            "process broker request targets a different canonical workspace"
        )
    }
    Result.Ok(())
}

func brokerIdentity(workspace: String): AgentValue {
    let pid = getProcessId()
    objectValue([
        ValueField("protocol", integerValue(PROCESS_BROKER_PROTOCOL)),
        ValueField("workspace", textValue(workspace)),
        ValueField("pid", integerValue(pid)),
        ValueField(
            "startIdentity",
            textValue(linuxProcessStartToken(
                "/proc/" + pid.toString() + "/stat"
            ))
        ),
        ValueField("startedAt", integerValue(nowMillis()))
    ])
}

func brokerLeaseOwnerValue(
    token: String,
    workspace: String,
    identity: AgentValue
): AgentValue {
    objectValue([
        ValueField("protocol", integerValue(PROCESS_BROKER_PROTOCOL)),
        ValueField("token", textValue(token)),
        ValueField("workspace", textValue(workspace)),
        ValueField("pid", integerValue(brokerInteger(identity, "pid", 0))),
        ValueField(
            "startIdentity",
            textValue(brokerText(identity, "startIdentity"))
        ),
        ValueField("createdAt", integerValue(nowMillis()))
    ])
}

func assignBrokerLeaseOwner(
    paths: ProductProcessBrokerPaths,
    token: String,
    workspace: String,
    identity: AgentValue
): Result<Unit> {
    let pid = brokerInteger(identity, "pid", 0)
    let startIdentity = brokerText(identity, "startIdentity")
    if (brokerText(identity, "workspace") != workspace ||
        brokerInteger(identity, "protocol", 0) != PROCESS_BROKER_PROTOCOL ||
        pid <= 0 || startIdentity == "" ||
        !brokerProcessIdentityMatches(pid, startIdentity)) {
        return brokerError<Unit>(
            AgentErrorKind.RecoveryRequired,
            "hub.process_broker_owner_unverified",
            "refusing to assign the broker lease without a live PID and start identity"
        )
    }
    if (!brokerLeaseOwnedBy(paths, token, workspace)) {
        return brokerError<Unit>(
            AgentErrorKind.Conflict,
            "hub.process_broker_lease_lost",
            "the broker lease changed before ownership could be assigned"
        )
    }
    match (atomicBrokerWrite(
        paths.leasePath + "/owner.json",
        encodeAgentValue(brokerLeaseOwnerValue(token, workspace, identity)),
        "600"
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let assigned = match (readBrokerLease(paths.leasePath)) {
        case Some(value) =>
            constantTimeBrokerTokenEquals(brokerText(value, "token"), token) &&
                brokerText(value, "workspace") == workspace &&
                brokerInteger(value, "pid", 0) == pid &&
                brokerText(value, "startIdentity") == startIdentity
        case None => false
    }
    if (!assigned) {
        return brokerError<Unit>(
            AgentErrorKind.Conflict,
            "hub.process_broker_lease_lost",
            "the broker lease changed while ownership was being assigned"
        )
    }
    Result.Ok(())
}

func brokerOwnerIdentityConfirmedDead(
    value: AgentValue,
    workspace: String
): Bool {
    if (value.unifiedKind != ValueKind.Object ||
        brokerText(value, "workspace") != workspace ||
        brokerInteger(value, "protocol", 0) != PROCESS_BROKER_PROTOCOL) {
        return false
    }
    let pid = brokerInteger(value, "pid", 0)
    let startIdentity = brokerText(value, "startIdentity")
    pid > 0 && startIdentity != "" &&
        !brokerProcessIdentityMatches(pid, startIdentity)
}

func readBrokerIdentity(path: String): ?AgentValue {
    try {
        if (!exists(Path(path))) { return None }
        let info = FileInfo(Path(path))
        if (!info.isRegular() || info.isSymbolicLink() ||
            info.size < 1 || info.size > 4096) {
            return None
        }
        match (decodeAgentValue(
            String.fromUtf8(File.readFrom(path)),
            maxBytes: 4096
        )) {
            case Result.Ok(value) => Some(value)
            case Result.Err(_) => None
        }
    } catch (_: Exception) {
        None
    }
}

func prepareBrokerEndpointTakeover(
    paths: ProductProcessBrokerPaths,
    workspace: String
): Result<Unit> {
    let hasSocket = exists(Path(paths.socketPath))
    let hasIdentity = exists(Path(paths.identityPath))
    if (!hasSocket && !hasIdentity) { return Result.Ok(()) }
    let identity = match (readBrokerIdentity(paths.identityPath)) {
        case Some(value) => value
        case None =>
            return brokerError<Unit>(
                AgentErrorKind.RecoveryRequired,
                "hub.process_broker_takeover_unverified",
                "refusing to replace broker state without a verifiable owner identity"
            )
    }
    if (!brokerOwnerIdentityConfirmedDead(identity, workspace)) {
        return brokerError<Unit>(
            AgentErrorKind.RecoveryRequired,
            "hub.process_broker_takeover_unverified",
            "refusing to replace broker state whose PID and start identity are not confirmed dead"
        )
    }
    let _ = removeIfExists(paths.socketPath)
    let _ = removeIfExists(paths.identityPath)
    if (exists(Path(paths.socketPath)) || exists(Path(paths.identityPath))) {
        return brokerError<Unit>(
            AgentErrorKind.PermissionDenied,
            "hub.process_broker_takeover_failed",
            "confirmed stale broker state could not be removed"
        )
    }
    Result.Ok(())
}

func brokerRoundTrip(
    socketPath: String,
    request: AgentValue,
    requestId: String
): Result<AgentValue> {
    let payload = encodeAgentValue(request) + "\n"
    if (payload.size > PROCESS_BROKER_MAX_REQUEST_BYTES) {
        return brokerError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "hub.process_broker_frame_too_large",
            "process broker request exceeds the frame limit"
        )
    }
    let socket = try {
        UnixSocket(socketPath)
    } catch (error: Exception) {
        return brokerError<AgentValue>(
            AgentErrorKind.Transport,
            "hub.process_broker_connect_failed",
            error.message
        )
    }
    try {
        socket.readTimeout = Some(Duration.second * 10)
        socket.writeTimeout = Some(Duration.second * 10)
        socket.connect(timeout: Some(Duration.millisecond * 500))
        socket.write(payload.toArray())
        let source = match (readBrokerFrame(
            socket,
            PROCESS_BROKER_MAX_RESPONSE_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let response = match (decodeAgentValue(
            source,
            maxBytes: PROCESS_BROKER_MAX_RESPONSE_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return brokerError<AgentValue>(
                    AgentErrorKind.Protocol,
                    "hub.process_broker_response_invalid",
                    error.message
                )
        }
        if (brokerInteger(response, "version", 0) != PROCESS_BROKER_PROTOCOL ||
            brokerText(response, "requestId") != requestId) {
            return brokerError<AgentValue>(
                AgentErrorKind.Protocol,
                "hub.process_broker_response_mismatch",
                "process broker response identity does not match the request"
            )
        }
        if (!brokerBoolean(response, "ok", false)) {
            let error = match (response.field("error")) {
                case Some(value) => decodeBrokerAgentError(value)
                case None => AgentError(
                    AgentErrorKind.Protocol,
                    "hub.process_broker_error_missing",
                    "process broker returned an error without details"
                )
            }
            return Result.Err(error)
        }
        Result.Ok(response)
    } catch (error: Exception) {
        brokerError<AgentValue>(
            AgentErrorKind.Transport,
            "hub.process_broker_transport_failed",
            error.message
        )
    } finally {
        try { socket.close() } catch (_: Exception) {}
    }
}

func readBrokerFrame(
    stream: InputStream,
    limit: Int64
): Result<String> {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = try {
            stream.read(buffer)
        } catch (error: Exception) {
            return brokerError<String>(
                AgentErrorKind.Transport,
                "hub.process_broker_read_failed",
                error.message
            )
        }
        if (count <= 0) {
            return brokerError<String>(
                AgentErrorKind.Protocol,
                "hub.process_broker_frame_incomplete",
                "process broker connection ended before the NDJSON frame"
            )
        }
        for (index in 0..count) {
            let byte = buffer[index]
            if (byte == b'\n') {
                return try {
                    Result.Ok(String.fromUtf8(bytes.toArray()))
                } catch (error: Exception) {
                    brokerError<String>(
                        AgentErrorKind.Protocol,
                        "hub.process_broker_frame_utf8",
                        error.message
                    )
                }
            }
            if (bytes.size >= limit) {
                return brokerError<String>(
                    AgentErrorKind.Protocol,
                    "hub.process_broker_frame_too_large",
                    "process broker NDJSON frame exceeds the configured limit"
                )
            }
            bytes.add(byte)
        }
    }
    brokerError<String>(
        AgentErrorKind.Internal,
        "hub.process_broker_read_unreachable",
        "process broker frame reader stopped unexpectedly"
    )
}

func writeBrokerResponse(socket: UnixSocket, response: AgentValue): Unit {
    var encoded = encodeAgentValue(response)
    if (encoded.size > PROCESS_BROKER_MAX_RESPONSE_BYTES) {
        encoded = encodeAgentValue(brokerResponseError(
            brokerText(response, "requestId"),
            AgentError(
                AgentErrorKind.Protocol,
                "hub.process_broker_response_too_large",
                "process broker response exceeds the configured limit"
            )
        ))
    }
    try {
        socket.write((encoded + "\n").toArray())
    } catch (_: Exception) {}
}

func brokerResponseError(
    requestId: String,
    error: AgentError
): AgentValue {
    objectValue([
        ValueField("version", integerValue(PROCESS_BROKER_PROTOCOL)),
        ValueField("requestId", textValue(requestId)),
        ValueField("ok", boolValue(false)),
        ValueField("error", brokerAgentErrorValue(error))
    ])
}

func brokerToolResultValue(result: ToolResult): AgentValue {
    objectValue([
        ValueField("ok", boolValue(true)),
        ValueField("callId", textValue(result.callId)),
        ValueField("output", result.output),
        ValueField("isError", boolValue(result.isError)),
        ValueField("receiptId", textValue(result.receiptId))
    ])
}

func decodeBrokerToolResult(response: AgentValue): Result<ToolResult> {
    let result = match (response.field("result")) {
        case Some(value) => value
        case None =>
            return brokerError<ToolResult>(
                AgentErrorKind.Protocol,
                "hub.process_broker_result_missing",
                "process broker response did not include a tool result"
            )
    }
    let callId = brokerText(result, "callId")
    let output = match (result.field("output")) {
        case Some(value) => value
        case None =>
            return brokerError<ToolResult>(
                AgentErrorKind.Protocol,
                "hub.process_broker_output_missing",
                "process broker result did not include output"
            )
    }
    if (callId == "") {
        return brokerError<ToolResult>(
            AgentErrorKind.Protocol,
            "hub.process_broker_call_id_missing",
            "process broker result did not include a call id"
        )
    }
    Result.Ok(ToolResult(
        callId,
        output,
        isError: brokerBoolean(result, "isError", false),
        receiptId: brokerText(result, "receiptId")
    ))
}

func brokerErrorValue(error: AgentError): AgentValue {
    objectValue([
        ValueField("ok", boolValue(false)),
        ValueField("error", brokerAgentErrorValue(error))
    ])
}

func brokerAgentErrorValue(error: AgentError): AgentValue {
    let fields = ArrayList<AgentValue>()
    for (field in error.fields) {
        fields.add(objectValue([
            ValueField("name", textValue(field.name)),
            ValueField("value", textValue(field.value))
        ]))
    }
    objectValue([
        ValueField("kind", textValue(brokerErrorKindName(error.kind))),
        ValueField("code", textValue(error.code)),
        ValueField("message", textValue(error.message)),
        ValueField("retryable", boolValue(error.retryable)),
        ValueField("fallbackAllowed", boolValue(error.fallbackAllowed)),
        ValueField("fields", listValue(fields.toArray()))
    ])
}

func decodeBrokerAgentError(value: AgentValue): AgentError {
    let fields = ArrayList<ErrorField>()
    match (value.field("fields")) {
        case Some(items) =>
            if (items.unifiedKind == ValueKind.List) {
                for (item in items.items) {
                    let name = brokerText(item, "name")
                    if (name != "") {
                        fields.add(ErrorField(
                            name,
                            brokerText(item, "value")
                        ))
                    }
                }
            }
        case None => ()
    }
    let code = brokerText(value, "code")
    let message = brokerText(value, "message")
    AgentError(
        brokerErrorKind(brokerText(value, "kind")),
        if (code == "") { "hub.process_broker_remote_error" } else { code },
        if (message == "") { "process broker returned an error" } else { message },
        retryable: brokerBoolean(value, "retryable", false),
        fallbackAllowed: brokerBoolean(value, "fallbackAllowed", false),
        fields: fields.toArray()
    )
}

func brokerErrorKindName(kind: AgentErrorKind): String {
    match (kind) {
        case AgentErrorKind.Configuration => "configuration"
        case AgentErrorKind.Authentication => "authentication"
        case AgentErrorKind.PermissionDenied => "permission_denied"
        case AgentErrorKind.InvalidInput => "invalid_input"
        case AgentErrorKind.RateLimited => "rate_limited"
        case AgentErrorKind.Timeout => "timeout"
        case AgentErrorKind.Transport => "transport"
        case AgentErrorKind.Provider => "provider"
        case AgentErrorKind.Protocol => "protocol"
        case AgentErrorKind.Cancelled => "cancelled"
        case AgentErrorKind.BudgetExceeded => "budget_exceeded"
        case AgentErrorKind.Conflict => "conflict"
        case AgentErrorKind.RecoveryRequired => "recovery_required"
        case AgentErrorKind.Internal => "internal"
    }
}

func brokerErrorKind(value: String): AgentErrorKind {
    match (value) {
        case "configuration" => AgentErrorKind.Configuration
        case "authentication" => AgentErrorKind.Authentication
        case "permission_denied" => AgentErrorKind.PermissionDenied
        case "invalid_input" => AgentErrorKind.InvalidInput
        case "rate_limited" => AgentErrorKind.RateLimited
        case "timeout" => AgentErrorKind.Timeout
        case "transport" => AgentErrorKind.Transport
        case "provider" => AgentErrorKind.Provider
        case "protocol" => AgentErrorKind.Protocol
        case "cancelled" => AgentErrorKind.Cancelled
        case "budget_exceeded" => AgentErrorKind.BudgetExceeded
        case "conflict" => AgentErrorKind.Conflict
        case "recovery_required" => AgentErrorKind.RecoveryRequired
        case _ => AgentErrorKind.Internal
    }
}

func prepareBrokerRuntime(
    paths: ProductProcessBrokerPaths
): Result<Unit> {
    if (paths.socketPath.size > 100) {
        return brokerError<Unit>(
            AgentErrorKind.Configuration,
            "hub.process_broker_socket_path_too_long",
            "process broker Unix socket path exceeds the portable limit"
        )
    }
    try {
        if (!exists(Path(paths.runtimeRoot))) {
            Directory.create(paths.runtimeRoot, recursive: true)
        }
        let info = FileInfo(Path(paths.runtimeRoot))
        if (!info.isDirectory() || info.isSymbolicLink()) {
            return brokerError<Unit>(
                AgentErrorKind.PermissionDenied,
                "hub.process_broker_runtime_unsafe",
                "process broker runtime path must be a real directory"
            )
        }
    } catch (error: Exception) {
        return brokerError<Unit>(
            AgentErrorKind.Configuration,
            "hub.process_broker_runtime_failed",
            error.message
        )
    }
    match (chmodBrokerPath(paths.runtimeRoot, "700")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    if (exists(Path(paths.tokenPath))) {
        let tokenInfo = try {
            FileInfo(Path(paths.tokenPath))
        } catch (error: Exception) {
            return brokerError<Unit>(
                AgentErrorKind.PermissionDenied,
                "hub.process_broker_token_invalid",
                error.message
            )
        }
        if (tokenInfo.isSymbolicLink() || !tokenInfo.isRegular() ||
            tokenInfo.size < 1 || tokenInfo.size > 128) {
            return brokerError<Unit>(
                AgentErrorKind.PermissionDenied,
                "hub.process_broker_token_invalid",
                "process broker token file is unsafe or malformed"
            )
        }
        match (chmodBrokerPath(paths.tokenPath, "600")) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    Result.Ok(())
}

func tryAcquireBrokerLease(
    paths: ProductProcessBrokerPaths,
    workspace: String
): Result<?String> {
    let token = match (secureBrokerToken()) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let candidate = paths.leasePath + ".pending-" + token
    try {
        Directory.create(candidate)
        let candidateInfo = FileInfo(Path(candidate))
        if (!candidateInfo.isDirectory() || candidateInfo.isSymbolicLink()) {
            let _ = removeIfExists(candidate, recursive: true)
            return brokerError<?String>(
                AgentErrorKind.PermissionDenied,
                "hub.process_broker_lease_invalid",
                "process broker lease candidate is unsafe"
            )
        }
        match (chmodBrokerPath(candidate, "700")) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = removeIfExists(candidate, recursive: true)
                return Result.Err(error)
        }
        let owner = brokerLeaseOwnerValue(
            token,
            workspace,
            brokerIdentity(workspace)
        )
        match (atomicBrokerWrite(
            candidate + "/owner.json",
            encodeAgentValue(owner),
            "600"
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = removeIfExists(candidate, recursive: true)
                return Result.Err(error)
        }
        try {
            rename(candidate, to: paths.leasePath, overwrite: false)
            Result.Ok(Some(token))
        } catch (_: Exception) {
            let _ = removeIfExists(candidate, recursive: true)
            Result.Ok(None)
        }
    } catch (error: Exception) {
        let _ = removeIfExists(candidate, recursive: true)
        brokerError<?String>(
            AgentErrorKind.Internal,
            "hub.process_broker_lease_failed",
            error.message
        )
    }
}

func brokerLeaseOwnedBy(
    paths: ProductProcessBrokerPaths,
    token: String,
    workspace: String
): Bool {
    let value = match (readBrokerLease(paths.leasePath)) {
        case Some(item) => item
        case None => return false
    }
    constantTimeBrokerTokenEquals(brokerText(value, "token"), token) &&
        brokerText(value, "workspace") == workspace &&
        brokerInteger(value, "protocol", 0) == PROCESS_BROKER_PROTOCOL
}

func brokerLeaseOwnedByIdentity(
    paths: ProductProcessBrokerPaths,
    workspace: String,
    identity: AgentValue
): Bool {
    let value = match (readBrokerLease(paths.leasePath)) {
        case Some(item) => item
        case None => return false
    }
    brokerText(value, "workspace") == workspace &&
        brokerInteger(value, "protocol", 0) == PROCESS_BROKER_PROTOCOL &&
        validBrokerToken(brokerText(value, "token")) &&
        brokerInteger(value, "pid", 0) == brokerInteger(identity, "pid", 0) &&
        brokerText(value, "startIdentity") ==
            brokerText(identity, "startIdentity") &&
        brokerProcessIdentityMatches(
            brokerInteger(value, "pid", 0),
            brokerText(value, "startIdentity")
        )
}

func brokerLeaseOwnerConfirmedDead(
    paths: ProductProcessBrokerPaths,
    workspace: String
): Bool {
    if (!exists(Path(paths.leasePath))) { return false }
    let value = match (readBrokerLease(paths.leasePath)) {
        case Some(item) => item
        case None => return false
    }
    brokerOwnerIdentityConfirmedDead(value, workspace)
}

func readBrokerLease(path: String): ?AgentValue {
    try {
        let owner = path + "/owner.json"
        if (!exists(Path(owner))) { return None }
        let info = FileInfo(Path(owner))
        if (!info.isRegular() || info.isSymbolicLink() ||
            info.size < 1 || info.size > 4096) {
            return None
        }
        match (decodeAgentValue(
            String.fromUtf8(File.readFrom(owner)),
            maxBytes: 4096
        )) {
            case Result.Ok(value) => Some(value)
            case Result.Err(_) => None
        }
    } catch (_: Exception) {
        None
    }
}

func recoverDeadBrokerLease(
    paths: ProductProcessBrokerPaths,
    workspace: String
): Bool {
    let stale = paths.leasePath + ".stale-" + getProcessId().toString() +
        "-" + processBrokerSequence.fetchAdd(1).toString()
    try {
        rename(paths.leasePath, to: stale, overwrite: false)
        let dead = match (readBrokerLease(stale)) {
            case Some(value) => brokerOwnerIdentityConfirmedDead(
                value,
                workspace
            )
            case None => false
        }
        if (dead) {
            let _ = removeIfExists(stale, recursive: true)
            return true
        }
        try {
            rename(stale, to: paths.leasePath, overwrite: false)
        } catch (_: Exception) {}
        false
    } catch (_: Exception) {
        false
    }
}

func releaseBrokerLease(
    paths: ProductProcessBrokerPaths,
    token: String
): Unit {
    let release = paths.leasePath + ".release-" + getProcessId().toString() +
        "-" + processBrokerSequence.fetchAdd(1).toString()
    try {
        rename(paths.leasePath, to: release, overwrite: false)
        let value = readBrokerLease(release)
        let owned = match (value) {
            case Some(item) => constantTimeBrokerTokenEquals(
                brokerText(item, "token"),
                token
            )
            case None => false
        }
        if (owned) {
            let _ = removeIfExists(release, recursive: true)
        } else {
            try {
                rename(release, to: paths.leasePath, overwrite: false)
            } catch (_: Exception) {}
        }
    } catch (_: Exception) {}
}

func readBrokerToken(path: String): Result<String> {
    if (!exists(Path(path))) { return Result.Ok("") }
    try {
        let info = FileInfo(Path(path))
        if (!info.isRegular() || info.isSymbolicLink() ||
            info.size < 1 || info.size > 128) {
            return brokerError<String>(
                AgentErrorKind.PermissionDenied,
                "hub.process_broker_token_invalid",
                "process broker token file is unsafe or malformed"
            )
        }
        let token = String.fromUtf8(File.readFrom(path)).trimAscii()
        if (!validBrokerToken(token)) {
            return brokerError<String>(
                AgentErrorKind.Authentication,
                "hub.process_broker_token_invalid",
                "process broker token is malformed"
            )
        }
        Result.Ok(token)
    } catch (error: Exception) {
        brokerError<String>(
            AgentErrorKind.PermissionDenied,
            "hub.process_broker_token_read_failed",
            error.message
        )
    }
}

func ensureBrokerToken(path: String): Result<String> {
    match (readBrokerToken(path)) {
        case Result.Ok(value) =>
            if (value != "") { return Result.Ok(value) }
        case Result.Err(error) => return Result.Err(error)
    }
    let token = match (secureBrokerToken()) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (atomicBrokerWrite(path, token + "\n", "600")) {
        case Result.Ok(_) => Result.Ok(token)
        case Result.Err(error) => Result.Err(error)
    }
}

func secureBrokerToken(): Result<String> {
    let file = try {
        File("/dev/urandom", OpenMode.Read)
    } catch (error: Exception) {
        return brokerError<String>(
            AgentErrorKind.Internal,
            "hub.process_broker_random_failed",
            error.message
        )
    }
    let bytes = Array<Byte>(32, repeat: 0)
    var offset: Int64 = 0
    try {
        while (offset < bytes.size) {
            let buffer = Array<Byte>(bytes.size - offset, repeat: 0)
            let count = file.read(buffer)
            if (count <= 0) {
                return brokerError<String>(
                    AgentErrorKind.Internal,
                    "hub.process_broker_random_failed",
                    "secure random source ended unexpectedly"
                )
            }
            for (index in 0..count) {
                bytes[offset + index] = buffer[index]
            }
            offset += count
        }
    } catch (error: Exception) {
        return brokerError<String>(
            AgentErrorKind.Internal,
            "hub.process_broker_random_failed",
            error.message
        )
    } finally {
        try { file.close() } catch (_: Exception) {}
    }
    var token = ""
    for (byte in bytes) {
        let encoded = byte.toString(radix: 16)
        if (encoded.size == 1) { token += "0" }
        token += encoded
    }
    Result.Ok(token)
}

func atomicBrokerWrite(
    path: String,
    source: String,
    mode: String
): Result<Unit> {
    var temporary = ""
    try {
        // The destination-directory temporary is created exclusively with a
        // random name.  Keep writing through that already-open handle so a
        // pre-planted symlink can neither capture nor overwrite broker
        // credentials before the atomic rename.
        let file = File.createTemp(Path(path).parent)
        temporary = file.info.path.toString()
        try {
            file.write(source.toArray())
        } finally {
            file.close()
        }
        let info = FileInfo(Path(temporary))
        if (!info.isRegular() || info.isSymbolicLink()) {
            let _ = removeIfExists(temporary)
            return brokerError<Unit>(
                AgentErrorKind.PermissionDenied,
                "hub.process_broker_temporary_invalid",
                "process broker temporary file is unsafe"
            )
        }
        match (chmodBrokerPath(temporary, mode)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = removeIfExists(temporary)
                return Result.Err(error)
        }
        rename(temporary, to: path, overwrite: true)
        Result.Ok(())
    } catch (error: Exception) {
        if (temporary != "") {
            let _ = removeIfExists(temporary)
        }
        brokerError<Unit>(
            AgentErrorKind.Internal,
            "hub.process_broker_write_failed",
            error.message
        )
    }
}

func chmodBrokerPath(path: String, mode: String): Result<Unit> {
    let (code, _, error) = executeWithOutput(
        "/usr/bin/chmod",
        [mode, "--", path]
    )
    if (code == 0) { return Result.Ok(()) }
    brokerError<Unit>(
        AgentErrorKind.PermissionDenied,
        "hub.process_broker_permissions_failed",
        String.fromUtf8(error).trimAscii()
    )
}

func validBrokerToken(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in unsafe { value.rawData() }) {
        if (!((byte >= b'0' && byte <= b'9') ||
            (byte >= b'a' && byte <= b'f'))) {
            return false
        }
    }
    true
}

func constantTimeBrokerTokenEquals(left: String, right: String): Bool {
    let leftBytes = unsafe { left.rawData() }
    let rightBytes = unsafe { right.rawData() }
    var difference: Int64 = leftBytes.size ^ rightBytes.size
    let limit = max(leftBytes.size, rightBytes.size)
    for (index in 0..limit) {
        let a: UInt8 = if (index < leftBytes.size) {
            leftBytes[index]
        } else {
            0
        }
        let b: UInt8 = if (index < rightBytes.size) {
            rightBytes[index]
        } else {
            0
        }
        difference = difference | Int64(a ^ b)
    }
    difference == 0
}

func stableBrokerScope(value: String): String {
    var first: Int64 = 17
    var second: Int64 = 97
    for (byte in unsafe { value.rawData() }) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    first.toString(radix: 16) + "-" + second.toString(radix: 16)
}

func currentBrokerExecutable(): String {
    let arguments = getCommandLine()
    if (arguments.isEmpty()) { return "" }
    let candidate = arguments[0]
    try {
        if (exists(Path(candidate))) {
            canonicalize(Path(candidate)).toString()
        } else {
            candidate
        }
    } catch (_: Exception) {
        candidate
    }
}

func brokerRequestId(): String {
    getProcessId().toString() + "-" + nowMillis().toString() + "-" +
        processBrokerSequence.fetchAdd(1).toString()
}

func brokerAuthenticationError(error: AgentError): Bool {
    error.kind == AgentErrorKind.Authentication ||
        error.code == "hub.process_broker_auth_failed"
}

func brokerCliArgument(
    arguments: Array<String>,
    name: String
): String {
    var index: Int64 = 2
    while (index + 1 < arguments.size) {
        if (arguments[index] == name) { return arguments[index + 1] }
        index += 1
    }
    ""
}

func brokerCliHasArgument(
    arguments: Array<String>,
    name: String
): Bool {
    for (argument in arguments where argument == name) { return true }
    false
}

func brokerText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func brokerInteger(
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

func brokerBoolean(
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

func brokerError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}
