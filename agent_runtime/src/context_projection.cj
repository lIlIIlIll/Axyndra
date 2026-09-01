package agent_runtime

import yjson_support.*

import yjson.*

import std.collection.*
import std.overflow.*
import agent_domain.*

public class ContextCheckpoint {
    public let id: String
    public let threadId: ThreadId
    public let coversThroughItemOrdinal: Int64
    public let structuredSummary: AgentValue
    public let sourceDigest: String
    public let projectorVersion: String
    public let laneCompatibility: String
    public let activeState: AgentValue
    public let activeGoal: String
    public let durableNotes: Array<String>
    public let artifactReferences: Array<String>

    public init(
        id: String,
        threadId: ThreadId,
        coversThroughItemOrdinal: Int64,
        structuredSummary: AgentValue,
        sourceDigest: String,
        projectorVersion: String,
        laneCompatibility: String,
        activeState!: AgentValue = objectValue([]),
        activeGoal!: String = "",
        durableNotes!: Array<String> = [],
        artifactReferences!: Array<String> = []
    ) {
        if (id.trimAscii() == "" || coversThroughItemOrdinal < 1 ||
            sourceDigest.trimAscii() == "" || projectorVersion.trimAscii() == "" ||
            laneCompatibility.trimAscii() == "" || structuredSummary.unifiedKind != ValueKind.Object ||
            activeState.unifiedKind != ValueKind.Object) {
            throw IllegalArgumentException("context checkpoint metadata is invalid")
        }
        this.id = id.trimAscii()
        this.threadId = threadId
        this.coversThroughItemOrdinal = coversThroughItemOrdinal
        this.structuredSummary = structuredSummary
        this.sourceDigest = sourceDigest.trimAscii()
        this.projectorVersion = projectorVersion.trimAscii()
        this.laneCompatibility = laneCompatibility.trimAscii()
        this.activeState = activeState
        this.activeGoal = activeGoal
        this.durableNotes = durableNotes
        this.artifactReferences = artifactReferences
    }
}

public interface ContextCheckpointRepository {
    func loadLatest(
        thread: AgentThreadSnapshot,
        projectorVersion: String,
        laneCompatibility: String
    ): ?ContextCheckpoint
}

public interface ThreadTokenEstimator {
    func estimateSystemInstructions(version: String): Int64
    func estimateToolSet(snapshot: ToolSetSnapshot): Int64
    func estimateCheckpoint(checkpoint: ContextCheckpoint): Int64
    func estimateItem(item: ThreadItem): Int64
    func estimateDynamicState(dynamicState: AgentValue): Int64
}

public class ModelContextProjection {
    public let threadRevision: Int64
    public let checkpoint: ?ContextCheckpoint
    public let recentItems: Array<ThreadItem>
    public let dynamicState: AgentValue
    public let estimatedInputTokens: Int64
    public let overBudget: Bool

    public init(
        threadRevision: Int64,
        checkpoint: ?ContextCheckpoint,
        recentItems: Array<ThreadItem>,
        dynamicState: AgentValue,
        estimatedInputTokens: Int64,
        overBudget: Bool
    ) {
        this.threadRevision = threadRevision
        this.checkpoint = checkpoint
        this.recentItems = recentItems
        this.dynamicState = dynamicState
        this.estimatedInputTokens = estimatedInputTokens
        this.overBudget = overBudget
    }
}

public class ContextProjector {
    public let version: String
    private let estimator: ThreadTokenEstimator

    public init(version: String, estimator: ThreadTokenEstimator) {
        if (version.trimAscii() == "") {
            throw IllegalArgumentException("context projector version must not be empty")
        }
        this.version = version.trimAscii()
        this.estimator = estimator
    }

    public func project(
        thread: AgentThreadSnapshot,
        lane: ModelLane,
        checkpoint!: ?ContextCheckpoint = None,
        dynamicState!: AgentValue = objectValue([])
    ): Result<ModelContextProjection> {
        let compatibleCheckpoint: ?ContextCheckpoint = match (checkpoint) {
            case Some(value) =>
                if (value.threadId.value != thread.thread.id.value) {
                    return projectionError(
                        "context.checkpoint_wrong_thread",
                        "context checkpoint belongs to another thread"
                    )
                }
                if (value.coversThroughItemOrdinal >= thread.thread.nextItemOrdinal) {
                    return projectionError(
                        "context.checkpoint_cover_invalid",
                        "context checkpoint covers items outside canonical history"
                    )
                }
                if (value.projectorVersion != version ||
                    value.laneCompatibility != lane.protocol ||
                    value.sourceDigest != contextSourceDigest(
                        thread, value.coversThroughItemOrdinal
                    )) {
                    None
                } else {
                    Some(value)
                }
            case None => None
        }
        let covered = match (compatibleCheckpoint) {
            case Some(value) => value.coversThroughItemOrdinal
            case None => 0
        }
        match (validateCanonicalToolPairs(thread.items, covered)) {
            case Some(error) => return Result.Err(error)
            case None => ()
        }
        let recent = ArrayList<ThreadItem>()
        for (item in thread.items where item.ordinal > covered) { recent.add(item) }
        var estimated = estimator.estimateSystemInstructions(lane.systemInstructionVersion) +
            estimator.estimateToolSet(lane.toolSet) +
            estimator.estimateDynamicState(dynamicState)
        match (compatibleCheckpoint) {
            case Some(value) => estimated += estimator.estimateCheckpoint(value)
            case None => ()
        }
        for (item in recent) { estimated += estimator.estimateItem(item) }
        if (estimated < 0) {
            return projectionError(
                "context.estimator_negative",
                "context estimator returned a negative token count"
            )
        }
        Result.Ok(ModelContextProjection(
            thread.thread.revision,
            compatibleCheckpoint,
            recent.toArray(),
            dynamicState,
            estimated,
            estimated + lane.outputReserve + lane.providerSafetyMargin > lane.contextWindow
        ))
    }
}

// The digest is not a permission primitive. It is a stable corruption/staleness
// guard binding a checkpoint to the exact immutable Thread prefix it summarizes.
public func contextSourceDigest(thread: AgentThreadSnapshot, cover: Int64): String {
    if (cover < 1 || cover >= thread.thread.nextItemOrdinal) {
        throw IllegalArgumentException("context source digest cover is outside canonical history")
    }
    var source = contextFrame(thread.thread.id.value) + contextFrame(cover.toString())
    var seen: Int64 = 0
    for (item in thread.items where item.ordinal <= cover) {
        source += contextFrame(item.id.value) + contextFrame(item.turnId.value) +
            contextFrame(item.ordinal.toString()) + contextFrame(contextContent(item.content)) +
            contextFrame(item.provenance.source) + contextFrame(match (item.provenance.runId) {
                case Some(value) => value.value
                case None => ""
            }) + contextFrame(match (item.provenance.operationId) {
                case Some(value) => value.value
                case None => ""
            }) + contextFrame(item.createdAtMillis.toString())
        seen += 1
    }
    if (seen != cover) {
        throw IllegalStateException("canonical Thread prefix is not ordinal-complete")
    }
    var hash: UInt64 = 1469598103934665603
    for (byte in unsafe { source.rawData() }) {
        hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211)
    }
    "fnv1a64-v1:" + hash.toString()
}

func contextContent(content: ThreadItemContent): String {
    match (content) {
        case ThreadItemContent.UserMessage(parts) => "user" + contextParts(parts)
        case ThreadItemContent.AssistantMessage(parts) => "assistant" + contextParts(parts)
        case ThreadItemContent.ToolCall(callId, name, arguments) =>
            "call" + contextFrame(callId.value) + contextFrame(name) + contextValue(arguments)
        case ThreadItemContent.ToolResult(callId, operationId, receiptId, result, isError) =>
            "result" + contextFrame(callId.value) + contextFrame(operationId.value) +
                contextFrame(receiptId) + contextValue(result) +
                if (isError) { "t" } else { "f" }
        case ThreadItemContent.ReasoningReference(referenceId, summary) =>
            "reasoning" + contextFrame(referenceId) + contextFrame(summary)
        case ThreadItemContent.ProviderOpaqueItem(state) =>
            "opaque" + contextFrame(state.providerId) + contextFrame(state.protocol) +
                contextFrame(state.itemId) + contextFrame(state.payload) +
                if (state.replayRequired) { "t" } else { "f" }
        case ThreadItemContent.ArtifactReference(hash, mime, size) =>
            "artifact" + contextFrame(hash) + contextFrame(mime) + contextFrame(size.toString())
        case ThreadItemContent.SystemNote(value) => "system" + contextFrame(value)
    }
}

func contextParts(parts: Array<ThreadMessagePart>): String {
    var result = contextFrame(parts.size.toString())
    for (part in parts) {
        result += match (part) {
            case ThreadMessagePart.Text(value) => "text" + contextFrame(value)
            case ThreadMessagePart.Refusal(value) => "refusal" + contextFrame(value)
            case ThreadMessagePart.Image(image) =>
                "image" + contextFrame(match (image.sourceKind) {
                    case ThreadImageSourceKind.Url => "url"
                    case ThreadImageSourceKind.Base64 => "base64"
                    case ThreadImageSourceKind.Artifact => "artifact"
                }) + contextFrame(image.data) + contextFrame(image.mediaType)
        }
    }
    result
}

func contextValue(value: AgentValue): String {
    match (value.unifiedKind) {
        case ValueKind.Null => "n"
        case ValueKind.Boolean => if (value.boolean) { "t" } else { "f" }
        case ValueKind.Number => "d" + contextFrame(value.number)
        case ValueKind.Text => "s" + contextFrame(value.text)
        case ValueKind.List =>
            var result = "l" + contextFrame(value.items.size.toString())
            for (item in value.items) { result += contextValue(item) }
            result
        case ValueKind.Object =>
            var result = "o" + contextFrame(value.fields.size.toString())
            for (field in value.fields) {
                result += contextFrame(field.name) + contextValue(field.value)
            }
            result
    }
}

func contextFrame(value: String): String {
    value.toArray().size.toString() + ":" + value
}

func validateCanonicalToolPairs(items: Array<ThreadItem>, checkpointCover: Int64): ?AgentError {
    let pending = ArrayList<String>()
    for (item in items) {
        match (item.content) {
            case ThreadItemContent.ToolCall(callId, _, _) =>
                if (containsPending(pending, callId.value)) {
                    return toolPairError("duplicate canonical tool-call id")
                }
                pending.add(callId.value)
            case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                let index = pendingIndex(pending, callId.value)
                if (index < 0) {
                    return toolPairError("tool result has no preceding canonical tool call")
                }
                pending.remove(at: index)
            case _ =>
                if (!pending.isEmpty()) {
                    return toolPairError("canonical tool round is split by another semantic Item")
                }
        }
        if (item.ordinal == checkpointCover && !pending.isEmpty()) {
            return Some(AgentError(
                AgentErrorKind.InvalidInput,
                "context.checkpoint_splits_tool_round",
                "context checkpoint cannot split a canonical tool call/result round"
            ))
        }
    }
    if (!pending.isEmpty()) {
        return toolPairError("canonical history ends with an incomplete tool round")
    }
    None
}

public func validateContextCheckpointBoundary(
    thread: AgentThreadSnapshot,
    cover: Int64
): Result<Unit> {
    if (cover < 1 || cover >= thread.thread.nextItemOrdinal) {
        return projectionError(
            "context.checkpoint_cover_invalid",
            "context checkpoint covers items outside canonical history"
        )
    }
    match (validateCanonicalToolPairs(thread.items, cover)) {
        case Some(error) => Result.Err(error)
        case None => Result.Ok(())
    }
}

func containsPending(values: ArrayList<String>, value: String): Bool {
    pendingIndex(values, value) >= 0
}

func pendingIndex(values: ArrayList<String>, value: String): Int64 {
    for (index in 0..values.size where values[index] == value) { return index }
    -1
}

func toolPairError(message: String): ?AgentError {
    Some(AgentError(
        AgentErrorKind.InvalidInput,
        "context.canonical_tool_protocol_incomplete",
        message
    ))
}

func projectionError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
