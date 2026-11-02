package sqlite_run_repository_contract

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.sync.*
import std.time.*

func outputLimitRetryBoundaryContract(database: SqliteDatabase): Unit {
    legalOutputLimitRetryContract(database)
    outputLimitRetryRequestMutationContract(database)
    outputLimitRetryFrozenInputContract(database)
    outputLimitRetryCorruptSnapshotContract(database)
    outputLimitRetryDigestAlignmentContract(database)
    outputLimitRetryIdentityAndLifecycleContract(database)
    outputLimitRetryResolvedPolicyMutationContract(database)
    outputLimitRetryDecisionAndCompetitionContract(database)
}

func outputLimitRetryResolvedPolicyMutationContract(database: SqliteDatabase): Unit {
    let skipped = OutputLimitRecoveryFixture(database, "recovery-skip-down")
    let skippedChild = OutputLimitRecoveryChild(skipped)
    let offResolution = recoveryResolvePolicy(
        skipped.frozenRequestedPolicy, skipped.frozenCapabilities, Some(ThinkingLevel.Off)
    )
    expect(offResolution.thinking.effective == ThinkingLevel.Off,
        "skip-down mutation resolves to Off from the frozen medium request")
    recoveryConfigureChildResolution(skipped, skippedChild, offResolution)
    rejectOutputLimitRetry(skipped, skippedChild,
        "a resolved medium-to-off skip is rejected when the next frozen level is low")

    let upgraded = OutputLimitRecoveryFixture(database, "recovery-upgrade")
    let upgradedChild = OutputLimitRecoveryChild(upgraded)
    let highRequested = RequestedModelPolicy(
        ThinkingLevel.High, RequestOutputBudget(16384, minVisibleResponseTokens: 1024)
    )
    let highResolution = recoveryResolvePolicy(
        highRequested, upgraded.frozenCapabilities, Some(ThinkingLevel.High)
    )
    expect(highResolution.thinking.effective == ThinkingLevel.High,
        "upgrade mutation resolves consistently to High under its forged request policy")
    recoveryConfigureChildResolution(upgraded, upgradedChild, highResolution)
    rejectOutputLimitRetry(upgraded, upgradedChild,
        "a fully resolved and re-digested high child cannot upgrade the frozen medium request")

    let changedConstraint = OutputLimitRecoveryFixture(
        database, "recovery-resolved-constraint-array"
    )
    let changedConstraintChild = OutputLimitRecoveryChild(changedConstraint)
    let resolvedBefore = changedConstraintChild.canonicalRequest
        .field("resolved_policy").getOrThrow()
    let canonicalBefore = resolvedBefore.field("canonical").getOrThrow().text
    expect(resolvedBefore.field("thinking_constraints").getOrThrow().items.size > 0,
        "low recovery fixture includes a frozen thinking constraint")
    let alteredResolved = replaceRecoveryField(
        resolvedBefore, "thinking_constraints", listValue([])
    )
    expect(alteredResolved.field("canonical").getOrThrow().text == canonicalBefore,
        "constraint-array mutation keeps resolved-policy canonical text unchanged")
    changedConstraintChild.canonicalRequest = replaceRecoveryField(
        changedConstraintChild.canonicalRequest, "resolved_policy", alteredResolved
    )
    changedConstraintChild.semanticRequestDigest = modelPolicySha256Text(
        canonicalAgentValue(changedConstraintChild.canonicalRequest)
    )
    rejectOutputLimitRetry(
        changedConstraint, changedConstraintChild,
        changedConstraintChild.continuation(changedConstraint),
        "model.recovery_boundary_corrupt",
        "resolved-policy constraint arrays are compared independently from canonical text"
    )
}

func recoveryConfigureChildResolution(
    fixture: OutputLimitRecoveryFixture,
    child: OutputLimitRecoveryChild,
    resolution: ResolvedModelRequestPolicy
): Unit {
    child.canonicalRequest = recoveryRequestCanonical(resolution)
    child.semanticRequestDigest = modelPolicySha256Text(
        canonicalAgentValue(child.canonicalRequest)
    )
    child.policy = attemptPolicyValue(AttemptPolicy(
        fixture.model, resolution.thinking.effective, ModelToolChoice.Auto,
        resolution.output.effectiveWireLimit,
        reason: AttemptPolicyReason.OutputLimitRecovery,
        streamIdleMillis: 60000,
        resolvedPolicy: Some(resolution)
    ))
    child.wirePolicyDigest = modelAttemptWirePolicyDigest(
        fixture.model, resolution.output.effectiveWireLimit, ModelToolChoice.Auto, 0,
        canonicalResolvedModelRequestPolicy(resolution)
    )
}

func legalOutputLimitRetryContract(database: SqliteDatabase): Unit {
    let providerTerminal = OutputLimitRecoveryFixture(database, "recovery-legal")
    acceptOutputLimitRetry(providerTerminal, OutputLimitRecoveryChild(providerTerminal),
        "medium-to-low recovery with changed cumulative counters commits")
    expect(providerTerminal.parent.replayBarrier == ModelAttemptReplayBarrier.ProviderTerminal,
        "provider-terminal parent barrier is allowed for output-limit recovery")

    let noBarrier = OutputLimitRecoveryFixture(
        database, "recovery-no-barrier", parentBarrier: ModelAttemptReplayBarrier.NoBarrier
    )
    acceptOutputLimitRetry(noBarrier, OutputLimitRecoveryChild(noBarrier),
        "no-barrier parent is allowed for output-limit recovery")

    let toolEvidence = OutputLimitRecoveryFixture(
        database, "recovery-tool-evidence", parentBarrier: ModelAttemptReplayBarrier.ToolEvidence,
        failureKind: "output_limited_before_decision"
    )
    acceptOutputLimitRetry(toolEvidence, OutputLimitRecoveryChild(toolEvidence),
        "tool-evidence parent and output-limited-before-decision failure are allowed")

    let suffixedRequest = OutputLimitRecoveryFixture(
        database, "recovery-existing-request-suffix", parentRequestSuffix: "-retry-1"
    )
    acceptOutputLimitRetry(suffixedRequest, OutputLimitRecoveryChild(suffixedRequest),
        "recovery appends retry-1 without truncating a parent request ID suffix")
}

func outputLimitRetryRequestMutationContract(database: SqliteDatabase): Unit {
    rejectCanonicalRequestMutation(database, "model", textValue("other-model"))
    rejectCanonicalRequestMutation(database, "system", textValue("changed system prompt"))
    rejectCanonicalRequestMutation(database, "messages", listValue([]))
    rejectCanonicalRequestMutation(database, "tools", listValue([]))
    rejectCanonicalRequestMutation(database, "thinking", textValue("high"))
    rejectCanonicalRequestMutation(database, "wire_max_output_tokens", integerValue(8192))
    rejectCanonicalRequestMutation(database, "streaming", boolValue(false))
    rejectCanonicalRequestMutation(database, "parallel_tool_calls", boolValue(false))
    rejectCanonicalRequestMutation(database, "service_tier", textValue("changed-tier"))
    rejectCanonicalRequestMutation(database, "cache_policy", textValue("default"))
    rejectCanonicalRequestMutation(database, "cache_key", textValue("changed-cache-key"))
    rejectCanonicalRequestMutation(database, "tool_choice", textValue("required"))
    rejectCanonicalRequestMutation(database, "structured_output", objectValue([
        ValueField("name", textValue("changed-schema")),
        ValueField("description", textValue("")),
        ValueField("schema", objectValue([])),
        ValueField("strict", boolValue(false))
    ]))

    let requestBinding = OutputLimitRecoveryFixture(database, "recovery-request-binding")
    let requestBindingChild = OutputLimitRecoveryChild(requestBinding)
    let changedRequestBinding = recoveryContinuation(
        requestBinding,
        requestBindingChild.checkpoint(requestBinding),
        requestBinding.frozenRequestedPolicy,
        requestBinding.frozenCapabilities,
        requestBinding.resolverVersion,
        "other-model"
    )
    rejectOutputLimitRetry(
        requestBinding, requestBindingChild, changedRequestBinding,
        "continuation-level model binding drift is rejected atomically"
    )

    let requestedBinding = OutputLimitRecoveryFixture(database, "recovery-requested-binding")
    let requestedBindingChild = OutputLimitRecoveryChild(requestedBinding)
    let changedRequested = RequestedModelPolicy(
        ThinkingLevel.High, RequestOutputBudget(16384, minVisibleResponseTokens: 1024)
    )
    rejectOutputLimitRetry(
        requestedBinding, requestedBindingChild,
        recoveryContinuation(
            requestedBinding, requestedBindingChild.checkpoint(requestedBinding),
            changedRequested, requestedBinding.frozenCapabilities,
            requestedBinding.resolverVersion, "fixture"
        ),
        "continuation-level requested-policy drift is rejected atomically"
    )

    let capabilitiesBinding = OutputLimitRecoveryFixture(database, "recovery-capabilities-binding")
    let capabilitiesBindingChild = OutputLimitRecoveryChild(capabilitiesBinding)
    let changedCapabilities = ModelExecutionCapabilitiesSnapshot(
        "other-model", ThinkingCapabilities(
            ThinkingControlMode.Effort, supportedLevels: canonicalNonOffThinkingLevels()
        ), 16384
    )
    rejectOutputLimitRetry(
        capabilitiesBinding, capabilitiesBindingChild,
        recoveryContinuation(
            capabilitiesBinding, capabilitiesBindingChild.checkpoint(capabilitiesBinding),
            capabilitiesBinding.frozenRequestedPolicy, changedCapabilities,
            capabilitiesBinding.resolverVersion, "fixture"
        ),
        "continuation-level capability-snapshot drift is rejected atomically"
    )

    let resolverBinding = OutputLimitRecoveryFixture(database, "recovery-resolver-binding")
    let resolverBindingChild = OutputLimitRecoveryChild(resolverBinding)
    rejectOutputLimitRetry(
        resolverBinding, resolverBindingChild,
        recoveryContinuation(
            resolverBinding, resolverBindingChild.checkpoint(resolverBinding),
            resolverBinding.frozenRequestedPolicy, resolverBinding.frozenCapabilities,
            MODEL_POLICY_RESOLUTION_VERSION + 1u32, "fixture"
        ),
        "continuation-level resolver-version drift is rejected atomically"
    )

    let labelOnly = OutputLimitRecoveryFixture(database, "recovery-label-only")
    let labelOnlyChild = OutputLimitRecoveryChild(labelOnly)
    labelOnlyChild.policyReason = "retry"
    rejectOutputLimitRetry(labelOnly, labelOnlyChild,
        "retry label alone cannot authorize a changed request digest")

    let policyScalar = OutputLimitRecoveryFixture(database, "recovery-policy-scalar")
    let policyScalarChild = OutputLimitRecoveryChild(policyScalar)
    policyScalarChild.policy = replaceRecoveryField(
        policyScalarChild.policy, "max_output_tokens", integerValue(8192)
    )
    rejectOutputLimitRetry(policyScalar, policyScalarChild,
        "child attempt policy scalar drift is rejected atomically")

    let parentPolicyScalar = OutputLimitRecoveryFixture(
        database, "recovery-parent-policy-scalar", parentPolicyMutation: "max_output_tokens"
    )
    rejectOutputLimitRetry(parentPolicyScalar, OutputLimitRecoveryChild(parentPolicyScalar),
        "parent attempt policy scalar drift is rejected atomically")

    let parentPolicyReason = OutputLimitRecoveryFixture(
        database, "recovery-parent-policy-reason", parentPolicyReason: "retry"
    )
    rejectOutputLimitRetry(parentPolicyReason, OutputLimitRecoveryChild(parentPolicyReason),
        "parent policy label drift is rejected atomically")
}

func rejectCanonicalRequestMutation(
    database: SqliteDatabase,
    fieldName: String,
    replacement: AgentValue
): Unit {
    let fixture = OutputLimitRecoveryFixture(database, "recovery-request-" + fieldName)
    let child = OutputLimitRecoveryChild(fixture)
    child.canonicalRequest = replaceRecoveryField(child.canonicalRequest, fieldName, replacement)
    child.semanticRequestDigest = modelPolicySha256Text(canonicalAgentValue(child.canonicalRequest))
    rejectOutputLimitRetry(
        fixture, child,
        "independent canonical request mutation is rejected atomically: " + fieldName
    )
}

func outputLimitRetryFrozenInputContract(database: SqliteDatabase): Unit {
    let changedRequested = RequestedModelPolicy(
        ThinkingLevel.High, RequestOutputBudget(16384, minVisibleResponseTokens: 1024)
    )
    let requested = OutputLimitRecoveryFixture(
        database, "recovery-frozen-requested", frozenRequestedPolicy: Some(changedRequested)
    )
    rejectOutputLimitRetry(requested, OutputLimitRecoveryChild(requested),
        "stored frozen requested policy must resolve the parent attempt exactly")

    let changedModel = ModelExecutionCapabilitiesSnapshot(
        "other-model", ThinkingCapabilities(
            ThinkingControlMode.Effort, supportedLevels: canonicalNonOffThinkingLevels()
        ), 16384
    )
    let model = OutputLimitRecoveryFixture(
        database, "recovery-frozen-capability-model", frozenCapabilities: Some(changedModel)
    )
    rejectOutputLimitRetry(model, OutputLimitRecoveryChild(model),
        "stored frozen capability model identity is validated against the parent request")

    let changedThinking = ModelExecutionCapabilitiesSnapshot(
        "fixture", ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: [ThinkingLevel.Low, ThinkingLevel.Medium]
        ), 16384
    )
    let thinking = OutputLimitRecoveryFixture(
        database, "recovery-frozen-capability-thinking", frozenCapabilities: Some(changedThinking)
    )
    rejectOutputLimitRetry(thinking, OutputLimitRecoveryChild(thinking),
        "stored frozen supported thinking levels are validated against parent policy")

    let changedModelLimit = ModelExecutionCapabilitiesSnapshot(
        "fixture", ThinkingCapabilities(
            ThinkingControlMode.Effort, supportedLevels: canonicalNonOffThinkingLevels()
        ), 8192
    )
    let modelLimit = OutputLimitRecoveryFixture(
        database, "recovery-frozen-model-limit", frozenCapabilities: Some(changedModelLimit)
    )
    rejectOutputLimitRetry(modelLimit, OutputLimitRecoveryChild(modelLimit),
        "stored frozen model output ceiling is validated against parent policy")

    let changedEndpointLimit = ModelExecutionCapabilitiesSnapshot(
        "fixture", ThinkingCapabilities(
            ThinkingControlMode.Effort, supportedLevels: canonicalNonOffThinkingLevels()
        ), 16384, endpointMaxOutputTokens: Some(8192)
    )
    let endpointLimit = OutputLimitRecoveryFixture(
        database, "recovery-frozen-endpoint-limit", frozenCapabilities: Some(changedEndpointLimit)
    )
    rejectOutputLimitRetry(endpointLimit, OutputLimitRecoveryChild(endpointLimit),
        "stored frozen endpoint output ceiling is validated against parent policy")

    let resolver = OutputLimitRecoveryFixture(
        database, "recovery-frozen-resolver", resolverVersion: MODEL_POLICY_RESOLUTION_VERSION + 1u32
    )
    rejectOutputLimitRetry(resolver, OutputLimitRecoveryChild(resolver),
        "unsupported stored resolver version propagates a corrupt recovery boundary")
}

func outputLimitRetryCorruptSnapshotContract(database: SqliteDatabase): Unit {
    let missingChild = OutputLimitRecoveryFixture(database, "recovery-child-resolved-missing")
    let missingChildCandidate = OutputLimitRecoveryChild(missingChild)
    missingChildCandidate.canonicalRequest = removeRecoveryField(
        missingChildCandidate.canonicalRequest, "resolved_policy"
    )
    missingChildCandidate.semanticRequestDigest = modelPolicySha256Text(
        canonicalAgentValue(missingChildCandidate.canonicalRequest)
    )
    rejectOutputLimitRetry(
        missingChild, missingChildCandidate, missingChildCandidate.continuation(missingChild),
        "model.recovery_boundary_corrupt",
        "missing child resolved policy is propagated fail-closed"
    )

    let corruptChild = OutputLimitRecoveryFixture(database, "recovery-child-resolved-corrupt")
    let corruptChildCandidate = OutputLimitRecoveryChild(corruptChild)
    let corruptChildResolved = corruptChildCandidate.canonicalRequest
        .field("resolved_policy").getOrThrow()
    corruptChildCandidate.canonicalRequest = replaceRecoveryField(
        corruptChildCandidate.canonicalRequest,
        "resolved_policy",
        replaceRecoveryField(corruptChildResolved, "canonical", textValue("tampered policy"))
    )
    corruptChildCandidate.semanticRequestDigest = modelPolicySha256Text(
        canonicalAgentValue(corruptChildCandidate.canonicalRequest)
    )
    rejectOutputLimitRetry(
        corruptChild, corruptChildCandidate, corruptChildCandidate.continuation(corruptChild),
        "model.recovery_boundary_corrupt",
        "corrupt child resolved-policy canonical text is propagated fail-closed"
    )

    let corruptChildScalar = OutputLimitRecoveryFixture(database, "recovery-child-resolved-scalar")
    let corruptChildScalarCandidate = OutputLimitRecoveryChild(corruptChildScalar)
    let corruptChildScalarPolicy = corruptChildScalarCandidate.canonicalRequest
        .field("resolved_policy").getOrThrow()
    corruptChildScalarCandidate.canonicalRequest = replaceRecoveryField(
        corruptChildScalarCandidate.canonicalRequest,
        "resolved_policy",
        replaceRecoveryField(corruptChildScalarPolicy, "output_effective", integerValue(8192))
    )
    corruptChildScalarCandidate.semanticRequestDigest = modelPolicySha256Text(
        canonicalAgentValue(corruptChildScalarCandidate.canonicalRequest)
    )
    rejectOutputLimitRetry(
        corruptChildScalar, corruptChildScalarCandidate,
        corruptChildScalarCandidate.continuation(corruptChildScalar),
        "model.recovery_boundary_corrupt",
        "resolved-policy scalar drift is propagated fail-closed"
    )

    let missingParent = OutputLimitRecoveryFixture(
        database, "recovery-parent-resolved-missing", parentResolvedCorruption: "missing"
    )
    rejectOutputLimitRetry(
        missingParent, OutputLimitRecoveryChild(missingParent),
        OutputLimitRecoveryChild(missingParent).continuation(missingParent),
        "model.recovery_boundary_corrupt",
        "missing parent resolved policy is propagated fail-closed"
    )

    let corruptParent = OutputLimitRecoveryFixture(
        database, "recovery-parent-resolved-corrupt", parentResolvedCorruption: "canonical"
    )
    rejectOutputLimitRetry(
        corruptParent, OutputLimitRecoveryChild(corruptParent),
        OutputLimitRecoveryChild(corruptParent).continuation(corruptParent),
        "model.recovery_boundary_corrupt",
        "corrupt parent resolved-policy canonical text is propagated fail-closed"
    )

    let corruptParentScalar = OutputLimitRecoveryFixture(
        database, "recovery-parent-resolved-scalar", parentResolvedCorruption: "scalar"
    )
    rejectOutputLimitRetry(
        corruptParentScalar, OutputLimitRecoveryChild(corruptParentScalar),
        OutputLimitRecoveryChild(corruptParentScalar).continuation(corruptParentScalar),
        "model.recovery_boundary_corrupt",
        "parent resolved-policy scalar drift is propagated fail-closed"
    )
}

func outputLimitRetryDigestAlignmentContract(database: SqliteDatabase): Unit {
    let childSemantic = OutputLimitRecoveryFixture(database, "recovery-child-semantic-digest")
    let childSemanticCandidate = OutputLimitRecoveryChild(childSemantic)
    childSemanticCandidate.semanticRequestDigest = "tampered-child-semantic-digest"
    rejectOutputLimitRetry(
        childSemantic, childSemanticCandidate, childSemanticCandidate.continuation(childSemantic),
        "model.recovery_boundary_corrupt",
        "child request payload digest mismatch is propagated fail-closed"
    )

    let childWire = OutputLimitRecoveryFixture(database, "recovery-child-wire-digest")
    let childWireCandidate = OutputLimitRecoveryChild(childWire)
    childWireCandidate.wirePolicyDigest = "tampered-child-wire-digest"
    rejectOutputLimitRetry(
        childWire, childWireCandidate, childWireCandidate.continuation(childWire),
        "model.recovery_boundary_corrupt",
        "child wire-policy digest mismatch is propagated fail-closed"
    )

    let parentSemantic = OutputLimitRecoveryFixture(
        database, "recovery-parent-semantic-digest",
        parentSemanticDigestMutation: "tampered-parent-semantic-digest"
    )
    rejectOutputLimitRetry(
        parentSemantic, OutputLimitRecoveryChild(parentSemantic),
        OutputLimitRecoveryChild(parentSemantic).continuation(parentSemantic),
        "model.recovery_boundary_corrupt",
        "parent request payload digest mismatch is propagated fail-closed"
    )

    let parentWire = OutputLimitRecoveryFixture(
        database, "recovery-parent-wire-digest",
        parentWireDigestMutation: "tampered-parent-wire-digest"
    )
    rejectOutputLimitRetry(
        parentWire, OutputLimitRecoveryChild(parentWire),
        OutputLimitRecoveryChild(parentWire).continuation(parentWire),
        "model.recovery_boundary_corrupt",
        "parent wire-policy digest mismatch is propagated fail-closed"
    )
}

func outputLimitRetryIdentityAndLifecycleContract(database: SqliteDatabase): Unit {
    let attemptNumber = OutputLimitRecoveryFixture(database, "recovery-attempt-number")
    let attemptNumberChild = OutputLimitRecoveryChild(attemptNumber)
    attemptNumberChild.attemptNo = 3
    rejectOutputLimitRetry(attemptNumber, attemptNumberChild,
        "recovery child must be attempt A2")

    let childSemantic = OutputLimitRecoveryFixture(database, "recovery-child-semantic")
    let childSemanticCandidate = OutputLimitRecoveryChild(childSemantic)
    childSemanticCandidate.semanticRequestId = SemanticModelRequestId("other-semantic")
    rejectOutputLimitRetry(childSemantic, childSemanticCandidate,
        "child semantic request identity drift is rejected")

    let childParent = OutputLimitRecoveryFixture(database, "recovery-child-parent")
    let childParentCandidate = OutputLimitRecoveryChild(childParent)
    childParentCandidate.parentAttemptId = Some(ModelAttemptId("other-parent"))
    rejectOutputLimitRetry(childParent, childParentCandidate,
        "child parent-attempt identity drift is rejected")

    let originalAttempt = OutputLimitRecoveryFixture(database, "recovery-original-attempt")
    let originalAttemptCandidate = OutputLimitRecoveryChild(originalAttempt)
    originalAttemptCandidate.originalAttemptId = ModelAttemptId("other-original")
    rejectOutputLimitRetry(originalAttempt, originalAttemptCandidate,
        "child checkpoint must retain the original A1 identity")

    let activeAttempt = OutputLimitRecoveryFixture(database, "recovery-active-attempt")
    let activeAttemptCandidate = OutputLimitRecoveryChild(activeAttempt)
    activeAttemptCandidate.id = activeAttempt.parentAttemptId
    activeAttemptCandidate.activeAttemptId = activeAttempt.parentAttemptId
    rejectOutputLimitRetry(activeAttempt, activeAttemptCandidate,
        "recovery child identity must be distinct from its active parent")

    let stableTurn = OutputLimitRecoveryFixture(database, "recovery-stable-turn")
    let stableTurnCandidate = OutputLimitRecoveryChild(stableTurn)
    stableTurnCandidate.stableTurnId = "other-turn"
    rejectOutputLimitRetry(stableTurn, stableTurnCandidate,
        "stable turn identity cannot change during recovery")

    let stableRequest = OutputLimitRecoveryFixture(database, "recovery-stable-request")
    let stableRequestCandidate = OutputLimitRecoveryChild(stableRequest)
    stableRequestCandidate.providerRequestId = stableRequest.parentRequestId + "-retry-2"
    stableRequestCandidate.stableRequestId = stableRequestCandidate.providerRequestId
    rejectOutputLimitRetry(stableRequest, stableRequestCandidate,
        "recovery wire request ID must use the exact retry-1 suffix")

    let childLifecycle = OutputLimitRecoveryFixture(database, "recovery-child-lifecycle")
    let childLifecycleCandidate = OutputLimitRecoveryChild(childLifecycle)
    childLifecycleCandidate.lifecycle = ModelAttemptLifecycle.Streaming
    rejectOutputLimitRetry(childLifecycle, childLifecycleCandidate,
        "recovery child must remain Created before prepare")

    let childDispatch = OutputLimitRecoveryFixture(database, "recovery-child-dispatch")
    let childDispatchCandidate = OutputLimitRecoveryChild(childDispatch)
    childDispatchCandidate.dispatchState = ModelAttemptDispatchState.DispatchClaimed
    rejectOutputLimitRetry(childDispatch, childDispatchCandidate,
        "recovery child must be Prepared before dispatch claim")

    let childBarrier = OutputLimitRecoveryFixture(database, "recovery-child-barrier")
    let childBarrierCandidate = OutputLimitRecoveryChild(childBarrier)
    childBarrierCandidate.replayBarrier = ModelAttemptReplayBarrier.ToolEvidence
    rejectOutputLimitRetry(childBarrier, childBarrierCandidate,
        "recovery child must have no replay barrier")

    let parentNotDispatched = OutputLimitRecoveryFixture(
        database, "recovery-parent-not-dispatched", parentBarrier: ModelAttemptReplayBarrier.NoBarrier,
        claimParentDispatch: false
    )
    rejectOutputLimitRetry(parentNotDispatched, OutputLimitRecoveryChild(parentNotDispatched),
        "parent must have claimed provider dispatch before recovery")

    let parentNotAbandoned = OutputLimitRecoveryFixture(
        database, "recovery-parent-not-abandoned", terminalizeParent: false
    )
    rejectOutputLimitRetry(parentNotAbandoned, OutputLimitRecoveryChild(parentNotAbandoned),
        "parent must be durably Abandoned before recovery")

    let parentWrongFailure = OutputLimitRecoveryFixture(
        database, "recovery-parent-wrong-failure", failureKind: "stream_idle_timeout"
    )
    rejectOutputLimitRetry(parentWrongFailure, OutputLimitRecoveryChild(parentWrongFailure),
        "only output-limit parent failures authorize recovery")

    let parentCancelledBarrier = OutputLimitRecoveryFixture(
        database, "recovery-parent-cancelled-barrier",
        parentBarrier: ModelAttemptReplayBarrier.Cancelled
    )
    rejectOutputLimitRetry(parentCancelledBarrier,
        OutputLimitRecoveryChild(parentCancelledBarrier),
        "cancelled parent replay barrier cannot authorize recovery")

    let parentDeadlineBarrier = OutputLimitRecoveryFixture(
        database, "recovery-parent-deadline-barrier",
        parentBarrier: ModelAttemptReplayBarrier.RunDeadline
    )
    rejectOutputLimitRetry(parentDeadlineBarrier,
        OutputLimitRecoveryChild(parentDeadlineBarrier),
        "run-deadline parent replay barrier cannot authorize recovery")
}

func outputLimitRetryDecisionAndCompetitionContract(database: SqliteDatabase): Unit {
    let decisionFixture = OutputLimitRecoveryFixture(database, "recovery-parent-decision")
    insertRecoveryParentDecision(decisionFixture)
    rejectOutputLimitRetry(decisionFixture, OutputLimitRecoveryChild(decisionFixture),
        "a persisted parent Model Decision prevents output-limit recovery")

    let competing = OutputLimitRecoveryFixture(database, "recovery-competing-children")
    let winner = OutputLimitRecoveryChild(competing)
    acceptOutputLimitRetry(competing, winner,
        "first competing recovery child commits")
    let afterWinner = outputLimitRecoveryStoreFingerprint(competing)
    let loser = OutputLimitRecoveryChild(competing)
    loser.id = ModelAttemptId(competing.name + "-attempt-rival")
    loser.activeAttemptId = loser.id
    let loserResult = competing.repository.prepareModelAttempt(
        loser.attempt(competing), loser.event(competing), loser.continuation(competing)
    )
    expect(loserResult.isError() &&
        outputLimitRecoveryStoreFingerprint(competing) == afterWinner &&
        competing.database.scalarInt(
            "SELECT COUNT(*) FROM model_attempts WHERE run_id=" + sqliteText(competing.runId.value)
        ) == 2,
        "a stale competing child is rejected without changing Attempt/Event/Continuation state")

    let beforeDuplicate = outputLimitRecoveryStoreFingerprint(competing)
    expect(competing.repository.prepareModelAttempt(
        winner.attempt(competing), winner.event(competing), winner.continuation(competing)
    ).isOk() && outputLimitRecoveryStoreFingerprint(competing) == beforeDuplicate,
        "identical prepared recovery child is idempotent")

    let eventCountBeforeDispatch = competing.database.scalarInt(
        "SELECT COUNT(*) FROM app_run_events WHERE run_id=" + sqliteText(competing.runId.value)
    )
    let dispatchEvent = recoveryEvent(
        competing.childEventSequence + 1, competing.runId,
        winner.semanticRequestId, winner.id, "model.attempt_dispatch_claimed"
    )
    let firstDispatch = competing.repository.claimModelAttemptDispatch(winner.id, dispatchEvent)
    let afterFirstDispatch = outputLimitRecoveryStoreFingerprint(competing)
    let secondDispatch = competing.repository.claimModelAttemptDispatch(winner.id, dispatchEvent)
    expect(firstDispatch.isOk() && firstDispatch.value().getOrThrow() &&
        secondDispatch.isOk() && !secondDispatch.value().getOrThrow() &&
        outputLimitRecoveryStoreFingerprint(competing) == afterFirstDispatch &&
        competing.database.scalarInt(
            "SELECT COUNT(*) FROM app_run_events WHERE run_id=" + sqliteText(competing.runId.value)
        ) == eventCountBeforeDispatch + 1,
        "recovery dispatch can be claimed and journaled only once")
    outputLimitRetryConcurrentPrepareRace(database)
}

func outputLimitRetryConcurrentPrepareRace(database: SqliteDatabase): Unit {
    let fixture = OutputLimitRecoveryFixture(database, "recovery-competing-concurrent")
    let left = OutputLimitRecoveryChild(fixture)
    left.id = ModelAttemptId(fixture.name + "-attempt-left")
    left.activeAttemptId = left.id
    let right = OutputLimitRecoveryChild(fixture)
    right.id = ModelAttemptId(fixture.name + "-attempt-right")
    right.activeAttemptId = right.id

    let ready = AtomicInt64(0)
    let release = AtomicBool(false)
    let leftPrepare = spawn {
        let _ = ready.fetchAdd(1)
        while (!release.load()) { sleep(Duration.millisecond) }
        fixture.repository.prepareModelAttempt(
            left.attempt(fixture), left.event(fixture), left.continuation(fixture)
        )
    }
    let rightPrepare = spawn {
        let _ = ready.fetchAdd(1)
        while (!release.load()) { sleep(Duration.millisecond) }
        fixture.repository.prepareModelAttempt(
            right.attempt(fixture), right.event(fixture), right.continuation(fixture)
        )
    }
    var waitMillis: Int64 = 0
    while (ready.load() < 2 && waitMillis < 5000) {
        sleep(Duration.millisecond)
        waitMillis += 1
    }
    let bothReady = ready.load() == 2
    release.store(true)
    let leftResult = leftPrepare.get()
    let rightResult = rightPrepare.get()
    let leftWon = leftResult.isOk()
    let rightWon = rightResult.isOk()
    let winnerId = if (leftWon) { left.id.value } else { right.id.value }
    let activeAttemptId = fixture.repository.continuation(fixture.runId)
        .value().getOrThrow().runningModel.getOrThrow().activeAttemptId.value
    expect(bothReady && leftWon != rightWon && activeAttemptId == winnerId &&
        fixture.database.scalarInt(
            "SELECT COUNT(*) FROM model_attempts WHERE run_id=" + sqliteText(fixture.runId.value)
        ) == 2 &&
        fixture.database.scalarInt(
            "SELECT COUNT(*) FROM app_run_events WHERE run_id=" + sqliteText(fixture.runId.value)
        ) == fixture.childEventSequence &&
        outputLimitRecoveryStoreFingerprint(fixture).contains(winnerId),
        "simultaneous competing SQLite child prepares commit exactly one child atomically")
}
class OutputLimitRecoveryFixture {
    public let database: SqliteDatabase
    public let name: String
    public let repository: SqliteRunRepository
    public let decisions: SqliteModelDecisionStore
    public let runId: RunId
    public let sessionId: SessionId
    public let semanticRequestId: SemanticModelRequestId
    public let parentAttemptId: ModelAttemptId
    public let childAttemptId: ModelAttemptId
    public let stableTurnId: String
    public let parentRequestId: String
    public let childRequestId: String
    public let model: String
    public let frozenRequestedPolicy: RequestedModelPolicy
    public let frozenCapabilities: ModelExecutionCapabilitiesSnapshot
    public let resolverVersion: UInt32
    public let childCanonicalRequest: AgentValue
    public let childSemanticRequestDigest: String
    public let childWirePolicyDigest: String
    public let childPolicy: AgentValue
    public let parent: DurableModelAttempt
    public let childEventSequence: Int64

    public init(
        database: SqliteDatabase,
        name: String,
        parentBarrier!: ModelAttemptReplayBarrier = ModelAttemptReplayBarrier.ProviderTerminal,
        failureKind!: String = "output_limited",
        parentRequestSuffix!: String = "",
        terminalizeParent!: Bool = true,
        claimParentDispatch!: Bool = true,
        frozenRequestedPolicy!: ?RequestedModelPolicy = None,
        frozenCapabilities!: ?ModelExecutionCapabilitiesSnapshot = None,
        resolverVersion!: UInt32 = MODEL_POLICY_RESOLUTION_VERSION,
        parentResolvedCorruption!: String = "",
        parentPolicyReason!: String = "initial",
        parentPolicyMutation!: String = "",
        parentSemanticDigestMutation!: String = "",
        parentWireDigestMutation!: String = ""
    ) {
        this.database = database
        this.name = name
        seedOutputLimitRecoveryRun(database, name)
        let repository = SqliteRunRepository(database)
        this.repository = repository
        let decisions = SqliteModelDecisionStore(database)
        this.decisions = decisions
        let runId = RunId(name + "-run")
        let sessionId = SessionId(name + "-thread")
        let semanticRequestId = SemanticModelRequestId(name + "-semantic")
        let parentAttemptId = ModelAttemptId(name + "-attempt-1")
        let childAttemptId = ModelAttemptId(name + "-attempt-2")
        let stableTurnId = name + "-turn"
        let parentRequestId = name + "-request" + parentRequestSuffix
        let childRequestId = parentRequestId + "-retry-1"
        let model = "fixture"
        this.runId = runId
        this.sessionId = sessionId
        this.semanticRequestId = semanticRequestId
        this.parentAttemptId = parentAttemptId
        this.childAttemptId = childAttemptId
        this.stableTurnId = stableTurnId
        this.parentRequestId = parentRequestId
        this.childRequestId = childRequestId
        this.model = model
        expect(repository.save(RunSnapshot(
            runId, sessionId, RunState.Running, summary: "output-limit recovery"
        )).isOk(), "output-limit recovery fixture stores its canonical Run")

        let defaultRequested = RequestedModelPolicy(
            ThinkingLevel.Medium,
            RequestOutputBudget(16384, minVisibleResponseTokens: 1024)
        )
        let defaultCapabilities = ModelExecutionCapabilitiesSnapshot(
            model,
            ThinkingCapabilities(
                ThinkingControlMode.Effort,
                supportedLevels: canonicalNonOffThinkingLevels()
            ),
            16384
        )
        let effectiveRequested = match (frozenRequestedPolicy) {
            case Some(value) => value
            case None => defaultRequested
        }
        let effectiveCapabilities = match (frozenCapabilities) {
            case Some(value) => value
            case None => defaultCapabilities
        }
        this.frozenRequestedPolicy = effectiveRequested
        this.frozenCapabilities = effectiveCapabilities
        this.resolverVersion = resolverVersion

        let parentResolution = recoveryResolvePolicy(
            defaultRequested, defaultCapabilities, None
        )
        let childCeiling = match (nextLowerThinkingCeiling(
            defaultCapabilities, parentResolution.thinking.effective
        )) {
            case Some(value) => value
            case None => throw IllegalStateException("recovery fixture has no lower thinking level")
        }
        let childResolution = recoveryResolvePolicy(
            defaultRequested, defaultCapabilities, Some(childCeiling)
        )

        let expectedParentCanonical = recoveryRequestCanonical(parentResolution)
        let parentCanonical = match (parentResolvedCorruption) {
            case "missing" => removeRecoveryField(expectedParentCanonical, "resolved_policy")
            case "canonical" => replaceRecoveryField(
                expectedParentCanonical,
                "resolved_policy",
                replaceRecoveryField(
                    expectedParentCanonical.field("resolved_policy").getOrThrow(),
                    "canonical", textValue("tampered policy")
                )
            )
            case "scalar" => replaceRecoveryField(
                expectedParentCanonical,
                "resolved_policy",
                replaceRecoveryField(
                    expectedParentCanonical.field("resolved_policy").getOrThrow(),
                    "output_effective", integerValue(8192)
                )
            )
            case _ => expectedParentCanonical
        }
        let parentSemanticDigestCanonical = modelPolicySha256Text(canonicalAgentValue(parentCanonical))
        let parentSemanticDigest = if (parentSemanticDigestMutation == "") {
            parentSemanticDigestCanonical
        } else { parentSemanticDigestMutation }
        let parentPolicyBase = attemptPolicyValue(AttemptPolicy(
            model, parentResolution.thinking.effective, ModelToolChoice.Auto,
            parentResolution.output.effectiveWireLimit,
            streamIdleMillis: 60000,
            resolvedPolicy: Some(parentResolution)
        ))
        let parentPolicy = if (parentPolicyMutation == "") { parentPolicyBase } else {
            let replacement = if (parentPolicyMutation == "max_output_tokens") {
                integerValue(8192)
            } else { textValue("tampered") }
            replaceRecoveryField(parentPolicyBase, parentPolicyMutation, replacement)
        }
        let parentWireDigestCanonical = modelAttemptWirePolicyDigest(
            model, parentResolution.output.effectiveWireLimit, ModelToolChoice.Auto, 0,
            canonicalResolvedModelRequestPolicy(parentResolution)
        )
        let parentWireDigest = if (parentWireDigestMutation == "") {
            parentWireDigestCanonical
        } else { parentWireDigestMutation }

        let childCanonical = recoveryRequestCanonical(childResolution)
        let childSemanticDigest = modelPolicySha256Text(canonicalAgentValue(childCanonical))
        let childPolicy = attemptPolicyValue(AttemptPolicy(
            model, childResolution.thinking.effective, ModelToolChoice.Auto,
            childResolution.output.effectiveWireLimit,
            reason: AttemptPolicyReason.OutputLimitRecovery,
            streamIdleMillis: 60000,
            resolvedPolicy: Some(childResolution)
        ))
        let childWireDigest = modelAttemptWirePolicyDigest(
            model, childResolution.output.effectiveWireLimit, ModelToolChoice.Auto, 0,
            canonicalResolvedModelRequestPolicy(childResolution)
        )
        this.childCanonicalRequest = childCanonical
        this.childSemanticRequestDigest = childSemanticDigest
        this.childWirePolicyDigest = childWireDigest
        this.childPolicy = childPolicy

        let parentCheckpoint = RunningModelCheckpoint(
            semanticRequestId, parentCanonical, parentSemanticDigest, parentWireDigest,
            parentAttemptId, parentAttemptId, stableTurnId, parentRequestId, 1
        )
        let parentContinuation = recoveryContinuation(
            runId, sessionId, model, parentCheckpoint,
            effectiveRequested, effectiveCapabilities, resolverVersion
        )
        let parentAttempt = DurableModelAttempt(
            parentAttemptId, semanticRequestId, runId, 1, ModelAttemptLifecycle.Created,
            parentPolicy, parentPolicyReason, 1, 1,
            providerRequestId: parentRequestId,
            semanticRequestDigest: parentSemanticDigest,
            wirePolicyDigest: parentWireDigest
        )
        expect(repository.prepareModelAttempt(
            parentAttempt,
            recoveryEvent(1, runId, semanticRequestId, parentAttemptId, "model.attempt_policy_applied"),
            parentContinuation
        ).isOk(), "output-limit recovery fixture persists its A1 parent")

        var nextSequence: Int64 = 2
        if (claimParentDispatch) {
            let dispatch = repository.claimModelAttemptDispatch(
                parentAttemptId,
                recoveryEvent(nextSequence, runId, semanticRequestId, parentAttemptId,
                    "model.attempt_dispatch_claimed")
            )
            expect(dispatch.isOk() && dispatch.value().getOrThrow(),
                "output-limit recovery fixture claims A1 dispatch")
            nextSequence += 1
        }
        if (parentBarrier != ModelAttemptReplayBarrier.NoBarrier) {
            expect(repository.markModelAttemptReplayBarrier(
                parentAttemptId, parentBarrier,
                recoveryEvent(nextSequence, runId, semanticRequestId, parentAttemptId,
                    "model.attempt_replay_barrier")
            ).isOk(), "output-limit recovery fixture stores its requested parent barrier")
            nextSequence += 1
        }
        if (terminalizeParent) {
            expect(decisions.terminalizeAttempt(
                parentAttemptId, ModelAttemptLifecycle.Abandoned, failureKind,
                (nextSequence - 1) * 10 + 5
            ).isOk(), "output-limit recovery fixture terminalizes its A1 parent")
        }
        this.parent = match (repository.modelAttempt(parentAttemptId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(
                "output-limit recovery parent read failed: " + error.code
            )
        }
        this.childEventSequence = nextSequence
    }
}

class OutputLimitRecoveryChild {
    public var id: ModelAttemptId
    public var semanticRequestId: SemanticModelRequestId
    public var attemptNo: Int64
    public var parentAttemptId: ?ModelAttemptId
    public var lifecycle: ModelAttemptLifecycle
    public var policy: AgentValue
    public var policyReason: String
    public var providerRequestId: String
    public var semanticRequestDigest: String
    public var wirePolicyDigest: String
    public var dispatchState: ModelAttemptDispatchState
    public var replayBarrier: ModelAttemptReplayBarrier
    public var canonicalRequest: AgentValue
    public var originalAttemptId: ModelAttemptId
    public var activeAttemptId: ModelAttemptId
    public var stableTurnId: String
    public var stableRequestId: String

    public init(fixture: OutputLimitRecoveryFixture) {
        this.id = fixture.childAttemptId
        this.semanticRequestId = fixture.semanticRequestId
        this.attemptNo = 2
        this.parentAttemptId = Some(fixture.parentAttemptId)
        this.lifecycle = ModelAttemptLifecycle.Created
        this.policy = fixture.childPolicy
        this.policyReason = "output_limit_recovery"
        this.providerRequestId = fixture.childRequestId
        this.semanticRequestDigest = fixture.childSemanticRequestDigest
        this.wirePolicyDigest = fixture.childWirePolicyDigest
        this.dispatchState = ModelAttemptDispatchState.Prepared
        this.replayBarrier = ModelAttemptReplayBarrier.NoBarrier
        this.canonicalRequest = fixture.childCanonicalRequest
        this.originalAttemptId = fixture.parentAttemptId
        this.activeAttemptId = fixture.childAttemptId
        this.stableTurnId = fixture.stableTurnId
        this.stableRequestId = fixture.childRequestId
    }

    public func checkpoint(fixture: OutputLimitRecoveryFixture): RunningModelCheckpoint {
        RunningModelCheckpoint(
            semanticRequestId, canonicalRequest, semanticRequestDigest, wirePolicyDigest,
            originalAttemptId, activeAttemptId, stableTurnId, stableRequestId, 2,
            modelRequests: 1,
            workModelRequests: 1,
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: 5,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            costMicros: Some(130),
            lastInputTokens: 100,
            lastOutputTokens: 20
        )
    }

    public func continuation(fixture: OutputLimitRecoveryFixture): RunContinuation {
        recoveryContinuation(
            fixture, checkpoint(fixture), fixture.frozenRequestedPolicy,
            fixture.frozenCapabilities, fixture.resolverVersion, fixture.model
        )
    }

    public func attempt(fixture: OutputLimitRecoveryFixture): DurableModelAttempt {
        DurableModelAttempt(
            id, semanticRequestId, fixture.runId, attemptNo, lifecycle, policy,
            policyReason, fixture.childEventSequence * 10, fixture.childEventSequence * 10,
            parentAttemptId: parentAttemptId,
            providerRequestId: providerRequestId,
            semanticRequestDigest: semanticRequestDigest,
            wirePolicyDigest: wirePolicyDigest,
            dispatchState: dispatchState,
            replayBarrier: replayBarrier
        )
    }

    public func event(fixture: OutputLimitRecoveryFixture): AgentEvent {
        recoveryEvent(
            fixture.childEventSequence, fixture.runId, semanticRequestId, id,
            "model.attempt_policy_applied"
        )
    }
}

func recoveryResolvePolicy(
    requested: RequestedModelPolicy,
    capabilities: ModelExecutionCapabilitiesSnapshot,
    ceiling: ?ThinkingLevel
): ResolvedModelRequestPolicy {
    match (resolveModelAttemptPolicy(AttemptPolicyInput(
        requested, capabilities, recoveryCeiling: ceiling
    ))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "output-limit recovery fixture policy resolution failed: " + error.code
        )
    }
}

func recoveryRequestCanonical(policy: ResolvedModelRequestPolicy): AgentValue {
    let userBlock = objectValue([
        ValueField("kind", textValue("text")),
        ValueField("text", textValue("Use the frozen fixture request.")),
        ValueField("call_id", textValue("")),
        ValueField("name", textValue("")),
        ValueField("arguments", objectValue([])),
        ValueField("is_error", boolValue(false)),
        ValueField("receipt_id", textValue("")),
        ValueField("image", nullValue()),
        ValueField("opaque_state", nullValue())
    ])
    let userMessage = objectValue([
        ValueField("role", textValue("user")),
        ValueField("blocks", listValue([userBlock]))
    ])
    let echoTool = objectValue([
        ValueField("name", textValue("echo")),
        ValueField("description", textValue("Fixture echo tool")),
        ValueField("input_schema", objectValue([
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue([])),
            ValueField("required", listValue([]))
        ]))
    ])
    objectValue([
        ValueField("model", textValue("fixture")),
        ValueField("system", textValue("fixture system")),
        ValueField("messages", listValue([userMessage])),
        ValueField("tools", listValue([echoTool])),
        ValueField("thinking", textValue(modelPolicyThinkingLevelName(policy.thinking.effective))),
        ValueField("wire_max_output_tokens", integerValue(policy.output.effectiveWireLimit)),
        ValueField("streaming", boolValue(true)),
        ValueField("parallel_tool_calls", boolValue(true)),
        ValueField("service_tier", textValue("priority")),
        ValueField("cache_policy", textValue("stable_prefix")),
        ValueField("cache_key", textValue("recovery-cache")),
        ValueField("tool_choice", textValue("auto")),
        ValueField("structured_output", nullValue()),
        ValueField("resolved_policy", resolvedModelPolicyCheckpointValue(policy))
    ])
}

func recoveryContinuation(
    fixture: OutputLimitRecoveryFixture,
    checkpoint: RunningModelCheckpoint,
    requested: RequestedModelPolicy,
    capabilities: ModelExecutionCapabilitiesSnapshot,
    resolverVersion: UInt32,
    model: String
): RunContinuation {
    recoveryContinuation(
        fixture.runId, fixture.sessionId, model, checkpoint,
        requested, capabilities, resolverVersion
    )
}

func recoveryContinuation(
    runId: RunId,
    sessionId: SessionId,
    model: String,
    checkpoint: RunningModelCheckpoint,
    requested: RequestedModelPolicy,
    capabilities: ModelExecutionCapabilitiesSnapshot,
    resolverVersion: UInt32
): RunContinuation {
    RunContinuation(
        RunContinuationKind.RunningModel, runId, sessionId, model,
        "Use the frozen fixture request.", checkpoint, requested, capabilities,
        system: "fixture system",
        thinking: ThinkingLevel.Medium,
        serviceTier: "priority",
        cachePolicy: ModelCachePolicy.StablePrefix,
        cacheKey: "recovery-cache",
        parallelToolCalls: true,
        resolverVersion: resolverVersion
    )
}

func acceptOutputLimitRetry(
    fixture: OutputLimitRecoveryFixture,
    candidate: OutputLimitRecoveryChild,
    message: String
): Unit {
    let childAttempt = candidate.attempt(fixture)
    let childContinuation = candidate.continuation(fixture)
    let prepared = fixture.repository.prepareModelAttempt(
        childAttempt, candidate.event(fixture), childContinuation
    )
    let prepareMessage = if (prepared.isError()) {
        message + ": " + prepared.error().getOrThrow().describe()
    } else { message }
    expect(prepared.isOk(), prepareMessage)
    let savedParent = fixture.repository.modelAttempt(fixture.parentAttemptId).value().getOrThrow()
    let savedChild = fixture.repository.modelAttempt(candidate.id).value().getOrThrow()
    let savedContinuation = fixture.repository.continuation(fixture.runId).value().getOrThrow()
    let checkpoint = savedContinuation.runningModel.getOrThrow()
    expect(savedParent.lifecycle == ModelAttemptLifecycle.Abandoned &&
        savedParent.failureKind == fixture.parent.failureKind &&
        savedChild.attemptNo == 2 && savedChild.parentAttemptId.isSome() &&
        savedChild.parentAttemptId.getOrThrow().value == fixture.parentAttemptId.value &&
        savedChild.policyReason == "output_limit_recovery" &&
        canonicalAgentValue(savedChild.policy) == canonicalAgentValue(candidate.policy) &&
        checkpoint.canonicalRequest.field("thinking").getOrThrow().text == "low" &&
        checkpoint.activeAttemptId.value == candidate.id.value &&
        checkpoint.originalAttemptId.value == fixture.parentAttemptId.value &&
        checkpoint.modelRequests == 1 && checkpoint.inputTokens == 100 &&
        checkpoint.outputTokens == 20 && checkpoint.reasoningTokens == 5 &&
        checkpoint.cacheReadTokens == 30 && checkpoint.cacheWriteTokens == 10 &&
        checkpoint.costMicros == Some(130) &&
        fixture.parent.semanticRequestDigest != savedChild.semanticRequestDigest &&
        fixture.parent.wirePolicyDigest != savedChild.wirePolicyDigest,
        "legal recovery persists its A2 policy, changed digest, and carried usage counters")
}

func rejectOutputLimitRetry(
    fixture: OutputLimitRecoveryFixture,
    candidate: OutputLimitRecoveryChild,
    message: String
): Unit {
    rejectOutputLimitRetry(
        fixture, candidate, candidate.continuation(fixture), "", message
    )
}

func rejectOutputLimitRetry(
    fixture: OutputLimitRecoveryFixture,
    candidate: OutputLimitRecoveryChild,
    continuation: RunContinuation,
    message: String
): Unit {
    rejectOutputLimitRetry(fixture, candidate, continuation, "", message)
}

func rejectOutputLimitRetry(
    fixture: OutputLimitRecoveryFixture,
    candidate: OutputLimitRecoveryChild,
    continuation: RunContinuation,
    expectedCode: String,
    message: String
): Unit {
    let before = outputLimitRecoveryStoreFingerprint(fixture)
    let result = fixture.repository.prepareModelAttempt(
        candidate.attempt(fixture), candidate.event(fixture), continuation
    )
    let errorMatches = if (expectedCode == "") { true } else {
        match (result.error()) {
            case Some(error) => error.code == expectedCode
            case None => false
        }
    }
    expect(result.isError() && errorMatches &&
        outputLimitRecoveryStoreFingerprint(fixture) == before,
        message + " (rejection must preserve Attempt/Event/Continuation rows)")
}

func replaceRecoveryField(value: AgentValue, name: String, replacement: AgentValue): AgentValue {
    let fields = ArrayList<ValueField>()
    var found = false
    for (field in value.fields) {
        if (field.name == name) {
            fields.add(ValueField(name, replacement))
            found = true
        } else {
            fields.add(field)
        }
    }
    if (!found) { fields.add(ValueField(name, replacement)) }
    objectValue(fields.toArray())
}

func removeRecoveryField(value: AgentValue, name: String): AgentValue {
    let fields = ArrayList<ValueField>()
    for (field in value.fields where field.name != name) { fields.add(field) }
    objectValue(fields.toArray())
}

func outputLimitRecoveryStoreFingerprint(fixture: OutputLimitRecoveryFixture): String {
    let run = sqliteText(fixture.runId.value)
    let attempts = fixture.database.query(
        "SELECT COALESCE(group_concat(row_value,char(10)),'') FROM (" +
            "SELECT id || '|' || semantic_request_id || '|' || run_id || '|' || " +
            "COALESCE(parent_attempt_id,'') || '|' || attempt_no || '|' || lifecycle || '|' || " +
            "policy || '|' || policy_reason || '|' || started_at_millis || '|' || " +
            "last_activity_at_millis || '|' || COALESCE(completed_at_millis,-1) || '|' || " +
            "provider_request_id || '|' || provider_response_id || '|' || failure_kind || '|' || " +
            "semantic_request_digest || '|' || wire_policy_digest || '|' || dispatch_state || '|' || " +
            "replay_barrier || '|' || COALESCE(dispatch_started_at_millis,-1) || '|' || " +
            "COALESCE(provider_terminal_at_millis,-1) || '|' || transcript_snapshot AS row_value FROM model_attempts " +
            "WHERE run_id=" + run + " ORDER BY id)"
    )[0].required(0)
    let events = fixture.database.query(
        "SELECT COALESCE(group_concat(row_value,char(10)),'') FROM (" +
            "SELECT sequence || '|' || sequence_start || '|' || sequence_end || '|' || " +
            "payload || '|' || accounting || '|' || event_class || '|' || stream_key || '|' || " +
            "delta_count || '|' || char_count || '|' || created_at_millis AS row_value " +
            "FROM app_run_events WHERE run_id=" + run + " ORDER BY sequence)"
    )[0].required(0)
    let eventHead = fixture.database.query(
        "SELECT last_sequence FROM app_run_event_heads WHERE run_id=" + run
    )[0].required(0)
    let continuations = fixture.database.query(
        "SELECT COALESCE(group_concat(payload || '|' || active_attempt_id,char(10)),'') " +
            "FROM run_continuations WHERE run_id=" + run
    )[0].required(0)
    attempts + "\n--events--\n" + events + "\n--event-head--\n" + eventHead +
        "\n--continuation--\n" + continuations
}

func insertRecoveryParentDecision(fixture: OutputLimitRecoveryFixture): Unit {
    fixture.database.execute(
        "INSERT INTO model_decisions(" +
            "id,attempt_id,semantic_request_id,validation_status,completion_disposition," +
            "decision_outcome,content_hash,replay_hash,provider_id,provider_response_id," +
            "terminal_evidence,validator_version,created_at_millis,canonical_committed_at_millis) VALUES(" +
            sqliteText(fixture.name + "-decision") + "," +
            sqliteText(fixture.parentAttemptId.value) + "," +
            sqliteText(fixture.semanticRequestId.value) + "," +
            sqliteText("rejected") + "," + sqliteText("output_limited") + "," +
            sqliteText("unknown") + "," + sqliteText("content") + "," +
            sqliteText("replay") + "," + sqliteText("fixture") + "," +
            sqliteText("") + "," + sqliteText("{}") + ",1,10,NULL)"
    )
}

func recoveryEvent(
    sequence: Int64,
    runId: RunId,
    semanticRequestId: SemanticModelRequestId,
    attemptId: ModelAttemptId,
    code: String
): AgentEvent {
    AgentEvent(
        EventMeta(sequence, TraceId("output-limit-recovery-contract"), runId,
            occurredAtMillis: sequence * 10,
            semanticRequestId: Some(semanticRequestId), attemptId: Some(attemptId)),
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([
            ValueField("code", textValue(code))
        ]))
    )
}

func seedOutputLimitRecoveryRun(database: SqliteDatabase, name: String): Unit {
    let thread = name + "-thread"
    let turn = name + "-turn"
    let userItem = name + "-user"
    let run = name + "-run"
    database.transaction<Unit>({ transaction =>
        transaction.execute(
            "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) VALUES(" +
                sqliteText(thread) + ",1,'workspace','open',2," + sqliteText(turn) + ")"
        )
        transaction.execute(
            "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) VALUES(" +
                sqliteText(turn) + "," + sqliteText(thread) + ",1,'active'," +
                sqliteText(userItem) + "," + sqliteText(run) + ")"
        )
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES(" +
                sqliteText(userItem) + "," + sqliteText(thread) + "," + sqliteText(turn) +
                ",1,'user_message','{}','user',1)"
        )
        transaction.execute(
            "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis) VALUES(" + sqliteText(run) + "," + sqliteText(thread) + "," +
                sqliteText(turn) + ",1,'running','{}','{}','{}','{}',1)"
        )
    })
}
