package agent_tui

import std.collection.*
import std.deriving.*
import std.time.*

@Derive[Equatable]
public enum UiCardKind {
    User
    | Assistant
    | Reasoning
    | Tool
    | Approval
    | Permission
    | Ask
    | Plan
    | Subagent
    | Advisor
    | Reviewer
    | Job
    | Warning
    | Compaction
    | Summary
    | Error
    | Steer
    | Setup
    | Mcp
}

// Keep the external/card-id vocabulary independent from the enum's derived
// representation.  These values intentionally match the legacy string kinds.
public func uiCardKindName(kind: UiCardKind): String {
    match (kind) {
        case UiCardKind.User => "user"
        case UiCardKind.Assistant => "assistant"
        case UiCardKind.Reasoning => "reasoning"
        case UiCardKind.Tool => "tool"
        case UiCardKind.Approval => "approval"
        case UiCardKind.Permission => "permission"
        case UiCardKind.Ask => "ask"
        case UiCardKind.Plan => "plan"
        case UiCardKind.Subagent => "subagent"
        case UiCardKind.Advisor => "advisor"
        case UiCardKind.Reviewer => "reviewer"
        case UiCardKind.Job => "job"
        case UiCardKind.Warning => "warning"
        case UiCardKind.Compaction => "compaction"
        case UiCardKind.Summary => "summary"
        case UiCardKind.Error => "error"
        case UiCardKind.Steer => "steer"
        case UiCardKind.Setup => "setup"
        case UiCardKind.Mcp => "mcp"
    }
}

// Product-facing events are deliberately independent from cjtui widgets.
// The same reducer can therefore drive the terminal, headless tests and replay.
public enum UiEvent {
    AppendText(String, UiCardKind, String, String)
    | RemoveAttempt(String)
    | CommitAttempt(String)
    | UpsertCard(String, UiCardKind, String, String, String, Bool, String)
    | AppendToolOutput(String, String)
    | ReplaceToolOutput(String, String, Bool)
    | SetToolMetadata(String, String, String, String, String)
    | SetToolStartedAt(String, MonoTime)
    | SetToolElapsed(String, Int64)
    | SetCardState(String, String, String, Bool)
    | SetStatus(String)
    | SetWorking(Bool)
    | SetUsage(Int64, Int64)
    | AwaitApproval(String)
    | ClearApproval
}

public class UiCard {
    public let id: String
    public var kind: UiCardKind
    public var title: String
    public var body: String
    public var state: String
    public var collapsed: Bool
    public var footer: String
    // Structured tool metadata stays beside the presentation body.  The
    // renderer can therefore produce Read/Search/Edit layouts without
    // putting raw argument JSON in the visible transcript.
    public var toolName: String
    public var toolArguments: String
    public var toolCallId: String
    // Streaming output is retained in arrival order, including SGR styling.
    // The final structured result is separate so completion cannot overwrite
    // the stream order already observed by the UI.
    public var toolOutput: String
    public var toolOutputTruncated: Bool
    public var toolResult: String
    public var toolStartedAt: ?MonoTime
    public var toolElapsedMillis: Int64
    public var collapseTouched: Bool
    // Expanded long-output cards own a small local viewport.  The outer
    // transcript viewport remains independent from this offset.
    public var bodyScroll: Int64
    public var bodyViewport: Int64
    // Rendering consumers use this monotonic value instead of rebuilding a
    // body head/tail signature on every frame.  Reducer mutations advance it;
    // view-only changes (collapse and local scrolling) also advance it so
    // the virtual transcript can invalidate just this entry.
    public var contentRevision: Int64
    public var renderRevision: Int64
    // Streaming layout may reuse rows only while the body is extended by
    // appendBody().  Any other content mutation advances this epoch, forcing
    // a full rebuild without comparing the complete previous String.
    public var bodyRewriteEpoch: Int64
    private var bodyLineCountRevision: Int64
    private var cachedBodyLineCount: Int64

    public init(
        id: String,
        kind: UiCardKind,
        title: String,
        body: String,
        state!: String = "",
        collapsed!: Bool = false,
        footer!: String = ""
    ) {
        this.id = id
        this.kind = kind
        this.title = title
        this.body = body
        this.state = state
        this.collapsed = collapsed
        this.footer = footer
        this.toolName = ""
        this.toolArguments = ""
        this.toolCallId = ""
        this.toolOutput = ""
        this.toolOutputTruncated = false
        this.toolResult = ""
        this.toolStartedAt = None
        this.toolElapsedMillis = 0
        this.collapseTouched = false
        this.bodyScroll = 0
        this.bodyViewport = 0
        this.contentRevision = 0
        this.renderRevision = 0
        this.bodyRewriteEpoch = 0
        this.bodyLineCountRevision = -1
        this.cachedBodyLineCount = 1
    }

    public func appendBody(text: String): Unit {
        if (text == "") { return }
        body += text
        bumpContentRevision()
    }

    public func markContentChanged(): Unit {
        bodyRewriteEpoch++
        bumpContentRevision()
    }

    private func bumpContentRevision(): Unit {
        contentRevision++
        renderRevision++
        bodyLineCountRevision = -1
    }

    public func markViewChanged(): Unit {
        renderRevision++
    }

    public func bodyLines(): Int64 {
        if (bodyLineCountRevision != contentRevision) {
            cachedBodyLineCount = max(1, body.split("\n").size)
            bodyLineCountRevision = contentRevision
        }
        cachedBodyLineCount
    }
}

public class UiSnapshot {
    public let cards = ArrayList<UiCard>()
    // Reducer streams normally update the same tail card many times.  Cache
    // its verified index so repeated deltas do not scan and allocate an
    // iterator over the complete transcript.  Direct list mutations remain
    // safe because every hit is checked against the current list entry.
    var cardLookupId = ""
    var cardLookupIndex: Int64 = -1
    public var status = "ready"
    public var working = false
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var approvalId: ?String = None
}

public class UiReducer {
    public static func reduce(
        snapshot: UiSnapshot,
        event: UiEvent
    ): Unit {
        match (event) {
            case UiEvent.RemoveAttempt(attemptId) =>
                let prefix = "attempt-" + attemptId + "-"
                let toolPrefix = attemptId + "::"
                var index: Int64 = 0
                while (index < snapshot.cards.size) {
                    let card = snapshot.cards[index]
                    if (card.id.startsWith(prefix) || card.toolCallId.startsWith(toolPrefix)) {
                        snapshot.cards.remove(at: index)
                    } else { index++ }
                }
                snapshot.cardLookupId = ""
                snapshot.cardLookupIndex = -1
            case UiEvent.CommitAttempt(attemptId) =>
                let prefix = "attempt-" + attemptId + "-"
                let toolPrefix = attemptId + "::"
                var index: Int64 = 0
                while (index < snapshot.cards.size) {
                    let card = snapshot.cards[index]
                    if (card.toolCallId.startsWith(toolPrefix)) {
                        snapshot.cards.remove(at: index)
                    } else {
                        if (card.id.startsWith(prefix)) {
                            card.state = "completed"
                            card.markContentChanged()
                        }
                        index++
                    }
                }
                snapshot.cardLookupId = ""
                snapshot.cardLookupIndex = -1
            case UiEvent.AppendText(id, kind, title, text) =>
                if (text == "") { return }
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        if (uiStateAllowsTransition(card.state, "streaming")) {
                            card.state = "streaming"
                        }
                        card.appendBody(text)
                    case None =>
                        snapshot.cards.add(UiCard(
                            id,
                            kind,
                            title,
                            text,
                            state: "streaming",
                            // Reasoning streams expanded so the thinking text
                            // is visible while it is being produced; the turn
                            // completion handler collapses it afterwards.
                            collapsed: false
                        ))
                }
            case UiEvent.UpsertCard(
                id,
                kind,
                title,
                body,
                state,
                collapsed,
                footer
            ) =>
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        card.kind = kind
                        card.title = title
                        card.body = body
                        if (uiStateAllowsTransition(card.state, state)) {
                            card.state = state
                        }
                        if (!card.collapseTouched) {
                            card.collapsed = collapsed
                        }
                        card.footer = footer
                        card.markContentChanged()
                    case None =>
                        snapshot.cards.add(UiCard(
                            id,
                            kind,
                            title,
                            body,
                            state: state,
                            collapsed: collapsed,
                            footer: footer
                        ))
                }
            case UiEvent.AppendToolOutput(id, chunk) =>
                if (chunk == "") { return }
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        if (!card.toolOutputTruncated) {
                            let preview = boundedTerminalPreview(card.toolOutput + chunk)
                            card.toolOutput = preview.text
                            card.toolOutputTruncated = preview.truncated
                            card.markContentChanged()
                        }
                        if (uiStateAllowsTransition(card.state, "running")) {
                            card.state = "running"
                        }
                    case None => ()
                }
            case UiEvent.ReplaceToolOutput(id, preview, truncated) =>
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        card.toolOutput = preview
                        card.toolOutputTruncated = truncated
                        card.markContentChanged()
                    case None => ()
                }
            case UiEvent.SetToolMetadata(id, name, arguments, callId, output) =>
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        card.toolName = name
                        card.toolArguments = arguments
                        card.toolCallId = callId
                        card.toolResult = output
                        card.markContentChanged()
                    case None => ()
                }
            case UiEvent.SetToolStartedAt(id, startedAt) =>
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        card.toolStartedAt = Some(startedAt)
                        card.markViewChanged()
                    case None => ()
                }
            case UiEvent.SetToolElapsed(id, elapsedMillis) =>
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        card.toolElapsedMillis = max(0, elapsedMillis)
                        card.markViewChanged()
                    case None => ()
                }
            case UiEvent.SetCardState(id, state, body, collapsed) =>
                match (findCard(snapshot, id)) {
                    case Some(card) =>
                        if (uiStateAllowsTransition(card.state, state)) {
                            card.state = state
                        }
                        card.body = body
                        if (!card.collapseTouched) {
                            card.collapsed = collapsed
                        }
                        card.markContentChanged()
                    case None => ()
                }
            case UiEvent.SetStatus(value) => snapshot.status = value
            case UiEvent.SetWorking(value) => snapshot.working = value
            case UiEvent.SetUsage(input, output) =>
                snapshot.inputTokens = input
                snapshot.outputTokens = output
            case UiEvent.AwaitApproval(id) =>
                snapshot.approvalId = Some(id)
            case UiEvent.ClearApproval =>
                snapshot.approvalId = None
        }
    }

    private static func findCard(
        snapshot: UiSnapshot,
        id: String
    ): ?UiCard {
        let cached = snapshot.cardLookupIndex
        if (snapshot.cardLookupId == id && cached >= 0 && cached < snapshot.cards.size) {
            let card = snapshot.cards[cached]
            if (card.id == id) { return Some(card) }
        }
        var index: Int64 = 0
        while (index < snapshot.cards.size) {
            let card = snapshot.cards[index]
            if (card.id == id) {
                snapshot.cardLookupId = id
                snapshot.cardLookupIndex = index
                return Some(card)
            }
            index++
        }
        snapshot.cardLookupId = id
        snapshot.cardLookupIndex = -1
        None
    }
}

// One transition rule is shared by every reducer event so a late stream
// chunk or replay upsert cannot resurrect an already-settled card.
func uiStateAllowsTransition(current: String, next: String): Bool {
    if (current == next || current == "") {
        return true
    }
    !isUiTerminalState(current) || isUiTerminalState(next)
}

func isUiTerminalState(value: String): Bool {
    match (value.toAsciiLower()) {
        case "completed" | "failed" | "cancelled" | "canceled" | "denied" | "rejected" | "timed_out" |
            "timeout" | "approved" => true
        case _ => false
    }
}
