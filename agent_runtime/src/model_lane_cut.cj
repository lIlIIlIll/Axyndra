package agent_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Encoded immutable values prevent a caller from changing a lane after its CAS
// was validated. These are ordinary data, not an executor or capability grant.
public class RunModelLaneChange {
    private var ownedCut159: ?OwnedModelLaneCut159 = None<OwnedModelLaneCut159>
    private let previousJson: String
    private let nextJson: String
    public let observedAtMillis: Int64
    private let previousContextJson: ?String
    private let nextContextJson: ?String
    private let factLinks: Array<ContextReadFactLink>
    private let coreBoundaryJson: ?String

    public init(previous: ModelLane, next: ModelLane, observedAtMillis: Int64,
        previousContext!: ?InvocationContextProjection = None,
        nextContext!: ?InvocationContextProjection = None, contextFacts!: Array<ContextReadFactLink> = [],
        coreBoundary!: ?AgentValue = None) {
        if (observedAtMillis < 0) { throw IllegalArgumentException("negative safe-cut timestamp") }
        let frozenPrevious = stringifyUnifiedJson(modelLaneSnapshotValue(previous))
        let frozenNext = stringifyUnifiedJson(modelLaneSnapshotValue(next))
        // Bound before persisting; parsing also validates the frozen copy.
        let _ = modelLaneFromSnapshotValue(parseUnifiedJson(frozenPrevious, maxBytes: 4194304))
        let _ = modelLaneFromSnapshotValue(parseUnifiedJson(frozenNext, maxBytes: 4194304))
        if (!contextFacts.isEmpty() && nextContext.isNone()) { throw IllegalArgumentException("facts require a context projection cut") }
        this.coreBoundaryJson = match (coreBoundary) { case Some(value) =>
            let encoded = stringifyUnifiedJson(value)
            let _ = parseUnifiedJson(encoded, maxBytes: 8388608)
            Some(encoded)
            case None => None }
        this.factLinks = validatedContextReadFactLinks(contextFacts)
        this.observedAtMillis = observedAtMillis
        this.previousJson = frozenPrevious; this.nextJson = frozenNext
        if (previousContext.isSome() != nextContext.isSome()) {
            throw IllegalArgumentException("context cut requires both expected and replacement snapshots") }
        this.previousContextJson = match (previousContext) { case Some(value) =>
            Some(stringifyUnifiedJson(contextSnapshotValue(validatedContextSnapshot(value))))
            case None => None }
        this.nextContextJson = match (nextContext) { case Some(value) =>
            Some(stringifyUnifiedJson(contextSnapshotValue(validatedContextSnapshot(value))))
            case None => None }
    }

    init(input: OwnedModelLaneCut159, observedAtMillis: Int64,
        previousContext!: ?InvocationContextProjection = None,
        nextContext!: ?InvocationContextProjection = None, contextFacts!: Array<ContextReadFactLink> = [],
        coreBoundary!: ?AgentValue = None) {
        this.ownedCut159 = Some(input)
        input.reservePreviousCopy159(); input.reserveNextCopy159()
        if (observedAtMillis < 0) { throw IllegalArgumentException("negative safe-cut timestamp") }
        let frozenPrevious = stringifyUnifiedJson(input.previousValue159())
        let frozenNext = stringifyUnifiedJson(input.nextValue159())
        // Bound before persisting; parsing also validates the frozen copy.
        let _ = modelLaneFromSnapshotValue(parseUnifiedJson(frozenPrevious, maxBytes: 4194304))
        let _ = modelLaneFromSnapshotValue(parseUnifiedJson(frozenNext, maxBytes: 4194304))
        if (!contextFacts.isEmpty() && nextContext.isNone()) { throw IllegalArgumentException("facts require a context projection cut") }
        this.coreBoundaryJson = match (coreBoundary) { case Some(value) =>
            let encoded = stringifyUnifiedJson(value)
            let _ = parseUnifiedJson(encoded, maxBytes: 8388608)
            Some(encoded)
            case None => None }
        this.factLinks = validatedContextReadFactLinks(contextFacts)
        this.observedAtMillis = observedAtMillis
        this.previousJson = frozenPrevious; this.nextJson = frozenNext
        if (previousContext.isSome() != nextContext.isSome()) {
            throw IllegalArgumentException("context cut requires both expected and replacement snapshots") }
        this.previousContextJson = match (previousContext) { case Some(value) =>
            Some(stringifyUnifiedJson(contextSnapshotValue(validatedContextSnapshot(value))))
            case None => None }
        this.nextContextJson = match (nextContext) { case Some(value) =>
            Some(stringifyUnifiedJson(contextSnapshotValue(validatedContextSnapshot(value))))
            case None => None }
    }

    func clearOwnedCutLink159(): Unit { ownedCut159 = None<OwnedModelLaneCut159> }

    public func coreBoundary(): ?AgentValue { match (coreBoundaryJson) {
        case Some(value) => Some(parseUnifiedJson(value, maxBytes: 8388608)); case None => None } }

    public func contextFacts(): Array<ContextReadFactLink> { factLinks.clone() }
    public func previousContext(): ?InvocationContextProjection {
        match (previousContextJson) { case Some(value) => Some(contextSnapshotFromValue(parseUnifiedJson(value, maxBytes: 4194304)))
            case None => None }
    }
    public func nextContext(): ?InvocationContextProjection {
        match (nextContextJson) { case Some(value) => Some(contextSnapshotFromValue(parseUnifiedJson(value, maxBytes: 4194304)))
            case None => None }
    }
    public func previousLane(): ModelLane {
        match (ownedCut159) { case Some(value) => value.reservePreviousCopy159(); case None => () }
        modelLaneFromSnapshotValue(parseUnifiedJson(previousJson, maxBytes: 4194304))
    }
    public func nextLane(): ModelLane {
        match (ownedCut159) { case Some(value) => value.reserveNextCopy159(); case None => () }
        modelLaneFromSnapshotValue(parseUnifiedJson(nextJson, maxBytes: 4194304))
    }
}

public func modelLaneReplacingToolSet(lane: ModelLane, snapshot: ToolSetSnapshot): ModelLane {
    var anyTools = false
    for (entry in snapshot.entries where entry.availableAtSnapshot) { anyTools = true }
    let caps = lane.capabilities
    ModelLane(lane.role, lane.providerId, lane.modelId, lane.protocol,
        ModelLaneCapabilitiesSnapshot(streaming: caps.streaming, tools: anyTools,
            reasoning: caps.reasoning, structuredOutput: caps.structuredOutput,
            imageInput: caps.imageInput, promptCache: caps.promptCache,
            providerOpaqueState: caps.providerOpaqueState),
        lane.contextWindow, lane.outputReserve, lane.providerSafetyMargin, lane.estimatorId,
        lane.retryPolicyId, lane.cachePolicyId, snapshot, lane.systemInstructionVersion)
}

public func toolSetSnapshotContentDigest(snapshot: ToolSetSnapshot): String {
    let neutral = ToolSetSnapshot("content", snapshot.entries,
        hookHandlers: snapshot.hookHandlers, threadId: snapshot.threadId)
    let lane = modelLaneReplacingToolSet(ModelLane(ModelLaneRole.Main,
        "content", "content", "content", ModelLaneCapabilitiesSnapshot(),
        10, 1, 0, "content", "content", "content", ToolSetSnapshot("empty", []), "content"), neutral)
    modelPolicySha256Text(canonicalAgentValue(modelLaneSnapshotValue(lane)))
}

public func validateModelLaneChange(change: RunModelLaneChange, threadId: ThreadId): Unit {
    let before = change.previousLane()
    let after = change.nextLane()
    let snapshot = after.toolSet
    if (change.nextContext().isSome()) {
        if (canonicalAgentValue(modelLaneSnapshotValue(before)) != canonicalAgentValue(modelLaneSnapshotValue(after)) ||
            contextReadProjectionDigest(change.previousContext().getOrThrow()) ==
                contextReadProjectionDigest(change.nextContext().getOrThrow())) {
            throw IllegalArgumentException("context cut changes only a distinct prompt-data snapshot") }
        return
    }
    if (snapshot.threadId.isNone() || snapshot.threadId.getOrThrow().value != threadId.value ||
        before.toolSet.id == snapshot.id ||
        toolSetSnapshotContentDigest(before.toolSet) == toolSetSnapshotContentDigest(snapshot)) {
        throw IllegalArgumentException("safe cut requires a distinct snapshot for this Thread")
    }
    for (entry in snapshot.entries where !entry.hasCompleteIdentity()) {
        throw IllegalArgumentException("safe cut cannot admit an incomplete executor identity")
    }
    // A catalog change is not permission to replace provider, prompt policy,
    // resources, retry policy, or any unrelated model capability.
    if (canonicalAgentValue(modelLaneSnapshotValue(modelLaneReplacingToolSet(before, snapshot))) !=
        canonicalAgentValue(modelLaneSnapshotValue(after))) {
        throw IllegalArgumentException("safe cut may replace only the tool-set projection")
    }
}

func modelLaneCutError(code: String, message: String): AgentError {
    AgentError(AgentErrorKind.Conflict, code, message)
}
