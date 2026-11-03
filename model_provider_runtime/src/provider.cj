package model_provider_runtime

import agent_domain.*
import agent_ports.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*

public class PluginModelPort <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    private let binding: ModelProviderBinding
    private let gate: ModelProviderDispatchGate
    private let endpoint: ModelProviderEndpoint
    private let lock = Mutex()
    private var consumed: ?HashSet<String> = Some(HashSet<String>())
    private var active: ?HashMap<String, ModelProviderDispatch> = Some(HashMap<String, ModelProviderDispatch>())
    private var inputFrames159: Int64 = 0
    private var inputClosing159 = false
    private var inputRetiring159 = false
    private var inputClosed159 = false
    private var inputIdentities159: ?ProviderInputIdentity159 = None<ProviderInputIdentity159>

    public init(binding: ModelProviderBinding, gate: ModelProviderDispatchGate, endpoint: ModelProviderEndpoint) {
        this.binding = binding; this.gate = gate; this.endpoint = endpoint
    }

    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        // Use the real private serializer. On an exception keep the loan;
        // ordinary None remains the original public compatibility behavior.
        try {
            let value = snapshot(request)
            loan.returnModelToolsFrame159()
            Some(value)
        } catch (_: Exception) { None }
    }
    public func transcriptSnapshot(request: ModelRequest): ?String {
        try { Some(snapshot(request)) } catch (_: Exception) { None }
    }
    public func validateTranscriptSnapshot(snapshot: String): Bool {
        try {
            let value = parseUnifiedJson(snapshot, maxBytes: 67108864, maxDepth: 64)
            providerExact(value, ["schema", "binding_digest", "request"])
            if (providerText(value, "schema") != MODEL_PROVIDER_SNAPSHOT ||
                providerText(value, "binding_digest") != binding.digest) { return false }
            let request = match (modelRequestFromSnapshotValue(providerField(value, "request"), "snapshot-validation")) {
                case Result.Ok(value) => value; case Result.Err(_) => return false }
            canonicalAgentValuesEqual(value, parseUnifiedJson(this.snapshot(request), maxBytes: 67108864))
        } catch (_: Exception) { false }
    }

    private func snapshot(request: ModelRequest): String {
        if (binding.validate(request).isError()) { throw IllegalArgumentException("model feature unsupported") }
        if (request.model != binding.model || (!request.tools.isEmpty() && !binding.supportsTools) ||
            (request.structuredOutput.isSome() && !binding.supportsStructuredOutput)) {
            throw IllegalArgumentException("model provider capability mismatch")
        }
        for (message in request.messages) { for (block in message.blocks) {
            if (block.kind == ModelBlockKind.Image && !binding.supportsImages) {
                throw IllegalArgumentException("model provider does not support images")
            }
        } }
        match (request.resolvedPolicy) { case Some(policy) =>
            if (policy.capabilityFingerprint != binding.capabilityFingerprint) {
                throw IllegalArgumentException("model provider capability snapshot changed")
            }
            case None => () }
        let value = objectValue([ValueField("schema", textValue(MODEL_PROVIDER_SNAPSHOT)),
            ValueField("binding_digest", textValue(binding.digest)),
            ValueField("request", modelRequestSnapshotValue(request))]).stringify()
        if (value.size > 67108864) { throw IllegalArgumentException("model input exceeds current protocol ceiling") }
        // Deep freeze and strict depth/duplicate validation; never runs a plugin.
        parseUnifiedJson(value, maxBytes: 67108864, maxDepth: 64).stringify()
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        if (!beginInputFrame159()) { return inputCachePending159<ModelReply>() }
        try { executeFrame159(request, events) } finally { endInputFrame159() }
    }
    private func executeFrame159(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        executeInputFrame159(request, events, request.requestId, None<ProviderInputIdentity159>)
    }
    private func beginInputFrame159(allowClosing!: Bool = false): Bool {
        lock.lock(); try {
            if (inputClosed159 || inputRetiring159 || (inputClosing159 && !allowClosing)) { return false }
            inputFrames159++; true
        } finally { lock.unlock() }
    }
    private func endInputFrame159(): Unit {
        lock.lock(); try { inputFrames159-- } finally { lock.unlock() }
    }
    private func inputCachePending159<T>(): Result<T> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "model.input_cache_pending",
            "Model input consumers or retained observations have not returned"))
    }
    // DATA retirement only. Never authorizes execution, clears a Run, retries
    // a Tool, or interprets cancellation/registry close as an input receipt.
    public func retireInputCache159(): Result<Unit> {
        lock.lock()
        try {
            if (inputClosed159) { return Result.Ok(()) }
            inputClosing159 = true
            if (inputFrames159 != 0 || inputRetiring159 || !active.getOrThrow().isEmpty()) {
                return inputCachePending159<Unit>() }
            var cursor = inputIdentities159
            while (cursor.isSome()) {
                let item = cursor.getOrThrow()
                if (!item.isReturned159()) { return inputCachePending159<Unit>() }
                cursor = item.portNext159
            }
            inputRetiring159 = true
            // Drop the whole backing, not only entries in a retained table.
            consumed = None<HashSet<String>>
            active = None<HashMap<String, ModelProviderDispatch>>
        } finally { lock.unlock() }
        try {
            while (true) {
                let paid = clearInputIdentityFrame159()
                match (paid) { case Some(value) => value.close(); case None => break }
            }
            lock.lock(); try { inputClosed159 = true } finally { lock.unlock() }
            Result.Ok(())
        } finally { lock.lock(); try { inputRetiring159 = false } finally { lock.unlock() } }
    }
    private func clearInputIdentityFrame159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            match (inputIdentities159) {
                case None => None<LogicalJsonOwnerReservation>
                case Some(value) =>
                    inputIdentities159 = value.portNext159
                    value.clearCacheReferences159()
            }
        } finally { lock.unlock() }
    }

    private func executeInputFrame159(request: ModelRequest, events: ModelEventSink,
        requestId: String, retained: ?ProviderInputIdentity159): Result<ModelReply> {
        let frozen = try { providerIdentifier(requestId); snapshot(request) }
            catch (_: Exception) { return providerFailure(AgentErrorKind.InvalidInput,
                "model.provider_input_invalid", AttemptFailureKind.ProviderProtocolError) }
        let neutral = providerField(parseUnifiedJson(frozen, maxBytes: 67108864), "request")
        let decoded = match (modelRequestFromSnapshotValue(neutral, requestId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let copied = ModelRequest(decoded.model, decoded.messages, system: decoded.system, tools: decoded.tools,
            thinking: decoded.thinking, wireMaxOutputTokens: Some(decoded.wireMaxOutputTokens),
            resolvedPolicy: decoded.resolvedPolicy, streaming: decoded.streaming, parallelToolCalls: decoded.parallelToolCalls,
            requestId: decoded.requestId, serviceTier: decoded.serviceTier, cachePolicy: decoded.cachePolicy,
            cacheKey: decoded.cacheKey, toolChoice: decoded.toolChoice, structuredOutput: decoded.structuredOutput,
            transportHardTimeoutMillis: request.transportHardTimeoutMillis)
        // The port never starts an Attempt. The gate must find the existing
        // exact claimed Attempt and retain its current owner cancellation.
        let authorization = try { gate.open(copied, binding, frozen) } catch (_: Exception) {
            providerFailure<ModelProviderDispatch>(AgentErrorKind.PermissionDenied,
                "model.provider_authority_invalid", AttemptFailureKind.ProviderProtocolError) }
        let authorized = match (authorization) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        // Preserve the host gate's exact authority object all the way through
        // endpoint launch; this object already owns a linked cancellation.
        let dispatch = authorized
        match (retained) { case Some(value) => value.observe159(dispatch); case None => () }
        try {
        let inputDigest = canonicalAgentValueSha256(neutral)
        if (dispatch.requestId != requestId || dispatch.bindingDigest != binding.digest ||
            dispatch.inputDigest != inputDigest) {
            return providerFailure(AgentErrorKind.PermissionDenied, "model.provider_dispatch_mismatch",
                AttemptFailureKind.ProviderProtocolError)
        }
        match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (consumed.getOrThrow().contains(requestId)) {
                return providerFailure(AgentErrorKind.RecoveryRequired, "model.provider_request_replayed",
                    AttemptFailureKind.ProviderProtocolError)
            }
            if (consumed.getOrThrow().size >= 4096) {
                return providerFailure(AgentErrorKind.BudgetExceeded, "model.provider_instance_capacity",
                    AttemptFailureKind.ProviderProtocolError)
            }
            consumed.getOrThrow().add(requestId); active.getOrThrow().add(requestId, dispatch)
        } finally { lock.unlock() }
        let stream = ProviderStream(dispatch, copied, events, binding.providerId, payloadLimits: endpoint.payloadLimits(dispatch))
        let callback159 = match (retained) {
            case Some(value) => Some(value.cancellationBridge159(endpoint))
            case None => None<ProviderInputCancellation159>
        }
        let registration = match (callback159) {
            case Some(value) => dispatch.cancellation.onCancelReturning159({ _ => value.cancel159() })
            case None => dispatch.cancellation.onCancel({ _ =>
                try { let _ = endpoint.cancel(requestId) } catch (_: Exception) {} })
        }
        match (callback159) { case Some(value) => value.registration159(registration); case None => () }
        try {
            let result: Result<Unit> = try {
                match (dispatch.check()) { case Result.Err(error) => Result<Unit>.Err(error)
                    case Result.Ok(_) => endpoint.execute(objectValue([
                        ValueField("schema", textValue(MODEL_PROVIDER_PROTOCOL)), ValueField("type", textValue("execute")),
                        ValueField("identity", dispatch.identity()), ValueField("binding", binding.snapshot()),
                        ValueField("request", neutral),
                        ValueField("transport_hard_timeout_ms", integerValue(request.transportHardTimeoutMillis))
                    ]), dispatch, { frame => stream.receive(frame) }) }
            } catch (_: Exception) { providerFailure<Unit>(AgentErrorKind.Transport,
                "model.provider_endpoint_failed", AttemptFailureKind.ProviderTransportError) }
            stream.finish(result)
        } finally {
            stream.closePayloadBudget()
            registration.dispose()
            match (callback159) { case Some(value) => value.stop159(); case None => () }
            lock.lock()
            try { active.getOrThrow().remove(requestId) } finally { lock.unlock() }
        }
            } finally { authorized.close() }
    }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        funding: ModelInputDataBudget159): ModelInputReturn159 {
        if (!beginInputFrame159()) { return ModelInputReturn159.Held(inputCachePending159<ModelReply>()) }
        try { executeReturningInput159Frame159(request, events, funding) } finally { endInputFrame159() }
    }
    private func executeReturningInput159Frame159(request: ModelRequest, events: ModelEventSink,
        funding: ModelInputDataBudget159): ModelInputReturn159 {
        // Validate the original bounded identifier before constructing any
        // additional String, node or callback. The original error is retained.
        try { providerIdentifier(request.requestId) }
        catch (_: Exception) { return ModelInputReturn159.Held(providerFailure<ModelReply>(
            AgentErrorKind.InvalidInput, "model.provider_input_invalid", AttemptFailureKind.ProviderProtocolError)) }
        let paid = funding.reserveRetainedModelMetadata159(8192 + 8 * request.requestId.size)
        let retained = ProviderInputIdentity159(paid)
        retained.copyIdentity159(request.requestId)
        lock.lock()
        try { retained.portNext159 = inputIdentities159; inputIdentities159 = Some(retained) }
        finally { lock.unlock() }
        let result = executeInputFrame159(request, events, retained.text159(), Some(retained))
        // The whole producer/callback/codec frame is gone. Only a successful
        // concrete exchange can certify return; unknown errors keep custody.
        if (result.isOk()) {
            retained.recordSuccessfulFrame159(gate, endpoint)
            if (retained.inputAliasesReturned159()) { return ModelInputReturn159.Returned(result) }
            return ModelInputReturn159.Pending(result, retained)
        }
        ModelInputReturn159.Held(result)
    }

    public func cancel(requestId: String): Result<Unit> {
        if (!beginInputFrame159(allowClosing: true)) { return inputCachePending159<Unit>() }
        try { cancelFrame159(requestId) } finally { endInputFrame159() }
    }
    private func cancelFrame159(requestId: String): Result<Unit> {
        let pending = { => lock.lock(); try { active.getOrThrow().get(requestId) } finally { lock.unlock() } }()
        match (pending) { case Some(value) => let _ = value.cancel(); case None => return Result.Ok(()) }
        try { endpoint.cancel(requestId) } catch (_: Exception) {
            providerFailure(AgentErrorKind.Transport, "model.provider_cancel_failed", AttemptFailureKind.ProviderTransportError)
        }
    }
}
