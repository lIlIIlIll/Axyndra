package agent_runtime

import agent_domain.*
import std.collection.*
import std.overflow.*
import yjson.*
import yjson_support.*

// An estimator that might retain an item must retain this actual custody.
// Ordinary/custom estimators do not acquire this contract implicitly.
public interface OwnedThreadTokenEstimator {
    func estimateOwnedItem(item: ThreadItem, custody: OwnedCanonicalThreadItemCustody): Result<Int64>
}

// Complete selected history remains in its actual ordered Store readback.
// This projection does not turn a large corpus into a recentItems DOM array.
public class OwnedModelContextProjection {
    public let threadRevision: Int64
    public let checkpoint: ?ContextCheckpoint
    public let dynamicState: AgentValue
    public let estimatedInputTokens: Int64
    public let overBudget: Bool
    private let thread: ThreadId
    private let readback: OwnedCanonicalThreadReadback
    private let covered: Int64
    private let guard: () -> Result<Unit>
    init(thread: ThreadId, revision: Int64, readback: OwnedCanonicalThreadReadback, covered: Int64,
        checkpoint: ?ContextCheckpoint, dynamicState: AgentValue, estimated: Int64, overBudget: Bool,
        guard: () -> Result<Unit>) {
        this.thread = thread; this.threadRevision = revision; this.readback = readback; this.covered = covered
        this.checkpoint = checkpoint; this.dynamicState = dynamicState; this.estimatedInputTokens = estimated
        this.overBudget = overBudget; this.guard = guard
    }
    public func visitRecent(consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        readback.visit(thread, threadRevision, covered, guard, consume)
    }
}

func ownedProjectionAdd(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > Int64.Max - left) {
        throw IllegalStateException("canonical context framing extent overflow") }
    left + right
}

// Exact original contextFrame/contextContent bytes, consumed without their
// full String or full prefix String. This hash remains a staleness guard,
// never an input supplied by a worker and never Source/approval authority.
class OwnedContextByteWriter {
    var bytes: Int64 = 0
    var hash: UInt64 = 1469598103934665603
    var seen: Int64 = 0
    private let hashing: Bool
    init(hashing: Bool) { this.hashing = hashing }
    func text(value: String): Unit {
        bytes = ownedProjectionAdd(bytes, value.size)
        if (hashing) { for (byte in unsafe { value.rawData() }) {
            hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211) } }
    }
    func prefix(length: Int64): Unit { text(length.toString()); text(":") }
    func frame(value: String): Unit { prefix(value.size); text(value) }
    func value(value: AgentValue): Unit {
        match (value.unifiedKind) {
            case ValueKind.Null => text("n")
            case ValueKind.Boolean => text(if (value.asBool()) { "t" } else { "f" })
            case ValueKind.Number => text("d"); frame(value.asNumberText())
            case ValueKind.Text => text("s"); frame(value.text)
            case ValueKind.List => text("l"); frame(value.items.size.toString())
                for (child in value.items) { this.value(child) }
            case ValueKind.Object => text("o"); frame(value.fields.size.toString())
                for (field in value.fields) { frame(field.name); this.value(field.value) }
        }
    }
    func parts(parts: Array<ThreadMessagePart>): Unit {
        frame(parts.size.toString())
        for (part in parts) { match (part) {
            case ThreadMessagePart.Text(value) => text("text"); frame(value)
            case ThreadMessagePart.Refusal(value) => text("refusal"); frame(value)
            case ThreadMessagePart.Image(image) => text("image")
                frame(match (image.sourceKind) {
                    case ThreadImageSourceKind.Url => "url"
                    case ThreadImageSourceKind.Base64 => "base64"
                    case ThreadImageSourceKind.Artifact => "artifact" })
                frame(image.data); frame(image.mediaType) } }
    }
    func content(content: ThreadItemContent): Unit {
        match (content) {
            case ThreadItemContent.UserMessage(parts) => text("user"); this.parts(parts)
            case ThreadItemContent.AssistantMessage(parts) => text("assistant"); this.parts(parts)
            case ThreadItemContent.ToolCall(call, name, value) => text("call"); frame(call.value); frame(name); this.value(value)
            case ThreadItemContent.ToolResult(call, operation, receipt, value, error) =>
                text("result"); frame(call.value); frame(operation.value); frame(receipt); this.value(value); text(if (error) { "t" } else { "f" })
            case ThreadItemContent.ReasoningReference(reference, summary) => text("reasoning"); frame(reference); frame(summary)
            case ThreadItemContent.ProviderOpaqueItem(state) => text("opaque"); frame(state.providerId); frame(state.protocol)
                frame(state.itemId); frame(state.payload); text(if (state.replayRequired) { "t" } else { "f" })
            case ThreadItemContent.ArtifactReference(hash, mime, size) => text("artifact"); frame(hash); frame(mime); frame(size.toString())
            case ThreadItemContent.SystemNote(value) => text("system"); frame(value)
        }
    }
    // The original provenance additions use canonicalAgentValue rather than
    // contextValue. Preserve its sorted-field order and nested child frames.
    func canonical(value: AgentValue): Unit {
        match (value.unifiedKind) {
            case ValueKind.Null => text("null")
            case ValueKind.Boolean => text(if (value.asBool()) { "true" } else { "false" })
            case ValueKind.Number => text("n"); frame(value.asNumberText())
            case ValueKind.Text => text("s"); frame(value.text)
            case ValueKind.List => text("[")
                for (child in value.items) { canonicalFrame(child) }; text("]")
            case ValueKind.Object => text("{")
                let used = Array<Bool>(value.fields.size, repeat: false)
                for (_ in 0..value.fields.size) {
                    var selected: Int64 = -1
                    for (at in 0..value.fields.size where !used[at]) {
                        if (selected < 0 || value.fields[at].name < value.fields[selected].name) { selected = at } }
                    used[selected] = true; frame(value.fields[selected].name); canonicalFrame(value.fields[selected].value)
                }
                text("}")
        }
    }
    func canonicalFrame(value: AgentValue): Unit {
        let measure = OwnedContextByteWriter(false); measure.canonical(value)
        prefix(measure.bytes); canonical(value)
    }
    func item(item: ThreadItem): Unit {
        frame(item.id.value); frame(item.turnId.value); frame(item.ordinal.toString())
        let measure = OwnedContextByteWriter(false); measure.content(item.content)
        prefix(measure.bytes); content(item.content)
        frame(item.provenance.source)
        frame(match (item.provenance.runId) { case Some(value) => value.value; case None => "" })
        frame(match (item.provenance.operationId) { case Some(value) => value.value; case None => "" })
        frame(item.createdAtMillis.toString())
        match (item.provenance.continuationOrigin) {
            case Some(origin) => canonicalFrame(continuationRunOriginValue(origin)); case None => () }
        match (item.provenance.continuationHistory) {
            case Some(history) => canonicalFrame(continuationHistorySourceValue(history)); case None => () }
        match(item.provenance.completedInitiatorHistory173e){
            case Some(history)=>canonicalFrame(completedInitiatorHistoryValue173e(history));case None=>()}
    }
}

public func ownedContextSourceDigest(thread: ThreadRecord, readback: OwnedCanonicalThreadReadback,
    cover: Int64, guard: () -> Result<Unit>): Result<String> {
    if (cover < 1 || cover >= thread.nextItemOrdinal) {
        return projectionError("context.checkpoint_cover_invalid", "context source digest cover is outside canonical history") }
    try {
        let writer = OwnedContextByteWriter(true); writer.frame(thread.id.value); writer.frame(cover.toString())
        match (readback.visit(thread.id, thread.revision, 0, guard, { item, _ =>
            if (item.ordinal <= cover) { writer.item(item); writer.seen++ }; Result.Ok(()) })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (writer.seen != cover) { throw IllegalStateException("canonical Thread prefix is not ordinal-complete") }
        Result.Ok("fnv1a64-v1:" + writer.hash.toString())
    } catch (error: Exception) { projectionError("context.source_digest_failed", error.message) }
}

class OwnedContextProjectionCounters {
    var pendingBytes: Int64 = 0
    var estimated: Int64 = 0
    init(estimated: Int64) { this.estimated = estimated }
}

func projectOwnedContext(version: String, estimator: ThreadTokenEstimator,
    thread: ThreadRecord, readback: OwnedCanonicalThreadReadback, lane: ModelLane,
    checkpoint: ?ContextCheckpoint, dynamicState: AgentValue,
    allocate: (Int64) -> LogicalJsonOwnerReservation, guard: () -> Result<Unit>): Result<OwnedModelContextProjection> {
    let actual = match (estimator as OwnedThreadTokenEstimator) {
        case Some(value) => value
        case None => return projectionError("context.estimator_owned_contract_missing", "context estimator has no actual item custody contract") }
    var metadata: ?LogicalJsonOwnerReservation = None
    let pending = ArrayList<String>()
    try {
        var compatible: ?ContextCheckpoint = None
        match (checkpoint) {
            case Some(value) =>
                if (value.threadId.value != thread.id.value) {
                    return projectionError("context.checkpoint_wrong_thread", "context checkpoint belongs to another thread") }
                if (value.coversThroughItemOrdinal >= thread.nextItemOrdinal) {
                    return projectionError("context.checkpoint_cover_invalid", "context checkpoint covers items outside canonical history") }
                if (value.projectorVersion == version && value.laneCompatibility == lane.protocol) {
                    let digest = match (ownedContextSourceDigest(thread, readback, value.coversThroughItemOrdinal, guard)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(text) => text }
                    if (digest == value.sourceDigest) { compatible = Some(value) }
                }
            case None => () }
        let covered = match (compatible) { case Some(value) => value.coversThroughItemOrdinal; case None => 0 }
        let owner = allocate(65536); metadata = Some(owner)
        let counters = OwnedContextProjectionCounters(lane.estimateSystemInstructions159(estimator) +
            lane.estimateToolSet159(estimator) + estimator.estimateDynamicState(dynamicState))
        match (compatible) { case Some(value) => counters.estimated += estimator.estimateCheckpoint(value); case None => () }
        let validation = readback.visit(thread.id, thread.revision, 0, guard, { item, custody =>
            match (item.content) {
                case ThreadItemContent.ToolCall(call, _, _) =>
                    if (containsPending(pending, call.value)) {
                        return Result.Err(toolPairError("duplicate canonical tool-call id").getOrThrow()) }
                    let wanted = ownedProjectionAdd(counters.pendingBytes, call.value.size)
                    if (wanted > Int64.Max / 8 || pending.size > (Int64.Max - 8192) / 256) {
                        throw IllegalStateException("canonical tool-pair metadata payment overflow") }
                    owner.ensureRetainedPeak(ownedProjectionAdd(8192,
                        ownedProjectionAdd(wanted * 8, (pending.size + 1) * 256)))
                    // A real copied identifier, not a retained whole call DOM.
                    // Its original row and this index are simultaneously paid.
                    pending.add(String.fromUtf8(call.value.toArray())); counters.pendingBytes = wanted
                case ThreadItemContent.ToolResult(call, _, _, _, _) =>
                    let at = pendingIndex(pending, call.value)
                    if (at < 0) { return Result.Err(toolPairError("tool result has no preceding canonical tool call").getOrThrow()) }
                    counters.pendingBytes -= pending[at].size; pending.remove(at: at)
                case _ => if (!pending.isEmpty()) {
                    return Result.Err(toolPairError("canonical tool round is split by another semantic Item").getOrThrow()) } }
            if (item.ordinal == covered && !pending.isEmpty()) {
                return projectionError("context.checkpoint_splits_tool_round", "context checkpoint cannot split a canonical tool call/result round") }
            if (item.ordinal > covered) { match (actual.estimateOwnedItem(item, custody)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(tokens) => counters.estimated += tokens } }
            Result.Ok(())
        })
        // This copied header index ends before its actual metadata owner.
        let incomplete = !pending.isEmpty(); pending.clear()
        match (validation) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (incomplete) {
            return Result.Err(toolPairError("canonical history ends with an incomplete tool round").getOrThrow()) }
        if (counters.estimated < 0) {
            return projectionError("context.estimator_negative", "context estimator returned a negative token count") }
        Result.Ok(OwnedModelContextProjection(thread.id, thread.revision, readback, covered,
            compatible, dynamicState, counters.estimated,
            counters.estimated + lane.outputReserve + lane.providerSafetyMargin > lane.contextWindow, guard))
    } catch (error: Exception) { projectionError("context.owned_projection_failed", error.message) }
    finally { pending.clear(); match (metadata) { case Some(owner) => owner.close(); case None => () } }
}
