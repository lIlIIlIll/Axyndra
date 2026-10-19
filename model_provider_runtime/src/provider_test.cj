package model_provider_runtime

import agent_domain.*
import agent_ports.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

func providerTestBinding(configuration!: AgentValue = objectValue([]), tools!: Bool = false): ModelProviderBinding {
    ModelProviderBinding("fixture", "sha256:" + modelPolicySha256Text("pkg"), modelPolicySha256Text("config"),
        "instance", "model", "fixture-model", "wire-model",
        ModelExecutionCapabilitiesSnapshot("fixture-model", ThinkingCapabilities(ThinkingControlMode.NoThinking), 4096),
        configuration: configuration, supportsTools: tools, providerId: "fixture")
}
func providerTestRequest(id!: String = "req", tools!: Array<ModelToolDefinition> = []): ModelRequest {
    ModelRequest("fixture-model", [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "hello")])],
        requestId: id, thinking: ThinkingLevel.Off, tools: tools, parallelToolCalls: false, streaming: true)
}
func providerTestReply(text!: String = "hello", usage!: ModelUsage = ModelUsage()): ModelReply {
    ModelReply([ModelBlock(ModelBlockKind.Text, text: text)], stopReason: "stop", usage: Some(usage),
        providerId: "fixture", responseId: "response", terminalEvidence: Some(TerminalEvidence("fixture", "terminal",
            rawStopReason: "stop", messageTerminalObserved: true, streamEofObserved: true, adapterVersion: "fixture-1")),
        completionDisposition: CompletionDisposition.Complete, decisionOutcome: DecisionOutcome.Response, validationVersion: 1)
}
class ProviderTestGate <: ModelProviderDispatchGate {
    let source = CancellationSource()
    var allowed = true
    var calls: Int64 = 0
    public func open(request: ModelRequest, binding: ModelProviderBinding, snapshot: String): Result<ModelProviderDispatch> {
        calls += 1
        if (!allowed) { return providerFailure(AgentErrorKind.PermissionDenied, "fixture.grant_denied", AttemptFailureKind.ProviderProtocolError) }
        Result.Ok(ModelProviderDispatch(ModelAttemptId("attempt"), RunId("run"), ThreadId("thread"), 1,
            request.requestId, binding.digest, modelPolicySha256Text(canonicalAgentValue(modelRequestSnapshotValue(request))),
            source.token, { => if (allowed) { Result.Ok(()) } else {
                providerFailure(AgentErrorKind.PermissionDenied, "fixture.grant_revoked", AttemptFailureKind.ProviderProtocolError) } }))
    }
}
class ProviderTestEndpoint <: ModelProviderEndpoint {
    var calls: Int64 = 0
    var cancelled: Int64 = 0
    var action: (ModelProviderDispatch, ModelProviderFrameSink) -> Result<Unit> = { dispatch, frames =>
        frames(modelProviderFrame(dispatch.identity(), 1, "reply", modelProviderReplyValue(providerTestReply()))) }
    public func execute(input: AgentValue, dispatch: ModelProviderDispatch, frames: ModelProviderFrameSink): Result<Unit> {
        calls += 1; action(dispatch, frames)
    }
    public func cancel(requestId: String): Result<Unit> { cancelled += 1; Result.Ok(()) }
}

class ProviderTestObservations {
    var completed: Int64 = 0
    var progress: Int64 = 0
    var callback: ?ModelProviderFrameSink = None
    var identity: AgentValue = objectValue([])
}

@Test
class ModelProviderBoundaryTests {
    @TestCase
    func frozenConfigurationAndTranscriptCannotAliasCallerJson(): Unit {
        let config = objectValue([ValueField("endpoint", textValue("original"))])
        let binding = providerTestBinding(configuration: config)
        let fingerprint = binding.digest
        config.put("endpoint", textValue("mutated"))
        binding.snapshot().field("configuration").getOrThrow().put("endpoint", textValue("mutated again"))
        @Expect(binding.digest == fingerprint)
        @Expect(binding.snapshot().field("configuration").getOrThrow().field("endpoint").getOrThrow().text == "original")
    }
    @TestCase
    func prepareAndSnapshotValidationHaveZeroEndpointAndGrantCalls(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        let port = PluginModelPort(providerTestBinding(), gate, endpoint)
        let value = port.transcriptSnapshot(providerTestRequest()).getOrThrow()
        @Expect(port.validateTranscriptSnapshot(value))
        @Expect(gate.calls == 0 && endpoint.calls == 0)
        let drift = parseUnifiedJson(value); drift.put("binding_digest", textValue(modelPolicySha256Text("other")))
        @Expect(!port.validateTranscriptSnapshot(drift.stringify()))
        @Expect(!port.validateTranscriptSnapshot("{}"))
    }
    @TestCase
    func wrongSchemaOrCapabilityFailsBeforeAuthorityAndIo(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        let port = PluginModelPort(providerTestBinding(), gate, endpoint)
        let request = providerTestRequest(tools: [ModelToolDefinition("probe", "probe", objectValue([]))])
        @Expect(port.execute(request, { _ => () }).error().getOrThrow().code == "model.provider_input_invalid")
        @Expect(gate.calls == 0 && endpoint.calls == 0)
    }
    @TestCase
    func deniedGrantAndDuplicateRequestNeverRedispatch(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        let port = PluginModelPort(providerTestBinding(), gate, endpoint)
        gate.allowed = false
        @Expect(port.execute(providerTestRequest(), { _ => () }).isError())
        @Expect(endpoint.calls == 0)
        gate.allowed = true
        @Expect(port.execute(providerTestRequest(), { _ => () }).isOk())
        @Expect(port.execute(providerTestRequest(), { _ => () }).error().getOrThrow().code == "model.provider_request_replayed")
        @Expect(endpoint.calls == 1)
    }
    @TestCase
    func wrongIdentityAndDuplicateSequenceCannotProduceCompletedEvent(): Unit {
        for (mode in ["identity", "sequence"]) {
            let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
            endpoint.action = { dispatch, frames =>
                let identity = dispatch.identity()
                if (mode == "identity") { identity.put("epoch", integerValue(2)) }
                let start = modelProviderFrame(identity, 1, "event", objectValue([
                    ValueField("kind", textValue("started")), ValueField("protocol", textValue("fixture"))]))
                let _ = frames(start)
                frames(modelProviderFrame(identity, 1, "reply", modelProviderReplyValue(providerTestReply())))
            }
            let observations = ProviderTestObservations()
            let result = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { event =>
                match (event) { case ModelEvent.Completed => observations.completed += 1; case _ => () } })
            @Expect(result.isError() && observations.completed == 0)
        }
    }
    @TestCase
    func currentRevocationOverridesLateSuccessAndPreventsFurtherFrames(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        endpoint.action = { dispatch, frames =>
            gate.allowed = false
            let _ = frames(modelProviderFrame(dispatch.identity(), 1, "reply", modelProviderReplyValue(providerTestReply())))
            Result.Ok(())
        }
        let result = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () })
        @Expect(result.error().getOrThrow().code == "fixture.grant_revoked")
    }
    @TestCase
    func partialUsageSurvivesEndpointFailureWithoutInventingCost(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        endpoint.action = { dispatch, frames =>
            let _ = frames(modelProviderFrame(dispatch.identity(), 1, "usage", modelProviderUsageValue(ModelUsage(
                inputTokens: 11, outputTokens: 3, reasoningTokens: 1, cacheReadTokens: 4, cacheWriteTokens: 2,
                source: ModelUsageSource.ProviderStreamFinal,
                evidence: Some(ModelUsageEvidence("fixture", "usage_final", providerResponseId: "response"))))))
            providerFailure(AgentErrorKind.Transport, "fixture.eof", AttemptFailureKind.ProviderTransportError)
        }
        let error = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () }).error().getOrThrow()
        @Expect(error.field("usage_reasoning_tokens").getOrThrow() == "1")
        @Expect(error.field("usage_cache_read_tokens").getOrThrow() == "4")
        @Expect(error.field("usage_source").getOrThrow() == "provider_stream_final")
        @Expect(!error.retryable && !error.fallbackAllowed)
    }
    @TestCase
    func invalidAndOverflowingUsageAreTypedProtocolFailures(): Unit {
        for (mode in ["subset", "overflow", "missing_evidence", "invented_source"]) {
            let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
            endpoint.action = { dispatch, frames =>
                let usage = modelProviderUsageValue(ModelUsage(inputTokens: 10, outputTokens: 1))
                if (mode == "subset") { usage.put("cache_read", integerValue(11)) }
                if (mode == "overflow") { usage.put("cache_read", integerValue(Int64.Max)); usage.put("cache_write", integerValue(Int64.Max)) }
                if (mode == "missing_evidence") { usage.put("source", textValue("provider_final")) }
                if (mode == "invented_source") { usage.put("source", textValue("provider_said_so")) }
                frames(modelProviderFrame(dispatch.identity(), 1, "usage", usage))
            }
            @Expect(PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () }).isError())
        }
    }
    @TestCase
    func endpointEofCannotBecomeAProviderTerminal(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        endpoint.action = { _, _ => Result.Ok(()) }
        @Expect(PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () })
            .error().getOrThrow().code == "model.provider_terminal_missing")
    }
    @TestCase
    func callbackAfterEndpointReturnsIsRejected(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        let observations = ProviderTestObservations()
        endpoint.action = { dispatch, frames =>
            observations.callback = Some(frames); observations.identity = dispatch.identity()
            frames(modelProviderFrame(observations.identity, 1, "reply", modelProviderReplyValue(providerTestReply())))
        }
        @Expect(PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () }).isOk())
        @Expect(observations.callback.getOrThrow()(modelProviderFrame(observations.identity, 2, "reply", modelProviderReplyValue(providerTestReply()))).isError())
    }
}
