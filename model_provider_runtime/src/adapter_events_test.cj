package model_provider_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*
import std.sync.*

@Test
class ModelProviderAdapterEventsTests {
    @TestCase
    func terminalOnlyArgumentsRemainDistinctFromObservedMalformedOrDriftingArguments(): Unit {
        for (mode in ["absent", "matching", "chunked", "empty", "malformed", "drift", "missing-end"]) {
            let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
            let expectedArguments = objectValue([ValueField("number", integerValue(1))])
            endpoint.action = { dispatch, frames =>
                let sequence = AtomicInt64(0)
                let emit = { kind: String, payload: AgentValue =>
                    frames(modelProviderFrame(dispatch.identity(), sequence.fetchAdd(1) + 1, kind, payload))
                }
                let _ = emit("event", objectValue([ValueField("kind", textValue("started")),
                    ValueField("protocol", textValue("fixture"))]))
                let _ = emit("event", objectValue([ValueField("kind", textValue("tool_start")),
                    ValueField("id", textValue("call-1")), ValueField("name", textValue("probe"))]))
                if (mode != "absent" && mode != "missing-end") {
                    let deltas = if (mode == "chunked") { ["{\"number\":", "1}"] }
                        else if (mode == "matching") { ["{\"number\":1}"] }
                        else if (mode == "drift") { ["{\"number\":2}"] }
                        else if (mode == "malformed") { ["{"] } else { [""] }
                    for (delta in deltas) {
                        let _ = emit("event", objectValue([ValueField("kind", textValue("tool_arguments")),
                            ValueField("id", textValue("call-1")), ValueField("text", textValue(delta))]))
                    }
                }
                if (mode != "missing-end") {
                    let _ = emit("event", objectValue([ValueField("kind", textValue("tool_end")),
                        ValueField("id", textValue("call-1"))]))
                }
                let observed = TerminalEvidence("fixture", "terminal", rawStopReason: "tool_calls",
                    messageTerminalObserved: true, streamEofObserved: false, adapterVersion: "fixture-1")
                let _ = emit("event", objectValue([ValueField("kind", textValue("terminal")),
                    ValueField("evidence", modelProviderTerminalValue(observed))]))
                let _ = emit("event", objectValue([ValueField("kind", textValue("transport_closed"))]))
                let reply = ModelReply([ModelBlock(ModelBlockKind.ToolCall, callId: "call-1", name: "probe",
                    arguments: expectedArguments)], stopReason: "tool_calls", usage: Some(ModelUsage()), providerId: "fixture",
                    terminalEvidence: Some(TerminalEvidence("fixture", "terminal", rawStopReason: "tool_calls",
                        messageTerminalObserved: true, streamEofObserved: true, adapterVersion: "fixture-1")),
                    completionDisposition: CompletionDisposition.ToolUse, decisionOutcome: DecisionOutcome.ToolCalls, validationVersion: 1)
                emit("reply", modelProviderReplyValue(reply))
            }
            let request = providerTestRequest(tools: [ModelToolDefinition("probe", "Probe", objectValue([]))])
            let result = PluginModelPort(providerTestBinding(tools: true), gate, endpoint).execute(request, { _ => () })
            @Expect(result.isOk(), ["absent", "matching", "chunked"].contains(mode))
            match(result){case Result.Ok(reply)=>@Expect(canonicalAgentValue(reply.blocks[0].arguments),canonicalAgentValue(expectedArguments));case Result.Err(_)=>()}
        }
    }

    @TestCase
    func terminalEofCanAdvanceOnlyAfterTransportClosed(): Unit {
        for (withClose in [false, true]) {
            let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
            endpoint.action = { dispatch, frames =>
                let _ = frames(modelProviderFrame(dispatch.identity(), 1, "event", objectValue([
                    ValueField("kind", textValue("started")), ValueField("protocol", textValue("fixture"))])))
                let terminal = TerminalEvidence("fixture", "terminal", rawStopReason: "stop",
                    messageTerminalObserved: true, streamEofObserved: false, adapterVersion: "fixture-1")
                let _ = frames(modelProviderFrame(dispatch.identity(), 2, "event", objectValue([
                    ValueField("kind", textValue("terminal")), ValueField("evidence", modelProviderTerminalValue(terminal))])))
                if (withClose) { let _ = frames(modelProviderFrame(dispatch.identity(), 3, "event",
                    objectValue([ValueField("kind", textValue("transport_closed"))]))) }
                frames(modelProviderFrame(dispatch.identity(), if (withClose) { 4 } else { 3 }, "reply", modelProviderReplyValue(providerTestReply())))
            }
            let result = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () })
            @Expect(result.isOk(), withClose)
        }
    }
    @TestCase
    func refusalBlockAndUsageProgressPreserveExistingEventsWithoutInventingEvidence(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        endpoint.action = { dispatch, frames =>
            let values = [ModelEvent.ProviderProgress(ProviderStreamEvent.StreamStarted("fixture")),
                ModelEvent.ProviderProgress(ProviderStreamEvent.ContentBlockStarted(0, "refusal")),
                ModelEvent.ProviderProgress(ProviderStreamEvent.ContentBlockCompleted(0, "refusal")),
                ModelEvent.ProviderProgress(ProviderStreamEvent.UsageDelta(11, 3)),
                ModelEvent.ProviderProgress(ProviderStreamEvent.UsageCompleted(11, 3))]
            var sequence: Int64 = 0
            for (event in values) { sequence += 1
                let _ = frames(modelProviderFrame(dispatch.identity(), sequence, "event", modelProviderEventValue(event).getOrThrow())) }
            Result.Ok(())
        }
        let observations = ProviderTestObservations()
        let result = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { event =>
            match (event) { case ModelEvent.ProviderProgress(_) => observations.progress += 1; case _ => () } })
        @Expect(observations.progress, 5)
        @Expect(result.error().getOrThrow().code, "model.provider_terminal_missing")
        @Expect(result.error().getOrThrow().field("usage_source").isNone())
    }
    @TestCase
    func providerFailureKeepsPartialUsageAndTypedMalformedArguments(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        endpoint.action = { dispatch, frames => frames(modelProviderFrame(dispatch.identity(), 1, "failure",
            modelProviderFailureValue(AgentError(AgentErrorKind.Protocol, "llm.tool_arguments_not_executable", "private diagnostic",
                fields: [ErrorField("usage_input_tokens", "11"), ErrorField("usage_output_tokens", "3")],
                attemptFailure: Some(AttemptFailure(AttemptFailureKind.MalformedToolArguments)))))) }
        let error = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () }).error().getOrThrow()
        @Expect(error.attemptFailure.getOrThrow().kind == AttemptFailureKind.MalformedToolArguments)
        @Expect(error.field("usage_input_tokens").getOrThrow(), "11")
        @Expect(error.retryable && error.fallbackAllowed)
        @Expect(!error.describe().contains("private diagnostic"))
    }
    @TestCase
    func pluginCannotClaimHostCancellationOrUnboundedRetryDelay(): Unit {
        for (mode in ["cancel", "delay", "usage"]) {
            let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
            endpoint.action = { dispatch, frames =>
                let failure = modelProviderFailureValue(AgentError(AgentErrorKind.Provider, "model.provider_error", "private"))
                if (mode == "cancel") { failure.put("attempt_failure", textValue("user_cancelled")) }
                else if (mode == "delay") { failure.put("retry_after_ms", integerValue(Int64.Max)) }
                else { failure.put("usage_fields", objectValue([ValueField("usage_input_tokens", textValue("1")),
                    ValueField("usage_cache_read_tokens", textValue("2"))])) }
                frames(modelProviderFrame(dispatch.identity(), 1, "failure", failure))
            }
            let error = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () }).error().getOrThrow()
            @Expect(error.code, "model.provider_frame_invalid")
            @Expect(error.attemptFailure.getOrThrow().kind != AttemptFailureKind.UserCancelled)
        }
    }
    @TestCase
    func toggleCapabilitiesRoundTripAndRejectStructuredProjectionDrift(): Unit {
        let snapshot = ModelExecutionCapabilitiesSnapshot("fixture-model", ThinkingCapabilities(ThinkingControlMode.Toggle), 4096)
        let binding = ModelProviderBinding("fixture", "sha256:" + modelPolicySha256Text("pkg"), modelPolicySha256Text("config"),
            "instance", "model", "fixture-model", "wire", snapshot)
        @Expect(modelProviderBindingCapabilities(binding.snapshot()).thinking.mode == ThinkingControlMode.Toggle)
        let changed = binding.snapshot(); changed.field("execution_capabilities").getOrThrow().put("levels", listValue([]))
        var rejected = false
        try { let _ = modelProviderBindingCapabilities(changed) } catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }
}
