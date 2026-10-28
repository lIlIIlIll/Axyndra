package agent_app

import agent_domain.*
import agent_product.*
import agent_rpc.*
import agent_runtime.*
import std.time.*
import yjson_support.*
import yjson.*

class AppProductOwnerFrontend180 <: ProductOwnerFrontend180 {
    public func serveOwnerFrontend180(product: ProductRuntime, request: AgentValue,
        peer: ProductOwnerPeer180): Result<Unit> {
        if (ownerFrontendText180(request, "frontend") == "tui") {
            return serveOwnedProductTui180(product, request, peer) }
        let scope = OwnerApplicationFrontend180(product, request, peer)
        match (peer.bindOwnerFrontendConsumer180(scope)) {
            case Result.Err(error) => let _ = scope.closeOwnerFrontendConsumer180(); return Result.Err(error)
            case Result.Ok(_) => () }
        scope.initializeOwnerScope180()
        scope.run180()
    }
}

// The broker's original peer slot owns this exact concrete consumer before
// Session construction, subscription, worker spawn or any frontend I/O. Its
// close is called by the broker only after the complete serve helper returned.
private class OwnerApplicationFrontend180 <: ProductOwnerFrontendConsumer180 {
    private var product: ?ProductRuntime
    private var request: ?AgentValue
    private var peer: ?ProductOwnerPeer180
    private var metadata: ?LogicalJsonOwnerReservation
    private var session: ?ApplicationSession = None<ApplicationSession>
    private var input: ?OwnerFrontendInput180 = None<OwnerFrontendInput180>
    private var io: ?OwnerCliIo180 = None<OwnerCliIo180>
    private var cancellation: ?CancellationSource = None<CancellationSource>
    private var failure: ?AgentError = None<AgentError>
    private var thrown: ?Exception = None<Exception>
    private var failureConsumed180 = false
    private var operatorOptions180: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>
    private var rpc: ?RpcFrontendShutdown113 = None<RpcFrontendShutdown113>
    private var rpcPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var acp: ?ProductAcpServer = None<ProductAcpServer>
    private var acpControl: ?AcpOwnedWorkerControl113 = None<AcpOwnedWorkerControl113>
    private var acpPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    init(product: ProductRuntime, request: AgentValue, peer: ProductOwnerPeer180) {
        this.product = Some(product); this.request = Some(request); this.peer = Some(peer)
        this.metadata = None<LogicalJsonOwnerReservation>
    }
    func initializeOwnerScope180(): Unit {
        metadata = Some(peer.getOrThrow().deriveOwnerFrameData180(65536))
    }
    func retainRpc180(frontend: RpcFrontendShutdown113, paid: LogicalJsonOwnerReservation): Unit {
        rpcPayment = Some(paid); rpc = Some(frontend)
    }
    func retireRpcAfterHelper180(): Unit {
        rpc = None<RpcFrontendShutdown113>
        let paid = rpcPayment; rpcPayment = None<LogicalJsonOwnerReservation>
        match (paid) { case Some(actual) => actual.close(); case None => () }
    }
    func retainAcpControl180(control: AcpOwnedWorkerControl113, paid: LogicalJsonOwnerReservation): Unit {
        acpControl = Some(control); acpPayment = Some(paid)
    }
    func retainAcpServer180(server: ProductAcpServer): Unit { acp = Some(server) }
    func retireAcpAfterHelper180(): Bool {
        let actual = acpControl.getOrThrow()
        let controlPayment = actual.takeOwnerFrontendPaymentAfterScopeReturn180()
        if (controlPayment.isNone()) { return false }
        acp = None<ProductAcpServer>; acpControl = None<AcpOwnedWorkerControl113>
        let paid = acpPayment; acpPayment = None<LogicalJsonOwnerReservation>
        match (controlPayment) { case Some(value) => value.close(); case None => () }
        match (paid) { case Some(value) => value.close(); case None => () }
        true
    }
    func frozenOptions180(): ProductOperatorOptions180 { operatorOptions180.getOrThrow() }
    func run180(): Result<Unit> {
        try { runApplicationHelper180() }
        catch (error: OwnedCanonicalDataFailure113) {
            failure = Some(error.error); Result.Err(error.error)
        } catch (error: Exception) {
            // Keep the original thrown object, including an owned paid failure
            // consumer, rather than acknowledging an unknown failed helper.
            thrown = Some(error)
            let result = AgentError(AgentErrorKind.Transport,
                "owner.frontend_helper_failed", error.message)
            failure = Some(result); Result.Err(result)
        }
    }
    private func runApplicationHelper180(): Result<Unit> {
        let root = product.getOrThrow(); let original = request.getOrThrow(); let connection = peer.getOrThrow()
        let source = CancellationSource(); cancellation = Some(source)
        operatorOptions180 = Some(ownerOperatorOptions180(root, original, metadata.getOrThrow()))
        let application = ownerApplicationSession180(root, original, metadata.getOrThrow(),
            frontendCancellation180: Some(source.token), frontendOptions180: operatorOptions180); session = Some(application)
        let kind = ownerFrontendText180(original, "frontend")
        let reader = OwnerFrontendInput180(connection, application, root,
            connection.deriveOwnerFrameData180(65536), source,
            maxLineBytes: if (kind == "rpc" || kind == "acp") { 8388608 } else { Int64.Max })
        input = Some(reader)
        let output = OwnerCliIo180(connection, reader, metadata.getOrThrow()); io = Some(output)
        reader.start180()
        let status = match (kind) {
            case "rpc" => serveOwnerRpc180(root, application, reader, output, connection, this)
            case "acp" => serveOwnerAcp180(root, original, reader, output, connection, this)
            case "cli" => runOwnedCliCommand180(root, application, original, output)
            case "text" | "json" =>
                let prompt = reader.nextLine180() ?? ""
                runOwnedPrintCommand180(root, application, prompt, kind == "json", output, connection)
            case _ => printError(AgentError(AgentErrorKind.InvalidInput,
                "owner.frontend_unknown", "unknown owner frontend"), io: output); 2 }
        reader.retireLineAfterHelperReturn180()
        let cancelled = application.cancel()
        match (cancelled) { case Result.Err(error) => failure = Some(error); return cancelled
            case Result.Ok(_) => () }
        if (!output.retireSubscriptions180(application)) {
            let error = AgentError(AgentErrorKind.RecoveryRequired,
                "owner.frontend_subscriptions_pending", "frontend callbacks remain attached")
            failure = Some(error); return Result.Err(error) }
        let answer = connection.writeOwnerFrame180(encodeAgentValue(objectValue([
            ValueField("kind", textValue("exit")), ValueField("status", integerValue(status))])), None)
        match (answer) { case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () }
        answer
    }
    public func observeOwnerFrontendFailure180(receipt: ProductOwnerFrontendFailureConsumed180): Unit {
        match (failure) {
            case Some(error) => if (receipt.matches180(this, error)) { failureConsumed180 = true }
            case None => ()
        }
    }
    private func clearConsumedFailureReferencesHelper180(): Bool {
        if (failure.isNone()) { return true }
        if (!failureConsumed180 || thrown.isSome()) { return false }
        failure = None<AgentError>
        true
    }
    public func closeOwnerFrontendConsumer180(): Result<Unit> {
        match (session) {
            case Some(application) => match (application.cancel()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => () }
        match (input) {
            case Some(reader) => match (reader.stopAndJoinAfterFrontendReturn180()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => () }
        if (!clearConsumedFailureReferencesHelper180()) { return Result.Err(failure.getOrThrow()) }
        match (session) {
            case Some(application) => match (io) {
                case Some(output) => if (!output.retireSubscriptions180(application)) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "owner.frontend_subscriptions_pending", "frontend callbacks remain attached")) }
                case None => () }
            case None => () }
        if (rpc.isSome() || acp.isSome() || acpControl.isSome() || thrown.isSome()) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "owner.frontend_helpers_pending", "original frontend helper references remain")) }
        match (input) {
            case Some(reader) => match (reader.retireAfterReaderJoin180()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => match (cancellation) { case Some(source) => source.close(); case None => () } }
        io = None<OwnerCliIo180>; input = None<OwnerFrontendInput180>; session = None<ApplicationSession>
        cancellation = None<CancellationSource>; request = None<AgentValue>; peer = None<ProductOwnerPeer180>
        product = None<ProductRuntime>
        let paid = metadata; metadata = None<LogicalJsonOwnerReservation>
        match (paid) { case Some(value) => value.close(); case None => () }
        Result.Ok(())
    }
}

private func runOwnedCliCommand180(product: ProductRuntime, session: ApplicationSession,
    request: AgentValue, io: CliIo180): Int64 {
    let arguments = ownerFrontendArguments180(request)
    match (ownerFrontendText180(request, "command")) {
        case "read" => runReadCli(session, arguments, io: io)
        case "tools" => runToolsCli(session, arguments, io: io)
        case "plugin" => if (!arguments.isEmpty() && arguments[0] == "serve") {
            runPluginStdioCli(product, arguments, io: io)
        } else { runPluginCli(session, arguments, io: io) }
        case "config" => runConfigCli(session, arguments, io: io)
        case "grep" => runGrepCli(session, arguments, io: io)
        case "agents" => runAgentsCli(session, arguments, io: io)
        case "worktree" => runWorktreeCli(session, arguments, io: io)
        case "gc" => runGcCli(session, arguments, io: io)
        case "usage" => runUsageCli(session, arguments, io: io)
        case "stats" => runStatsCli(session, arguments, io: io)
        case "grievances" => runGrievancesCli(session, arguments, io: io)
        case "ssh" => runSshCli(session, arguments, io: io)
        case "models" => runModelsCli(session, arguments, io: io)
        case "reviewer-dry-run" => runReviewerDryRun(product, io: io, session180: Some(session))
        case "__complete" => runDynamicCompletionCli(product, arguments, io: io, session180: Some(session))
        case "token" => runTokenCli(product, arguments, io: io)
        case "shell" => runShellCli(product, arguments, io: io, session180: Some(session))
        case _ => printError(unavailableCliCommand(ownerFrontendText180(request, "command"), arguments), io: io); 1
    }
}

private func runOwnedPrintCommand180(product: ProductRuntime, session: ApplicationSession,
    prompt: String, json: Bool, io: OwnerCliIo180, peer: ProductOwnerPeer180): Int64 {
    let paid = peer.deriveOwnerFrameData180(32768)
    runOwnedPrintHelper180(product, session, prompt, json, io, paid)
}
private func runOwnedPrintHelper180(product: ProductRuntime, session: ApplicationSession,
    prompt: String, json: Bool, io: OwnerCliIo180, paid: LogicalJsonOwnerReservation): Int64 {
    let failures = CliFailureOutput113(paid, json, io: io)
    io.retainFailureHelper180(failures, paid)
    let status = if (json) { runJsonStream(product, prompt, failures, io: io, session180: Some(session)) }
        else { runPrint(product, prompt, failures, io: io, session180: Some(session)) }
    failures.finishMode(status)
}

private func serveOwnerRpc180(product: ProductRuntime, session: ApplicationSession,
    input: OwnerFrontendInput180, io: CliIo180, peer: ProductOwnerPeer180,
    scope: OwnerApplicationFrontend180): Int64 {
    let paid = peer.deriveOwnerFrameData180(65536)
    let status = serveOwnerRpcHelper180(product, session, input, io, paid, scope)
    if (!status[1]) { throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
        "owner.rpc_frontend_retirement_pending", "original RPC workers or subscriptions have not retired")) }
    scope.retireRpcAfterHelper180()
    status[0]
}
private func serveOwnerRpcHelper180(product: ProductRuntime, session: ApplicationSession,
    input: OwnerFrontendInput180, io: CliIo180, paid: LogicalJsonOwnerReservation,
    scope: OwnerApplicationFrontend180): (Int64, Bool) {
    let frontend = RpcFrontendShutdown113(paid, io180: io, observerPayment180: Some(paid))
    scope.retainRpc180(frontend, paid)
    let _ = frontend.install113(product, session180: Some(session))
    let status = serveOwnerRpcBody180(session, input, frontend)
    (frontend.finishRootStatus113(status), frontend.retireOwnerFrontendReferences180())
}
private func serveOwnerRpcBody180(session: ApplicationSession, input: OwnerFrontendInput180,
    frontend: RpcFrontendShutdown113): Int64 {
    let server = frontend.server113()
    try {
        frontend.startStartup113()
        while (true) {
            frontend.collectFinishedTasks113()
            if (frontend.observedStartupFailure113()) { return frontend.finishObservedExit113(1, true) }
            if (frontend.startupReturned113()) { break }
            sleep(Duration.millisecond * 10)
        }
        frontend.writePlain113(server.ready())
        while (true) {
            frontend.requestPump113()
            let polled = input.poll180(50)
            if (polled.eof) {
                let _ = session.cancel()
                return frontend.finishObservedExit113(0, true)
            }
            match (polled.line) {
                case Some(line) => runOwnerRpcLineHelper180(server, frontend, line)
                case None => continue
            }
            input.retireLineAfterHelperReturn180()
        }
        0
    } finally { frontend.requestShutdown113(true) }
}
private func runOwnerRpcLineHelper180(server: ProductJsonlRpcServer,
    frontend: RpcFrontendShutdown113, line: String): Unit {
    let response = server.handle(line)
    if (response != "") { frontend.writePlain113(response) }
}

private func serveOwnerAcp180(product: ProductRuntime, request: AgentValue,
    input: OwnerFrontendInput180, io: CliIo180, peer: ProductOwnerPeer180,
    scope: OwnerApplicationFrontend180): Int64 {
    let control = newAcpOwnedWorkerControl113(peer.deriveOwnerFrameData180(65536))
    let paid = peer.deriveOwnerFrameData180(65536)
    scope.retainAcpControl180(control, paid)
    let status = serveOwnerAcpHelper180(product, request, input, io, peer, control, paid, scope)
    if (!scope.retireAcpAfterHelper180()) {
        throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
            "owner.acp_frontend_retirement_pending", "original ACP workers or close journal have not retired")) }
    status
}
private func serveOwnerAcpHelper180(product: ProductRuntime, request: AgentValue,
    input: OwnerFrontendInput180, io: CliIo180, peer: ProductOwnerPeer180,
    control: AcpOwnedWorkerControl113, paid: LogicalJsonOwnerReservation,
    scope: OwnerApplicationFrontend180): Int64 {
    let output = RpcOutput(io: io)
    let server = ProductAcpServer(product, { cwd =>
        match (canonicalAcpCwd(cwd)) {
            case Result.Err(error) => Result<ProductRuntime>.Err(error)
            case Result.Ok(path) => if (path == product.workspace.rootPath()) { Result<ProductRuntime>.Ok(product) }
                else { Result<ProductRuntime>.Err(AgentError(AgentErrorKind.Conflict,
                    "acp.session_workspace_factory_mismatch", "ACP request reached a different workspace Owner")) }
        }
    },
        { _ => throw IllegalStateException("ACP production has no bare String output") },
        control113: control, ownedFailureOutput113: Some(output), ownedResponseOutput113: Some(output),
        sharedRootPayment180: Some(paid),
        applicationFactory180: { root, id => ownerApplicationSession180(root, request, paid, sessionId: id,
            frontendCancellation180: Some(input.cancellation180()), frontendOptions180: Some(scope.frozenOptions180())) },
        requestIdAllocator180: if (ownerFrontendBoolean180(request, "acp_id_allocator")) {
            Some({ => input.allocateAcpRequestId180() }) } else { None<() -> Int64> })
    scope.retainAcpServer180(server)
    if (ownerFrontendBoolean180(request, "acp_initialized")) { server.initializeOwnerConnection180() }
    let status = serveOwnerAcpBody180(server, input, io, peer)
    if (!server.detachFailedInputAfterClosedFrontendReturn113() ||
        !server.retireOwnedCloseAfterFrontendHelperReturn113()) {
        throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
            "owner.acp_frontend_close_pending", "original ACP frontend close has not retired")) }
    status
}

private func serveOwnerAcpBody180(server: ProductAcpServer, input: OwnerFrontendInput180,
    io: CliIo180, peer: ProductOwnerPeer180): Int64 {
    var status: Int64 = 0
    try {
        while (true) {
            let _ = server.collectOwnedCheckpointFailures113()
            let polled = input.poll180(50)
            if (polled.eof) { break }
            match (polled.line) {
                case None => continue
                case Some(line) =>
                    let paid = peer.deriveOwnerFrameData180(65536 + line.size * 8)
                    let actual = AcpOwnedInput113(paid, 65536 + line.size * 8, { => line })
                    match (server.handleOwnedInput113(actual)) {
                        case Result.Err(_) => status = 1; break
                        case Result.Ok(_) => () }
                    if (!server.afterOwnedInputHelperReturn113(actual) || !actual.retireAfterHandlerReturn113()) {
                        status = 1; break }
            }
            input.retireLineAfterHelperReturn180()
            server.flushDeferred()
        }
    } catch (failure: OwnedCanonicalPaidFailure113) {
        server.retainFrontendFailure113(failure.takeConsumer())
        let _ = server.writeFrontendFailure113({ frame => writeOwnedAcpFrontendFailure113(frame, io: io) }); status = 1
    } catch (failure: OwnedCanonicalDataFailure113) {
        server.retainFrontendFailure113(failure.error)
        let _ = server.writeFrontendFailure113({ frame => writeOwnedAcpFrontendFailure113(frame, io: io) }); status = 1
    } catch (failure: Exception) {
        server.retainFrontendFailure113(failure)
        let _ = server.writeFrontendFailure113({ frame => writeOwnedAcpFrontendFailure113(frame, io: io) }); status = 1
    }
    match (server.closeOwned113()) {
        case AcpOwnedCloseStatus113.Complete => status
        case AcpOwnedCloseStatus113.Failed =>
            let _ = server.writeOwnedClose113({ frame => writeOwnedAcpClose113(frame, io: io) }); 1
        case AcpOwnedCloseStatus113.FailedConsumed | AcpOwnedCloseStatus113.Held => 1
    }
}
