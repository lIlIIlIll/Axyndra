package agent_app

import agent_domain.*
import agent_runtime.*
import agent_product.*
import agent_tui.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*

func serveOwnedProductTui180(product: ProductRuntime, request: AgentValue, peer: ProductOwnerPeer180): Result<Unit> {
    let owner = OwnedProductTuiPeer180(product, request, peer)
    match (peer.bindOwnerFrontendConsumer180(owner)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    owner.serve180()
}

// Only this actual socket writer can mint the serializer retirement receipt.
// It does not acknowledge client Screen, terminal, history or renderer copies.
class TuiRootSerializerRetirement180 <: OwnedRegistryResponseRetirement161 {
    private let owner: OwnedProductTuiPeer180
    private let backend: Object
    private let scope: Int64
    init(owner: OwnedProductTuiPeer180, backend: Object, scope: Int64) {
        this.owner = owner; this.backend = backend; this.scope = scope
    }
    func acknowledges180(actual: Object): Bool { refEq(actual, backend) && owner.serializerReferencesRetired180(scope) }
    public func copiedReferencesRetired(): Bool { owner.serializerReferencesRetired180(scope) }
}

private class TuiRootWriteFrame180 {
    private var paid: ?LogicalJsonOwnerReservation
    private var data: ?AgentValue = None
    private var encoded: ?String = None
    private var result: ?Result<Unit> = None
    init(paid: LogicalJsonOwnerReservation) { this.paid = Some(paid) }
    func write180(peer: ProductOwnerPeer180, kind: String, id: Int64, build: () -> AgentValue): Result<Unit> {
        data = Some(listValue([textValue(kind), integerValue(id), build()]))
        encoded = Some(encodeAgentValue(data.getOrThrow()))
        result = Some(peer.writeOwnerFrame180(encoded.getOrThrow()))
        result.getOrThrow()
    }
    func clearAfterWholeWriterHelper180(): Unit { data = None; encoded = None; result = None }
    func retirePayment180(): Unit { paid.getOrThrow().close(); paid = None }
}

class OwnedProductTuiPeer180 <: OwnedTuiToolDisplayOutput & OwnedTuiFailureDisplayOutput113 & OwnedTuiSerializerLifetime180 & ProductOwnerFrontendConsumer180 {
    private var peerValue: ?ProductOwnerPeer180
    private prop peer: ProductOwnerPeer180 { get() { peerValue.getOrThrow() } }
    private var cancellationValue180:?CancellationSource=None<CancellationSource>
    private prop peerCancellation180:CancellationSource { get(){cancellationValue180.getOrThrow()} }
    private var backendValue: ?ProductTuiBackend = None
    private prop backend: ProductTuiBackend { get() { backendValue.getOrThrow() } }
    private var metadata: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private let lock = Mutex()
    private let writer = Mutex()
    private var writerFrames: Int64 = 0
    private var lastWrite: Int64 = 0
    private var closing = false
    private var quiesced = false
    private var closed = false
    private var writeFrame: ?TuiRootWriteFrame180 = None
    private var turn: ?Future<Unit> = None
    private var turnData: ?AgentValue = None
    private var turnPaid: ?TuiOwnerReadFrame180 = None
    private var readFrame180: ?TuiOwnerReadFrame180 = None
    private var readRawPending180: ?LogicalJsonOwnerReservation = None
    private var turnSpawnFailure180: ?Exception = None
    private var turnId: Int64 = 0
    private var turnMethod = ""
    private var retiredScope: Int64 = -1
    private var originalProduct180: ?ProductRuntime
    private var originalRequest180: ?AgentValue
    private var serveFailure180: ?Exception = None<Exception>
    private var cleanupFailure180: ?Exception = None<Exception>
    init(product: ProductRuntime, request: AgentValue, peer: ProductOwnerPeer180) {
        this.peerValue = Some(peer)
        this.originalProduct180 = Some(product); this.originalRequest180 = Some(request)
    }
    private func preservePrimary180(error: Exception): AgentError {
        if (serveFailure180.isNone()) { serveFailure180 = Some(error) }
        match (error as OwnedCanonicalDataFailure113) {
            case Some(original) => original.error
            case None => AgentError(AgentErrorKind.Transport, "tui.owner_transport_failed", error.message)
        }
    }
    func serve180(): Result<Unit> {
        let result = try { serveWholeHelper180() }
            catch (error: Exception) { Result<Unit>.Err(preservePrimary180(error)) }
        try { closeRootProducer180() }
        catch (error: Exception) {
            cleanupFailure180 = Some(error)
            match (result) { case Result.Err(primary) => return Result.Err(primary)
                case Result.Ok(_) => return Result.Err(preservePrimary180(error)) }
        }
        result
    }
    private func serveWholeHelper180(): Result<Unit> {
        // The exact field-only owner is already reachable from the real peer.
        metadata=Some(peer.deriveOwnerFrameData180(65536))
        cancellationValue180=Some(CancellationSource())
        let product = originalProduct180.getOrThrow(); let request = originalRequest180.getOrThrow()
        let session = ownerApplicationSession180(product, request, metadata.getOrThrow(),
            frontendCancellation180: Some(peerCancellation180.token))
        backendValue = Some(ProductTuiBackend(product, applicationSession: session,
            ownerAllocation180: Some({ bytes => peer.deriveOwnerFrameData180(bytes) }),
            ownerSerializerLifetime180: Some(this)))
        backend.initializeFrontend180()
        backend.observe({ event => emitEvent180(0, event) })
        backend.observeOwnedToolDisplay(this)
        backend.observeOwnedFailureDisplay113(this)
        sendState180()
        while (true) {
            collectTurn180(false)
            let rawPaid = peer.deriveOwnerFrameData180(65536)
            readRawPending180 = Some(rawPaid)
            let frame = TuiOwnerReadFrame180(rawPaid)
            readFrame180 = Some(frame); readRawPending180 = None
            frame.initializeCodec180(peer)
            if (!readCall180(frame)) { break }
        }
        collectReadPayments180()
        Result<Unit>.Ok(())
    }

    private func readCall180(paid: TuiOwnerReadFrame180): Bool {
        let data = paid.readAndDecode180(peer, 1048576)
        tuiOwnerShape180(data, 4)
        if (tuiOwnerText180(data.items[0]) != "call") { throw Exception("tui.owner_expected_call") }
        let id = tuiOwnerInteger180(data.items[1]); let method = tuiOwnerText180(data.items[2]); let args = data.items[3]
        if (id < 1) { throw Exception("tui.owner_invalid_request_id") }
        if (method == "close") {
            tuiOwnerShape180(args, 0)
            closeRootProducer180()
            sendResult180(id, 4096, { => nullValue() })
            finishReadFrame180(paid)
            return false
        }
        if (method == "submit" || method == "decide" || method == "reviewPlan" || method == "runPluginCommand") {
            beginTurn180(id, method, args, paid)
            return true
        }
        try { dispatch180(id, method, args) }
        catch (error: Exception) { send180("failure", id, tuiOwnerInvoice180(error.message), { => textValue(error.message) }) }
        // readCall180's raw/DOM/helper must end before payment retirement.
        finishReadFrame180(paid)
        true
    }
    private func finishReadFrame180(paid: TuiOwnerReadFrame180): Unit {
        // The enclosing helper still owns its DOM; retire at the next actual
        // outer boundary, after that helper has returned.
        lock.lock(); try { pendingReadPayments180.add(paid); readFrame180 = None } finally { lock.unlock() }
    }
    private let pendingReadPayments180 = ArrayList<TuiOwnerReadFrame180>()
    private func collectReadPayments180(): Unit {
        for (paid in pendingReadPayments180) { paid.retireAfterWholeReadConsumer180() }; pendingReadPayments180.clear()
    }
    private func beginTurn180(id: Int64, method: String, args: AgentValue, paid: TuiOwnerReadFrame180): Unit {
        collectTurn180(false)
        if (turn.isSome()) { send180("failure", id, 4096, { => textValue("tui.owner_turn_already_running") }); finishReadFrame180(paid); return }
        turnId = id; turnMethod = method; turnData = Some(args); turnPaid = Some(paid)
        readFrame180 = None
        try { turn = Some(spawn { runTurn180() }) }
        catch (error: Exception) { turnSpawnFailure180 = Some(error); throw error }
    }
    private func runTurn180(): Unit {
        try { dispatch180(turnId, turnMethod, turnData.getOrThrow()) }
        catch (error: Exception) { send180("failure", turnId, tuiOwnerInvoice180(error.message), { => textValue(error.message) }) }
        finally { backend.pollOwnedFailureDisplays113() }
    }
    private func getTurnWholeHelper180(): Unit { turn.getOrThrow().get() }
    private func clearTurnReferences180(): Unit { turn = None; turnData = None; turnMethod = ""; turnId = 0 }
    private func collectTurn180(wait: Bool): Unit {
        if (turnSpawnFailure180.isSome()) { throw turnSpawnFailure180.getOrThrow() }
        collectReadPayments180()
        if (turn.isNone() || (!wait && turn.getOrThrow().tryGet().isNone())) { return }
        getTurnWholeHelper180()
        clearTurnReferences180()
        match (turnPaid) { case Some(paid) => paid.retireAfterWholeReadConsumer180(); turnPaid = None; case None => () }
    }
    private func send180(kind: String, id: Int64, invoice: Int64, build: () -> AgentValue): Unit {
        writer.lock()
        try {
            if (writeFrame.isSome()) { throw Exception("tui.owner_previous_writer_pending") }
            let paid = peer.deriveOwnerFrameData180(4096); paid.ensureRetainedPeak(tuiOwnerInvoiceAdd180(4096, invoice))
            writeFrame = Some(TuiRootWriteFrame180(paid))
            lock.lock(); writerFrames++; lock.unlock()
            let result = try { writeFrame.getOrThrow().write180(peer, kind, id, build) }
                finally { lock.lock(); writerFrames--; lock.unlock() }
            // The real physical socket writer and complete codec helper have
            // returned. Only now clear their actual retained DATA fields.
            match (result) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
            writeFrame.getOrThrow().clearAfterWholeWriterHelper180()
            writeFrame.getOrThrow().retirePayment180(); writeFrame = None
            lock.lock(); try { lastWrite++ } finally { lock.unlock() }
        } finally { writer.unlock() }
    }
    private func emitEvent180(id: Int64, event: TuiAgentEvent): Unit {
        match (event) {
            case TuiAgentEvent.OwnedToolDisplay(value) => accept(value).value().getOrThrow()
            case TuiAgentEvent.OwnedFailureDisplay113(value) => acceptFailureDisplay113(value).value().getOrThrow()
            case TuiAgentEvent.OwnedRegistryError167(_, message) =>
                send180("event", id, tuiOwnerInvoice180(message), { => listValue([textValue("owned_registry_error"), textValue(message)]) })
            case _ => send180("event", id, tuiOwnerInvoice180(event), { => tuiOwnerEncode180(event) })
        }
    }
    public func accept(display: OwnedTuiToolDisplay): Result<Unit> {
        display.withCopiedEvent({ event =>
            send180("event", 0, tuiOwnerInvoice180(event), { => listValue([textValue("owned_tool"), tuiOwnerEncode180(event)]) })
            Result<Unit>.Ok(()) })
    }
    public func acceptFailureDisplay113(display: OwnedTuiFailureDisplay113): Result<Unit> {
        display.withCopiedFailure113({ code, message, encoded =>
            let invoice = tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(code), tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(message), tuiOwnerInvoice180(encoded)))
            send180("event", 0, invoice, { => listValue([textValue("owned_failure"), textValue(code), textValue(message), textValue(encoded)]) })
            Result<Unit>.Ok(()) })
    }
    private func sendState180(): Unit {
        let values = [backend.currentModel(), backend.currentSession(), backend.currentThinking(), backend.currentWorkMode(),
            backend.currentShellNetworkMode(), backend.currentTheme(), backend.currentBranch(), backend.workspace()]
        let invoice = tuiOwnerInvoiceArray180(values, { item => tuiOwnerInvoice180(item) })
        send180("state", 0, invoice, { => tuiOwnerEncodeArray180(values, { item => textValue(item) }) })
    }
    private func sendTurn180(id: Int64, value: TuiTurnResult): Unit {
        let invoice = tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(value.text), tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(value.status), tuiOwnerInvoice180(value.action)))
        sendResult180(id, invoice, { => listValue([textValue(value.text), textValue(value.status), tuiOwnerEncode180(value.action),
            tuiOwnerEncode180(value.planReviewDisposition), boolValue(value.ownedRegistryDisplay167.isSome())]) })
    }
    private func sendResult180(id: Int64, invoice: Int64, build: () -> AgentValue): Unit {
        if (!closing) { sendState180() }
        send180("result", id, invoice, build)
    }
    private func dispatch180(id: Int64, method: String, args: AgentValue): Unit {
        match (method) {
            case "cancel" =>
                tuiOwnerShape180(args, 1)
                if (turn.isSome() && tuiOwnerInteger180(args.items[0]) == turnId) { backend.cancelOwnerTurn180().value().getOrThrow() }
                sendResult180(id, 4096, { => nullValue() })
            case "pollOwnedFailureDisplays113" => tuiOwnerShape180(args, 0); backend.pollOwnedFailureDisplays113(); sendResult180(id, 4096, { => nullValue() })
            case "welcome" =>
                tuiOwnerShape180(args, 0)
                let value = backend.welcome()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => tuiOwnerEncode180(item) }) })
            case "submit" =>
                tuiOwnerShape180(args, 1)
                let value = backend.submit(tuiOwnerText180(args.items[0]), { event => emitEvent180(id, event) })
                sendTurn180(id, value)
            case "steer" =>
                tuiOwnerShape180(args, 2)
                let value = backend.steer(tuiOwnerText180(args.items[0]), tuiOwnerText180(args.items[1]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "followUp" =>
                tuiOwnerShape180(args, 2)
                let value = backend.followUp(tuiOwnerText180(args.items[0]), tuiOwnerText180(args.items[1]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "withdrawQueued" =>
                tuiOwnerShape180(args, 1)
                let value = backend.withdrawQueued(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case "decide" =>
                tuiOwnerShape180(args, 2)
                let value = backend.decide(tuiOwnerText180(args.items[0]), tuiOwnerDecodeTuiApprovalDecision180(args.items[1]), { event => emitEvent180(id, event) })
                sendTurn180(id, value)
            case "reviewPlan" =>
                tuiOwnerShape180(args, 3)
                let value = backend.reviewPlan(tuiOwnerText180(args.items[0]), tuiOwnerDecodeTuiPlanReviewDecision180(args.items[1]), tuiOwnerText180(args.items[2]), { event => emitEvent180(id, event) })
                sendTurn180(id, value)
            case "answerAsk" =>
                tuiOwnerShape180(args, 2)
                let value = backend.answerAsk(tuiOwnerText180(args.items[0]), tuiOwnerDecodeTuiAskResolution180(args.items[1]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "pluginCommands" =>
                tuiOwnerShape180(args, 0)
                let value = backend.pluginCommands()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => textValue(item) }) })
            case "runPluginCommand" =>
                tuiOwnerShape180(args, 2)
                let value = backend.runPluginCommand(tuiOwnerText180(args.items[0]), tuiOwnerText180(args.items[1]), { event => emitEvent180(id, event) })
                sendTurn180(id, value)
            case "currentModel" =>
                tuiOwnerShape180(args, 0)
                let value = backend.currentModel()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "currentSession" =>
                tuiOwnerShape180(args, 0)
                let value = backend.currentSession()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "currentThinking" =>
                tuiOwnerShape180(args, 0)
                let value = backend.currentThinking()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "currentWorkMode" =>
                tuiOwnerShape180(args, 0)
                let value = backend.currentWorkMode()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "currentShellNetworkMode" =>
                tuiOwnerShape180(args, 0)
                let value = backend.currentShellNetworkMode()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "currentTheme" =>
                tuiOwnerShape180(args, 0)
                let value = backend.currentTheme()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "currentBranch" =>
                tuiOwnerShape180(args, 0)
                let value = backend.currentBranch()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "workspace" =>
                tuiOwnerShape180(args, 0)
                let value = backend.workspace()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "models" =>
                tuiOwnerShape180(args, 0)
                let value = backend.models()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => textValue(item) }) })
            case "customThemes" =>
                tuiOwnerShape180(args, 0)
                let value = backend.customThemes()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => tuiOwnerEncode180(item) }) })
            case "selectTheme" =>
                tuiOwnerShape180(args, 1)
                let value = backend.selectTheme(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "sessions" =>
                tuiOwnerShape180(args, 1)
                let value = backend.sessions(tuiOwnerBoolean180(args.items[0]))
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => tuiOwnerEncode180(item) }) })
            case "sessionTree" =>
                tuiOwnerShape180(args, 0)
                let value = backend.sessionTree()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => tuiOwnerEncode180(item) }) })
            case "renameSession" =>
                tuiOwnerShape180(args, 2)
                let value = backend.renameSession(tuiOwnerText180(args.items[0]), tuiOwnerText180(args.items[1]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "archiveSession" =>
                tuiOwnerShape180(args, 1)
                let value = backend.archiveSession(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "restoreSession" =>
                tuiOwnerShape180(args, 1)
                let value = backend.restoreSession(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "subagents" =>
                tuiOwnerShape180(args, 0)
                let value = backend.subagents()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => tuiOwnerEncode180(item) }) })
            case "subagentTranscript" =>
                tuiOwnerShape180(args, 1)
                let value = backend.subagentTranscript(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "focusSubagent" =>
                tuiOwnerShape180(args, 1)
                let value = backend.focusSubagent(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case "focusMain" =>
                tuiOwnerShape180(args, 0)
                let value = backend.focusMain()
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case "loadMainTranscriptPage" =>
                tuiOwnerShape180(args, 2)
                let value = backend.loadMainTranscriptPage(tuiOwnerInteger180(args.items[0]), tuiOwnerInteger180(args.items[1]))
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case "draft" =>
                tuiOwnerShape180(args, 0)
                let value = backend.draft()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "saveDraft" =>
                tuiOwnerShape180(args, 1)
                let value = backend.saveDraft(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "branchMessages" =>
                tuiOwnerShape180(args, 0)
                let value = backend.branchMessages()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => textValue(item) }) })
            case "selectModel" =>
                tuiOwnerShape180(args, 1)
                let value = backend.selectModel(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "selectSession" =>
                tuiOwnerShape180(args, 1)
                let value = backend.selectSession(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => boolValue(value) })
            case "selectBranch" =>
                tuiOwnerShape180(args, 1)
                let value = backend.selectBranch(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoiceOption180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeOption180(value, { item => textValue(item) }) })
            case "configureSetup" =>
                tuiOwnerShape180(args, 1)
                let value = backend.configureSetup(tuiOwnerDecodeTuiSetupRequest180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "archiveAndReset" =>
                tuiOwnerShape180(args, 0)
                let value = backend.archiveAndReset()
                sendResult180(id, tuiOwnerInvoice180(value), { => textValue(value) })
            case "frontendSlashDefinitions" =>
                tuiOwnerShape180(args, 0)
                let value = backend.frontendSlashDefinitions()
                sendResult180(id, tuiOwnerInvoiceArray180(value, { item => tuiOwnerInvoice180(item) }), { => tuiOwnerEncodeArray180(value, { item => tuiOwnerEncode180(item) }) })
            case "todoMarkdown" =>
                tuiOwnerShape180(args, 0)
                let value = backend.todoMarkdown()
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case "copyTodoData180" =>
                tuiOwnerShape180(args, 0)
                let value = backend.copyTodoData180()
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case "loadTodoEditor" =>
                tuiOwnerShape180(args, 0)
                let value = backend.loadTodoEditor()
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case "saveTodoMarkdown" =>
                tuiOwnerShape180(args, 1)
                let value = backend.saveTodoMarkdown(tuiOwnerText180(args.items[0]))
                sendResult180(id, tuiOwnerInvoice180(value), { => tuiOwnerEncode180(value) })
            case _ => throw Exception("tui.owner_unknown_method")
        }
    }
    private func closeRootProducer180(): Unit {
        if (closed) { return }
        peerCancellation180.cancel()
        if (backendValue.isNone()) { throw Exception("tui.owner_backend_initialization_unknown") }
        lock.lock(); try { closing = true } finally { lock.unlock() }
        if (turn.isSome()) { backend.cancelOwnerTurn180().value().getOrThrow() }
        collectTurn180(true)
        backend.pollOwnedFailureDisplays113()
        backend.beginOwnedToolDisplayProducerClosing()
        if (!backend.awaitRootSerializerFrames180()) { throw Exception("tui.owner_producer_retirement_pending") }
        writer.lock()
        try {
            lock.lock(); try {
                if (writerFrames != 0 || writeFrame.isSome()) { throw Exception("tui.owner_writer_retirement_pending") }
                quiesced = true; retiredScope = lastWrite
            } finally { lock.unlock() }
        } finally { writer.unlock() }
        let receipt = TuiRootSerializerRetirement180(this, backend, retiredScope)
        backend.retireRootSerializer180(receipt).value().getOrThrow()
        collectReadPayments180()
        closed = true
    }
    public func closeOwnerFrontendConsumer180(): Result<Unit> {
        match (serveFailure180) { case Some(error) => return Result.Err(preservePrimary180(error)); case None => () }
        try { closeRootProducer180(); retireAfterServe180(); Result<Unit>.Ok(()) }
        catch (error: Exception) { cleanupFailure180 = Some(error); Result<Unit>.Err(preservePrimary180(error)) }
    }
    private func retireAfterServe180(): Unit {
        if (!closed || !serializerReferencesRetired180(retiredScope) || readFrame180.isSome() ||
            readRawPending180.isSome() || turnPaid.isSome() || turnData.isSome() || turn.isSome()) {
            throw Exception("tui.owner_retirement_pending") }
        backendValue = None
        originalProduct180 = None<ProductRuntime>; originalRequest180 = None<AgentValue>
        peerCancellation180.close();cancellationValue180=None<CancellationSource>
        peerValue = None
        match (metadata) { case Some(paid) => paid.close(); metadata = None; case None => () }
    }
    public func rootSerializerReferencesRetired180(actualProducer: Object): Bool {
        match (backendValue) {
            case Some(actual) => refEq(actual, actualProducer) && serializerReferencesRetired180(retiredScope)
            case None => false }
    }
    func serializerReferencesRetired180(scope: Int64): Bool {
        lock.lock(); try { closing && quiesced && writerFrames == 0 && writeFrame.isNone() && scope == retiredScope } finally { lock.unlock() }
    }
}
