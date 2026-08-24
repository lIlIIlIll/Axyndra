package agent_domain

import json4cj.*
import std.deriving.*

public class ThreadId {
    public let value: String

    public init(value: String) {
        this.value = validatedIdentifier("thread", value)
    }
}

public class ItemId {
    public let value: String

    public init(value: String) {
        this.value = validatedIdentifier("item", value)
    }
}

public class SemanticTurnId {
    public let value: String

    public init(value: String) {
        this.value = validatedIdentifier("semantic turn", value)
    }
}

public class CanonicalToolCallId {
    public let value: String

    public init(value: String) {
        this.value = validatedIdentifier("canonical tool call", value)
    }
}

@Derive[Equatable]
public enum ThreadStatus {
    Open | Closed
}

@Derive[Equatable]
public enum TurnState {
    Active | Completed | Cancelled | Failed | Superseded
}

@Derive[Equatable]
public enum ItemKind {
    UserMessage
    | AssistantMessage
    | ToolCall
    | ToolResult
    | ReasoningReference
    | ProviderOpaqueItem
    | ArtifactReference
    | SystemNote
}

@Derive[Equatable]
public enum ThreadImageSourceKind {
    Url | Base64 | Artifact
}

public class ThreadImage {
    public let sourceKind: ThreadImageSourceKind
    public let data: String
    public let mediaType: String

    public init(
        sourceKind: ThreadImageSourceKind,
        data: String,
        mediaType!: String = ""
    ) {
        if (data.trimAscii() == "") {
            throw IllegalArgumentException("thread image data must not be empty")
        }
        if (sourceKind == ThreadImageSourceKind.Base64 && mediaType.trimAscii() == "") {
            throw IllegalArgumentException("base64 thread image requires a media type")
        }
        this.sourceKind = sourceKind
        this.data = data
        this.mediaType = mediaType.trimAscii()
    }
}

public enum ThreadMessagePart {
    Text(String) | Image(ThreadImage) | Refusal(String)
}

public func validateThreadMessageParts(parts: Array<ThreadMessagePart>): Unit {
    if (parts.isEmpty()) {
        throw IllegalArgumentException("message Item requires at least one part")
    }
    for (part in parts) {
        match (part) {
            case ThreadMessagePart.Text(value) =>
                if (value == "") {
                    throw IllegalArgumentException("message text part must not be empty")
                }
            case ThreadMessagePart.Refusal(value) =>
                if (value == "") {
                    throw IllegalArgumentException("message text part must not be empty")
                }
            case ThreadMessagePart.Image(_) => ()
        }
    }
}

public func textMessageParts(value: String): Array<ThreadMessagePart> {
    [ThreadMessagePart.Text(value)]
}

public enum ThreadItemContent {
    UserMessage(Array<ThreadMessagePart>)
    | AssistantMessage(Array<ThreadMessagePart>)
    | ToolCall(CanonicalToolCallId, String, AgentValue)
    | ToolResult(CanonicalToolCallId, OperationId, String, AgentValue, Bool)
    | ReasoningReference(String, String)
    | ProviderOpaqueItem(OpaqueProviderState)
    | ArtifactReference(String, String, Int64)
    | SystemNote(String)
}

public func threadItemKind(content: ThreadItemContent): ItemKind {
    match (content) {
        case ThreadItemContent.UserMessage(_) => ItemKind.UserMessage
        case ThreadItemContent.AssistantMessage(_) => ItemKind.AssistantMessage
        case ThreadItemContent.ToolCall(_, _, _) => ItemKind.ToolCall
        case ThreadItemContent.ToolResult(_, _, _, _, _) => ItemKind.ToolResult
        case ThreadItemContent.ReasoningReference(_, _) => ItemKind.ReasoningReference
        case ThreadItemContent.ProviderOpaqueItem(_) => ItemKind.ProviderOpaqueItem
        case ThreadItemContent.ArtifactReference(_, _, _) => ItemKind.ArtifactReference
        case ThreadItemContent.SystemNote(_) => ItemKind.SystemNote
    }
}

public func validateThreadItemContent(content: ThreadItemContent): Unit {
    match (content) {
        case ThreadItemContent.UserMessage(parts) => validateThreadMessageParts(parts)
        case ThreadItemContent.AssistantMessage(parts) => validateThreadMessageParts(parts)
        case ThreadItemContent.ToolCall(_, name, arguments) =>
            if (name.trimAscii() == "" || arguments.kind != ValueKind.Object) {
                throw IllegalArgumentException(
                    "tool-call Item requires a name and object arguments"
                )
            }
        case ThreadItemContent.ToolResult(_, _, receiptId, _, _) =>
            if (receiptId.trimAscii() == "") {
                throw IllegalArgumentException("tool-result Item requires a receipt id")
            }
        case ThreadItemContent.ArtifactReference(hash, mimeType, size) =>
            if (hash.trimAscii() == "" || mimeType.trimAscii() == "" || size < 0) {
                throw IllegalArgumentException(
                    "artifact reference requires hash, mime type and non-negative size"
                )
            }
        case ThreadItemContent.SystemNote(value) =>
            if (value.trimAscii() == "") {
                throw IllegalArgumentException("system note must not be empty")
            }
        case ThreadItemContent.ReasoningReference(referenceId, summary) =>
            if (referenceId.trimAscii() == "" || summary.trimAscii() == "") {
                throw IllegalArgumentException(
                    "reasoning reference requires an id and safe summary"
                )
            }
        case _ => ()
    }
}

public func validateThreadItemProvenance(
    content: ThreadItemContent,
    provenance: ItemProvenance
): Unit {
    match (content) {
        case ThreadItemContent.ToolResult(_, operationId, _, _, _) =>
            match (provenance.operationId) {
                case Some(value) =>
                    if (value.value != operationId.value) {
                        throw IllegalArgumentException(
                            "tool-result provenance operation does not match its content"
                        )
                    }
                case None => throw IllegalArgumentException(
                    "tool-result Item requires operation provenance"
                )
            }
        case _ =>
            if (provenance.operationId.isSome()) {
                throw IllegalArgumentException(
                    "only a tool-result Item may carry operation provenance"
                )
            }
    }
}

public class ThreadRecord {
    public let id: ThreadId
    public let revision: Int64
    public let workspaceId: String
    public let status: ThreadStatus
    public let nextItemOrdinal: Int64
    public let activeTurnId: ?SemanticTurnId

    public init(
        id: ThreadId,
        revision: Int64,
        workspaceId: String,
        status: ThreadStatus,
        nextItemOrdinal: Int64,
        activeTurnId!: ?SemanticTurnId = None
    ) {
        if (revision < 0) {
            throw IllegalArgumentException("thread revision must not be negative")
        }
        if (workspaceId.trimAscii() == "") {
            throw IllegalArgumentException("thread workspace id must not be empty")
        }
        if (nextItemOrdinal < 1) {
            throw IllegalArgumentException("thread next item ordinal must be positive")
        }
        this.id = id
        this.revision = revision
        this.workspaceId = workspaceId.trimAscii()
        this.status = status
        this.nextItemOrdinal = nextItemOrdinal
        this.activeTurnId = activeTurnId
    }
}

public class TurnRecord {
    public let id: SemanticTurnId
    public let threadId: ThreadId
    public let ordinal: Int64
    public let state: TurnState
    public let userItemId: ItemId
    public let activeRunId: ?RunId

    public init(
        id: SemanticTurnId,
        threadId: ThreadId,
        ordinal: Int64,
        state: TurnState,
        userItemId: ItemId,
        activeRunId!: ?RunId = None
    ) {
        if (ordinal < 1) {
            throw IllegalArgumentException("turn ordinal must be positive")
        }
        this.id = id
        this.threadId = threadId
        this.ordinal = ordinal
        this.state = state
        this.userItemId = userItemId
        this.activeRunId = activeRunId
    }
}

public class ItemProvenance {
    public let source: String
    public let runId: ?RunId
    public let operationId: ?OperationId

    public init(
        source: String,
        runId!: ?RunId = None,
        operationId!: ?OperationId = None
    ) {
        if (source.trimAscii() == "") {
            throw IllegalArgumentException("item provenance source must not be empty")
        }
        this.source = source.trimAscii()
        this.runId = runId
        this.operationId = operationId
    }
}

public class ThreadItem {
    public let id: ItemId
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let ordinal: Int64
    public let kind: ItemKind
    public let content: ThreadItemContent
    public let provenance: ItemProvenance
    public let createdAtMillis: Int64

    public init(
        id: ItemId,
        threadId: ThreadId,
        turnId: SemanticTurnId,
        ordinal: Int64,
        content: ThreadItemContent,
        provenance: ItemProvenance,
        createdAtMillis!: Int64 = 0
    ) {
        if (ordinal < 1) {
            throw IllegalArgumentException("item ordinal must be positive")
        }
        if (createdAtMillis < 0) {
            throw IllegalArgumentException("item timestamp must not be negative")
        }
        validateThreadItemContent(content)
        validateThreadItemProvenance(content, provenance)
        this.id = id
        this.threadId = threadId
        this.turnId = turnId
        this.ordinal = ordinal
        this.kind = threadItemKind(content)
        this.content = content
        this.provenance = provenance
        this.createdAtMillis = createdAtMillis
    }
}

// Immutable canonical page. Items are presented in ascending transcript order;
// nextBeforeOrdinal is a stable cursor for loading the preceding page.
public class ThreadItemsPage {
    public let threadId: ThreadId
    public let threadRevision: Int64
    public let requestedBeforeOrdinal: Int64
    public let nextBeforeOrdinal: Int64
    public let hasMore: Bool
    public let items: Array<ThreadItem>

    public init(
        threadId: ThreadId,
        threadRevision: Int64,
        requestedBeforeOrdinal: Int64,
        nextBeforeOrdinal: Int64,
        hasMore: Bool,
        items: Array<ThreadItem>
    ) {
        if (threadRevision < 0 || requestedBeforeOrdinal < 0 || nextBeforeOrdinal < 0) {
            throw IllegalArgumentException("Thread page revision and cursors must not be negative")
        }
        var previous: Int64 = 0
        for (item in items) {
            if (item.threadId.value != threadId.value || item.ordinal <= previous ||
                (requestedBeforeOrdinal > 0 && item.ordinal >= requestedBeforeOrdinal)) {
                throw IllegalArgumentException("Thread page Items violate scope or cursor order")
            }
            previous = item.ordinal
        }
        if (items.isEmpty()) {
            if (hasMore || nextBeforeOrdinal != 0) {
                throw IllegalArgumentException("empty Thread page cannot advertise another cursor")
            }
        } else if (nextBeforeOrdinal != items[0].ordinal ||
            (hasMore && nextBeforeOrdinal <= 1)) {
            throw IllegalArgumentException("Thread page next cursor is inconsistent")
        }
        this.threadId = threadId
        this.threadRevision = threadRevision
        this.requestedBeforeOrdinal = requestedBeforeOrdinal
        this.nextBeforeOrdinal = nextBeforeOrdinal
        this.hasMore = hasMore
        this.items = items
    }
}

public class AgentThreadSnapshot {
    public let thread: ThreadRecord
    public let turns: Array<TurnRecord>
    public let items: Array<ThreadItem>
    public let activeRunId: ?RunId
    public let activeEpoch: Int64
    public let nextResultSequence: Int64

    public init(
        thread: ThreadRecord,
        turns: Array<TurnRecord>,
        items: Array<ThreadItem>,
        activeRunId!: ?RunId = None,
        activeEpoch!: Int64 = 0,
        nextResultSequence!: Int64 = 1
    ) {
        if (activeEpoch < 0) {
            throw IllegalArgumentException("thread epoch must not be negative")
        }
        if (nextResultSequence < 1) {
            throw IllegalArgumentException("result sequence must be positive")
        }
        this.thread = thread
        this.turns = turns
        this.items = items
        this.activeRunId = activeRunId
        this.activeEpoch = activeEpoch
        this.nextResultSequence = nextResultSequence
    }
}
