package agent_rpc

import yjson_support.*

import yjson.*

import agent_cli.*
import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.RpcQueuedStoreFailure113
import agent_product.*
import std.collection.*
import std.convert.*
import std.sync.*

public class ProductJsonlRpcServer {
    private let session: ApplicationSession
    private let emit: (String) -> Unit
    private let ownedOutput: ?OwnedRpcFrameOutput
    private let ownedDeliveries = ArrayList<OwnedProductRpcEventDelivery>()
    private let ownedFailureDeliveries113 = RpcOwnedFailureQueue113()
    private let unadmittedFailure113 = AtomicBool(false)
    private var hostTools: ?RpcHostToolBridge = None
    private var hostUris: ?RpcHostUriBridge = None
    private let lock = Mutex()
    private let frameLock = Mutex()
    private var running = false
    // One actual prompt/decision Future; never infer retirement from running.
    private var runWorker113: ?Future<Unit> = None<Future<Unit>>
    private var runWorkerStartingFailed113 = false
    // One actual Native-bank root; each concurrent worker derives a SUM-paid
    // child without another pool, transfer slot or 16 MiB floor.
    private var workerMetadata113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var runWorkerMetadata113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var commandWorkerMetadata113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var runWorkerBasePeak113: Int64 = 0
    private var queuedWorkerPeak113: Int64 = 0
    private var workerPaymentFailed113 = false
    private var queuedInputCustody113: ?RpcQueuedRetainedInput113 = None<RpcQueuedRetainedInput113>
    private var workerSnapshotArrays113: Int64 = 0
    private var workerJoinFrames113: Int64 = 0
    private var bashWorkers: ?ArrayList<RpcBashWorker> = None<ArrayList<RpcBashWorker>>
    private var closing = false
    private var interactionProfile = "none"
    private var activePluginCommandRequestId = ""
    private var pluginCommandWorker: ?Future<Unit> = None
    private var pluginCommandStartingFailed113 = false
    private var protocolVersion: Int64 = 1
    private var chunkCounter: Int64 = 0
    private var thinkingLevel = "medium"
    private var steeringMode = "one-at-a-time"
    private var followUpMode = "one-at-a-time"
    private var interruptMode = "immediate"
    private var subagentSubscription = "off"

    public init(
        session: ApplicationSession,
        emit: (String) -> Unit,
        ownedOutput!: ?OwnedRpcFrameOutput = None
    ) {
        this.session = session
        this.emit = emit
        this.ownedOutput = ownedOutput
        this.hostTools = Some(
            RpcHostToolBridge(
                session,
                {frame => emitFrame(frame)}
            )
        )
        this.hostUris = Some(
            RpcHostUriBridge(
                session,
                {frame => emitFrame(frame)}
            )
        )
        if (ownedOutput.isNone()) {
        session.subscribe({
            event => emitFrame(
                encodeAgentValue(
                    objectValue(
                        [
                            ValueField("type", textValue("agent_event")),
                            ValueField("sequence", integerValue(event.sequence)),
                            ValueField("runId", textValue(event.runId.value)),
                            ValueField("event", eventProtocolDetail(event))
                        ]
                    )
                )
            )
        })
        } else {
            session.subscribeOwned({
            event => emitFrame(
                encodeAgentValue(
                    objectValue(
                        [
                            ValueField("type", textValue("agent_event")),
                            ValueField("sequence", integerValue(event.sequence)),
                            ValueField("runId", textValue(event.runId.value)),
                            ValueField("event", eventProtocolDetail(event))
                        ]
                    )
                )
            )
        }, CallbackOwnedAgentEventSink({ event => emitOwnedEvent(event) }),
            failures: Some(ProductRpcFailureSink113({ value => admitOwnedFailure113(value) })))
        }
        session.subscribeSubagents({
            event => emitSubagentFrame(event)
        })
        session.subscribeAsks({request => publishInteractionRequest(request)})
        session.subscribeAsyncJobs({
            event => emitFrame(
                encodeAgentValue(
                    objectValue(
                        [
                            ValueField("type", textValue("async_job")),
                            ValueField("kind", textValue(event.kind)),
                            ValueField(
                                "payload",
                                asyncJobRpcValue(event.snapshot)
                            )
                        ]
                    )
                )
            )
        })
    }

    public func ready(): String {
        encodeAgentValue(
            objectValue(
                [
                    ValueField("type", textValue("ready")),
                    ValueField("protocolVersion", integerValue(1)),
                    ValueField(
                        "supportedProtocolVersions",
                        listValue([integerValue(1), integerValue(2)])
                    ),
                    ValueField("supportedInteractionProfiles", stringListValue(["basic-v1"])),
                    ValueField("maxFrameBytes", integerValue(1048576)),
                    ValueField(
                        "maxReassembledFrameBytes",
                        integerValue(67108864)
                    )
                ]
            )
        )
    }

    public func handle(source: String): String {
        let logical = handleLogical(source)
        if (logical == "") {
            ""
        } else {
            outbound(logical)
        }
    }

    private func handleLogical(source: String): String {
        let bytes = unsafe { source.rawData() }
        if (bytes.size > 1048576) {
            return failure("", "parse", "RPC frame exceeds 1 MiB")
        }
        let value = match (decodeAgentValue(source)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return failure("", "parse", error.message)
        }
        let id = productTextField(value, "id")
        let command = productTextField(value, "type")
        if (command == "host_tool_result") {
            return match (hostToolBridge().handleResult(value)) {
                case Result.Ok(_) => ""
                case Result.Err(error) => failure(id, command, error.message)
            }
        }
        if (command == "host_tool_update") {
            return match (hostToolBridge().handleUpdate(value)) {
                case Result.Ok(_) => ""
                case Result.Err(error) => failure(id, command, error.message)
            }
        }
        if (command == "host_uri_result") {
            return match (hostUriBridge().handleResult(value)) {
                case Result.Ok(_) => ""
                case Result.Err(error) => failure(id, command, error.message)
            }
        }
        match (command) {
            case "prompt" =>
                let message = productTextField(value, "message")
                if (message.trimAscii() == "") {
                    return failure(
                        id,
                        command,
                        "message must not be empty"
                    )
                }
                let streamingBehavior = productTextField(
                    value,
                    "streamingBehavior"
                )
                if (isRunning() || session.approval().isSome()) {
                    if (streamingBehavior == "steer") {
                        match (queueInteraction("steer", message)) {
                            case Result.Ok(_) => success(id, command)
                            case Result.Err(error) => failure(id, command, error.message)
                        }
                    } else if (streamingBehavior == "followUp") {
                        match (queueInteraction("follow_up", message)) {
                            case Result.Ok(_) => success(id, command)
                            case Result.Err(error) => failure(id, command, error.message)
                        }
                    } else {
                        failure(
                            id,
                            command,
                            "Agent is already processing. Use steer or " + "follow_up, or wait for completion."
                        )
                    }
                } else {
                    if (startPrompt(id, command, message)) {
                        success(id, command)
                    } else {
                        failure(
                            id,
                            command,
                            "Agent is already processing. Use steer or " + "follow_up, or wait for completion."
                        )
                    }
                }
            case "steer" | "follow_up" =>
                let message = productTextField(value, "message")
                if (message.trimAscii() == "") {
                    return failure(
                        id,
                        command,
                        "message must not be empty"
                    )
                }
                match (queueInteraction(command, message)) {
                    case Result.Ok(_) => success(id, command)
                    case Result.Err(error) => failure(id, command, error.message)
                }
            case "abort_and_prompt" =>
                let message = productTextField(value, "message")
                if (message.trimAscii() == "") {
                    return failure(
                        id,
                        command,
                        "message must not be empty"
                    )
                }
                match (session.cancel()) {
                    case Result.Ok(_) =>
                        if (scheduleDeferred(id, command, message)) { success(id, command) }
                        else { failure(id, command, "RPC server is closing or retiring its prior request") }
                    case Result.Err(error) => failure(id, command, error.message)
                }
            case "abort" => match (session.cancel()) {
                case Result.Ok(_) => success(id, command)
                case Result.Err(error) => failure(id, command, error.message)
            }
            case "approve" | "approve_session" | "reject" =>
                let operationId = productTextField(
                    value,
                    "operationId"
                )
                let pending = session.approval()
                if (operationId == "" || pending.isNone() || pending.getOrThrow().operationId.value != operationId) {
                    failure(
                        id,
                        command,
                        "operationId does not match the pending approval"
                    )
                } else if (command == "approve_session" && !pending.getOrThrow().sessionApprovalAllowed) {
                    failure(
                        id,
                        command,
                        "session approval is unavailable for network-enabled operations"
                    )
                } else if (!startDecision(
                    RpcDecision(
                        id,
                        command,
                        operationId,
                        match (command) {
                            case "approve" => ApprovalDecision.Approve
                            case "approve_session" => ApprovalDecision.ApproveSession
                            case _ =>
                                let reason = productTextField(
                                    value,
                                    "reason"
                                )
                                if (reason == "") {
                                    ApprovalDecision.Reject
                                } else {
                                    ApprovalDecision.RejectWithReason(reason)
                                }
                        }
                    )
                )) {
                    failure(id, command, "another operation is active")
                } else {
                    success(id, command)
                }
            case "new_session" => match (session.newSession(
                parentSession: productTextField(
                    value,
                    "parentSession"
                )
            )) {
                case Result.Ok(_) => success(id, command, data: objectValue([ValueField("cancelled", boolValue(false))]))
                case Result.Err(error) => failure(id, command, error.message)
            }
            case "get_state" => success(id, command, data: stateValue())
            case "get_available_commands" => success(id, command, data: commandsValue(session.frontendSlashDefinitions()))
            case "get_plugin_commands" => success(id, command, data: pluginCommandsValue())
            case "plugin_command" => startPluginCommand(
                id, command, productTextField(value, "routeName"),
                productTextField(value, "arguments")
            )
            case "set_fast_mode" =>
                let enabled = productBoolField(value, "enabled")
                match (session.setFastMode(enabled)) {
                    case Result.Ok(active) => success(
                        id,
                        command,
                        data: objectValue(
                            [
                                ValueField("enabled", boolValue(session.fastModeEnabled())),
                                ValueField("active", boolValue(active))
                            ]
                        )
                    )
                    case Result.Err(error) => failure(id, command, error.message)
                }
            case "set_todos" =>
                let phases = match (value.field("phases")) {
                    case Some(phases) => match (decodeTodoPhases(phases)) {
                        case Result.Ok(value) => value
                        case Result.Err(error) => return failure(
                            id,
                            command,
                            error.message
                        )
                    }
                    case None => return failure(
                        id,
                        command,
                        "todo phases are required"
                    )
                }
                match (session.replaceTodoPhases(phases)) {
                    case Result.Ok(response) =>
                        match(response.approval){
                            case Some(request)=>emitFrame(encodeAgentValue(productApprovalFrame(request)))
                            case None=>()}
                        let committed=if(response.approval.isNone()){
                            match(session.todoPhases()){case Result.Ok(value)=>encodeTodoPhases(value);case Result.Err(error)=>return failure(id,command,error.message)}
                        }else{nullValue()}
                        success(id,command,data:objectValue([
                            ValueField("todoPhases",committed),
                            ValueField("awaitingApproval",boolValue(response.approval.isSome())),
                            ValueField("output",textValue(response.text))]))
                    case Result.Err(error) => failure(id, command, error.message)
                }
            case "set_host_tools" => match (hostToolBridge().setTools(value)) {
                case Result.Ok(names) => success(
                    id,
                    command,
                    data: objectValue(
                        [
                            ValueField(
                                "toolNames",
                                stringListValue(names)
                            )
                        ]
                    )
                )
                case Result.Err(error) => failure(id, command, error.message)
            }
            case "set_host_uri_schemes" => match (hostUriBridge().setSchemes(value)) {
                case Result.Ok(schemes) => success(
                    id,
                    command,
                    data: objectValue(
                        [
                            ValueField(
                                "schemes",
                                stringListValue(schemes)
                            )
                        ]
                    )
                )
                case Result.Err(error) => failure(id, command, error.message)
            }
            case "set_subagent_subscription" =>
                let level = productTextField(value, "level")
                if (level != "off" && level != "progress" && level != "events") {
                    failure(
                        id,
                        command,
                        "Invalid subagent subscription level: " + level
                    )
                } else {
                    setSubagentSubscription(level)
                    success(id, command, data: objectValue([ValueField("level", textValue(level))]))
                }
            case "get_subagents" => success(
                id,
                command,
                data: objectValue(
                    [
                        ValueField(
                            "subagents",
                            subagentSnapshotsValue(session.subagents())
                        )
                    ]
                )
            )
            case "get_subagent_messages" =>
                let fromItem = productIntegerField(value, "fromItem")
                if (fromItem < 0) {
                    failure(
                        id,
                        command,
                        "fromItem must be a finite number"
                    )
                } else {
                    match (session.subagentTranscript(
                        subagentId: productTextField(
                            value,
                            "subagentId"
                        ),
                        sessionRef: productTextField(
                            value,
                            "sessionRef"
                        ),
                        fromItem: fromItem
                    )) {
                        case Result.Ok(transcript) => success(
                            id,
                            command,
                            data: subagentTranscriptValue(transcript)
                        )
                        case Result.Err(error) => failure(id, command, error.message)
                    }
                }
            case "set_model" =>
                let provider = productTextField(value, "provider")
                let model = productTextField(value, "modelId")
                match (session.resolveModel(provider, model)) {
                    case Result.Ok(resolved) => match (session.selectModel(resolved)) {
                        case Result.Ok(_) => success(
                            id,
                            command,
                            data: modelValueFor(resolved)
                        )
                        case Result.Err(error) => failure(id, command, error.message)
                    }
                    case Result.Err(error) => failure(id, command, error.message)
                }
            case "cycle_model" => cycleModel(id, command)
            case "get_available_models" => success(id, command, data: objectValue([ValueField("models", modelValues())]))
            case "set_thinking_level" => setThinkingLevel(
                id,
                command,
                productTextField(value, "level")
            )
            case "cycle_thinking_level" => cycleThinkingLevel(id, command)
            case "set_steering_mode" => applyQueueMode(
                id,
                command,
                productTextField(value, "mode"),
                0
            )
            case "set_follow_up_mode" => applyQueueMode(
                id,
                command,
                productTextField(value, "mode"),
                1
            )
            case "set_interrupt_mode" => applyQueueMode(
                id,
                command,
                productTextField(value, "mode"),
                2
            )
            case "compact" => applicationReply(
                id,
                command,
                session.handle("/compact")
            )
            case "set_auto_compaction" =>
                let enabled = productBoolField(value, "enabled")
                session.setAutoCompaction(enabled)
                success(id, command, data: objectValue([ValueField("enabled", boolValue(enabled))]))
            case "set_auto_retry" =>
                let enabled = productBoolField(value, "enabled")
                session.setAutoRetry(enabled)
                success(id, command, data: objectValue([ValueField("enabled", boolValue(enabled))]))
            case "abort_retry" =>
                session.abortRetry()
                success(id, command)
            case "bash" => startBash(id, command, productTextField(value, "command"))
            case "abort_bash" => match (session.abortBash()) {
                case Result.Ok(_) => success(id, command)
                case Result.Err(error) => failure(id, command, error.message)
            }
            case "get_session_stats" => sessionStats(id, command)
            case "export_html" => exportHtml(
                id,
                command,
                productTextField(value, "outputPath")
            )
            case "switch_session" => switchSession(
                id,
                command,
                productTextField(value, "sessionPath")
            )
            case "branch" => branchSession(
                id,
                command,
                productTextField(value, "entryId")
            )
            case "get_branch_messages" => branchMessagesReply(id, command)
            case "get_messages" => messagesReply(id, command)
            case "get_last_assistant_text" => lastAssistantReply(id, command)
            case "set_session_name" => setSessionName(
                id,
                command,
                productTextField(value, "name")
            )
            case "handoff" => handoff(
                id,
                command,
                productTextField(value, "customInstructions")
            )
            case "get_messages_page" => messagesPage(id, command, value)
            case "get_login_providers" =>
                let providers = ArrayList<AgentValue>()
                for (profile in session.providers()) {
                    providers.add(
                        objectValue(
                            [
                                ValueField("id", textValue(profile.id)),
                                ValueField("name", textValue(profile.provider)),
                                ValueField(
                                    "available",
                                    boolValue(session.providerAvailable(profile.id))
                                ),
                                ValueField(
                                    "authenticated",
                                    boolValue(session.providerAuthenticated(profile.id))
                                )
                            ]
                        )
                    )
                }
                success(id, command, data: objectValue([ValueField("providers", listValue(providers.toArray()))]))
            case "login" =>
                let providerId = productTextField(value, "providerId")
                if (providerId == "") {
                    failure(id, command, "providerId is required")
                } else {
                    match (session.loginProvider(providerId)) {
                        case Result.Ok(_) => success(
                            id,
                            command,
                            data: objectValue(
                                [
                                    ValueField(
                                        "providerId",
                                        textValue(providerId)
                                    )
                                ]
                            )
                        )
                        case Result.Err(error) => failure(id, command, error.message)
                    }
                }
            case "negotiate_interactions" => negotiateInteractions(id, command, value)
            case "interaction_response" => interactionResponse(id, command, value)
            case "negotiate_protocol" =>
                if (productIntegerField(value, "protocolVersion") == 2) {
                    frameLock.lock()
                    try {
                        protocolVersion = 2
                    } finally {
                        frameLock.unlock()
                    }
                    success(id, command, data: objectValue([ValueField("protocolVersion", integerValue(2))]))
                } else {
                    failure(
                        id,
                        command,
                        "only protocol version 2 can be negotiated"
                    )
                }
            case _ => failure("", command, "unknown RPC command")
        }
    }

    // Caller holds the existing short server lock. No source, receipt or
    // resource refund is created by this physical-return check.
    private func runWorkerReturnedLocked113(): Bool {
        if (runWorkerStartingFailed113 || pluginCommandStartingFailed113 || workerPaymentFailed113) { return false }
        rpcWorkerReturned113(runWorker113) && rpcWorkerReturned113(pluginCommandWorker)
    }

    private func reserveWorkerMetadataLocked113(peak: Int64): ?LogicalJsonOwnerReservation {
        try {
            if (workerMetadata113.isNone()) {
                workerMetadata113 = Some(reserveProductControlMetadata113(4096))
            }
            let child = workerMetadata113.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(peak); Some(child) }
            catch (_: Exception) { child.close(); None<LogicalJsonOwnerReservation> }
        } catch (_: Exception) { None<LogicalJsonOwnerReservation> }
    }

    // These helpers return ONLY a reservation, after the observed Future and
    // its retained action have been removed from all server fields.
    private func takeReturnedRunMetadataLocked113(): ?LogicalJsonOwnerReservation {
        if (runWorkerStartingFailed113 || !rpcWorkerReturned113(runWorker113)) {
            return None<LogicalJsonOwnerReservation>
        }
        runWorker113 = None<Future<Unit>>
        let paid = runWorkerMetadata113
        runWorkerMetadata113 = None<LogicalJsonOwnerReservation>
        runWorkerBasePeak113 = 0; queuedWorkerPeak113 = 0
        match (queuedInputCustody113) {
            case Some(source) => if (paid.isSome() && refEq(source.payment, paid.getOrThrow())) {
                return None<LogicalJsonOwnerReservation> }
            case None => () }
        paid
    }
    private func takeReturnedCommandMetadataLocked113(): ?LogicalJsonOwnerReservation {
        if (pluginCommandStartingFailed113 || !rpcWorkerReturned113(pluginCommandWorker)) {
            return None<LogicalJsonOwnerReservation>
        }
        pluginCommandWorker = None<Future<Unit>>
        let paid = commandWorkerMetadata113
        commandWorkerMetadata113 = None<LogicalJsonOwnerReservation>
        paid
    }
    private func retireReturnedWorkerMetadataLocked113(): Unit {
        // A joining close frame may still retain a Future/holder snapshot.
        if (workerJoinFrames113 != 0 || workerPaymentFailed113) { return }
        rpcCloseWorkerMetadata113(takeRetiredQueuedSource113())
        rpcCloseWorkerMetadata113(takeReturnedRunMetadataLocked113())
        rpcCloseWorkerMetadata113(takeReturnedCommandMetadataLocked113())
    }

    private func startRunWorkerLocked113(paid: LogicalJsonOwnerReservation,
        peak: Int64, action: () -> Unit): Unit {
        runWorkerMetadata113 = Some(paid)
        runWorkerBasePeak113 = peak; queuedWorkerPeak113 = 0
        // Mark debt BEFORE spawn. A throwing/unknown spawn remains closed.
        // Its actual Future is registered before unlocking the short gate.
        runWorkerStartingFailed113 = true
        runWorker113 = Some(spawn { action() })
        runWorkerStartingFailed113 = false
    }

    public func beginRunWorkerShutdown113(): Unit {
        lock.lock(); try { closing = true } finally { lock.unlock() }
    }

    // Nonblocking. The existing Main has no finite exit deadline. A concrete
    // frontend exit policy and cancellation/waiting remain a separate change;
    // this DATA query neither invents a timeout nor starts or ACKs a Run.
    public func collectRunWorkerRetirement113(): Bool {
        lock.lock()
        try {
            // closing is a gate, not evidence that any callback returned.
            if (!closing || workerJoinFrames113 != 0 || !runWorkerReturnedLocked113()) { return false }
            if (!allBashWorkersReturnedLocked113()) { return false }
            rpcCloseWorkerMetadata113(takeRetiredQueuedSource113())
            if (queuedInputCustody113.isSome()) { return false }
            // takeRetiredWorkerRoot drops every Future/action/holder/list in a
            // separate frame. Only the real allocation survives its return.
            rpcCloseWorkerMetadata113(takeRetiredWorkerRootLocked113())
            true
        } finally { lock.unlock() }
    }

    private func allBashWorkersReturnedLocked113(): Bool {
        match (bashWorkers) {
            case None => true
            case Some(workers) =>
                for (worker in workers) {
                    if (!worker.rejectedFrameReturned113 && (worker.future.isNone() || !rpcWorkerReturned113(worker.future))) { return false }
                }
                true
        }
    }
    private func takeReturnedBashMetadataLocked113(index: Int64): ?LogicalJsonOwnerReservation {
        let workers = bashWorkers.getOrThrow()
        let worker = workers[index]
        if (!worker.rejectedFrameReturned113 && (worker.future.isNone() || !rpcWorkerReturned113(worker.future))) {
            return None<LogicalJsonOwnerReservation>
        }
        worker.future = None<Future<Unit>>
        let paid = worker.metadata113
        worker.metadata113 = None<LogicalJsonOwnerReservation>
        workers.remove(at: index)
        paid
    }
    private func takeRetiredWorkerRootLocked113(): ?LogicalJsonOwnerReservation {
        retireReturnedWorkerMetadataLocked113()
        match (bashWorkers) {
            case Some(workers) =>
                while (!workers.isEmpty()) { rpcCloseWorkerMetadata113(takeReturnedBashMetadataLocked113(0)) }
            case None => ()
        }
        // Clearing a list alone can retain its backing array. Drop that real
        // container too, before the physical shared root may be released.
        bashWorkers = None<ArrayList<RpcBashWorker>>
        let paid = workerMetadata113
        workerMetadata113 = None<LogicalJsonOwnerReservation>
        paid
    }

    private func startPrompt(id: String, command: String, message: String): Bool {
        lock.lock()
        try {
            if (closing || running || session.approval().isSome() || !runWorkerReturnedLocked113()) {
                return false
            }
            retireReturnedWorkerMetadataLocked113()
            let peak = rpcWorkerInputPeak113(id, command, message)
            let paid = match (reserveWorkerMetadataLocked113(peak)) {
                case Some(value) => value; case None => return false }
            // Funding precedes BOTH the prompt object and the action closure.
            let prompt = RpcPrompt(id, command, message)
            running = true
            startRunWorkerLocked113(paid, peak, { => runPrompts(prompt) })
            true
        } finally { lock.unlock() }
    }

    private func pluginCommandsValue(): AgentValue {
        let commands = ArrayList<AgentValue>()
        for (command in session.javascriptPluginCommands()) {
            commands.add(objectValue([
                ValueField("routeName", textValue(command.routeName)),
                ValueField("name", textValue(command.name)),
                ValueField("description", textValue(command.description))
            ]))
        }
        objectValue([ValueField("commands", listValue(commands.toArray()))])
    }

    private func startPluginCommand(
        id: String,
        command: String,
        routeName: String,
        arguments: String
    ): String {
        if (id.trimAscii() == "" || routeName.trimAscii() == "" ||
            routeName.size > 256 || arguments.size > 1048576) {
            return failure(id, command, "plugin command identity or arguments are invalid")
        }
        var registered = false
        for (candidate in session.javascriptPluginCommands()) {
            if (candidate.routeName == routeName) { registered = true; break }
        }
        if (!registered) { return failure(id, command, "plugin command is not registered") }
        lock.lock()
        let accepted = try {
            if (closing || running || activePluginCommandRequestId != "" ||
                session.approval().isSome() || !runWorkerReturnedLocked113()) {
                false
            } else {
                retireReturnedWorkerMetadataLocked113()
                let peak = rpcWorkerInputPeak113(id, routeName, arguments)
                let paid = match (reserveWorkerMetadataLocked113(peak)) {
                    case Some(value) => value; case None => return failure(id, command, "RPC worker metadata capacity is exhausted") }
                commandWorkerMetadata113 = Some(paid)
                activePluginCommandRequestId = id
                running = true
                pluginCommandStartingFailed113 = true
                pluginCommandWorker = Some(spawn {
                    runPluginCommand(id, routeName, arguments)
                })
                pluginCommandStartingFailed113 = false
                true
            }
        } finally {
            lock.unlock()
        }
        if (!accepted) {
            return failure(id, command, "RPC server is busy or another command is active")
        }
        success(id, command, data: objectValue([
            ValueField("accepted", boolValue(true))
        ]))
    }

    private func runPluginCommand(
        id: String,
        routeName: String,
        arguments: String
    ): Unit {
        let result = session.invokeJavaScriptPluginCommand(
            routeName, arguments, {noticeType, message =>
                emitFrame(encodeAgentValue(objectValue([
                    ValueField("type", textValue("plugin_notice")),
                    ValueField("requestId", textValue(id)),
                    ValueField("routeName", textValue(routeName)),
                    ValueField("noticeType", textValue(noticeType)),
                    ValueField("message", textValue(message))
                ])))
            }
        )
        lock.lock()
        try {
            if (activePluginCommandRequestId == id) {
                activePluginCommandRequestId = ""
                running = false
            }
        } finally {
            lock.unlock()
        }
        match (result) {
            case Result.Ok(_) => match (session.approval()) {
                case Some(approval) => emitFrame(encodeAgentValue(productApprovalFrame(approval)))
                case None => emitFrame(encodeAgentValue(objectValue([
                ValueField("type", textValue("plugin_command_completed")),
                ValueField("requestId", textValue(id)),
                ValueField("routeName", textValue(routeName)),
                ValueField("ok", boolValue(true))
            ]))) }
            case Result.Err(error) => emitFrame(encodeAgentValue(objectValue([
                ValueField("type", textValue("plugin_command_completed")),
                ValueField("requestId", textValue(id)),
                ValueField("routeName", textValue(routeName)),
                ValueField("ok", boolValue(false)),
                ValueField("error", textValue(error.message)),
                ValueField("code", textValue(error.code))
            ])))
        }
    }

    private func queueInteraction(
        kind: String,
        message: String
    ): Result<Unit> {
        lock.lock()
        try {
            if (closing) { return ownedRpcOutputError("rpc.server_closing") }
            if (activePluginCommandRequestId != "") {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "plugin.command_active",
                    "steering cannot be queued while a plugin command is active"
                ))
            }
            if (running || session.approval().isSome()) {
                return session.enqueue("", kind, message)
            }
            // Do not accept a message after the old safe-boundary dequeue
            // has ended while its callback/Future is still returning.
            if (!runWorkerReturnedLocked113()) { return ownedRpcOutputError("rpc.prior_worker_pending") }
            retireReturnedWorkerMetadataLocked113()
            let peak = rpcWorkerInputPeak113("", kind, message)
            let paid = match (reserveWorkerMetadataLocked113(peak)) {
                case Some(value) => value; case None => return ownedRpcOutputError("rpc.worker_metadata_capacity") }
            running = true
            startRunWorkerLocked113(paid, peak, { =>
                runPrompts(RpcPrompt("", kind, message, publishResult: false))
            })
            Result.Ok(())
        } finally { lock.unlock() }
    }

    private func scheduleDeferred(id: String, command: String, message: String): Bool {
        lock.lock()
        try {
            if (closing) { return false }
            if (running || session.approval().isSome()) {
                return session.enqueue(id, command, message).isOk()
            }
            if (!runWorkerReturnedLocked113()) { return false }
            retireReturnedWorkerMetadataLocked113()
            let peak = rpcWorkerInputPeak113(id, command, message)
            let paid = match (reserveWorkerMetadataLocked113(peak)) {
                case Some(value) => value; case None => return false }
            // Funding precedes BOTH the prompt object and the action closure.
            let prompt = RpcPrompt(id, command, message)
            running = true
            startRunWorkerLocked113(paid, peak, { => runPrompts(prompt) })
            true
        } finally { lock.unlock() }
    }

    private func runRpcQueuedInput113(value: QueuedInteraction): Result<ApplicationResponse> {
        lock.lock()
        let source = try {
            if (queuedInputCustody113.isSome()) { throw IllegalStateException("rpc.previous_queued_source_pending") }
            let paid = runWorkerMetadata113.getOrThrow()
            let inputPeak = rpcWorkerAdd113(runWorkerBasePeak113, rpcWorkerAdd113(queuedWorkerPeak113, queuedWorkerPeak113))
            paid.ensureRetainedPeak(rpcWorkerAdd113(inputPeak, 65536))
            let actual = RpcQueuedRetainedInput113(value, paid, inputPeak)
            queuedInputCustody113 = Some(actual)
            actual
        } finally { lock.unlock() }
        try {
            let origin = match (session.prepareRpcQueuedInitiator113(value, { bytes =>
                try {
                    if (bytes > (Int64.Max - 65536) / 64) { return ownedRpcOutputError("rpc.queued_extent_overflow") }
                    source.payment.ensureRetainedPeak(rpcWorkerAdd113(source.inputPeak, 65536 + bytes * 64))
                    Result<Unit>.Ok(())
                } catch (_: Exception) { ownedRpcOutputError("rpc.queued_metadata_capacity") }
            })) {
                case Result.Ok(actual) => actual
                case Result.Err(error) =>
                    source.capturePrimary(error); source.uncertain = true
                    lock.lock(); try { workerPaymentFailed113 = true; closing = true } finally { lock.unlock() }
                    return Result<ApplicationResponse>.Err(error) }
            source.origin = Some(origin)
            let result = session.handleRpcQueuedAtReturnedBoundary113(value, origin,
                { bytes => source.allocate(bytes) }, { error => source.capturePrimary(error) }, source.payment,
                { cell => source.retainStoreCell113(cell) })
            // The WHOLE synchronous App/Store helper has now returned.
            source.retireReturnedStoreCells113()
            result
        } catch (failure: RpcQueuedStoreFailure113) {
            source.admitStoreFailure113(failure); source.uncertain = true
            lock.lock(); try { workerPaymentFailed113 = true; closing = true } finally { lock.unlock() }
            Result<ApplicationResponse>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "rpc.queued_settlement_pending", "the original queued SQL producer remains held for recovery"))
        } catch (failure: OwnedCanonicalPaidFailure113) {
            // Move before a fallible gate; neither the primary nor this full
            // secondary can disappear because another callback returned.
            source.secondary = Some(failure.takeConsumer()); source.uncertain = true
            lock.lock(); try { workerPaymentFailed113 = true; closing = true } finally { lock.unlock() }
            Result<ApplicationResponse>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "rpc.queued_settlement_pending", "the original queued input needs paid settlement recovery"))
        } catch (error: Exception) {
            source.unknown = Some(error); source.uncertain = true
            lock.lock(); try { workerPaymentFailed113 = true; closing = true } finally { lock.unlock() }
            throw error
        }
    }

    // Return only the lease after this helper's node/data locals disappear.
    // An active current worker continues to pay its original/current aliases.
    private func takeRetiredQueuedSource113(): ?LogicalJsonOwnerReservation {
        let source = match (queuedInputCustody113) {
            case None => return None<LogicalJsonOwnerReservation>; case Some(value) => value }
        if (source.uncertain || source.secondary.isSome() || source.origin.isNone()) {
            return None<LogicalJsonOwnerReservation> }
        try {
            let done = session.rpcQueuedReferencesRetired113(source.origin.getOrThrow(),
                { bytes => source.allocate(bytes) }, { cell => source.retainStoreCell113(cell) })
            // Same whole-helper-return witness, also when the SQL says nonterminal.
            source.retireReturnedStoreCells113()
            if (!done) { return None<LogicalJsonOwnerReservation> }
        } catch (failure: RpcQueuedStoreFailure113) {
            source.admitStoreFailure113(failure); source.uncertain = true
            workerPaymentFailed113 = true; closing = true
            return None<LogicalJsonOwnerReservation>
        } catch (failure: OwnedCanonicalPaidFailure113) {
            source.secondary = Some(failure.takeConsumer()); source.uncertain = true
            workerPaymentFailed113 = true; closing = true
            return None<LogicalJsonOwnerReservation>
        } catch (failure: Exception) {
            source.unknown = Some(failure); source.uncertain = true
            workerPaymentFailed113 = true; closing = true
            return None<LogicalJsonOwnerReservation>
        }
        match (source.primary) {
            case Some(consumer) => if (!consumer.isAcknowledged()) { return None<LogicalJsonOwnerReservation> }
            case None => () }
        let paid = source.payment
        queuedInputCustody113 = None<RpcQueuedRetainedInput113>
        if (runWorkerMetadata113.isSome() && refEq(runWorkerMetadata113.getOrThrow(), paid)) {
            return None<LogicalJsonOwnerReservation> }
        Some(paid)
    }

    private func runPrompts(first: RpcPrompt): Unit {
        var current: ?RpcPrompt = Some(first)
        while (current.isSome()) {
            let prompt = current.getOrThrow()
            let result = match (prompt.queued113) {
                case Some(value) => runRpcQueuedInput113(value)
                case None => session.handle(prompt.message) }
            if (prompt.publishResult) {
                publishPromptResult(prompt, result)
            }
            current = takeNext(result)
        }
    }

    private func startDecision(decision: RpcDecision): Bool {
        lock.lock()
        try {
            if (closing || running || !runWorkerReturnedLocked113()) { return false }
            retireReturnedWorkerMetadataLocked113()
            let peak = rpcWorkerAdd113(rpcWorkerInputPeak113(decision.id, decision.command,
                decision.operationId), rpcWorkerDecisionPeak113(decision.decision))
            let paid = match (reserveWorkerMetadataLocked113(peak)) {
                case Some(value) => value; case None => return false }
            running = true
            startRunWorkerLocked113(paid, peak, { =>
                let result = session.decide(decision.operationId, decision.decision)
                publishDecision(decision, result)
                match (takeNext(result)) {
                    case Some(prompt) => runPrompts(prompt)
                    case None => ()
                }
            })
            true
        } finally { lock.unlock() }
    }

    private func publishDecision(
        decision: RpcDecision,
        result: Result<ApplicationResponse>
    ): Unit {
        match (result) {
            case Result.Err(error) =>
                if (!publishOwnedCheckpointFailure113(decision.id, decision.command, error)) {
                    emitFrame(failure(decision.id, decision.command, error.message))
                }
                match (session.approval()) { case Some(approval) => emitFrame(encodeAgentValue(productApprovalFrame(approval))); case None => () }
            case Result.Ok(response) => match (response.approval) {
                case Some(approval) => emitFrame(encodeAgentValue(productApprovalFrame(approval)))
                case None => ()
            }
        }
    }

    private func takeNext(result: Result<ApplicationResponse>): ?RpcPrompt {
        lock.lock()
        try {
            rpcCloseWorkerMetadata113(takeRetiredQueuedSource113())
            if (queuedInputCustody113.isSome()) { running = false; return None<RpcPrompt> }
        } finally { lock.unlock() }
        if (hasOwnedCheckpointFailureOutput113()) {
            lock.lock()
            try { running = false } finally { lock.unlock() }
            return None<RpcPrompt>
        }
        lock.lock()
        try {
            // Drain only entries accepted before closing. New external queue
            // admission is already closed under this same lock.
            let consumerPayment = runWorkerMetadata113.getOrThrow()
            let selected = session.takeRpcQueuedAtReturnedBoundaryWithDataPayment113(result, { bytes =>
                try {
                    // The first prompt remains captured by the actual Future.
                    // At a boundary, old current and next queued inputs can
                    // overlap. Two maximum live queued invoices cover both;
                    // completed sequential inputs do not accumulate forever.
                    let nextPeak = rpcWorkerExtentPeak113(bytes)
                    let maximum = max(queuedWorkerPeak113, nextPeak)
                    let total = rpcWorkerAdd113(runWorkerBasePeak113, rpcWorkerAdd113(maximum, maximum))
                    consumerPayment.ensureRetainedPeak(total)
                    queuedWorkerPeak113 = maximum
                    Result<Unit>.Ok(())
                } catch (_: Exception) { ownedRpcOutputError("rpc.worker_metadata_capacity") }
            })
            let queued = match (selected) {
                case Result.Ok(value) => value
                case Result.Err(_) =>
                    // The exact queue entry was NOT removed. Physical return
                    // alone cannot retire its unpaid admission or permit retry.
                    workerPaymentFailed113 = true; closing = true; running = false
                    return None<RpcPrompt>
            }
            match (queued) {
                case Some(next) => Some(
                    RpcPrompt(
                        next.correlationId,
                        next.kind,
                        next.input, queued113: Some(next)
                    )
                )
                case None =>
                    running = false
                    None
            }
        } finally {
            lock.unlock()
        }
    }

    private func publishQueuedFailure113(prompt: RpcPrompt): Bool {
        let source = match (queuedInputCustody113) { case Some(value) => value; case None => return false }
        if (prompt.queued113.isNone() || !refEq(prompt.queued113.getOrThrow(), source.value)) { return false }
        let consumer = match (source.primary) {
            case Some(value) => value
            case None => match (source.secondary) {
                case Some(value) => value
                case None =>
                    // Exact input recognition is independent of fallible
                    // full-consumer capture. Keep original raw/cell debt;
                    // no synthetic short response, ACK or gate retirement.
                    unadmittedFailure113.store(true)
                    return true } }
        let extra = if (source.primary.isSome()) { source.secondary } else { None<OwnedFailureDataConsumer113> }
        frameLock.lock()
        try {
            if (!source.primaryRegistered) {
                match (rpcPrepareQueuedFailureData113(consumer, extra, prompt.id, prompt.command, protocolVersion)) {
                    case Result.Err(_) => unadmittedFailure113.store(true)
                    case Result.Ok(value) =>
                        ownedFailureDeliveries113.append(value)
                        source.primaryRegistered = true
                }
            }
        } finally { frameLock.unlock() }
        collectOwnedCheckpointFailures113()
        // Recognition is not ACK. A refused or unsupported output keeps the
        // exact primary and source node paid, with no short second response.
        true
    }

    private func publishPromptResult(
        prompt: RpcPrompt,
        result: Result<ApplicationResponse>
    ): Unit {
        match (result) {
            case Result.Err(error) =>
                if (!publishQueuedFailure113(prompt) && !publishOwnedCheckpointFailure113(prompt.id, prompt.command, error)) {
                    emitFrame(failure(prompt.id, prompt.command, error.message))
                }
            case Result.Ok(response) =>
                if (!response.agentInvoked && response.text != "") {
                    emitFrame(
                        encodeAgentValue(
                            objectValue(
                                [
                                    ValueField(
                                        "type",
                                        textValue("command_output")
                                    ),
                                    ValueField("id", textValue(prompt.id)),
                                    ValueField("output", textValue(response.text))
                                ]
                            )
                        )
                    )
                }
                match (response.approval) {
                    case Some(approval) => emitFrame(encodeAgentValue(productApprovalFrame(approval)))
                    case None => ()
                }
                emitFrame(
                    encodeAgentValue(
                        objectValue(
                            [
                                ValueField("type", textValue("prompt_result")),
                                ValueField("id", textValue(prompt.id)),
                                ValueField(
                                    "agentInvoked",
                                    boolValue(response.agentInvoked)
                                )
                            ]
                        )
                    )
                )
        }
    }

    private func cycleModel(id: String, command: String): String {
        let models = session.models()
        if (models.isEmpty()) {
            return failure(id, command, "no models are available")
        }
        var next = models[0]
        for (index in 0..models.size) {
            if (models[index] == session.model()) {
                next = models[(index + 1) % models.size]
                break
            }
        }
        match (session.selectModel(next)) {
            case Result.Ok(_) => success(
                id,
                command,
                data: objectValue(
                    [
                        ValueField("model", modelValueFor(next)),
                        ValueField("thinkingLevel", textValue(thinkingLevel)),
                        ValueField("isScoped", boolValue(false))
                    ]
                )
            )
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func modelValues(): AgentValue {
        let values = ArrayList<AgentValue>()
        for (model in session.models()) {
            values.add(modelValueFor(model))
        }
        listValue(values.toArray())
    }

    private func modelValueFor(model: String): AgentValue {
        modelValue(
            session.modelProvider(model),
            session.rawModelId(model),
            session.modelMetadata(model)
        )
    }

    private func setThinkingLevel(
        id: String,
        command: String,
        level: String
    ): String {
        if (!validThinkingLevel(level)) {
            return failure(id, command, "invalid thinking level")
        }
        session.setThinking(thinkingLevelValue(level))
        thinkingLevel = level
        success(id, command)
    }

    private func cycleThinkingLevel(
        id: String,
        command: String
    ): String {
        let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        var next = levels[0]
        for (index in 0..levels.size) {
            if (levels[index] == thinkingLevel) {
                next = levels[(index + 1) % levels.size]
                break
            }
        }
        session.setThinking(thinkingLevelValue(next))
        thinkingLevel = next
        success(id, command, data: objectValue([ValueField("level", textValue(next))]))
    }

    private func applyQueueMode(
        id: String,
        command: String,
        mode: String,
        target: Int64
    ): String {
        let valid = if (target == 2) {
            mode == "immediate" || mode == "wait"
        } else {
            mode == "all" || mode == "one-at-a-time"
        }
        if (!valid) {
            return failure(id, command, "invalid queue mode")
        }
        if (target == 0) {
            steeringMode = mode
            session.setSteeringMode(queueDeliveryMode(mode))
        } else if (target == 1) {
            followUpMode = mode
            session.setFollowUpMode(queueDeliveryMode(mode))
        } else {
            interruptMode = mode
            session.setInterruptMode(if (mode == "wait") {
                RunInterruptMode.Wait
            } else {
                RunInterruptMode.Immediate
            })
        }
        success(id, command, data: objectValue([ValueField("mode", textValue(mode))]))
    }

    private func hostToolBridge(): RpcHostToolBridge {
        hostTools.getOrThrow()
    }

    private func hostUriBridge(): RpcHostUriBridge {
        hostUris.getOrThrow()
    }

    private func interactionProfileEnabled(): Bool {
        lock.lock()
        try {
            interactionProfile == "basic-v1" && !closing
        } finally {
            lock.unlock()
        }
    }

    private func negotiateInteractions(
        id: String,
        command: String,
        value: AgentValue
    ): String {
        let profile = match (rpcInteractionText(value, "profile")) {
            case Some(item) => item
            case None => return failure(id, command, "profile must be 'basic-v1' or 'none'")
        }
        if (profile != "basic-v1" && profile != "none") {
            return failure(id, command, "profile must be 'basic-v1' or 'none'")
        }
        lock.lock()
        try {
            if (closing) { return failure(id, command, "RPC server is closing") }
            interactionProfile = profile
        } finally {
            lock.unlock()
        }
        session.setAskInteractive(profile == "basic-v1")
        success(id, command, data: objectValue([
            ValueField("interactionProfile", textValue(profile))
        ]))
    }

    private func publishInteractionRequest(request: ProductAskRequest): Unit {
        if (!interactionProfileEnabled()) { return }
        let questions = ArrayList<AgentValue>()
        for (question in request.questions) {
            questions.add(rpcInteractionQuestionValue(question))
        }
        emitFrame(encodeAgentValue(objectValue([
            ValueField("type", textValue("interaction_request")),
            ValueField("interactionId", textValue(request.requestId)),
            ValueField("interactionKind", textValue(request.interactionKind)),
            ValueField("runId", textValue(request.runId)),
            ValueField("sessionId", textValue(request.sessionId.value)),
            ValueField("operationId", textValue(request.operationId)),
            ValueField("commandId", textValue(request.commandId)),
            ValueField("callId", textValue(request.callId)),
            ValueField("epoch", integerValue(request.epoch)),
            ValueField("questions", listValue(questions.toArray()))
        ])))
    }

    private func interactionResponse(
        id: String,
        command: String,
        value: AgentValue
    ): String {
        if (!interactionProfileEnabled()) {
            return failure(id, command, "basic-v1 interactions have not been negotiated")
        }
        let request = match (session.pendingAsk()) {
            case Some(item) => item
            case None => return failure(id, command, "there is no pending interaction")
        }
        let interactionId = match (rpcInteractionText(value, "interactionId")) {
            case Some(item) => item
            case None => return failure(id, command, "interactionId must be a string")
        }
        let runId = match (rpcInteractionText(value, "runId")) {
            case Some(item) => item
            case None => return failure(id, command, "runId must be a string")
        }
        let sessionId = match (rpcInteractionText(value, "sessionId")) {
            case Some(item) => item
            case None => return failure(id, command, "sessionId must be a string")
        }
        let operationId = match (rpcInteractionText(value, "operationId")) {
            case Some(item) => item
            case None => return failure(id, command, "operationId must be a string")
        }
        let commandId = match (rpcInteractionText(value, "commandId")) {
            case Some(item) => item
            case None => return failure(id, command, "commandId must be a string")
        }
        let callId = match (rpcInteractionText(value, "callId")) {
            case Some(item) => item
            case None => return failure(id, command, "callId must be a string")
        }
        let interactionKind = match (rpcInteractionText(value, "interactionKind")) {
            case Some(item) => item
            case None => return failure(id, command, "interactionKind must be a string")
        }
        let epoch = match (rpcInteractionInteger(value, "epoch")) {
            case Some(item) => item
            case None => return failure(id, command, "epoch must be an integer")
        }
        if (interactionId != request.requestId || runId != request.runId ||
            sessionId != request.sessionId.value || operationId != request.operationId ||
            commandId != request.commandId || callId != request.callId ||
            interactionKind != request.interactionKind || epoch != request.epoch) {
            return failure(id, command, "interaction identity does not match the pending request")
        }
        let cancelled = match (rpcInteractionBoolean(value, "cancelled")) {
            case Some(item) => item
            case None => return failure(id, command, "cancelled must be a boolean")
        }
        if (cancelled) {
            return answerInteraction(id, command, request.requestId, ProductAskResolution.Cancelled)
        }
        if (request.interactionKind == "select" && request.questions.size == 1) {
            let choice = match (rpcInteractionText(value, "choice")) {
                case Some(item) => item
                case None => return failure(id, command, "choice must be a string")
            }
            let question = request.questions[0]
            let answer = ProductAskAnswer(question.id, selectedOptions: [choice])
            return answerInteraction(
                id, command, request.requestId, ProductAskResolution.Answers([answer])
            )
        }
        if (request.interactionKind == "confirm" && request.questions.size == 1) {
            let confirmed = match (rpcInteractionBoolean(value, "confirmed")) {
                case Some(item) => item
                case None => return failure(id, command, "confirmed must be a boolean")
            }
            let question = request.questions[0]
            let answer = ProductAskAnswer(
                question.id, selectedOptions: [if (confirmed) { "Yes" } else { "No" }]
            )
            return answerInteraction(
                id, command, request.requestId, ProductAskResolution.Answers([answer])
            )
        }
        if (request.interactionKind == "ask") {
            let rawAnswers = match (value.field("answers")) {
                case Some(item) => item
                case None => return failure(id, command, "answers must be an array")
            }
            if (rawAnswers.unifiedKind != ValueKind.List ||
                rawAnswers.items.size != request.questions.size) {
                return failure(id, command, "answers must match the pending question count")
            }
            let answers = ArrayList<ProductAskAnswer>()
            for (index in 0..request.questions.size) {
                let rawAnswer = rawAnswers.items[index]
                if (rawAnswer.unifiedKind != ValueKind.Object) {
                    return failure(id, command, "each answer must be an object")
                }
                let answerId = match (rpcInteractionText(rawAnswer, "id")) {
                    case Some(item) => item
                    case None => return failure(id, command, "answer id must be a string")
                }
                let selected = match (rpcInteractionStringList(rawAnswer, "selectedOptions")) {
                    case Some(item) => item
                    case None => return failure(id, command, "selectedOptions must be an array of strings")
                }
                let customInput = match (rpcOptionalInteractionText(rawAnswer, "customInput")) {
                    case Result.Ok(item) => item
                    case Result.Err(error) => return failure(id, command, error.message)
                }
                let note = match (rpcOptionalInteractionText(rawAnswer, "note")) {
                    case Result.Ok(item) => item
                    case Result.Err(error) => return failure(id, command, error.message)
                }
                let timedOut = match (rpcOptionalInteractionBoolean(rawAnswer, "timedOut")) {
                    case Result.Ok(item) => item
                    case Result.Err(error) => return failure(id, command, error.message)
                }
                answers.add(ProductAskAnswer(
                    answerId,
                    selectedOptions: selected,
                    customInput: customInput,
                    note: note,
                    timedOut: timedOut
                ))
            }
            return answerInteraction(
                id, command, request.requestId,
                ProductAskResolution.Answers(answers.toArray())
            )
        }
        failure(id, command, "pending interaction kind is unsupported by basic-v1")
    }

    private func answerInteraction(
        id: String,
        command: String,
        requestId: String,
        resolution: ProductAskResolution
    ): String {
        match (session.answerAsk(requestId, resolution)) {
            case Result.Ok(_) => success(id, command)
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    // Package-internal numbers from the actual server/ledger locks. This
    // read does not fund, join, admit or retire any work.
    func observedWorkerJoinState113(): (Int64, Int64, Int64, Int64, Int64) {
        lock.lock()
        try {
            let usage = match (workerMetadata113) {
                case Some(value) => value.retainedCustodyUsage113()
                case None => (0, 0, 0)
            }
            (workerJoinFrames113, workerSnapshotArrays113, usage[0], usage[1], usage[2])
        } finally { lock.unlock() }
    }

    // Package-only scalar read. Server/source/cell use their actual locks.
    // Only real Future.tryGet proves worker return; no read ACKs or retires.
    func observedQueuedSqlCustody113(): (Int64, Int64, Bool, Bool) {
        lock.lock()
        try {
            let cells = match (queuedInputCustody113) {
                case Some(actual) => actual.observedStoreCustody113()
                case None => (0, 0) }
            (cells[0], cells[1], rpcWorkerReturned113(runWorker113), unadmittedFailure113.load())
        } finally { lock.unlock() }
    }

    public func close(cancelBash!: Bool = true): Unit {
        // This caller owns a distinct share of the existing worker bank.
        // Payment precedes every snapshot/Future alias created by the helper.
        let join = beginWorkerJoin113()
        try { waitAcceptedWorkers113(cancelBash) }
        finally {
            // The complete wait frame (including its holder array and Future
            // locals) has returned or unwound; no snapshot escapes that frame.
            // Close only this join share before permitting worker retirement.
            rpcCloseWorkerMetadata113(join)
            lock.lock(); try { workerJoinFrames113-- } finally { lock.unlock() }
        }
        if (!collectRunWorkerRetirement113()) {
            throw IllegalStateException("rpc.worker_failure_cleanup_required")
        }
    }

    private func beginWorkerJoin113(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            closing = true
            if (workerJoinFrames113 == Int64.Max) {
                throw IllegalStateException("rpc.worker_metadata_overflow") }
            let root = match (workerMetadata113) {
                case Some(actual) => actual
                case None =>
                    // No worker root implies no retained worker to snapshot.
                    // Do not create a fresh root just to close an empty server.
                    if (runWorker113.isSome() || pluginCommandWorker.isSome() || bashWorkers.isSome() ||
                        runWorkerStartingFailed113 || pluginCommandStartingFailed113) {
                        throw IllegalStateException("rpc.worker_metadata_missing") }
                    workerJoinFrames113++
                    return None<LogicalJsonOwnerReservation>
            }
            let count = match (bashWorkers) { case Some(value) => value.size; case None => 0 }
            let peak = rpcWorkerJoinPeak113(count)
            // deriveRetainedLease adds THIS close's invoice to all concurrent
            // joins and worker children in the same original physical bank.
            let paid = root.deriveRetainedLease()
            try { paid.ensureRetainedPeak(peak) }
            catch (_: Exception) {
                paid.close()
                throw IllegalStateException("rpc.worker_metadata_capacity")
            }
            workerJoinFrames113++
            Some(paid)
        } finally { lock.unlock() }
    }

    private func waitAcceptedWorkers113(cancelBash: Bool): Unit {
        lock.lock()
        interactionProfile = "none"
        let commandActive = activePluginCommandRequestId != ""
        let commandWorker = pluginCommandWorker
        let promptWorker113 = runWorker113
        let unknownWorker113 = runWorkerStartingFailed113 || pluginCommandStartingFailed113
        // Admission is closed and joinFrames blocks retirement, so the exact
        // holder count cannot grow between the prepaid gate and this snapshot.
        let workers = try {
            match (bashWorkers) {
                case Some(value) =>
                    let actual = value.toArray()
                    // Count only a successfully allocated real snapshot.
                    if (workerSnapshotArrays113 < Int64.Max) { workerSnapshotArrays113++ }
                    Some(actual)
                case None => None<Array<RpcBashWorker>>
            }
        } finally { lock.unlock() }
        session.setAskInteractive(false)
        if (commandActive) { session.cancelJavaScriptPluginCommand() }
        if (cancelBash) { let _ = session.abortBash() }
        // The compatibility close retains its original wait outside the lock.
        // Main has no original finite exit window; a future frontend policy
        // must not confuse this method with a new product timeout.
        if (unknownWorker113) { throw IllegalStateException("rpc.worker_start_cleanup_required") }
        match (promptWorker113) {
            case Some(worker) => try { worker.get() }
                catch (_: Exception) { throw IllegalStateException("rpc.worker_failure_cleanup_required") }
            case None => ()
        }
        var failureMessage: ?String = None
        match (workers) {
            case Some(actual) => for (worker in actual) {
                if (worker.rejectedFrameReturned113) { continue }
                try { worker.future.getOrThrow().get() } catch (error: Exception) {
                    if (failureMessage.isNone()) { failureMessage = Some(error.message) }
                }
            }
            case None => ()
        }
        match (commandWorker) {
            case Some(worker) => try { worker.get() } catch (error: Exception) {
                if (failureMessage.isNone()) { failureMessage = Some(error.message) }
            }
            case None => ()
        }
        match (failureMessage) {
            case Some(message) => throw IllegalStateException(message)
            case None => ()
        }
    }

    private func startBash(id: String, command: String, source: String): String {
        lock.lock()
        try {
            let answer = startBashPaidFrameLocked113(id, command, source)
            // Only here have the real producer/helper/action frames returned.
            // The marking helper retains no holder alias after it returns.
            markReturnedBashRejectionsLocked113()
            answer
        } finally { lock.unlock() }
    }

    private func markReturnedBashRejectionsLocked113(): Unit {
        match (bashWorkers) {
            case Some(workers) => for (worker in workers) {
                if (worker.rejectedBeforeSpawn113) { worker.rejectedFrameReturned113 = true }
            }
            case None => ()
        }
    }

    private func startBashPaidFrameLocked113(id: String, command: String, source: String): String {
            if (closing) { return failure(id, command, "RPC server is closing") }
            if (workerJoinFrames113 != 0 || workerPaymentFailed113) {
                return failure(id, command, "RPC worker cleanup is pending") }
            if (bashWorkers.isSome()) {
                var index: Int64 = 0
                while (index < bashWorkers.getOrThrow().size) {
                    let complete = bashWorkers.getOrThrow()[index].rejectedFrameReturned113 ||
                        (bashWorkers.getOrThrow()[index].future.isSome() &&
                            rpcWorkerReturned113(bashWorkers.getOrThrow()[index].future))
                    if (complete) { rpcCloseWorkerMetadata113(takeReturnedBashMetadataLocked113(index)) }
                    else { index += 1 }
                }
            }
            let peak = rpcWorkerInputPeak113(id, command, source)
            let paid = match (reserveWorkerMetadataLocked113(peak)) {
                case Some(value) => value; case None => return failure(id, command, "RPC worker metadata capacity is exhausted") }
            let count = match (bashWorkers) { case Some(value) => value.size; case None => 0 }
            try { workerMetadata113.getOrThrow().ensureRetainedPeak(rpcWorkerListPeak113(rpcWorkerAdd113(count, 1))) }
            catch (_: Exception) { paid.close(); return failure(id, command, "RPC worker metadata capacity is exhausted") }
            if (bashWorkers.isNone()) { bashWorkers = Some(ArrayList<RpcBashWorker>()) }
            let owned = RpcBashWorker(paid)
            // Publish a holder before the actual producer can spawn. An
            // unexpected throw keeps future=None and therefore stays Held.
            bashWorkers.getOrThrow().add(owned)
            match (session.executeBashAsync(source, {result =>
                try { emitFrame(bashReply(id, command, result)) } finally {
                    lock.lock()
                    owned.completed = true
                    lock.unlock()
                }
            })) {
                case Result.Ok(worker) =>
                    owned.future = Some(worker)
                    ""
                // The actual Session producer returns Err only before its
                // spawn, while acquiring the canonical Bash invocation.
                case Result.Err(error) =>
                    // Known pre-spawn rejection has no physical producer.
                    // Keep this funded holder until the caller/helper frame
                    // returns; a later collector may retire the empty record.
                    owned.rejectedBeforeSpawn113 = true
                    failure(id, command, error.message)
            }
    }

    private func bashReply(
        id: String,
        command: String,
        execution: Result<ProcessResult>
    ): String {
        match (execution) {
            case Result.Ok(result) => success(
                id,
                command,
                data: objectValue(
                    [
                        ValueField(
                            "stdout",
                            textValue(result.stdout)
                        ),
                        ValueField(
                            "stderr",
                            textValue(result.stderr)
                        ),
                        ValueField("exitCode", integerValue(result.exitCode)),
                        ValueField("timedOut", boolValue(result.timedOut)),
                        ValueField("truncated", boolValue(result.truncated))
                    ]
                )
            )
            case Result.Err(error) =>
                if(error.code=="application.bash_approval_required"){
                    match(session.approval()){
                        case Some(approval)=>
                            emitFrame(encodeAgentValue(productApprovalFrame(approval)))
                            return success(id,command,data:objectValue([ValueField("awaitingApproval",boolValue(true)),
                                ValueField("operationId",textValue(approval.operationId.value))]))
                        case None=>()}}
                failureCode(id,command,error.code,error.message)
        }
    }

    private func sessionStats(id: String, command: String): String {
        let messages = match (session.messages()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return failure(id, command, error.message)
        }
        let usage = match (session.runStats()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return failure(id, command, error.message)
        }
        var userMessages: Int64 = 0
        var assistantMessages: Int64 = 0
        var toolResults: Int64 = 0
        var toolCalls: Int64 = 0
        for (message in messages) {
            if (message.role == ModelRole.Assistant) {
                assistantMessages += 1
            }
            var containsToolResult = false
            var containsUserContent = false
            for (block in message.blocks) {
                if (block.kind == ModelBlockKind.ToolCall) {
                    toolCalls += 1
                } else if (block.kind == ModelBlockKind.ToolResult) {
                    containsToolResult = true
                    toolResults += 1
                } else if (block.kind == ModelBlockKind.Text && block.text.trimAscii() != "") {
                    containsUserContent = true
                }
            }
            if (message.role == ModelRole.User && (!containsToolResult || containsUserContent)) {
                userMessages += 1
            }
        }
        let totalTokens = usage.inputTokens + usage.outputTokens
        success(
            id,
            command,
            data: objectValue(
                [
                    ValueField("sessionRef", textValue(session.sessionRef())),
                    ValueField("sessionId", textValue(session.id().value)),
                    ValueField("userMessages", integerValue(userMessages)),
                    ValueField(
                        "assistantMessages",
                        integerValue(assistantMessages)
                    ),
                    ValueField("toolCalls", integerValue(toolCalls)),
                    ValueField("toolResults", integerValue(toolResults)),
                    ValueField("totalMessages", integerValue(messages.size)),
                    ValueField(
                        "tokens",
                        objectValue(
                            [
                                ValueField("input", integerValue(usage.inputTokens)),
                                ValueField("output", integerValue(usage.outputTokens)),
                                ValueField("reasoning", integerValue(usage.reasoningTokens)),
                                ValueField("cacheRead", integerValue(usage.cacheReadTokens)),
                                ValueField("cacheWrite", integerValue(usage.cacheWriteTokens)),
                                ValueField("total", integerValue(totalTokens))
                            ]
                        )
                    ),
                    ValueField("premiumRequests", integerValue(0)),
                    ValueField("costMicros", match (usage.costMicros) {
                        case Some(value) => integerValue(value)
                        case None => nullValue()
                    }),
                    ValueField("cost", match (usage.costMicros) {
                        case Some(value) => numberValue(
                            (Float64(value) / 1000000.0).toString()
                        )
                        case None => nullValue()
                    }),
                    ValueField("lastRequest", objectValue([
                        ValueField("inputTokens", integerValue(usage.lastInputTokens)),
                        ValueField("outputTokens", integerValue(usage.lastOutputTokens)),
                        ValueField(
                            "durationMillis",
                            if (usage.lastRequestDurationMillis > 0) {
                                integerValue(usage.lastRequestDurationMillis)
                            } else {
                                nullValue()
                            }
                        ),
                        ValueField("outputTokensPerSecond", if (
                            usage.lastRequestDurationMillis > 0
                        ) {
                            numberValue(
                                (Float64(usage.lastOutputTokens) * 1000.0 /
                                    Float64(usage.lastRequestDurationMillis)).toString()
                            )
                        } else {
                            nullValue()
                        })
                    ]))
                ]
            )
        )
    }

    private func exportHtml(
        id: String,
        command: String,
        requested: String
    ): String {
        let path = if (requested == "") {
            "Axyndra-" + session.id().value + ".html"
        } else {
            requested
        }
        match (session.exportHtml(path)) {
            case Result.Ok(outputPath) => success(id, command,
                data: objectValue([ValueField("outputPath", textValue(outputPath))]))
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func switchSession(
        id: String,
        command: String,
        sessionPath: String
    ): String {
        if (sessionPath.trimAscii() == "") {
            return failure(id, command, "sessionPath is required")
        }
        let parts = sessionPath.split("/")
        var sessionId = parts[parts.size - 1]
        if (sessionId.endsWith(".jsonl")) {
            sessionId = sessionId.removeSuffix(".jsonl")
        }
        match (session.switchSession(SessionId(sessionId))) {
            case Result.Ok(_) => success(id, command,
                data: objectValue([ValueField("sessionId", textValue(session.id().value))]))
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func branchSession(
        id: String,
        command: String,
        entryId: String
    ): String {
        match (session.branchAt(entryId)) {
            case Result.Ok(result) => success(
                id,
                command,
                data: objectValue(
                    [
                        ValueField("text", textValue(result.text)),
                        ValueField("cancelled", boolValue(false))
                    ]
                )
            )
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func branchMessagesReply(
        id: String,
        command: String
    ): String {
        match (session.branchMessages()) {
            case Result.Ok(messages) =>
                let values = ArrayList<AgentValue>()
                for (message in messages) {
                    values.add(
                        objectValue(
                            [
                                ValueField(
                                    "entryId",
                                    textValue(message.entryId)
                                ),
                                ValueField("text", textValue(message.text))
                            ]
                        )
                    )
                }
                success(id, command, data: objectValue([ValueField("messages", listValue(values.toArray()))]))
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func messagesReply(id: String, command: String): String {
        match (session.messages()) {
            case Result.Ok(messages) => success(
                id,
                command,
                data: objectValue([ValueField("messages", messageListValue(messages))])
            )
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func lastAssistantReply(id: String, command: String): String {
        let messages = match (session.messages()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return failure(id, command, error.message)
        }
        var text = ""
        for (message in messages) {
            if (message.role == ModelRole.Assistant) {
                var candidate = ""
                for (block in message.blocks where block.kind == ModelBlockKind.Text) {
                    candidate += block.text
                }
                if (candidate != "") {
                    text = candidate
                }
            }
        }
        success(id, command, data: objectValue([ValueField("text", textValue(text))]))
    }

    private func setSessionName(
        id: String,
        command: String,
        name: String
    ): String {
        match (session.setName(name)) {
            case Result.Ok(_) => success(id, command,
                data: objectValue([ValueField("name", textValue(name.trimAscii()))]))
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func handoff(
        id: String,
        command: String,
        customInstructions: String
    ): String {
        if (isRunning()) {
            return failure(
                id,
                command,
                "Cannot hand off while a response is in progress"
            )
        }
        match (session.handoff(customInstructions: customInstructions)) {
            case Result.Ok(_) => success(id, command, data: objectValue([]))
            case Result.Err(error) => failure(id, command, error.message)
        }
    }

    private func messagesPage(
        id: String,
        command: String,
        request: AgentValue
    ): String {
        if (isRunning()) {
            return failureCode(
                id,
                command,
                "session_busy",
                "session is busy"
            )
        }
        let messages = match (session.messages()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return failure(id, command, error.message)
        }
        var start: Int64 = 0
        let cursor = productTextField(request, "cursor")
        if (cursor != "") {
            let parts = cursor.split(":")
            if (parts.size != 3 || parts[0] != session.id().value || parseRpcInteger(parts[2]) != messages.size) {
                return failureCode(
                    id,
                    command,
                    "stale_cursor",
                    "message cursor is stale"
                )
            }
            start = parseRpcInteger(parts[1])
        }
        var limit = productIntegerField(request, "limit")
        if (limit <= 0) {
            limit = 64
        }
        if (limit > 256) {
            limit = 256
        }
        if (start < 0 || start > messages.size) {
            return failureCode(
                id,
                command,
                "stale_cursor",
                "message cursor is stale"
            )
        }
        let end = minInt(messages.size, start + limit)
        let page: Array<ModelMessage> = if (start == end) {
            []
        } else {
            messages[start..end]
        }
        success(
            id,
            command,
            data: objectValue(
                [
                    ValueField("messages", messageListValue(page)),
                    ValueField("totalMessages", integerValue(messages.size)),
                    ValueField(
                        "nextCursor",
                        if (end < messages.size) {
                            textValue(session.id().value + ":" + end.toString() + ":" + messages.size.toString())
                        } else {
                            nullValue()
                        }
                    )
                ]
            )
        )
    }

    private func applicationReply(
        id: String,
        command: String,
        result: Result<ApplicationResponse>
    ): String {
        match (result) {
            case Result.Ok(response) => success(
                id,
                command,
                data: objectValue(
                    [
                        ValueField("output", textValue(response.text)),
                        ValueField(
                            "agentInvoked",
                            boolValue(response.agentInvoked)
                        )
                    ]
                )
            )
            case Result.Err(error) =>
                if (publishOwnedCheckpointFailure113(id, command, error)) { "" }
                else { failure(id, command, error.message) }
        }
    }

    private func tokensPerSecondValue(): AgentValue {
        let stats = match (session.runStats()) {
            case Result.Ok(value) => value
            case Result.Err(_) => return nullValue()
        }
        if (stats.lastRequestDurationMillis <= 0) {
            return nullValue()
        }
        numberValue(
            (Float64(stats.lastOutputTokens) * 1000.0 /
                Float64(stats.lastRequestDurationMillis)).toString()
        )
    }

    private func stateValue(): AgentValue {
        let todoProjection=session.todoPhases()
        let messageCount = match (session.messages()) {
            case Result.Ok(messages) => messages.size
            case Result.Err(_) => 0
        }
        let sessionName = match (session.name()) {
            case Result.Ok(value) => value
            case Result.Err(_) => ""
        }
        objectValue(
            [
                ValueField("model", modelValueFor(session.model())),
                ValueField("thinkingLevel", textValue(thinkingLevel)),
                ValueField("sessionRef", textValue(session.sessionRef())),
                ValueField("sessionId", textValue(session.id().value)),
                ValueField("sessionName", textValue(sessionName)),
                ValueField("workMode", textValue(session.workMode())),
                ValueField("loopModeEnabled", boolValue(session.loopEnabled())),
                ValueField("isStreaming", boolValue(isRunning())),
                ValueField(
                    "isCompacting",
                    boolValue(session.isCompacting())
                ),
                ValueField("steeringMode", textValue(steeringMode)),
                ValueField("followUpMode", textValue(followUpMode)),
                ValueField("interruptMode", textValue(interruptMode)),
                ValueField(
                    "autoCompactionEnabled",
                    boolValue(session.autoCompactionEnabled())
                ),
                ValueField("fastModeEnabled", boolValue(session.fastModeEnabled())),
                ValueField("fastModeActive", boolValue(session.fastModeActive())),
                ValueField("tokensPerSecond", tokensPerSecondValue()),
                ValueField("messageCount", integerValue(messageCount)),
                ValueField("systemPrompt", listValue([])),
                ValueField(
                    "dumpTools",
                    toolDefinitionsValue(session.activeTools())
                ),
                ValueField(
                    "contextUsage",
                    contextUsageValue(session.contextUsage())
                ),
                ValueField(
                    "queuedMessageCount",
                    integerValue(queuedCount())
                ),
                ValueField(
                    "todoPhases",
                    match (todoProjection) {
                        case Result.Ok(phases) => encodeTodoPhases(phases)
                        case Result.Err(_) => listValue([])
                    }
                ),
                // Explicit component failure accompanies an empty projection;
                // absence is never presented as authoritative empty Todo state.
                ValueField("todoComponentError",match(todoProjection){
                    case Result.Ok(_)=>nullValue();case Result.Err(error)=>textValue(error.code)}),
                ValueField(
                    "awaitingApproval",
                    boolValue(session.approval().isSome())
                )
            ]
        )
    }

    private func setSubagentSubscription(level: String): Unit {
        lock.lock()
        try {
            subagentSubscription = level
        } finally {
            lock.unlock()
        }
    }

    private func subagentSubscriptionLevel(): String {
        lock.lock()
        try {
            subagentSubscription
        } finally {
            lock.unlock()
        }
    }

    private func emitSubagentFrame(event: ProductSubagentEvent): Unit {
        let level = subagentSubscriptionLevel()
        if (level == "off") {
            return
        }
        if (event.kind == "event" && level != "events") {
            return
        }
        let frame = match (event.kind) {
            case "lifecycle" => objectValue(
                [
                    ValueField(
                        "type",
                        textValue("subagent_lifecycle")
                    ),
                    ValueField(
                        "payload",
                        subagentLifecycleValue(event.snapshot)
                    )
                ]
            )
            case "progress" => objectValue(
                [
                    ValueField(
                        "type",
                        textValue("subagent_progress")
                    ),
                    ValueField(
                        "payload",
                        subagentProgressValue(event.snapshot)
                    )
                ]
            )
            case _ => objectValue(
                [
                    ValueField(
                        "type",
                        textValue("subagent_event")
                    ),
                    ValueField(
                        "payload",
                        subagentEventValue(event)
                    )
                ]
            )
        }
        emitFrame(encodeAgentValue(frame))
    }

    private func isRunning(): Bool {
        lock.lock()
        try {
            running
        } finally {
            lock.unlock()
        }
    }

    private func queuedCount(): Int64 {
        session.queuedCount()
    }

    // New failure output is an explicit capability of the same concrete
    // output object. A legacy String callback cannot provide a physical ACK.
    private func failureOutput113(): ?OwnedRpcFailureOutput113 {
        match (ownedOutput) {
            case Some(value) => value as OwnedRpcFailureOutput113
            case None => None<OwnedRpcFailureOutput113>
        }
    }

    private func admitOwnedFailure113(value: OwnedFailureRunPublication113): Bool {
        frameLock.lock()
        try {
            let delivery = match (rpcPrepareFailurePublication113(value, "", "", true, protocolVersion)) {
                case Result.Err(_) => return false
                case Result.Ok(actual) => actual
            }
            ownedFailureDeliveries113.append(delivery)
            // Registration is acceptance. Offering happens on a later DATA
            // collection entry, after the Application admission callback ends.
            true
        } finally { frameLock.unlock() }
    }

    private func publishOwnedCheckpointFailure113(id: String, command: String, marker: AgentError): Bool {
        let matched = session.hasOwnedCheckpointFailure113(marker)
        if (!matched) { return false }
        let accepted = session.admitOwnedCheckpointFailure113(marker, { result =>
            frameLock.lock()
            try {
                let prepared = match (result) {
                    case OwnedAgentRunResult113.Failed(value) =>
                        rpcPrepareFailurePublication113(value, id, command, false, protocolVersion)
                    case OwnedAgentRunResult113.Pending(value) =>
                        rpcPrepareFailureData113(value, id, command, protocolVersion)
                    case _ => return false
                }
                match (prepared) {
                    case Result.Err(_) => false
                    case Result.Ok(value) => ownedFailureDeliveries113.append(value); true
                }
            } finally { frameLock.unlock() }
        })
        // Failed payment leaves the exact original marker/result in App;
        // recognized failures never emit the short static marker as a second
        // ordinary response or masquerade as a successful Application result.
        if (!accepted && session.hasOwnedCheckpointFailure113(marker)) { unadmittedFailure113.store(true) }
        collectOwnedCheckpointFailures113()
        true
    }

    public func collectOwnedCheckpointFailures113(): Unit {
        frameLock.lock()
        try {
            let _ = ownedFailureDeliveries113.collect()
            while (ownedFailureDeliveries113.pending()) {
                ownedFailureDeliveries113.offer(failureOutput113(), { => chunkCounter++; "rpc-" + chunkCounter.toString() })
                if (!ownedFailureDeliveries113.collect()) { break }
            }
        } finally { frameLock.unlock() }
        session.collectOwnedCheckpointFailure113()
    }

    public func hasOwnedCheckpointFailureOutput113(): Bool {
        frameLock.lock()
        try { unadmittedFailure113.load() || ownedFailureDeliveries113.pending() } finally { frameLock.unlock() }
    }

    // Startup uses exactly the installed App marker and the existing paid
    // caller admission/complete eight-field output path. True means recognized
    // ownership, never output consumption; false preserves the plain fallback.
    public func admitStartupCheckpointFailure113(marker: AgentError): Bool {
        publishOwnedCheckpointFailure113("", "startup", marker)
    }

    // ONLY a paid frontend producer may call this potentially blocking method.
    // The parent queries its real Future, not this frame/output lock. All old
    // event/failure emit methods and their one-offer/ACK contracts stay intact.
    public func collectFrontendOutputRetirement113(): Bool {
        collectOwnedCheckpointFailures113()
        frameLock.lock()
        try {
            var index: Int64 = 0
            while (index < ownedDeliveries.size) {
                if (ownedDeliveries[index].isAcknowledged() ||
                    ownedDeliveries[index].closeAfterDeliveryRetirement().isOk()) {
                    ownedDeliveries.remove(at: index)
                } else { index += 1 }
            }
            !unadmittedFailure113.load() && !ownedFailureDeliveries113.pending() && ownedDeliveries.isEmpty()
        } finally { frameLock.unlock() }
    }

    private func emitOwnedEvent(event: OwnedAgentEvent): Result<Unit> {
        frameLock.lock()
        try {
            var index: Int64 = 0
            while (index < ownedDeliveries.size) {
                if (ownedDeliveries[index].isAcknowledged() ||
                    ownedDeliveries[index].closeAfterDeliveryRetirement().isOk()) { ownedDeliveries.remove(at: index) }
                else { return ownedRpcOutputError("rpc.owned_prior_delivery_pending") }
            }
            let delivery = OwnedProductRpcEventDelivery(event, ownedOutput.getOrThrow())
            ownedDeliveries.add(delivery)
            let result = try {
                delivery.run(protocolVersion, { => chunkCounter++; "rpc-" + chunkCounter.toString() })
            } finally {
                // Physical error cleanup does not replay output or turn the
                // failed delivery into success. Unknown output debt stays
                // under this actual registered delivery for later ACK.
                let _ = delivery.closeAfterDeliveryRetirement()
            }
            result
        } finally { frameLock.unlock() }
    }

    private func emitFrame(logical: String): Unit {
        frameLock.lock()
        try {
            emit(outboundUnlocked(logical))
        } finally {
            frameLock.unlock()
        }
    }

    private func outbound(logical: String): String {
        frameLock.lock()
        try {
            outboundUnlocked(logical)
        } finally {
            frameLock.unlock()
        }
    }

    private func outboundUnlocked(logical: String): String {
        let bytes = unsafe { logical.rawData() }
        if (bytes.size + 1 <= 1048576) {
            return logical
        }
        if (protocolVersion != 2) {
            return failure(
                "",
                "frame",
                "RPC output exceeds the v1 frame limit; negotiate protocol v2"
            )
        }
        if (bytes.size > 67108864) {
            return failure(
                "",
                "frame",
                "RPC output exceeds the reassembly limit"
            )
        }
        chunkCounter += 1
        let chunkId = "rpc-" + chunkCounter.toString()
        let payloadBytes: Int64 = 262144
        let count = (bytes.size + payloadBytes - 1) / payloadBytes
        var output = ""
        for (index in 0..count) {
            let start = index * payloadBytes
            let end = minInt(bytes.size, start + payloadBytes)
            if (output != "") {
                output += "\n"
            }
            output += encodeAgentValue(
                objectValue(
                    [
                        ValueField("type", textValue("rpc_chunk")),
                        ValueField("chunkId", textValue(chunkId)),
                        ValueField("index", integerValue(index)),
                        ValueField("count", integerValue(count)),
                        ValueField("byteLength", integerValue(bytes.size)),
                        ValueField(
                            "data",
                            textValue(productBase64Bytes(bytes[start..end]))
                        )
                    ]
                )
            )
        }
        output
    }
}

func contextUsageValue(value: ProductContextUsage): AgentValue {
    objectValue([
        ValueField("tokens", match (value.tokens) {
            case Some(number) => integerValue(number)
            case None => nullValue()
        }),
        ValueField("contextWindow", match (value.contextWindow) {
            case Some(number) => integerValue(number)
            case None => nullValue()
        }),
        ValueField("percent", match (value.percent) {
            case Some(number) => numberValue(number.toString())
            case None => nullValue()
        })
    ])
}

func thinkingLevelValue(value: String): ThinkingLevel {
    match (value) {
        case "off" => ThinkingLevel.Off
        case "minimal" => ThinkingLevel.Minimal
        case "low" => ThinkingLevel.Low
        case "medium" => ThinkingLevel.Medium
        case "high" => ThinkingLevel.High
        case "xhigh" => ThinkingLevel.XHigh
        case "max" => ThinkingLevel.Max
        case _ => ThinkingLevel.Medium
    }
}

func queueDeliveryMode(value: String): QueueDeliveryMode {
    if (value == "all") {
        QueueDeliveryMode.All
    } else {
        QueueDeliveryMode.OneAtATime
    }
}

class RpcPrompt {
    let id: String
    let command: String
    let message: String
    let publishResult: Bool
    let queued113: ?QueuedInteraction

    init(
        id: String,
        command: String,
        message: String,
        publishResult!: Bool = true,
        queued113!: ?QueuedInteraction = None<QueuedInteraction>
    ) {
        this.id = id
        this.command = command
        this.message = message
        this.publishResult = publishResult
        this.queued113 = queued113
    }
}

class RpcDecision {
    let id: String
    let command: String
    let operationId: String
    let decision: ApprovalDecision

    init(
        id: String,
        command: String,
        operationId: String,
        decision: ApprovalDecision
    ) {
        this.id = id
        this.command = command
        this.operationId = operationId
        this.decision = decision
    }
}

func commandsValue(extraDefinitions:Array<SlashCommandDefinition>): AgentValue {
    let values = ArrayList<AgentValue>()
    // Slash-command discovery is UI/product metadata. Keep it independent
    // from availableRpcCommands(), which is the transport protocol inventory.
    for (command in presentedSlashCommandDefinitions(extraDefinitions)) {
        values.add(slashCommandValue(command))
    }
    objectValue([ValueField("commands", listValue(values.toArray()))])
}

func slashCommandValue(command: SlashCommandDefinition): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("name", textValue(command.name)))
    if (!command.aliases.isEmpty()) {
        fields.add(ValueField("aliases", stringListValue(command.aliases)))
    }
    if (command.description != "") {
        fields.add(ValueField("description", textValue(command.description)))
    }
    let inputHint = command.inputHint()
    if (inputHint != "") {
        fields.add(
            ValueField(
                "input",
                objectValue([ValueField("hint", textValue(inputHint))])
            )
        )
    }
    if (!command.subcommands.isEmpty()) {
        let subcommands = ArrayList<AgentValue>()
        for (subcommand in command.subcommands) {
            subcommands.add(
                objectValue([ValueField("name", textValue(subcommand))])
            )
        }
        fields.add(
            ValueField("subcommands", listValue(subcommands.toArray()))
        )
    }
    fields.add(ValueField("source", textValue(command.source)))
    objectValue(fields.toArray())
}

func rpcInteractionText(value: AgentValue, name: String): ?String {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Text) { Some(field.text) } else { None }
        case None => None
    }
}

func rpcInteractionInteger(value: AgentValue, name: String): ?Int64 {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind != ValueKind.Number) { return None }
            let source = field.asNumberText()
            try {
                let parsed = Int64.parse(source)
                if (parsed.toString() == source) { Some(parsed) } else { None }
            } catch (_: Exception) {
                None
            }
        case None => None
    }
}

func rpcInteractionBoolean(value: AgentValue, name: String): ?Bool {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Boolean) { Some(field.asBool()) } else { None }
        case None => None
    }
}

func rpcInteractionStringList(value: AgentValue, name: String): ?Array<String> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return None
    }
    if (field.unifiedKind != ValueKind.List) { return None }
    let values = ArrayList<String>()
    for (item in field.items) {
        if (item.unifiedKind != ValueKind.Text) { return None }
        values.add(item.text)
    }
    Some(values.toArray())
}

func rpcOptionalInteractionText(value: AgentValue, name: String): Result<?String> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) {
                Result.Ok(Some(field.text))
            } else {
                Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "rpc.interaction_field_invalid",
                    name + " must be a string"
                ))
            }
        case None => Result.Ok(None)
    }
}

func rpcOptionalInteractionBoolean(value: AgentValue, name: String): Result<Bool> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Boolean) {
                Result.Ok(field.asBool())
            } else {
                Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "rpc.interaction_field_invalid",
                    name + " must be a boolean"
                ))
            }
        case None => Result.Ok(false)
    }
}

func rpcInteractionQuestionValue(question: ProductAskQuestion): AgentValue {
    let options = ArrayList<AgentValue>()
    for (option in question.options) {
        options.add(objectValue([
            ValueField("label", textValue(option.label)),
            ValueField("description", textValue(option.description)),
            ValueField("preview", textValue(option.preview))
        ]))
    }
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("id", textValue(question.id)))
    fields.add(ValueField("question", textValue(question.question)))
    fields.add(ValueField("header", textValue(question.header)))
    fields.add(ValueField("options", listValue(options.toArray())))
    fields.add(ValueField("multi", boolValue(question.multi)))
    match (question.recommended) {
        case Some(index) => fields.add(ValueField("recommended", integerValue(index)))
        case None => ()
    }
    objectValue(fields.toArray())
}

public func availableRpcCommands(): Array<String> {
    [
        "negotiate_protocol",
        "negotiate_interactions",
        "get_plugin_commands",
        "plugin_command",
        "interaction_response",
        "prompt",
        "steer",
        "follow_up",
        "abort",
        "abort_and_prompt",
        "new_session",
        "get_state",
        "set_fast_mode",
        "get_available_commands",
        "set_todos",
        "set_host_tools",
        "set_host_uri_schemes",
        "set_subagent_subscription",
        "get_subagents",
        "get_subagent_messages",
        "set_model",
        "cycle_model",
        "get_available_models",
        "set_thinking_level",
        "cycle_thinking_level",
        "set_steering_mode",
        "set_follow_up_mode",
        "set_interrupt_mode",
        "compact",
        "set_auto_compaction",
        "set_auto_retry",
        "abort_retry",
        "bash",
        "abort_bash",
        "get_session_stats",
        "export_html",
        "switch_session",
        "branch",
        "get_branch_messages",
        "get_last_assistant_text",
        "set_session_name",
        "handoff",
        "get_messages",
        "get_messages_page",
        "get_login_providers",
        "login"
    ]
}

func success(
    id: String,
    command: String,
    data!: ?AgentValue = None
): String {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("type", textValue("response")))
    if (id != "") {
        fields.add(ValueField("id", textValue(id)))
    }
    fields.add(ValueField("command", textValue(command)))
    fields.add(ValueField("success", boolValue(true)))
    match (data) {
        case Some(value) => fields.add(ValueField("data", value))
        case None => ()
    }
    encodeAgentValue(objectValue(fields.toArray()))
}

func failure(id: String, command: String, message: String): String {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("type", textValue("response")))
    if (id != "") {
        fields.add(ValueField("id", textValue(id)))
    }
    fields.add(ValueField("command", textValue(command)))
    fields.add(ValueField("success", boolValue(false)))
    fields.add(ValueField("error", textValue(message)))
    encodeAgentValue(objectValue(fields.toArray()))
}

func failureCode(
    id: String,
    command: String,
    code: String,
    message: String
): String {
    let value = match (decodeAgentValue(failure(id, command, message))) {
        case Result.Ok(item) => item
        case Result.Err(_) => return failure(id, command, message)
    }
    let fields = ArrayList<ValueField>()
    for (field in value.fields) {
        fields.add(field)
    }
    fields.add(ValueField("code", textValue(code)))
    encodeAgentValue(objectValue(fields.toArray()))
}

public func productApprovalFrame(approval: ApprovalRequest): AgentValue {
    let details = approvalDetails(approval)
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("type", textValue("approval_request")))
    fields.add(
        ValueField(
            "operationId",
            textValue(details.operationId.value)
        )
    )
    fields.add(ValueField("callId", textValue(details.callId)))
    fields.add(ValueField("tool", textValue(details.toolName)))
    fields.add(
        ValueField(
            "capability",
            textValue(details.metadata.capabilityLabel)
        )
    )
    fields.add(
        ValueField(
            "resource",
            textValue(details.capability.resource)
        )
    )
    fields.add(ValueField("risk", textValue(match (details.review) {
        case Some(review) => review.riskLevel
        case None => approvalRiskName(details.risk)
    })))
    fields.add(ValueField("argumentHash", textValue(details.argumentHash)))
    fields.add(ValueField("riskFlags", approvalRpcStrings(details.riskFlags)))
    fields.add(ValueField("riskReasons", approvalRpcStrings(details.metadata.assessment.reasons)))
    fields.add(ValueField("decisionSource", textValue(approvalDecisionSourceName(details.decisionSource))))
    fields.add(ValueField("sessionApprovalAllowed", boolValue(approval.sessionApprovalAllowed)))
    fields.add(ValueField("preview", approvalReviewerArguments(approval)))
    match (details.review) {
        case Some(review) => fields.add(
            ValueField(
                "reviewer",
                objectValue(
                    [
                        ValueField(
                            "decision",
                            textValue(match (review.decision) {
                                case ApprovalReviewDecision.Approve => "approve"
                                case ApprovalReviewDecision.Deny => "deny"
                                case ApprovalReviewDecision.AskUser => "ask_user"
                            })
                        ),
                        ValueField("reason", textValue(review.reason)),
                        ValueField("model", textValue(review.reviewerModel)),
                        ValueField("latencyMs", integerValue(review.latencyMillis)),
                        ValueField("failureType", textValue(review.failureType))
                    ]
                )
            )
        )
        case None => ()
    }
    objectValue(fields.toArray())
}

func approvalRpcStrings(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(textValue(value))
    }
    listValue(items.toArray())
}

func productTextField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => item.text
        case None => ""
    }
}

func productIntegerField(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) => try {
            Int64.parse(item.asNumberText())
        } catch (_: Exception) {
            0
        }
        case None => 0
    }
}

func productBoolField(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.unifiedKind == ValueKind.Boolean && item.asBool()
        case None => false
    }
}

func stringListValue(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(textValue(value))
    }
    listValue(items.toArray())
}

func toolDefinitionsValue(tools: Array<ModelToolDefinition>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (tool in tools) {
        values.add(
            objectValue(
                [
                    ValueField("name", textValue(tool.name)),
                    ValueField("description", textValue(tool.description)),
                    ValueField("parameters", tool.inputSchema)
                ]
            )
        )
    }
    listValue(values.toArray())
}

func modelValue(
    provider: String,
    model: String,
    metadata: ?ModelCatalogEntry
): AgentValue {
    let contextWindow: ?Int64 = match (metadata) {
        case Some(value) => value.contextWindow
        case None => None
    }
    let maxTokens: ?Int64 = match (metadata) {
        case Some(value) => value.maxOutputTokens
        case None => None
    }
    let reasoning: ?Bool = match (metadata) {
        case Some(value) => Some(match (value.thinking) {
            case Some(capabilities) => capabilities.mode != ThinkingControlMode.NoThinking
            case None => false
        })
        case None => None
    }
    let input: ?Array<String> = match (metadata) {
        case Some(value) => value.inputModalities
        case None => None
    }
    let output: ?Array<String> = match (metadata) {
        case Some(value) => value.outputModalities
        case None => None
    }
    objectValue(
        [
            ValueField("provider", textValue(provider)),
            ValueField("id", textValue(model)),
            ValueField("contextWindow", optionalRpcInteger(contextWindow)),
            ValueField("maxTokens", optionalRpcInteger(maxTokens)),
            ValueField("reasoning", optionalRpcBoolean(reasoning)),
            ValueField("input", optionalRpcStrings(input)),
            ValueField("output", optionalRpcStrings(output)),
            ValueField("fastServiceTier", match (metadata) {
                case Some(value) => if (value.fastServiceTier == "") {
                    nullValue()
                } else {
                    textValue(value.fastServiceTier)
                }
                case None => nullValue()
            }),
            ValueField("costMicrosPerMillion", objectValue([
                ValueField("input", optionalRpcInteger(match (metadata) {
                    case Some(value) => value.inputCostMicrosPerMillion
                    case None => None
                })),
                ValueField("output", optionalRpcInteger(match (metadata) {
                    case Some(value) => value.outputCostMicrosPerMillion
                    case None => None
                })),
                ValueField("cacheRead", optionalRpcInteger(match (metadata) {
                    case Some(value) => value.cacheReadCostMicrosPerMillion
                    case None => None
                })),
                ValueField("cacheWrite", optionalRpcInteger(match (metadata) {
                    case Some(value) => value.cacheWriteCostMicrosPerMillion
                    case None => None
                }))
            ]))
        ]
    )
}

func optionalRpcInteger(value: ?Int64): AgentValue {
    match (value) {
        case Some(number) => integerValue(number)
        case None => nullValue()
    }
}

func optionalRpcBoolean(value: ?Bool): AgentValue {
    match (value) {
        case Some(enabled) => boolValue(enabled)
        case None => nullValue()
    }
}

func optionalRpcStrings(value: ?Array<String>): AgentValue {
    match (value) {
        case Some(items) => stringListValue(items)
        case None => nullValue()
    }
}

func validThinkingLevel(level: String): Bool {
    level == "off" || level == "minimal" || level == "low" || level == "medium" || level == "high" || level == "xhigh" ||
        level == "max"
}

func messageListValue(messages: Array<ModelMessage>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (message in messages) {
        values.add(messageValue(message))
    }
    listValue(values.toArray())
}

func subagentSnapshotsValue(snapshots: Array<ProductSubagentSnapshot>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (snapshot in snapshots) {
        values.add(subagentSnapshotValue(snapshot))
    }
    listValue(values.toArray())
}

func subagentSnapshotValue(snapshot: ProductSubagentSnapshot): AgentValue {
    objectValue(
        [
            ValueField("id", textValue(snapshot.id)),
            ValueField("index", integerValue(snapshot.index)),
            ValueField("agent", textValue(snapshot.agent)),
            ValueField(
                "agentSource",
                textValue(snapshot.agentSource)
            ),
            ValueField("description", textValue(snapshot.description)),
            ValueField("status", textValue(snapshot.status)),
            ValueField("task", textValue(snapshot.task)),
            ValueField("assignment", textValue(snapshot.assignment)),
            ValueField("sessionRef", textValue(snapshot.sessionRef)),
            ValueField(
                "parentToolCallId",
                textValue(snapshot.parentToolCallId)
            ),
            ValueField("lastUpdate", integerValue(snapshot.lastUpdate)),
            ValueField("progress", subagentProgressStateValue(snapshot))
        ]
    )
}

func subagentLifecycleValue(snapshot: ProductSubagentSnapshot): AgentValue {
    objectValue(
        [
            ValueField("id", textValue(snapshot.id)),
            ValueField("agent", textValue(snapshot.agent)),
            ValueField(
                "agentSource",
                textValue(snapshot.agentSource)
            ),
            ValueField("description", textValue(snapshot.description)),
            ValueField(
                "status",
                textValue(if (snapshot.status == "running") {
                    "started"
                } else if (snapshot.status == "cancelled") {
                    "aborted"
                } else {
                    snapshot.status
                })
            ),
            ValueField("sessionRef", textValue(snapshot.sessionRef)),
            ValueField(
                "parentToolCallId",
                textValue(snapshot.parentToolCallId)
            ),
            ValueField("index", integerValue(snapshot.index))
        ]
    )
}

func subagentProgressValue(snapshot: ProductSubagentSnapshot): AgentValue {
    objectValue(
        [
            ValueField("index", integerValue(snapshot.index)),
            ValueField("agent", textValue(snapshot.agent)),
            ValueField(
                "agentSource",
                textValue(snapshot.agentSource)
            ),
            ValueField("task", textValue(snapshot.task)),
            ValueField("assignment", textValue(snapshot.assignment)),
            ValueField("sessionRef", textValue(snapshot.sessionRef)),
            ValueField(
                "parentToolCallId",
                textValue(snapshot.parentToolCallId)
            ),
            ValueField("progress", subagentProgressStateValue(snapshot))
        ]
    )
}

func subagentProgressStateValue(snapshot: ProductSubagentSnapshot): AgentValue {
    objectValue(
        [
            ValueField("index", integerValue(snapshot.index)),
            ValueField("id", textValue(snapshot.id)),
            ValueField("agent", textValue(snapshot.agent)),
            ValueField(
                "agentSource",
                textValue(snapshot.agentSource)
            ),
            ValueField("status", textValue(snapshot.status)),
            ValueField("task", textValue(snapshot.task)),
            ValueField("assignment", textValue(snapshot.assignment)),
            ValueField("description", textValue(snapshot.description)),
            ValueField("currentTool", textValue(snapshot.currentTool)),
            ValueField("toolCount", integerValue(snapshot.toolCount)),
            ValueField("requests", integerValue(snapshot.requests)),
            ValueField("tokens", integerValue(snapshot.tokens)),
            ValueField(
                "durationMs",
                integerValue(snapshot.durationMillis)
            ),
            ValueField("recentTools", listValue([])),
            ValueField("recentOutput", listValue([])),
            ValueField("cost", numberValue("0"))
        ]
    )
}

func subagentEventValue(event: ProductSubagentEvent): AgentValue {
    let raw = match (event.event) {
        case Some(value) => objectValue(
            [
                ValueField("sequence", integerValue(value.sequence)),
                ValueField("runId", textValue(value.runId.value)),
                ValueField("event", value.detail)
            ]
        )
        case None => objectValue([])
    }
    objectValue(
        [
            ValueField("id", textValue(event.snapshot.id)),
            ValueField("event", raw)
        ]
    )
}

func asyncJobRpcValue(snapshot: ProductAsyncJobSnapshot): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("id", textValue(snapshot.id)))
    fields.add(ValueField("agentId", textValue(snapshot.agentId)))
    fields.add(ValueField("type", textValue(snapshot.jobType)))
    fields.add(ValueField("status", textValue(snapshot.status)))
    fields.add(ValueField("label", textValue(snapshot.label)))
    fields.add(
        ValueField(
            "durationMs",
            integerValue(snapshot.durationMillis)
        )
    )
    match (snapshot.result) {
        case Some(value) => fields.add(ValueField("result", value))
        case None => ()
    }
    if (snapshot.error != "") {
        fields.add(ValueField("error", textValue(snapshot.error)))
    }
    objectValue(fields.toArray())
}

func subagentTranscriptValue(transcript: ProductSubagentTranscript): AgentValue {
    let entries = ArrayList<AgentValue>()
    for (message in transcript.messages) {
        entries.add(
            objectValue(
                [
                    ValueField("type", textValue("message")),
                    ValueField("message", messageValue(message))
                ]
            )
        )
    }
    objectValue(
        [
            ValueField("sessionRef", textValue(transcript.sessionRef)),
            ValueField("fromItem", integerValue(transcript.fromItem)),
            ValueField("nextItem", integerValue(transcript.nextItem)),
            ValueField("reset", boolValue(transcript.reset)),
            ValueField("entries", listValue(entries.toArray())),
            ValueField(
                "messages",
                messageListValue(transcript.messages)
            )
        ]
    )
}

func messageValue(message: ModelMessage): AgentValue {
    let blocks = ArrayList<AgentValue>()
    for (block in message.blocks) {
        blocks.add(
            objectValue(
                [
                    ValueField("type", textValue(blockType(block.kind))),
                    ValueField("text", textValue(block.text)),
                    ValueField("callId", textValue(block.callId)),
                    ValueField("name", textValue(block.name)),
                    ValueField("arguments", block.arguments),
                    ValueField("isError", boolValue(block.isError)),
                    ValueField("image", match (block.image) {
                        case Some(image) => objectValue([
                            ValueField("sourceKind", textValue(match (image.sourceKind) {
                                case ModelImageSourceKind.Url => "url"
                                case ModelImageSourceKind.Base64 => "base64"
                            })),
                            ValueField("data", textValue(image.data)),
                            ValueField("mediaType", textValue(image.mediaType)),
                            ValueField("detail", textValue(match (image.detail) {
                                case ModelImageDetail.Auto => "auto"
                                case ModelImageDetail.Low => "low"
                                case ModelImageDetail.High => "high"
                            }))
                        ])
                        case None => nullValue()
                    })
                ]
            )
        )
    }
    objectValue(
        [
            ValueField(
                "role",
                textValue(if (message.role == ModelRole.User) {
                    "user"
                } else {
                    "assistant"
                })
            ),
            ValueField("content", listValue(blocks.toArray()))
        ]
    )
}

func blockType(kind: ModelBlockKind): String {
    match (kind) {
        case ModelBlockKind.Text => "text"
        case ModelBlockKind.Image => "image"
        case ModelBlockKind.Reasoning => "thinking"
        case ModelBlockKind.ToolCall => "toolCall"
        case ModelBlockKind.ToolResult => "toolResult"
        case ModelBlockKind.Refusal => "refusal"
        case ModelBlockKind.Error => "error"
        case ModelBlockKind.Unknown => "unknown"
    }
}

func parseRpcInteger(value: String): Int64 {
    try {
        Int64.parse(value)
    } catch (_: Exception) {
        -1
    }
}

func minInt(first: Int64, second: Int64): Int64 {
    if (first < second) {
        first
    } else {
        second
    }
}

// A returned callback flag is progress only. Retirement requires the same
// physical Future tryGet witness used by the actual child worker owner.
class RpcBashWorker {
    var future: ?Future<Unit> = None<Future<Unit>>
    var metadata113: ?LogicalJsonOwnerReservation
    var rejectedBeforeSpawn113 = false
    var rejectedFrameReturned113 = false
    var completed = false
    init(paid: LogicalJsonOwnerReservation) { metadata113 = Some(paid) }
}

// No cancellation, scheduler flag or callback return can manufacture this
// observation. Exceptional/unknown completion stays retained and closed.
private func rpcWorkerReturned113(worker: ?Future<Unit>): Bool {
    match (worker) {
        case None => true
        case Some(actual) => try { actual.tryGet().isSome() } catch (_: Exception) { false }
    }
}

// Numeric extents only: no UTF8 arrays, raw copies or new semantic input cap.
// Fixed 64 KiB covers each actual Future, action, holder and short helper frames;
// the original complete captured input is billed separately at eight copies.
private func rpcWorkerAdd113(first: Int64, second: Int64): Int64 {
    if (first < 0 || second < 0 || first > Int64.Max - second) {
        throw IllegalStateException("rpc.worker_metadata_overflow") }
    first + second
}
private func rpcWorkerExtentPeak113(bytes: Int64): Int64 {
    if (bytes < 0 || bytes > (Int64.Max - 65536) / 8) {
        throw IllegalStateException("rpc.worker_metadata_overflow") }
    65536 + bytes * 8
}
private func rpcWorkerInputPeak113(first: String, second: String, third: String): Int64 {
    rpcWorkerExtentPeak113(rpcWorkerAdd113(first.size, rpcWorkerAdd113(second.size, third.size)))
}
private func rpcWorkerDecisionPeak113(decision: ApprovalDecision): Int64 {
    match (decision) {
        case ApprovalDecision.RejectWithReason(reason) => rpcWorkerExtentPeak113(reason.size)
        case _ => 4096
    }
}
private func rpcWorkerListPeak113(count: Int64): Int64 {
    if (count < 0 || count > (Int64.Max - 65536) / 512) {
        throw IllegalStateException("rpc.worker_metadata_overflow") }
    // Retained server-list backing remains paid with its actual holders.
    65536 + count * 512
}
private func rpcWorkerJoinPeak113(count: Int64): Int64 {
    if (count < 0 || count > (Int64.Max - 65536) / 512) {
        throw IllegalStateException("rpc.worker_metadata_overflow") }
    // Each live close owns its own exact-length reference array, header,
    // iterator and prompt/command Future locals. Captured input remains paid
    // by the original worker children until ALL join frames have returned.
    65536 + count * 512
}
private func rpcCloseWorkerMetadata113(value: ?LogicalJsonOwnerReservation): Unit {
    match (value) { case Some(actual) => actual.close(); case None => () }
}
// File-private paid custody. A failed preparation/SQL/capture keeps this
// exact queue object and old worker payment reachable, without re-enqueue.
class RpcQueuedRetainedInput113 {
    let value: QueuedInteraction
    let payment: LogicalJsonOwnerReservation
    let inputPeak: Int64
    var primaryRegistered = false
    var primaryRaw113: ?AgentError = None<AgentError>
    private let storeLock113 = Mutex()
    private var storeCells113: ?RpcQueuedStoreFailure113 = None<RpcQueuedStoreFailure113>
    var unknown: ?Exception = None<Exception>
    var origin: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>
    var primary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    var uncertain = false
    init(value: QueuedInteraction, payment: LogicalJsonOwnerReservation, inputPeak: Int64) {
        this.value = value; this.payment = payment; this.inputPeak = inputPeak
    }
    func retainStoreCell113(cell: RpcQueuedStoreFailure113): Unit {
        storeLock113.lock()
        try {
            let expected = origin.getOrThrow()
            if (!cell.matches113(expected)) { throw IllegalStateException("SQL custody has another original input") }
            cell.previous113 = storeCells113
            storeCells113 = Some(cell)
        } finally { storeLock113.unlock() }
    }
    func admitStoreFailure113(cell: RpcQueuedStoreFailure113): Unit {
        storeLock113.lock()
        try {
            var found = false
            var cursor = storeCells113
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, cell)) { found = true; break }
                cursor = current.previous113
            }
            if (!found || secondary.isSome()) { throw IllegalStateException("original SQL failure cell was not registered") }
            // Existing paid node accepts before any transfer. False retains
            // the exact original exception with no fake consumer or output.
            let _ = cell.admitConsumer113({ consumer => secondary = Some(consumer); true })
        } finally { storeLock113.unlock() }
    }
    private func takeReturnedStoreCellPaymentHelper113(): ?LogicalJsonOwnerReservation {
        storeLock113.lock()
        try {
            var previous: ?RpcQueuedStoreFailure113 = None<RpcQueuedStoreFailure113>
            var cursor = storeCells113
            while (cursor.isSome()) {
                let cell = cursor.getOrThrow()
                let next = cell.previous113
                let paid = cell.takeRetirementPaymentAfterReturned113()
                if (paid.isSome()) {
                    match (previous) { case Some(actual) => actual.previous113 = next
                        case None => storeCells113 = next }
                    return paid
                }
                previous = cursor; cursor = next
            }
            None<LogicalJsonOwnerReservation>
        } finally { storeLock113.unlock() }
    }
    func retireReturnedStoreCells113(): Unit {
        // Actual whole App/Store return precedes this helper; unlink and its
        // lock/Future-free local frame return before child payment close.
        while (true) {
            let paid = takeReturnedStoreCellPaymentHelper113()
            match (paid) { case Some(actual) => actual.close(); case None => return }
        }
    }
    func observedStoreCustody113(): (Int64, Int64) {
        storeLock113.lock()
        try {
            var count: Int64 = 0; var held: Int64 = 0
            var cursor = storeCells113
            while (cursor.isSome()) {
                let cell = cursor.getOrThrow()
                count++
                if (cell.observedOriginalWithoutConsumer113()) { held++ }
                cursor = cell.previous113
            }
            (count, held)
        } finally { storeLock113.unlock() }
    }

    func allocate(bytes: Int64): LogicalJsonOwnerReservation {
        let child = payment.deriveRetainedLease()
        try { child.ensureRetainedPeak(bytes); child }
        catch (error: Exception) { child.close(); throw error }
    }
    func capturePrimary(error: AgentError): Unit {
        if (primaryRaw113.isSome()) { throw IllegalStateException("original primary input is already retained") }
        primaryRaw113 = Some(error)
        match (captureOwnedFailureData113<Unit>(error, { bytes => allocate(bytes) })) {
            case OwnedFailureDataOutcome113.Failure(value) => primary = Some(value)
            case _ => throw IllegalStateException("original primary capture returned no consumer") }
    }
}

