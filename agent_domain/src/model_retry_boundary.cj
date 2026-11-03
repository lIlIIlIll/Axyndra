package agent_domain

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*

// These encodings are shared by the pre-I/O writer and the recovery verifier.
// Keep their persisted field shapes independent of the canonical policy text.
public func attemptPolicyValue(policy: AttemptPolicy): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("model", textValue(policy.model)))
    fields.add(ValueField("thinking", textValue(thinkingLevelCanonicalName(policy.thinking))))
    fields.add(ValueField("tool_choice", textValue(retryBoundaryToolChoiceName(policy.toolChoice))))
    fields.add(ValueField("max_output_tokens", integerValue(policy.maxOutputTokens)))
    fields.add(ValueField("reason", textValue(retryBoundaryPolicyReasonName(policy.reason))))
    fields.add(ValueField("soft_deadline_ms", integerValue(policy.softDeadlineMillis)))
    fields.add(ValueField("hard_deadline_ms", integerValue(policy.hardDeadlineMillis)))
    fields.add(ValueField("stream_idle_ms", integerValue(policy.streamIdleMillis)))
    match (policy.resolvedPolicy) {
        case Some(value) =>
            fields.add(ValueField("policy_resolution_version", integerValue(Int64(value.policyResolutionVersion))))
            fields.add(ValueField("capability_snapshot_version", integerValue(Int64(value.capabilitySnapshotVersion))))
            fields.add(ValueField("capability_fingerprint", textValue(value.capabilityFingerprint)))
            fields.add(ValueField("capability_snapshot_payload", textValue(value.capabilitySnapshotPayload)))
            fields.add(ValueField("min_visible_response_tokens", integerValue(value.minVisibleResponseTokens)))
            fields.add(ValueField("thinking_source", textValue(thinkingPreferenceSourceCanonicalName(value.thinkingSource))))
            match (value.userRequestedThinking) {
                case Some(level) => fields.add(ValueField("user_requested_thinking", textValue(thinkingLevelCanonicalName(level))))
                case None => ()
            }
            fields.add(ValueField("thinking_requested", textValue(thinkingLevelCanonicalName(value.thinking.requested))))
            fields.add(ValueField("thinking_effective", textValue(thinkingLevelCanonicalName(value.thinking.effective))))
            fields.add(ValueField("thinking_mode", textValue(thinkingControlModeCanonicalName(value.thinking.mode))))
            match (value.thinking.budgetTokens) {
                case Some(tokens) => fields.add(ValueField("thinking_budget_tokens", integerValue(tokens)))
                case None => ()
            }
            fields.add(ValueField("thinking_constraints", retryBoundaryConstraintsValue(value.thinking.constraints)))
            fields.add(ValueField("output_requested_hard_limit", integerValue(value.output.requestedHardLimit)))
            fields.add(ValueField("output_effective_wire_limit", integerValue(value.output.effectiveWireLimit)))
            fields.add(ValueField("output_constraints", retryBoundaryConstraintsValue(value.output.constraints)))
        case None => ()
    }
    objectValue(fields.toArray())
}

public func resolvedModelPolicyCheckpointValue(value: ResolvedModelRequestPolicy): AgentValue {
    objectValue([
        ValueField("canonical", textValue(canonicalResolvedModelRequestPolicy(value))),
        ValueField("thinking_requested", textValue(thinkingLevelCanonicalName(value.thinking.requested))),
        ValueField("thinking_effective", textValue(thinkingLevelCanonicalName(value.thinking.effective))),
        ValueField("thinking_mode", textValue(thinkingControlModeCanonicalName(value.thinking.mode))),
        ValueField("thinking_budget_tokens", match (value.thinking.budgetTokens) {
            case Some(tokens) => integerValue(tokens)
            case None => nullValue()
        }),
        ValueField("adaptive_effort", match (value.thinking.adaptiveEffort) {
            case Some(level) => textValue(thinkingLevelCanonicalName(level))
            case None => nullValue()
        }),
        ValueField("output_requested", integerValue(value.output.requestedHardLimit)),
        ValueField("output_effective", integerValue(value.output.effectiveWireLimit)),
        ValueField("policy_resolution_version", integerValue(Int64(value.policyResolutionVersion))),
        ValueField("capability_snapshot_version", integerValue(Int64(value.capabilitySnapshotVersion))),
        ValueField("capability_fingerprint", textValue(value.capabilityFingerprint)),
        ValueField("capability_snapshot_payload", textValue(value.capabilitySnapshotPayload)),
        ValueField("response_reserve", integerValue(value.minVisibleResponseTokens)),
        ValueField("thinking_source", textValue(thinkingPreferenceSourceCanonicalName(value.thinkingSource))),
        ValueField("user_requested_thinking", match (value.userRequestedThinking) {
            case Some(level) => textValue(thinkingLevelCanonicalName(level))
            case None => nullValue()
        }),
        ValueField("thinking_constraints", retryBoundaryConstraintsValue(value.thinking.constraints)),
        ValueField("output_constraints", retryBoundaryConstraintsValue(value.output.constraints))
    ])
}

public func modelAttemptWirePolicyDigest(
    model: String,
    wireMaxOutputTokens: Int64,
    toolChoice: ModelToolChoice,
    transportHardTimeoutMillis: Int64,
    policyCanonical: String
): String {
    modelPolicySha256Text(
        "wire-policy-v1\n" + model + "\n" + wireMaxOutputTokens.toString() + "\n" +
            retryBoundaryToolChoiceName(toolChoice) + "\n" +
            "transport_hard_timeout_millis=" + transportHardTimeoutMillis.toString() + "\n" +
            policyCanonical
    )
}

// The caller attests the complete continuation request binding. Lifecycle,
// absence of a parent Decision, and atomic installation belong to the store.
// This proof uses only frozen inputs and never grants permission from a label.
public func exactOutputLimitRecoveryBoundary(
    previous: RunContinuation,
    next: RunContinuation,
    child: DurableModelAttempt,
    parent: DurableModelAttempt
): Result<Bool> {
    if (previous.kind != RunContinuationKind.RunningModel ||
        next.kind != RunContinuationKind.RunningModel) { return Result.Ok(false) }
    try {
        let stored = previous.runningModel.getOrThrow()
        let proposed = next.runningModel.getOrThrow()
        if (previous.runId.value != next.runId.value ||
            previous.sessionId.value != next.sessionId.value ||
            parent.runId.value != previous.runId.value || child.runId.value != next.runId.value ||
            stored.semanticRequestId.value != parent.semanticRequestId.value ||
            proposed.semanticRequestId.value != child.semanticRequestId.value ||
            parent.semanticRequestId.value != child.semanticRequestId.value ||
            stored.activeAttemptId.value != parent.id.value || proposed.activeAttemptId.value != child.id.value ||
            parent.attemptNo != 1 || child.attemptNo != 2 || parent.parentAttemptId.isSome() ||
            child.parentAttemptId.isNone() || child.parentAttemptId.getOrThrow().value != parent.id.value ||
            stored.originalAttemptId.value != parent.id.value || proposed.originalAttemptId.value != parent.id.value ||
            stored.stableTurnId != proposed.stableTurnId ||
            child.id.value == parent.id.value || child.lifecycle != ModelAttemptLifecycle.Created ||
            child.dispatchState != ModelAttemptDispatchState.Prepared ||
            child.replayBarrier != ModelAttemptReplayBarrier.NoBarrier ||
            parent.dispatchState != ModelAttemptDispatchState.DispatchClaimed ||
            (parent.replayBarrier != ModelAttemptReplayBarrier.NoBarrier &&
                parent.replayBarrier != ModelAttemptReplayBarrier.ToolEvidence &&
                parent.replayBarrier != ModelAttemptReplayBarrier.ProviderTerminal)) {
            return Result.Ok(false)
        }
        if (stored.stableRequestId != parent.providerRequestId ||
            proposed.stableRequestId != child.providerRequestId ||
            child.providerRequestId != parent.providerRequestId + "-retry-1") {
            return Result.Ok(false)
        }
        let parentCanonical = canonicalAgentValue(stored.canonicalRequest)
        let childCanonical = canonicalAgentValue(proposed.canonicalRequest)
        let parentDigest = modelPolicySha256Text(parentCanonical)
        let childDigest = modelPolicySha256Text(childCanonical)
        if (parentDigest != stored.semanticRequestDigest || parentDigest != parent.semanticRequestDigest ||
            childDigest != proposed.semanticRequestDigest || childDigest != child.semanticRequestDigest) {
            throw IllegalArgumentException("recovery request digest does not match its frozen payload")
        }
        let requested = previous.requestedPolicy.getOrThrow()
        let capabilities = previous.modelCapabilitiesSnapshot.getOrThrow()
        if (previous.resolverVersion != MODEL_POLICY_RESOLUTION_VERSION ||
            capabilities.snapshotSchemaVersion != MODEL_CAPABILITY_SNAPSHOT_VERSION ||
            capabilities.capabilityFingerprint != modelCapabilitySnapshotFingerprint(
                capabilities.snapshotSchemaVersion, capabilities.modelId, capabilities.thinking,
                capabilities.modelMaxOutputTokens, capabilities.endpointMaxOutputTokens
            )) {
            throw IllegalArgumentException("recovery policy version or capability fingerprint is invalid")
        }
        let streamIdle = retryBoundaryInteger(parent.policy, "stream_idle_ms")
        if (streamIdle < 1) { throw IllegalArgumentException("recovery stream idle interval is invalid") }
        let expectedParent = match (resolveModelAttemptPolicy(AttemptPolicyInput(
            requested, capabilities, resolverVersion: previous.resolverVersion
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalArgumentException(error.message)
        }
        let parentResolved = resolvedModelPolicyCheckpointValue(expectedParent)
        let model = retryBoundaryText(stored.canonicalRequest, "model")
        let wireLimit = retryBoundaryInteger(stored.canonicalRequest, "wire_max_output_tokens")
        let toolChoice = retryBoundaryToolChoice(retryBoundaryText(stored.canonicalRequest, "tool_choice"))
        if (model != previous.model || model != capabilities.modelId ||
            wireLimit != expectedParent.output.effectiveWireLimit ||
            retryBoundaryText(stored.canonicalRequest, "thinking") !=
                thinkingLevelCanonicalName(expectedParent.thinking.effective) ||
            parent.policyReason != "initial" || retryBoundaryText(parent.policy, "reason") != "initial") {
            return Result.Ok(false)
        }
        retryBoundaryRequireResolved(stored.canonicalRequest, parentResolved)
        let parentPolicy = attemptPolicyValue(AttemptPolicy(
            model, expectedParent.thinking.effective, toolChoice, wireLimit,
            streamIdleMillis: streamIdle, resolvedPolicy: Some(expectedParent)
        ))
        retryBoundaryRequireShape(parent.policy, parentPolicy)
        if (!retryBoundaryValuesEqual(parent.policy, parentPolicy)) { return Result.Ok(false) }
        let ceiling = match (nextLowerThinkingCeiling(capabilities, expectedParent.thinking.effective)) {
            case Some(value) => value
            case None => return Result.Ok(false)
        }
        let expectedChild = match (resolveModelAttemptPolicy(AttemptPolicyInput(
            requested, capabilities, recoveryCeiling: Some(ceiling), resolverVersion: previous.resolverVersion
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalArgumentException(error.message)
        }
        if (thinkingLevelRank(expectedChild.thinking.effective) >= thinkingLevelRank(expectedParent.thinking.effective) ||
            child.policyReason != "output_limit_recovery" ||
            retryBoundaryText(child.policy, "reason") != "output_limit_recovery") { return Result.Ok(false) }
        let childPolicy = attemptPolicyValue(AttemptPolicy(
            model, expectedChild.thinking.effective, toolChoice, expectedChild.output.effectiveWireLimit,
            reason: AttemptPolicyReason.OutputLimitRecovery,
            streamIdleMillis: streamIdle, resolvedPolicy: Some(expectedChild)
        ))
        retryBoundaryRequireShape(child.policy, childPolicy)
        if (!retryBoundaryValuesEqual(child.policy, childPolicy)) { return Result.Ok(false) }
        let childResolved = resolvedModelPolicyCheckpointValue(expectedChild)
        retryBoundaryRequireResolved(proposed.canonicalRequest, childResolved)
        if (retryBoundaryText(proposed.canonicalRequest, "thinking") !=
            thinkingLevelCanonicalName(expectedChild.thinking.effective)) { return Result.Ok(false) }
        // Reuse the parent's field references; never decode or copy messages/tools.
        let expectedFields = ArrayList<ValueField>()
        for (field in stored.canonicalRequest.fields) {
            expectedFields.add(match (field.name) {
                case "thinking" => ValueField("thinking", textValue(thinkingLevelCanonicalName(expectedChild.thinking.effective)))
                case "resolved_policy" => ValueField("resolved_policy", childResolved)
                case _ => field
            })
        }
        let expectedCanonical = canonicalAgentValue(objectValue(expectedFields.toArray()))
        // Equality also proves the expected digest equals the already verified
        // childDigest; do not hash the complete messages/tools payload twice.
        if (expectedCanonical != childCanonical) {
            return Result.Ok(false)
        }
        let parentWire = modelAttemptWirePolicyDigest(model, wireLimit, toolChoice, 0,
            retryBoundaryText(parentResolved, "canonical"))
        let childWire = modelAttemptWirePolicyDigest(model, expectedChild.output.effectiveWireLimit, toolChoice, 0,
            retryBoundaryText(childResolved, "canonical"))
        if (parentWire != stored.wirePolicyDigest || parentWire != parent.wirePolicyDigest ||
            childWire != proposed.wirePolicyDigest || childWire != child.wirePolicyDigest) {
            throw IllegalArgumentException("recovery wire policy digest does not match its frozen resolution")
        }
        Result.Ok(true)
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired, "model.recovery_boundary_corrupt",
            "frozen output-limit recovery boundary is corrupt",
            fields: [ErrorField("detail", error.message)]
        ))
    }
}

func retryBoundaryRequireResolved(request: AgentValue, expected: AgentValue): Unit {
    let stored = retryBoundaryField(request, "resolved_policy")
    retryBoundaryRequireShape(stored, expected)
    if (!retryBoundaryValuesEqual(stored, expected)) {
        throw IllegalArgumentException("resolved policy does not match the complete frozen resolution")
    }
}

func retryBoundaryField(value: AgentValue, name: String): AgentValue {
    if (value.unifiedKind != ValueKind.Object) {
        throw IllegalArgumentException("recovery snapshot must be an object")
    }
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalArgumentException("recovery field is missing: " + name)
    }
}

func retryBoundaryText(value: AgentValue, name: String): String {
    let item = retryBoundaryField(value, name)
    if (item.unifiedKind != ValueKind.Text) {
        throw IllegalArgumentException("recovery field must be text: " + name)
    }
    item.text
}

func retryBoundaryInteger(value: AgentValue, name: String): Int64 {
    let item = retryBoundaryField(value, name)
    if (item.unifiedKind != ValueKind.Number) {
        throw IllegalArgumentException("recovery field must be an integer: " + name)
    }
    Int64.parse(item.asNumberText())
}

func retryBoundaryRequireShape(value: AgentValue, expected: AgentValue): Unit {
    if (value.unifiedKind != expected.unifiedKind) {
        throw IllegalArgumentException("recovery policy field has an invalid type")
    }
    match (expected.unifiedKind) {
        case ValueKind.Object => for (field in expected.fields) {
            retryBoundaryRequireShape(retryBoundaryField(value, field.name), field.value)
        }
        case ValueKind.List =>
            let expectedItems = expected.items
            // Full equality is still required for empty constraint lists.
            if (!expectedItems.isEmpty()) {
                for (item in value.items) { retryBoundaryRequireShape(item, expectedItems[0]) }
            }
        case ValueKind.Number => let _ = Int64.parse(value.asNumberText())
        case _ => ()
    }
}

func retryBoundaryValuesEqual(left: AgentValue, right: AgentValue): Bool {
    if (left.unifiedKind != right.unifiedKind) { return false }
    match (left.unifiedKind) {
        case ValueKind.Null => true
        case ValueKind.Boolean => left.asBool() == right.asBool()
        case ValueKind.Number => left.asNumberText() == right.asNumberText()
        case ValueKind.Text => left.text == right.text
        case ValueKind.List =>
            let leftItems = left.items
            let rightItems = right.items
            if (leftItems.size != rightItems.size) { return false }
            for (index in 0..leftItems.size) {
                if (!retryBoundaryValuesEqual(leftItems[index], rightItems[index])) { return false }
            }
            true
        case ValueKind.Object =>
            let fields = left.fields
            if (fields.size != right.fields.size) { return false }
            for (field in fields) {
                match (right.field(field.name)) {
                    case Some(value) => if (!retryBoundaryValuesEqual(field.value, value)) { return false }
                    case None => return false
                }
            }
            true
    }
}

func retryBoundaryToolChoice(value: String): ModelToolChoice {
    match (value) {
        case "auto" => ModelToolChoice.Auto
        case "none" => ModelToolChoice.NoTools
        case "required" => ModelToolChoice.Required
        case _ => throw IllegalArgumentException("recovery tool choice is invalid")
    }
}

func retryBoundaryToolChoiceName(value: ModelToolChoice): String {
    match (value) {
        case ModelToolChoice.Auto => "auto"
        case ModelToolChoice.NoTools => "none"
        case ModelToolChoice.Required => "required"
    }
}

func retryBoundaryPolicyReasonName(value: AttemptPolicyReason): String {
    match (value) {
        case AttemptPolicyReason.Initial => "initial"
        case AttemptPolicyReason.Retry => "retry"
        case AttemptPolicyReason.DeadlineEscalation => "deadline_escalation"
        case AttemptPolicyReason.OutputLimitRecovery => "output_limit_recovery"
    }
}

func retryBoundaryConstraintsValue(values: Array<ResolutionConstraint>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) {
        result.add(objectValue([
            ValueField("target", textValue(match (value.target) {
                case ResolutionConstraintTarget.OutputLimit => "output_limit"
                case ResolutionConstraintTarget.ThinkingLevel => "thinking_level"
            })),
            ValueField("kind", textValue(match (value.kind) {
                case ResolutionConstraintKind.ModelOutputLimit => "model_output_limit"
                case ResolutionConstraintKind.EndpointOutputLimit => "endpoint_output_limit"
                case ResolutionConstraintKind.ModelSupportedLevel => "model_supported_level"
                case ResolutionConstraintKind.AttemptRecoveryCeiling => "attempt_recovery_ceiling"
                case ResolutionConstraintKind.AvailableThinkingBudget => "available_thinking_budget"
            })),
            ValueField("before", retryBoundaryResolutionValue(value.before)),
            ValueField("after", retryBoundaryResolutionValue(value.after))
        ]))
    }
    listValue(result.toArray())
}

func retryBoundaryResolutionValue(value: ResolutionValue): AgentValue {
    match (value) {
        case ResolutionValue.TokenLimit(tokens) => integerValue(tokens)
        case ResolutionValue.ThinkingValue(level) => textValue(thinkingLevelCanonicalName(level))
    }
}
