package operation_domain_vnext_contract

import agent_domain.*
import yjson.*
import yjson_support.*

func operationObservationContract(): Unit {
    let source = objectValue([ValueField("stdout", textValue("partial 中文 output")),
        ValueField("claimed_outcome", textValue("completed")), ValueField("retry_safe", boolValue(true))])
    let observation = OperationObservation(stringifyUnifiedJson(source))
    source.put("stdout", textValue("mutated by caller"))
    let first = observation.toValue()
    first.field("content").getOrThrow().put("stdout", textValue("mutated projection"))
    expect(observation.toValue().field("content").getOrThrow().field("stdout").getOrThrow().text == "partial 中文 output",
        "operation observation is immutable across source and projection mutation")
    expect(observation.toValue().field("trust").getOrThrow().text == "untrusted_data" &&
        !observation.toValue().field("authorizes_effects").getOrThrow().asBool(),
        "observed plugin output never claims host authority")
    for (effect in [OperationEffectClass.ReadOnly, OperationEffectClass.ExternalMutation]) {
        let capabilities: Array<Capability> = if (effect == OperationEffectClass.ExternalMutation) {
            [Capability(CapabilityKind.NetworkAccess)]
        } else { [] }
        let plan = NormalizedOperationPlan("observe", objectValue([]), capabilities, effect,
            OperationRetryDisposition.Never, "observation-plan", replayDisposition: Some(ReplayDisposition.NeverReplay))
        let failure = AgentError(AgentErrorKind.RecoveryRequired, "fixture.unknown", "effect requires reconciliation",
            observation: Some(observation))
        let resolved = terminal(resolveOperationAttempt(OperationId("observation-op"), CanonicalToolCallId("observation-call"),
            plan, OperationAttemptStage.Executing, Result<ToolInvocationResult>.Err(failure), "observation-receipt", 12))
        let expected = canonicalAgentValue(observation.toValue())
        expect(resolved.receipt.outcome == OperationOutcome.Unknown && resolved.retryDecision == OperationRetryDecision.Stop &&
            resolved.error.getOrThrow().kind == AgentErrorKind.RecoveryRequired && !resolved.error.getOrThrow().retryable &&
            !resolved.error.getOrThrow().fallbackAllowed,
            "untrusted claimed success/retry does not change actual Unknown settlement")
        expect(canonicalAgentValue(resolved.receipt.detail.field("observation").getOrThrow()) == expected &&
            canonicalAgentValue(resolved.toolResult.getOrThrow().output.field("error").getOrThrow().field("observation").getOrThrow()) == expected &&
            canonicalAgentValue(resolved.error.getOrThrow().observation.getOrThrow().toValue()) == expected,
            "same bounded observation survives Receipt, ToolResult and stopping error")
    }
    let exact = "\"" + String.fromUtf8(Array<Byte>(65534, repeat: b'x')) + "\""
    let _ = OperationObservation(exact)
    for (invalid in [exact + " ", "{invalid", String.fromUtf8(Array<Byte>(40, repeat: b'[')) + "0" +
        String.fromUtf8(Array<Byte>(40, repeat: b']'))]) {
        var rejected = false
        try { let _ = OperationObservation(invalid) } catch (_: Exception) { rejected = true }
        expect(rejected, "observation rejects excess bytes, malformed JSON and excessive depth")
    }
    println("Operation observation contract passed: immutable bounded data, unchanged Unknown and retry semantics")
}
