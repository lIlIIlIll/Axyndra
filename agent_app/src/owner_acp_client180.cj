package agent_app

import agent_domain.*
import agent_product.*
import agent_rpc.*
import agent_runtime.*
import agent_tui.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*
import yjson_support.*
import yjson.*

private class OwnerAcpPermissionPeer180 {
    let id: Int64
    let channel: OwnerAcpClientPeer180
    init(id: Int64, channel: OwnerAcpClientPeer180) { this.id = id; this.channel = channel }
}

// DATA references only. Every actual Product/Source/Run remains in its chosen
// workspace daemon. The original peer and native reader are never fabricated.
private class OwnerAcpClientPeer180 {
    var workspace: String
    private let connectionLock = Mutex()
    private var connection: ?ProductOwnerPeer180 = None<ProductOwnerPeer180>
    private var payment: ?LogicalJsonOwnerReservation
    var reader: ?Future<Result<Int64>> = None<Future<Result<Int64>>>
    var closeWorker: ?Future<Result<Unit>> = None<Future<Result<Unit>>>
    var closePayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    var raw: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    var codec: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    var thrown: ?Exception = None<Exception>
    var readerError180: ?AgentError = None<AgentError>
    var closeError180: ?AgentError = None<AgentError>
    var rawData180: ?String = None<String>
    var decodedData180: ?AgentValue = None<AgentValue>
    var holdingOutput = false
    private let creditLock = Mutex()
    private var credit = true
    private let lookupLock = Mutex()
    private let resultLock = Mutex()
    private var lookupSequence: Int64 = 0
    private var lookupReturned: Int64 = 0
    private var lookupPending: Int64 = 0
    private var lookupWorkspace = ""
    private var lookupPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    init(workspace: String, payment: LogicalJsonOwnerReservation) {
        this.workspace = workspace; this.payment = Some(payment)
    }
    func installPeer180(peer: ProductOwnerPeer180): Unit {
        connectionLock.lock()
        try {
            if (connection.isSome()) { throw IllegalStateException("ACP peer already installed") }
            connection = Some(peer)
        } finally { connectionLock.unlock() }
    }
    func clearPeerAfterReader180(): Unit {
        connectionLock.lock()
        try { connection = None<ProductOwnerPeer180> } finally { connectionLock.unlock() }
    }
    func peer180(): ProductOwnerPeer180 { connection.getOrThrow() }
    private func write180(frame: String): Result<Unit> {
        connectionLock.lock()
        try { match (connection) {
            case Some(peer) => peer.writeOwnerFrame180(frame, None)
            case None => Result.Err(AgentError(AgentErrorKind.Transport,
                "owner.acp_peer_ended", "ACP workspace peer is not connected")) }
        } finally { connectionLock.unlock() }
    }
    func takeMetadataAfterReaderReturn180(): LogicalJsonOwnerReservation {
        if (reader.isSome() || closeWorker.isSome() || thrown.isSome() || readerError180.isSome() || closeError180.isSome()) {
            throw IllegalStateException("original ACP reader/close helper is still active") }
        workspace = ""; lookupWorkspace = ""; clearPeerAfterReader180(); thrown = None<Exception>
        retireLookupAfterDispatchHelper180(); retireFrameAfterReadHelper180()
        let actual = payment.getOrThrow(); payment = None<LogicalJsonOwnerReservation>; actual
    }
    func grantCredit180(): Unit {
        creditLock.lock()
        try {
            if (credit) { throw IllegalStateException("duplicate ACP ingress credit") }
            credit = true
        } finally { creditLock.unlock() }
    }
    func send180(line: String, stopped: AtomicBool): Result<Unit> {
        while (!stopped.load()) {
            connectionLock.lock()
            let connected = try { connection.isSome() } finally { connectionLock.unlock() }
            if (connected) {
                creditLock.lock()
                let available = try { if (credit) { credit = false; true } else { false } }
                    finally { creditLock.unlock() }
                if (available) {
                    connectionLock.lock()
                    try { match (connection) {
                        case Some(peer) => return sendOwnerFrontendInput180(peer, line)
                        case None => () }
                    } finally { connectionLock.unlock() }
                }
            }
            match (reader) {
                case Some(worker) => if (worker.tryGet().isSome()) {
                    return Result.Err(AgentError(AgentErrorKind.Transport,
                        "owner.acp_peer_ended", "ACP workspace frontend ended before accepting input")) }
                case None => () }
            sleep(Duration.millisecond * 10)
        }
        Result.Err(AgentError(AgentErrorKind.Cancelled, "owner.acp_input_cancelled", "ACP frontend is closing"))
    }
    func awaitHandlerReturn180(stopped: AtomicBool): Result<Unit> {
        while (!stopped.load()) {
            creditLock.lock()
            let returned = try { credit } finally { creditLock.unlock() }
            if (returned) { return Result.Ok(()) }
            if (reader.getOrThrow().tryGet().isSome()) { break }
            sleep(Duration.millisecond * 10)
        }
        Result.Err(AgentError(AgentErrorKind.Transport,
            "owner.acp_initialize_failed", "original ACP initialize handler did not return"))
    }
    func acceptWorkspace180(value: AgentValue): Unit {
        let sequence = Int64.parse(value.field("sequence").getOrThrow().asNumberText())
        let text = ownerFrontendText180(value, "workspace")
        resultLock.lock()
        try {
            if (sequence != lookupSequence || sequence <= lookupReturned || lookupPayment.isSome()) {
                throw IllegalStateException("ACP workspace lookup reply is not pending") }
            lookupPayment = Some(peer180().deriveOwnerFrameData180(65536 + text.size * 8))
            lookupWorkspace = String.fromUtf8(text.toArray()); lookupPending = sequence
        } finally { resultLock.unlock() }
    }
    func publishLookupAfterReadHelper180(): Unit {
        resultLock.lock()
        try { if (lookupPending > lookupReturned) { lookupReturned = lookupPending } }
        finally { resultLock.unlock() }
    }
    func retireLookupAfterDispatchHelper180(): Unit {
        resultLock.lock()
        try {
            lookupWorkspace = ""
            let paid = lookupPayment; lookupPayment = None<LogicalJsonOwnerReservation>
            match (paid) { case Some(value) => value.close(); case None => () }
        } finally { resultLock.unlock() }
    }
    func sessionWorkspace180(id: String, stopped: AtomicBool): Result<String> {
        lookupLock.lock()
        try {
            resultLock.lock()
            let sequence = try { lookupSequence++; lookupSequence } finally { resultLock.unlock() }
            match (write180(encodeAgentValue(objectValue([
                ValueField("kind", textValue("acp_session_workspace")),
                ValueField("sequence", integerValue(sequence)), ValueField("sessionId", textValue(id))])))) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => () }
            let until = MonoTime.now() + Duration.millisecond * 5000
            while (!stopped.load()) {
                resultLock.lock()
                try { if (lookupReturned == sequence) { return Result.Ok(lookupWorkspace) } }
                finally { resultLock.unlock() }
                if (MonoTime.now() >= until || reader.getOrThrow().tryGet().isSome()) { break }
                sleep(Duration.millisecond * 10)
            }
            Result.Err(AgentError(AgentErrorKind.Transport, "owner.acp_workspace_lookup_failed",
                "actual Owner did not return the ACP session workspace"))
        } finally { lookupLock.unlock() }
    }
    func beginClose180(): Result<Unit> {
        write180(encodeAgentValue(objectValue([ValueField("kind", textValue("eof"))])))
    }
    func closePhysicalPeer180(): Unit {
        connectionLock.lock()
        try { match (connection) { case Some(peer) => let _ = peer.closeOwnerPeer180(); case None => () } }
        finally { connectionLock.unlock() }
    }
    func retireFrameAfterReadHelper180(): Unit {
        let decoded = codec; codec = None<LogicalJsonOwnerReservation>
        let physical = raw; raw = None<LogicalJsonOwnerReservation>
        decodedData180 = None<AgentValue>; rawData180 = None<String>
        match (decoded) { case Some(paid) => paid.close(); case None => () }
        match (physical) { case Some(paid) => paid.close(); case None => () }
    }
}

// Root B's concrete consumer lives inside Main's original private enclosing
// helper for this entire stream. The coordinator owns the real outer Future.
private class OwnerAcpWorkspaceFrontend180 <: ProductOwnerClientFrontend180 {
    private var coordinator: ?OwnerAcpClient180
    private var channel: ?OwnerAcpClientPeer180
    private var peer: ?ProductOwnerPeer180
    init(coordinator: OwnerAcpClient180, channel: OwnerAcpClientPeer180, peer: ProductOwnerPeer180) {
        this.coordinator = Some(coordinator); this.channel = Some(channel); this.peer = Some(peer)
    }
    public func runOwnerClientFrontend180(): Int64 {
        let actual = channel.getOrThrow(); let connection = peer.getOrThrow()
        actual.installPeer180(connection)
        match (coordinator.getOrThrow().readPeer180(actual, connection)) {
            case Result.Ok(status) => status
            case Result.Err(_) => 1 }
    }
    public func closeOwnerClientFrontend180(): Result<Unit> {
        channel.getOrThrow().clearPeerAfterReader180()
        peer = None<ProductOwnerPeer180>; channel = None<OwnerAcpClientPeer180>
        coordinator = None<OwnerAcpClient180>
        Result.Ok(())
    }
}

private class OwnerAcpClient180 {
    private var config: ?ProductConfig
    private var original: ?AgentValue
    private var allocate: ?((Int64) -> LogicalJsonOwnerReservation)
    private var metadata: ?LogicalJsonOwnerReservation
    private let lock = Mutex()
    private let physicalWriter = Mutex()
    private var routingOutput: ?AcpOwnerRoutingOutput180
    private var channels: ?ArrayList<OwnerAcpClientPeer180> = Some(ArrayList<OwnerAcpClientPeer180>())
    private var permissions: ?ArrayList<OwnerAcpPermissionPeer180> = Some(ArrayList<OwnerAcpPermissionPeer180>())
    private var nextPermissionId: Int64 = 0
    private var initialized = false
    private var closeUntil: ?MonoTime = None<MonoTime>
    let stopped = AtomicBool(false)
    init(config: ProductConfig, original: AgentValue,
        allocate: (Int64) -> LogicalJsonOwnerReservation, metadata: LogicalJsonOwnerReservation,
        routingOutput: AcpOwnerRoutingOutput180) {
        this.config = Some(config); this.original = Some(original); this.allocate = Some(allocate)
        this.metadata = Some(metadata); this.routingOutput = Some(routingOutput)
    }
    private func request180(): AgentValue {
        let source = original.getOrThrow()
        objectValue([
            ValueField("frontend", textValue("acp")), ValueField("command", textValue("acp")),
            ValueField("arguments", source.field("arguments").getOrThrow()),
            ValueField("options", source.field("options").getOrThrow()),
            ValueField("acp_initialized", boolValue(initialized)), ValueField("acp_id_allocator", boolValue(true))])
    }
    func installInitial180(peer: ProductOwnerPeer180): Unit {
        let workspace = canonicalize(Path(config.getOrThrow().workspaceRoot)).toString()
        let channel = OwnerAcpClientPeer180(workspace, allocate.getOrThrow()(65536 + workspace.size * 16))
        channels.getOrThrow().add(channel); channel.installPeer180(peer)
        channel.reader = Some(spawn { readPeer180(channel, peer) })
    }
    private func channel180(workspace: String): Result<OwnerAcpClientPeer180> {
        for (channel in channels.getOrThrow()) { if (channel.workspace == workspace) { return Result.Ok(channel) } }
        metadata.getOrThrow().ensureRetainedPeak(65536 + (channels.getOrThrow().size + permissions.getOrThrow().size + 1) * 8192)
        let allocator = allocate.getOrThrow()
        let channel = OwnerAcpClientPeer180(workspace, allocator(65536 + workspace.size * 16))
        lock.lock(); try { channels.getOrThrow().add(channel) } finally { lock.unlock() }
        let request = request180(); let configuration = acpSessionProductConfig(config.getOrThrow(), workspace)
        channel.reader = Some(spawn {
            Result<Int64>.Ok(runProductOwnerClientFrontend180(configuration, request,
                { peer => OwnerAcpWorkspaceFrontend180(this, channel, peer) }, allocate: allocator)) })
        Result.Ok(channel)
    }
    private func allocatePermission180(channel: OwnerAcpClientPeer180, value: AgentValue): Result<Unit> {
        lock.lock()
        let id = try {
            metadata.getOrThrow().ensureRetainedPeak(65536 + (channels.getOrThrow().size + permissions.getOrThrow().size + 1) * 8192)
            nextPermissionId++
            permissions.getOrThrow().add(OwnerAcpPermissionPeer180(nextPermissionId, channel))
            nextPermissionId
        } finally { lock.unlock() }
        channel.peer180().writeOwnerFrame180(encodeAgentValue(objectValue([
            ValueField("kind", textValue("acp_request_id_returned")),
            ValueField("sequence", value.field("sequence").getOrThrow()), ValueField("id", integerValue(id))])), None)
    }
    private func permissionChannel180(value: AgentValue): ?OwnerAcpClientPeer180 {
        let id = match (value.field("id")) {
            case Some(actual) => if (actual.unifiedKind == ValueKind.Number) {
                try { Int64.parse(actual.asNumberText()) } catch (_: Exception) { return None<OwnerAcpClientPeer180> }
            } else { return None<OwnerAcpClientPeer180> }
            case None => return None<OwnerAcpClientPeer180>
        }
        lock.lock()
        try { for (entry in permissions.getOrThrow()) { if (entry.id == id) { return Some(entry.channel) } }; None<OwnerAcpClientPeer180> }
        finally { lock.unlock() }
    }
    private func retirePermission180(value: AgentValue): Unit {
        let id = Int64.parse(value.field("id").getOrThrow().asNumberText())
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < permissions.getOrThrow().size) {
                if (permissions.getOrThrow()[index].id == id) { permissions.getOrThrow().remove(at: index); return }
                index++
            }
        } finally { lock.unlock() }
    }
    func dispatch180(line: String): Result<Unit> {
        let result = dispatchOriginal180(line)
        match (result) {
            case Result.Ok(_) => result
            case Result.Err(error) =>
                let value = match (decodeAgentValue(line)) {
                    case Result.Err(_) => return result
                    case Result.Ok(actual) => actual
                }
                let id = match (value.field("id")) { case None => return Result.Ok(()); case Some(actual) => actual }
                physicalWriter.lock()
                let written = try { routingOutput.getOrThrow().write180(id, error, RpcOutput()) }
                    finally { physicalWriter.unlock() }
                if (written) { Result.Ok(()) } else { result }
        }
    }
    private func dispatchOriginal180(line: String): Result<Unit> {
        let value = match (decodeAgentValue(line)) {
            case Result.Err(_) => return channels.getOrThrow()[0].send180(line, stopped)
            case Result.Ok(actual) => actual
        }
        let method = ownerFrontendText180(value, "method")
        if (method == "") {
            match (permissionChannel180(value)) {
                case Some(channel) =>
                    let result = channel.send180(line, stopped)
                    if (result.isOk()) { retirePermission180(value) }
                    return result
                case None => return channels.getOrThrow()[0].send180(line, stopped)
            }
        }
        var workspace = ""
        if (method == "session/new" || method == "session/load" || method == "session/resume" ||
            method == "session/list" || method == "session/fork" || method == "session/close" ||
            method == "session/set_mode" || method == "session/set_config_option" ||
            method == "session/prompt" || method == "session/cancel") {
            let params = value.field("params") ?? objectValue([])
            let sessionId = ownerFrontendText180(params, "sessionId")
            if (sessionId != "") {
                workspace = match (channels.getOrThrow()[0].sessionWorkspace180(sessionId, stopped)) {
                    case Result.Ok(path) => path
                    case Result.Err(error) => return Result.Err(error)
                }
            } else { workspace = ownerFrontendText180(params, "cwd") }
        }
        let channel = if (workspace == "" || !initialized) { channels.getOrThrow()[0] } else {
            match (canonicalAcpCwd(workspace)) {
                // Keep the actual original method and its original structured
                // validation error, rather than substitute a routing error.
                case Result.Err(_) => channels.getOrThrow()[0]
                case Result.Ok(path) => match (channel180(path)) {
                    case Result.Ok(actual) => actual
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        }
        let result = channel.send180(line, stopped)
        if (result.isOk() && method == "initialize") {
            let returned = channel.awaitHandlerReturn180(stopped)
            if (returned.isError()) { return returned }
            initialized = true
        }
        result
    }
    func readPeer180(channel: OwnerAcpClientPeer180, connection: ProductOwnerPeer180): Result<Int64> {
        try {
            while (true) {
                channel.raw = Some(connection.deriveOwnerFrameData180(65536))
                channel.codec = Some(connection.deriveOwnerFrameData180(65536))
                let answer = readOneFrameHelper180(channel, connection,
                    channel.raw.getOrThrow(), channel.codec.getOrThrow())
                match (answer) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                channel.publishLookupAfterReadHelper180()
                channel.retireFrameAfterReadHelper180()
                match (answer) {
                    case Result.Ok(Some(status)) => return Result.Ok(status)
                    case Result.Ok(None) => ()
                    case Result.Err(error) => return Result.Err(error) }
            }
            Result.Ok(0)
        } catch (error: OwnedCanonicalDataFailure113) { channel.thrown = Some(error); Result.Err(error.error) }
        catch (error: Exception) {
            channel.thrown = Some(error)
            Result.Err(AgentError(AgentErrorKind.Transport, "owner.acp_peer_failed", error.message))
        } finally {
            if (channel.holdingOutput) { physicalWriter.unlock(); channel.holdingOutput = false }
        }
    }
    private func readOneFrameHelper180(channel: OwnerAcpClientPeer180, connection: ProductOwnerPeer180,
        raw: LogicalJsonOwnerReservation, codec: LogicalJsonOwnerReservation): Result<?Int64> {
        let frame = match (connection.readOwnerFrame180(raw, None)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(actual) => actual }
        codec.ensureRetainedPeak(ownerFrontendDecodeInvoice180(frame))
        channel.rawData180 = Some(frame)
        readFrameHelper180(channel, frame)
    }
    private func readFrameHelper180(channel: OwnerAcpClientPeer180, frame: String): Result<?Int64> {
        let value = match (decodeAgentValue(frame)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(actual) => actual
        }
        channel.decodedData180 = Some(value)
        match (ownerFrontendText180(value, "kind")) {
            case "input_credit" => channel.grantCredit180(); Result.Ok(None<Int64>)
            case "acp_request_id" => match (allocatePermission180(channel, value)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => Result.Ok(None<Int64>) }
            case "acp_session_workspace_result" => channel.acceptWorkspace180(value); Result.Ok(None<Int64>)
            case "output" | "error_output" =>
                if (!channel.holdingOutput) { physicalWriter.lock(); channel.holdingOutput = true }
                let status = writeOwnerFrontendOutput180(channel.peer180(), value)
                if (ownerFrontendBoolean180(value, "final")) { physicalWriter.unlock(); channel.holdingOutput = false }
                match (status) {
                    case None => Result.Ok(None<Int64>)
                    case Some(_) => Result.Err(AgentError(AgentErrorKind.Transport,
                        "owner.acp_output_failed", "original ACP physical output helper failed")) }
            case "exit" => Result.Ok(Some(Int64.parse(value.field("status").getOrThrow().asNumberText())))
            case _ => Result.Err(AgentError(AgentErrorKind.Protocol,
                "owner.acp_frame_invalid", "unexpected ACP workspace Owner frame"))
        }
    }
    func hasReturnedReader180(): Bool {
        for (channel in channels.getOrThrow()) {
            match (channel.reader) { case Some(worker) => if (worker.tryGet().isSome()) { return true }; case None => () } }
        false
    }
    func retireRoutingCopiesAfterInputHelper180(): Unit {
        for (channel in channels.getOrThrow()) { channel.retireLookupAfterDispatchHelper180() }
    }
    private func joinReaderHelper180(channel: OwnerAcpClientPeer180): Int64 {
        match (channel.reader.getOrThrow().get()) {
            case Result.Ok(status) => status
            case Result.Err(error) => channel.readerError180 = Some(error); consoleCliIo180.eprintln(error.describe()); 1 }
    }
    private func joinCloseHelper180(channel: OwnerAcpClientPeer180): Bool {
        match (channel.closeWorker.getOrThrow().get()) {
            case Result.Ok(_) => true
            case Result.Err(error) => channel.closeError180 = Some(error); consoleCliIo180.eprintln(error.describe()); false }
    }
    func closeAfterInputHelperReturn180(): Int64 {
        if (!stopped.load()) {
            stopped.store(true); closeUntil = Some(MonoTime.now() + Duration.millisecond * 5000)
            for (channel in channels.getOrThrow()) {
                channel.closePayment = Some(allocate.getOrThrow()(65536))
                channel.closeWorker = Some(spawn { channel.beginClose180() }) }
        }
        let until = closeUntil.getOrThrow()
        var status: Int64 = 0
        for (channel in channels.getOrThrow()) {
            match (channel.reader) {
                case Some(reader) =>
                    while (reader.tryGet().isNone() && MonoTime.now() < until) { sleep(Duration.millisecond * 10) }
                    if (reader.tryGet().isNone()) { channel.closePhysicalPeer180() }
                    if (reader.tryGet().isSome()) {
                        if (joinReaderHelper180(channel) != 0) { status = 1 }
                        if (channel.readerError180.isNone() && channel.thrown.isNone()) { channel.reader = None<Future<Result<Int64>>> }
                    } else { status = 1 }
                case None => () }
            match (channel.closeWorker) {
                case Some(worker) =>
                    while (worker.tryGet().isNone() && MonoTime.now() < until) { sleep(Duration.millisecond * 10) }
                    if (worker.tryGet().isSome()) {
                        let returned = joinCloseHelper180(channel)
                        if (returned) { channel.closeWorker = None<Future<Result<Unit>>> } else { status = 1 }
                    } else { status = 1 }
                case None => () }
            if (channel.closeWorker.isNone() && channel.closeError180.isNone()) {
                let paid = channel.closePayment; channel.closePayment = None<LogicalJsonOwnerReservation>
                match (paid) { case Some(value) => value.close(); case None => () }
            }
        }
        status
    }
    func retireAfterCloseHelperReturn180(): Bool {
        for (channel in channels.getOrThrow()) {
            if (channel.reader.isSome() || channel.closeWorker.isSome() || channel.thrown.isSome() ||
                channel.readerError180.isSome() || channel.closeError180.isSome()) { return false }
        }
        if (!routingOutput.getOrThrow().retireAfterFrontendHelpersReturn180()) { return false }
        routingOutput = None<AcpOwnerRoutingOutput180>
        permissions = None<ArrayList<OwnerAcpPermissionPeer180>>
        for (channel in channels.getOrThrow()) { channel.takeMetadataAfterReaderReturn180().close() }
        channels = None<ArrayList<OwnerAcpClientPeer180>>
        original = None<AgentValue>; config = None<ProductConfig>; allocate = None<(Int64) -> LogicalJsonOwnerReservation>
        closeUntil = None<MonoTime>
        let paid = metadata; metadata = None<LogicalJsonOwnerReservation>
        match (paid) { case Some(value) => value.close(); case None => () }
        true
    }
}

private class OwnerAcpCoordinatorFrontend180 <: ProductOwnerClientFrontend180 {
    private var peer: ?ProductOwnerPeer180
    private var request: ?AgentValue
    private var allocator: ?((Int64) -> LogicalJsonOwnerReservation)
    private var coordinator: ?OwnerAcpClient180 = None<OwnerAcpClient180>
    private var control: ?AcpOwnedWorkerControl113 = None<AcpOwnedWorkerControl113>
    private var input: ?AcpOwnedJsonlInput113 = None<AcpOwnedJsonlInput113>
    init(peer: ProductOwnerPeer180, request: AgentValue,
        allocate: (Int64) -> LogicalJsonOwnerReservation) {
        this.peer = Some(peer); this.request = Some(request); this.allocator = Some(allocate)
    }
    public func runOwnerClientFrontend180(): Int64 {
        let actual = peer.getOrThrow(); let allocate = allocator.getOrThrow()
        let lifetime = newAcpOwnedWorkerControl113(allocate(65536)); control = Some(lifetime)
        let routing = AcpOwnerRoutingOutput180(lifetime)
        let owner = OwnerAcpClient180(actual.ownerConfiguration180(), request.getOrThrow(),
            allocate, allocate(65536), routing); coordinator = Some(owner)
        owner.installInitial180(actual)
        tuiStartupStage("configuration_loading_completed")
        let source = AcpOwnedJsonlInput113(lifetime, lifetime.prepareFrontendCustody113())
        input = Some(source); lifetime.installFrontendCustody113(source)
        let status = runOwnerAcpInputHelper180(owner, source)
        if (owner.closeAfterInputHelperReturn180() != 0) { return 1 }
        status
    }
    public func closeOwnerClientFrontend180(): Result<Unit> {
        match (coordinator) {
            case Some(owner) => let _ = owner.closeAfterInputHelperReturn180()
                if (!owner.retireAfterCloseHelperReturn180()) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.acp_frontend_retirement_pending", "actual ACP peer helpers remain owned")) }
            case None => () }
        coordinator = None<OwnerAcpClient180>
        match (input) {
            case Some(source) => if (!source.destroyInputAfterFailedFrontendReturn113()) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "owner.acp_input_retirement_pending", "actual ACP input helper remains owned")) }
            case None => () }
        input = None<AcpOwnedJsonlInput113>
        match (control) {
            case Some(lifetime) =>
                if (!lifetime.collectFrontendAfterHelperReturn113()) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.acp_input_retirement_pending", "actual ACP input custody remains owned")) }
                match (lifetime.takeOwnerFrontendPaymentAfterScopeReturn180()) {
                    case Some(paid) => paid.close()
                    case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.acp_control_retirement_pending", "actual ACP controller remains owned")) }
            case None => () }
        control = None<AcpOwnedWorkerControl113>; peer = None<ProductOwnerPeer180>
        request = None<AgentValue>; allocator = None<(Int64) -> LogicalJsonOwnerReservation>
        Result.Ok(())
    }
}
func runOwnerAcpClient180(config: ProductConfig, request: AgentValue,
    frontendRoot: LogicalJsonOwnerReservation): Int64 {
    let allocate = { bytes: Int64 =>
        let payment = frontendRoot.deriveRetainedLease()
        try { payment.ensureRetainedPeak(bytes); payment }
        catch (error: Exception) { payment.close(); throw error } }
    let initial = objectValue([
        ValueField("frontend", textValue("acp")), ValueField("command", textValue("acp")),
        ValueField("arguments", request.field("arguments").getOrThrow()),
        ValueField("options", request.field("options").getOrThrow()),
        ValueField("acp_initialized", boolValue(false)), ValueField("acp_id_allocator", boolValue(true))])
    runProductOwnerClientFrontend180(config, initial,
        { peer => OwnerAcpCoordinatorFrontend180(peer, initial, allocate) }, allocate: allocate)
}
private func runOwnerAcpInputHelper180(coordinator: OwnerAcpClient180, input: AcpOwnedJsonlInput113): Int64 {
    while (!coordinator.hasReturnedReader180()) {
        let (eof, line) = input.poll113(50)
        if (eof) { return 0 }
        match (line) {
            case None => ()
            case Some(actual) =>
                let result = actual.withLine113({ text, _ =>
                    if (!actual.prepareParser113()) { return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.acp_parser_payment_pending", "original ACP parser custody is unavailable")) }
                    coordinator.dispatch180(text)
                })
                coordinator.retireRoutingCopiesAfterInputHelper180()
                match (result) { case Result.Err(error) => consoleCliIo180.eprintln(error.describe()); return 1; case Result.Ok(_) => () }
                if (!input.retireHandledInputAfterHelperReturn113()) { return 1 }
        }
    }
    1
}
