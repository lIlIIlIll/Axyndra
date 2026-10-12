package model_provider_runtime

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*

class ProviderToolStream {
    let name: String
    var arguments = ""
    var completed = false
    init(name: String) { this.name = name }
}

class ProviderStream {
    private let lock = Mutex()
    private let dispatch: ModelProviderDispatch
    private let events: ModelEventSink
    private let request: ModelRequest
    private let providerId: String
    private let identity: String
    private let maximumFrameBytes: Int64
    private let budgetRetainedFrames: Bool
    private var retainedBudget: ?LogicalJsonOwnerReservation = None
    private var next: Int64 = 1
    private var receivedBytes: Int64 = 0
    private var closed = false
    private var started = false
    private var transportClosed = false
    private var text = ""
    private var reasoning = ""
    private var reply: ?ModelReply = None
    private var fault: ?AgentError = None
    private var usage: ?ModelUsage = None
    private var observedTerminal: ?TerminalEvidence = None
    private let tools = HashMap<String, ProviderToolStream>()
    private let blocks = HashMap<Int64, String>()
    private let completedBlocks = HashSet<Int64>()

    init(dispatch: ModelProviderDispatch, request: ModelRequest, events: ModelEventSink, providerId: String,
        payloadLimits!: ?ServicePayloadLimits = None) {
        this.dispatch = dispatch; this.request = request; this.events = events; this.providerId = providerId
        this.identity = canonicalAgentValue(dispatch.identity())
        this.budgetRetainedFrames = payloadLimits.isSome()
        this.maximumFrameBytes = match (payloadLimits) { case Some(value) => value.maxResultBytes + 65536; case None => 262144 }
    }

    func receive(raw: AgentValue): Result<Unit> {
        lock.lock()
        try {
            if (closed || fault.isSome() || reply.isSome()) {
                return fail("model.provider_late_frame")
            }
            match (dispatch.check()) { case Result.Err(error) => fault = Some(error); return Result.Err(error)
                case Result.Ok(_) => () }
            let encoded = raw.stringify()
            if (encoded.size > maximumFrameBytes || receivedBytes > 67108864 - encoded.size || next > 262144) {
                return fail("model.provider_output_limit")
            }
            receivedBytes += encoded.size
            // The message charge lasts through this callback. Semantic text,
            // Tool arguments and final reply may remain until finish(): charge
            // those copies separately on the same aggregate pool, not as a
            // second transfer reservation or authority registry.
            if (budgetRetainedFrames) {
                if (retainedBudget.isNone()) { retainedBudget = Some(modelLogicalOwnerBudget.acquire(1)) }
                retainedBudget.getOrThrow().ensureDecoded(receivedBytes, 65536)
            }
            let frame = parseUnifiedJson(encoded, maxBytes: maximumFrameBytes, maxDepth: 64)
            providerExact(frame, ["schema", "identity", "sequence", "kind", "payload"])
            if (providerText(frame, "schema") != MODEL_PROVIDER_PROTOCOL ||
                canonicalAgentValue(providerField(frame, "identity")) != identity ||
                providerInt(frame, "sequence") != next) { return fail("model.provider_frame_identity") }
            next += 1
            let payload = providerField(frame, "payload")
            match (providerText(frame, "kind")) {
                case "event" => acceptEvent(payload)
                case "usage" =>
                    let value = providerUsage(payload)
                    match (usage) { case Some(previous) =>
                        if (value.inputTokens < previous.inputTokens || value.outputTokens < previous.outputTokens ||
                            value.reasoningTokens < previous.reasoningTokens) { return fail("model.provider_usage_regressed") }
                        case None => () }
                    usage = Some(value)
                    events(ModelEvent.UsageUpdated(value.inputTokens, value.outputTokens))
                    Result.Ok(())
                case "reply" | "reply_stream" =>
                    let value = if (providerText(frame, "kind") == "reply_stream") {
                        if (!request.streaming || !started || observedTerminal.isNone() || !transportClosed) {
                            return fail("model.provider_compact_order")
                        }
                        let restored = restoreModelProviderStreamReply(payload, text, reasoning)
                        // Preserve the exact ordinary final-frame encoding limit.
                        // A small reference cannot smuggle a larger semantic reply.
                        if (modelProviderFrame(dispatch.identity(), next - 1, "reply", restored).stringify().size > maximumFrameBytes) {
                            return fail("model.provider_output_limit")
                        }
                        providerReply(restored)
                    } else { providerReply(payload) }
                    validateReply(value)
                    usage = Some(value.usage)
                    events(ModelEvent.UsageUpdated(value.inputTokens, value.outputTokens))
                    reply = Some(value)
                    Result.Ok(())
                case "failure" =>
                    fault = Some(providerFailureValue(payload))
                    Result.Ok(())
                case _ => fail("model.provider_frame_kind")
            }
        } catch (_: Exception) { fail("model.provider_frame_invalid") }
        finally { lock.unlock() }
    }

    func closePayloadBudget(): Unit {
        let selected = { => lock.lock(); try { let value = retainedBudget; retainedBudget = None; value }
            finally { lock.unlock() } }()
        match (selected) { case Some(value) => value.close(); case None => () }
    }

    private func acceptEvent(value: AgentValue): Result<Unit> {
        let kind = providerText(value, "kind")
        match (kind) {
            case "text" | "reasoning" =>
                providerExact(value, ["kind", "text"])
                if (!started || observedTerminal.isSome()) { return fail("model.provider_event_order") }
                let delta = providerText(value, "text")
                if (kind == "text") { text += delta; events(ModelEvent.TextDelta(delta)) }
                else { reasoning += delta; events(ModelEvent.ReasoningDelta(delta)) }
            case "tool_start" =>
                providerExact(value, ["kind", "id", "name"])
                if (!started || observedTerminal.isSome()) { return fail("model.provider_event_order") }
                let id = providerText(value, "id"); let name = providerText(value, "name")
                providerIdentifier(id); providerIdentifier(name)
                if (tools.contains(id) || tools.size >= 1024) { return fail("model.provider_tool_duplicate") }
                var declared = false
                for (tool in request.tools where tool.name == name) { declared = true }
                if (!declared || providerNoTools(request.toolChoice)) { return fail("model.provider_tool_undeclared") }
                tools.add(id, ProviderToolStream(name))
                events(ModelEvent.ToolCallStarted(id, name))
            case "tool_arguments" | "tool_end" =>
                providerExact(value, if (kind == "tool_arguments") { ["kind", "id", "text"] } else { ["kind", "id"] })
                let id = providerText(value, "id")
                let tool = match (tools.get(id)) { case Some(item) => item
                    case None => return fail("model.provider_tool_order") }
                if (tool.completed || observedTerminal.isSome()) { return fail("model.provider_tool_order") }
                if (kind == "tool_arguments") {
                    let delta = providerText(value, "text"); tool.arguments += delta
                    events(ModelEvent.ToolArgumentsDelta(id, delta))
                } else { tool.completed = true; events(ModelEvent.ToolCallCompleted(id)) }
            case "started" =>
                providerExact(value, ["kind", "protocol"])
                if (started) { return fail("model.provider_event_order") }
                started = true
                events(ModelEvent.ProviderProgress(ProviderStreamEvent.StreamStarted(providerText(value, "protocol"))))
            case "block_start" | "block_end" =>
                providerExact(value, ["kind", "index", "block_kind"])
                let index = providerInt(value, "index"); let blockKind = providerText(value, "block_kind")
                if (!started || observedTerminal.isSome() || index < 0 || index > 4095 ||
                    !["text", "reasoning", "tool_call", "refusal", "opaque"].contains(blockKind)) { return fail("model.provider_block_order") }
                if (kind == "block_start") {
                    if (blocks.contains(index) || completedBlocks.contains(index)) { return fail("model.provider_block_order") }
                    blocks.add(index, blockKind); events(ModelEvent.ProviderProgress(ProviderStreamEvent.ContentBlockStarted(index, blockKind)))
                } else {
                    if (blocks.get(index) != Some(blockKind)) { return fail("model.provider_block_order") }
                    blocks.remove(index); completedBlocks.add(index); events(ModelEvent.ProviderProgress(ProviderStreamEvent.ContentBlockCompleted(index, blockKind)))
                }
            case "terminal" =>
                providerExact(value, ["kind", "evidence"])
                if (!started || observedTerminal.isSome() || !blocks.isEmpty()) { return fail("model.provider_terminal_order") }
                let terminal = providerTerminal(providerField(value, "evidence"))
                if (!terminal.messageTerminalObserved) { return fail("model.provider_terminal_missing") }
                observedTerminal = Some(terminal)
                events(ModelEvent.ProviderProgress(ProviderStreamEvent.MessageTerminalObserved(terminal)))
            case "usage_counts" | "usage_delta" | "usage_completed" =>
                providerExact(value, ["kind", "input", "output"])
                let input = providerInt(value, "input"); let output = providerInt(value, "output")
                if (input < 0 || output < 0) { return fail("model.provider_usage_invalid") }
                // Preserve existing progress; counts alone never invent final
                // accounting evidence. Final usage is validated separately.
                if (kind == "usage_counts") { events(ModelEvent.UsageUpdated(input, output)) }
                else if (kind == "usage_delta") { events(ModelEvent.ProviderProgress(ProviderStreamEvent.UsageDelta(input, output))) }
                else { events(ModelEvent.ProviderProgress(ProviderStreamEvent.UsageCompleted(input, output))) }
            case "provider_error" =>
                providerExact(value, ["kind"])
                events(ModelEvent.ProviderProgress(ProviderStreamEvent.ProviderError("provider reported an error")))
            case "transport_closed" =>
                providerExact(value, ["kind"])
                if (transportClosed) { return fail("model.provider_event_order") }
                transportClosed = true
                events(ModelEvent.ProviderProgress(ProviderStreamEvent.StreamTransportClosed))
            case _ => return fail("model.provider_event_kind")
        }
        Result.Ok(())
    }

    private func validateReply(value: ModelReply): Unit {
        if (value.providerId != providerId || value.blocks.size > 4096) {
            throw IllegalArgumentException("provider terminal identity changed")
        }
        let terminal = value.terminalEvidence.getOrThrow()
        if (!terminal.messageTerminalObserved || !blocks.isEmpty() || value.validationVersion < 1) {
            throw IllegalArgumentException("provider reply lacks a validated terminal")
        }
        match (observedTerminal) { case Some(previous) =>
            if (previous.protocol != terminal.protocol || previous.terminalEventKind != terminal.terminalEventKind ||
                previous.rawStopReason != terminal.rawStopReason || previous.adapterVersion != terminal.adapterVersion ||
                previous.messageTerminalObserved != terminal.messageTerminalObserved ||
                (previous.streamEofObserved && !terminal.streamEofObserved) ||
                (!previous.streamEofObserved && terminal.streamEofObserved && !transportClosed)) {
                throw IllegalArgumentException("provider terminal changed without matching transport evidence")
            }
            case None => () }
        let ids = HashSet<String>()
        var finalText = ""; var finalReasoning = ""
        for (block in value.blocks) {
            match (block.kind) {
                case ModelBlockKind.ToolResult | ModelBlockKind.Image => throw IllegalArgumentException("invalid assistant output kind")
                case ModelBlockKind.Text => finalText += block.text
                case ModelBlockKind.Reasoning => finalReasoning += block.text
                case ModelBlockKind.ToolCall =>
                    providerIdentifier(block.callId); providerIdentifier(block.name)
                    if (ids.contains(block.callId) || block.arguments.unifiedKind != ValueKind.Object ||
                        providerNoTools(request.toolChoice)) { throw IllegalArgumentException("invalid final tool call") }
                    ids.add(block.callId)
                    var declared = false
                    for (tool in request.tools where tool.name == block.name) { declared = true }
                    if (!declared) { throw IllegalArgumentException("undeclared final tool call") }
                    match (tools.get(block.callId)) { case Some(stream) =>
                        if (!stream.completed || stream.name != block.name || canonicalAgentValue(parseUnifiedJson(stream.arguments)) !=
                            canonicalAgentValue(block.arguments)) { throw IllegalArgumentException("streamed tool call drift") }
                        case None => if (request.streaming) { throw IllegalArgumentException("missing streamed tool call") } }
                case _ => ()
            }
        }
        if ((!text.isEmpty() && text != finalText) || (!reasoning.isEmpty() && reasoning != finalReasoning) ||
            (request.streaming && ids.size != tools.size)) { throw IllegalArgumentException("partial output differs from terminal") }
        if (!request.parallelToolCalls && ids.size > 1) { throw IllegalArgumentException("unexpected parallel tool calls") }
        match (usage) { case Some(previous) =>
            if (value.inputTokens < previous.inputTokens || value.outputTokens < previous.outputTokens ||
                value.reasoningTokens < previous.reasoningTokens) { throw IllegalArgumentException("terminal usage regressed") }
            case None => () }
    }

    private func fail(code: String): Result<Unit> {
        let error = AgentError(AgentErrorKind.Protocol, code, "invalid model provider protocol",
            attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError)))
        fault = Some(error)
        Result.Err(error)
    }
    func finish(transport: Result<Unit>): Result<ModelReply> {
        lock.lock()
        try {
            closed = true
            let current = dispatch.check()
            // Actual cancellation/revocation beats a late success; partial usage
            // still accompanies the failure for Core's existing budget ledger.
            let error: ?AgentError = match (current) { case Result.Err(e) => Some(e)
                case Result.Ok(_) => match (fault) { case Some(e) => Some(e)
                    case None => transport.error() } }
            match (error) { case Some(value) => return Result.Err(withUsage(value)); case None => () }
            match (reply) {
                case Some(value) => events(ModelEvent.Completed); Result.Ok(value)
                case None => Result.Err(withUsage(AgentError(AgentErrorKind.Protocol, "model.provider_terminal_missing",
                    "provider endpoint ended without a terminal reply",
                    attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderTerminalMissing)))))
            }
        } catch (_: Exception) {
            providerFailure(AgentErrorKind.Protocol, "model.provider_callback_failed", AttemptFailureKind.ProviderProtocolError)
        } finally { lock.unlock() }
    }
    private func withUsage(error: AgentError): AgentError {
        let fields = ArrayList<ErrorField>()
        for (field in error.fields where usage.isNone() || !field.name.startsWith("usage_")) { fields.add(field) }
        match (usage) { case None => (); case Some(value) =>
            fields.add(ErrorField("usage_input_tokens", value.inputTokens.toString()))
            fields.add(ErrorField("usage_output_tokens", value.outputTokens.toString()))
            fields.add(ErrorField("usage_reasoning_tokens", value.reasoningTokens.toString()))
            fields.add(ErrorField("usage_cache_read_tokens", value.cacheReadTokens.toString()))
            fields.add(ErrorField("usage_cache_write_tokens", value.cacheWriteTokens.toString()))
            fields.add(ErrorField("usage_source", modelUsageSourceName(value.source)))
            match (value.evidence) { case None => (); case Some(e) =>
                fields.add(ErrorField("usage_protocol", e.protocol)); fields.add(ErrorField("usage_event", e.eventKind))
                fields.add(ErrorField("usage_response_id", e.providerResponseId)) }
        }
        AgentError(error.kind, error.code, error.message, retryable: error.retryable, fallbackAllowed: error.fallbackAllowed, fields: fields.toArray(),
            attemptFailure: error.attemptFailure)
    }
}

func providerNoTools(value: ModelToolChoice): Bool {
    match (value) { case ModelToolChoice.NoTools => true; case _ => false }
}
