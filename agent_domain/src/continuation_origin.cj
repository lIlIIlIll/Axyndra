package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// Fork/import history is data, never a continuation origin or live authority.
// The Store must verify the actual source and freeze its input in the same
// transaction that creates the new completed history.
public class ContinuationHistorySource {
    public let threadId: String
    public let turnId: String
    public let runId: String
    public let itemId: String
    public let requestDigest: String
    public init(threadId: String, turnId: String, runId: String, itemId: String, requestDigest: String) {
        for (value in [threadId, turnId, runId, itemId]) {
            if (value == "" || value.size > 256) { throw IllegalArgumentException("continuation history source is invalid") }
        }
        if (!continuationOriginDigest(requestDigest)) { throw IllegalArgumentException("continuation history digest is invalid") }
        this.threadId = threadId; this.turnId = turnId; this.runId = runId; this.itemId = itemId; this.requestDigest = requestDigest
    }
}
public func continuationHistorySourceValue(value: ContinuationHistorySource): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.continuation-history-source/v1")),
        ValueField("thread_id", textValue(value.threadId)), ValueField("turn_id", textValue(value.turnId)),
        ValueField("run_id", textValue(value.runId)), ValueField("item_id", textValue(value.itemId)),
        ValueField("request_digest", textValue(value.requestDigest))])
}
public func continuationHistorySourceFromValue(value: AgentValue): ContinuationHistorySource {
    if (!httpIntentExactFields(value, ["schema", "thread_id", "turn_id", "run_id", "item_id", "request_digest"]) ||
        httpIntentText(value, "schema") != "axyndra.continuation-history-source/v1") {
        throw IllegalArgumentException("unsupported continuation history source") }
    ContinuationHistorySource(httpIntentText(value, "thread_id"), httpIntentText(value, "turn_id"),
        httpIntentText(value, "run_id"), httpIntentText(value, "item_id"), httpIntentText(value, "request_digest"))
}
public func isContinuationHistoryDescription(item: ThreadItem): Bool {
    item.provenance.source == "continuation_history" && item.provenance.continuationHistory.isSome() &&
        item.provenance.continuationOrigin.isNone() && item.provenance.runId.isSome() &&
        item.provenance.operationId.isNone() && item.provenance.directOrigin.isNone() &&
        match (item.content) { case ThreadItemContent.SystemNote(text) => text == "Host continuation"; case _ => false }
}

// Historical description only. Neither this DTO nor its codec is an admission.
public class ContinuationRunOrigin {
    public let threadId: String
    public let laneId: String
    public let namespace: String
    public let documentKey: String
    public let allowanceId: String
    public let controlPayloadDigest: String
    public let controlSourceDigest: String
    public let previousRunId: String
    public let runId: String
    public let turnId: String
    public let initiatorItemId: String
    public let requestDigest: String
    public let launchDigest: String
    public let generation: Int64
    public let controlEventId: Int64
    public let expectedThreadRevision: Int64
    public let epoch: Int64
    public let documentObservation: ?ContinuationDocumentObservation
    public init(threadId: String,
        laneId: String,
        namespace: String,
        documentKey: String,
        allowanceId: String,
        controlPayloadDigest: String,
        controlSourceDigest: String,
        previousRunId: String,
        runId: String,
        turnId: String,
        initiatorItemId: String,
        requestDigest: String,
        launchDigest: String,
        generation: Int64,
        controlEventId: Int64,
        expectedThreadRevision: Int64,
        epoch: Int64,
        documentObservation!: ?ContinuationDocumentObservation = None) {
        for (value in [threadId, laneId, namespace, documentKey, allowanceId, previousRunId, runId, turnId, initiatorItemId]) {
            if (value == "" || value.size > 256) { throw IllegalArgumentException("continuation identity is missing or too large") }
        }
        for (value in [controlPayloadDigest, controlSourceDigest, requestDigest, launchDigest]) {
            if (!continuationOriginDigest(value)) { throw IllegalArgumentException("continuation digest is malformed") }
        }
        if (generation < 1 || controlEventId < 1 || expectedThreadRevision < 0 || epoch < 1 || previousRunId == runId) {
            throw IllegalArgumentException("continuation owner sequence is invalid")
        }
        this.threadId = threadId
        this.laneId = laneId
        this.namespace = namespace
        this.documentKey = documentKey
        this.allowanceId = allowanceId
        this.controlPayloadDigest = controlPayloadDigest
        this.controlSourceDigest = controlSourceDigest
        this.previousRunId = previousRunId
        this.runId = runId
        this.turnId = turnId
        this.initiatorItemId = initiatorItemId
        this.requestDigest = requestDigest
        this.launchDigest = launchDigest
        this.generation = generation
        this.controlEventId = controlEventId
        this.expectedThreadRevision = expectedThreadRevision
        this.epoch = epoch
        this.documentObservation = documentObservation
    }
}

public func continuationRunOriginValue(value: ContinuationRunOrigin): AgentValue {
    let result = objectValue([ValueField("schema", textValue(if (value.documentObservation.isSome()) {
        "axyndra.continuation-run/v2" } else { "axyndra.continuation-run/v1" })),
        ValueField("thread_id", textValue(value.threadId)),
        ValueField("lane_id", textValue(value.laneId)),
        ValueField("namespace", textValue(value.namespace)),
        ValueField("document_key", textValue(value.documentKey)),
        ValueField("allowance_id", textValue(value.allowanceId)),
        ValueField("control_payload_digest", textValue(value.controlPayloadDigest)),
        ValueField("control_source_digest", textValue(value.controlSourceDigest)),
        ValueField("previous_run_id", textValue(value.previousRunId)),
        ValueField("run_id", textValue(value.runId)),
        ValueField("turn_id", textValue(value.turnId)),
        ValueField("initiator_item_id", textValue(value.initiatorItemId)),
        ValueField("request_digest", textValue(value.requestDigest)),
        ValueField("launch_digest", textValue(value.launchDigest)),
        ValueField("generation", integerValue(value.generation)),
        ValueField("control_event_id", integerValue(value.controlEventId)),
        ValueField("expected_thread_revision", integerValue(value.expectedThreadRevision)),
        ValueField("epoch", integerValue(value.epoch))])
    match (value.documentObservation) { case Some(observation) => result.put("document_observation", observation.value()); case None => () }
    result
}
public func continuationRunOriginFromValue(value: AgentValue): ContinuationRunOrigin {
    let version = httpIntentText(value, "schema")
    let legacy = version == "axyndra.continuation-run/v1" && httpIntentExactFields(value, ["schema", "thread_id", "lane_id", "namespace", "document_key", "allowance_id", "control_payload_digest", "control_source_digest", "previous_run_id", "run_id", "turn_id", "initiator_item_id", "request_digest", "launch_digest", "generation", "control_event_id", "expected_thread_revision", "epoch"])
    let observed = version == "axyndra.continuation-run/v2" && httpIntentExactFields(value, ["schema", "thread_id", "lane_id", "namespace", "document_key", "allowance_id", "control_payload_digest", "control_source_digest", "previous_run_id", "run_id", "turn_id", "initiator_item_id", "request_digest", "launch_digest", "generation", "control_event_id", "expected_thread_revision", "epoch", "document_observation"])
    if (!legacy && !observed) { throw IllegalArgumentException("unsupported continuation origin") }
    ContinuationRunOrigin(httpIntentText(value, "thread_id"),
        httpIntentText(value, "lane_id"),
        httpIntentText(value, "namespace"),
        httpIntentText(value, "document_key"),
        httpIntentText(value, "allowance_id"),
        httpIntentText(value, "control_payload_digest"),
        httpIntentText(value, "control_source_digest"),
        httpIntentText(value, "previous_run_id"),
        httpIntentText(value, "run_id"),
        httpIntentText(value, "turn_id"),
        httpIntentText(value, "initiator_item_id"),
        httpIntentText(value, "request_digest"),
        httpIntentText(value, "launch_digest"),
        continuationOriginInteger(value, "generation"),
        continuationOriginInteger(value, "control_event_id"),
        continuationOriginInteger(value, "expected_thread_revision"),
        continuationOriginInteger(value, "epoch"), documentObservation: if (observed) {
            Some(ContinuationDocumentObservation(value.field("document_observation").getOrThrow())) } else { None })
}
func continuationOriginInteger(value: AgentValue, key: String): Int64 {
    let field = value.field(key).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("continuation sequence must be an integer") }
    Int64.parse(field.asNumberText())
}
func continuationOriginDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) { if (!(byte >= 48 && byte <= 57) && !(byte >= 97 && byte <= 102)) { return false } }
    true
}
public func sameContinuationRunOrigin(left: ContinuationRunOrigin, right: ContinuationRunOrigin): Bool {
    canonicalAgentValue(continuationRunOriginValue(left)) == canonicalAgentValue(continuationRunOriginValue(right))
}
public func continuationRunLaunchDigest(lane: AgentValue, context: AgentValue, budget: AgentValue): String {
    modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("lane", lane),
        ValueField("context", context), ValueField("budget", budget)])))
}
// This predicate permits displaying historical/copied Items, never execution.
public func isContinuationInitiatorDescription(item: ThreadItem): Bool {
    item.kind == ItemKind.SystemNote && item.provenance.source == "continuation" &&
        item.provenance.continuationOrigin.isSome() && item.provenance.runId.isSome() &&
        item.provenance.operationId.isNone() && item.provenance.directOrigin.isNone() &&
        match (item.content) { case ThreadItemContent.SystemNote(text) => text == "Host continuation"; case _ => false }
}
