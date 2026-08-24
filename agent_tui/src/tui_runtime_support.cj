package agent_tui

import agent_cli.*
import core.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.sync.*

class SetupDraft {
    let profileId: String
    let provider: String
    let protocol: String
    let custom: Bool
    var model: String = ""
    var baseUrl: String
    var apiKeyEnv: String = ""
    var stage: Int64 = 0

    init(selection: String) {
        custom = selection == "OpenAI-compatible"
        if (selection == "Anthropic Messages") {
            profileId = "anthropic"
            provider = "anthropic"
            protocol = "messages"
            baseUrl = "https://api.anthropic.com"
        } else if (custom) {
            profileId = "openai-compatible"
            provider = "openai-compatible"
            protocol = "chat-completions"
            baseUrl = ""
        } else {
            profileId = "openai"
            provider = "openai"
            protocol = "responses"
            baseUrl = "https://api.openai.com"
        }
    }
}

class TuiMailbox {
    private let lock = Mutex()
    private let events = ArrayList<TuiAgentEvent>()
    private let capacity: Int64
    private var result: ?TuiTurnResult = None
    private let ready: () -> Unit

    init(capacity!: Int64 = 4096, ready!: () -> Unit = {=>}) {
        if (capacity < 8) {
            throw IllegalArgumentException("TUI mailbox capacity must be at least 8")
        }
        this.capacity = capacity
        this.ready = ready
    }

    // Streaming deltas are folded while they are still adjacent, preserving
    // event order without retaining one heap object per token/chunk. If a
    // burst contains more distinct, non-coalescible events than the bound,
    // apply producer backpressure until the UI drains; terminal events are
    // never dropped.
    func push(event: TuiAgentEvent): Unit {
        while (true) {
            var accepted = false
            var needsReady = false
            lock.lock()
            try {
                needsReady = events.isEmpty()
                if (!events.isEmpty()) {
                    match (mergeTuiMailboxEvent(events[events.size - 1], event)) {
                        case Some(value) =>
                            events[events.size - 1] = value
                            accepted = true
                        case None => ()
                    }
                }
                if (!accepted && events.size < capacity) {
                    events.add(event)
                    accepted = true
                }
            } finally {
                lock.unlock()
            }
            if (accepted) {
                if (needsReady) { ready() }
                return
            }
            sleep(Duration.millisecond)
        }
    }

    func complete(value: TuiTurnResult): Unit {
        var needsReady = false
        lock.lock()
        try {
            needsReady = events.isEmpty() && match (result) {
                case Some(_) => false
                case None => true
            }
            result = Some(value)
        } finally {
            lock.unlock()
        }
        if (needsReady) { ready() }
    }

    func drain(): Array<TuiAgentEvent> {
        lock.lock()
        try {
            let values = events.toArray()
            events.clear()
            values
        } finally {
            lock.unlock()
        }
    }

    func size(): Int64 {
        lock.lock()
        try {
            events.size
        } finally {
            lock.unlock()
        }
    }

    func takeResult(): ?TuiTurnResult {
        lock.lock()
        try {
            let value = result
            result = None
            value
        } finally {
            lock.unlock()
        }
    }
}

func mergeTuiMailboxEvent(
    previous: TuiAgentEvent,
    incoming: TuiAgentEvent
): ?TuiAgentEvent {
    match ((previous, incoming)) {
        case (TuiAgentEvent.AttemptTextDelta(leftScope, left),
              TuiAgentEvent.AttemptTextDelta(rightScope, right)) =>
            if (leftScope.attemptId == rightScope.attemptId) {
                Some(TuiAgentEvent.AttemptTextDelta(rightScope, left + right))
            } else { None }
        case (TuiAgentEvent.AttemptReasoningDelta(leftScope, left),
              TuiAgentEvent.AttemptReasoningDelta(rightScope, right)) =>
            if (leftScope.attemptId == rightScope.attemptId) {
                Some(TuiAgentEvent.AttemptReasoningDelta(rightScope, left + right))
            } else { None }
        case (TuiAgentEvent.AttemptToolArguments(leftScope, leftCall, left),
              TuiAgentEvent.AttemptToolArguments(rightScope, rightCall, right)) =>
            if (leftScope.attemptId == rightScope.attemptId && leftCall == rightCall) {
                Some(TuiAgentEvent.AttemptToolArguments(rightScope, rightCall, left + right))
            } else { None }
        case (TuiAgentEvent.TextDelta(left), TuiAgentEvent.TextDelta(right)) =>
            Some(TuiAgentEvent.TextDelta(left + right))
        case (TuiAgentEvent.ReasoningDelta(left), TuiAgentEvent.ReasoningDelta(right)) =>
            Some(TuiAgentEvent.ReasoningDelta(left + right))
        case (TuiAgentEvent.ToolOutput(leftId, left, leftStderr),
              TuiAgentEvent.ToolOutput(rightId, right, rightStderr)) =>
            if (leftId == rightId && leftStderr == rightStderr) {
                Some(TuiAgentEvent.ToolOutput(leftId, left + right, leftStderr))
            } else {
                None
            }
        case (TuiAgentEvent.Usage(_, _), TuiAgentEvent.Usage(input, output)) =>
            Some(TuiAgentEvent.Usage(input, output))
        case _ => None
    }
}

func maskedSecret(value: String): String {
    var masked = ""
    for (_ in graphemeClusters(value)) {
        masked += "•"
    }
    masked
}

func headless(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS")) {
        case Some(value) => value == "1" || value == "true"
        case None => false
    }
}

func headlessPerformance(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_PERF")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func headlessDocumentPerformance(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_DOCUMENT_PERF")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func headlessComposerPerformance(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_COMPOSER_PERF")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func headlessLongPerformance(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_LONG_PERF")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func longTranscriptPerformanceCards(): Int64 {
    let configured = match (getVariable("AXYNDRA_TUI_PERF_DATA_COUNT")) {
        case Some(value) => Some(value)
        case None => getVariable("AGENT_TUI_HEADLESS_LONG_CARDS")
    }
    match (configured) {
        case Some(value) => try {
            let parsed: Int64 = Int64.parse(value)
            max(1, parsed)
        } catch (_: Exception) {
            500
        }
        case None => 500
    }
}

func tuiPerformanceTraceRequested(): Bool {
    match (getVariable("AXYNDRA_TUI_PERF_TRACE")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func tuiCoreMetricsRequested(): Bool {
    match (getVariable("AXYNDRA_TUI_CORE_METRICS")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func tuiMemoryTraceRequested(): Bool {
    match (getVariable("AXYNDRA_TUI_MEMORY_TRACE")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func tuiMemoryFixtureInputRequested(): Bool {
    match (getVariable("AXYNDRA_TUI_MEMORY_INPUT")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func tuiMemoryLargeFixtureRequested(): Bool {
    match (getVariable("AXYNDRA_TUI_MEMORY_LARGE_FIXTURE")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func tuiGalleryFixtureRequested(): Bool {
    match (getVariable("AXYNDRA_TUI_GALLERY_FIXTURE")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func tuiPtyPerformanceFixtureRequested(): Bool {
    match (getVariable("AXYNDRA_TUI_PERF_FIXTURE")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func tuiPerformanceStreamChunks(): Int64 {
    match (getVariable("AXYNDRA_TUI_PERF_STREAM_CHUNKS")) {
        case Some(value) => try {
            max(1, Int64.parse(value))
        } catch (_: Exception) {
            200
        }
        case None => 200
    }
}

// Step 3B.5 proof-only producer cadence. It is read only by the explicit PTY
// performance fixture and does not alter normal provider streaming.
func tuiSameHeightBurstIntervalMillis(): Int64 {
    match (getVariable("AXYNDRA_TUI_SAME_HEIGHT_BURST_INTERVAL_MS")) {
        case Some(value) => try {
            max(0, Int64.parse(value))
        } catch (_: Exception) {
            0
        }
        case None => 0
    }
}

func headlessSetup(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_SETUP")) {
        case Some(value) => value == "1" || value == "true"
        case None => false
    }
}

func headlessCards(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_CARDS")) {
        case Some(value) => value == "1" || value == "true"
        case None => false
    }
}

func headlessTodo(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_TODO")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func headlessAsk(): Bool {
    match (getVariable("AGENT_TUI_HEADLESS_ASK")) {
        case Some(value) => value == "1" || value.toAsciiLower() == "true"
        case None => false
    }
}

func ctrlRune(key: KeyEvent, expected: Rune): Bool {
    match (key.code) {
        case KeyCode.Char(value) => key.modifiers.ctrl && value == expected
        case _ => false
    }
}

func isToolOutputCard(card: UiCard): Bool {
    card.kind == UiCardKind.Tool || card.title.startsWith("Tool result") || card.title.startsWith("Subagent") ||
        card.title.startsWith("Background")
}

func pathCompletionCandidates(
    workspace: String,
    prefix: String
): Array<CompletionCandidate> {
    if (prefix.contains("\n") || prefix.contains("\r")) {
        return []
    }
    var authoredParent = ""
    var insertionBase = ""
    var leaf = prefix
    match (prefix.lastIndexOf("/")) {
        case Some(index) =>
            insertionBase = prefix[..index + 1]
            authoredParent = if (index == 0) {
                "/"
            } else {
                prefix[..index]
            }
            leaf = prefix[index + 1..]
        case None => ()
    }
    let directory = if (authoredParent == "") {
        workspace
    } else if (authoredParent == "~") {
        match (getVariable("HOME")) {
            case Some(home) => home
            case None => workspace
        }
    } else if (authoredParent.startsWith("~/")) {
        match (getVariable("HOME")) {
            case Some(home) => Path(home).join(authoredParent[2..]).normalize().toString()
            case None => Path(workspace).join(authoredParent).normalize().toString()
        }
    } else if (Path(authoredParent).isAbsolute()) {
        Path(authoredParent).normalize().toString()
    } else {
        Path(workspace).join(authoredParent).normalize().toString()
    }
    let items = ArrayList<CompletionCandidate>()
    try {
        if (!exists(Path(directory)) || !FileInfo(Path(directory)).isDirectory()) {
            return []
        }
        for (entry in Directory.readFrom(directory)) {
            if (!leaf.startsWith(".") && entry.name.startsWith(".")) {
                continue
            }
            let child = Path(directory).join(entry.name)
            let suffix = if (FileInfo(child).isDirectory()) {
                "/"
            } else {
                ""
            }
            let label = insertionBase + entry.name + suffix
            items.add(
                CompletionCandidate(
                    label,
                    detail: if (suffix == "/") { "directory" } else { "file" },
                    directory: suffix == "/"
                )
            )
        }
    } catch (_: Exception) {
        return []
    }
    items.toArray()
}
