package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_host_runtime.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import logical_json_payload.LogicalJsonOwnerReservation as ProcessBrokerOwner180
import std.collection.*
import process4cj.*
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
        // Portable Unix-socket budget: the whole socket path must stay under
        // 100 bytes, and a clean install may live under a long temporary
        // root. Keep the per-install scope but drop the redundant segment.
        this.runtimeRoot = normalizedState + "/r/pb-" + scope
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
    private let shellNetworkMode: ShellNetworkMode
    private let sandboxCaBundle: String
    private let paths: ProductProcessBrokerPaths
    private let configuration180: ?ProductConfig
    private var frontendOwnerPid180:Int64=0
    private var frontendOwnerStart180=""
    private var frontendToken180=""
    private var frontendRequestId180=""

    init(
        stateRoot: String,
        workspace: String,
        shellNetworkMode!: ShellNetworkMode = ShellNetworkMode.Restricted,
        sandboxCaBundle!: String = "",
        configuration180!: ?ProductConfig = None<ProductConfig>
    ) {
        this.stateRoot = Path(stateRoot).normalize().toString()
        this.workspace = workspace
        this.shellNetworkMode = shellNetworkMode
        this.sandboxCaBundle = sandboxCaBundle.trimAscii()
        this.executable = currentBrokerExecutable()
        this.configuration180 = configuration180
        this.paths = ProductProcessBrokerPaths(this.stateRoot, workspace)
    }

    // The shipping Native route never sends a Source object/history grant.
    // Actual Root identity and a one-use, durably issued DATA ticket are bound
    // independently; the Root must claim it against the live canonical Store.
    func captureDerivedTarget180(request:AgentValue,meter:HostPaidValueProjection151):Result<AgentValue>{
        meter.fundAdditional151(65536+stateRoot.size*2+workspace.size*2,32)
        let token=match(ensureBroker()){case Result.Ok(value)=>value;case Result.Err(error)=>return Result.Err(error)}
        let shape=meter.measureBorrowedValue151(request)
        meter.fundAdditional151(shape.storageBytes*2,shape.nodes*2+16)
        let requestId=brokerRequestId()
        let packet=objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId",textValue(requestId)),ValueField("token",textValue(token)),
            ValueField("workspace",textValue(workspace)),ValueField("kind",textValue("observe-process180")),
            ValueField("request",request)])
        let response=match(brokerPaidRoundTrip180(paths.socketPath,packet,requestId,meter)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(response.field("actual_target")){case Some(value)=>Result.Ok(value)
            case None=>brokerError<AgentValue>(AgentErrorKind.Protocol,"hub.process_target_missing","actual broker target is missing")}
    }
    func executeDerived180(request:AgentValue,owner:String,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        let result=executeDerivedTransportHelper180(request,owner,lease)
        lease.retireRootWireAfterTransportHelper180()
        let _=lease.completeNonPersistentCurrentBridge180()
        result
    }
    private func executeDerivedTransportHelper180(request:AgentValue,owner:String,lease:HostHubDerivedProcessLease180):Result<ToolResult>{
        match(lease.validateActualRequest180(request)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lease.retainData180(65536+stateRoot.size*2+workspace.size*2+owner.size*2,32)
        let token=match(ensureBroker()){case Result.Ok(value)=>value;case Result.Err(error)=>return Result.Err(error)}
        let identity=match(probeWithToken(token)){case Result.Ok(value)=>value;case Result.Err(error)=>return Result.Err(error)}
        let pid=brokerInteger(identity,"pid",0);let start=brokerText(identity,"startIdentity")
        if(!brokerLeaseOwnedByIdentity(paths,workspace,identity)){
            return brokerError<ToolResult>(AgentErrorKind.PermissionDenied,"hub.process_root_identity_changed","actual broker ownership changed")}
        let nonce=match(secureBrokerToken()){case Result.Ok(value)=>value;case Result.Err(error)=>return Result.Err(error)}
        let currentPath="/tmp/axyndra-current-"+nonce+".sock"
        lease.prepareActualHostCurrentBridge180(currentPath,nonce,pid,start)
        match(chmodBrokerPath(currentPath,"600")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lease.startActualHostCurrentBridge180()
        let ticket=match(lease.issueActualRootHandoff180(pid,start,nonce)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        lease.retainData180(65536+token.size*2+nonce.size*2+paths.socketPath.size*2+workspace.size*2,32)
        lease.prepareRootRestrictionBeforeClosure180()
        match(lease.installActualRootRestriction180({=>revokeActualRootTransportHelper180(token,nonce,lease)})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lease.fundBorrowedDataBeforeCopy180(request)
        lease.reserveRootWireBeforeCodec180(ticket)
        let wire=hubProcessRootWireValue180(ticket)
        lease.fundBorrowedDataBeforeCopy180(wire)
        let requestId=brokerRequestId()
        let packet=objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId",textValue(requestId)),ValueField("token",textValue(token)),
            ValueField("workspace",textValue(workspace)),ValueField("kind",textValue("derived-process180")),
            ValueField("owner",textValue(owner)),ValueField("request",request),ValueField("handoff",wire)])
        let response=match(brokerPaidRoundTrip180(paths.socketPath,packet,requestId,lease)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let retained=match(response.field("service_retained")){
            case Some(value)=>if(value.unifiedKind==ValueKind.Boolean){value.asBool()}
                else{throw IllegalStateException("actual Root disposition is invalid")}
            case None=>throw IllegalStateException("actual Root disposition is missing")}
        lease.noteActualRootDisposition180(retained)
        decodeBrokerToolResult(response)
    }
    private func revokeActualRootTransportHelper180(token:String,nonce:String,
        lease:HostHubDerivedProcessLease180):Result<Unit>{
        let id=brokerRequestId()
        let packet=objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId",textValue(id)),ValueField("token",textValue(token)),
            ValueField("workspace",textValue(workspace)),ValueField("kind",textValue("revoke-process180")),
            ValueField("nonce",textValue(nonce))])
        match(brokerPaidRoundTrip180(paths.socketPath,packet,id,lease)){
            case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result<Unit>.Ok(())}
    }
    func executeDerivedIfConfigured180(request:AgentValue,owner:String,
        lease:HostHubDerivedProcessLease180):?Result<ToolResult>{
        if(!exists(Path(paths.tokenPath))){return None<Result<ToolResult>>}
        Some(executeDerived180(request,owner,lease))
    }


    func probe(tokenOverride!: String = ""): Result<AgentValue> {
        let token = match (ensureBroker()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        probeWithToken(if (tokenOverride == "") { token } else { tokenOverride })
    }

    func pathsValue(): AgentValue { paths.value() }


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
                brokerSetsidLauncher(),
                [
                    "-f",
                    executable,
                    "__process-broker-worker",
                    "--state-root",
                    stateRoot,
                    "--workspace",
                    workspace,
                    "--shell-network-mode",
                    shellNetworkModeName(shellNetworkMode),
                    "--sandbox-ca-bundle",
                    sandboxCaBundle,
                    "--lease-token",
                    leaseToken
                    ,"--settings-root",match(configuration180){case Some(config)=>config.settingsRoot;case None=>defaultProductHome()}
                    ,"--distribution-root",match(configuration180){case Some(config)=>config.distributionRoot;case None=>""}
                    ,"--fixture",match(configuration180){case Some(config)=>if(config.fixture){"true"}else{"false"};case None=>"false"}
                    ,"--unsafe-direct-launch-for-tests",match(configuration180){case Some(config)=>if(config.unsafeDirectLaunchForTests){"true"}else{"false"};case None=>"false"}
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
        if(configuration180.isSome()){
            frontendOwnerPid180=brokerInteger(identity,"pid",0)
            frontendOwnerStart180=brokerText(identity,"startIdentity");frontendToken180=token}
        Result.Ok(identity)
    }
    func newFrontendRendezvous180(data:ActualProcessBrokerData180):ActualOwnerFrontendRendezvous180{
        ActualOwnerFrontendRendezvous180(data,configuration180.getOrThrow(),paths.socketPath,
            workspace,frontendToken180,frontendOwnerPid180,frontendOwnerStart180,frontendRequestId180)
    }
    func openFrontend180(request:AgentValue,root:ActualOwnerClientRoot180):Result<ActualProductOwnerPeer180>{
        let data=root.currentData180()
        let token=match(ensureBroker()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let config=configuration180.getOrThrow()
        let socket=UnixSocket(paths.socketPath)
        root.installPhysicalSocketBeforePeerConstruction180(socket)
        let peer=ActualProductOwnerPeer180(socket,data,config,PROCESS_BROKER_MAX_RESPONSE_BYTES,PROCESS_BROKER_MAX_REQUEST_BYTES)
        root.installPhysicalPeerBeforeConnect180(peer)
        peer.initializePhysicalPeer180()
        try{socket.connect(timeout:Some(Duration.second*5))}
        catch(error:Exception){peer.retainOriginalPhysicalFailure180(error);return brokerError<ActualProductOwnerPeer180>(AgentErrorKind.Transport,"owner.peer_connect_failed",error.message)}
        let id=brokerRequestId()
        frontendRequestId180=id
        let packet=objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId",textValue(id)),ValueField("token",textValue(token)),
            ValueField("workspace",textValue(workspace)),ValueField("kind",textValue("frontend180")),
            ValueField("request",request)])
        data.fundValue(packet)
        let encoded=encodeAgentValue(packet)
        match(peer.writeOwnerFrame180(encoded,None)){case Result.Err(error)=>let _=peer.closeOwnerPeer180();return Result.Err(error);case Result.Ok(_)=>()}
        peer.enableAuthenticatedIdle180();Result.Ok(peer)
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
    println(encodeAgentValue(brokerErrorValue(AgentError(AgentErrorKind.InvalidInput,
        "hub.process_broker_cli_request", "broker client supports only --paths and --probe"))))
    return 2
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

// restart uses a persisted readiness spec which is not present in the request;
// its legal maximum is one hour, plus the stop phase and transport margin.
func brokerOperationReadTimeout(request: AgentValue): Int64 {
    let op = daemonValueText(request, "op")
    let arguments = request.field("arguments") ?? objectValue([])
    var deadline: Int64 = 0
    match (op) {
        case "start" => match (arguments.field("ready")) {
            case Some(ready) => deadline = secondsToMillis(daemonValueInteger(ready, "timeout", 30), 30)
            case None => ()
        }
        case "restart" => deadline = 3600000 + 7000
        case "wait" => deadline = secondsToMillis(daemonValueInteger(arguments, "timeout", 30), 30)
        case "logs" => if (brokerBoolean(arguments, "follow", false)) {
            deadline = secondsToMillis(daemonValueInteger(arguments, "timeout", 30), 30)
        }
        case "stop" => deadline = secondsToMillis(daemonValueInteger(arguments, "timeout", 5), 5) + 2000
        case _ => ()
    }
    max(10000, deadline + 10000)
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
        socket.readTimeout = Some(Duration.millisecond * brokerOperationReadTimeout(request))
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
            Result.Ok(Option<String>.None)
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
    let bytes = Array<Byte>(32, repeat: 0)
    try {
        fillSecureRandom(bytes)
    } catch (error: Exception) {
        return brokerError<String>(
            AgentErrorKind.Internal,
            "hub.process_broker_random_failed",
            error.message
        )
    }
    let digits = "0123456789abcdef".toArray()
    var token = ""
    for (byte in bytes) {
        let value = UInt8(byte)
        token += String.fromUtf8([digits[Int64((value >> 4) & 0x0f)]])
        token += String.fromUtf8([digits[Int64(value & 0x0f)]])
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
    // Exactly eight hex characters so the socket path budget is predictable.
    // A collision only makes two installs share a runtime root, which the
    // lease and token protocol already arbitrates; it grants no authority.
    let text = (first ^ (second * 2654435761 % 2147483647)).toString(radix: 16)
    if (text.size >= 8) { text[text.size - 8..] } else { text }
}

// The broker must start under a minimal PATH: a clean install is allowed to
// expose only the package's own runtime directory. Resolve the launcher from
// the fixed system directories first and fall back to a bare name so a
// nonstandard layout still behaves as before.
func brokerSetsidLauncher(): String {
    for (candidate in ["/usr/bin/setsid", "/bin/setsid"]) {
        try {
            if (exists(Path(candidate)) && !FileInfo(Path(candidate)).isSymbolicLink()) {
                return candidate
            }
        } catch (_: Exception) {}
    }
    "setsid"
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
            try { Int64.parse(field.asNumberText()) } catch (_: Exception) { fallback }
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
            if (field.unifiedKind == ValueKind.Boolean) { field.asBool() } else { fallback }
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


// All original transport limits and operation timeout policy remain unchanged.
// The meter/lease already belongs to the original canonical Native bank. Its
// escaping response/error stays paid there; there is no raw-output refund.
func brokerPaidRoundTrip180(path:String,request:AgentValue,id:String,meter:HostPaidValueProjection151):Result<AgentValue>{
    let shape=meter.measureBorrowedValue151(request)
    if(shape.bytes>Int64.Max/4 || shape.nodes>(Int64.Max-32)/2){throw LogicalJsonPayloadError("process wire invoice overflow")}
    meter.fundAdditional151(shape.bytes*4,shape.nodes*2+32)
    brokerPaidRoundTripHelper180(path,request,id,{bytes,nodes=>meter.fundAdditional151(bytes,nodes)})
}
func brokerPaidRoundTrip180(path:String,request:AgentValue,id:String,lease:HostHubDerivedProcessLease180):Result<AgentValue>{
    lease.fundBorrowedDataBeforeCopy180(request)
    let cell=lease.reserveControlBeforeClosure180()
    cell.fundProducerFrameBeforeEffect180(65536)
    let result=ActualProcessBrokerClientResult180()
    cell.invokeSynchronousHelper180({=>
        match(brokerPaidRoundTripHelper180(path,request,id,{bytes,nodes=>lease.retainData180(bytes,nodes)},failureCell:Some(cell))){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(value)=>result.response=Some(value)}})
    cell.noteSynchronousHelperReturned180()
    // Whole socket/read/decode/close helper has returned. A complete Root
    // failure or close secondary stays in the same registered original pool.
    if(cell.hasOriginalFailure180()){throw HostHubProcessHeldProducerFailure180(cell)}
    let answer=result.response.getOrThrow();result.response=None<AgentValue>
    if(!cell.retireObservedReturn()){throw HostHubProcessHeldProducerFailure180(cell)}
    Result<AgentValue>.Ok(answer)
}
func brokerNativeReadTimeout180(request:AgentValue):Int64{
    // The original timeout helper consumes the original argument grammar;
    // Native has frozen the same defaults into *_ms DATA, not larger caps.
    let input=request.field("request") ?? objectValue([])
    let op=brokerText(input,"op");var deadline:Int64=0
    match(op){
        case "start"=>match(input.field("spec")){case Some(spec)=>match(spec.field("ready")){
            case Some(ready)=>deadline=brokerInteger(ready,"timeoutMs",30000);case None=>()};case None=>()}
        case "restart"=>deadline=3607000
        case "wait"=>deadline=brokerInteger(input,"timeout_ms",30000)
        case "logs"=>if(brokerBoolean(input,"follow",false)){deadline=brokerInteger(input,"timeout_ms",30000)}
        case "stop"=>deadline=brokerInteger(input,"timeout_ms",5000)+2000
        case _=>()}
    max(10000,deadline+10000)
}
class ActualProcessBrokerClientResult180 {var response:?AgentValue=None<AgentValue>;init(){}}
func brokerPaidRoundTripHelper180(path:String,request:AgentValue,id:String,
    fund:(Int64,Int64)->Unit,failureCell!:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>):Result<AgentValue>{
    fund(65536+path.size*2+id.size*2,32)
    let payload=encodeAgentValue(request)+"\n"
    if(payload.size>PROCESS_BROKER_MAX_REQUEST_BYTES){return brokerError<AgentValue>(AgentErrorKind.InvalidInput,
        "hub.process_broker_frame_too_large","process broker request exceeds the frame limit")}
    fund(payload.size*2,4)
    let socket=UnixSocket(path)
    try{
        socket.readTimeout=Some(Duration.millisecond*brokerNativeReadTimeout180(request))
        socket.writeTimeout=Some(Duration.second*10);socket.connect(timeout:Some(Duration.millisecond*500))
        socket.write(payload.toArray())
        let source=match(readPaidBrokerFrame180(socket,PROCESS_BROKER_MAX_RESPONSE_BYTES,fund)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        fund(source.size*6,brokerBorrowedLexicalNodes180(source)+32)
        let response=match(decodeAgentValue(source,maxBytes:PROCESS_BROKER_MAX_RESPONSE_BYTES)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(brokerInteger(response,"version",0)!=PROCESS_BROKER_PROTOCOL || brokerText(response,"requestId")!=id){
            return brokerError<AgentValue>(AgentErrorKind.Protocol,"hub.process_broker_response_mismatch","process broker response identity does not match the request")}
        if(!brokerBoolean(response,"ok",false)){
            let value=match(response.field("error")){case Some(item)=>item;case None=>return brokerError<AgentValue>(
                AgentErrorKind.Protocol,"hub.process_broker_error_missing","process broker returned an error without details")}
            let primary=match(decodeCompleteProcessBrokerError180(value)){
                case Result.Ok(error)=>error;case Result.Err(error)=>return Result.Err(error)}
            match(failureCell){case Some(cell)=>
                // The original eight-field primary is installed BEFORE any
                // secondary decode/holder operation can fail under pressure.
                cell.retainFailureBeforeCleanup180(OwnedCanonicalDataFailure113(primary))
                match(response.field("secondary_errors")){case Some(value)=>
                    match(value as JsonArray){case Some(values)=>
                        for(index in 0..values.size()){
                            let secondary=match(decodeCompleteProcessBrokerError180(values.get(index).getOrThrow())){
                                case Result.Ok(error)=>error
                                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)}
                            cell.retainActualCleanupFailure180(OwnedCanonicalDataFailure113(secondary))
                            if(cell.hasUnregisteredSecondary180()){throw HostHubProcessHeldProducerFailure180(cell)}}
                        case None=>throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.Protocol,
                            "hub.process_broker_secondary_invalid","complete process secondary error array is invalid"))}
                    case None=>()}
                throw HostHubProcessHeldProducerFailure180(cell)
                case None=>return Result.Err(primary)}}
        Result.Ok(response)
    }catch(error:Exception){
        match(failureCell){case Some(cell)=>
            // This cell's own opaque carrier is not another failure. It only
            // transports the exact already installed primary/secondary set.
            match(error as HostHubProcessHeldProducerFailure180){case Some(held)=>
                if(!refEq(held.producer,cell)){cell.retainActualCleanupFailure180(error)}
                case None=>if(cell.hasOriginalFailure180()){cell.retainActualCleanupFailure180(error)}
                    else{cell.retainFailureBeforeCleanup180(error)}}
            case None=>()}
        throw error
    }finally{
        try{socket.close()}
        catch(error:Exception){match(failureCell){case Some(cell)=>
            if(cell.hasOriginalFailure180()){cell.retainActualCleanupFailure180(error)}
            else{cell.retainFailureBeforeCleanup180(error)}
            case None=>throw error}}}
}
// No source.toArray/DOM is needed to prepay the actual complete lexer nodes.
// It supplies only an invoice; the original decoder still validates grammar.
func brokerBorrowedLexicalNodes180(source:String):Int64{
    var quoted=false;var escaped=false;var scalar=false;var count:Int64=0
    unsafe{let data=source.rawData();for(index in 0..data.size){let byte=data[index]
        if(quoted){if(escaped){escaped=false}else if(byte==b'\\'){escaped=true}else if(byte==b'"'){quoted=false}}
        else if(byte==b'"'){quoted=true;scalar=false;count+=1}
        else if(byte==b'{' || byte==b'['){scalar=false;count+=1}
        else if(byte==b',' || byte==b':' || byte==b'}' || byte==b']' || byte==b' ' || byte==b'\n' || byte==b'\r' || byte==b'\t'){scalar=false}
        else if(!scalar){scalar=true;count+=1}}}
    count
}
func readPaidBrokerFrame180(stream:InputStream,limit:Int64,fund:(Int64,Int64)->Unit):Result<String>{
    fund(16384,8)
    let bytes=ArrayList<Byte>();let buffer=Array<Byte>(4096,repeat:0)
    while(true){
        let count=stream.read(buffer)
        if(count<=0){return brokerError<String>(AgentErrorKind.Protocol,"hub.process_broker_frame_incomplete",
            "process broker connection ended before the NDJSON frame")}
        fund(count*2,0)
        for(index in 0..count){let byte=buffer[index]
            if(byte==b'\n'){fund(bytes.size*2,2);return Result.Ok(String.fromUtf8(bytes.toArray()))}
            if(bytes.size>=limit){return brokerError<String>(AgentErrorKind.Protocol,"hub.process_broker_frame_too_large",
                "process broker NDJSON frame exceeds the configured limit")}
            // Pay each actual backing occurrence BEFORE growing the list.
            bytes.add(byte)}}
    brokerError<String>(AgentErrorKind.Internal,"hub.process_broker_read_unreachable","process broker frame reader stopped unexpectedly")
}


// Root and all child shares use the original process-wide Native bank. The
// fixed registry is allocated only in the real external broker process.
// Keeping an unknown action/error reachable is intentional paid custody.
var retainedActualProcessBrokerRoot180:?ActualProcessBrokerRoot180=None<ActualProcessBrokerRoot180>

class ActualProcessBrokerData180{
    private let lock=Mutex()
    private let owner:ProcessBrokerOwner180
    private var peak:Int64=65536
    private var scalarPeak:Int64=0
    private var retired=false
    init(owner:ProcessBrokerOwner180){this.owner=owner}
    func fund(bytes:Int64,nodes:Int64):Unit{
        lock.lock();try{
            if(retired || bytes<0 || nodes<0 || bytes>(Int64.Max-4096)/8 ||
                nodes>(Int64.Max-4096-bytes*8)/512){throw IllegalStateException("actual broker invoice is invalid")}
            let invoice=bytes*8+nodes*512+4096
            if(peak>Int64.Max-invoice-scalarPeak){throw IllegalStateException("actual broker invoice SUM overflow")}
            owner.ensureRetainedPeak(peak+invoice+scalarPeak);peak+=invoice
        }finally{lock.unlock()}
    }
    func fundScalar(bytes:Int64):Unit{
        lock.lock();try{if(retired || bytes<0 || peak>Int64.Max-bytes){throw IllegalStateException("broker scalar invoice overflow")}
            owner.ensureRetainedPeak(peak+max(scalarPeak,bytes));scalarPeak=max(scalarPeak,bytes)
        }finally{lock.unlock()}
    }
    func fundValue(value:AgentValue):Unit{
        fund(4096,8)
        let shape=hostProjectionMeasure151(value,{bytes=>fundScalar(bytes)})
        if(shape.bytes>Int64.Max/4 || shape.storageBytes>Int64.Max/4 || shape.nodes>Int64.Max/2){
            throw IllegalStateException("broker complete value invoice overflow")}
        fund(shape.bytes*4+shape.storageBytes*2,shape.nodes*2+16)
    }
    func derive(invoice:Int64):ProcessBrokerOwner180{
        lock.lock();try{if(retired){throw IllegalStateException("broker data owner is retired")}
            let child=owner.deriveRetainedLease()
            try{child.ensureRetainedPeak(invoice);child}catch(error:Exception){child.close();throw error}
        }finally{lock.unlock()}
    }
    func ownsOriginalFramePayment180(frame: LogicalJsonOwnerReservation): Bool { frame.paysSamePrivateBankData180(owner) }
    // The actual outer registry invokes this only after its entire handler
    // and Future-observation helper returned and every dynamic member cleared.
    func retireAfterWholeHandler180():Unit{lock.lock();try{owner.close();retired=true}finally{lock.unlock()}}
}

class ActualProcessBrokerSlot180{
    private let lock=Mutex()
    private let root:ActualProcessBrokerRoot180
    private var paid:?ActualProcessBrokerData180=None<ActualProcessBrokerData180>
    private var socket:?UnixSocket=None<UnixSocket>
    private var action:?()->Unit=None<()->Unit>
    private var worker:?Future<Unit>=None<Future<Unit>>
    private var original:?Exception=None<Exception>
    // Registered fixed slots cover this actual handler, renderer and socket
    // close's distinct returned exceptions. No late error overwrites another.
    private let secondary=Array<?Exception>(4,repeat:None<Exception>)
    private var secondaryCount:Int64=0
    private var secondaryOverflow:?Exception=None<Exception>
    private var renderedFailure180:?ActualProcessBrokerFailureFrame180=None<ActualProcessBrokerFailureFrame180>
    private var failure:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>
    private var storeFailure:?HubProcessStoreFailure180=None<HubProcessStoreFailure180>
    private var producerFailure180:?HostHubProcessProducerCell=None<HostHubProcessProducerCell>
    private var joining=false
    private var socketReturned=false
    private var outputReturned=false
    private var unknownSpawn=false
    private var futureReturned=false
    private var service:?ActualProcessBrokerService180=None<ActualProcessBrokerService180>
    private var observerPayment:?ProcessBrokerOwner180=None<ProcessBrokerOwner180>
    private var frontendPeer180:?ActualProductOwnerPeer180=None<ActualProductOwnerPeer180>
    private var inboundFrame180:?ProcessBrokerOwner180=None<ProcessBrokerOwner180>
    private var lifetimeObservationRequested180=false
    private var lifetimeObservationAnswer180:?Bool=None<Bool>
    private var frontendRequest180=""
    private var retiringFrontendRequest180=""
    private var inboundCodec180:?ProcessBrokerOwner180=None<ProcessBrokerOwner180>
    init(root:ActualProcessBrokerRoot180){this.root=root}
    func reserveBeforeAccept180():Bool{
        lock.lock();try{
            if(paid.isSome() || joining){return false}
            // A failure to allocate/construct retains the derived share in the
            // Root pending slot. No accepted socket/action is inferred absent.
            let value=root.newRegisteredData180();paid=Some(value)
            socketReturned=false;outputReturned=false;unknownSpawn=false;futureReturned=false
            lifetimeObservationRequested180=false;lifetimeObservationAnswer180=None<Bool>
            frontendRequest180="";retiringFrontendRequest180="";true
        }finally{lock.unlock()}
    }
    func isLifetimeObservation180():Bool{lock.lock();try{paid.isSome() && lifetimeObservationRequested180}finally{lock.unlock()}}
    func isVacant180():Bool{lock.lock();try{paid.isNone() && !joining}finally{lock.unlock()}}
    func registerFrontendRequest180(id:String):Unit{
        lock.lock();try{frontendRequest180=id}finally{lock.unlock()}}
    private func frontendRequestIdentity180():String{
        lock.lock();try{frontendRequest180}finally{lock.unlock()}}
    func waitsForFrontend180(other:ActualProcessBrokerSlot180):Bool{
        let id=other.frontendRequestIdentity180()
        lock.lock();try{id!="" && retiringFrontendRequest180==id}finally{lock.unlock()}}
    func awaitLifetimeObservation180(retiringId:String):Bool{
        let until=MonoTime.now()+Duration.second*5
        lock.lock();try{
            retiringFrontendRequest180=retiringId;lifetimeObservationRequested180=true
        }finally{lock.unlock()}
        while(true){
            lock.lock();let answer=try{lifetimeObservationAnswer180}finally{lock.unlock()}
            match(answer){case Some(value)=>return value;case None=>()}
            if(MonoTime.now()>=until){throw OwnedCanonicalDataFailure113(AgentError(
                AgentErrorKind.Timeout,"owner.frontend_retirement_pending","original frontend helper has not retired"))}
            sleep(Duration.millisecond*10)
        }
        true
    }
    func answerLifetimeObservation180(debt:Bool):Unit{
        lock.lock();try{if(lifetimeObservationRequested180 && lifetimeObservationAnswer180.isNone()){
            lifetimeObservationAnswer180=Some(debt)}}finally{lock.unlock()}
    }
    func retainActualSupervisorOwner180(value:HostHubDerivedProcessLease180):Unit{
        lock.lock();try{service.getOrThrow().retainActualSupervisorOwner180(value)}finally{lock.unlock()}
    }
    func currentData180():ActualProcessBrokerData180{lock.lock();try{paid.getOrThrow()}finally{lock.unlock()}}
    func installFrontendPeerBeforeRead180(peer:ActualProductOwnerPeer180):ProcessBrokerOwner180 {
        lock.lock();try {
            frontendPeer180=Some(peer)
            let raw=paid.getOrThrow().derive(65536);inboundFrame180=Some(raw);raw
        }finally{lock.unlock()}
    }
    func fundInboundDecodeBeforeAllocation180(source:String):Unit {
        lock.lock();try {
            let invoice=source.size*48+brokerBorrowedLexicalNodes180(source)*1024+32768
            let codec=paid.getOrThrow().derive(invoice);inboundCodec180=Some(codec)
        }finally{lock.unlock()}
    }
    func installServiceBeforeClaim180(value:ActualProcessBrokerService180):Unit{
        lock.lock();try{if(service.isSome()){throw IllegalStateException("actual request service is already retained")};service=Some(value)}
        finally{lock.unlock()}
    }
    func retainObserverBeforeConstruction180():ProcessBrokerOwner180{
        lock.lock();try{if(observerPayment.isSome()){throw IllegalStateException("observer is already retained")}
            let value=root.derive180(65536);observerPayment=Some(value);value
        }finally{lock.unlock()}}
    func installAndSpawn180(client:UnixSocket):Unit{
        lock.lock();try{
            socket=Some(client)
            // Fixed slot/data/control metadata was prepaid before this closure.
            action=Some({=>invokeActual180()});unknownSpawn=true
            worker=Some(spawn{invokeRegisteredAction180()});unknownSpawn=false
        }finally{lock.unlock()}
    }
    private func invokeRegisteredAction180():Unit{let actual=borrowAction180();actual()}
    private func borrowAction180():()->Unit{lock.lock();try{action.getOrThrow()}finally{lock.unlock()}}
    private func invokeActual180():Unit{
        let client=borrowSocket180()
        try{handleActualProcessBroker180(client,root,this)}
        catch(error:Exception){retainOriginal180(error)}
        finally{
            try {
                lock.lock();let actual=try{frontendPeer180}finally{lock.unlock()}
                match(actual){case Some(peer)=>match(peer.closeOwnerPeer180()){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
                    case None=>client.close()}
                noteSocketReturned180()
            }
            catch(error:Exception){retainOriginal180(error)}}
    }
    private func borrowSocket180():UnixSocket{lock.lock();try{socket.getOrThrow()}finally{lock.unlock()}}
    private func noteSocketReturned180():Unit{lock.lock();try{socketReturned=true}finally{lock.unlock()}}
    func noteOutputHelperReturned180():Unit{lock.lock();try{outputReturned=true}finally{lock.unlock()}}

    func retainOriginal180(error:Exception):Unit{
        lock.lock();try{
            if(original.isNone()){original=Some(error)}
            else if(!refEq(original.getOrThrow(),error)){
                for(index in 0..secondaryCount){if(refEq(secondary[index].getOrThrow(),error)){return}}
                if(secondaryCount<4){secondary[secondaryCount]=Some(error);secondaryCount+=1}
                else if(secondaryOverflow.isNone()){secondaryOverflow=Some(error)}
                else if(!refEq(secondaryOverflow.getOrThrow(),error)){
                    throw IllegalStateException("actual broker secondary registration remains held")}}

            // The exact raw Exception stays here if full capture runs out of
            // capacity. The output path is recognized/held, never short fallback.
            match(error as HubProcessStoreFailure180){case Some(cell)=>storeFailure=Some(cell);case None=>()}
        }finally{lock.unlock()}
    }
    func renderFailure180(client:UnixSocket,id:String,error:AgentError):Bool{
        let data=currentData180()
        let consumer=match(captureOwnedFailureData113<Unit>(error,{bytes=>data.derive(bytes)})){
            case OwnedFailureDataOutcome113.Failure(value)=>value
            case OwnedFailureDataOutcome113.Value(_)=>throw IllegalStateException("broker error capture lost failure")}
        lock.lock();try{failure=Some(consumer)}finally{lock.unlock()}
        if(!writeActualProcessBrokerFailure180(client,id,consumer,data)){return false}
        // The writer, complete encoder, exact fd.write and loan returned.
        match(consumer.acknowledgeAfterConsumption()){case Result.Err(_)=>return false;case Result.Ok(_)=>()}
        lock.lock(); let actual = try { frontendPeer180 } finally { lock.unlock() }
        match (actual) { case Some(peer) => peer.observeFrontendFailureConsumed180(error); case None => () }
        lock.lock();try{failure=None<OwnedFailureDataConsumer113>
            if(secondaryCount==0 && secondaryOverflow.isNone()){original=None<Exception>};outputReturned=true}
        finally{lock.unlock()};true
    }
    func renderProducerFailure180(client:UnixSocket,id:String,cell:HostHubProcessProducerCell):Bool{
        lock.lock();try{
            if(producerFailure180.isSome() && !refEq(producerFailure180.getOrThrow(),cell)){
                throw IllegalStateException("another actual process failure is still retained")}
            producerFailure180=Some(cell)
        }finally{lock.unlock()}
        // An opaque recognized source never falls back to its carrier message.
        // No consumer on pressure means no output and the same paid debt.
        if(!cell.collectReturned()){return false}
        let data=currentData180()
        let count=cell.secondaryFailureCount180()
        if(count<0 || count>(Int64.Max-65536)/4096 || cell.hasUnregisteredSecondary180()){return false}
        data.fund(65536+count*4096+id.size*8,count+32)
        let frame=ActualProcessBrokerFailureFrame180(data)
        // The paid slot is installed before any fallible source admission,
        // encoder/list/String allocation. Pressure leaves this exact frame.
        lock.lock();try{
            if(renderedFailure180.isSome()){return false};renderedFailure180=Some(frame)
        }finally{lock.unlock()}
        if(!frame.prepareProducerWholeHelper180(cell,count,id)){return false}
        if(!frame.writeWholeFrameHelper180(client)){return false}
        // Encoded aliases belong to Root DATA and are dropped after the actual
        // writer helper returned, before ACK of only this rendered set.
        if(!frame.retireWrittenSources180()){return false}
        noteOutputHelperReturned180();true
    }
    func renderStoreFailure180(client:UnixSocket,id:String,cell:HubProcessStoreFailure180):Bool{
        retainOriginal180(cell)
        let data=currentData180()
        let accepted=cell.admitFailure180({consumer=>
            if(!writeActualProcessBrokerFailure180(client,id,consumer,data)){return false}
            match(consumer.acknowledgeAfterConsumption()){case Result.Ok(_)=>true;case Result.Err(_)=>false}})
        if(accepted){noteOutputHelperReturned180()};accepted
    }
    private func observeWholeFutureReturn180():Bool {
        let value=borrowFuture180()
        match(value){case Some(actual)=>
            try {if(actual.tryGet().isNone()){return false};actual.get();true}
            catch(error:Exception){retainOriginal180(error);false}
            case None=>false}
    }
    private func borrowFuture180():?Future<Unit>{lock.lock();try{worker}finally{lock.unlock()}}
    private func collectOriginalFrontendHelpers180(): Bool {
        lock.lock(); let actual = try { frontendPeer180 } finally { lock.unlock() }
        match (actual) {
            case Some(peer) =>
                match (peer.closeConcreteFrontendHelper180()) {
                    case Result.Err(error) => retainOriginal180(OwnedCanonicalDataFailure113(error)); return false
                    case Result.Ok(_) => () }
                match (peer.retireAfterOriginalEnclosingHelpers180()) {
                    case Result.Err(error) => retainOriginal180(OwnedCanonicalDataFailure113(error)); return false
                    case Result.Ok(_) => () }
                lock.lock(); try { frontendPeer180 = None<ActualProductOwnerPeer180> } finally { lock.unlock() }
            case None => () }
        true
    }

    func collectActualReturn180():Bool{
        lock.lock();try{if(paid.isNone()){return true};if(joining || unknownSpawn || (!futureReturned && worker.isNone())){return false};joining=true}
        finally{lock.unlock()}
        try{
            lock.lock();let observed=try{futureReturned}finally{lock.unlock()}
            if(!observed && !observeWholeFutureReturn180()){return false}
            if(!collectOriginalFrontendHelpers180()){return false}
            lock.lock();try{
                // Joining is actual Future return, not an active--/finally flag.
                futureReturned=true;action=None<()->Unit>;worker=None<Future<Unit>>
                if(!socketReturned){return false};socket=None<UnixSocket>
                match(producerFailure180){case Some(cell)=>
                    if(!cell.retireObservedReturn()){return false}
                    producerFailure180=None<HostHubProcessProducerCell>;original=None<Exception>
                    case None=>()}
                match(storeFailure){case Some(cell)=>
                    if(!cell.retireReturnedPayment180()){return false}
                    storeFailure=None<HubProcessStoreFailure180>;original=None<Exception>
                    case None=>()}
                match(renderedFailure180){case Some(frame)=>
                    if(!frame.sourcesRetired180()){return false};renderedFailure180=None<ActualProcessBrokerFailureFrame180>
                    case None=>()}
                if(original.isSome() || secondaryCount!=0 || secondaryOverflow.isSome() || failure.isSome() || !outputReturned){return false}

                match(inboundFrame180){case Some(frame)=>frame.close();inboundFrame180=None<ProcessBrokerOwner180>;case None=>()}
                match(inboundCodec180){case Some(frame)=>frame.close();inboundCodec180=None<ProcessBrokerOwner180>;case None=>()}
                // Service DATA may be retired only now, after the entire
                // actual handler/Future observation returned. A persistent
                // start remains in its private physical incarnation owner.
                match(service){case Some(entry)=>
                    if(entry.retireReturnedRequest180()){service=None<ActualProcessBrokerService180>}
                    else if(entry.isPersistentIncarnation180()){service=None<ActualProcessBrokerService180>}
                    else{return false}
                    case None=>()}
                match(observerPayment){case Some(value)=>value.close();observerPayment=None<ProcessBrokerOwner180>;case None=>()}
                frontendRequest180="";retiringFrontendRequest180=""
                let data=paid.getOrThrow();data.retireAfterWholeHandler180()
                paid=None<ActualProcessBrokerData180>;true
            }finally{lock.unlock()}
        }finally{lock.lock();try{joining=false}finally{lock.unlock()}}
    }
    // A failed accept has no action/Future/socket. Only the outer accept helper
    // can establish this exact synchronous return; it is never used for spawn.
    func retireReturnedAccept180():Unit{
        lock.lock();try{if(socket.isSome() || action.isSome() || worker.isSome() || unknownSpawn){return}
            let value=paid.getOrThrow();value.retireAfterWholeHandler180();paid=None<ActualProcessBrokerData180>
        }finally{lock.unlock()}}
}

class ActualProcessBrokerService180{
    private let lock=Mutex()
    var pending:?ProcessBrokerOwner180=None<ProcessBrokerOwner180>
    var meter:?HostPaidValueProjection151=None<HostPaidValueProjection151>
    var lease:?HostHubDerivedProcessLease180=None<HostHubDerivedProcessLease180>
    private var busy=false
    private var persistent=false
    private var borrowed180:Int64=0
    private var retiringRequest180=false
    init(){}
    func reserve180(paid:ProcessBrokerOwner180):Unit{
        lock.lock();try{if(busy || pending.isSome() || meter.isSome() || lease.isSome()){
            throw IllegalStateException("actual process service slot remains retained")}
            pending=Some(paid);busy=true;persistent=false
        }finally{lock.unlock()}
    }
    func isVacant180():Bool{lock.lock();try{!retiringRequest180 && !busy && pending.isNone() && meter.isNone() && lease.isNone()}finally{lock.unlock()}}
    func installLease180(value:HostHubDerivedProcessLease180,start:Bool):Unit{
        lock.lock();try{lease=Some(value);persistent=start}finally{lock.unlock()}
    }
    func matchesActualNonce180(nonce:String):Bool{
        lock.lock();try{match(lease){case Some(value)=>value.matchesActualRootNonce180(nonce);case None=>false}}
        finally{lock.unlock()}
    }
    private func beginRestrictionLeaseLoan180():Bool{
        lock.lock();try{
            if(!busy || lease.isNone() || borrowed180==Int64.Max){return false}
            borrowed180+=1;true
        }finally{lock.unlock()}
    }
    private func borrowRestrictionLeaseHelper180():HostHubDerivedProcessLease180{
        lock.lock();try{lease.getOrThrow()}finally{lock.unlock()}
    }
    private func invokeRestrictionLeaseHelper180():Result<Unit>{
        let actual=borrowRestrictionLeaseHelper180()
        actual.revoke()
    }
    func revokeActualRestriction180():Result<Unit>{
        // The whole helper and its actual lease alias return/unwind before
        // the entry drops this loan. A borrow count is not a consumption ACK.
        if(!beginRestrictionLeaseLoan180()){
            return brokerError<Unit>(AgentErrorKind.PermissionDenied,
                "hub.process_root_restriction_unobserved","actual private Root lease is not retained")}
        try{return invokeRestrictionLeaseHelper180()}
        finally{lock.lock();try{borrowed180-=1}finally{lock.unlock()}}
    }
    func retainActualSupervisorOwner180(value:HostHubDerivedProcessLease180):Unit{
        lock.lock();try{
            if(lease.isNone() || !refEq(lease.getOrThrow(),value)){throw IllegalStateException("actual service owner differs from claimed Root lease")}
            persistent=true
        }finally{lock.unlock()}
    }
    func isPersistentIncarnation180():Bool{lock.lock();try{persistent}finally{lock.unlock()}}
    private func prepareReturnedRequestLeaseHelper180():Bool{
        lock.lock();try{
            if(persistent || borrowed180!=0){return false}
            // The actual handler and Future-observation helper already
            // returned. This entry stays busy and keeps its exact original
            // payment while the remaining private lease control is retired.
            match(lease){case Some(value)=>
                if(!value.hasNoProcessProducers180() || !value.retireReturnedRootRequestControl180()){return false}
                case None=>()}
            lease=None<HostHubDerivedProcessLease180>;true
        }finally{lock.unlock()}
    }
    private func retireReturnedRequestPaymentHelper180():Unit{
        lock.lock();try{
            if(persistent || borrowed180!=0 || lease.isSome()){
                throw IllegalStateException("actual service lease still owns request DATA")}
            // The WHOLE lease helper returned before entry payment can close:
            // no immutable plan/ticket/current/effect alias survives there.
            // A close error keeps these exact meter/payment fields reachable.
            match(meter){case Some(value)=>value.closeUnpublished151()
                case None=>match(pending){case Some(value)=>value.close();case None=>()}}
        }finally{lock.unlock()}
    }
    func retireReturnedRequest180():Bool{
        lock.lock();try{
            if(retiringRequest180 || persistent || borrowed180!=0){return false}
            retiringRequest180=true
        }finally{lock.unlock()}
        try{
            if(!prepareReturnedRequestLeaseHelper180()){return false}
            retireReturnedRequestPaymentHelper180()
            // Both private helper frames really returned. Only fixed paid
            // Root registry metadata remains; no request Source is reissued.
            lock.lock();try{
                meter=None<HostPaidValueProjection151>;pending=None<ProcessBrokerOwner180>
                busy=false;true
            }finally{lock.unlock()}
        }finally{lock.lock();try{retiringRequest180=false}finally{lock.unlock()}}
    }
}
class ActualProcessBrokerRoot180{
    private let lock=Mutex()
    private let owner:ProcessBrokerOwner180
    private var pending:?ProcessBrokerOwner180=None<ProcessBrokerOwner180>
    private let slots=ArrayList<ActualProcessBrokerSlot180>()
    private let services=ArrayList<ActualProcessBrokerService180>()
    private let inputs180=ArrayList<ActualProcessBrokerInput180>()
    private var rootPeak:Int64=524288
    var supervisor:?ProductProcessSupervisor=None<ProductProcessSupervisor>
    var operations:?DurableOperationStore=None<DurableOperationStore>
    var database:?SqliteDatabase=None<SqliteDatabase>
    var actualProduct180: ?ProductRuntime = None<ProductRuntime>
    var configuration180: ?ProductConfig = None<ProductConfig>
    private let frontend180: ProductOwnerFrontend180
    var token=""
    var workspace=""
    var identity:?AgentValue=None<AgentValue>
    var server:?UnixServerSocket=None<UnixServerSocket>
    var startupFailure:?Exception=None<Exception>
    // Readiness is published before the Product assembly completes: the socket
    // is bound and answers ping immediately, while `frontend180` requests wait
    // for the assembly. Crashing the socket on a slow assembly would turn a
    // 20 s first install into an unobservable 7 s transport failure.
    private let assemblyCompleted180=AtomicBool(false)
    private var assemblyFuture180:?Future<Unit>=None<Future<Unit>>
    private let assemblyLock180=Mutex()
    private var launchingFrontendPid180:Int64=0
    private var launchingFrontendStart180=""
    private var idleServeReturned180=false
    private var physicalShutdownReturned180=false
    private let frontendObserved180=AtomicBool(false)
    init(owner:ProcessBrokerOwner180,frontend180:ProductOwnerFrontend180){this.owner=owner;this.frontend180=frontend180;for(_ in 0..32){slots.add(ActualProcessBrokerSlot180(this))}}
    func captureLaunchingFrontend180(paths:ProductProcessBrokerPaths,leaseToken:String):Unit{
        let lease=readBrokerLease(paths.leasePath).getOrThrow()
        if(!constantTimeBrokerTokenEquals(brokerText(lease,"token"),leaseToken) ||
            brokerText(lease,"workspace")!=workspace){throw IllegalStateException("actual launching frontend lease changed")}
        launchingFrontendPid180=brokerInteger(lease,"pid",0)
        launchingFrontendStart180=brokerText(lease,"startIdentity")
        if(launchingFrontendPid180<=0 || launchingFrontendStart180==""){
            throw IllegalStateException("actual launching frontend identity is unknown")}
    }
    private func launchingFrontendGoneWholeHelper180():Bool{
        if(launchingFrontendPid180<=0 || launchingFrontendStart180==""){return false}
        let proc="/proc/"+launchingFrontendPid180.toString()
        if(!exists(Path(proc))){return true}
        let actual=linuxProcessStartToken(proc+"/stat")
        // An unreadable live PID is unknown, not proof of caller death.
        actual!="" && actual!=launchingFrontendStart180
    }
    func startAssembly180(build:() -> ProductRuntime):Unit{
        let future=spawn{
            let product=build()
            lock.lock();try{actualProduct180=Some(product)}finally{lock.unlock()}
            assemblyCompleted180.store(true)
        }
        assemblyLock180.lock();try{assemblyFuture180=Some(future)}finally{assemblyLock180.unlock()}
    }
    private func awaitAssembly180():(?ProductRuntime,?Exception){
        match(assemblyFuture180){case Some(future)=>
            try{future.get()}catch(error:Exception){return (None<ProductRuntime>,Some(error))}
            case None=>()}
        lock.lock();try{
            match(actualProduct180){case Some(product)=>return (Some(product),None<Exception>)
                case None=>return (None<ProductRuntime>,startupFailure)}
        }finally{lock.unlock()}
    }
    private func collectAssembly180():Bool{
        match(assemblyFuture180){case Some(future)=>
            try{if(future.tryGet().isNone()){return false};future.get();assemblyFuture180=None<Future<Unit>>;true}
            catch(_:Exception){assemblyFuture180=None<Future<Unit>>;false}
            case None=>true}
    }
    func bindActualProduct180(product:ProductRuntime,database:SqliteDatabase,operations:DurableOperationStore,config:ProductConfig):Unit {
        if(actualProduct180.isSome() || this.operations.isSome() || this.database.isSome()){throw IllegalStateException("actual Product owner is already bound")}
        this.database=Some(database);this.operations=Some(operations);configuration180=Some(config);actualProduct180=Some(product)
        let paths=ProductProcessBrokerPaths(config.stateRoot,product.workspace.rootPath())
        supervisor=Some(ProductProcessSupervisor(product.workspace,brokerRoot:paths.runtimeRoot,
            sandboxEnabled:product.directProcessSandboxEnabled(),allowUnsafeTestBypass:config.unsafeDirectLaunchForTests,
            shellNetworkMode:product.shellNetworkMode,sandboxCaBundle:product.sandboxCaBundle,brokerRootData180:Some(this)))
        supervisor.getOrThrow().initializeBrokerStorage180()
    }
    func serveFrontend180(request:AgentValue,peer:ProductOwnerPeer180):Result<Unit>{
        frontendObserved180.store(true)
        // Readiness was published before assembly; the actual owner is only
        // usable once the background assembly returned.
        let (product,failure)=awaitAssembly180()
        match(failure){case Some(error)=>throw OwnedCanonicalDataFailure113(
            AgentError(AgentErrorKind.Transport,"hub.process_broker_assembly_failed",error.message))
            case None=>()}
        frontend180.serveOwnerFrontend180(product.getOrThrow(),request,peer)
    }
    func retainRootData180(bytes:Int64):Unit{
        lock.lock();try{if(bytes<0 || rootPeak>Int64.Max-bytes){throw IllegalStateException("process Root retained SUM overflow")}
            owner.ensureRetainedPeak(rootPeak+bytes);rootPeak+=bytes
        }finally{lock.unlock()}}
    func derive180(invoice:Int64):ProcessBrokerOwner180{
        lock.lock();try{
            if(pending.isSome()){throw IllegalStateException("unknown Root allocation remains paid")}
            let paid=owner.deriveRetainedLease();pending=Some(paid);paid.ensureRetainedPeak(invoice)
            pending=None<ProcessBrokerOwner180>;paid
        }finally{lock.unlock()}}
    func newRegisteredData180():ActualProcessBrokerData180{
        lock.lock();try{
            if(pending.isSome()){throw IllegalStateException("unknown Root data construction remains paid")}
            let paid=owner.deriveRetainedLease();pending=Some(paid);paid.ensureRetainedPeak(65536)
            let result=ActualProcessBrokerData180(paid);pending=None<ProcessBrokerOwner180>;result
        }finally{lock.unlock()}}
    func claimService180(value:AgentValue,slot:ActualProcessBrokerSlot180):HostHubDerivedProcessLease180{
        let entry:ActualProcessBrokerService180
        lock.lock();try{
            if(pending.isSome()){throw IllegalStateException("unregistered process service share remains paid")}
            var vacant:?ActualProcessBrokerService180=None<ActualProcessBrokerService180>
            for(actual in services){if(actual.isVacant180()){vacant=Some(actual);break}}
            if(vacant.isNone()){
                if(rootPeak>Int64.Max-4096){throw IllegalStateException("process service metadata overflow")}
                owner.ensureRetainedPeak(rootPeak+4096);rootPeak+=4096
                let actual=ActualProcessBrokerService180();services.add(actual);vacant=Some(actual)}
            let paid=owner.deriveRetainedLease();pending=Some(paid);paid.ensureRetainedPeak(65536)
            entry=vacant.getOrThrow();entry.reserve180(paid);pending=None<ProcessBrokerOwner180>
        }finally{lock.unlock()}
        slot.installServiceBeforeClaim180(entry)
        let meter=HostPaidValueProjection151(entry.pending.getOrThrow());entry.meter=Some(meter)
        let shape=meter.measureBorrowedValue151(value)
        meter.fundAdditional151(shape.bytes*4+shape.storageBytes*2,shape.nodes*2+128)
        let ticket=decodeHubProcessRootWireData180(value)
        let lease=match(HostHubDerivedProcessLease180.claimActualRootHandoff180(operations.getOrThrow(),ticket,meter,decodeCompleteProcessBrokerError180)){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(actual)=>actual}
        let request=ticket.plan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("request").getOrThrow()
        entry.installLease180(lease,brokerText(request,"op")=="start");lease
    }
    private func borrowActualServiceByNonceHelper180(nonce:String):?ActualProcessBrokerService180{
        lock.lock();try{
            var selected:?ActualProcessBrokerService180=None<ActualProcessBrokerService180>
            for(entry in services){if(entry.matchesActualNonce180(nonce)){
                if(selected.isSome()){throw IllegalStateException("actual Root nonce has duplicate private owners")}
                selected=Some(entry)}}
            selected
        }finally{lock.unlock()}
    }
    func revokeActualService180(nonce:String):Result<Unit>{
        // This real private-lease lookup returns before SQL allocates through
        // the Root owner. No Root registry lock is held across the database.
        let actual=match(borrowActualServiceByNonceHelper180(nonce)){case Some(value)=>value
            case None=>return brokerError<Unit>(AgentErrorKind.PermissionDenied,
                "hub.process_root_restriction_unobserved","actual Root lease is not registered")}
        actual.revokeActualRestriction180()
    }
    func registerActualInputBeforeConstruction180():ActualProcessBrokerInput180 {
        lock.lock();try {
            if(pending.isSome()){throw IllegalStateException("unknown Root input payment remains held")}
            var vacant:?ActualProcessBrokerInput180=None<ActualProcessBrokerInput180>
            for(value in inputs180){if(value.isVacant180()){vacant=Some(value);break}}
            if(vacant.isNone()){
                if(rootPeak>Int64.Max-4096){throw IllegalStateException("actual input registry SUM overflow")}
                owner.ensureRetainedPeak(rootPeak+4096);rootPeak+=4096
                let value=ActualProcessBrokerInput180(workspace);inputs180.add(value);vacant=Some(value)}
            let payment=owner.deriveRetainedLease();pending=Some(payment);payment.ensureRetainedPeak(131072)
            let data=ActualProcessBrokerData180(payment)
            let value=vacant.getOrThrow();value.reserveBeforeConstruction180(data)
            pending=None<ProcessBrokerOwner180>;value
        }finally{lock.unlock()}
    }

    func serve180():Unit{
        var pendingAccept:?ActualProcessBrokerSlot180=None<ActualProcessBrokerSlot180>
        while(true){
            // The same registered accept payment survives empty polls. Only
            // the returned helper may retire it; persistent owners do not
            // allocate another bank share on every scheduling interval.
            for(slot in slots){let _=slot.collectActualReturn180()}
            answerLifetimeObservations180(pendingAccept)
            if(idleExceptReturnedAccept180(pendingAccept)){
                match(pendingAccept){case Some(slot)=>slot.retireReturnedAccept180();case None=>()}
                pendingAccept=None<ActualProcessBrokerSlot180>
                if(collectIdleRootWholeHelper180()){idleServeReturned180=true;return}
            }
            if(pendingAccept.isNone()){
                for(slot in slots){if(slot.reserveBeforeAccept180()){pendingAccept=Some(slot);break}}}
            if(pendingAccept.isNone()){sleep(Duration.millisecond*20);continue}
            let slot=pendingAccept.getOrThrow()
            let client=try{acceptWholeHelper180()}
            catch(_:SocketTimeoutException){continue}
            catch(error:Exception){
                // An unexpected accept exception retains its original slot.
                slot.retainOriginal180(error);startupFailure=Some(error);return}
            slot.installAndSpawn180(client);pendingAccept=None<ActualProcessBrokerSlot180>
        }
    }
    private func acceptWholeHelper180():UnixSocket{
        server.getOrThrow().accept(timeout:Some(Duration.millisecond*100))}
    // A control response is only a scalar observation. Its own original peer,
    // output and Future must still return before the idle Root can exit.
    private func answerLifetimeObservations180(pendingAccept:?ActualProcessBrokerSlot180):Unit{
        var observing=false
        for(slot in slots){if(slot.isLifetimeObservation180()){observing=true}}
        if(!observing){return}
        let persistentDebt=hasNonSlotLifetimeDebt180()
        for(observer in slots){
            if(!observer.isLifetimeObservation180()){continue}
            var retiring=false;var otherDebt=persistentDebt
            for(slot in slots){
                match(pendingAccept){case Some(value)=>if(refEq(slot,value)){continue};case None=>()}
                if(refEq(slot,observer) || slot.isLifetimeObservation180() || slot.isVacant180()){continue}
                // Only this observer's original authenticated frontend must
                // return first. Other live frontends keep the shared owner.
                if(observer.waitsForFrontend180(slot)){retiring=true}else{otherDebt=true}
            }
            if(!retiring){observer.answerLifetimeObservation180(otherDebt)}
        }
    }
    private func idleExceptReturnedAccept180(pendingAccept:?ActualProcessBrokerSlot180):Bool{
        if(!frontendObserved180.load() && !launchingFrontendGoneWholeHelper180()){return false}
        for(slot in slots){
            match(pendingAccept){case Some(value)=>if(refEq(slot,value)){continue};case None=>()}
            if(!slot.isVacant180()){return false}}
        !hasNonSlotLifetimeDebt180()
    }
    private func hasNonSlotLifetimeDebt180():Bool{
        lock.lock();try{
            if(startupFailure.isSome() || pending.isSome()){return true}
            for(entry in services){if(!entry.isVacant180()){return true}}
            for(input in inputs180){if(!input.isVacant180()){return true}}
        }finally{lock.unlock()}
        // A running assembly is real debt: shutdown must not keep the socket
        // after the Product it is building can no longer be retired.
        if(!collectAssembly180()){return true}
        match(actualProduct180){case Some(product)=>product.hasOwnerLifetimeDebt180();case None=>false}
    }
    private func collectIdleRootWholeHelper180():Bool{
        if(!frontendObserved180.load() && !launchingFrontendGoneWholeHelper180()){return false}
        for(slot in slots){if(!slot.collectActualReturn180()){return false}}
        !hasNonSlotLifetimeDebt180()
    }
    private func closeIdleProductWholeHelper180():Unit{
        match(actualProduct180){case None=>return;case Some(_)=>()}
        match(actualProduct180.getOrThrow().close()){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
    }
    private func closeIdleServerWholeHelper180():Unit{server.getOrThrow().close()}
    func closeAfterIdleServeHelper180():Bool{
        if(!idleServeReturned180 || !collectIdleRootWholeHelper180()){return false}
        // No new accept can activate work after the returned serve helper.
        // Product.close is cleanup only after the actual scalar debt check;
        // it is never an idle probe or permission to cancel persistent work.
        closeIdleServerWholeHelper180();server=None<UnixServerSocket>
        closeIdleProductWholeHelper180()
        physicalShutdownReturned180=true;true
    }
    func retireAfterWholeOwnerHelper180():Bool{
        if(!physicalShutdownReturned180 || startupFailure.isSome() || pending.isSome()){return false}
        if(!collectAssembly180()){return false}
        actualProduct180=None<ProductRuntime>;operations=None<DurableOperationStore>
        database=None<SqliteDatabase>;supervisor=None<ProductProcessSupervisor>
        configuration180=None<ProductConfig>;identity=None<AgentValue>;token="";workspace=""
        launchingFrontendStart180="";launchingFrontendPid180=0
        slots.clear();services.clear();inputs180.clear()
        owner.close();true
    }
}

func writeActualProcessBrokerValue180(client:UnixSocket,response:AgentValue,data:ActualProcessBrokerData180):Unit{
    data.fundValue(response)
    let encoded=encodeAgentValue(response)
    if(encoded.size>PROCESS_BROKER_MAX_RESPONSE_BYTES){throw OwnedCanonicalDataFailure113(AgentError(
        AgentErrorKind.Protocol,"hub.process_broker_response_too_large","process broker response exceeds the configured limit"))}
    data.fund(encoded.size*2+2,2)
    client.write((encoded+"\n").toArray())
}
class ActualProcessBrokerWriteState180{var returned=false;init(){}}
func writeActualProcessBrokerFailure180(client:UnixSocket,id:String,consumer:OwnedFailureDataConsumer113,
    data:ActualProcessBrokerData180):Bool{
    data.fund(4096+id.size*2,32)
    let state=ActualProcessBrokerWriteState180()
    let loan=consumer.withError({error,fund=>
        let prefix=[ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId",textValue(id)),ValueField("ok",boolValue(false))]
        let encoded=match(encodeOwnedFailureError113(error,prefix,"error",fund)){
            case Result.Err(failure)=>throw OwnedCanonicalDataFailure113(failure);case Result.Ok(value)=>value}
        if(encoded.size>PROCESS_BROKER_MAX_RESPONSE_BYTES){throw IllegalStateException("complete process failure exceeds original frame limit")}
        match(fund(encoded.size*2+2)){case Result.Err(failure)=>throw OwnedCanonicalDataFailure113(failure);case Result.Ok(_)=>()}
        client.write((encoded+"\n").toArray());state.returned=true})
    loan.isOk() && state.returned
}
func handleActualProcessBroker180(client:UnixSocket,root:ActualProcessBrokerRoot180,slot:ActualProcessBrokerSlot180):Unit{
    let data=slot.currentData180()
    let peer=ActualProductOwnerPeer180(client,data,root.configuration180.getOrThrow(),PROCESS_BROKER_MAX_REQUEST_BYTES,PROCESS_BROKER_MAX_RESPONSE_BYTES)
    let rawPayment=slot.installFrontendPeerBeforeRead180(peer)
    peer.initializePhysicalPeer180()
    var id=""
    try{
        let source=match(peer.readOwnerFrame180(rawPayment,None)){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(value)=>value}
        slot.fundInboundDecodeBeforeAllocation180(source)
        let request=match(decodeAgentValue(source,maxBytes:PROCESS_BROKER_MAX_REQUEST_BYTES)){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(value)=>value}
        id=brokerText(request,"requestId")
        match(validateBrokerRequest(request,root.token,root.workspace)){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
        let kind=brokerText(request,"kind")
        data.fund(65536+id.size*2,64)
        if(kind=="ping"){
            writeActualProcessBrokerValue180(client,objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
                ValueField("requestId",textValue(id)),ValueField("ok",boolValue(true)),
                ValueField("identity",root.identity.getOrThrow())]),data)
        }else if(kind=="frontend-lifetime180"){
            if(brokerInteger(request,"ownerPid",0)!=brokerInteger(root.identity.getOrThrow(),"pid",0) ||
                brokerText(request,"ownerStart")!=brokerText(root.identity.getOrThrow(),"startIdentity")){
                throw IllegalStateException("frontend lifetime observation changed actual owner identity")}
            let retiringId=brokerText(request,"retiringFrontendRequestId")
            if(retiringId=="" || retiringId.size>256){throw IllegalStateException("frontend lifetime observation has no bounded original request identity")}
            let debt=slot.awaitLifetimeObservation180(retiringId)
            writeActualProcessBrokerValue180(client,objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
                ValueField("requestId",textValue(id)),ValueField("otherDebt",boolValue(debt))]),data)
        }else if(kind=="frontend180"){
            slot.registerFrontendRequest180(id)
            peer.enableAuthenticatedIdle180()
            match(root.serveFrontend180(request.field("request").getOrThrow(),peer)){
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
        }else{throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.Protocol,"hub.process_broker_kind_invalid","unsupported broker request kind"))}
        slot.noteOutputHelperReturned180()
    }catch(error:Exception){
        slot.retainOriginal180(error)
        match(error as HostHubProcessHeldProducerFailure180){
            case Some(actual)=>let _=slot.renderProducerFailure180(client,id,actual.producer)
            case None=>match(error as HubProcessStoreFailure180){case Some(cell)=>let _=slot.renderStoreFailure180(client,id,cell)
            case None=>match(error as OwnedCanonicalDataFailure113){case Some(failure)=>let _=slot.renderFailure180(client,id,failure.error)
                case None=>let _=slot.renderFailure180(client,id,AgentError(AgentErrorKind.Transport,
                    "hub.process_broker_transport_failed",error.message))}}}
    }
}


// The broker Root owns the prepaid registry, canonical database and accepted
// tasks. Process effects require the durably claimed Derived Service handoff.
public func runProductProcessBrokerWorker(arguments:Array<String>,frontend180:ProductOwnerFrontend180):Int64{
    let paid=reserveProductControlMetadata113(65536)
    paid.ensureRetainedPeak(524288)
    let root=ActualProcessBrokerRoot180(paid,frontend180)
    retainedActualProcessBrokerRoot180=Some(root)
    try{
        let status=initializeAndServeActualProcessBroker180(arguments,root)
        if(!root.retireAfterWholeOwnerHelper180()){return 1}
        retainedActualProcessBrokerRoot180=None<ActualProcessBrokerRoot180>;return status
    }
    catch(error:Exception){root.startupFailure=Some(error);return 1}
}
func initializeAndServeActualProcessBroker180(arguments:Array<String>,root:ActualProcessBrokerRoot180):Int64{
    // Borrowing sizes creates no argument copies. The real Root prepays the
    // complete path/configuration/lease arguments before their old projections.
    var bytes:Int64=65536
    for(value in arguments){if(value.size>(Int64.Max-bytes)/8){throw IllegalStateException("process Root argument SUM overflow")};bytes+=value.size*8}
    root.retainRootData180(bytes)
    let stateRoot=brokerCliArgument(arguments,"--state-root")
    let authoredWorkspace=brokerCliArgument(arguments,"--workspace")
    let leaseToken=brokerCliArgument(arguments,"--lease-token")
    let authoredMode=brokerCliArgument(arguments,"--shell-network-mode")
    let ca=brokerCliArgument(arguments,"--sandbox-ca-bundle")
    let mode=if(authoredMode==""){ShellNetworkMode.Restricted}else{
        match(parseShellNetworkMode(authoredMode)){case Result.Ok(value)=>value;case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)}}
    if(stateRoot=="" || authoredWorkspace=="" || leaseToken==""){return 2}
    let workspace=LocalWorkspace(authoredWorkspace)
    let canonical=workspace.rootPath()
    root.retainRootData180(canonical.size*8+65536)
    let paths=ProductProcessBrokerPaths(stateRoot,canonical)
    match(prepareBrokerRuntime(paths)){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
    if(!brokerLeaseOwnedBy(paths,leaseToken,canonical)){return 1}
    let token=match(readBrokerToken(paths.tokenPath)){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(value)=>value}
    if(token==""){return 1}
    let identity=brokerIdentity(canonical)
    root.identity=Some(identity);root.token=token;root.workspace=canonical
    root.captureLaunchingFrontend180(paths,leaseToken)
    match(assignBrokerLeaseOwner(paths,leaseToken,canonical,identity)){
        case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
    root.retainRootData180(65536)
    let settings=brokerCliArgument(arguments,"--settings-root")
    let distribution=brokerCliArgument(arguments,"--distribution-root")
    let fixture=brokerCliArgument(arguments,"--fixture")=="true"
    let unsafeFixture=brokerCliArgument(arguments,"--unsafe-direct-launch-for-tests")=="true"
    let config=ProductConfig(settingsRoot:if(settings==""){defaultProductHome()}else{settings},
        stateRoot:stateRoot,workspaceRoot:canonical,fixture:fixture,unsafeDirectLaunchForTests:unsafeFixture,
        startupMode:ProductStartupMode.Owner,distributionRoot:distribution)
    // Bind first: readiness must not depend on how long the first install
    // takes. The assembly runs on its own worker and `frontend180` waits for it.
    let server=UnixServerSocket(bindAt:paths.socketPath);root.server=Some(server)
    server.backlogSize=32;server.bind()
    match(chmodBrokerPath(paths.socketPath,"600")){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
    match(atomicBrokerWrite(paths.identityPath,encodeAgentValue(identity),"600")){
        case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
    root.startAssembly180({=>
        match(openProductAssembly180(config,Some(root))){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(value)=>value}})
    root.serve180()
    if(!root.closeAfterIdleServeHelper180()){return 1}
    // Close returned before endpoint removal; release only our exact lease.
    if(!brokerLeaseOwnedBy(paths,leaseToken,canonical)){return 1}
    let _=removeIfExists(paths.socketPath)
    let _=removeIfExists(paths.identityPath)
    releaseBrokerLease(paths,leaseToken)
    0
}

// The actual open descriptor is read incrementally. A FileInfo race cannot
// materialize an arbitrarily enlarged file before invoice/limit checks.
func readActualProcessBrokerFile180(path:String,limit:Int64,root:ActualProcessBrokerRoot180):String {
    let cell=root.registerActualInputBeforeConstruction180()
    try {
        let text=readActualProcessBrokerFileHelper180(path,limit,root,cell)
        // The whole decoder/read helper returned; escaping DATA is separately
        // Root-paid. Physical cursor and child share retirement are independent.
        if(!cell.retireAfterReturnedInputHelper180()){
            throw IllegalStateException("actual input close/payment remains retained")}
        text
    }catch(error:Exception){cell.retainOriginal180(error);throw error}
}
func brokerBorrowedLexicalNodesFromBytes180(bytes:ArrayList<Byte>):Int64{
    var quoted=false;var escaped=false;var scalar=false;var count:Int64=0
    for(index in 0..bytes.size){let byte=bytes[index]
        if(quoted){if(escaped){escaped=false}else if(byte==b'\\'){escaped=true}else if(byte==b'"'){quoted=false}}
        else if(byte==b'"'){quoted=true;scalar=false;count+=1}
        else if(byte==b'{' || byte==b'['){scalar=false;count+=1}
        else if(byte==b',' || byte==b':' || byte==b'}' || byte==b']' || byte==b' ' || byte==b'\n' || byte==b'\r' || byte==b'\t'){scalar=false}
        else if(!scalar){scalar=true;count+=1}}
    count
}


// The Root registers this cell before constructing/opening the actual input.
// Successful cells can be reused only after the whole input/close helpers
// returned and the exact private cursor/owner fields cleared. Failed cells
// retain both producer and close exceptions, and never count as retired.
class ActualProcessBrokerInput180 {
    private let lock = Mutex()
    private var paid: ?ActualProcessBrokerData180 = None<ActualProcessBrokerData180>
    private var cursor: ?OwnedProcessInputCursor180 = None<OwnedProcessInputCursor180>
    private var original: ?Exception = None<Exception>
    private var closeError: ?Exception = None<Exception>
    private var ending = false
    private let workingDirectory180: String
    init(workingDirectory180: String) { this.workingDirectory180 = workingDirectory180 }
    func isVacant180(): Bool { lock.lock(); try { paid.isNone() && cursor.isNone() && original.isNone() && closeError.isNone() && !ending } finally { lock.unlock() } }
    func reserveBeforeConstruction180(value: ActualProcessBrokerData180): Unit {
        lock.lock(); try {
            if (paid.isSome() || cursor.isSome() || original.isSome() || closeError.isSome() || ending) {
                throw IllegalStateException("actual input cell remains retained") }
            paid = Some(value)
        } finally { lock.unlock() }
    }
    private func currentData180(): ActualProcessBrokerData180 { lock.lock(); try { paid.getOrThrow() } finally { lock.unlock() } }
    private func borrowCursor180(): OwnedProcessInputCursor180 { lock.lock(); try { cursor.getOrThrow() } finally { lock.unlock() } }
    func fundTemporaryBeforeCopy180(bytes: Int64): Unit { currentData180().fundScalar(bytes) }
    func open180(path: String, directory!: Bool = false, maximum!: Int64 = 0): Unit {
        let data = currentData180()
        if (path.size > Int64.Max - workingDirectory180.size) { throw IllegalStateException("physical input path SUM overflow") }
        data.fundScalar(65536 + max(0, OwnedProcessInputCursor180.nativeContextBytes180()) +
            processInvoice180(path.size + workingDirectory180.size, 4, 4096))
        let authored = Path(path)
        // Keep every authored component for the unchanged native no-follow
        // traversal. Only the physical spelling changes; socket paths stay
        // compact and retain the original100-byte portable bound.
        let physical = if (authored.isAbsolute()) { path }
            else { Path(workingDirectory180).join(authored).toString() }

        lock.lock(); try {
            if (cursor.isSome()) { throw IllegalStateException("input cursor is already registered") }
            cursor = Some(OwnedProcessInputCursor180({ bytes => fundTemporaryBeforeCopy180(bytes) }))
        } finally { lock.unlock() }
        // Registration, not construction completion, precedes the native open.
        borrowCursor180().openRegistered180(physical, directory: directory, maximum: maximum)
    }
    func withNextName180(consume: (String) -> Unit): Bool {
        // Do not keep this cell lock across the callback: restoration may
        // register another input in the same Root registry. The lower cursor
        // holds its own actual borrowed dirent lock until consume returns.
        let value = borrowCursor180(); value.withNextName180(consume)
    }
    func read180(buffer: Array<Byte>): Int64 { let value = borrowCursor180(); value.readOwned180(buffer) }
    func retainOriginal180(error: Exception): Unit {
        lock.lock(); try {
            if (original.isNone()) { original = Some(error) }
            else if (!refEq(original.getOrThrow(), error) && closeError.isNone()) { closeError = Some(error) }
            else if (closeError.isSome() && !refEq(closeError.getOrThrow(), error) && !refEq(original.getOrThrow(), error)) {
                // There are exactly two fallible physical producer stages in
                // this cell (input and close). A third is a retained debt;
                // never silently overwrite either original producer error.
                throw IllegalStateException("actual input error cell has two retained producers") }
        } finally { lock.unlock() }
    }
    private func closeWholeInputHelper180(): Unit { let value = borrowCursor180(); value.closeAfterReturnedInputHelper180() }
    private func closeWholePaymentHelper180(): Unit { let value = currentData180(); value.retireAfterWholeHandler180() }
    func retireAfterReturnedInputHelper180(): Bool {
        lock.lock(); try { if (ending || original.isSome() || closeError.isSome()) { return false }; ending = true } finally { lock.unlock() }
        try {
            closeWholeInputHelper180()
            lock.lock(); try { cursor = None<OwnedProcessInputCursor180> } finally { lock.unlock() }
            closeWholePaymentHelper180()
            lock.lock(); try { paid = None<ActualProcessBrokerData180>; true } finally { lock.unlock() }
        } catch (error: Exception) { retainOriginal180(error); false }
        finally { lock.lock(); try { ending = false } finally { lock.unlock() } }
    }
}

func readActualProcessBrokerFileHelper180(path: String, limit: Int64, root: ActualProcessBrokerRoot180,
    cell: ActualProcessBrokerInput180): String {
    cell.open180(path, maximum: limit)
    cell.fundTemporaryBeforeCopy180(131072)
    let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = cell.read180(buffer)
        if (count <= 0) { break }
        if (count > limit || bytes.size > limit - count) { throw IllegalStateException("original process restore file exceeds its bound") }
        cell.fundTemporaryBeforeCopy180(processInvoice180(bytes.size + count, 16, 131072))
        for (index in 0..count) { bytes.add(buffer[index]) }
    }
    let nodes = brokerBorrowedLexicalNodesFromBytes180(bytes)
    if (nodes > (Int64.Max - 65536) / 512 || bytes.size > (Int64.Max - 65536 - nodes * 512) / 12) {
        throw IllegalStateException("actual restored DATA extent overflow") }
    // The String/decoded state may escape this transient read helper. The
    // original Root, not the temporary input share, pays those exact aliases
    // before their Array/String/DOM construction. Root lifetime stays held.
    root.retainRootData180(bytes.size * 12 + nodes * 512 + 65536)
    String.fromUtf8(bytes.toArray())
}

// Private actual rendered-set receipt. It cannot ACK any source not admitted
// to this exact frame, and cannot make a pending/running producer quiet.
class ActualProcessBrokerFailureFrame180 {
    private let data:ActualProcessBrokerData180
    private var sources:?ArrayList<OwnedFailureDataConsumer113>=Some(ArrayList<OwnedFailureDataConsumer113>())
    private var encoded:?ArrayList<String>=Some(ArrayList<String>())
    private var pendingSource:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>
    private var pendingText:?String=None<String>
    private var output:?String=None<String>
    private var offered=false
    private var written=false
    private var retired=false
    init(data:ActualProcessBrokerData180){this.data=data}
    private func encodeConsumerWholeHelper180(source:OwnedFailureDataConsumer113):Bool{
        pendingSource=Some(source)
        data.fund(4096,8)
        sources.getOrThrow().add(source);pendingSource=None<OwnedFailureDataConsumer113>
        let loan=source.withError({error,fund=>
            let value=match(encodeOwnedFailureError113(error,{bytes=>
                // The immutable encoded copy remains in Root until whole
                // output return. Both actual owners are independently paid.
                data.fund(bytes,4);fund(bytes)})){
                case Result.Err(failure)=>throw OwnedCanonicalDataFailure113(failure)
                case Result.Ok(value)=>value}
            pendingText=Some(value)
            data.fund(4096,4);encoded.getOrThrow().add(value);pendingText=None<String>})
        loan.isOk()
    }
    func prepareProducerWholeHelper180(cell:HostHubProcessProducerCell,count:Int64,id:String):Bool{
        if(!cell.admitOriginalFailure180({source=>encodeConsumerWholeHelper180(source)})){return false}
        for(index in 0..count){
            if(!cell.admitSecondaryFailure180(index,{source=>encodeConsumerWholeHelper180(source)})){return false}}
        if(cell.hasUnregisteredSecondary180() || cell.secondaryFailureCount180()!=count ||
            sources.getOrThrow().size!=count+1 || encoded.getOrThrow().size!=count+1){return false}
        var bytes:Int64=65536+id.size*8
        for(value in encoded.getOrThrow()){
            if(value.size>Int64.Max-bytes-2){throw IllegalStateException("complete Root error frame invoice overflow")}
            bytes+=value.size+2}
        if(bytes>(Int64.Max-65536)/4){throw IllegalStateException("complete Root error frame invoice overflow")}
        data.fund(bytes*4,count+32)
        let prefix=encodeAgentValue(objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId",textValue(id)),ValueField("ok",boolValue(false))]))
        let text=StringBuilder()
        text.append(prefix[..prefix.size-1]);text.append(",\"error\":")
        text.append(encoded.getOrThrow()[0]);text.append(",\"secondary_errors\":[")
        for(index in 1..encoded.getOrThrow().size){if(index>1){text.append(",")};text.append(encoded.getOrThrow()[index])}
        text.append("]}")
        let answer=text.toString()
        if(answer.size>PROCESS_BROKER_MAX_RESPONSE_BYTES){throw IllegalStateException("complete Root error set exceeds original frame limit")}
        output=Some(answer);true
    }
    func writeWholeFrameHelper180(client:UnixSocket):Bool{
        if(offered || output.isNone()){return false}
        offered=true
        let text=output.getOrThrow()
        data.fund(text.size*2+2,4)
        client.write((text+"\n").toArray())
        written=true;true
    }
    private func acknowledgeRenderedSetWholeHelper180():Bool{
        for(source in sources.getOrThrow()){
            match(source.acknowledgeAfterConsumption()){case Result.Err(_)=>return false;case Result.Ok(_)=>()}}
        true
    }
    func retireWrittenSources180():Bool{
        if(retired){return true}
        if(!written || pendingSource.isSome() || pendingText.isSome()){return false}
        // No encoded String, builder, writer frame or borrowed error survives
        // this point. ACK exceptions preserve the original registered sources.
        output=None<String>;encoded=None<ArrayList<String>>
        if(!acknowledgeRenderedSetWholeHelper180()){return false}
        sources=None<ArrayList<OwnedFailureDataConsumer113>>;retired=true;true
    }
    func sourcesRetired180():Bool{retired && sources.isNone() && output.isNone() && encoded.isNone() &&
        pendingSource.isNone() && pendingText.isNone()}
}

// Installed on the real client Root before any allocation, socket connect or
// observer frame. The Bool is not consumption/cleanup acknowledgement: only
// physical return of the original pinned worker completes the idle rendezvous.
class ActualOwnerFrontendRendezvous180 {
    private let data:ActualProcessBrokerData180
    private let config:ProductConfig
    private let path:String
    private let workspace:String
    private let token:String
    private let pid:Int64
    private let start:String
    private let retiringId:String
    private let deadline180=MonoTime.now()+Duration.second*5
    private var socket:?UnixSocket=None<UnixSocket>
    private var peer:?ActualProductOwnerPeer180=None<ActualProductOwnerPeer180>
    private var rawPaid:?ProcessBrokerOwner180=None<ProcessBrokerOwner180>
    private var packet:?AgentValue=None<AgentValue>
    private var response:?AgentValue=None<AgentValue>
    private var source:?String=None<String>
    init(data:ActualProcessBrokerData180,config:ProductConfig,path:String,workspace:String,token:String,pid:Int64,start:String,retiringId:String){
        this.data=data;this.config=config;this.path=path;this.workspace=workspace;this.token=token;this.pid=pid;this.start=start
        this.retiringId=retiringId
    }
    private func physicalOwnerReturned180():Bool{
        if(pid<=0 || start==""){throw IllegalStateException("actual frontend owner identity is unavailable")}
        let proc="/proc/"+pid.toString()
        if(!exists(Path(proc))){return true}
        match(linuxProcessStatTail(proc+"/stat")){
            case Some(fields)=>fields[19]!=start || fields[0]=="Z" || fields[0]=="X" || fields[0]=="x"
            case None=>false // Unreadable live identity is unknown, never return.
        }
    }
    func observeWholeHelper180():Bool{
        data.fund(131072+path.size*4+workspace.size*4+token.size*4+start.size*4+retiringId.size*4,128)
        if(physicalOwnerReturned180()){return false}
        socket=Some(UnixSocket(path))
        let now=MonoTime.now()
        if(now>=deadline180){throw IllegalStateException("actual frontend owner observation exceeded its deadline")}
        try{socket.getOrThrow().connect(timeout:Some(deadline180-now))}
        catch(error:SocketException){
            // The listener can close before the same pinned process returns.
            // Join that actual process; never retry I/O or infer DATA ACK.
            if(awaitOriginalPhysicalReturn180()){return false};throw error
        }
        peer=Some(ActualProductOwnerPeer180(socket.getOrThrow(),data,config,
            PROCESS_BROKER_MAX_RESPONSE_BYTES,PROCESS_BROKER_MAX_REQUEST_BYTES))
        peer.getOrThrow().initializePhysicalPeer180()
        let id=brokerRequestId()
        packet=Some(objectValue([ValueField("version",integerValue(PROCESS_BROKER_PROTOCOL)),
            ValueField("requestId",textValue(id)),ValueField("token",textValue(token)),
            ValueField("workspace",textValue(workspace)),ValueField("kind",textValue("frontend-lifetime180")),
            ValueField("ownerPid",integerValue(pid)),ValueField("ownerStart",textValue(start)),
            ValueField("retiringFrontendRequestId",textValue(retiringId))]))
        data.fundValue(packet.getOrThrow())
        match(peer.getOrThrow().writeOwnerFrame180(encodeAgentValue(packet.getOrThrow()),Some(deadline180))){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
        rawPaid=Some(data.derive(65536))
        source=Some(match(peer.getOrThrow().readOwnerFrame180(rawPaid.getOrThrow(),Some(deadline180))){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(value)=>value})
        let text=source.getOrThrow()
        let nodes=brokerBorrowedLexicalNodes180(text)
        data.fund(65536+text.size*48+nodes*1024,64+nodes)
        response=Some(match(decodeAgentValue(text,maxBytes:PROCESS_BROKER_MAX_RESPONSE_BYTES)){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(value)=>value})
        if(brokerText(response.getOrThrow(),"requestId")!=id){throw IllegalStateException("frontend lifetime response identity mismatch")}
        match(response.getOrThrow().field("otherDebt")){
            case Some(value)=>if(value.unifiedKind==ValueKind.Boolean){value.asBool()}
                else{throw IllegalStateException("frontend lifetime response is not a scalar Bool")}
            case None=>throw IllegalStateException("frontend lifetime response is missing")
        }
    }
    func closeAfterWholeObservation180():Unit{
        match(peer){case Some(actual)=>
            match(actual.closeOwnerPeer180()){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
            match(actual.retireAfterOriginalEnclosingHelpers180()){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
            case None=>match(socket){case Some(actual)=>actual.close();case None=>()}}
        peer=None<ActualProductOwnerPeer180>;socket=None<UnixSocket>;source=None<String>
        packet=None<AgentValue>;response=None<AgentValue>
        match(rawPaid){case Some(value)=>value.close();case None=>()};rawPaid=None<ProcessBrokerOwner180>
    }
    private func awaitOriginalPhysicalReturn180():Bool{
        while(!physicalOwnerReturned180()){
            if(MonoTime.now()>=deadline180){return false}
            sleep(Duration.millisecond*10)
        }
        true
    }
    func waitForOriginalPhysicalReturn180():Unit{
        if(!awaitOriginalPhysicalReturn180()){
            throw IllegalStateException("actual idle owner worker has not physically returned")}
    }
}
