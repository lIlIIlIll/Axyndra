package agent_rpc

import agent_cli.*
import agent_core.*
import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.sync.*

public class ProductJsonlRpcServer {
    private let session: ApplicationSession
    private let emit: (String) -> Unit
    private var hostTools: ?RpcHostToolBridge = None
    private var hostUris: ?RpcHostUriBridge = None
    private let lock = Mutex()
    private let frameLock = Mutex()
    private var running = false
    private var protocolVersion: Int64 = 1
    private var chunkCounter: Int64 = 0
    private var thinkingLevel = "medium"
    private var steeringMode = "one-at-a-time"
    private var followUpMode = "one-at-a-time"
    private var interruptMode = "immediate"
    private var subagentSubscription = "off"

    public init(
        session: ApplicationSession,
        emit: (String) -> Unit
    ) {
        this.session = session
        this.emit = emit
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
        session.subscribeSubagents({
            event => emitSubagentFrame(event)
        })
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
                        match (session.enqueue("", "steer", message)) {
                            case Result.Ok(_) => success(id, command)
                            case Result.Err(error) => failure(id, command, error.message)
                        }
                    } else if (streamingBehavior == "followUp") {
                        match (session.enqueue("", "follow_up", message)) {
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
                    if (startPrompt(RpcPrompt(id, command, message))) {
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
                        scheduleDeferred(RpcPrompt(id, command, message))
                        success(id, command)
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
            case "get_available_commands" => success(id, command, data: commandsValue())
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
                match (session.setTodoPhases(phases)) {
                    case Result.Ok(_) => success(
                        id,
                        command,
                        data: objectValue(
                            [
                                ValueField(
                                    "todoPhases",
                                    encodeTodoPhases(phases)
                                )
                            ]
                        )
                    )
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
            case "bash" => runBash(id, command, productTextField(value, "command"))
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

    private func startPrompt(prompt: RpcPrompt): Bool {
        lock.lock()
        try {
            if (running || session.approval().isSome()) {
                return false
            }
            running = true
        } finally {
            lock.unlock()
        }
        let _ = spawn {runPrompts(prompt)}
        true
    }

    private func queueInteraction(
        kind: String,
        message: String
    ): Result<Unit> {
        lock.lock()
        try {
            if (running || session.approval().isSome()) {
                return session.enqueue("", kind, message)
            }
            running = true
        } finally {
            lock.unlock()
        }
        let _ = spawn {
            runPrompts(
                RpcPrompt(
                    "",
                    kind,
                    message,
                    publishResult: false
                )
            )
        }
        Result.Ok(())
    }

    private func scheduleDeferred(prompt: RpcPrompt): Unit {
        lock.lock()
        try {
            if (running || session.approval().isSome()) {
                let _ = session.enqueue(
                    prompt.id,
                    prompt.command,
                    prompt.message
                )
                return
            }
            running = true
        } finally {
            lock.unlock()
        }
        let _ = spawn {runPrompts(prompt)}
    }

    private func runPrompts(first: RpcPrompt): Unit {
        var current: ?RpcPrompt = Some(first)
        while (current.isSome()) {
            let prompt = current.getOrThrow()
            let result = session.handle(prompt.message)
            if (prompt.publishResult) {
                publishPromptResult(prompt, result)
            }
            current = takeNext(result)
        }
    }

    private func startDecision(decision: RpcDecision): Bool {
        lock.lock()
        try {
            if (running) {
                return false
            }
            running = true
        } finally {
            lock.unlock()
        }
        let _ = spawn {
            let result = session.decide(
                decision.operationId,
                decision.decision
            )
            publishDecision(decision, result)
            match (takeNext(result)) {
                case Some(prompt) => runPrompts(prompt)
                case None => ()
            }
        }
        true
    }

    private func publishDecision(
        decision: RpcDecision,
        result: Result<ApplicationResponse>
    ): Unit {
        match (result) {
            case Result.Err(error) => emitFrame(
                failure(
                    decision.id,
                    decision.command,
                    error.message
                )
            )
            case Result.Ok(response) => match (response.approval) {
                case Some(approval) => emitFrame(encodeAgentValue(productApprovalFrame(approval)))
                case None => ()
            }
        }
    }

    private func takeNext(result: Result<ApplicationResponse>): ?RpcPrompt {
        lock.lock()
        try {
            match (session.takeQueuedAtSafeBoundary(result)) {
                case Some(next) => Some(
                    RpcPrompt(
                        next.correlationId,
                        next.kind,
                        next.input
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

    private func publishPromptResult(
        prompt: RpcPrompt,
        result: Result<ApplicationResponse>
    ): Unit {
        match (result) {
            case Result.Err(error) => emitFrame(
                failure(
                    prompt.id,
                    prompt.command,
                    error.message
                )
            )
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

    private func runBash(
        id: String,
        command: String,
        source: String
    ): String {
        match (session.executeBash(source)) {
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
                        ValueField("truncated", boolValue(false))
                    ]
                )
            )
            case Result.Err(error) => failure(id, command, error.message)
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
            case Result.Err(error) => failure(id, command, error.message)
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
                    match (session.todoPhases()) {
                        case Result.Ok(phases) => encodeTodoPhases(phases)
                        case Result.Err(_) => listValue([])
                    }
                ),
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
                            textValue(base64Bytes(bytes[start..end]))
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

    init(
        id: String,
        command: String,
        message: String,
        publishResult!: Bool = true
    ) {
        this.id = id
        this.command = command
        this.message = message
        this.publishResult = publishResult
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

func commandsValue(): AgentValue {
    let values = ArrayList<AgentValue>()
    // Slash-command discovery is UI/product metadata. Keep it independent
    // from availableRpcCommands(), which is the transport protocol inventory.
    for (command in slashCommandDefinitions()) {
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

public func availableRpcCommands(): Array<String> {
    [
        "negotiate_protocol",
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
            Int64.parse(item.number)
        } catch (_: Exception) {
            0
        }
        case None => 0
    }
}

func productBoolField(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.kind == ValueKind.Boolean && item.boolean
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

func base64Bytes(bytes: Array<UInt8>): String {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    let chars = ArrayList<UInt8>()
    var index: Int64 = 0
    while (index < bytes.size) {
        let first = UInt32(bytes[index])
        let second = if (index + 1 < bytes.size) {
            UInt32(bytes[index + 1])
        } else {
            UInt32(0)
        }
        let third = if (index + 2 < bytes.size) {
            UInt32(bytes[index + 2])
        } else {
            UInt32(0)
        }
        let packed = (first << 16) | (second << 8) | third
        appendBase64(chars, alphabet, Int64((packed >> 18) & 63))
        appendBase64(chars, alphabet, Int64((packed >> 12) & 63))
        if (index + 1 < bytes.size) {
            appendBase64(chars, alphabet, Int64((packed >> 6) & 63))
        } else {
            chars.add(b'=')
        }
        if (index + 2 < bytes.size) {
            appendBase64(chars, alphabet, Int64(packed & 63))
        } else {
            chars.add(b'=')
        }
        index += 3
    }
    String.fromUtf8(chars.toArray())
}

func appendBase64(
    output: ArrayList<UInt8>,
    alphabet: String,
    index: Int64
): Unit {
    output.add(unsafe { alphabet.rawData() }[index])
}
