package agent_tui

import agent_cli.*
import core.*
import markdown.*
import std.collection.*
import std.env.*
import std.sync.*
import std.time.*

let AGENT_STREAM_TIMER = "agent-stream-refresh"
let PERF_STREAM_TIMER = "omp-tui-perf-stream"
let PERF_STEP05_STREAM_CARD_ID = "perf-step05-stream-target"
let EMPTY_LEFT_DOUBLE_TAP_WINDOW = Duration.millisecond * 400
let MAIN_CONVERSATION_ID = "__main__"

func asciiRailRequested(): Bool {
    match (getVariable("AXYNDRA_ASCII")) {
        case Some(value) => value == "1" || value == "true"
        case None => match (getVariable("TERM")) {
            case Some(value) => value == "dumb"
            case None => false
        }
    }
}

func startAgentTurn(task: () -> Event): UpdateResult {
    UpdateResult.withCommand(
        Command.Batch(
            [
                Command.StartTimer(
                    TimerSpec(
                        AGENT_STREAM_TIMER,
                        Duration.millisecond * 80
                    )
                ),
                Command.AsyncTask("agent-turn", task)
            ]
        )
    )
}

func stopAgentStream(result: UpdateResult): UpdateResult {
    UpdateResult(
        flow: result.flow,
        command: Command.Batch(
            [
                Command.StopTimer(AGENT_STREAM_TIMER),
                result.command
            ]
        ),
        dirtyRects: result.dirtyRects
    )
}

func productSlashHints(): Array<String> {
    let values = ArrayList<String>()
    for (name in availableSlashCommands()) {
        values.add("/" + name)
    }
    values.toArray()
}

class CardScreenRange {
    let id: String
    let top: Int64
    let bottom: Int64

    init(id: String, top: Int64, bottom: Int64) {
        this.id = id
        this.top = top
        this.bottom = bottom
    }
}

class ToolCardBinding {
    let callId: String
    let cardId: String
    let name: String
    var arguments: String
    let startedAt: MonoTime

    init(callId: String, cardId: String, name: String, arguments: String, startedAt: MonoTime) {
        this.callId = callId
        this.cardId = cardId
        this.name = name
        this.arguments = arguments
        this.startedAt = startedAt
    }
}

// Keeps one stateful DocumentView per immutable modal body.  The cjtui view
// caches Unicode-aware wrapping by width; changing only the scroll offset then
// renders a row slice without laying out the document again.
class DocumentWindowCache {
    private var key = ""
    private var width: Int64 = -1
    private var state = DocumentViewState()
    private var view: ?DocumentView = None
    private var raster = Buffer(Rect(0, 0, 1, 1))
    private var rasterStart: Int64 = 0
    private var rasterHeight: Int64 = 0
    private var rasterValid = false
    private var layoutCount: Int64 = 0

    func render(document: Document, documentKey: String, scroll: Int64, area: Rect, target: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) {
            return
        }
        if (key != documentKey) {
            key = documentKey
            width = -1
            state = DocumentViewState()
            view = Some(DocumentView(document, state: Some(state), cacheLayout: true))
            rasterValid = false
        }
        if (width != area.width) {
            width = area.width
            layoutCount++
            rasterValid = false
        }
        let requested = max(0, scroll)
        let wantedHeight = max(128, area.height * 4)
        if (!rasterValid || rasterHeight != wantedHeight || requested < rasterStart || requested + area.height >
            rasterStart + rasterHeight) {
            rasterStart = max(0, requested - wantedHeight / 3)
            rasterHeight = wantedHeight
            raster = Buffer(Rect(0, 0, area.width, rasterHeight))
            state.scroll = rasterStart
            match (view) {
                case Some(current) => current.render(Rect(0, 0, area.width, rasterHeight), raster)
                case None => ()
            }
            rasterValid = true
        }
        target.blitFromUnchecked(
            raster,
            Rect(0, requested - rasterStart, area.width, area.height),
            area.x,
            area.y
        )
    }

    func layouts(): Int64 {
        layoutCount
    }

    func entries(): Int64 {
        if (view.isSome()) { 1 } else { 0 }
    }

    func bufferCapacityCells(): Int64 {
        max(0, raster.area.width * raster.area.height)
    }
}

class CachedDocumentViewport <: Widget {
    private let cache: DocumentWindowCache
    private let document: Document
    private let documentKey: String
    private let scroll: Int64

    init(cache: DocumentWindowCache, document: Document, documentKey: String, scroll: Int64) {
        this.cache = cache
        this.document = document
        this.documentKey = documentKey
        this.scroll = scroll
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        cache.render(document, documentKey, scroll, area, buffer)
    }
}

func agentHubShortcut(key: KeyEvent): Bool {
    match (key.code) {
        case KeyCode.Char(r'a') | KeyCode.Char(r'A') => key.modifiers.alt && !key.modifiers.ctrl
        case KeyCode.Char(r's') | KeyCode.Char(r'S') => key.modifiers.ctrl && !key.modifiers.alt
        case _ => false
    }
}

enum TuiModalKind {
    Setup
    | Model
    | Theme
    | Session
    | Tree
    | Agent
    | Extensions
    | Branch
    | Settings
    | Reset
    | Document
}

public func runAgentTui(
    backend: AgentTuiBackend,
    title!: String = "Agent Workbench",
    initialPrompt!: String = ""
): Int64 {
    let performanceTrace: ?TuiPerformanceTrace = if (tuiPerformanceTraceRequested()) {
        Some(TuiPerformanceTrace())
    } else {
        None
    }
    tuiStartupStage("card_registry_initialization_started")
    // Card renderers are stateless dispatch functions. This marker proves the
    // startup path does not eagerly construct the gallery fixture or a second
    // formatter registry.
    tuiStartupStage("card_registry_initialization_completed")
    tuiStartupStage("first_state_construction_started")
    let externalPort = ExternalPort<Event>(capacity: 1)
    if (performanceTrace.isSome()) {
        externalPort.enableLatencyMeasurement()
    }
    let screen = AgentScreen(
        backend,
        title,
        initialPrompt,
        performanceTrace: performanceTrace,
        externalPort: externalPort
    )
    tuiStartupStage("first_state_construction_completed")
    tuiStartupStage("fixture_generation_started")
    if (tuiGalleryFixtureRequested()) {
        screen.seedGallerySmoke()
    }
    if (tuiPtyPerformanceFixtureRequested()) {
        screen.seedLongTranscriptPerformance()
        if (tuiMemoryLargeFixtureRequested()) {
            screen.seedLargeMemoryCards()
        }
    }
    tuiStartupStage("fixture_generation_completed")
    if (headless()) {
        let result = runHeadless(screen)
        externalPort.close()
        return result
    }
    match (performanceTrace) {
        case Some(trace) =>
            let output = TuiTracingOutput(getStdOut(), trace)
            let app = App(
                backend: AnsiBackend(output: output),
                mouse: true,
                instrumentationEnabled: tuiCoreMetricsRequested()
            )
            app.attachTraceSink(trace)
            app.runWithExternalPort(
                externalPort,
                {frame =>
                    screen.render(frame)
                    if (trace.memorySampleDue()) {
                        screen.emitMemoryState(trace)
                    }
                    trace.renderCompleted()
                },
                {event => screen.update(event)}
            )
        case None => App(mouse: true).runWithExternalPort(
            externalPort,
            {frame => screen.render(frame)},
            {event => screen.update(event)}
        )
    }
    0
}

class MarkdownCacheEntry {
    let id: String
    var body: String
    var kind: UiCardKind
    var document: Document

    init(
        id: String,
        body: String,
        kind: UiCardKind,
        document: Document
    ) {
        this.id = id
        this.body = body
        this.kind = kind
        this.document = document
    }
}

class ApprovalPresentation {
    let tool: String
    let capability: String
    let resource: String
    let risk: String
    let preview: String

    init(
        tool: String,
        capability: String,
        resource: String,
        risk: String,
        preview: String
    ) {
        this.tool = tool
        this.capability = capability
        this.resource = resource
        this.risk = risk
        this.preview = preview
    }
}

class QueuedPrompt {
    let id: String
    let kind: String
    let text: String

    init(id: String, kind: String, text: String) {
        this.id = id
        this.kind = kind
        this.text = text
    }
}

class CompletedQueueWithdrawal {
    let id: String
    let result: TuiQueueWithdrawal

    init(id: String, result: TuiQueueWithdrawal) {
        this.id = id
        this.result = result
    }
}

class AgentTranscriptSource <: VirtualTranscriptSource {
    private var snapshot: UiSnapshot
    private let renderCard: (UiCard, Int64, String) -> Document
    private var theme = axyndraTheme()
    private var generationValue: Int64 = 0
    // Focused card id for the header focus marker (›); set by the screen
    // before each render.
    public var focusedCardId = ""
    public var unicode = true
    public var activityFrame: Int64 = 0
    public var approvalSelected: Int64 = -1
    public var documentCalls: Int64 = 0

    init(
        snapshot: UiSnapshot,
        renderCard: (UiCard, Int64, String) -> Document
    ) {
        this.snapshot = snapshot
        this.renderCard = renderCard
    }

    func setSnapshot(value: UiSnapshot): Unit {
        this.snapshot = value
        generationValue++
    }

    func setTheme(value: ProductTheme): Unit {
        this.theme = value
    }

    func invalidateGeneration(): Unit {
        generationValue++
    }

    public func generation(): Int64 {
        generationValue
    }

    public func itemAppendOnlyText(
        index: Int64,
        width: Int64,
        themeKey: String
    ): ?VirtualTranscriptAppendOnlyText {
        let _ = themeKey
        if (index < 0 || index >= snapshot.cards.size) { return None }
        let item = snapshot.cards[index]
        let streamingText = item.state == "streaming" &&
            (item.kind == UiCardKind.Assistant || item.kind == UiCardKind.Reasoning)
        if (!streamingText || (item.kind == UiCardKind.Reasoning && item.collapsed)) {
            return None
        }
        Some(VirtualTranscriptAppendOnlyText(
            item.body,
            style: Style(fg: theme.text),
            wrapWidth: max(1, width - 2),
            appendEpoch: item.bodyRewriteEpoch
        ))
    }

    public func itemCardTheme(index: Int64): ?TranscriptCardTheme {
        if (index >= 0 && index < snapshot.cards.size) {
            Some(productTranscriptCardTheme(theme, snapshot.cards[index]))
        } else {
            None
        }
    }

    public func size(): Int64 {
        snapshot.cards.size
    }

    public func itemId(index: Int64): String {
        snapshot.cards[index].id
    }

    public func itemTitle(index: Int64): String {
        itemTitleForWidth(index, 240)
    }

    public func itemUsesCardChrome(index: Int64): Bool {
        let kind = snapshot.cards[index].kind
        kind != UiCardKind.Assistant && kind != UiCardKind.User && kind != UiCardKind.Reasoning
    }

    public func itemUsesCompactCardChrome(index: Int64): Bool {
        let item = snapshot.cards[index]
        if (item.kind == UiCardKind.Tool && isShellToolCard(item)) {
            return false
        }
        let collapsed = item.collapsed || (item.kind == UiCardKind.Approval && !approvalCardIsWaiting(item.state))
        collapsed && itemFooter(index) == ""
    }

    public func itemTitleForWidth(index: Int64, width: Int64): String {
        let item = snapshot.cards[index]
        let status = productTranscriptStatus(item)
        let collapsed = item.collapsed || (item.kind == UiCardKind.Approval && !approvalCardIsWaiting(item.state))
        let focusMark = if (item.id == focusedCardId) {
            "› "
        } else {
            ""
        }
        let mark = if (unicode) {
            statusMark(status, activityFrame: activityFrame)
        } else {
            asciiStatusMark(status)
        }
        let state = readableCardState(item.state)
        let duration = productCardDuration(item)
        // The timer is allowed to change the running marker only.  Keeping
        // the title width stable avoids rewrapping the whole transcript on
        // every spinner tick; the final duration is written at tool_end.
        let liveDuration = duration
        let suffix = " · " + state + (if (liveDuration == "") {
            ""
        } else {
            " · " + liveDuration
        }) + (if (collapsed) {
            " ▸"
        } else {
            ""
        })
        let prefix = focusMark + mark + " "
        // Older persisted cards may still carry the former generic
        // `Tool · name` title.  Drop only that redundant presentation prefix
        // at render time; keep the stored card and all specialized titles
        // unchanged.
        let genericToolPrefix = "Tool · "
        let displayTitle = if (item.kind == UiCardKind.Tool && item.title.startsWith(genericToolPrefix)) {
            item.title[genericToolPrefix.size..]
        } else {
            item.title
        }
        prefix + fitAgentCardTitle(
            displayTitle,
            max(1, width - displayWidth(prefix + suffix)),
            unicode
        ) + suffix
    }

    public func itemFooter(index: Int64): String {
        let item = snapshot.cards[index]
        let summary = if (item.kind == UiCardKind.Tool && isShellToolCard(item)) {
            shellToolMetadata(item, unicode)
        } else if (item.footer != "") {
            item.footer
        } else if (item.kind == UiCardKind.Tool && (item.state == "completed" || item.state == "success")) {
            productCardDuration(item)
        } else {
            ""
        }
        if (item.bodyScroll <= 0 || item.bodyViewport <= 0) {
            return summary
        }
        let total = item.bodyLines()
        let first = min(total, item.bodyScroll + 1)
        let last = min(total, item.bodyScroll + max(1, item.bodyViewport))
        let position = first.toString() + "–" + last.toString() + "/" + total.toString()
        if (summary == "") {
            position
        } else {
            position + " · " + summary
        }
    }

    public func revision(index: Int64): Int64 {
        let item = snapshot.cards[index]
        // The reducer owns content invalidation.  Keep approval selection in
        // the key because it changes only the active card's option rows.
        let approvalRevision = if (item.kind == UiCardKind.Approval) {
            max(0, approvalSelected + 1)
        } else {
            0
        }
        item.renderRevision * 4096 + approvalRevision
    }

    public func document(
        index: Int64,
        width: Int64,
        themeKey: String
    ): Document {
        documentCalls++
        renderCard(snapshot.cards[index], width, themeKey)
    }
}

func appendTranscriptItem(snapshot: UiSnapshot, item: TuiTranscriptItem): Unit {
    UiReducer.reduce(
        snapshot,
        UiEvent.UpsertCard(
            item.id, item.kind, item.title, item.body, item.state, item.collapsed, ""
        )
    )
    if (item.toolName != "" || item.toolCallId != "") {
        UiReducer.reduce(
            snapshot,
            UiEvent.SetToolMetadata(
                item.id,
                item.toolName,
                item.toolArguments,
                item.toolCallId,
                item.toolOutput
            )
        )
    }
}

func prependTranscriptPage(current: UiSnapshot, page: TuiTranscriptPage): UiSnapshot {
    let next = UiSnapshot()
    for (item in page.items) { appendTranscriptItem(next, item) }
    let existingIds = HashSet<String>()
    for (card in next.cards) { existingIds.add(card.id) }
    for (card in current.cards) {
        if (!existingIds.contains(card.id)) { next.cards.add(card) }
    }
    next.status = current.status
    next.working = current.working
    next.inputTokens = current.inputTokens
    next.outputTokens = current.outputTokens
    next.approvalId = current.approvalId
    next
}

class AgentScreen {
    private let backend: AgentTuiBackend
    private let performanceTrace: ?TuiPerformanceTrace
    private let title: String
    private let initialPrompt: String
    private let composer = Composer(slashHints: productSlashHints())
    private var ui = UiSnapshot()
    private let markdownCache = HashMap<String, MarkdownCacheEntry>()
    private let mailbox: TuiMailbox
    private let externalPort: ExternalPort<Event>
    private var mailboxChanged = false
    private var mailboxViewportRefresh = false
    private var status = "ready"
    private var taskLabel = ""
    private var working = false
    private var mainWorking = false
    private var turnOwnerSubagentId = ""
    private var workingElapsedMillis: Int64 = 0
    private var workingArea = Rect(0, 0, 0, 0)
    private var queuedArea = Rect(0, 0, 0, 0)
    private var todoArea = Rect(0, 0, 0, 0)
    private var composerArea = Rect(0, 0, 0, 0)
    private var composerInputArea = Rect(0, 0, 0, 0)
    private var composerHeightBeforePaint: Int64 = 1
    private var composerHeightAfterPaint: Int64 = 1
    private var composerHeight: Int64 = 1
    private var viewportHeight: Int64 = 0
    private var viewportArea = Rect(0, 0, 0, 0)
    private var transcriptArea = Rect(0, 0, 0, 0)
    private var scrollOffset: Int64 = 0
    private var transcriptTotalLines: Int64 = 0
    private var transcriptVisibleLines: Int64 = 0
    private var transcriptStartLine: Int64 = 0
    private var newTranscriptLines: Int64 = 0
    private var configuredCardViewport: Int64 = -1
    private var configuredCardViewportCount: Int64 = 0
    private var terminalUnicode = true
    private var virtualTranscriptSource: ?AgentTranscriptSource = None
    private var virtualTranscriptView: ?VirtualTranscriptView = None
    private let transcriptRanges = ArrayList<CardScreenRange>()
    private let queuedPrompts = ArrayList<QueuedPrompt>()
    private let queueWithdrawalLock = Mutex()
    private let completedQueueWithdrawals = ArrayList<CompletedQueueWithdrawal>()
    private var withdrawalInFlightId = ""
    private let toolBindings = ArrayList<ToolCardBinding>()
    private var modal: ?TuiModalKind = None
    private var modalItems: Array<String> = []
    private var modalSelected: Int64 = 0
    private var documentTitle = ""
    private var documentBody = ""
    private var documentScroll: Int64 = 0
    private var documentRevision: Int64 = 0
    private var documentModalCacheKey = ""
    private var documentModalCache = Document([])
    private let documentWindowCache = DocumentWindowCache()
    private var activeModalArea = Rect(0, 0, 0, 0)
    private var modalRefreshOnly = false
    private var treeNodes: Array<TuiSessionNode> = []
    private var sessionNodes: Array<TuiSessionNode> = []
    private var visibleSessionNodes: Array<TuiSessionNode> = []
    private var sessionFilter = ""
    private var sessionInput = ""
    private var sessionMode = "browse"
    private var sessionShowArchived = false
    private var subagentItems: Array<TuiSubagentInfo> = []
    private var agentHubActive = false
    private var focusedSubagentId = ""
    private var focusedConversationLabel = "Main"
    private var mainTranscriptBeforeOrdinal: Int64 = 0
    private var mainTranscriptHasMore = false
    private let runningSubagentIds = ArrayList<String>()
    private var extensionItems: Array<TuiExtensionInfo> = []
    private let planReview = PlanReviewController()
    private let ask = AskController()
    private let todos = TodoController()
    private var setupDraft: ?SetupDraft = None
    private var setupRequired = false
    private var initialSubmitted: Bool
    private var draftLoadStarted = false
    private var cardSequence: Int64 = 0
    private var turnSequence: Int64 = 0
    private var modelRoundSequence: Int64 = 0
    private let attemptProjection = AttemptProjection()
    private var activeToolCardId = ""
    private var activeToolCallId = ""
    private var activeToolArguments = ""
    private var activeToolStartedAt: ?MonoTime = None
    private var focusedCardIndex: Int64 = -1
    private var focusedCardId = ""
    private var approvalSelected: Int64 = 0
    private var approvalSessionLabel = "Allow scoped access for this session"
    private var approvalInspectTitle = "Approval details"
    private var approvalInspectBody = ""
    private var approvalToolCardId = ""
    private var idleCtrlCArmed = false
    private var lastEmptyLeftTap: ?MonoTime = None
    private var agentHubOpenCount: Int64 = 0
    private var backgroundSequence: Int64 = 0
    private var completionSequence: Int64 = 0
    private var performanceStreamRemaining: Int64 = 0
    private var performanceAppendSequence: Int64 = 0
    private var performanceLongSeedStart: Int64 = -1
    private var performanceLongSeedCount: Int64 = 0
    private var performanceBurstActive = false
    private var performanceBurstAppliedThisUpdate: Int64 = 0
    private var performanceBurstAppliedTotal: Int64 = 0
    private var performanceBurstReadyMarkersProcessed: Int64 = 0
    private var performanceBurstInitialRect: ?Rect = None
    private var performanceBurstPreviousHeight: Int64 = -1
    private var performanceBurstInitialVisibleSignature = ""
    private var performanceBurstExternalAcceptedBaseline: Int64 = 0
    private var performanceBurstExternalFullBaseline: Int64 = 0
    private var performanceBurstWakeSignalsBaseline: Int64 = 0
    private var memoryReplaceSequence: Int64 = 0
    private var memoryStreamCardIndex: Int64 = -1
    private var memoryLargeShellCardIndex: Int64 = -1
    private var themeName: String
    private var customThemeDefinitions: Array<TuiThemeDefinition>
    private var modelLabel: String
    private let workspaceLabel: String

    init(
        backend: AgentTuiBackend,
        title: String,
        initialPrompt: String,
        performanceTrace!: ?TuiPerformanceTrace = None,
        externalPort!: ExternalPort<Event> = ExternalPort<Event>(capacity: 1)
    ) {
        this.backend = backend
        this.performanceTrace = performanceTrace
        this.externalPort = externalPort
        this.mailbox = TuiMailbox(ready: {=>
            // Capacity one is a single-flight ready marker. Full means a
            // marker is already pending; mailbox contents remain retained.
            _ = externalPort.tryEnqueue(Event.Message("agent-external-ready"))
        })
        this.title = title
        this.initialPrompt = initialPrompt.trimAscii()
        this.initialSubmitted = this.initialPrompt == ""
        this.modelLabel = backend.currentModel()
        this.workspaceLabel = backend.workspace()
        this.themeName = backend.currentTheme()
        this.customThemeDefinitions = backend.customThemes()
        this.terminalUnicode = !asciiRailRequested()
        planReview.setTheme(themeName, customThemeDefinitions)
        let source = AgentTranscriptSource(ui, {
            item, width, _ => renderTranscriptBodyDocument(
                item,
                width,
                activeProductTheme(
                    overrideName: themeName,
                    customThemes: customThemeDefinitions
                )
            )
        })
        source.unicode = terminalUnicode
        virtualTranscriptSource = Some(source)
        // Long sessions should only materialize the visible/overscan window.
        // The core's background batch is useful for eager height convergence,
        // but doing that work on every wheel/key frame makes scrolling render
        // unrelated cards and produces visible stalls.
        let view = VirtualTranscriptView(
            source,
            backgroundBatch: 0,
            instrumentationEnabled: tuiCoreMetricsRequested()
        )
        view.setUnicode(terminalUnicode)
        virtualTranscriptView = Some(view)
        backend.observe({event => mailbox.push(event)})
        var needsSetup = false
        for (event in backend.welcome()) {
            match (event) {
                case TuiAgentEvent.Setup(_) => needsSetup = true
                case _ => ()
            }
            acceptAgentEvent(event)
        }
        let _ = todos.applySnapshot(backend.todoMarkdown())
        setupRequired = needsSetup
        if (!needsSetup && this.initialPrompt == "" && headless()) {
            composer.restoreDraft(backend.draft())
            draftLoadStarted = true
        }
        if (needsSetup) {
            let _ = openModal(
                TuiModalKind.Setup,
                [
                    "OpenAI Responses",
                    "Anthropic Messages",
                    "OpenAI-compatible",
                    "Close"
                ]
            )
        }
    }

    private func handleKeyDown(key: KeyEvent): UpdateResult {
        // Enhanced keyboard protocols report Ctrl+C as a modified character
        // instead of the removed dedicated key code. Normalize it before any
        // modal/approval/composer routing so interrupt and exit semantics are
        // identical in kitty, WezTerm, tmux and basic terminals.
        if (ctrlRune(key, r'c')) {
            return handleKeyDown(KeyEvent(KeyCode.CtrlC))
        }
        match (key.code) {
            case KeyCode.F(4) =>
                if (tuiPtyPerformanceFixtureRequested()) {
                    return openModal(TuiModalKind.Model, ["model-a", "model-b", "model-c"])
                }
            case KeyCode.F(11) =>
                if (tuiMemoryFixtureInputRequested()) {
                    return UpdateResult.exit()
                }
                if (tuiPtyPerformanceFixtureRequested()) {
                    return UpdateResult.exit()
                }
            case KeyCode.F(9) =>
                if (tuiMemoryFixtureInputRequested()) {
                    appendMemoryStreamCard()
                    return dirtyTranscript()
                }
                if (tuiPtyPerformanceFixtureRequested()) {
                    appendPerformanceTranscriptItem()
                    return dirtyTranscript()
                }
            case KeyCode.F(10) =>
                if (tuiMemoryFixtureInputRequested()) {
                    replaceFixedMemoryCard()
                    return dirtyTranscriptAndActivity()
                }
                if (tuiPtyPerformanceFixtureRequested()) {
                    // Step 1A product proof: publish after the key update and
                    // frame have completed. No timer/input is available to
                    // wake the runtime; only the mailbox ExternalPort marker
                    // can make this delta visible.
                    _ = spawn {
                        sleep(Duration.millisecond * 20)
                        mailbox.push(TuiAgentEvent.TextDelta(" idle-wake"))
                    }
                    return UpdateResult.unchanged()
                }
            case KeyCode.F(12) =>
                if (tuiMemoryFixtureInputRequested()) {
                    toggleLargeMemoryFixture()
                    return dirtyTranscriptAndActivity()
                }
                if (tuiPtyPerformanceFixtureRequested()) {
                    return startPerformanceSameHeightBurst()
                }
            case KeyCode.F(5) =>
                if (tuiPtyPerformanceFixtureRequested()) {
                    appendPerformanceStreamText("x")
                    var update = dirtyTranscriptItem(PERF_STEP05_STREAM_CARD_ID)
                    // When the changed tail is offscreen there is correctly
                    // no transcript frame. Keep the PTY proof observable by
                    // repainting only the one-row activity strip.
                    if (scrollOffset > 0 && workingArea.width > 0 && workingArea.height > 0) {
                        update = update.withDirty(workingArea)
                    }
                    return update
                }
            case KeyCode.F(6) =>
                if (tuiPtyPerformanceFixtureRequested()) {
                    appendPerformanceStreamText(
                        " product wrap boundary 中文 wide 界 0123456789" +
                            " product wrap boundary 中文 wide 界 0123456789"
                    )
                    return dirtyTranscriptItem(PERF_STEP05_STREAM_CARD_ID)
                }
            case KeyCode.F(7) =>
                if (tuiPtyPerformanceFixtureRequested()) {
                    appendPerformanceStreamText("\ncomplete product line")
                    return dirtyTranscriptItem(PERF_STEP05_STREAM_CARD_ID)
                }
            case KeyCode.F(8) =>
                if (tuiPtyPerformanceFixtureRequested()) {
                    performanceStreamRemaining = tuiPerformanceStreamChunks()
                    return UpdateResult.withCommand(
                        Command.StartTimer(
                            TimerSpec(
                                PERF_STREAM_TIMER,
                                Duration.millisecond * 5
                            )
                        )
                    )
                }
            case _ => ()
        }
        if (ctrlRune(key, r'l')) {
            status = "terminal display reset"
            return syncPlanReviewStatus(UpdateResult.withCommand(Command.ResetTerminal))
        }
        if (ctrlRune(key, r'z')) {
            status = if (working) {
                "working"
            } else {
                "ready"
            }
            return syncPlanReviewStatus(UpdateResult.withCommand(Command.Suspend))
        }
        if (ctrlRune(key, r'o')) {
            return syncPlanReviewStatus(toggleToolOutputVisibility())
        }
        if (ctrlRune(key, r't')) {
            return syncPlanReviewStatus(toggleThinkingVisibility())
        }
        if (planReview.isActive()) {
            return applyPlanReviewTransition(planReview.updateKey(key, working))
        }
        if (todos.isEditing()) {
            return applyTodoTransition(todos.updateKey(key))
        }
        if (ask.editorActive()) {
            return updateAskEditor(key)
        }
        if (ask.isActive()) {
            return updateAskModal(key)
        }
        if (agentHubActive) {
            return updateAgentHub(key)
        }
        if (modal.isSome()) {
            return updateModal(key)
        }
        if (secretSetupEntry()) {
            return updateSecretSetup(key)
        }
        if (ui.approvalId.isSome()) {
            return updateApproval(key)
        }
        if (agentHubShortcut(key)) {
            lastEmptyLeftTap = None
            return openAgentHub()
        }
        match (key.code) {
            case KeyCode.Up => if (key.modifiers.alt) {
                idleCtrlCArmed = false
                lastEmptyLeftTap = None
                return withdrawLatestQueued()
            }
            case _ => ()
        }
        if (ctrlRune(key, r'q')) {
            idleCtrlCArmed = false
            return submitComposer(if (working) { "follow_up" } else { "normal" })
        }
        if (composer.area.value.isEmpty()) {
            match (key.code) {
                case KeyCode.Left =>
                    if (focusedCardIndex >= 0) {
                        return setFocusedCardExpanded(false)
                    }
                    if (!key.nativeRepeat) {
                        let now = MonoTime.now()
                        let doubleTap = match (lastEmptyLeftTap) {
                            case Some(previous) => now - previous <= EMPTY_LEFT_DOUBLE_TAP_WINDOW
                            case None => false
                        }
                        lastEmptyLeftTap = if (doubleTap) {
                            None
                        } else {
                            Some(now)
                        }
                        if (doubleTap) {
                            return openAgentHub()
                        }
                    }
                    return UpdateResult.next()
                case _ => lastEmptyLeftTap = None
            }
        } else {
            lastEmptyLeftTap = None
        }
        match (key.code) {
            case KeyCode.CtrlC =>
                if (idleCtrlCArmed) {
                    UpdateResult.exit()
                } else {
                    _ = composer.cancelCompletion()
                    composer.area.setValue("")
                    idleCtrlCArmed = true
                    status = "input cleared · Ctrl+C again to exit"
                    backgroundTask(
                        "draft",
                        {
                            =>
                                let _ = backend.saveDraft("")
                                Event.Message("draft cleared")
                        }
                    )
                }
            case KeyCode.Esc =>
                idleCtrlCArmed = false
                if (composer.cancelCompletion()) {
                    status = if (working) {
                        "working"
                    } else {
                        "ready"
                    }
                    return dirtyComposer()
                }
                if (working) {
                    status = "cancelling"
                    return backgroundTask(
                        "cancel",
                        {
                            =>
                                backend.cancel()
                                Event.Message("cancel requested")
                        }
                    )
                }
                UpdateResult.next()
            case KeyCode.Tab =>
                idleCtrlCArmed = false
                if (composer.completionVisible()) {
                    _ = composer.handle(key)
                    dirtyComposer()
                } else {
                    openComposerCompletion()
                }
            case KeyCode.Up | KeyCode.Down =>
                idleCtrlCArmed = false
                if (composer.completionVisible()) {
                    _ = composer.area.handle(key)
                    dirtyComposer()
                } else {
                    match (composer.handle(key)) {
                        case Some(submit) => submitPrompt(submit.text)
                        case None => dirtyComposer()
                    }
                }
            case KeyCode.Char(r) =>
                if (key.modifiers.ctrl && r == r'd' && composer.area.value.isEmpty()) {
                    return UpdateResult.exit()
                }
                idleCtrlCArmed = false
                // Card focus navigation when the composer is empty: j/k move focus,
                // space toggles the focused card.
                if (composer.area.value.isEmpty()) {
                    if (r == r'y' || r == r'Y') {
                        return copyFocusedCard()
                    }
                    if (r == r'j' || r == r'J' || r == r'k' || r == r'K') {
                        moveCardFocus(if (r == r'j' || r == r'J') {
                            1
                        } else {
                            -1
                        })
                        return UpdateResult.next()
                    }
                    if (r == r'h' || r == r'H') {
                        return setFocusedCardExpanded(false)
                    }
                    if (r == r'l' || r == r'L') {
                        return setFocusedCardExpanded(true)
                    }
                    if (r == r' ' && focusedCardIndex >= 0) {
                        return toggleFocusedCard()
                    }
                }
                match (composer.handle(key)) {
                    case Some(submit) => submitPrompt(submit.text)
                    case None => dirtyComposerContent()
                }
            case KeyCode.Enter =>
                idleCtrlCArmed = false
                if (key.modifiers.shift || key.modifiers.alt) {
                    _ = composer.cancelCompletion()
                    _ = composer.handle(key)
                    return dirtyComposerContent()
                }
                if (key.modifiers.ctrl) {
                    return submitComposer(if (working) { "follow_up" } else { "normal" })
                }
                if (composer.completionVisible()) {
                    _ = composer.area.handle(key)
                    return dirtyComposer()
                }
                if (composer.area.value.isEmpty() && focusedCardIndex >= 0) {
                    return toggleFocusedCard()
                }
                submitComposer(if (working) { "steer" } else { "normal" })
            case KeyCode.PageUp =>
                idleCtrlCArmed = false
                if (composer.area.value.isEmpty() && scrollFocusedCardBy(transcriptPageSize())) {
                    return dirtyTranscriptAndActivity()
                }
                scrollTranscriptBy(transcriptPageSize())
            case KeyCode.PageDown =>
                idleCtrlCArmed = false
                if (composer.area.value.isEmpty() && scrollFocusedCardBy(-transcriptPageSize())) {
                    return dirtyTranscriptAndActivity()
                }
                scrollTranscriptBy(-transcriptPageSize())
            case KeyCode.Home =>
                idleCtrlCArmed = false
                if (key.modifiers.ctrl) {
                    scrollTranscriptToTop()
                } else if (composer.area.value.isEmpty()) {
                    focusFirstCard()
                    UpdateResult.next()
                } else {
                    match (composer.handle(key)) {
                        case Some(submit) => submitPrompt(submit.text)
                        case None => dirtyComposerContent()
                    }
                }
            case KeyCode.End =>
                idleCtrlCArmed = false
                if (key.modifiers.ctrl) {
                    scrollOffset = 0
                    newTranscriptLines = 0
                    clearScrollAnchor()
                    dirtyTranscriptAndActivity()
                } else if (composer.area.value.isEmpty()) {
                    focusLastCard()
                    // End is both the last-card navigation key and the explicit
                    // follow-bottom affordance for a transcript that was scrolled up.
                    scrollOffset = 0
                    newTranscriptLines = 0
                    clearScrollAnchor()
                    dirtyTranscriptAndActivity()
                } else {
                    match (composer.handle(key)) {
                        case Some(submit) => submitPrompt(submit.text)
                        case None => dirtyComposerContent()
                    }
                }
            case _ =>
                idleCtrlCArmed = false
                match (composer.handle(key)) {
                    case Some(submit) => submitPrompt(submit.text)
                    case None => dirtyComposerContent()
                }
        }
    }

    private func handleMouse(mouse: MouseEvent): UpdateResult {
        if (mouse.x < transcriptArea.x || mouse.x >= transcriptArea.right || mouse.y < transcriptArea.y || mouse.y >= transcriptArea
            .bottom) {
            return UpdateResult.next()
        }
        match ((mouse.kind, mouse.button)) {
            case (MouseKind.Scroll, MouseButton.WheelUp) =>
                // A wheel notch should feel like a small continuous movement.  A
                // viewport-relative jump becomes 6-12 rows on normal terminals and
                // reads as stutter even when the frame itself is fast.
                scrollTranscriptBy(3)
            case (MouseKind.Scroll, MouseButton.WheelDown) => scrollTranscriptBy(-3)
            case (MouseKind.Down, MouseButton.Left) =>
                focusCardAt(mouse.y)
                toggleCardAt(mouse.y)
            case _ => UpdateResult.next()
        }
    }

    private func handlePaste(text: String): UpdateResult {
        idleCtrlCArmed = false
        if (planReview.isActive()) {
            return planReview.paste(text)
        } else if (todos.isEditing()) {
            return applyTodoTransition(todos.paste(text))
        } else if (ask.editorActive()) {
            return ask.paste(text)
        } else {
            _ = composer.paste(text)
        }
        if (!ask.editorActive()) {
            dirtyComposerContent()
        } else {
            UpdateResult.next()
        }
    }

    private func applyPlanReviewTransition(step: PlanReviewTransition): UpdateResult {
        status = planReview.statusText()
        match (step.effect) {
            case None => step.update
            case Some(PlanReviewEffect.Close) =>
                planReview.close()
                status = "ready"
                if (viewportArea.width > 0 && viewportArea.height > 0) {
                    UpdateResult.dirty(viewportArea)
                } else {
                    UpdateResult.next()
                }
            case Some(PlanReviewEffect.CopyText(text)) =>
                status = backend.copyTextToClipboard(text)
                _ = planReview.setStatusText(status)
                step.update
            case Some(PlanReviewEffect.ReviewPlan(hash, decision, feedback)) =>
                if (decision == TuiPlanReviewDecision.UpdatePlan) {
                    return startBackground(
                        "updating plan",
                        {
                            => backend.reviewPlan(
                                hash,
                                decision,
                                feedback,
                                {event => mailbox.push(event)}
                            )
                        }
                    )
                }
                turnOwnerSubagentId = focusedSubagentId
                if (focusedSubagentId == "") {
                    mainWorking = true
                }
                working = true
                UiReducer.reduce(ui, UiEvent.SetWorking(true))
                status = "reviewing plan"
                startAgentTurn(
                    {
                        =>
                            let result = backend.reviewPlan(
                                hash,
                                decision,
                                feedback,
                                {event => mailbox.push(event)}
                            )
                            mailbox.complete(result)
                            Event.Message("agent-turn")
                    }
                )
        }
    }

    private func applyTodoTransition(step: TodoTransition): UpdateResult {
        match (step.status) {
            case Some(value) => status = value
            case None => ()
        }
        match (step.effect) {
            case Some(TodoEffect.SaveMarkdown(markdown)) =>
                return startBackground(
                    "saving todo",
                    {
                        =>
                            let result = backend.saveTodoMarkdown(markdown)
                            TuiTurnResult(
                                "",
                                result.message,
                                action: TuiTurnAction.TodoSaved(result)
                            )
                    }
                )
            case None => ()
        }
        if (step.layoutChanged) {
            invalidateTodoLayout(step.update)
        } else {
            step.update
        }
    }

    private func syncPlanReviewStatus(result: UpdateResult): UpdateResult {
        if (!planReview.isActive()) {
            return result
        }
        mergeDirty(planReview.setStatusText(status), result)
    }

    private func submitComposer(delivery: String): UpdateResult {
        _ = composer.cancelCompletion()
        match (composerSlashInputError()) {
            case Some(message) =>
                status = message
                return dirtyComposer()
            case None => ()
        }
        match (composer.handle(KeyEvent(KeyCode.Enter))) {
            case Some(submit) => submitPrompt(submit.text, delivery: delivery)
            case None => dirtyComposer()
        }
    }

    private func handleInteractive(event: Event): UpdateResult {
        match (event) {
            case Event.KeyDown(key) => handleKeyDown(key)
            case Event.Mouse(mouse) =>
                if (planReview.isActive()) {
                    planReview.updateMouse(mouse)
                } else if (todos.isEditing()) {
                    applyTodoTransition(todos.updateMouse(mouse))
                } else if (ask.editorActive()) {
                    ask.updateMouse(mouse)
                } else if (modal.isSome()) {
                    handleModalMouse(mouse)
                } else {
                    handleMouse(mouse)
                }
            case Event.Paste(text) => handlePaste(text)
            case _ => UpdateResult.next()
        }
    }

    // Merges dirty rects from both results; flow/command come from `second`.
    private func mergeDirty(first: UpdateResult, second: UpdateResult): UpdateResult {
        var rects = match (first.dirtyRects) {
            case Some(existing) => existing.copy()
            case None => DirtyRects()
        }
        match (second.dirtyRects) {
            case Some(extra) => rects.addAll(extra)
            case None => ()
        }
        UpdateResult(
            flow: second.flow,
            command: second.command,
            dirtyRects: Some(rects)
        )
    }

    private func consumeMailboxViewportRefresh(result: UpdateResult): UpdateResult {
        if (!mailboxViewportRefresh) {
            return result
        }
        mailboxViewportRefresh = false
        modalRefreshOnly = false
        if (viewportArea.width > 0 && viewportArea.height > 0) {
            result.withDirty(viewportArea)
        } else {
            result
        }
    }

    func update(event: Event): UpdateResult {
        performanceBurstAppliedThisUpdate = 0
        let performanceBurstReadyEvent = performanceBurstActive && match (event) {
            case Event.Message("agent-external-ready") => true
            case _ => false
        }
        let pendingAction = drainMailbox()
        if (performanceBurstReadyEvent && performanceBurstAppliedThisUpdate > 0) {
            performanceBurstReadyMarkersProcessed++
        }
        let completingAgentTurn = match (event) {
            case Event.AsyncCompleted("agent-turn", _) | Event.AsyncFailed("agent-turn", _)
                | Event.AsyncCancelled("agent-turn") => true
            case _ => false
        }
        // Pending actions (modal selectors, session/tree loads) must be
        // applied before the mailbox-driven redraw so their UI (e.g. the
        // branch selector) actually appears.
        if (!completingAgentTurn) {
            match (pendingAction) {
                case Some(action) => match (event) {
                    case Event.KeyDown(_) | Event.Mouse(_) | Event.Paste(_) =>
                        // Interactive input wins over the queued action:
                        // apply the action for its UI side effects, then
                        // handle the key/mouse/paste, merging both redraws.
                        let actionResult = applyTurnAction(action)
                        let interactiveResult = handleInteractive(event)
                        // A modal-local input must not hide the background
                        // redraw required by the concurrently applied action.
                        modalRefreshOnly = false
                        return consumeMailboxViewportRefresh(mergeDirty(actionResult, interactiveResult))
                    case _ =>
                        var result = applyTurnAction(action)
                        if (mailboxChanged) {
                            result = result.withDirty(transcriptArea)
                        }
                        return consumeMailboxViewportRefresh(result)
                }
                case None => ()
            }
        }
        if (mailboxChanged && performanceBurstActive && !completingAgentTurn) {
            let burstRedraw = dirtyPerformanceBurstItem()
            match (event) {
                case Event.KeyDown(_) | Event.Mouse(_) | Event.Paste(_) =>
                    return mergeDirty(burstRedraw, handleInteractive(event))
                case _ => return burstRedraw
            }
        }
        if (mailboxChanged && !completingAgentTurn) {
            // New agent events (text deltas, tool cards, usage) must trigger a
            // redraw even without a pending approval: event-driven rendering
            // is what makes streaming text appear. Interactive events
            // (keyboard, mouse, paste) must NOT be swallowed here: while the
            // mailbox keeps draining, a key press (e.g. Ctrl+T collapsing
            // thinking) would otherwise be skipped entirely. Handle them and
            // merge the mailbox redraw so streaming text still updates.
            // Stream timers fall through too: while the mailbox is busy, a
            // swallowed tick would freeze the working spinner (elapsedMillis
            // never advances), making it look like the UI is stuck mid-think.
            match (event) {
                case Event.KeyDown(_) | Event.Mouse(_) | Event.Paste(_) =>
                    var mailboxRedraw = dirtyTranscriptAndActivity()
                    if (viewportArea.width > 0 && viewportArea.height > 0) {
                        mailboxRedraw = mailboxRedraw.withDirty(viewportArea)
                    }
                    let interactiveResult = handleInteractive(event)
                    // Streaming changes outside the overlay take precedence
                    // over its one-frame local redraw optimization.
                    modalRefreshOnly = false
                    return consumeMailboxViewportRefresh(mergeDirty(mailboxRedraw, interactiveResult))
                case Event.Timer(timer) =>
                    // Stream tick while the mailbox still holds events: the
                    // drain above already applied the deltas, so redraw the
                    // transcript now and keep the working spinner advancing.
                    // Without this, streaming text only appears on the next
                    // interactive event or at turn completion (event-driven
                    // rendering has no other wakeup).
                    if (timer.id == AGENT_STREAM_TIMER && (working || !runningSubagentIds.isEmpty())) {
                        workingElapsedMillis = timer.elapsedMillis
                        var result = dirtyTranscriptAndActivity()
                        if (agentHubActive && viewportArea.width > 0 && viewportArea.height > 0) {
                            result = result.withDirty(viewportArea)
                        }
                        if (hasAnimatedTranscriptCard() && transcriptArea.width > 0 && transcriptArea.height > 0) {
                            result = result.withDirty(transcriptArea)
                        }
                        if (workingArea.width > 0 && workingArea.height > 0) {
                            result = result.withDirty(workingArea)
                        }
                        return consumeMailboxViewportRefresh(result)
                    }
                    return consumeMailboxViewportRefresh(dirtyTranscriptAndActivity())
                case _ =>
                    var result = dirtyTranscriptAndActivity()
                    if (viewportArea.width > 0 && viewportArea.height > 0) {
                        result = result.withDirty(viewportArea)
                    }
                    return consumeMailboxViewportRefresh(result)
            }
        }
        match (event) {
            case Event.AsyncCompleted("agent-turn", _) => settleStreamingCards(
                if (status == "error" || status == "failed" || status == "rejected") {
                    "failed"
                } else if (status == "cancelled") {
                    "cancelled"
                } else {
                    "completed"
                })
            case Event.AsyncFailed("agent-turn", _) => settleStreamingCards("failed")
            case Event.AsyncCancelled("agent-turn") => settleStreamingCards("cancelled")
            case _ => ()
        }
        if (planReview.hasPending()) {
            match (event) {
                case Event.AsyncCompleted("agent-turn", _) => if (pendingAction.isNone()) {
                    _ = planReview.completeWithoutResult()
                    status = planReview.statusText()
                }
                case Event.AsyncFailed("agent-turn", _) =>
                    _ = planReview.failAgentTurn()
                    status = planReview.statusText()
                case Event.AsyncCancelled("agent-turn") =>
                    _ = planReview.cancelAgentTurn()
                    status = planReview.statusText()
                case _ => ()
            }
        }
        if (!completingAgentTurn) {
            match (pendingAction) {
                case Some(action) => return applyTurnAction(action)
                case None => ()
            }
        }
        if (!draftLoadStarted && !setupRequired && initialPrompt == "") {
            match (event) {
                case Event.Capabilities(caps) =>
                    terminalUnicode = caps.unicode && !asciiRailRequested()
                    match (virtualTranscriptView) {
                        case Some(view) => view.setUnicode(terminalUnicode)
                        case None => ()
                    }
                    match (virtualTranscriptSource) {
                        case Some(source) => source.unicode = terminalUnicode
                        case None => ()
                    }
                    draftLoadStarted = true
                    return startBackground("loading session", {
                        => TuiTurnResult(
                            "",
                            "ready",
                            action: TuiTurnAction.DraftLoaded(backend.draft())
                        )
                    })
                case Event.Tick(_) =>
                    draftLoadStarted = true
                    return startBackground("loading session", {
                        => TuiTurnResult(
                            "",
                            "ready",
                            action: TuiTurnAction.DraftLoaded(backend.draft())
                        )
                    })
                case _ => ()
            }
        }
        if (!initialSubmitted && !setupRequired) {
            match (event) {
                case Event.Tick(_) =>
                    initialSubmitted = true
                    return submitPrompt(initialPrompt)
                case _ => ()
            }
        }
        match (event) {
            case Event.KeyDown(key) => handleKeyDown(key)
            case Event.Mouse(mouse) => if (planReview.isActive()) {
                planReview.updateMouse(mouse)
            } else if (todos.isEditing()) {
                applyTodoTransition(todos.updateMouse(mouse))
            } else if (ask.editorActive()) {
                ask.updateMouse(mouse)
            } else {
                handleMouse(mouse)
            }
            case Event.Paste(text) => handlePaste(text)
            case Event.Capabilities(caps) =>
                terminalUnicode = caps.unicode && !asciiRailRequested()
                match (virtualTranscriptView) {
                    case Some(view) => view.setUnicode(terminalUnicode)
                    case None => ()
                }
                match (virtualTranscriptSource) {
                    case Some(source) => source.unicode = terminalUnicode
                    case None => ()
                }
                dirtyTranscriptAndActivity()
            case Event.Resize(_) => UpdateResult.next()
            case Event.Timer(timer) =>
                if (timer.id == PERF_STREAM_TIMER && performanceStreamRemaining > 0) {
                    let chunkIndex = tuiPerformanceStreamChunks() - performanceStreamRemaining
                    acceptAgentEvent(
                        TuiAgentEvent.TextDelta(
                            "stream ${chunkIndex} · 中文 🧭 wide 界 · \u{1b}[36mANSI\u{1b}[0m\n"
                        )
                    )
                    performanceStreamRemaining--
                    if (performanceStreamRemaining == 0) {
                        return UpdateResult(
                            command: Command.StopTimer(PERF_STREAM_TIMER),
                            dirtyRects: Some(DirtyRects.full(viewportArea))
                        )
                    }
                    return dirtyTranscriptAndActivity()
                }
                if (timer.id == AGENT_STREAM_TIMER && ask.isActive()) {
                    // AskRuntime still owns the live turn, but it is waiting
                    // on the user rather than doing autonomous work. Keep the
                    // timer alive so execution resumes without a restart,
                    // while avoiding an idle activity redraw every tick.
                    return UpdateResult.unchanged()
                }
                if (timer.id == AGENT_STREAM_TIMER && (working || !runningSubagentIds.isEmpty())) {
                    workingElapsedMillis = timer.elapsedMillis
                    var result = UpdateResult.next()
                    if (agentHubActive && mailboxChanged && viewportArea.width > 0 && viewportArea.height > 0) {
                        result = result.withDirty(viewportArea)
                    }
                    if (hasAnimatedTranscriptCard() && transcriptArea.width > 0 && transcriptArea.height > 0) {
                        result = result.withDirty(transcriptArea)
                    }
                    if (workingArea.width > 0 && workingArea.height > 0) {
                        result = result.withDirty(workingArea)
                    }
                    return result
                }
                if (timer.id == AGENT_STREAM_TIMER && !working && runningSubagentIds.isEmpty()) {
                    return UpdateResult.withCommand(Command.StopTimer(AGENT_STREAM_TIMER))
                }
                UpdateResult.next()
            case Event.AsyncCompleted("agent-turn", _) | Event.AsyncFailed("agent-turn", _)
                | Event.AsyncCancelled("agent-turn") =>
                if (turnOwnerSubagentId == "") {
                    mainWorking = false
                }
                if (turnOwnerSubagentId == focusedSubagentId) {
                    working = false
                    UiReducer.reduce(ui, UiEvent.SetWorking(false))
                }
                turnOwnerSubagentId = ""
                let todoChanged = refreshTodoSnapshot()
                var result = match (pendingAction) {
                    case Some(action) => applyTurnAction(action)
                    case None => match (drainMailbox()) {
                        case Some(action) => applyTurnAction(action)
                        case None => UpdateResult.next()
                    }
                }
                if (todoChanged) {
                    result = invalidateTodoLayout(result)
                }
                let settled = if (runningSubagentIds.isEmpty()) {
                    stopAgentStream(result)
                } else {
                    result
                }
                consumeMailboxViewportRefresh(settled)
            case Event.AsyncCompleted(id, inner) =>
                if (id.startsWith("tui-background-")) {
                    update(inner)
                } else {
                    UpdateResult.next()
                }
            case Event.Message(message) =>
                if (message.startsWith("queue-queued:")) {
                    let id = message[13..]
                    var kind = "steer"
                    for (queued in queuedPrompts where queued.id == id) {
                        kind = queued.kind
                    }
                    status = if (kind == "follow_up") {
                        "after-yield input queued"
                    } else {
                        "steering input queued"
                    }
                } else if (message.startsWith("queue-failed:")) {
                    let id = message[13..]
                    match (removeQueuedPrompt(id)) {
                        case Some(queued) => restoreQueuedText(queued.text)
                        case None => ()
                    }
                    status = "cannot queue input"
                    addErrorCard(
                        "Error",
                        "cannot queue input: the agent is not accepting input right now"
                    )
                    return dirtyComposerAndQueue()
                } else if (message.startsWith("queue-withdrawal:")) {
                    return completeQueueWithdrawal(message[17..])
                } else if (message == "cancel requested") {
                    status = message
                }
                dirtyComposerAndQueue()
            case _ => UpdateResult.next()
        }
    }

    private func backgroundTask(
        label: String,
        task: () -> Event
    ): UpdateResult {
        backgroundSequence += 1
        UpdateResult.withCommand(
            Command.AsyncTask(
                "tui-background-" + label + "-" + backgroundSequence.toString(),
                task
            )
        )
    }

    private func activeApprovalOperationId(): String {
        match (ui.approvalId) {
            case Some(id) =>
                if (id.startsWith("approval-")) {
                    id[9..]
                } else {
                    id
                }
            case None => ""
        }
    }

    private func updateApproval(key: KeyEvent): UpdateResult {
        match (key.code) {
            case KeyCode.CtrlC => cancelApprovalInteraction(true)
            case KeyCode.PageUp => scrollTranscriptBy(transcriptPageSize())
            case KeyCode.PageDown => scrollTranscriptBy(-transcriptPageSize())
            case KeyCode.Home =>
                if (key.modifiers.ctrl) {
                    scrollTranscriptToTop()
                } else {
                    match (composer.handle(key)) {
                        case Some(_) => UpdateResult.next()
                        case None => dirtyComposer()
                    }
                }
            case KeyCode.End =>
                if (key.modifiers.ctrl) {
                    scrollOffset = 0
                    clearScrollAnchor()
                    dirtyTranscriptAndActivity()
                } else {
                    match (composer.handle(key)) {
                        case Some(_) => UpdateResult.next()
                        case None => dirtyComposer()
                    }
                }
            case KeyCode.Left | KeyCode.Up =>
                approvalSelected = max(0, approvalSelected - 1)
                UpdateResult.next()
            case KeyCode.Right | KeyCode.Down =>
                approvalSelected = min(2, approvalSelected + 1)
                UpdateResult.next()
            case KeyCode.Enter =>
                if (working) {
                    status = "waiting for approval request to settle"
                    return UpdateResult.next()
                }
                let rejecting = approvalSelected == 2
                let decision = match (approvalSelected) {
                    case 0 => TuiApprovalDecision.AllowOnce
                    case 1 => TuiApprovalDecision.AllowSession
                    case _ => TuiApprovalDecision.Reject(composer.area.value.trimAscii())
                }
                let state = match (approvalSelected) {
                    case 0 => "approved-once"
                    case 1 => "approved-session"
                    case _ => "rejected"
                }
                match (ui.approvalId) {
                    case Some(id) =>
                        UiReducer.reduce(
                            ui,
                            UiEvent.SetCardState(
                                id,
                                state,
                                if (approvalSelected == 2 && composer.area.value.trimAscii() != "") {
                                    "rejected: " + composer.area.value.trimAscii()
                                } else {
                                    state
                                },
                                false
                            )
                        )
                        for (card in ui.cards where card.id == id) {
                            card.footer = match (approvalSelected) {
                                case 0 => "allowed once"
                                case 1 => approvalSessionLabel
                                case _ => "rejected"
                            }
                        }
                    case None => ()
                }
                let operationId = activeApprovalOperationId()
                if (approvalToolCardId != "") {
                    UiReducer.reduce(
                        ui,
                        UiEvent.SetCardState(
                            approvalToolCardId,
                            "running",
                            "resuming after approval",
                            false
                        )
                    )
                }
                UiReducer.reduce(ui, UiEvent.ClearApproval)
                approvalInspectBody = ""
                approvalToolCardId = ""
                approvalSelected = 0
                if (rejecting) {
                    composer.area.setValue("")
                }
                working = true
                UiReducer.reduce(ui, UiEvent.SetWorking(true))
                status = "resuming"
                startAgentTurn(
                    {
                        =>
                            let result = backend.decide(
                                operationId,
                                decision,
                                {value => mailbox.push(value)}
                            )
                            mailbox.complete(result)
                            Event.Message("agent-turn")
                    }
                )
            case KeyCode.Char(r'e') =>
                if (approvalInspectBody == "") {
                    status = "no additional approval details"
                    UpdateResult.next()
                } else {
                    applyTurnAction(TuiTurnAction.OpenDocument(approvalInspectTitle, approvalInspectBody))
                }
            case KeyCode.Esc => cancelApprovalInteraction(false)
            case _ => match (composer.handle(key)) {
                case Some(_) =>
                    status = "choose an approval action before sending"
                    UpdateResult.next()
                case None => dirtyComposer()
            }
        }
    }

    private func cancelApprovalInteraction(armExit: Bool): UpdateResult {
        match (ui.approvalId) {
            case Some(id) => UiReducer.reduce(
                ui,
                UiEvent.SetCardState(
                    id,
                    "cancelled",
                    "approval cancelled",
                    false
                )
            )
            case None => ()
        }
        if (approvalToolCardId != "") {
            UiReducer.reduce(
                ui,
                UiEvent.SetCardState(
                    approvalToolCardId,
                    "cancelled",
                    "cancelled before execution",
                    false
                )
            )
        }
        UiReducer.reduce(ui, UiEvent.ClearApproval)
        approvalSelected = 0
        approvalInspectBody = ""
        approvalToolCardId = ""
        mainWorking = false
        working = false
        UiReducer.reduce(ui, UiEvent.SetWorking(false))
        idleCtrlCArmed = armExit
        status = if (armExit) {
            "approval cancelled · Ctrl+C again to exit"
        } else {
            "approval cancelled"
        }
        backgroundTask(
            "cancel-approval",
            {
                =>
                    backend.cancel()
                    Event.Message("approval cancelled")
            }
        )
    }

    private func dirtyComposer(): UpdateResult {
        dirtyComposerWithScope(false)
    }

    private func dirtyComposerContent(): UpdateResult {
        dirtyComposerWithScope(true)
    }

    private func dirtyComposerWithScope(contentOnly: Bool): UpdateResult {
        composerHeightBeforePaint = composerHeight
        let todoRows = todos.stripRowCount(
            viewportArea.width,
            viewportHeight,
            queuedPromptRows()
        )
        let desired = if (secretSetupEntry()) {
            1
        } else {
            composer.visualHeight(
                max(1, composerArea.width - 4),
                composerMaximumHeight(
                    viewportHeight,
                    queuedRows: queuedPromptRows(),
                    todoRows: todoRows
                )
            )
        }
        if (desired != composerHeight) {
            composerHeight = desired
            composerHeightAfterPaint = composerHeight
            if (viewportArea.width > 0 && viewportArea.height > 0) {
                return UpdateResult.dirty(viewportArea)
            }
            return UpdateResult.next()
        }
        composerHeightAfterPaint = composerHeight
        let narrowContentSafe = contentOnly && desired == 1 &&
            !composer.completionVisible() && composer.lastError.isNone() &&
            !composer.area.value.contains("\n") &&
            displayWidth(composer.area.value) <= composerInputArea.width
        if (narrowContentSafe && composerInputArea.width > 0 && composerInputArea.height > 0) {
            return UpdateResult.dirty(composerInputArea)
        }
        if (composerArea.width > 0 && composerArea.height > 0) {
            return UpdateResult.dirty(composerArea)
        }
        UpdateResult.next()
    }

    private func dirtyComposerAndQueue(): UpdateResult {
        var result = dirtyComposer()
        if (queuedArea.width > 0 && queuedArea.height > 0) {
            result = result.withDirty(queuedArea)
        }
        if (workingArea.width > 0 && workingArea.height > 0) {
            result = result.withDirty(workingArea)
        }
        result
    }

    private func frameDirtyCellCount(frame: Frame, area: Rect): Int64 {
        var cells: Int64 = 0
        for (dirty in frame.dirtyRects()) {
            let left = max(dirty.x, area.x)
            let top = max(dirty.y, area.y)
            let right = min(dirty.right, area.right)
            let bottom = min(dirty.bottom, area.bottom)
            cells += max(0, right - left) * max(0, bottom - top)
        }
        cells
    }

    private func refreshTodoSnapshot(): Bool {
        todos.applySnapshot(backend.todoMarkdown()).update.renderRequested
    }

    private func invalidateTodoLayout(result: UpdateResult): UpdateResult {
        if (viewportArea.width > 0 && viewportArea.height > 0) {
            result.withDirty(viewportArea)
        } else {
            result
        }
    }

    private func transcriptPageSize(): Int64 {
        max(1, transcriptVisibleLines - 1)
    }

    private func maximumTranscriptScroll(): Int64 {
        max(0, transcriptTotalLines - transcriptVisibleLines)
    }

    private func clearScrollAnchor(): Unit {
        match (virtualTranscriptView) {
            case Some(view) =>
                view.state.anchorId = ""
                view.state.anchorRow = 0
            case None => ()
        }
    }

    private func scrollTranscriptBy(delta: Int64): UpdateResult {
        let previousOffset = scrollOffset
        scrollOffset = min(
            maximumTranscriptScroll(),
            max(0, scrollOffset + delta)
        )
        if (scrollOffset == previousOffset) {
            return UpdateResult.unchanged()
        }
        match (virtualTranscriptView) {
            case Some(view) =>
                let total = view.totalRows()
                let viewport = max(1, transcriptVisibleLines)
                if (scrollOffset <= 0) {
                    view.state.end(total, viewport)
                    newTranscriptLines = 0
                } else {
                    view.state.followBottom = false
                    view.state.scrollTop = min(
                        max(0, view.state.scrollTop - delta),
                        max(0, total - viewport)
                    )
                }
            case None =>
                if (scrollOffset <= 0) {
                    newTranscriptLines = 0
                }
        }
        let loadedOlder = delta > 0 && scrollOffset >= maximumTranscriptScroll() &&
            loadOlderMainTranscriptPage()
        if (!loadedOlder) { clearScrollAnchor() }
        dirtyTranscriptAndActivity()
    }

    private func loadOlderMainTranscriptPage(): Bool {
        if (focusedSubagentId != "" || !mainTranscriptHasMore || mainTranscriptBeforeOrdinal <= 0) {
            return false
        }
        let page = backend.loadMainTranscriptPage(mainTranscriptBeforeOrdinal, 512)
        if (page.items.isEmpty()) {
            mainTranscriptBeforeOrdinal = page.nextBeforeOrdinal
            mainTranscriptHasMore = page.hasMore
            return false
        }

        let previousFirstId = if (ui.cards.isEmpty()) { "" } else { ui.cards[0].id }
        let next = prependTranscriptPage(ui, page)
        ui = next
        mainTranscriptBeforeOrdinal = page.nextBeforeOrdinal
        mainTranscriptHasMore = page.hasMore
        configuredCardViewport = -1
        configuredCardViewportCount = 0
        markdownCache.clear()
        match (virtualTranscriptSource) {
            case Some(source) => source.setSnapshot(next)
            case None => ()
        }
        match (virtualTranscriptView) {
            case Some(view) =>
                view.state.followBottom = false
                view.state.anchorId = previousFirstId
                view.state.anchorRow = 0
                view.lastVisibleRanges.clear()
            case None => ()
        }
        true
    }

    private func scrollTranscriptToTop(): UpdateResult {
        scrollOffset = maximumTranscriptScroll()
        match (virtualTranscriptView) {
            case Some(view) => view.state.home()
            case None => ()
        }
        clearScrollAnchor()
        dirtyTranscriptAndActivity()
    }

    private func dirtyTranscriptAndActivity(): UpdateResult {
        var result = UpdateResult.next()
        if (transcriptArea.width > 0 && transcriptArea.height > 0) {
            result = result.withDirty(transcriptArea)
        }
        if (workingArea.width > 0 && workingArea.height > 0) {
            result = result.withDirty(workingArea)
        }
        if (queuedArea.width > 0 && queuedArea.height > 0) {
            result = result.withDirty(queuedArea)
        }
        result
    }

    private func dirtyTranscript(): UpdateResult {
        if (transcriptArea.width > 0 && transcriptArea.height > 0) {
            UpdateResult.dirty(transcriptArea)
        } else {
            UpdateResult.next()
        }
    }

    // Specialized VirtualTranscript fast path for an existing item whose
    // source index/order is unchanged. The view owns derived visible geometry;
    // application business state remains solely in UiSnapshot.
    private func dirtyTranscriptItem(id: String): UpdateResult {
        match (virtualTranscriptView) {
            case Some(view) => match (view.dirtyRectForItemRevision(id)) {
                case Some(rect) => if (rect.width > 0 && rect.height > 0) {
                    UpdateResult.dirty(rect)
                } else {
                    UpdateResult.unchanged()
                }
                case None => UpdateResult.unchanged()
            }
            case None => dirtyTranscript()
        }
    }

    private func startPerformanceSameHeightBurst(): UpdateResult {
        if (performanceBurstActive) { return UpdateResult.unchanged() }
        let expectedTokens: Int64 = 60
        let intervalMillis = tuiSameHeightBurstIntervalMillis()
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard(
                assistantCardId(),
                UiCardKind.Assistant,
                "Assistant",
                "same-height burst: ",
                "streaming",
                false,
                ""
            )
        )
        performanceBurstActive = true
        performanceBurstAppliedThisUpdate = 0
        performanceBurstAppliedTotal = 0
        performanceBurstReadyMarkersProcessed = 0
        performanceBurstInitialRect = None
        performanceBurstPreviousHeight = -1
        performanceBurstInitialVisibleSignature = ""
        performanceBurstExternalAcceptedBaseline = externalPort.acceptedCount()
        performanceBurstExternalFullBaseline = externalPort.fullCount()
        performanceBurstWakeSignalsBaseline = externalPort.wakeSignals()
        match (performanceTrace) {
            case Some(trace) => trace.burstProofStarted(expectedTokens, intervalMillis)
            case None => ()
        }
        _ = spawn {
            // Establish the target's initial visible bounds before the real
            // producer publishes through mailbox -> ExternalPort.
            sleep(Duration.millisecond * 50)
            for (_ in 0..expectedTokens) {
                mailbox.push(TuiAgentEvent.TextDelta("x"))
                if (intervalMillis > 0) {
                    sleep(Duration.millisecond * intervalMillis)
                }
            }
        }
        dirtyTranscript()
    }

    private func performanceVisibleSignature(view: VirtualTranscriptView): String {
        let value = StringBuilder()
        for (range in view.lastVisibleRanges) {
            value.append(range.id)
            value.append(":")
            value.append(range.top.toString())
            value.append(":")
            value.append(range.bottom.toString())
            value.append(";")
        }
        value.toString()
    }

    private func dirtyPerformanceBurstItem(): UpdateResult {
        match (virtualTranscriptView) {
            case Some(view) =>
                let signature = performanceVisibleSignature(view)
                match (view.dirtyRectForItemRevision(assistantCardId())) {
                    case Some(rect) =>
                        let before = if (performanceBurstPreviousHeight < 0) {
                            rect.height
                        } else {
                            performanceBurstPreviousHeight
                        }
                        let initialRect = match (performanceBurstInitialRect) {
                            case Some(value) => value
                            case None =>
                                performanceBurstInitialRect = Some(rect)
                                rect
                        }
                        if (performanceBurstInitialVisibleSignature == "") {
                            performanceBurstInitialVisibleSignature = signature
                        }
                        let boundsStable = rect == initialRect
                        let mappingStable = signature == performanceBurstInitialVisibleSignature
                        let precise = rect != transcriptArea
                        performanceBurstPreviousHeight = rect.height
                        match (performanceTrace) {
                            case Some(trace) => trace.burstProofUpdate(
                                performanceBurstAppliedThisUpdate,
                                performanceBurstAppliedTotal,
                                performanceBurstReadyMarkersProcessed,
                                before,
                                rect.height,
                                boundsStable,
                                mappingStable,
                                view.state.followBottom,
                                precise,
                                externalPort.acceptedCount() - performanceBurstExternalAcceptedBaseline,
                                externalPort.fullCount() - performanceBurstExternalFullBaseline,
                                externalPort.wakeSignals() - performanceBurstWakeSignalsBaseline
                            )
                            case None => ()
                        }
                        if (rect.width > 0 && rect.height > 0) {
                            UpdateResult.dirty(rect)
                        } else {
                            UpdateResult.unchanged()
                        }
                    case None =>
                        match (performanceTrace) {
                            case Some(trace) => trace.burstProofUpdate(
                                performanceBurstAppliedThisUpdate,
                                performanceBurstAppliedTotal,
                                performanceBurstReadyMarkersProcessed,
                                performanceBurstPreviousHeight,
                                -1,
                                false,
                                false,
                                view.state.followBottom,
                                false,
                                externalPort.acceptedCount() - performanceBurstExternalAcceptedBaseline,
                                externalPort.fullCount() - performanceBurstExternalFullBaseline,
                                externalPort.wakeSignals() - performanceBurstWakeSignalsBaseline
                            )
                            case None => ()
                        }
                        UpdateResult.unchanged()
                }
            case None => dirtyTranscript()
        }
    }

    private func configureCardBodyViewports(cardViewport: Int64): Unit {
        var start = configuredCardViewportCount
        if (configuredCardViewport != cardViewport || configuredCardViewportCount > ui.cards.size) {
            start = 0
        }
        for (index in start..ui.cards.size) {
            let card = ui.cards[index]
            if (card.kind == UiCardKind.Assistant || card.kind == UiCardKind.User || card.kind == UiCardKind.Reasoning) {
                continue
            }
            if (card.bodyViewport != cardViewport) {
                card.bodyViewport = cardViewport
                card.markViewChanged()
            }
            let maximum = max(0, card.bodyLines() - cardViewport)
            let boundedScroll = min(card.bodyScroll, maximum)
            if (card.bodyScroll != boundedScroll) {
                card.bodyScroll = boundedScroll
                card.markViewChanged()
            }
        }
        configuredCardViewport = cardViewport
        configuredCardViewportCount = ui.cards.size
    }

    private func removeQueuedPrompt(id: String): ?QueuedPrompt {
        for (index in 0..queuedPrompts.size where queuedPrompts[index].id == id) {
            let queued = queuedPrompts[index]
            queuedPrompts.remove(at: index)
            return Some(queued)
        }
        None
    }

    private func queuedPromptCount(kind: String): Int64 {
        var count: Int64 = 0
        for (queued in queuedPrompts where queued.kind == kind) {
            count++
        }
        count
    }

    private func queuedPromptRows(): Int64 {
        (if (queuedPromptCount("steer") > 0) { 1 } else { 0 }) +
            (if (queuedPromptCount("follow_up") > 0) { 1 } else { 0 })
    }

    private func queuedPromptLabel(kind: String, width: Int64): String {
        let count = queuedPromptCount(kind)
        if (count == 0) {
            return ""
        }
        let label = if (kind == "follow_up") {
            "After yield"
        } else {
            "Steering"
        }
        let previews = ArrayList<String>()
        for (queued in queuedPrompts where queued.kind == kind) {
            previews.add(queued.text.replace("\n", " ↵ "))
        }
        var detail = ""
        if (width < 72) {
            detail = previews[previews.size - 1]
        } else {
            for (preview in previews) {
                if (detail != "") { detail += " · " }
                detail += preview
            }
        }
        label + " · " + count.toString() + " · " + detail
    }

    private func restoreQueuedText(text: String): Unit {
        _ = composer.cancelCompletion()
        let current = composer.area.value
        if (current == "") {
            composer.area.setValue(text, cursor: text.size)
        } else {
            composer.area.setValue(text + "\n\n" + current, cursor: text.size)
        }
    }

    private func storeQueueWithdrawal(id: String, result: TuiQueueWithdrawal): Unit {
        queueWithdrawalLock.lock()
        try {
            completedQueueWithdrawals.add(CompletedQueueWithdrawal(id, result))
        } finally {
            queueWithdrawalLock.unlock()
        }
    }

    private func takeQueueWithdrawal(id: String): ?TuiQueueWithdrawal {
        queueWithdrawalLock.lock()
        try {
            for (index in 0..completedQueueWithdrawals.size where completedQueueWithdrawals[index].id == id) {
                let result = completedQueueWithdrawals[index].result
                completedQueueWithdrawals.remove(at: index)
                return Some(result)
            }
            None
        } finally {
            queueWithdrawalLock.unlock()
        }
    }

    private func withdrawLatestQueued(): UpdateResult {
        _ = composer.cancelCompletion()
        if (queuedPrompts.isEmpty()) {
            status = "no pending input to edit"
            return dirtyComposerAndQueue()
        }
        if (withdrawalInFlightId != "") {
            status = "withdrawing pending input"
            return dirtyComposerAndQueue()
        }
        let target = queuedPrompts[queuedPrompts.size - 1]
        withdrawalInFlightId = target.id
        status = "withdrawing pending input"
        return backgroundTask("withdraw", {
            =>
                storeQueueWithdrawal(target.id, backend.withdrawQueued(target.id))
                Event.Message("queue-withdrawal:" + target.id)
        })
    }

    private func completeQueueWithdrawal(id: String): UpdateResult {
        if (withdrawalInFlightId == id) {
            withdrawalInFlightId = ""
        }
        match (takeQueueWithdrawal(id)) {
            case Some(TuiQueueWithdrawal.Withdrawn(kind, text)) =>
                let _ = removeQueuedPrompt(id)
                restoreQueuedText(text)
                status = if (kind == "follow_up") {
                    "after-yield input restored"
                } else {
                    "steering input restored"
                }
            case Some(TuiQueueWithdrawal.AlreadyDelivered) =>
                let _ = removeQueuedPrompt(id)
                status = "pending input already delivered"
            case Some(TuiQueueWithdrawal.Failed(message)) => status = "cannot withdraw pending input: " + message
            case None => status = "cannot resolve pending input withdrawal"
        }
        dirtyComposerAndQueue()
    }

    private func transcriptScrollLabel(): String {
        if (scrollOffset <= 0 || transcriptTotalLines <= transcriptVisibleLines) {
            return ""
        }
        let first = transcriptStartLine + 1
        let last = min(
            transcriptTotalLines,
            transcriptStartLine + transcriptVisibleLines
        )
        "↑ " + first.toString() + "–" + last.toString() + "/" + transcriptTotalLines.toString() + (if (newTranscriptLines >
            0) {
            " · ↓ " + newTranscriptLines.toString() + " new lines"
        } else {
            ""
        }) + " · Ctrl+End latest"
    }

    private func startBackground(
        label: String,
        task: () -> TuiTurnResult
    ): UpdateResult {
        if (headless()) {
            mailbox.complete(task())
            return match (drainMailbox()) {
                case Some(action) => applyTurnAction(action)
                case None => UpdateResult.next()
            }
        }
        turnOwnerSubagentId = focusedSubagentId
        if (focusedSubagentId == "") {
            mainWorking = true
        }
        working = true
        workingElapsedMillis = 0
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        status = label
        startAgentTurn(
            {
                =>
                    mailbox.complete(task())
                    Event.Message("agent-turn")
            }
        )
    }

    private func selectTheme(name: String): UpdateResult {
        closeModal(keepStatus: true)
        startBackground(
            "switching theme",
            {
                =>
                    let ok = backend.selectTheme(name)
                    let definitions = backend.customThemes()
                    TuiTurnResult(
                        "",
                        if (ok) {
                            "theme: " + name
                        } else {
                            "theme selection failed"
                        },
                        action: TuiTurnAction.ThemeSelected(name, ok, definitions)
                    )
            }
        )
    }

    private func submitPrompt(raw: String, delivery!: String = "normal"): UpdateResult {
        let prompt = raw.trimAscii()
        if (prompt == "") {
            return UpdateResult.next()
        }
        if (prompt == "/theme") {
            customThemeDefinitions = backend.customThemes()
            return openModal(
                TuiModalKind.Theme,
                themeNames(customThemeDefinitions, themeName)
            )
        }
        if (prompt.startsWith("/theme ")) {
            let requested = prompt[7..].trimAscii().toAsciiLower()
            if (requested == "") {
                status = "usage: /theme [name]"
                return UpdateResult.next()
            }
            return selectTheme(requested)
        }
        if (setupDraft.isSome()) {
            return continueSetup(prompt)
        }
        if (prompt == "/cancel") {
            status = "cancelling"
            return backgroundTask(
                "cancel",
                {
                    =>
                        backend.cancel()
                        Event.Message("cancel requested")
                }
            )
        }
        if (working) {
            if (prompt.startsWith("/")) {
                status = "finish or cancel the active turn before commands"
                return UpdateResult.next()
            }
            let kind = if (delivery == "follow_up") {
                "follow_up"
            } else {
                "steer"
            }
            let queuedId = nextCardId(kind)
            queuedPrompts.add(QueuedPrompt(queuedId, kind, prompt))
            status = if (kind == "follow_up") {
                "queueing after-yield input"
            } else {
                "queueing steering input"
            }
            return backgroundTask(kind, {
                =>
                    let accepted = if (kind == "follow_up") {
                    backend.followUp(queuedId, prompt)
                } else {
                    backend.steer(queuedId, prompt)
                }
                    Event.Message(if (accepted) {
                        "queue-queued:" + queuedId
                    } else {
                        "queue-failed:" + queuedId
                    })
            })
        }
        if (prompt == "/model") {
            return startBackground("loading models", {
                => TuiTurnResult(
                    "",
                    "select model",
                    action: TuiTurnAction.ModelsLoaded(backend.models())
                )
            })
        }
        if (prompt == "/todo edit") {
            return startBackground("loading todo", {
                => TuiTurnResult(
                    "",
                    "todo loaded",
                    action: TuiTurnAction.TodoLoaded(backend.todoMarkdown())
                )
            })
        }
        if (prompt == "/todo copy") {
            return startBackground(
                "copying todo",
                {
                    =>
                        let value = backend.copyTodoMarkdown()
                        TuiTurnResult(
                            "",
                            value,
                            action: TuiTurnAction.UiStatus(value)
                        )
                }
            )
        }
        if (prompt == "/session") {
            sessionShowArchived = false
            sessionFilter = ""
            return startBackground("loading sessions", {
                => TuiTurnResult(
                    "",
                    "select session",
                    action: TuiTurnAction.SessionsLoaded(backend.sessions(false))
                )
            })
        }
        if (prompt.startsWith("/session ")) {
            let id = prompt[9..].trimAscii()
            if (id == "" || id.contains(" ")) {
                status = "usage: /session [session-id]"
                return UpdateResult.next()
            }
            return match (draftForSessionSwitch()) {
                case Some(draft) => switchSessionInBackground(id, id, draft)
                case None => UpdateResult.next()
            }
        }
        if (prompt == "/agents") {
            return openAgentHub()
        }
        if (prompt.startsWith("/agent ")) {
            let id = prompt[7..].trimAscii()
            if (id == "") {
                status = "usage: /agent <subagent-id>"
                return UpdateResult.next()
            }
            status = "switching to " + id
            return backgroundTask(
                "focus-subagent",
                {
                    =>
                        mailbox.complete(
                            TuiTurnResult(
                                "",
                                "subagent " + id,
                                action: TuiTurnAction.ConversationFocused(backend.focusSubagent(id))
                            )
                        )
                        Event.Message("subagent focused")
                }
            )
        }
        if (prompt == "/tree") {
            sessionShowArchived = false
            sessionFilter = ""
            return startBackground("loading sessions", {
                => TuiTurnResult(
                    "",
                    "select session",
                    action: TuiTurnAction.SessionsLoaded(backend.sessions(false))
                )
            })
        }
        if (prompt == "/extensions") {
            return startBackground("loading extensions", {
                => TuiTurnResult(
                    "",
                    "extensions",
                    action: TuiTurnAction.ExtensionsLoaded(backend.extensions())
                )
            })
        }
        if (prompt == "/settings") {
            return openModal(
                TuiModalKind.Settings,
                ["Model", "Theme", "Session", "Archive/reset", "Close"]
            )
        }
        if (prompt == "/approve" || prompt == "/approve-session" || prompt.startsWith("/reject")) {
            if (working) {
                status = "wait for the active turn before deciding"
                return UpdateResult.next()
            }
            let decision = if (prompt == "/approve") {
                TuiApprovalDecision.AllowOnce
            } else if (prompt == "/approve-session") {
                TuiApprovalDecision.AllowSession
            } else {
                TuiApprovalDecision.Reject(rejectReason(prompt))
            }
            working = true
            UiReducer.reduce(ui, UiEvent.SetWorking(true))
            status = "resuming"
            let operationId = activeApprovalOperationId()
            return startAgentTurn(
                {
                    =>
                        let result = backend.decide(
                            operationId,
                            decision,
                            {value => mailbox.push(value)}
                        )
                        mailbox.complete(result)
                        Event.Message("agent-turn")
                }
            )
        }
        taskLabel = prompt
        addCard(UiCardKind.User, "You", prompt)
        scrollOffset = 0
        turnSequence += 1
        modelRoundSequence = 0
        activeToolCardId = ""
        turnOwnerSubagentId = focusedSubagentId
        if (focusedSubagentId == "") {
            mainWorking = true
        }
        working = true
        workingElapsedMillis = 0
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        status = "working"
        startAgentTurn(
            {
                =>
                    let _ = backend.saveDraft("")
                    let result = backend.submit(
                        prompt,
                        {value => mailbox.push(value)}
                    )
                    mailbox.complete(result)
                    Event.Message("agent-turn")
            }
        )
    }

    private func openAgentHub(): UpdateResult {
        applyTurnAction(TuiTurnAction.SubagentsLoaded(backend.subagents()))
    }

    private func updateAgentHub(key: KeyEvent): UpdateResult {
        match (key.code) {
            case KeyCode.Esc | KeyCode.Left =>
                agentHubActive = false
                status = if (focusedSubagentId == "") {
                    "ready"
                } else {
                    "subagent " + focusedSubagentId
                }
                refreshViewport()
            case KeyCode.Up | KeyCode.Char(r'k') =>
                modalSelected = max(0, modalSelected - 1)
                refreshViewport()
            case KeyCode.Down | KeyCode.Char(r'j') =>
                modalSelected = min(
                    subagentItems.size,
                    modalSelected + 1
                )
                refreshViewport()
            case KeyCode.Enter =>
                agentHubActive = false
                if (modalSelected == 0) {
                    return focusMainConversation()
                }
                let selected = subagentItems[modalSelected - 1]
                status = "switching to " + selected.id
                backgroundTask(
                    "focus-subagent",
                    {
                        =>
                            mailbox.complete(
                                TuiTurnResult(
                                    "",
                                    "subagent " + selected.id,
                                    action: TuiTurnAction.ConversationFocused(backend.focusSubagent(selected.id))
                                )
                            )
                            Event.Message("subagent focused")
                    }
                )
            case _ => UpdateResult.next()
        }
    }

    private func focusMainConversation(): UpdateResult {
        if (focusedSubagentId == "") {
            status = if (mainWorking) {
                "working"
            } else {
                mainConversationStatus()
            }
            return refreshViewport()
        }
        status = "switching to Main"
        backgroundTask(
            "focus-main",
            {
                =>
                    mailbox.complete(
                        TuiTurnResult(
                            "",
                            "main conversation",
                            action: TuiTurnAction.ConversationFocused(backend.focusMain())
                        )
                    )
                    Event.Message("main focused")
            }
        )
    }

    private func refreshViewport(): UpdateResult {
        if (viewportArea.width > 0 && viewportArea.height > 0) {
            UpdateResult.dirty(viewportArea)
        } else {
            UpdateResult.next()
        }
    }

    private func openModal(
        kind: TuiModalKind,
        items: Array<String>
    ): UpdateResult {
        modal = Some(kind)
        modalItems = if (items.isEmpty()) {
            ["(none available)"]
        } else {
            items
        }
        modalSelected = 0
        status = "select with ↑/↓ and Enter; Esc closes"
        UpdateResult.next()
    }

    private func openSessionModal(items: Array<TuiSessionNode>): UpdateResult {
        modal = Some(TuiModalKind.Session)
        sessionNodes = items
        sessionMode = "browse"
        sessionInput = ""
        rebuildVisibleSessions(selectCurrent: true)
        status = sessionSelectorFooter(sessionMode, sessionShowArchived, sessionFilter)
        UpdateResult.next()
    }

    private func rebuildVisibleSessions(selectCurrent!: Bool = false): Unit {
        let values = ArrayList<TuiSessionNode>()
        let query = sessionFilter.trimAscii().toAsciiLower()
        for (node in sessionNodes) {
            if (query == "" || sessionSearchText(node).contains(query)) {
                values.add(node)
            }
        }
        visibleSessionNodes = values.toArray()
        modalItems = sessionLabels(visibleSessionNodes, sessionNodes)
        modalSelected = if (visibleSessionNodes.isEmpty()) {
            0
        } else {
            min(modalSelected, visibleSessionNodes.size - 1)
        }
        if (selectCurrent) {
            for (index in 0..visibleSessionNodes.size where visibleSessionNodes[index].current) {
                modalSelected = index
            }
        }
    }

    private func updateSessionModal(key: KeyEvent): UpdateResult {
        if (sessionMode == "search" || sessionMode == "rename") {
            match (key.code) {
                case KeyCode.Esc =>
                    if (sessionMode == "search" && sessionInput != "") {
                        sessionInput = ""
                        sessionFilter = ""
                        rebuildVisibleSessions(selectCurrent: true)
                    } else {
                        closeModal()
                        return UpdateResult.next()
                    }
                case KeyCode.Backspace =>
                    sessionInput = dropLastSessionRune(sessionInput)
                    if (sessionMode == "search") {
                        sessionFilter = sessionInput
                        rebuildVisibleSessions()
                    }
                case KeyCode.Enter =>
                    if (sessionMode == "search") {
                        sessionMode = "browse"
                    } else if (!visibleSessionNodes.isEmpty() && sessionInput.trimAscii() != "") {
                        let node = visibleSessionNodes[modalSelected]
                        let name = sessionInput.trimAscii()
                        sessionMode = "browse"
                        return startBackground(
                            "renaming session",
                            {
                                =>
                                    let ok = backend.renameSession(node.id, name)
                                    TuiTurnResult("", if (ok) {
                                        "session renamed"
                                    } else {
                                        "rename failed"
                                    }, action: TuiTurnAction.SessionsLoaded(backend.sessions(sessionShowArchived)))
                            }
                        )
                    }
                case KeyCode.Char(value) =>
                    if (!key.modifiers.ctrl && !key.modifiers.alt) {
                        sessionInput += value.toString()
                        if (sessionMode == "search") {
                            sessionFilter = sessionInput
                            rebuildVisibleSessions()
                        }
                    }
                case _ => ()
            }
            status = sessionSelectorFooter(sessionMode, sessionShowArchived, sessionFilter)
            // Search and rename only change the session overlay.  Keeping the
            // update local avoids re-rendering a large transcript behind it
            // for every typed rune.
            if (activeModalArea.width > 0) {
                modalRefreshOnly = true
                return UpdateResult.dirty(activeModalArea)
            }
            return UpdateResult.next()
        }
        if (sessionMode == "confirm_archive" || sessionMode == "confirm_restore") {
            match (key.code) {
                case KeyCode.Esc => sessionMode = "browse"
                case KeyCode.Enter =>
                    if (visibleSessionNodes.isEmpty()) {
                        return UpdateResult.next()
                    }
                    let node = visibleSessionNodes[modalSelected]
                    let restoring = sessionMode == "confirm_restore"
                    sessionMode = "browse"
                    return startBackground(
                        if (restoring) {
                            "restoring session"
                        } else {
                            "archiving session"
                        },
                        {
                            =>
                                let ok = if (restoring) {
                                    backend.restoreSession(node.id)
                                } else {
                                    backend.archiveSession(node.id)
                                }
                                TuiTurnResult("", if (ok) {
                                    if (restoring) {
                                        "session restored"
                                    } else {
                                        "session archived"
                                    }
                                } else {
                                    if (restoring) {
                                        "restore failed"
                                    } else {
                                        "archive failed"
                                    }
                                }, action: TuiTurnAction.SessionsLoaded(backend.sessions(sessionShowArchived)))
                        }
                    )
                case _ => ()
            }
            status = sessionSelectorFooter(sessionMode, sessionShowArchived, sessionFilter)
            return UpdateResult.next()
        }
        match (key.code) {
            case KeyCode.Esc =>
                if (sessionFilter != "") {
                    sessionFilter = ""
                    sessionInput = ""
                    rebuildVisibleSessions(selectCurrent: true)
                } else {
                    closeModal()
                    return UpdateResult.next()
                }
            case KeyCode.Up | KeyCode.Char(r'k') => modalSelected = max(0, modalSelected - 1)
            case KeyCode.Down | KeyCode.Char(r'j') => modalSelected = min(max(0, visibleSessionNodes.size - 1),
                modalSelected + 1)
            case KeyCode.Home => modalSelected = 0
            case KeyCode.End => modalSelected = max(0, visibleSessionNodes.size - 1)
            case KeyCode.Char(r'/') =>
                sessionMode = "search"
                sessionInput = sessionFilter
            case KeyCode.Char(r'A') =>
                sessionShowArchived = !sessionShowArchived
                return startBackground("loading sessions", {
                    => TuiTurnResult("", "select session",
                        action: TuiTurnAction.SessionsLoaded(backend.sessions(sessionShowArchived)))
                })
            case KeyCode.Char(r'r') =>
                if (!visibleSessionNodes.isEmpty() && !visibleSessionNodes[modalSelected].archived) {
                    sessionMode = "rename"
                    sessionInput = visibleSessionNodes[modalSelected].name
                }
            case KeyCode.Char(r'a') =>
                if (!visibleSessionNodes.isEmpty()) {
                    let node = visibleSessionNodes[modalSelected]
                    if (node.current) {
                        status = "the current session cannot be archived"
                        return UpdateResult.next()
                    }
                    if (!node.archived) {
                        sessionMode = "confirm_archive"
                    }
                }
            case KeyCode.Char(r'u') =>
                if (!visibleSessionNodes.isEmpty() && visibleSessionNodes[modalSelected].archived) {
                    sessionMode = "confirm_restore"
                }
            case KeyCode.Enter => return chooseModal()
            case _ => ()
        }
        status = sessionSelectorFooter(sessionMode, sessionShowArchived, sessionFilter)
        UpdateResult.next()
    }

    private func updateModal(key: KeyEvent): UpdateResult {
        match (modal) {
            case Some(TuiModalKind.Session) => return updateSessionModal(key)
            case _ => ()
        }
        match (modal) {
            case Some(TuiModalKind.Document) =>
                var changed = false
                match (key.code) {
                    case KeyCode.Esc =>
                        closeModal()
                        return UpdateResult.dirty(viewportArea)
                    case KeyCode.Left | KeyCode.Char(r'k') | KeyCode.Up =>
                        documentScroll = max(0, documentScroll - 1)
                        changed = true
                    case KeyCode.Right | KeyCode.Char(r'j') | KeyCode.Down =>
                        documentScroll += 1
                        changed = true
                    case KeyCode.PageUp =>
                        documentScroll = max(0, documentScroll - 5)
                        changed = true
                    case KeyCode.PageDown =>
                        documentScroll += 5
                        changed = true
                    case _ => ()
                }
                if (changed && activeModalArea.width > 0) {
                    modalRefreshOnly = true
                    return UpdateResult.dirty(activeModalBodyArea())
                }
                // The app loop renders once for every input event.  Restrict an
                // ignored key to the title row so typing while /help is open does
                // not redraw and re-layout the whole document.
                if (activeModalArea.width > 0) {
                    modalRefreshOnly = true
                    return UpdateResult.dirty(Rect(activeModalArea.x, activeModalArea.y, activeModalArea.width, 1))
                }
                return UpdateResult.next()
            case _ => ()
        }
        match (key.code) {
            case KeyCode.Esc => closeModal()
            case KeyCode.Up | KeyCode.Char(r'k') => modalSelected = max(0, modalSelected - 1)
            case KeyCode.Down | KeyCode.Char(r'j') => modalSelected = min(
                modalItems.size - 1,
                modalSelected + 1
            )
            case KeyCode.Enter => return chooseModal()
            case _ => ()
        }
        UpdateResult.next()
    }

    private func handleModalMouse(mouse: MouseEvent): UpdateResult {
        match (modal) {
            case Some(TuiModalKind.Document) =>
                if (mouse.x < activeModalArea.x || mouse.x >= activeModalArea.right || mouse.y < activeModalArea.y ||
                    mouse.y >= activeModalArea.bottom) {
                    return UpdateResult.dirty(Rect(activeModalArea.x, activeModalArea.y, activeModalArea.width, 1))
                }
                match ((mouse.kind, mouse.button)) {
                    case (MouseKind.Scroll, MouseButton.WheelUp) => documentScroll = max(0, documentScroll - 3)
                    case (MouseKind.Scroll, MouseButton.WheelDown) => documentScroll += 3
                    case _ => return UpdateResult.dirty(
                        Rect(activeModalArea.x, activeModalArea.y, activeModalArea.width, 1))
                }
                modalRefreshOnly = true
                UpdateResult.dirty(activeModalBodyArea())
            case _ => UpdateResult.dirty(Rect(activeModalArea.x, activeModalArea.y, max(1, activeModalArea.width), 1))
        }
    }

    private func activeModalBodyArea(): Rect {
        Rect(
            activeModalArea.x + 2,
            activeModalArea.y + 1,
            max(1, activeModalArea.width - 2),
            max(1, activeModalArea.height - 2)
        )
    }

    private func switchSessionInBackground(
        sessionId: String,
        label: String,
        previousDraft: String
    ): UpdateResult {
        startBackground(
            "switching session",
            {
                =>
                    let _ = backend.saveDraft(previousDraft)
                    let ok = backend.selectSession(sessionId)
                    TuiTurnResult(
                        "",
                        if (ok) {
                            "session: " + label
                        } else {
                            "session selection failed"
                        },
                        action: TuiTurnAction.SessionSelected(
                            label,
                            ok,
                            if (ok) {
                                backend.draft()
                            } else {
                                previousDraft
                            },
                            if (ok) {
                                Some(backend.focusMain())
                            } else {
                                None
                            }
                        )
                    )
            }
        )
    }

    private func draftForSessionSwitch(): ?String {
        match (composer.draftText()) {
            case Some(draft) => Some(draft)
            case None =>
                status = match (composer.lastError) {
                    case Some(message) => message
                    case None => "cannot preserve the current draft"
                }
                None
        }
    }

    private func chooseModal(): UpdateResult {
        let kind = match (modal) {
            case Some(value) => value
            case None => return UpdateResult.next()
        }
        if (modalItems.isEmpty()) {
            closeModal()
            return UpdateResult.next()
        }
        let selected = modalItems[modalSelected]
        match (kind) {
            case TuiModalKind.Model =>
                closeModal(keepStatus: true)
                startBackground(
                    "switching model",
                    {
                        =>
                            let ok = backend.selectModel(selected)
                            TuiTurnResult(
                                "",
                                if (ok) {
                                    "model: " + selected
                                } else {
                                    "model selection failed"
                                },
                                action: TuiTurnAction.ModelSelected(
                                    selected,
                                    ok,
                                    backend.currentModel()
                                )
                            )
                    }
                )
            case TuiModalKind.Theme => selectTheme(themeNameFromLabel(selected))
            case TuiModalKind.Session =>
                if (visibleSessionNodes.isEmpty()) {
                    status = "no matching sessions"
                    return UpdateResult.next()
                }
                let node = visibleSessionNodes[modalSelected]
                if (node.archived) {
                    status = "restore this session before opening it"
                    return UpdateResult.next()
                }
                match (draftForSessionSwitch()) {
                    case Some(draft) =>
                        closeModal(keepStatus: true)
                        switchSessionInBackground(node.id, node.label(), draft)
                    case None =>
                        closeModal(keepStatus: true)
                        UpdateResult.next()
                }
            case TuiModalKind.Tree =>
                if (treeNodes.isEmpty()) {
                    status = "no sessions available"
                    closeModal(keepStatus: true)
                    UpdateResult.next()
                } else {
                    let node = treeNodes[modalSelected]
                    match (draftForSessionSwitch()) {
                        case Some(draft) =>
                            closeModal(keepStatus: true)
                            switchSessionInBackground(node.id, node.label(), draft)
                        case None =>
                            closeModal(keepStatus: true)
                            UpdateResult.next()
                    }
                }
            case TuiModalKind.Agent =>
                if (subagentItems.isEmpty()) {
                    status = "no subagents available"
                    closeModal(keepStatus: true)
                    UpdateResult.next()
                } else {
                    let subagent = subagentItems[modalSelected]
                    closeModal(keepStatus: true)
                    startBackground("loading subagent", {
                        => TuiTurnResult(
                            "",
                            "subagent transcript",
                            action: TuiTurnAction.OpenDocument(
                                "Subagent · " + subagent.id,
                                backend.subagentTranscript(subagent.id)
                            )
                        )
                    })
                }
            case TuiModalKind.Extensions =>
                if (!extensionItems.isEmpty()) {
                    let selectedExtension = extensionItems[modalSelected]
                    let enabled = !selectedExtension.enabled
                    closeModal(keepStatus: true)
                    startBackground(
                        "updating extension",
                        {
                            =>
                                let ok = backend.setExtensionEnabled(
                                    selectedExtension.id,
                                    enabled
                                )
                                TuiTurnResult(
                                    "",
                                    if (ok) {
                                        (if (enabled) {
                                            "enabled: "
                                        } else {
                                            "disabled: "
                                        }) + selectedExtension.id
                                    } else {
                                        "extension state change failed"
                                    },
                                    action: TuiTurnAction.ExtensionToggled(
                                        selectedExtension.id,
                                        ok,
                                        backend.extensions()
                                    )
                                )
                        }
                    )
                } else {
                    UpdateResult.next()
                }
            case TuiModalKind.Branch =>
                closeModal(keepStatus: true)
                startBackground("creating branch", {
                    => match (backend.selectBranch(selected)) {
                        case Some(draft) => TuiTurnResult(
                            "",
                            "branch created; selected message restored",
                            action: TuiTurnAction.BranchSelected(true, draft)
                        )
                        case None => TuiTurnResult(
                            "",
                            "branch creation failed",
                            action: TuiTurnAction.BranchSelected(false, "")
                        )
                    }
                })
            case TuiModalKind.Settings =>
                if (selected == "Model") {
                    closeModal(keepStatus: true)
                    startBackground("loading models", {
                        => TuiTurnResult(
                            "",
                            "select model",
                            action: TuiTurnAction.ModelsLoaded(backend.models())
                        )
                    })
                } else if (selected == "Theme") {
                    customThemeDefinitions = backend.customThemes()
                    openModal(
                        TuiModalKind.Theme,
                        themeNames(customThemeDefinitions, themeName)
                    )
                } else if (selected == "Session") {
                    closeModal(keepStatus: true)
                    startBackground("loading sessions", {
                        => TuiTurnResult(
                            "",
                            "select session",
                            action: TuiTurnAction.SessionsLoaded(backend.sessions(false))
                        )
                    })
                } else if (selected == "Archive/reset") {
                    openModal(
                        TuiModalKind.Reset,
                        ["Archive and reset", "Cancel"]
                    )
                } else {
                    closeModal()
                }
                UpdateResult.next()
            case TuiModalKind.Setup =>
                if (selected == "Close") {
                    closeModal()
                } else {
                    setupDraft = Some(SetupDraft(selected))
                    closeModal(keepStatus: true)
                    status = "setup: enter model id"
                }
                UpdateResult.next()
            case TuiModalKind.Reset =>
                if (selected == "Archive and reset") {
                    closeModal(keepStatus: true)
                    startBackground(
                        "archiving session",
                        {
                            =>
                                let value = backend.archiveAndReset()
                                TuiTurnResult(
                                    "",
                                    value,
                                    action: TuiTurnAction.ResetCompleted(value)
                                )
                        }
                    )
                } else {
                    closeModal()
                    UpdateResult.next()
                }
            case TuiModalKind.Document =>
                closeModal()
                UpdateResult.next()
        }
    }

    private func continueSetup(value: String): UpdateResult {
        let draft = match (setupDraft) {
            case Some(item) => item
            case None => return UpdateResult.next()
        }
        match (draft.stage) {
            case 0 =>
                draft.model = value
                if (draft.custom) {
                    draft.stage = 1
                    status = "setup: enter base URL"
                } else {
                    draft.stage = 2
                    status = "setup: enter API key environment variable"
                }
            case 1 =>
                draft.baseUrl = value
                draft.stage = 2
                status = "setup: enter API key environment variable"
            case 2 =>
                draft.apiKeyEnv = value
                draft.stage = 3
                status = "setup: enter API key, or '-' to configure later"
            case _ =>
                let credential = if (value == "-") {
                    ""
                } else {
                    value
                }
                let request = TuiSetupRequest(
                    draft.profileId,
                    draft.provider,
                    draft.protocol,
                    draft.model,
                    draft.baseUrl,
                    draft.apiKeyEnv,
                    credential
                )
                setupDraft = None
                setupRequired = false
                return startBackground(
                    "saving provider",
                    {
                        =>
                            let outcome = backend.configureSetup(request)
                            TuiTurnResult(
                                "",
                                outcome,
                                action: TuiTurnAction.SetupConfigured(outcome)
                            )
                    }
                )
        }
        UpdateResult.next()
    }

    private func secretSetupEntry(): Bool {
        match (setupDraft) {
            case Some(draft) => draft.stage >= 3
            case None => false
        }
    }

    private func updateSecretSetup(key: KeyEvent): UpdateResult {
        match (key.code) {
            case KeyCode.CtrlC | KeyCode.Esc =>
                composer.area.setValue("")
                setupDraft = None
                status = "setup cancelled"
            case KeyCode.Enter =>
                let value = composer.area.value.trimAscii()
                composer.area.setValue("")
                if (value != "") {
                    return continueSetup(value)
                }
            case _ => _ = composer.area.handle(key)
        }
        UpdateResult.next()
    }

    private func beginAsk(request: TuiAskRequest): Unit {
        if (!ask.begin(request)) {
            status = ask.statusText()
            return
        }
        modal = None
        let cardId = askCardId(request)
        let inheritedArguments = match (toolCardForCall(request.callId)) {
            case Some(card) => card.toolArguments
            case None => ""
        }
        syncAskCard()
        if (request.callId != "") {
            UiReducer.reduce(
                ui,
                UiEvent.SetToolMetadata(
                    cardId,
                    "ask",
                    inheritedArguments,
                    request.callId,
                    ""
                )
            )
        }
        focusedCardId = cardId
        focusedCardIndex = -1
        status = ask.statusText()
    }

    private func askCardId(request: TuiAskRequest): String {
        match (toolCardForCall(request.callId)) {
            case Some(card) => return card.id
            case None => ()
        }
        if (request.requestId == "") {
            "ask-current"
        } else {
            "ask-" + request.requestId
        }
    }

    private func askCardScreenArea(): ?Rect {
        let id = match (ask.currentPresentation()) {
            case Some(value) => askCardId(value.request)
            case None => return None
        }
        let inset: Int64 = if (transcriptArea.width < 72) { 1 } else { 2 }
        for (range in transcriptRanges where range.id == id) {
            return Some(
                Rect(
                    transcriptArea.x + inset,
                    range.top,
                    max(1, transcriptArea.width - inset * 2),
                    max(0, range.bottom - range.top)
                )
            )
        }
        None
    }

    private func syncAskCard(
        state!: String = "awaiting",
        collapsed!: Bool = false,
        footer!: String = ""
    ): Unit {
        match (ask.currentPresentation()) {
            case Some(presentation) =>
                UiReducer.reduce(
                    ui,
                    UiEvent.UpsertCard(
                        askCardId(presentation.request),
                        UiCardKind.Ask,
                        presentation.title,
                        presentation.body,
                        state,
                        collapsed,
                        if (footer == "") { presentation.footer } else { footer }
                    )
                )
            case None => ()
        }
    }

    private func syncAskCompletion(completion: AskCompletion): Unit {
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard(
                askCardId(completion.request),
                UiCardKind.Ask,
                completion.title,
                completion.body,
                completion.state,
                completion.collapsed,
                completion.footer
            )
        )
    }

    private func updateAskModal(key: KeyEvent): UpdateResult {
        match (key.code) {
            case KeyCode.PageUp => return scrollTranscriptBy(transcriptPageSize())
            case KeyCode.PageDown => return scrollTranscriptBy(-transcriptPageSize())
            case KeyCode.Home =>
                if (key.modifiers.ctrl) {
                    return scrollTranscriptToTop()
                }
            case KeyCode.End =>
                if (key.modifiers.ctrl) {
                    scrollOffset = 0
                    clearScrollAnchor()
                    return dirtyTranscriptAndActivity()
                }
            case _ => ()
        }
        applyAskTransition(ask.updateKey(key))
    }

    private func updateAskEditor(key: KeyEvent): UpdateResult {
        applyAskTransition(ask.updateEditor(key))
    }

    private func applyAskTransition(step: AskTransition): UpdateResult {
        status = ask.statusText()
        match (step.effect) {
            case Some(AskEffect.Submit(request, resolution)) =>
                let accepted = backend.answerAsk(request.requestId, resolution)
                match (ask.completeSubmission(accepted, resolution)) {
                    case Some(completion) => syncAskCompletion(completion)
                    case None => ()
                }
                status = ask.statusText()
                UpdateResult.next()
            case None =>
                if (step.changed) {
                    if (step.cardChanged) {
                        syncAskCard()
                    }
                    status = ask.statusText()
                    UpdateResult.next()
                } else {
                    UpdateResult.unchanged()
                }
        }
    }

    private func resetGenericModal(): Unit {
        modal = None
        modalItems = []
        modalSelected = 0
        documentTitle = ""
        documentBody = ""
        documentScroll = 0
        treeNodes = []
        sessionNodes = []
        visibleSessionNodes = []
        sessionFilter = ""
        sessionInput = ""
        sessionMode = "browse"
        sessionShowArchived = false
        extensionItems = []
    }

    private func closeModal(keepStatus!: Bool = false): Unit {
        resetGenericModal()
        planReview.close(keepStatus: keepStatus)
        if (!keepStatus) {
            status = "ready"
        }
    }

    private func drainMailbox(): ?TuiTurnAction {
        let events = mailbox.drain()
        mailboxChanged = !events.isEmpty()
        for (event in events) {
            acceptAgentEvent(event)
        }
        match (mailbox.takeResult()) {
            case Some(result) =>
                mailboxChanged = true
                if (result.text != "") {
                    UiReducer.reduce(
                        ui,
                        UiEvent.UpsertCard(
                            assistantCardId(),
                            UiCardKind.Assistant,
                            "Assistant",
                            result.text,
                            "completed",
                            false,
                            ""
                        )
                    )
                }
                if (planReview.hasPending()) {
                    match (planReview.acceptTurnResult(
                        result.status.trimAscii(),
                        result.action,
                        disposition: result.planReviewDisposition
                    )) {
                        case Some(action) =>
                            status = planReview.statusText()
                            return Some(action)
                        case None => status = planReview.statusText()
                    }
                } else {
                    status = compactRunStatus(result.status)
                    match (result.action) {
                        case TuiTurnAction.NoAction => ()
                        case action => return Some(action)
                    }
                }
            case None => ()
        }
        None
    }

    private func applyTurnAction(action: TuiTurnAction): UpdateResult {
        match (action) {
            case TuiTurnAction.NoAction => UpdateResult.next()
            case TuiTurnAction.Exit => UpdateResult.exit()
            case TuiTurnAction.OpenProviderSetup => openModal(
                TuiModalKind.Setup,
                [
                    "OpenAI Responses",
                    "Anthropic Messages",
                    "OpenAI-compatible",
                    "Close"
                ]
            )
            case TuiTurnAction.OpenModelSelector => startBackground("loading models", {
                => TuiTurnResult(
                    "",
                    "select model",
                    action: TuiTurnAction.ModelsLoaded(backend.models())
                )
            })
            case TuiTurnAction.OpenBranchSelector => startBackground("loading branch points", {
                => TuiTurnResult(
                    "",
                    "select branch point",
                    action: TuiTurnAction.BranchesLoaded(backend.branchMessages())
                )
            })
            case TuiTurnAction.OpenPlanReview(body) =>
                resetGenericModal()
                let update = planReview.open(body)
                status = planReview.statusText()
                update
            case TuiTurnAction.OpenDocument(title, body) =>
                planReview.close()
                documentTitle = title
                documentBody = body
                documentRevision++
                documentScroll = 0
                modal = Some(TuiModalKind.Document)
                modalItems = []
                status = "↑/↓ scroll · Esc closes"
                UpdateResult.next()
            case TuiTurnAction.ModelsLoaded(items) => openModal(TuiModalKind.Model, items)
            case TuiTurnAction.ThemeSelected(name, ok, definitions) =>
                if (ok) {
                    themeName = name
                    customThemeDefinitions = definitions
                    markdownCache.clear()
                    match (virtualTranscriptSource) {
                        case Some(source) => source.invalidateGeneration()
                        case None => ()
                    }
                    documentRevision++
                    planReview.setTheme(name, definitions)
                    status = "theme: " + name
                } else {
                    status = "theme selection failed: " + name
                }
                UpdateResult.next()
            case TuiTurnAction.SessionsLoaded(items) => openSessionModal(items)
            case TuiTurnAction.BranchesLoaded(items) => openModal(TuiModalKind.Branch, items)
            case TuiTurnAction.SessionTreeLoaded(items) =>
                treeNodes = items
                openModal(TuiModalKind.Tree, treeLabels(items))
            case TuiTurnAction.SubagentsLoaded(items) =>
                agentHubOpenCount++
                subagentItems = items
                modalSelected = 0
                agentHubActive = true
                status = "select conversation"
                refreshViewport()
            case TuiTurnAction.ConversationFocused(view) => applyConversationView(view)
            case TuiTurnAction.ExtensionsLoaded(items) =>
                extensionItems = items
                if (items.isEmpty()) {
                    applyTurnAction(
                        TuiTurnAction.OpenDocument(
                            "Extensions",
                            "No external extensions are installed.\n\n" + "Built-in tools are product capabilities and " +
                                "are not counted as extensions."
                        )
                    )
                } else {
                    openModal(
                        TuiModalKind.Extensions,
                        extensionLabels(items)
                    )
                }
            case TuiTurnAction.TodoLoaded(result) =>
                applyTodoTransition(todos.open(result))
            case TuiTurnAction.ModelSelected(_, ok, current) =>
                if (ok) {
                    modelLabel = current
                }
                UpdateResult.next()
            case TuiTurnAction.SessionSelected(_, ok, draft, view) =>
                if (ok) {
                    composer.restoreDraft(draft)
                    modelLabel = backend.currentModel()
                    let todoChanged = refreshTodoSnapshot()
                    match (view) {
                        case Some(value) =>
                            let result = applyConversationView(value)
                            return if (todoChanged) {
                                invalidateTodoLayout(result)
                            } else {
                                result
                            }
                        case None => ()
                    }
                    if (todoChanged) {
                        return invalidateTodoLayout(UpdateResult.next())
                    }
                }
                UpdateResult.next()
            case TuiTurnAction.BranchSelected(ok, draft) =>
                if (ok) {
                    composer.restoreDraft(draft)
                }
                UpdateResult.next()
            case TuiTurnAction.ExtensionToggled(_, ok, items) =>
                if (ok) {
                    extensionItems = items
                    openModal(
                        TuiModalKind.Extensions,
                        extensionLabels(items)
                    )
                } else {
                    UpdateResult.next()
                }
            case TuiTurnAction.ResetCompleted(value) =>
                addCard(UiCardKind.Setup, "Session storage", value)
                if (refreshTodoSnapshot()) {
                    invalidateTodoLayout(UpdateResult.next())
                } else {
                    UpdateResult.next()
                }
            case TuiTurnAction.SetupConfigured(value) =>
                addCard(UiCardKind.Setup, "Provider configured", value)
                UpdateResult.next()
            case TuiTurnAction.TodoSaved(result) =>
                let update = applyTodoTransition(todos.acceptSave(result))
                if (result.saved && refreshTodoSnapshot()) {
                    invalidateTodoLayout(update)
                } else {
                    update
                }
            case TuiTurnAction.DraftLoaded(value) =>
                if (composer.area.value == "") {
                    composer.restoreDraft(value)
                }
                UpdateResult.next()
            case TuiTurnAction.UiStatus(value) =>
                status = compactRunStatus(value)
                UpdateResult.next()
        }
    }

    private func applyConversationView(view: TuiConversationView): UpdateResult {
        let snapshot = UiSnapshot()
        for (item in view.items) { appendTranscriptItem(snapshot, item) }
        ui = snapshot
        configuredCardViewport = -1
        configuredCardViewportCount = 0
        match (virtualTranscriptSource) {
            case Some(source) => source.setSnapshot(snapshot)
            case None => ()
        }
        // A session can switch while the modal still covers the transcript,
        // so waiting for the next transcript render leaves the previous
        // session's per-card entries retained. totalRows() synchronizes the
        // existing view with the new source without materializing documents.
        match (virtualTranscriptView) {
            case Some(view) =>
                let _ = view.totalRows()
                view.lastVisibleRanges.clear()
            case None => ()
        }
        markdownCache.clear()
        focusedSubagentId = if (view.isMain) {
            ""
        } else {
            view.id
        }
        focusedConversationLabel = view.label
        mainTranscriptBeforeOrdinal = if (view.isMain) { view.nextBeforeOrdinal } else { 0 }
        mainTranscriptHasMore = view.isMain && view.hasMore
        taskLabel = if (view.isMain) {
            ""
        } else {
            view.label
        }
        activeToolCardId = ""
        modelRoundSequence = 0
        scrollOffset = 0
        working = if (view.isMain) {
            mainWorking
        } else {
            runningStatus(view.status)
        }
        UiReducer.reduce(ui, UiEvent.SetWorking(working))
        status = conversationPromptStatus(view)
        // Canonical items are authoritative. Only the currently active
        // Attempt tail is applied after that bootstrap; completed attempts are
        // deliberately absent from provisionalEvents.
        for (event in view.provisionalEvents) { acceptAgentEvent(event) }
        refreshViewport()
    }

    private func conversationPromptStatus(view: TuiConversationView): String {
        if (view.isMain) {
            if (mainWorking) {
                "working"
            } else {
                mainConversationStatus()
            }
        } else {
            "subagent " + view.id + " · " + view.status + " · Agent Hub switches conversation"
        }
    }

    private func mainConversationStatus(): String {
        if (runningSubagentIds.isEmpty()) {
            "ready"
        } else {
            "ready · " + runningSubagentIds.size.toString() + " subagent" + if (runningSubagentIds.size == 1) {
                " running"
            } else {
                "s running"
            }
        }
    }

    private func runningStatus(value: String): Bool {
        value == "running"
    }

    private func toolBinding(callId: String): ?ToolCardBinding {
        if (callId == "") {
            return None
        }
        for (binding in toolBindings where binding.callId == callId) {
            return Some(binding)
        }
        None
    }

    private func toolCardForCall(callId: String): ?UiCard {
        if (callId == "") {
            return None
        }
        for (card in ui.cards where card.toolCallId == callId) {
            return Some(card)
        }
        None
    }

    private func removeToolBinding(cardId: String): Unit {
        var index: Int64 = 0
        while (index < toolBindings.size) {
            if (toolBindings[index].cardId == cardId) {
                toolBindings.remove(at: index)
            } else {
                index++
            }
        }
    }

    private func acceptToolStarted(
        name: String,
        callId: String,
        arguments: String
    ): Unit {
        // Event sources may replay a start after reconnecting. A call_id is
        // the identity of the card, so never append a second running card.
        if (callId != "") {
            match (toolBinding(callId)) {
                case Some(_) => return
                case None => ()
            }
            match (toolCardForCall(callId)) {
                case Some(_) => return
                case None => ()
            }
        }
        let startedAt = MonoTime.now()
        let cardId = nextCardId("tool")
        toolBindings.add(ToolCardBinding(callId, cardId, name, arguments, startedAt))
        activeToolCardId = cardId
        activeToolCallId = callId
        activeToolArguments = arguments
        activeToolStartedAt = Some(startedAt)
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard(
                cardId,
                UiCardKind.Tool,
                summarizeToolCall(name, arguments),
                beautifyToolDetail(name, arguments, "", false),
                "running",
                false,
                ""
            )
        )
        UiReducer.reduce(
            ui,
            UiEvent.SetToolMetadata(cardId, name, arguments, callId, "")
        )
        UiReducer.reduce(ui, UiEvent.SetToolStartedAt(cardId, startedAt))
    }

    private func acceptToolArguments(callId: String, delta: String): Unit {
        if (delta == "") { return }
        match (toolBinding(callId)) {
            case Some(binding) =>
                binding.arguments += delta
                activeToolArguments = binding.arguments
                UiReducer.reduce(ui, UiEvent.SetToolMetadata(
                    binding.cardId, binding.name, binding.arguments, callId, ""
                ))
                UiReducer.reduce(ui, UiEvent.UpsertCard(
                    binding.cardId, UiCardKind.Tool,
                    summarizeToolCall(binding.name, binding.arguments),
                    beautifyToolDetail(binding.name, binding.arguments, "", false),
                    "running", false, ""
                ))
            case None => ()
        }
    }

    private func acceptToolOutput(
        callId: String,
        chunk: String,
        _isStderr: Bool
    ): Unit {
        let _ = _isStderr
        if (chunk == "") {
            return
        }
        let cardId = match (toolBinding(callId)) {
            case Some(binding) => binding.cardId
            case None => match (toolCardForCall(callId)) {
                case Some(card) => card.id
                case None =>
                    if (callId == activeToolCallId || callId == "") {
                        activeToolCardId
                    } else {
                        ""
                    }
            }
        }
        if (cardId == "") {
            return
        }
        // stderr deliberately shares the normal output style.  The final
        // state/icon communicates failure without painting an entire log red.
        UiReducer.reduce(ui, UiEvent.AppendToolOutput(cardId, chunk))
    }

    private func acceptToolCompleted(
        name: String,
        callId: String,
        failed: Bool,
        completion: TuiToolCompletionPayload
    ): Unit {
        let binding = toolBinding(callId)
        let cardId = match (binding) {
            case Some(value) => value.cardId
            case None => match (toolCardForCall(callId)) {
                case Some(card) => card.id
                case None =>
                    if (callId == "" || callId == activeToolCallId) {
                        if (activeToolCardId == "") {
                            nextCardId("tool")
                        } else {
                            activeToolCardId
                        }
                    } else {
                        nextCardId("tool")
                    }
            }
        }
        let resolvedName = match (binding) {
            case Some(value) => value.name
            case None =>
                if (name == "") {
                    "tool"
                } else {
                    name
                }
        }
        let arguments = match (binding) {
            case Some(value) => value.arguments
            case None =>
                if (callId == activeToolCallId || callId == "") {
                    activeToolArguments
                } else {
                    ""
                }
        }
        let startedAt = match (binding) {
            case Some(value) => value.startedAt
            case None => match (activeToolStartedAt) {
                case Some(value) => value
                case None => MonoTime.now()
            }
        }
        let elapsed = max(0, (MonoTime.now() - startedAt).toMilliseconds())
        var interactiveAsk = false
        if (resolvedName == "ask") {
            for (card in ui.cards where card.id == cardId && card.kind == UiCardKind.Ask) {
                interactiveAsk = true
            }
        }
        if (interactiveAsk) {
            UiReducer.reduce(ui, UiEvent.SetToolElapsed(cardId, elapsed))
            if (activeToolCardId == cardId) {
                activeToolCardId = ""
                activeToolCallId = ""
                activeToolArguments = ""
                activeToolStartedAt = None
            }
            removeToolBinding(cardId)
            modelRoundSequence += 1
            return
        }
        let duration = if (elapsed <= 0) {
            ""
        } else {
            formatElapsedMillis(elapsed)
        }
        let shell = resolvedName == "bash" || resolvedName == "bash_readonly"
        let detail = if (shell) {
            // Shell cards render the bounded typed preview separately. Do not
            // duplicate it into the generic body as well.
            ""
        } else {
            beautifyToolDetail(resolvedName, arguments, completion.detailPreview, failed)
        }
        let state = if (failed) {
            "failed"
        } else {
            "completed"
        }
        let footer = if (resolvedName == "edit") {
            if (failed) {
                "failed"
            } else {
                "applied"
            }
        } else {
            tuiToolCompletionFooter(resolvedName, completion)
        }
        let body = state + if (duration == "") {
            ""
        } else {
            " · " + duration
        } + if (detail == "") {
            ""
        } else {
            "\n" + detail
        }
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard(
                cardId,
                UiCardKind.Tool,
                toolTitleWithStats(resolvedName, arguments, completion.detailPreview),
                body,
                state,
                resolvedName != "bash" && resolvedName != "bash_readonly" && !failed && detail != "",
                footer
            )
        )
        UiReducer.reduce(
            ui,
            UiEvent.SetToolMetadata(cardId, resolvedName, arguments, callId, completion.detailPreview)
        )
        UiReducer.reduce(
            ui,
            UiEvent.ReplaceToolOutput(
                cardId,
                tuiToolCompletionOutput(resolvedName, completion),
                completion.previewTruncated
            )
        )
        UiReducer.reduce(ui, UiEvent.SetToolElapsed(cardId, elapsed))
        if (activeToolCardId == cardId) {
            activeToolCardId = ""
            activeToolCallId = ""
            activeToolArguments = ""
            activeToolStartedAt = None
        }
        removeToolBinding(cardId)
        modelRoundSequence += 1
    }

    private func noteTranscriptMutation(followedBefore: Bool, lines: Int64): Unit {
        if (followedBefore) {
            scrollOffset = 0
            newTranscriptLines = 0
        } else {
            newTranscriptLines += max(1, lines)
        }
    }

    private func acceptAgentEvent(event: TuiAgentEvent): Unit {
        let followedBefore = scrollOffset <= 0
        match (event) {
            case TuiAgentEvent.AttemptStarted(_) | TuiAgentEvent.AttemptTextDelta(_, _) |
                TuiAgentEvent.AttemptReasoningDelta(_, _) | TuiAgentEvent.AttemptToolStarted(_, _, _) |
                TuiAgentEvent.AttemptToolArguments(_, _, _) | TuiAgentEvent.AttemptFailed(_, _) |
                TuiAgentEvent.AttemptCancelled(_) | TuiAgentEvent.AttemptAborted(_) |
                TuiAgentEvent.AttemptRetryScheduled(_) | TuiAgentEvent.DecisionCommitted(_, _) =>
                if (focusedSubagentId != "") { return }
            case TuiAgentEvent.SubagentStream(id, inner) =>
                acceptSubagentStream(id, inner)
                if (id == focusedSubagentId) {
                    noteTranscriptMutation(followedBefore, 1)
                }
                return
            case TuiAgentEvent.TextDelta(_) | TuiAgentEvent.ReasoningDelta(_) | TuiAgentEvent.ToolStarted(_, _)
                | TuiAgentEvent.ToolStartedWithId(_, _, _) | TuiAgentEvent.ToolOutput(_, _, _)
                | TuiAgentEvent.ToolCompleted(_, _, _) | TuiAgentEvent.ToolCompletedWithId(_, _, _, _)
                | TuiAgentEvent.InputInjected(_, _, _) | TuiAgentEvent.Usage(_, _) =>
                if (focusedSubagentId != "") {
                    return
                }
            case _ => ()
        }
        match (event) {
            case TuiAgentEvent.AttemptStarted(scope) =>
                let previous = attemptProjection.activeAttemptId(scope.semanticRequestId)
                attemptProjection.start(scope)
                if (previous != "" && previous != scope.attemptId) {
                    UiReducer.reduce(ui, UiEvent.RemoveAttempt(previous))
                }
            case TuiAgentEvent.AttemptTextDelta(scope, text) =>
                if (attemptProjection.accept(scope)) {
                    UiReducer.reduce(ui, UiEvent.AppendText(
                        "attempt-" + scope.attemptId + "-assistant",
                        UiCardKind.Assistant, "Assistant", text
                    ))
                }
            case TuiAgentEvent.AttemptReasoningDelta(scope, text) =>
                if (attemptProjection.accept(scope)) {
                    UiReducer.reduce(ui, UiEvent.AppendText(
                        "attempt-" + scope.attemptId + "-reasoning",
                        UiCardKind.Reasoning, "Thinking", text
                    ))
                }
            case TuiAgentEvent.AttemptToolStarted(scope, callId, name) =>
                if (attemptProjection.accept(scope)) {
                    acceptToolStarted(name, scope.attemptId + "::" + callId, "")
                }
            case TuiAgentEvent.AttemptToolArguments(scope, callId, delta) =>
                if (attemptProjection.accept(scope)) {
                    acceptToolArguments(scope.attemptId + "::" + callId, delta)
                }
            case TuiAgentEvent.AttemptFailed(scope, _) =>
                attemptProjection.fail(scope)
                UiReducer.reduce(ui, UiEvent.RemoveAttempt(scope.attemptId))
            case TuiAgentEvent.AttemptCancelled(scope) =>
                attemptProjection.cancel(scope)
                UiReducer.reduce(ui, UiEvent.RemoveAttempt(scope.attemptId))
            case TuiAgentEvent.AttemptAborted(scope) =>
                attemptProjection.abort(scope)
                UiReducer.reduce(ui, UiEvent.RemoveAttempt(scope.attemptId))
            case TuiAgentEvent.AttemptRetryScheduled(scope) =>
                attemptProjection.abort(scope)
                UiReducer.reduce(ui, UiEvent.RemoveAttempt(scope.attemptId))
            case TuiAgentEvent.DecisionCommitted(scope, _) =>
                attemptProjection.commit(scope)
                UiReducer.reduce(ui, UiEvent.CommitAttempt(scope.attemptId))
            case TuiAgentEvent.TextDelta(text) =>
                if (performanceBurstActive) {
                    performanceBurstAppliedThisUpdate += unsafe { text.rawData().size }
                    performanceBurstAppliedTotal += unsafe { text.rawData().size }
                }
                UiReducer.reduce(
                    ui,
                    UiEvent.AppendText(
                        assistantCardId(),
                        UiCardKind.Assistant,
                        "Assistant",
                        text
                    )
                )
            case TuiAgentEvent.ReasoningDelta(text) => UiReducer.reduce(
                ui,
                UiEvent.AppendText(
                    reasoningCardId(),
                    UiCardKind.Reasoning,
                    "Thinking",
                    text
                )
            )
            case TuiAgentEvent.ToolStarted(name, detail) => acceptToolStarted(name, "", detail)
            case TuiAgentEvent.ToolStartedWithId(name, callId, detail) => acceptToolStarted(name, callId, detail)
            case TuiAgentEvent.ToolOutput(callId, chunk, isStderr) => acceptToolOutput(callId, chunk, isStderr)
            case TuiAgentEvent.ToolCompleted(name, failed, detail) => acceptToolCompleted(name, "", failed, detail)
            case TuiAgentEvent.ToolCompletedWithId(name, callId, failed, detail) => acceptToolCompleted(name, callId,
                failed, detail)
            case TuiAgentEvent.InputInjected(correlationId, kind, text) =>
                removeQueuedPrompt(correlationId)
                let id = if (correlationId == "") {
                    nextCardId("user")
                } else {
                    correlationId
                }
                UiReducer.reduce(
                    ui,
                    UiEvent.UpsertCard(id, UiCardKind.User, "You", text, "submitted", false, "")
                )
                if (kind == "steer") {
                    modelRoundSequence += 1
                    activeToolCardId = ""
                    taskLabel = text
                    status = "working"
                }
            case TuiAgentEvent.JobStatus(id, jobType, jobStatus, label, durationMillis, error) =>
                let failed = jobStatus == "failed" || jobStatus == "cancelled"
                let runningJob = jobStatus == "running"
                let title = if (jobType == "task") {
                    "Subagent · " + id
                } else {
                    "Background · " + id
                }
                let elapsed = if (durationMillis <= 0) {
                    ""
                } else {
                    " · " + (durationMillis / 1000).toString() + "s"
                }
                if (jobType != "task" || focusedSubagentId == "" || focusedSubagentId == id) {
                    UiReducer.reduce(
                        ui,
                        UiEvent.UpsertCard(
                            "job-" + id,
                            if (failed) {
                                UiCardKind.Error
                            } else {
                                UiCardKind.Tool
                            },
                            title,
                            jobStatus + elapsed + if (label == "") {
                                ""
                            } else {
                                "\n" + label
                            } + if (error == "") {
                                ""
                            } else {
                                "\n" + error
                            },
                            jobStatus,
                            !runningJob,
                            ""
                        )
                    )
                }
                updateSubagentInfoStatus(id, jobType, jobStatus, label)
                if (jobType == "task" && id == focusedSubagentId) {
                    working = runningStatus(jobStatus)
                    UiReducer.reduce(ui, UiEvent.SetWorking(working))
                    status = "subagent " + id + " · " + jobStatus + " · Agent Hub switches conversation"
                } else if (jobType == "task" && focusedSubagentId == "") {
                    status = if (mainWorking) {
                        "working"
                    } else {
                        mainConversationStatus()
                    }
                } else {
                    if (jobType != "task") {
                        status = "background " + id + " · " + jobStatus
                    }
                }
            case TuiAgentEvent.SubagentStatus(info, durationMillis, error) =>
                acceptAgentEvent(
                    TuiAgentEvent.JobStatus(
                        info.id,
                        "task",
                        info.status,
                        info.task,
                        durationMillis,
                        error
                    )
                )
                updateSubagentInfoStatus(
                    info.id,
                    "task",
                    info.status,
                    info.task,
                    agent: info.agent
                )
            case TuiAgentEvent.Approval(tool, operationId, callId, capability, resource, risk, reason, preview, sessionLabel, inspectTitle, inspectBody, ownerId) =>
                let approvalId = "approval-" + operationId
                if (ownerId != focusedSubagentId) {
                    let _ = if (ownerId == "") {
                        applyConversationView(backend.focusMain())
                    } else {
                        applyConversationView(backend.focusSubagent(ownerId))
                    }
                }
                mainWorking = false
                working = false
                UiReducer.reduce(ui, UiEvent.SetWorking(false))
                status = "approval required"
                approvalSessionLabel = sessionLabel
                approvalInspectTitle = inspectTitle
                approvalInspectBody = inspectBody
                approvalToolCardId = match (toolCardForCall(callId)) {
                    case Some(card) => card.id
                    case None => ""
                }
                if (approvalToolCardId != "") {
                    UiReducer.reduce(
                        ui,
                        UiEvent.SetCardState(
                            approvalToolCardId,
                            "waiting",
                            "awaiting approval",
                            false
                        )
                    )
                }
                UiReducer.reduce(
                    ui,
                    UiEvent.UpsertCard(
                        approvalId,
                        UiCardKind.Approval,
                        "Approval · " + approvalOperationTitle(tool, preview),
                        approvalCardBody(
                            tool,
                            capability,
                            resource,
                            risk,
                            reason,
                            preview
                        ),
                        "awaiting_user",
                        false,
                        ""
                    )
                )
                UiReducer.reduce(
                    ui,
                    UiEvent.AwaitApproval(approvalId)
                )
                focusedCardId = approvalId
                focusedCardIndex = -1
            case TuiAgentEvent.ApprovalReview(
                requestId,
                tool,
                state,
                risk,
                reviewer,
                riskReason,
                reviewReason,
                latency,
                failure
            ) =>
                let body = approvalReviewCardBody(
                    state,
                    risk,
                    reviewer,
                    riskReason,
                    reviewReason,
                    failure
                )
                let footer = match (state) {
                    case "reviewing" => ""
                    case "approved" => "Approved · " + latency.toString() + " ms"
                    case "denied" => "Denied · " + latency.toString() + " ms"
                    case _ => "Handed off for your decision"
                }
                UiReducer.reduce(
                    ui,
                    UiEvent.UpsertCard(
                        "approval-review-" + requestId,
                        UiCardKind.Permission,
                        "AI approval · " + approvalOperationTitle(tool, ""),
                        body,
                        match (state) {
                            case "reviewing" => "running"
                            case "approved" => "completed"
                            case "denied" => "failed"
                            case _ => "waiting"
                        },
                        state == "approved",
                        footer
                    )
                )
            case TuiAgentEvent.Ask(request) => beginAsk(request)
            case TuiAgentEvent.PlanReviewConsumed(contentHash) =>
                if (planReview.acceptConsumed(contentHash)) {
                    status = planReview.statusText()
                    mailboxViewportRefresh = true
                }
            case TuiAgentEvent.Usage(input, output) =>
                UiReducer.reduce(ui, UiEvent.SetUsage(input, output))
                status = "tokens " + input.toString() + " in / " + output.toString() + " out"
            case TuiAgentEvent.Setup(message) =>
                addCard(
                    UiCardKind.Setup,
                    "Provider setup",
                    message
                )
                status = "setup required"
            case TuiAgentEvent.Plan(id, body) => UiReducer.reduce(
                ui,
                UiEvent.UpsertCard(
                    if (id == "") {
                        "plan-current"
                    } else {
                        "plan-" + id
                    },
                    UiCardKind.Plan,
                    if (body == "") {
                        "Plan"
                    } else {
                        body.split("\n")[0]
                    },
                    body,
                    "running",
                    false,
                    ""
                )
            )
            case TuiAgentEvent.Warning(title, body) => UiReducer.reduce(
                ui,
                UiEvent.UpsertCard(
                    if (title == "") {
                        "warning-current"
                    } else {
                        "warning-" + title
                    },
                    UiCardKind.Warning,
                    if (title == "") {
                        "Warning"
                    } else {
                        title
                    },
                    body,
                    "warning",
                    false,
                    "system event"
                )
            )
            case TuiAgentEvent.Compaction(before, after, reason) =>
                let saved = max(0, before - after)
                UiReducer.reduce(
                    ui,
                    UiEvent.UpsertCard(
                        "context-compaction",
                        UiCardKind.Compaction,
                        "Context compacted",
                        "Before   " + before.toString() + " tokens\nAfter    " + after.toString() + " tokens\nSaved    " +
                            saved.toString() + " tokens" + if (reason == "") {
                            ""
                        } else {
                            "\n\nReason   " + reason
                        },
                        "completed",
                        true,
                        "Conversation summary preserved"
                    )
                )
            case TuiAgentEvent.Summary(body) => UiReducer.reduce(
                ui,
                UiEvent.UpsertCard(
                    "run-summary",
                    UiCardKind.Summary,
                    "Task summary",
                    body,
                    "completed",
                    false,
                    ""
                )
            )
            case TuiAgentEvent.Error(message) => addErrorCard("Error", message)
            case TuiAgentEvent.SubagentStream(_, _) => ()
        }
        let changedLines = match (event) {
            case TuiAgentEvent.TextDelta(text) => max(1, text.split("\n").size - 1)
            case TuiAgentEvent.ReasoningDelta(text) => max(1, text.split("\n").size - 1)
            case TuiAgentEvent.ToolOutput(_, chunk, _) => max(1, chunk.split("\n").size - 1)
            case TuiAgentEvent.InputInjected(_, _, text) => max(1, text.split("\n").size)
            case TuiAgentEvent.Usage(_, _) => 0
            case TuiAgentEvent.PlanReviewConsumed(_) => 0
            case _ => 1
        }
        if (changedLines > 0) {
            noteTranscriptMutation(followedBefore, changedLines)
        }
    }

    private func acceptSubagentStream(
        id: String,
        event: TuiSubagentStreamEvent
    ): Unit {
        if (id != focusedSubagentId) {
            return
        }
        match (event) {
            case TuiSubagentStreamEvent.AttemptStarted(scope) =>
                let previous = attemptProjection.activeAttemptId(scope.semanticRequestId)
                attemptProjection.start(scope)
                if (previous != "" && previous != scope.attemptId) {
                    UiReducer.reduce(ui, UiEvent.RemoveAttempt(previous))
                }
            case TuiSubagentStreamEvent.AttemptTextDelta(scope, text) =>
                if (attemptProjection.accept(scope)) {
                    UiReducer.reduce(ui, UiEvent.AppendText(
                        "attempt-" + scope.attemptId + "-assistant",
                        UiCardKind.Assistant, "Assistant", text
                    ))
                }
            case TuiSubagentStreamEvent.AttemptReasoningDelta(scope, text) =>
                if (attemptProjection.accept(scope)) {
                    UiReducer.reduce(ui, UiEvent.AppendText(
                        "attempt-" + scope.attemptId + "-reasoning",
                        UiCardKind.Reasoning, "Thinking", text
                    ))
                }
            case TuiSubagentStreamEvent.AttemptToolStarted(scope, callId, name) =>
                if (attemptProjection.accept(scope)) {
                    acceptToolStarted(name, scope.attemptId + "::" + callId, "")
                }
            case TuiSubagentStreamEvent.AttemptToolArguments(scope, callId, delta) =>
                if (attemptProjection.accept(scope)) {
                    acceptToolArguments(scope.attemptId + "::" + callId, delta)
                }
            case TuiSubagentStreamEvent.AttemptFailed(scope) =>
                attemptProjection.fail(scope)
                UiReducer.reduce(ui, UiEvent.RemoveAttempt(scope.attemptId))
            case TuiSubagentStreamEvent.AttemptCancelled(scope) =>
                attemptProjection.cancel(scope)
                UiReducer.reduce(ui, UiEvent.RemoveAttempt(scope.attemptId))
            case TuiSubagentStreamEvent.AttemptAborted(scope) =>
                attemptProjection.abort(scope)
                UiReducer.reduce(ui, UiEvent.RemoveAttempt(scope.attemptId))
            case TuiSubagentStreamEvent.DecisionCommitted(scope) =>
                attemptProjection.commit(scope)
                UiReducer.reduce(ui, UiEvent.CommitAttempt(scope.attemptId))
            case TuiSubagentStreamEvent.TextDelta(text) => UiReducer.reduce(
                ui,
                UiEvent.AppendText(
                    assistantCardId(),
                    UiCardKind.Assistant,
                    "Assistant",
                    text
                )
            )
            case TuiSubagentStreamEvent.ReasoningDelta(text) => UiReducer.reduce(
                ui,
                UiEvent.AppendText(
                    reasoningCardId(),
                    UiCardKind.Reasoning,
                    "Thinking",
                    text
                )
            )
            case TuiSubagentStreamEvent.ToolStarted(name, detail) => acceptToolStarted(name, "", detail)
            case TuiSubagentStreamEvent.ToolStartedWithId(name, callId, detail) => acceptToolStarted(name, callId,
                detail)
            case TuiSubagentStreamEvent.ToolOutput(callId, chunk, isStderr) => acceptToolOutput(callId, chunk, isStderr)
            case TuiSubagentStreamEvent.ToolCompleted(name, failed, detail) => acceptToolCompleted(name, "", failed,
                detail)
            case TuiSubagentStreamEvent.ToolCompletedWithId(name, callId, failed, detail) => acceptToolCompleted(name,
                callId, failed, detail)
            case TuiSubagentStreamEvent.InputInjected(correlationId, kind, text) =>
                UiReducer.reduce(
                    ui,
                    UiEvent.UpsertCard(
                        if (correlationId == "") {
                            nextCardId("subagent-user")
                        } else {
                            correlationId
                        },
                        UiCardKind.User,
                        "You",
                        text,
                        kind,
                        false,
                        ""
                    )
                )
                modelRoundSequence += 1
            case TuiSubagentStreamEvent.Usage(input, output) =>
                UiReducer.reduce(ui, UiEvent.SetUsage(input, output))
                status = "subagent " + id + " · tokens " + input.toString() + " in / " + output.toString() + " out"
            case TuiSubagentStreamEvent.Error(message) => addCard(UiCardKind.Error, "Subagent error", message)
        }
    }

    private func updateSubagentInfoStatus(
        id: String,
        jobType: String,
        jobStatus: String,
        label: String,
        agent!: String = ""
    ): Unit {
        if (jobType != "task") {
            return
        }
        if (jobStatus == "running" || jobStatus == "blocked") {
            var present = false
            for (value in runningSubagentIds where value == id) {
                present = true
            }
            if (!present) {
                runningSubagentIds.add(id)
            }
        } else {
            var index: Int64 = 0
            while (index < runningSubagentIds.size) {
                if (runningSubagentIds[index] == id) {
                    runningSubagentIds.remove(at: index)
                } else {
                    index += 1
                }
            }
        }
        for (index in 0..subagentItems.size where subagentItems[index].id == id) {
            let current = subagentItems[index]
            subagentItems[index] = TuiSubagentInfo(
                current.id,
                if (agent == "") {
                    current.agent
                } else {
                    agent
                },
                jobStatus,
                if (label == "") {
                    current.task
                } else {
                    label
                }
            )
            return
        }
        let updated = ArrayList<TuiSubagentInfo>()
        for (item in subagentItems) {
            updated.add(item)
        }
        updated.add(
            TuiSubagentInfo(
                id,
                if (agent == "") {
                    "task"
                } else {
                    agent
                },
                jobStatus,
                label
            )
        )
        subagentItems = updated.toArray()
    }

    private func addCard(
        kind: UiCardKind,
        title: String,
        body: String
    ): Unit {
        let collapsed = kind == UiCardKind.Reasoning || (kind == UiCardKind.Tool && body.contains("\n"))
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard(
                nextCardId(uiCardKindName(kind)),
                kind,
                title,
                body,
                "completed",
                collapsed,
                ""
            )
        )
    }

    // Error cards always render with the failed badge (×) so live failures
    // and replayed transcript errors share one look.
    private func addErrorCard(title: String, body: String): Unit {
        for (card in ui.cards where card.kind == UiCardKind.Error && card.title == title && card.body == body) {
            card.state = "failed"
            card.markContentChanged()
            if (card.collapsed) {
                card.collapsed = false
                card.markViewChanged()
            }
            return
        }
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard(
                nextCardId("error"),
                UiCardKind.Error,
                title,
                body,
                "failed",
                false,
                ""
            )
        )
    }

    private func openComposerCompletion(): UpdateResult {
        completionSequence += 1
        let request = composer.area.beginCompletion("composer-completion-" + completionSequence.toString())
        let plan = commandCompletionPlan(request.value, request.cursor)
        let pathCandidates: Array<CompletionCandidate> = match (plan.target) {
            case CommandCompletionTarget.Path => pathCompletionCandidates(workspaceLabel, plan.activePrefix)
            case _ => []
        }
        let candidates = commandCompletionCandidates(plan, pathCandidates: pathCandidates)
        let completionItems = ArrayList<TextCompletionItem>()
        for (candidate in candidates) {
            if (completionItems.size >= 100) {
                break
            }
            completionItems.add(
                TextCompletionItem(
                    candidate.value,
                    insertText: candidate.insertText,
                    detail: candidate.detail
                )
            )
        }
        let items = completionItems.toArray()
        if (items.size == 0) {
            status = "no completion"
            return dirtyComposer()
        }
        _ = composer.area.handleCompletionEvent(
            Event.TextCompletion(
                request.requestId,
                TextCompletionResult(
                    request.requestId,
                    request.revision,
                    plan.replaceStart,
                    plan.replaceEnd,
                    items
                )
            )
        )
        status = items.size.toString() + " completion" + if (items.size == 1) {
            ""
        } else {
            "s"
        }
        dirtyComposer()
    }

    private func composerSlashInputError(): ?String {
        let value = composer.area.value.trimAscii()
        if (!value.startsWith("/")) {
            return None
        }
        if (parseCommandInputForCompletion(value).unterminatedQuote) {
            Some("cli.unterminated_quote: unterminated double quote")
        } else {
            None
        }
    }

    private func isCardFocusable(card: UiCard): Bool {
        card.kind != UiCardKind.Assistant && card.kind != UiCardKind.User && card.kind != UiCardKind.Reasoning
    }

    // Card focus navigation over the visible cards (transcriptRanges).
    // j/k move the focus; Enter/Space toggle the focused card. Up/Down stay
    // reserved for composer history navigation.
    private func moveCardFocus(delta: Int64): Unit {
        if (transcriptRanges.isEmpty()) {
            return
        }
        let currentRange = focusedRangeIndex()
        if (currentRange >= 0) {
            focusedCardIndex = currentRange
        } else if (focusedCardId != "") {
            focusedCardIndex = -1
        }
        var attempts: Int64 = 0
        while (attempts <= transcriptRanges.size) {
            if (focusedCardIndex < 0) {
                focusedCardIndex = if (delta > 0) {
                    0
                } else {
                    transcriptRanges.size - 1
                }
            } else {
                focusedCardIndex = min(
                    max(0, focusedCardIndex + delta),
                    max(0, transcriptRanges.size - 1)
                )
            }
            let candidate = transcriptRanges[focusedCardIndex].id
            var foldable = false
            for (card in ui.cards where card.id == candidate) {
                foldable = isCardFocusable(card)
            }
            if (foldable) {
                focusedCardId = candidate
                dirtyTranscriptAndActivity()
                return
            }
            attempts++
        }
    }

    private func focusFirstCard(): Unit {
        focusedCardIndex = -1
        moveCardFocus(1)
    }

    private func focusLastCard(): Unit {
        focusedCardIndex = transcriptRanges.size
        moveCardFocus(-1)
    }

    private func copyFocusedCard(): UpdateResult {
        if (focusedCardId == "") {
            status = "focus a card first"
            return dirtyTranscriptAndActivity()
        }
        for (card in ui.cards where card.id == focusedCardId) {
            let body = redactSensitiveText(stripAnsi(card.body).replace("\r", ""))
            let content = card.title + if (body == "") {
                ""
            } else {
                "\n" + body
            }
            status = backend.copyTextToClipboard(content)
            return dirtyTranscriptAndActivity()
        }
        status = "focused card is no longer available"
        dirtyTranscriptAndActivity()
    }

    private func setFocusedCardExpanded(expanded: Bool): UpdateResult {
        if (focusedCardId == "") {
            return UpdateResult.next()
        }
        for (card in ui.cards where card.id == focusedCardId) {
            if (!isCardFocusable(card)) {
                return UpdateResult.next()
            }
            if (card.collapsed != !expanded) {
                card.collapsed = !expanded
                card.markViewChanged()
            }
            card.collapseTouched = true
            if (!expanded && card.bodyScroll != 0) {
                card.bodyScroll = 0
                card.markViewChanged()
            }
            return dirtyTranscriptAndActivity()
        }
        UpdateResult.next()
    }

    private func scrollFocusedCardBy(delta: Int64): Bool {
        if (focusedCardId == "") {
            return false
        }
        for (card in ui.cards where card.id == focusedCardId) {
            if (!isCardFocusable(card) || card.collapsed) {
                return false
            }
            let viewport = max(1, card.bodyViewport)
            let maximum = max(0, card.bodyLines() - viewport)
            if (maximum <= 0) {
                return false
            }
            let next = min(maximum, max(0, card.bodyScroll - delta))
            if (next == card.bodyScroll) {
                return false
            }
            card.bodyScroll = next
            card.markViewChanged()
            _ = dirtyTranscriptAndActivity()
            return true
        }
        false
    }

    private func toggleFocusedCard(): UpdateResult {
        if (focusedCardId == "") {
            return UpdateResult.next()
        }
        for (card in ui.cards where card.id == focusedCardId) {
            if (!isCardFocusable(card)) {
                return UpdateResult.next()
            }
            card.collapsed = !card.collapsed
            card.collapseTouched = true
            card.markViewChanged()
            if (card.collapsed && card.bodyScroll != 0) {
                card.bodyScroll = 0
                card.markViewChanged()
            }
            return dirtyTranscriptAndActivity()
        }
        UpdateResult.next()
    }

    private func focusedRangeIndex(): Int64 {
        if (focusedCardId == "") {
            return -1
        }
        for (index in 0..transcriptRanges.size where transcriptRanges[index].id == focusedCardId) {
            return index
        }
        -1
    }

    private func focusCardAt(screenY: Int64): Unit {
        for (index in 0..transcriptRanges.size) {
            if (screenY >= transcriptRanges[index].top && screenY < transcriptRanges[index].bottom) {
                focusedCardIndex = index
                focusedCardId = transcriptRanges[index].id
                return
            }
        }
    }

    private func toggleCardAt(screenY: Int64): UpdateResult {
        for (range in transcriptRanges) {
            if (screenY >= range.top && screenY < range.bottom) {
                for (card in ui.cards where card.id == range.id) {
                    if (!isCardFocusable(card)) {
                        break
                    }
                    card.collapsed = !card.collapsed
                    card.collapseTouched = true
                    card.markViewChanged()
                    if (card.collapsed && card.bodyScroll != 0) {
                        card.bodyScroll = 0
                        card.markViewChanged()
                    }
                    return dirtyTranscriptAndActivity()
                }
                break
            }
        }
        UpdateResult.next()
    }

    private func toggleToolOutputVisibility(): UpdateResult {
        var count: Int64 = 0
        var hasExpanded = false
        for (card in ui.cards where isToolOutputCard(card)) {
            count++
            if (!card.collapsed) {
                hasExpanded = true
            }
        }
        if (count == 0) {
            status = "no tool output"
            return UpdateResult.next()
        }
        for (card in ui.cards where isToolOutputCard(card)) {
            if (card.collapsed != hasExpanded) {
                card.collapsed = hasExpanded
                card.markViewChanged()
            }
            card.collapseTouched = true
        }
        status = if (hasExpanded) {
            "tool outputs collapsed"
        } else {
            "tool outputs expanded"
        }
        dirtyTranscriptAndActivity()
    }

    private func toggleThinkingVisibility(): UpdateResult {
        var count: Int64 = 0
        var hasExpanded = false
        for (card in ui.cards where card.kind == UiCardKind.Reasoning) {
            count++
            if (!card.collapsed) {
                hasExpanded = true
            }
        }
        if (count == 0) {
            status = "no thinking blocks"
            return UpdateResult.next()
        }
        for (card in ui.cards where card.kind == UiCardKind.Reasoning) {
            if (card.collapsed != hasExpanded) {
                card.collapsed = hasExpanded
                card.markViewChanged()
            }
            card.collapseTouched = true
        }
        status = if (hasExpanded) {
            "thinking hidden"
        } else {
            "thinking shown"
        }
        dirtyTranscriptAndActivity()
    }

    private func hasAnimatedTranscriptCard(): Bool {
        // Only cards with a real activity animation (tool/approval/steer
        // spinners) need the timer-driven redraw. Assistant and reasoning
        // streaming text is event-driven: new deltas arrive as events and
        // render on their own, so redrawing the whole transcript every timer
        // tick while the model streams only burns terminal I/O.
        for (card in ui.cards where card.state == "running" && (card.kind == UiCardKind.Tool || card.kind == UiCardKind.Approval ||
            card.kind == UiCardKind.Steer)) {
            return true
        }
        false
    }

    private func settleStreamingCards(finalState: String): Unit {
        for (card in ui.cards where card.state == "streaming" && (card.kind == UiCardKind.Reasoning || card.kind == UiCardKind.Assistant)) {
            card.state = finalState
            // Thinking streams expanded; collapse them once the turn settles
            // so long transcripts stay compact (Ctrl+T expands again).
            if (card.kind == UiCardKind.Reasoning) {
                card.collapsed = true
            }
            card.markContentChanged()
        }
        for (card in ui.cards where card.kind == UiCardKind.Tool && card.state == "running") {
            card.state = finalState
            if (finalState == "completed" || finalState == "cancelled" || finalState == "failed") {
                card.collapsed = finalState == "completed"
            }
            card.markContentChanged()
        }
    }

    private func cachedMarkdownDocument(
        item: UiCard,
        theme: ProductTheme
    ): Document {
        match (markdownCache.get(item.id)) {
            case Some(entry) =>
                if (entry.body == item.body && entry.kind == item.kind) {
                    return entry.document
                }
                entry.body = item.body
                entry.kind = item.kind
                entry.document = markdownDocument(
                    item.body,
                    theme: productMarkdownTheme(theme, kind: item.kind),
                    preserveSoftBreaks: item.kind == UiCardKind.User
                )
                return entry.document
            case None => ()
        }
        let document = markdownDocument(
            item.body,
            theme: productMarkdownTheme(theme, kind: item.kind),
            preserveSoftBreaks: item.kind == UiCardKind.User
        )
        markdownCache[item.id] = MarkdownCacheEntry(
            item.id,
            item.body,
            item.kind,
            document
        )
        document
    }

    private func renderTranscriptDocument(
        items: Array<UiCard>,
        width: Int64,
        theme: ProductTheme
    ): Document {
        let lines = ArrayList<DocumentLine>()
        var renderedAny = false
        for (item in items) {
            let card = renderTranscriptCardDocument(item, width, theme)
            if (card.lines.isEmpty()) {
                continue
            }
            if (renderedAny) {
                lines.add(
                    DocumentLine(
                        DocumentLineKind.Blank,
                        "",
                        style: Style(bg: theme.background)
                    )
                )
            }
            for (line in card.lines) {
                lines.add(line)
            }
            renderedAny = true
        }
        Document(lines.toArray())
    }

    private func renderTranscriptCardDocument(
        item: UiCard,
        width: Int64,
        theme: ProductTheme
    ): Document {
        if (isApprovalRejectionToolCard(item)) {
            return Document([])
        }
        if (item.kind == UiCardKind.Reasoning && item.collapsed) {
            return Document([])
        }
        if (item.kind == UiCardKind.Assistant || item.kind == UiCardKind.Reasoning) {
            if (item.state == "streaming") {
                let lines = ArrayList<DocumentLine>()
                let bodyWidth = max(1, width - 2)
                for (line in wrapText(item.body, bodyWidth, WrapMode.Character)) {
                    lines.add(
                        DocumentLine(
                            DocumentLineKind.Paragraph,
                            [RichSpan(line, style: Style(fg: theme.text))]
                        )
                    )
                }
                return Document(lines.toArray())
            }
            let lines = ArrayList<DocumentLine>()
            for (line in cachedMarkdownDocument(item, theme).lines) {
                match (line.kind) {
                    case DocumentLineKind.Diagnostic => ()
                    case _ => lines.add(line)
                }
            }
            return Document(lines.toArray())
        }
        if (item.kind == UiCardKind.User) {
            let lines = ArrayList<DocumentLine>()
            for (line in cachedMarkdownDocument(item, theme).lines) {
                match (line.kind) {
                    case DocumentLineKind.Diagnostic => ()
                    case _ => lines.add(line)
                }
            }
            return Document(lines.toArray())
        }
        let card = productTranscriptItem(
            item,
            width,
            activityFrame: workingElapsedMillis / 80,
            theme: theme,
            approvalSelected: if (activeApprovalCard(item)) {
                approvalSelected
            } else {
                -1
            }
        )
        transcriptCardDocument(
            card,
            theme: productTranscriptCardTheme(theme, item)
        )
    }

    // VirtualTranscriptView owns the event rail and header.  Its source must
    // therefore return only the body for structured cards; returning the
    // Reusing a TranscriptCard document here would create a nested second card.
    private func renderTranscriptBodyDocument(
        item: UiCard,
        width: Int64,
        theme: ProductTheme
    ): Document {
        if (item.kind == UiCardKind.Assistant || item.kind == UiCardKind.Reasoning || item.kind == UiCardKind.User) {
            return renderTranscriptCardDocument(item, width, theme)
        }
        if (isApprovalRejectionToolCard(item)) {
            return Document([])
        }
        // The virtual transcript owns collapsed-card chrome.  Returning an
        // empty body here avoids parsing and laying out logs, file contents,
        // search results, and diffs that cannot be seen.  Expansion changes
        // the card revision and materializes the specialized renderer then.
        if (item.collapsed || (item.kind == UiCardKind.Approval && !approvalCardIsWaiting(item.state))) {
            if (item.kind == UiCardKind.Tool && isShellToolCard(item)) {
                return agentCardBodyDocument(item, width, theme)
            }
            return Document([])
        }
        var body = agentCardBodyDocument(item, width, theme)
        if (item.kind == UiCardKind.Approval && approvalCardIsWaiting(item.state)) {
            let lines = ArrayList<DocumentLine>()
            for (line in body.lines) {
                lines.add(line)
            }
            if (!lines.isEmpty()) {
                lines.add(DocumentLine(DocumentLineKind.Blank, ""))
            }
            let options = ["Allow once", approvalSessionLabel, "Deny"]
            for (index in 0..options.size) {
                let selected = index == approvalSelected
                lines.add(
                    DocumentLine(
                        DocumentLineKind.Paragraph,
                        (if (selected) {
                            "› "
                        } else {
                            "  "
                        }) + options[index],
                        style: if (selected) {
                            Style(fg: theme.accent, modifier: Modifier.strong())
                        } else {
                            Style(fg: theme.text)
                        }
                    )
                )
            }
            if (approvalInspectBody != "") {
                lines.add(
                    DocumentLine(DocumentLineKind.Paragraph, "  e  Inspect full content", style: Style(fg: theme.muted)))
            }
            body = Document(lines.toArray())
        }
        body
    }

    private func activeApprovalCard(item: UiCard): Bool {
        if (item.kind != UiCardKind.Approval) {
            return false
        }
        match (ui.approvalId) {
            case Some(id) => id == item.id
            case None => false
        }
    }

    private func nextCardId(prefix: String): String {
        cardSequence += 1
        prefix + "-" + cardSequence.toString()
    }

    private func assistantCardId(): String {
        "assistant-" + turnSequence.toString() + "-" + modelRoundSequence.toString()
    }

    private func reasoningCardId(): String {
        "reasoning-" + turnSequence.toString() + "-" + modelRoundSequence.toString()
    }

    private func renderAgentHub(
        canvas: Canvas,
        area: Rect,
        theme: ProductTheme
    ): Unit {
        if (area.width <= 0 || area.height <= 0) {
            return
        }
        canvas.fillRect(area, Style(bg: theme.background))
        let summary = subagentStatusSummary(subagentItems)
        drawHubBorder(
            canvas,
            area.x,
            area.y,
            area.width,
            "Agent Hub" + if (summary == "") {
                ""
            } else {
                " · " + summary
            },
            theme
        )
        let rail = if (terminalUnicode) {
            "│ "
        } else {
            "| "
        }
        for (row in (area.y + 1)..(area.bottom - 1)) {
            canvas.drawText(
                area.x,
                row,
                rail,
                Style(fg: theme.muted, bg: theme.background)
            )
        }
        let contentRows = max(1, area.height - 2)
        let entries = agentHubEntries()
        if (!entries.isEmpty()) {
            let capacity = max(1, contentRows / 2)
            let start = min(
                max(0, entries.size - capacity),
                max(0, modalSelected - capacity / 2)
            )
            let end = min(entries.size, start + capacity)
            var row = area.y + 1
            for (index in start..end) {
                let item = entries[index]
                let selected = index == modalSelected
                let marker = if (selected) {
                    "›"
                } else {
                    " "
                }
                let glyph = subagentStatusGlyph(item.status)
                let identity = if (item.id == MAIN_CONVERSATION_ID) {
                    "Main  primary"
                } else {
                    item.id + "  " + item.agent
                }
                let line = marker + " " + glyph + " " + identity + "  " + item.status
                canvas.drawText(
                    area.x + 2,
                    row,
                    cut(line, area.width - 2),
                    Style(
                        fg: if (selected) {
                            theme.accent
                        } else {
                            theme.text
                        },
                        bg: theme.background,
                        modifier: if (selected) {
                            Modifier.strong()
                        } else {
                            Modifier.none()
                        }
                    )
                )
                if (row + 1 < area.bottom - 1 && item.task != "") {
                    canvas.drawText(
                        area.x + 6,
                        row + 1,
                        cut(item.task.replace("\n", " "), area.width - 6),
                        Style(fg: theme.muted, bg: theme.background)
                    )
                }
                row += 2
            }
        }
        drawHubFooter(canvas, area, theme)
    }

    private func agentHubEntries(): Array<TuiSubagentInfo> {
        let entries = ArrayList<TuiSubagentInfo>()
        entries.add(
            TuiSubagentInfo(
                MAIN_CONVERSATION_ID,
                "primary",
                if (focusedSubagentId == "") {
                    "active"
                } else {
                    "ready"
                },
                if (subagentItems.isEmpty()) {
                    "Main · no subagents yet — task spawns appear here"
                } else {
                    "Main conversation"
                }
            )
        )
        for (item in subagentItems) {
            entries.add(item)
        }
        entries.toArray()
    }

    private func drawHubBorder(
        canvas: Canvas,
        x: Int64,
        y: Int64,
        width: Int64,
        title: String,
        theme: ProductTheme
    ): Unit {
        let prefix = if (terminalUnicode) {
            "╭─ "
        } else {
            "+- "
        }
        canvas.drawText(
            x,
            y,
            prefix,
            Style(fg: theme.muted, bg: theme.background)
        )
        canvas.drawText(
            x + 3,
            y,
            cut(title, max(1, width - 3)),
            Style(
                fg: theme.accent,
                bg: theme.background,
                modifier: Modifier.strong()
            )
        )
    }

    private func drawHubFooter(
        canvas: Canvas,
        area: Rect,
        theme: ProductTheme
    ): Unit {
        let hint = "↑/↓ select · Enter switch · Esc close"
        let prefix = if (terminalUnicode) {
            "╰─ "
        } else {
            "+- "
        }
        canvas.drawText(
            area.x,
            area.bottom - 1,
            prefix,
            Style(fg: theme.muted, bg: theme.background)
        )
        canvas.drawText(
            area.x + 3,
            area.bottom - 1,
            cut(hint, max(1, area.width - 3)),
            Style(fg: theme.muted, bg: theme.background)
        )
    }

    func render(frame: Frame): Unit {
        let canvas = frame.canvas()
        let theme = activeProductTheme(
            overrideName: themeName,
            customThemes: customThemeDefinitions
        )
        viewportArea = frame.area
        viewportHeight = frame.area.height
        // A partial redraw must not clear the whole backing buffer. Composer
        // edits normally dirty only the editor rows; clearing frame.area here
        // turned every key press into an O(viewport) operation even though the
        // transcript renderer was correctly skipped below.
        for (dirty in frame.dirtyRects()) {
            canvas.fillRect(
                dirty,
                Style(bg: theme.background)
            )
        }
        if (planReview.isActive()) {
            match (performanceTrace) {
                case Some(trace) =>
                    trace.layoutCompleted()
                    trace.screenPreparationCompleted()
                    trace.overlayStarted()
                case None => ()
            }
            planReview.render(frame, theme, terminalUnicode)
            match (performanceTrace) {
                case Some(trace) =>
                    trace.overlayCompleted()
                    match (virtualTranscriptView) {
                        case Some(view) => trace.transcriptMetrics(view.instrumentationMetrics())
                        case None => ()
                    }
                case None => ()
            }
            return
        }
        let queueHeight = if (agentHubActive) {
            1
        } else {
            queuedPromptRows()
        }
        let todoHeight = if (agentHubActive) {
            0
        } else {
            todos.stripRowCount(
                frame.area.width,
                frame.area.height,
                queueHeight
            )
        }
        composerHeight = if (agentHubActive) {
            min(
                max(6, 6 + subagentItems.size * 2),
                max(6, frame.area.height - 4)
            )
        } else if (secretSetupEntry()) {
            1
        } else {
            composer.visualHeight(
                max(1, frame.area.width - 4),
                composerMaximumHeight(
                    frame.area.height,
                    queuedRows: queueHeight,
                    todoRows: todoHeight
                )
            )
        }
        let editorHeight = if (agentHubActive) {
            composerHeight
        } else {
            composerHeight + 2
        }
        let rows = Layout.vertical(
            [
                Constraint.Min(3),
                Constraint.Length(1),
                Constraint.Length(queueHeight),
                Constraint.Length(todoHeight),
                Constraint.Length(editorHeight)
            ]
        ).split(frame.area)
        match (performanceTrace) {
            case Some(trace) => trace.layoutCompleted()
            case None => ()
        }
        workingArea = rows[1]
        queuedArea = if (agentHubActive) {
            Rect(0, 0, 0, 0)
        } else {
            rows[2]
        }
        todoArea = if (agentHubActive) {
            Rect(0, 0, 0, 0)
        } else {
            rows[3]
        }
        transcriptArea = rows[0]
        let inputArea = Rect(
            rows[4].x + 2,
            rows[4].y + 1,
            max(1, rows[4].width - 4),
            max(1, rows[4].height - 2)
        )
        composerInputArea = inputArea
        let renderModalOnly = modalRefreshOnly && modal.isSome()
        modalRefreshOnly = false
        match (performanceTrace) {
            case Some(trace) => trace.screenPreparationCompleted()
            case None => ()
        }
        if (!renderModalOnly) {
            if (agentHubActive && frame.isDirty(rows[2])) {
                drawTuiHeader(
                    canvas,
                    rows[2].x,
                    rows[2].y,
                    rows[2].width,
                    modelLabel,
                    backend.currentThinking(),
                    backend.currentWorkMode(),
                    workspaceLabel,
                    backend.currentBranch(),
                    backend.currentSession(),
                    taskLabel,
                    ui.inputTokens,
                    ui.outputTokens,
                    status,
                    theme
                )
            }
            match (performanceTrace) {
                case Some(trace) => trace.transcriptStarted()
                case None => ()
            }
            let transcriptInset: Int64 = if (frame.area.width < 72) {
                1
            } else {
                2
            }
            let available = max(
                1,
                rows[0].height
            )
            transcriptVisibleLines = available
            if (frame.isDirty(rows[0]) && ui.cards.isEmpty()) {
                match (performanceTrace) {
                    case Some(trace) => trace.transcriptPainted()
                    case None => ()
                }
                transcriptTotalLines = 0
                transcriptStartLine = 0
                scrollOffset = 0
                renderWelcome(canvas, rows[0], theme)
            } else if (frame.isDirty(rows[0])) {
                match (performanceTrace) {
                    case Some(trace) => trace.transcriptPainted()
                    case None => ()
                }
                let contentWidth = max(
                    1,
                    rows[0].width - transcriptInset * 2
                )
                match (virtualTranscriptView) {
                    case Some(view) =>
                        view.setThemeKey(themeName)
                        match (virtualTranscriptSource) {
                            case Some(source) =>
                                source.focusedCardId = focusedCardId
                                source.unicode = terminalUnicode
                                source.activityFrame = workingElapsedMillis / 80
                                source.approvalSelected = match (ui.approvalId) {
                                    case Some(_) => approvalSelected
                                    case None => -1
                                }
                            case None => ()
                        }
                        view.setCardChrome(true)
                        view.setUnicode(terminalUnicode)
                        match (virtualTranscriptSource) {
                            case Some(source) => source.setTheme(theme)
                            case None => ()
                        }
                        let cardViewport = max(1, min(20, available - 5))
                        configureCardBodyViewports(cardViewport)
                        if (!ui.cards.isEmpty()) {
                            view.setCardTheme(productTranscriptCardTheme(theme, ui.cards[0]))
                        }
                        if (ask.inlineEditorActive()) {
                            scrollOffset = 0
                            clearScrollAnchor()
                        }
                        if (scrollOffset <= 0) {
                            view.state.followBottom = true
                        } else {
                            view.state.followBottom = false
                        }
                        frame.renderWidget(
                            view,
                            Rect(
                                rows[0].x + transcriptInset,
                                rows[0].y,
                                contentWidth,
                                rows[0].height
                            )
                        )
                        // Snapshot the visible card screen ranges for click
                        // hit-testing (expand/collapse a single tool card).
                        transcriptRanges.clear()
                        for (range in view.lastVisibleRanges) {
                            transcriptRanges.add(
                                CardScreenRange(
                                    range.id,
                                    range.top,
                                    range.bottom
                                )
                            )
                        }
                        let total = view.totalRows()
                        transcriptTotalLines = total
                        transcriptStartLine = view.state.scrollTop
                        scrollOffset = max(
                            0,
                            total - available - view.state.scrollTop
                        )
                    case None => ()
                }
            }
            match (performanceTrace) {
                case Some(trace) => trace.transcriptCompleted()
                case None => ()
            }
            match (performanceTrace) {
                case Some(trace) => trace.activityStarted()
                case None => ()
            }
            if (frame.isDirty(rows[1])) {
                match (performanceTrace) {
                    case Some(trace) => trace.activityPainted()
                    case None => ()
                }
                let scrollLabel = transcriptScrollLabel()
                let activity = if (working && !ask.isActive()) {
                    workingIndicator(workingElapsedMillis) + " Working…  esc to interrupt"
                } else {
                    ""
                }
                let activityWidth = max(
                    0,
                    rows[1].width - 4 - displayWidth(scrollLabel) - (if (scrollLabel == "") {
                        0
                    } else {
                        1
                    })
                )
                if (activity != "") {
                    canvas.drawText(
                        rows[1].x + 2,
                        rows[1].y,
                        cut(activity, activityWidth),
                        Style(
                            fg: theme.warning,
                            bg: theme.background
                        )
                    )
                }
                if (scrollLabel != "") {
                    canvas.drawText(
                        max(rows[1].x + 2, rows[1].right - 2 - displayWidth(scrollLabel)),
                        rows[1].y,
                        scrollLabel,
                        Style(fg: theme.muted, bg: theme.background)
                    )
                }
            }
            match (performanceTrace) {
                case Some(trace) => trace.activityCompleted()
                case None => ()
            }
            match (performanceTrace) {
                case Some(trace) => trace.queueTodoStarted()
                case None => ()
            }
            if (!agentHubActive && frame.isDirty(rows[2])) {
                match (performanceTrace) {
                    case Some(trace) => trace.queueTodoPainted()
                    case None => ()
                }
                var queueRow: Int64 = 0
                for (kind in ["steer", "follow_up"]) {
                    let label = queuedPromptLabel(kind, rows[2].width)
                    if (label == "") {
                        continue
                    }
                    canvas.drawText(
                        rows[2].x + 2,
                        rows[2].y + queueRow,
                        cut(label, max(0, rows[2].width - 4)),
                        Style(fg: theme.secondary, bg: theme.background)
                    )
                    queueRow++
                }
            }
            if (!agentHubActive && frame.isDirty(rows[3])) {
                match (performanceTrace) {
                    case Some(trace) => trace.queueTodoPainted()
                    case None => ()
                }
                todos.renderStrip(canvas, rows[3], theme)
            }
            match (performanceTrace) {
                case Some(trace) => trace.queueTodoCompleted()
                case None => ()
            }
            composerArea = rows[4]
            if (frame.isDirty(rows[4])) {
                match (performanceTrace) {
                    case Some(trace) =>
                        trace.composerStarted()
                        trace.composerPainted()
                    case None => ()
                }
                if (agentHubActive) {
                    renderAgentHub(canvas, rows[4], theme)
                } else {
                    let composerHeaderArea = Rect(rows[4].x, rows[4].y, rows[4].width, 1)
                    let composerLeftRail = Rect(rows[4].x, inputArea.y, 1, inputArea.height)
                    let composerRightRail = Rect(rows[4].right - 1, inputArea.y, 1, inputArea.height)
                    let composerBottomArea = Rect(
                        rows[4].x,
                        rows[4].bottom - 1,
                        rows[4].width,
                        1
                    )
                    let headerDirty = frame.isDirty(composerHeaderArea)
                    let contentDirty = frame.isDirty(inputArea)
                    let chromeDirty = frame.isDirty(composerLeftRail) ||
                        frame.isDirty(composerRightRail) || frame.isDirty(composerBottomArea)
                    if (headerDirty) {
                        match (performanceTrace) {
                            case Some(trace) => trace.composerHeaderStarted()
                            case None => ()
                        }
                        drawTuiHeader(
                            canvas,
                            rows[4].x,
                            rows[4].y,
                            rows[4].width,
                            modelLabel,
                            backend.currentThinking(),
                            backend.currentWorkMode(),
                            workspaceLabel,
                            backend.currentBranch(),
                            backend.currentSession(),
                            taskLabel,
                            ui.inputTokens,
                            ui.outputTokens,
                            status,
                            theme
                        )
                        match (performanceTrace) {
                            case Some(trace) => trace.composerHeaderCompleted()
                            case None => ()
                        }
                    }
                    if (contentDirty && secretSetupEntry()) {
                        canvas.drawText(
                            inputArea.x,
                            inputArea.y,
                            cut(
                                "API key: " + maskedSecret(composer.area.value),
                                inputArea.width
                            ),
                            Style(fg: theme.text, bg: theme.background)
                        )
                    } else if (contentDirty) {
                        match (performanceTrace) {
                            case Some(trace) => trace.composerWidgetStarted()
                            case None => ()
                        }
                        frame.renderWidget(composer, inputArea)
                        match (performanceTrace) {
                            case Some(trace) => trace.composerWidgetCompleted()
                            case None => ()
                        }
                        if (composer.area.value.isEmpty()) {
                            match (performanceTrace) {
                                case Some(trace) => trace.composerPlaceholderStarted()
                                case None => ()
                            }
                            canvas.drawText(
                                inputArea.x,
                                inputArea.y,
                                cut("message", inputArea.width),
                                Style(fg: theme.secondary, bg: theme.background)
                            )
                            match (performanceTrace) {
                                case Some(trace) => trace.composerPlaceholderCompleted()
                                case None => ()
                            }
                        }
                    }
                    if (chromeDirty) {
                        match (performanceTrace) {
                            case Some(trace) => trace.composerChromeStarted()
                            case None => ()
                        }
                        drawComposerFrame(
                            canvas,
                            rows[4],
                            inputArea,
                            composer.area.value,
                            composer.area.cursor,
                            working,
                            !queuedPrompts.isEmpty(),
                            terminalUnicode,
                            theme
                        )
                    }
                    match (performanceTrace) {
                        case Some(trace) =>
                            if (chromeDirty) { trace.composerChromeCompleted() }
                            if (trace.composerMetricsEnabled()) {
                                let paintedRows = min(
                                    composer.visualHeight(inputArea.width, inputArea.height),
                                    inputArea.height
                                )
                                trace.composerWork(
                                    frameDirtyCellCount(frame, rows[4]),
                                    if (headerDirty) { rows[4].width } else { 0 },
                                    if (contentDirty) {
                                        if (paintedRows == 1 && !composer.area.value.contains("\n")) {
                                            min(displayWidth(composer.area.value), inputArea.width)
                                        } else {
                                            -1
                                        }
                                    } else { 0 },
                                    if (chromeDirty) {
                                        rows[4].width + inputArea.height * 2
                                    } else { 0 },
                                    if (contentDirty) { paintedRows } else { 0 },
                                    if (contentDirty) { paintedRows } else { 0 },
                                    composerHeightBeforePaint,
                                    composerHeightAfterPaint
                                )
                            }
                        case None => ()
                    }
                }
                match (performanceTrace) {
                    case Some(trace) => trace.composerCompleted()
                    case None => ()
                }
            }
        }
        match (modal) {
            case Some(kind) =>
                match (performanceTrace) {
                    case Some(trace) =>
                        trace.overlayStarted()
                        trace.overlayPainted()
                    case None => ()
                }
                let isDocument = match (kind) {
                    case TuiModalKind.Document | TuiModalKind.Session => true
                    case _ => false
                }
                let isSession = match (kind) {
                    case TuiModalKind.Session => true
                    case _ => false
                }
                let modalBodyDocument: Document = if (isSession) {
                    sessionModalDocument(
                        visibleSessionNodes,
                        sessionNodes,
                        modalSelected,
                        theme,
                        max(20, frame.area.width),
                        sessionMode,
                        sessionInput
                    )
                } else if (isDocument) {
                    let key = documentRevision.toString()
                    if (key != documentModalCacheKey) {
                        documentModalCacheKey = key
                        documentModalCache = markdownDocument(
                            documentBody,
                            theme: productMarkdownTheme(theme)
                        )
                    }
                    documentModalCache
                } else {
                    modalBody(modalItems, modalSelected, theme)
                }
                let overlayHost = frame.area
                activeModalArea = agentOverlayArea(
                    overlayHost,
                    document: isDocument,
                    itemCount: if (isSession) {
                        visibleSessionNodes.size
                    } else {
                        modalItems.size
                    }
                )
                renderAgentOverlay(
                    frame,
                    overlayHost,
                    if (isDocument) {
                        if (isSession) {
                            "Sessions"
                        } else {
                            documentTitle
                        }
                    } else {
                        modalTitle(kind)
                    },
                    modalBodyDocument,
                    if (isDocument) {
                        documentScroll
                    } else {
                        0
                    },
                    if (isSession) {
                        sessionSelectorFooter(sessionMode, sessionShowArchived, sessionFilter)
                    } else if (isDocument) {
                        "↑↓/PgUp/PgDn scroll · Esc close"
                    } else {
                        "↑↓/j/k select · Enter confirm · Esc cancel"
                    },
                    theme,
                    terminalUnicode,
                    document: isDocument,
                    itemCount: if (isSession) {
                        visibleSessionNodes.size
                    } else {
                        modalItems.size
                    },
                    documentCache: if (isDocument && !isSession) {
                        Some(documentWindowCache)
                    } else {
                        None
                    },
                    documentKey: documentModalCacheKey
                )
                match (performanceTrace) {
                    case Some(trace) => trace.overlayCompleted()
                    case None => ()
                }
            case None =>
                if (agentHubActive) {
                    ()
                } else if (secretSetupEntry()) {
                    frame.setCursor(
                        Position(
                            min(
                                rows[4].right - 1,
                                inputArea.x + 9 + displayWidth(maskedSecret(composer.area.value))
                            ),
                            inputArea.y
                        )
                    )
                } else {
                    frame.setCursor(composer.cursorPosition(inputArea))
                }
        }
        todos.renderEditor(frame, theme)
        if (ask.editorActive()) {
            ask.renderEditor(
                frame,
                theme,
                cardArea: askCardScreenArea(),
                fallbackArea: Some(transcriptArea),
                unicode: terminalUnicode
            )
        }
        match (performanceTrace) {
            case Some(trace) => match (virtualTranscriptView) {
                case Some(view) => trace.transcriptMetrics(view.instrumentationMetrics())
                case None => ()
            }
            case None => ()
        }
    }

    private func renderWelcome(
        canvas: Canvas,
        area: Rect,
        theme: ProductTheme
    ): Unit {
        if (area.width < 40 || area.height < 9) {
            canvas.drawText(
                area.x + 2,
                area.y + 1,
                cut("Welcome back!", area.width - 4),
                Style(
                    fg: theme.text,
                    bg: theme.background,
                    modifier: Modifier.strong()
                )
            )
            canvas.drawText(
                area.x + 2,
                area.y + 3,
                cut("π  " + modelLabel, area.width - 4),
                Style(fg: theme.accent, bg: theme.background)
            )
            canvas.drawText(
                area.x + 2,
                area.y + 5,
                cut("/help  /model  /session", area.width - 4),
                Style(fg: theme.muted, bg: theme.background)
            )
            return
        }
        let boxWidth = min(100, area.width - 2)
        let boxHeight = min(15, area.height - 1)
        let x = area.x + (area.width - boxWidth) / 2
        let y = area.y + max(0, (area.height - boxHeight) / 3)
        let split = if (boxWidth >= 72) {
            31
        } else {
            boxWidth
        }
        drawBox(canvas, Rect(x, y, boxWidth, boxHeight), theme.muted)
        if (split < boxWidth) {
            for (row in (y + 1)..(y + boxHeight - 1)) {
                canvas.drawText(
                    x + split,
                    row,
                    "│",
                    Style(fg: theme.muted, bg: theme.background)
                )
            }
        }
        canvas.drawText(
            x + 2,
            y + 2,
            cut("Welcome back!", max(1, split - 4)),
            Style(
                fg: theme.text,
                bg: theme.background,
                modifier: Modifier.strong()
            )
        )
        let logo = [
            "████████████████",
            "   ███    ███   ",
            "   ███    ███   ",
            "   ███    ███   ",
            "   ███    ███   "
        ]
        for (index in 0..logo.size where y + 4 + index < y + boxHeight - 3) {
            canvas.drawText(
                x + 3,
                y + 4 + index,
                cut(logo[index], max(1, split - 6)),
                Style(
                    fg: if (index < 2) {
                        theme.secondary
                    } else {
                        theme.accent
                    },
                    bg: theme.background
                )
            )
        }
        canvas.drawText(
            x + 2,
            y + boxHeight - 2,
            cut(modelLabel, max(1, split - 4)),
            Style(fg: theme.muted, bg: theme.background)
        )
        if (split < boxWidth) {
            let rightX = x + split + 3
            let rightWidth = max(1, boxWidth - split - 5)
            canvas.drawText(
                rightX,
                y + 2,
                cut("Shortcuts", rightWidth),
                Style(
                    fg: theme.text,
                    bg: theme.background,
                    modifier: Modifier.strong()
                )
            )
            let shortcuts = [
                "Tab         completion",
                "Esc         close / interrupt",
                "Ctrl+C      clear / exit",
                "Ctrl+O/T    tool / thinking"
            ]
            for (index in 0..shortcuts.size) {
                canvas.drawText(
                    rightX,
                    y + 4 + index,
                    cut(shortcuts[index], rightWidth),
                    Style(fg: theme.muted, bg: theme.background)
                )
            }
            canvas.drawText(
                rightX,
                y + 9,
                cut("Workspace", rightWidth),
                Style(
                    fg: theme.text,
                    bg: theme.background,
                    modifier: Modifier.strong()
                )
            )
            canvas.drawText(
                rightX,
                y + 11,
                cut(compactPath(workspaceLabel), rightWidth),
                Style(fg: theme.secondary, bg: theme.background)
            )
        }
    }

    func transcriptSize(): Int64 {
        ui.cards.size
    }

    func statusText(): String {
        status
    }

    func transcriptDocumentCalls(): Int64 {
        match (virtualTranscriptSource) {
            case Some(source) => source.documentCalls
            case None => 0
        }
    }

    func documentLayoutCalls(): Int64 {
        documentWindowCache.layouts()
    }

    func documentScrollPosition(): Int64 {
        documentScroll
    }

    func composerValueSize(): Int64 {
        composer.area.value.size
    }

    func unicodeMode(): Bool {
        terminalUnicode
    }

    func planReviewInteractionObserved(): Bool {
        let previousModal = modal
        let previousItems = modalItems
        let previousSelected = modalSelected
        let previousTitle = documentTitle
        let previousBody = documentBody
        let previousScroll = documentScroll
        let previousRevision = documentRevision
        let previousPlanState = planReview.beginProbe()
        let previousStatus = status
        let previousViewportArea = viewportArea
        let previousViewportHeight = viewportHeight
        let previousActiveModalArea = activeModalArea
        let previousMailboxChanged = mailboxChanged
        let previousMailboxViewportRefresh = mailboxViewportRefresh
        let previousWorking = working
        let previousMainWorking = mainWorking
        let previousTurnOwner = turnOwnerSubagentId
        let previousUiWorking = ui.working
        let previousWorkingElapsedMillis = workingElapsedMillis
        let previousModalRefreshOnly = modalRefreshOnly

        // This is a self-contained controller probe. Ask fixtures deliberately
        // keep their real turn alive while waiting for input, but that state
        // must not make Plan Review's edit interactions look busy.
        working = false
        mainWorking = false
        UiReducer.reduce(ui, UiEvent.SetWorking(false))

        var body = "Latest plan:\n\n# Goal\n\n"
        for (index in 0..32) {
            body += "- Step " + (index + 1).toString() + " · deterministic cached plan row\n"
        }
        body += "\n# Verification\n\nRun the TUI gate.\nEND-SENTINEL"
        _ = applyTurnAction(TuiTurnAction.OpenPlanReview(body))
        planReview.probeSetNavigation(2, PlanReviewFocus.Body, 1, 3)
        planReview.probeAddAnnotation("Goal", "Step 1", "stale annotation")
        let replacementBody = body + "\n\n# Replacement"
        _ = planReview.open(replacementBody)
        let resetState = planReview.probeSnapshot()
        let newPlanStateReset = resetState.contentHash == planContentHash(replacementBody) &&
            resetState.selected == 0 && resetState.focus == PlanReviewFocus.Actions &&
            resetState.tocSelected == 0 && resetState.scroll == 0 && resetState.annotationCount == 0

        planReview.probeSetNavigation(1, PlanReviewFocus.Body, 0, 2)
        planReview.probeAddAnnotation("Goal", "Step 2", "keep annotation")
        planReview.probeSetPending(false, true)
        let updatedBody = body + "\n\nUpdated after review."
        let updateResultAction = planReview.acceptTurnResult(
            "plan updated",
            TuiTurnAction.OpenPlanReview(updatedBody)
        )
        let preservedState = planReview.probeSnapshot()
        let updateResultPreservedState = updateResultAction.isNone() &&
            preservedState.contentHash == planContentHash(updatedBody) && preservedState.selected == 1 &&
            preservedState.focus == PlanReviewFocus.Body && preservedState.scroll == 2 &&
            preservedState.annotationCount == 1
        _ = planReview.open(body)
        status = planReview.statusText()
        let openedState = planReview.probeSnapshot()
        let opened = planReview.isActive() && openedState.contentHash == planContentHash(body) &&
            openedState.selected == 0 && openedState.focus == PlanReviewFocus.Actions &&
            status == "plan review · actions"
        let resetDisplay = handleKeyDown(
            KeyEvent(KeyCode.Char(r'l'), modifiers: KeyModifier(ctrl: true))
        )
        let resetCommandObserved = match (resetDisplay.command) {
            case Command.ResetTerminal => true
            case _ => false
        }
        let globalShortcutStatusSynced = resetCommandObserved && status == "terminal display reset" &&
            planReview.statusText() == status
        status = planReviewFocusStatus(planReview.probeSnapshot().focus)
        _ = planReview.setStatusText(status)

        let beforeRender = planReview.probeSnapshot()
        let layoutsBefore = beforeRender.layoutCount
        let parsesBefore = beforeRender.parseCount
        let wideBackend = TestBackend(area: Rect(0, 0, 80, 24))
        let wideTerminal = Terminal(wideBackend, renderMode: RenderMode.Diff)
        _ = wideTerminal.draw({frame => render(frame)})
        let wideVisual = wideBackend.snapshot()
        let afterFirstRender = planReview.probeSnapshot()
        let layoutsAfterFirst = afterFirstRender.layoutCount
        let parsesAfterFirst = afterFirstRender.parseCount
        let cachePrimed = afterFirstRender.cacheEntries == 1 && layoutsAfterFirst > layoutsBefore &&
            parsesAfterFirst == parsesBefore + 1
        let fullScreen = wideVisual.contains("Plan Review") &&
            wideVisual.contains("Approve and execute · fresh context") &&
            wideVisual.contains("Approve and compact context") &&
            wideVisual.contains("Approve and keep context") && wideVisual.contains("Refine plan")

        _ = wideTerminal.draw({frame => render(frame)})
        let unchangedRenderState = planReview.probeSnapshot()
        let unchangedFrameReused = unchangedRenderState.layoutCount == layoutsAfterFirst &&
            unchangedRenderState.parseCount == parsesAfterFirst
        let actionTopPage = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.PageUp), working))
        let actionTopBoundary = !actionTopPage.renderRequested && planReview.probeSnapshot().scroll == 0
        let downUpdate = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Down), working))
        let downSelected = downUpdate.renderRequested && planReview.probeSnapshot().selected == 1
        _ = wideTerminal.draw({frame => render(frame)})
        let selectionRenderState = planReview.probeSnapshot()
        let actionSelectionReused = selectionRenderState.layoutCount == layoutsAfterFirst &&
            selectionRenderState.parseCount == parsesAfterFirst
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Char(r'j')), working))
        let jSelected = planReview.probeSnapshot().selected == 2
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Up), working))
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Char(r'k')), working))
        let backAtFirst = planReview.probeSnapshot().selected == 0

        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Tab), working))
        let wideBodyFocused = planReview.probeSnapshot().focus == PlanReviewFocus.Body
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Tab), working))
        let wideTocFocused = planReview.probeSnapshot().focus == PlanReviewFocus.Toc
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Down), working))
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Enter), working))
        _ = wideTerminal.draw({frame => render(frame)})
        let tocJumpedToRenderedHeading = planReview.probeSnapshot().focus == PlanReviewFocus.Body &&
            wideBackend.snapshot().contains("Verification")

        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Home), working))
        let bodyTopUp = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Up), working))
        let bodyTopPage = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.PageUp), working))
        let bodyTopBoundary = !bodyTopUp.renderRequested && !bodyTopPage.renderRequested &&
            planReview.probeSnapshot().scroll == 0
        let firstScroll = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Down), working))
        let firstScrollChanged = firstScroll.renderRequested && planReview.probeSnapshot().scroll == 1
        _ = wideTerminal.draw({frame => render(frame)})
        let bodyScrollState = planReview.probeSnapshot()
        let bodyScrollReused = bodyScrollState.layoutCount == layoutsAfterFirst &&
            bodyScrollState.parseCount == parsesAfterFirst

        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.End), working))
        let bottom = planReview.probeSnapshot().scroll
        _ = wideTerminal.draw({frame => render(frame)})
        let endVisible = wideBackend.snapshot().contains("END-SENTINEL")
        let bodyBottomDown = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Down), working))
        let bodyBottomPage = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.PageDown), working))
        let bodyBottomBoundary = !bodyBottomDown.renderRequested && !bodyBottomPage.renderRequested &&
            planReview.probeSnapshot().scroll == bottom
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Right), working))
        let actionBottomPage = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.PageDown), working))
        let actionBottomBoundary = !actionBottomPage.renderRequested && planReview.probeSnapshot().scroll == bottom

        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Tab), working))
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Home), working))
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Right), working))
        let narrowBackend = TestBackend(area: Rect(0, 0, 60, 18))
        let narrowTerminal = Terminal(narrowBackend, renderMode: RenderMode.Diff)
        _ = narrowTerminal.draw({frame => render(frame)})
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Tab), working))
        let narrowBodyFocused = planReview.probeSnapshot().focus == PlanReviewFocus.Body
        let narrowDocumentArea = planReview.probeSnapshot().documentArea
        let mouseScroll = update(
            Event.Mouse(
                MouseEvent(
                    MouseKind.Scroll,
                    MouseButton.WheelDown,
                    narrowDocumentArea.x,
                    narrowDocumentArea.y
                )
            )
        )
        let mouseUsedPlanGeometry = mouseScroll.renderRequested && planReview.probeSnapshot().scroll > 0
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Tab), working))
        let narrowSkippedHiddenToc = planReview.probeSnapshot().focus == PlanReviewFocus.Actions

        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Char(r'e')), working))
        let editorOpenedState = planReview.probeSnapshot()
        let editOpened = editorOpenedState.mode == "edit" &&
            editorOpenedState.editorValue == stripPlanReviewLabel(body)
        planReview.probeSetEditor("edit", "")
        _ = applyPlanReviewTransition(
            planReview.updateKey(KeyEvent(KeyCode.Char(r's'), modifiers: KeyModifier(ctrl: true)), working)
        )
        _ = narrowTerminal.draw({frame => render(frame)})
        let emptyEditErrorVisible = narrowBackend.snapshot().contains("plan must not be empty")
        planReview.probeSetEditor("edit", stripPlanReviewLabel(body))
        let editorBeforePaste = planReview.probeSnapshot().editorValue
        let composerBeforePaste = composer.area.value
        let pasted = "\n\n## Pasted section\n\nPASTE-SENTINEL"
        let pasteUpdate = update(Event.Paste(pasted))
        let pasteRouted = pasteUpdate.renderRequested &&
            planReview.probeSnapshot().editorValue == editorBeforePaste + pasted && composer.area.value == composerBeforePaste
        _ = applyPlanReviewTransition(planReview.updateKey(KeyEvent(KeyCode.Esc), working))
        let editCancelledState = planReview.probeSnapshot()
        let editCancelled = editCancelledState.mode == "" && planReview.isActive() &&
            editCancelledState.contentHash == planContentHash(body)

        planReview.probeSetEditor("edit", "pending draft")
        planReview.probeSetPending(false, true)
        let pendingKeyUpdate = planReview.updateKey(KeyEvent(KeyCode.Char(r'x')), false).update
        let pendingPasteUpdate = planReview.paste("-mutated")
        let updatePendingInputFrozen = !pendingKeyUpdate.renderRequested && !pendingPasteUpdate.renderRequested &&
            planReview.probeSnapshot().editorValue == "pending draft"
        planReview.probeSetPending(false, false)
        planReview.probeSetEditor("", "pending draft")

        planReview.probeSetNavigation(0, PlanReviewFocus.Actions, 0, planReview.probeSnapshot().scroll)
        planReview.probeSetPending(true, false)
        let pendingActionsArea = planReview.probeSnapshot().actionsArea
        let pendingMouseUpdate = planReview.updateMouse(
            MouseEvent(
                MouseKind.Down,
                MouseButton.Left,
                pendingActionsArea.x,
                pendingActionsArea.y + 2
            )
        )
        let decisionPendingMouseFrozen = !pendingMouseUpdate.renderRequested && planReview.probeSnapshot().selected == 0
        planReview.probeSetPending(false, false)

        // Consumption is delivered before approved-plan execution finishes.
        // A timer-driven mailbox refresh must retire the full-screen overlay
        // immediately without stopping the still-running main turn.
        planReview.probeSetPending(true, false)
        working = true
        mainWorking = true
        turnOwnerSubagentId = ""
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        mailbox.push(TuiAgentEvent.PlanReviewConsumed(planContentHash(body)))
        let consumedUpdate = update(
            Event.Timer(
                TimerEvent(
                    AGENT_STREAM_TIMER,
                    elapsedMillis: 80
                )
            )
        )
        _ = narrowTerminal.draw({frame => render(frame)})
        let consumedVisual = narrowBackend.snapshot()
        let consumedBeforeResult = !planReview.isActive() && !planReview.hasPending() &&
            status == "executing approved plan" && working && mainWorking &&
            updateInvalidates(consumedUpdate, viewportArea) &&
            !consumedVisual.contains("Approve and execute · fresh context") &&
            !consumedVisual.contains("reviewing plan")

        working = previousWorking
        mainWorking = previousMainWorking
        turnOwnerSubagentId = previousTurnOwner
        workingElapsedMillis = previousWorkingElapsedMillis
        modalRefreshOnly = previousModalRefreshOnly
        UiReducer.reduce(ui, UiEvent.SetWorking(previousUiWorking))
        _ = planReview.open(body)
        status = planReview.statusText()

        planReview.probeSetPending(true, false)
        mailbox.complete(TuiTurnResult(
            "",
            "plan review failed: stale plan",
            planReviewDisposition: TuiPlanReviewDisposition.Retain
        ))
        let failedDecisionAction = drainMailbox()
        let failedDecisionState = planReview.probeSnapshot()
        let failedDecisionPreserved = failedDecisionAction.isNone() && !failedDecisionState.decisionPending &&
            planReview.isActive() && failedDecisionState.contentHash == planContentHash(body) &&
            failedDecisionState.body == body

        planReview.probeSetPending(true, false)
        mailbox.complete(
            TuiTurnResult(
                "",
                "error: fixture approved-plan execution failed",
                planReviewDisposition: TuiPlanReviewDisposition.Consumed
            )
        )
        let acceptedDecisionAction = drainMailbox()
        match (acceptedDecisionAction) {
            case Some(action) => _ = applyTurnAction(action)
            case None => ()
        }
        let acceptedDecisionClosed = !planReview.isActive() && !planReview.probeSnapshot().decisionPending &&
            status == "error: fixture approved-plan execution failed"

        _ = openModal(TuiModalKind.Model, ["model-a", "model-b"])
        _ = updateModal(KeyEvent(KeyCode.Char(r'j')))
        let genericJSelected = modalSelected == 1
        _ = updateModal(KeyEvent(KeyCode.Esc))
        let genericClosed = modal.isNone()

        modal = previousModal
        modalItems = previousItems
        modalSelected = previousSelected
        documentTitle = previousTitle
        documentBody = previousBody
        documentScroll = previousScroll
        documentRevision = previousRevision
        planReview.restoreProbe(previousPlanState)
        status = previousStatus
        viewportArea = previousViewportArea
        viewportHeight = previousViewportHeight
        activeModalArea = previousActiveModalArea
        mailboxChanged = previousMailboxChanged
        mailboxViewportRefresh = previousMailboxViewportRefresh
        working = previousWorking
        mainWorking = previousMainWorking
        turnOwnerSubagentId = previousTurnOwner
        UiReducer.reduce(ui, UiEvent.SetWorking(previousUiWorking))

        newPlanStateReset && updateResultPreservedState && opened && globalShortcutStatusSynced && fullScreen &&
            cachePrimed &&
            unchangedFrameReused && actionTopBoundary && downSelected &&
            actionSelectionReused && jSelected && backAtFirst && wideBodyFocused && wideTocFocused &&
            tocJumpedToRenderedHeading && bodyTopBoundary && firstScrollChanged && bodyScrollReused && endVisible &&
            bodyBottomBoundary && actionBottomBoundary && narrowBodyFocused && mouseUsedPlanGeometry &&
            narrowSkippedHiddenToc && editOpened && emptyEditErrorVisible && pasteRouted && editCancelled &&
            updatePendingInputFrozen && decisionPendingMouseFrozen && consumedBeforeResult &&
            failedDecisionPreserved && acceptedDecisionClosed && genericJSelected && genericClosed
    }

    func composerHistoryNavigationObserved(): Bool {
        let previousValue = composer.area.value
        composer.area.setValue("history first")
        let firstSubmitted = composer.handle(KeyEvent(KeyCode.Enter)).isSome()
        composer.area.setValue("history second")
        let secondSubmitted = composer.handle(KeyEvent(KeyCode.Enter)).isSome()

        _ = handleKeyDown(KeyEvent(KeyCode.Up))
        let newest = composer.area.value == "history second"
        _ = handleKeyDown(KeyEvent(KeyCode.Up))
        let oldest = composer.area.value == "history first"
        _ = handleKeyDown(KeyEvent(KeyCode.Down))
        let forward = composer.area.value == "history second"
        _ = handleKeyDown(KeyEvent(KeyCode.Down))
        let draftRestored = composer.area.value == ""

        composer.area.setValue(previousValue)
        firstSubmitted && secondSubmitted && newest && oldest && forward && draftRestored
    }

    func initialPromptObserved(): Bool {
        if (initialPrompt == "") {
            return true
        }
        var matches: Int64 = 0
        for (item in ui.cards where item.body.contains(initialPrompt)) {
            matches++
        }
        initialSubmitted && matches == 1
    }

    func hasInitialPrompt(): Bool {
        initialPrompt != ""
    }

    func themeAwareUserMessageObserved(): Bool {
        let width: Int64 = 24
        let custom = TuiThemeDefinition(
            "contract",
            "#101112",
            "#221d1a",
            "",
            "244",
            "#123456",
            "#234567",
            "#345678",
            "#456789",
            "#56789a",
            "",
            "#6789ab",
            ""
        )
        let cases = [axyndraTheme(), darkTheme(), lightTheme(), monoTheme(), configuredProductTheme(custom)]
        for (theme in cases) {
            let line = userMessageDocumentLine("theme sentinel", width, theme)
            let expected = Style(fg: theme.userMessageText, bg: theme.userMessageBg)
            if (line.spans.size != 1 || line.spans[0].style != expected || displayWidth(line.spans[0].text) !=
                displayWidth("  theme sentinel")) {
                return false
            }
        }
        themeNames([custom], "contract")[0] == "contract (current)" && themeNameFromLabel("contract (current)") ==
            "contract"
    }

    func ompShortcutContractObserved(): Bool {
        composer.area.setValue("/he")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        if (!composer.completionVisible()) {
            println("shortcut-contract: slash completion did not open")
            return false
        }
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        if (composer.area.value != "/help ") {
            println("shortcut-contract: slash completion did not accept")
            return false
        }

        composer.area.setValue("/todo don")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        if (composer.area.value != "/todo done ") {
            println("shortcut-contract: argument completion did not accept")
            return false
        }

        composer.area.setValue("agent_tu")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        if (!composer.completionVisible()) {
            println("shortcut-contract: path completion did not open")
            return false
        }
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        if (composer.area.value != "agent_tui/") {
            println("shortcut-contract: directory completion did not accept")
            return false
        }

        composer.area.setValue("agent_tu")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Esc)))
        if (composer.completionVisible()) {
            println("shortcut-contract: escape did not close completion")
            return false
        }

        composer.area.setValue("agent_tui/src/tu")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        if (composer.area.value != "agent_tui/src/tui.cj") {
            println("shortcut-contract: file completion did not accept")
            return false
        }

        let rootPlan = commandCompletionPlan("", 0)
        for (item in commandCompletionCandidates(
            rootPlan,
            pathCandidates: pathCompletionCandidates(workspaceLabel, "")
        ) where item.value.startsWith(".")) {
            return false
        }
        var dotGitVisible = false
        let dotPlan = commandCompletionPlan(".g", 2)
        for (item in commandCompletionCandidates(
            dotPlan,
            pathCandidates: pathCompletionCandidates(workspaceLabel, ".g")
        ) where item.value == ".git/") {
            dotGitVisible = true
        }
        let spacedPlan = commandCompletionPlan("My", 2)
        let spacedDirectory = commandCompletionCandidates(
            spacedPlan,
            pathCandidates: [CompletionCandidate("My Dir/", detail: "directory", directory: true)]
        )
        let spacedFile = commandCompletionCandidates(
            spacedPlan,
            pathCandidates: [CompletionCandidate("My File.txt", detail: "file")]
        )
        if (!dotGitVisible || spacedDirectory.size != 1 || spacedDirectory[0].insertText != "My\\ Dir/" ||
            spacedFile.size != 1 || spacedFile[0].insertText != "My\\ File.txt") {
            return false
        }

        let rootItems = commandCompletionCandidates(
            rootPlan,
            pathCandidates: pathCompletionCandidates(workspaceLabel, "")
        )
        if (rootItems.size > 1) {
            composer.area.setValue("history sentinel")
            let _ = composer.handle(KeyEvent(KeyCode.Enter))
            composer.area.setValue("")
            let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
            let _ = update(Event.KeyDown(KeyEvent(KeyCode.Down)))
            let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
            if (composer.area.value != rootItems[1].insertText) {
                println("shortcut-contract: completion selection did not move")
                return false
            }
        }

        composer.area.setValue("completion history sentinel")
        let _ = composer.handle(KeyEvent(KeyCode.Enter))
        let unmatchedDraft = "/todo no-such-subcommand"
        composer.area.setValue(unmatchedDraft, cursor: "/todo no".size)
        let unmatchedCursor = composer.area.cursor
        let queueSizeBeforeNoMatch = queuedPrompts.size
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        let noMatchPreserved = composer.area.value == unmatchedDraft && composer.area.cursor == unmatchedCursor &&
            !composer.completionVisible() && queuedPrompts.size == queueSizeBeforeNoMatch
        composer.area.setValue("")
        let _ = composer.handle(KeyEvent(KeyCode.Up))
        let noMatchHistoryPreserved = composer.area.value == "completion history sentinel"
        composer.area.setValue("")
        if (!noMatchPreserved || !noMatchHistoryPreserved) {
            println("shortcut-contract: no-match completion mutated composer state")
            return false
        }

        composer.area.setValue("/export \"unfinished")
        let wasWorking = working
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Enter)))
        if (composer.area.value != "/export \"unfinished" || working != wasWorking ||
            !status.contains("cli.unterminated_quote")) {
            println("shortcut-contract: unterminated quote was submitted")
            return false
        }
        composer.area.setValue("")

        let reasoning = UiCard(
            "shortcut-reasoning",
            UiCardKind.Reasoning,
            "Thinking",
            "details",
            collapsed: true
        )
        let tool = UiCard(
            "shortcut-tool",
            UiCardKind.Tool,
            "Tool result · read",
            "completed\nfirst line\nsecond line",
            collapsed: true
        )
        ui.cards.add(reasoning)
        ui.cards.add(tool)
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r't'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r'o'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        if (reasoning.collapsed || tool.collapsed) {
            return false
        }
        let expandedTool = productCardDetail(tool, 80)
        if (!expandedTool.contains("\n")) {
            return false
        }
        tool.collapsed = true
        let collapsedTool = productCardDetail(tool, 80)
        if (collapsedTool.contains("\n")) {
            return false
        }
        let structuredTool = UiCard(
            "shortcut-structured-tool",
            UiCardKind.Tool,
            "Tool result · bash",
            "completed\n{\"stdout\":\"full-output-sentinel\"}",
            state: "completed",
            collapsed: false
        )
        if (!productCardDetail(structuredTool, 80).contains("full-output-sentinel")) {
            return false
        }

        let reset = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r'l'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        match (reset.command) {
            case Command.ResetTerminal => ()
            case _ => return false
        }
        let suspend = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r'z'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        match (suspend.command) {
            case Command.Suspend => ()
            case _ => return false
        }

        composer.area.setValue("")
        let ctrlD = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r'd'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        match (ctrlD.flow) {
            case ControlFlow.Exit => ()
            case _ => return false
        }

        idleCtrlCArmed = false
        composer.area.setValue("draft")
        let firstCtrlC = update(
            Event.KeyDown(KeyEvent(KeyCode.Char(r'c'), modifiers: KeyModifier(ctrl: true)))
        )
        if (!composer.area.value.isEmpty()) {
            return false
        }
        match (firstCtrlC.flow) {
            case ControlFlow.Continue => ()
            case _ => return false
        }
        let secondCtrlC = update(Event.KeyDown(KeyEvent(KeyCode.CtrlC)))
        idleCtrlCArmed = false
        let exitObserved = match (secondCtrlC.flow) {
            case ControlFlow.Exit => true
            case _ => false
        }
        restoreShortcutTestState()
        exitObserved
    }

    // Removes the synthetic shortcut-test cards and restores the seed
    // reasoning card's collapsed state that the Ctrl+T toggle expanded.
    private func restoreShortcutTestState(): Unit {
        var index: Int64 = 0
        while (index < ui.cards.size) {
            let id = ui.cards[index].id
            if (id == "shortcut-reasoning" || id == "shortcut-tool" || id == "shortcut-structured-tool") {
                ui.cards.remove(at: index)
            } else {
                index += 1
            }
        }
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card
            .body
            .contains("The tool completed; summarize its result.")) {
            card.collapsed = true
            card.markViewChanged()
        }
    }

    func seedGallerySmoke(): Unit {
        for (fixture in transcriptGalleryFixtures()) {
            ui.cards.add(galleryCard(fixture.tool, fixture.state, true))
        }
        status = "card gallery · " + ui.cards.size.toString() + " fixtures"
    }

    func seedCardSmoke(): Unit {
        acceptAgentEvent(TuiAgentEvent.TextDelta("I will inspect the workspace."))
        acceptAgentEvent(
            TuiAgentEvent.ToolStarted(
                "read",
                "{\"path\":\"README.md\"}"
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.ToolCompleted(
                "read",
                false,
                TuiToolCompletionPayload(
                    detailPreview: "{\"content\":\"# axyndra\\n\\nA Cangjie agent product.\",\"bytes\":40}"
                )
            )
        )
        acceptAgentEvent(TuiAgentEvent.ReasoningDelta("The tool completed; summarize its result."))
        // This reasoning block belongs to an already-finished turn in the
        // seed: collapse it like the completion handler would.
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card
            .body
            .contains("The tool completed; summarize its result.")) {
            card.state = "completed"
            card.collapsed = true
            card.markContentChanged()
        }
        acceptAgentEvent(
            TuiAgentEvent.TextDelta(
                "## Result\n\nFinal summary after tool completion. " + "**bold-sentinel** and `code-sentinel`."))
        acceptAgentEvent(
            TuiAgentEvent.ToolStarted(
                "task",
                "{\"context\":\"count cj files\"}"
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.ToolCompleted(
                "task",
                true,
                TuiToolCompletionPayload(detailPreview: "{\"error\":\"tool.approval_rejected\"}")
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.Approval(
                "task",
                "operation-task-rejected",
                "call-task-rejected",
                "delegate",
                "",
                "high",
                "Delegation requires approval",
                "{\"context\":\"count cj files\"}",
                "Allow this delegation for this session",
                "Approval details",
                "{\"context\":\"count cj files\"}",
                ""
            )
        )
        UiReducer.reduce(
            ui,
            UiEvent.SetCardState(
                "approval-operation-task-rejected",
                "rejected",
                "rejected",
                false
            )
        )
        UiReducer.reduce(ui, UiEvent.ClearApproval)
        acceptAgentEvent(
            TuiAgentEvent.Approval(
                "edit",
                "operation-card",
                "call-card",
                "workspace.write",
                "README.md",
                "medium",
                "Target is a critical project file",
                "{\"input\":\"[README.md#ABCD]\"}",
                "Allow writes inside the workspace for this session",
                "Approval details",
                "{\"input\":\"[README.md#ABCD]\"}",
                ""
            )
        )
    }

    func seedDefaultGoldenSmoke(): Unit {
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard(
                "golden-default-user",
                UiCardKind.User,
                "You",
                "你好 · default golden fixture",
                "completed",
                false,
                ""
            )
        )
    }

    // The performance journey uses the same Agent event reducer as the
    // product stream, but keeps the scenario compact enough that its timing
    // reflects rendering rather than the full correctness contract suite.
    func seedPerformanceSmoke(): Unit {
        seedCardSmoke()
        acceptAgentEvent(
            TuiAgentEvent.ToolStartedWithId(
                "bash",
                "perf-shell",
                "{\"command\":\"cargo test --all\",\"cwd\":\"/workspace\"}"
            )
        )
        for (index in 0..32) {
            acceptAgentEvent(
                TuiAgentEvent.ToolOutput(
                    "perf-shell",
                    "[${index + 1}/32] compiling module-${index}\\n",
                    false
                )
            )
        }
        acceptAgentEvent(
            TuiAgentEvent.ToolCompletedWithId(
                "bash",
                "perf-shell",
                false,
                TuiToolCompletionPayload(
                    detailPreview: "{\"stdout\":\"test result: ok\",\"exit_code\":0,\"stdout_bytes\":15}",
                    stdoutPreview: "test result: ok",
                    exitCode: "0",
                    stdoutBytes: 15,
                    stderrBytes: 0
                )
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.ToolStartedWithId(
                "edit",
                "perf-edit",
                "{\"path\":\"src/runtime/TypeInfo.cj\"}"
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.ToolCompletedWithId(
                "edit",
                "perf-edit",
                false,
                TuiToolCompletionPayload(detailPreview: "{\"diff\":\"@@ -1 +1 @@\\n-old\\n+new\"}")
            )
        )
    }

    func emitMemoryState(trace: TuiPerformanceTrace): Unit {
        var payloadBytes: Int64 = 0
        var streamBufferBytes: Int64 = 0
        var expandedCards: Int64 = 0
        var expandedLargeFixtures: Int64 = 0
        for (card in ui.cards) {
            let bodyBytes: Int64 = unsafe { card.body.rawData().size }
            payloadBytes += bodyBytes
            payloadBytes += unsafe { card.toolArguments.rawData().size }
            payloadBytes += unsafe { card.toolOutput.rawData().size }
            payloadBytes += unsafe { card.toolResult.rawData().size }
            if (!card.collapsed && card.kind != UiCardKind.Assistant && card.kind != UiCardKind.User && card.kind != UiCardKind.Reasoning) {
                expandedCards++
                if (card.id.contains("memory-large-")) {
                    expandedLargeFixtures++
                }
            }
            if (card.kind == UiCardKind.Assistant || card.kind == UiCardKind.Reasoning) {
                streamBufferBytes += bodyBytes
            } else if (card.state == "streaming") {
                streamBufferBytes += unsafe { card.toolOutput.rawData().size }
                streamBufferBytes += unsafe { card.toolResult.rawData().size }
            }
        }
        let visibleCards = match (virtualTranscriptView) {
            case Some(view) => view.lastVisibleRanges.size
            case None => 0
        }
        let transcriptMetrics = match (virtualTranscriptView) {
            case Some(view) => view.metrics()
            case None => VirtualTranscriptMetrics(0, 0, 0, 0)
        }
        trace.memoryState(
            "\"card_count\":" + ui.cards.size.toString() +
                ",\"visible_card_count\":" + visibleCards.toString() +
                ",\"expanded_card_count\":" + expandedCards.toString() +
                ",\"large_fixture_expanded_count\":" + expandedLargeFixtures.toString() +
                ",\"card_payload_bytes\":" + payloadBytes.toString() +
                ",\"stream_buffer_bytes\":" + streamBufferBytes.toString() +
                ",\"markdown_cache_entries\":" + markdownCache.size.toString() +
                ",\"virtual_cache_entries\":" + transcriptMetrics.cacheEntries.toString() +
                ",\"measured_cache_entries\":" + transcriptMetrics.measuredEntries.toString() +
                ",\"cached_row_count\":" + transcriptMetrics.cachedRows.toString() +
                ",\"materialized_this_frame\":" + transcriptMetrics.materialized.toString() +
                ",\"append_only_full_layouts\":" + transcriptMetrics.appendOnlyFullLayouts.toString() +
                ",\"append_only_incremental_layouts\":" + transcriptMetrics.appendOnlyIncrementalLayouts.toString() +
                ",\"append_only_rewrapped_bytes\":" + transcriptMetrics.appendOnlyRewrappedBytes.toString() +
                ",\"document_cache_entries\":" + documentWindowCache.entries().toString() +
                ",\"document_buffer_cells\":" + documentWindowCache.bufferCapacityCells().toString() +
                ",\"mailbox_event_count\":" + mailbox.size().toString() +
                ",\"pending_job_count\":" +
                    ((if (working) { 1 } else { 0 }) + runningSubagentIds.size).toString() +
                ",\"queued_prompt_count\":" + queuedPrompts.size.toString() +
                ",\"tool_binding_count\":" + toolBindings.size.toString()
        )
    }

    func seedLongTranscriptPerformance(): Unit {
        performanceLongSeedStart = ui.cards.size
        performanceLongSeedCount = longTranscriptPerformanceCards()
        for (index in 0..performanceLongSeedCount) {
            if (index % 4 == 0) {
                ui.cards.add(
                    UiCard(
                        "perf-user-${index}",
                        UiCardKind.User,
                        "You",
                        "Inspect module ${index}: 中文、Emoji 🧭、wide 界 and ANSI \u{1b}[32mgreen\u{1b}[0m."
                    )
                )
            } else if (index % 4 == 1) {
                ui.cards.add(
                    UiCard(
                        "perf-assistant-${index}",
                        UiCardKind.Assistant,
                        "Assistant",
                        "### Result ${index}\n\n模块稳定 ✅. This paragraph exercises Markdown, 中文换行, Emoji 🚀 and wide glyphs while scrolling."
                    )
                )
            } else {
                let card = UiCard(
                    "perf-tool-${index}",
                    UiCardKind.Tool,
                    "Run fixture command ${index}",
                    "completed · 42 ms\n\nresult\nline one\nline two\nline three",
                    state: "completed",
                    collapsed: true,
                    footer: "exit 0 · 3 lines"
                )
                card.toolName = "bash"
                card.toolArguments = "{\"command\":\"fixture command ${index}\",\"cwd\":\"/workspace\"}"
                card.toolCallId = "perf-call-${index}"
                card.toolOutput = "line one\nline two\nline three"
                ui.cards.add(card)
            }
        }
        ui.cards.add(
            UiCard(
                PERF_STEP05_STREAM_CARD_ID,
                UiCardKind.Assistant,
                "Assistant",
                "stream target"
            )
        )
    }

    // Architecture-proof hook: exercise the real AgentScreen against both
    // the existing selective Rect path and a full-render reference.  It owns
    // no production state and is called only by the headless performance
    // fixture.
    func selectivePaintDifferentialObserved(): Bool {
        seedLongTranscriptPerformance()
        let initialArea = Rect(0, 0, 100, 28)
        let selectiveBackend = TestBackend(area: initialArea, captureSnapshots: false)
        let fullBackend = TestBackend(area: initialArea, captureSnapshots: false)
        let selective = Terminal(selectiveBackend, renderMode: RenderMode.Diff)
        let full = Terminal(fullBackend, renderMode: RenderMode.Full)
        _ = selective.draw { frame => render(frame) }
        _ = full.draw { frame => render(frame) }
        if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) { return false }

        for (text in [
            "x",
            " product wrap boundary 中文 wide 界 0123456789" +
                " product wrap boundary 中文 wide 界 0123456789",
            "\ncomplete product line"
        ]) {
            appendPerformanceStreamText(text)
            let update = dirtyTranscriptItem(PERF_STEP05_STREAM_CARD_ID)
            _ = selective.draw({ frame => render(frame) }, dirtyRects: update.dirtyRects)
            _ = full.draw { frame => render(frame) }
            if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) { return false }
        }

        appendPerformanceTranscriptItem()
        let appendUpdate = dirtyTranscript()
        _ = selective.draw({ frame => render(frame) }, dirtyRects: appendUpdate.dirtyRects)
        _ = full.draw { frame => render(frame) }
        if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) { return false }

        let scrollUpdate = update(Event.Mouse(MouseEvent(MouseKind.Scroll, MouseButton.WheelUp, 40, 10)))
        _ = selective.draw({ frame => render(frame) }, dirtyRects: scrollUpdate.dirtyRects)
        _ = full.draw { frame => render(frame) }
        if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) { return false }

        var composerDifferentialCase: Int64 = 0
        for (rune in [r'界', r'🙂', r'e', r'\u{301}']) {
            let composerUpdate = update(Event.KeyDown(KeyEvent(KeyCode.Char(rune))))
            _ = selective.draw({ frame => render(frame) }, dirtyRects: composerUpdate.dirtyRects)
            _ = full.draw { frame => render(frame) }
            if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) {
                println("composer differential failed unicode_case=${composerDifferentialCase}")
                return false
            }
            composerDifferentialCase++
        }
        composerDifferentialCase = 0
        for (code in [KeyCode.Left, KeyCode.Right, KeyCode.Backspace]) {
            let composerUpdate = update(Event.KeyDown(KeyEvent(code)))
            _ = selective.draw({ frame => render(frame) }, dirtyRects: composerUpdate.dirtyRects)
            _ = full.draw { frame => render(frame) }
            if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) {
                println("composer differential failed control_case=${composerDifferentialCase}")
                return false
            }
            composerDifferentialCase++
        }
        for (index in 0..120) {
            let composerUpdate = update(Event.KeyDown(KeyEvent(KeyCode.Char(r'x'))))
            _ = selective.draw({ frame => render(frame) }, dirtyRects: composerUpdate.dirtyRects)
            _ = full.draw { frame => render(frame) }
            if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) {
                println("composer differential failed wrap_index=${index}")
                return false
            }
        }

        let modalUpdate = openModal(TuiModalKind.Model, ["model-a", "model-b"])
        _ = selective.draw({ frame => render(frame) }, dirtyRects: modalUpdate.dirtyRects)
        _ = full.draw { frame => render(frame) }
        if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) { return false }
        let closeUpdate = update(Event.KeyDown(KeyEvent(KeyCode.Esc)))
        _ = selective.draw({ frame => render(frame) }, dirtyRects: closeUpdate.dirtyRects)
        _ = full.draw { frame => render(frame) }
        if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) { return false }

        let resized = Rect(0, 0, 72, 22)
        selectiveBackend.setSize(resized)
        fullBackend.setSize(resized)
        let resizeUpdate = update(Event.Resize(resized))
        _ = selective.draw({ frame => render(frame) }, dirtyRects: resizeUpdate.dirtyRects)
        _ = full.draw { frame => render(frame) }
        if (!headlessBuffersEqual(selectiveBackend.lastBuffer(), fullBackend.lastBuffer())) { return false }

        // Keep a negative control: omitting the Composer dirty rect must make
        // the selective buffer diverge from the full-render oracle.
        composer.area.setValue("INTENTIONAL_LOST_DIRTY_SENTINEL")
        _ = selective.draw(
            { frame => render(frame) },
            dirtyRects: DirtyRects([Rect(0, 0, 1, 1)])
        )
        let selectiveLostDirtySnapshot = selectiveBackend.snapshot()
        _ = full.draw { frame => render(frame) }
        let lostDirtyDetected = selectiveLostDirtySnapshot != fullBackend.snapshot()
        if (!lostDirtyDetected) {
            println("differential failed lost_dirty_negative_control")
        }
        lostDirtyDetected
    }

    // The differential fixture intentionally appends one stream target and
    // one additional transcript item after seeding the configured history.
    // Keep that accounting with the fixture so aggregate gates do not need a
    // duplicated magic number.
    func selectivePaintDifferentialExpectedFinalCount(): Int64 {
        if (performanceLongSeedStart < 0) { return ui.cards.size }
        performanceLongSeedStart + performanceLongSeedCount + 2
    }

    func longTranscriptFixtureContentPreserved(): Bool {
        if (performanceLongSeedStart < 0 || performanceLongSeedCount <= 0) { return false }
        let start = performanceLongSeedStart
        let last = start + performanceLongSeedCount - 1
        let stream = start + performanceLongSeedCount
        let appended = stream + 1
        if (appended >= ui.cards.size) { return false }
        let firstId = "perf-user-0"
        let lastIndex = performanceLongSeedCount - 1
        let lastId = if (lastIndex % 4 == 0) {
            "perf-user-${lastIndex}"
        } else if (lastIndex % 4 == 1) {
            "perf-assistant-${lastIndex}"
        } else {
            "perf-tool-${lastIndex}"
        }
        ui.cards[start].id == firstId &&
            ui.cards[last].id == lastId &&
            ui.cards[stream].id == PERF_STEP05_STREAM_CARD_ID &&
            ui.cards[appended].id.startsWith("perf-step05-append-")
    }

    private func appendPerformanceStreamText(text: String): Unit {
        UiReducer.reduce(
            ui,
            UiEvent.AppendText(
                PERF_STEP05_STREAM_CARD_ID,
                UiCardKind.Assistant,
                "Assistant",
                text
            )
        )
    }

    private func appendPerformanceTranscriptItem(): Unit {
        performanceAppendSequence++
        ui.cards.add(
            UiCard(
                "perf-step05-append-${performanceAppendSequence}",
                UiCardKind.Assistant,
                "Assistant",
                "appended product item ${performanceAppendSequence} · 中文 🧭"
            )
        )
    }

    func seedLargeMemoryCards(): Unit {
        let builder = StringBuilder()
        for (index in 0..2_000) {
            builder.append("line ${index} · 中文 🧭 e\u{0301} · bounded retained-heap fixture payload\n")
        }
        let lines = builder.toString()
        let fixtures = [
            ["memory-large-shell", "Run command", "bash"],
            ["memory-large-diff", "Edit large patch", "edit"],
            ["memory-large-mcp", "MCP · Large result", "mcp"],
            ["memory-large-read", "Read large file", "read"],
            ["memory-large-error", "Tool error", "unknown"]
        ]
        for (fixture in fixtures) {
            let card = UiCard(
                fixture[0],
                if (fixture[0] == "memory-large-error") { UiCardKind.Error } else { UiCardKind.Tool },
                fixture[1],
                lines,
                state: if (fixture[0] == "memory-large-error") { "failed" } else { "completed" },
                collapsed: true,
                footer: "2,000 lines · diagnostic fixture"
            )
            card.toolName = fixture[2]
            card.toolCallId = fixture[0]
            card.toolArguments = "{\"fixture\":\"large-memory-card\"}"
            card.toolOutput = lines
            ui.cards.add(card)
            if (fixture[0] == "memory-large-shell") {
                memoryLargeShellCardIndex = ui.cards.size - 1
            }
        }
    }

    private func toggleLargeMemoryFixture(): Unit {
        if (memoryLargeShellCardIndex < 0 || memoryLargeShellCardIndex >= ui.cards.size ||
            ui.cards[memoryLargeShellCardIndex].id != "memory-large-shell") {
            for (index in 0..ui.cards.size where ui.cards[index].id == "memory-large-shell") {
                memoryLargeShellCardIndex = index
                break
            }
        }
        if (memoryLargeShellCardIndex >= 0 && memoryLargeShellCardIndex < ui.cards.size &&
            ui.cards[memoryLargeShellCardIndex].id == "memory-large-shell") {
            let card = ui.cards[memoryLargeShellCardIndex]
            card.collapsed = !card.collapsed
            card.collapseTouched = true
            if (card.collapsed) {
                card.bodyScroll = 0
            }
            card.markViewChanged()
        }
    }

    private func replaceFixedMemoryCard(): Unit {
        memoryReplaceSequence = (memoryReplaceSequence + 1) % 1_000
        let sequence = if (memoryReplaceSequence < 10) {
            "00" + memoryReplaceSequence.toString()
        } else if (memoryReplaceSequence < 100) {
            "0" + memoryReplaceSequence.toString()
        } else {
            memoryReplaceSequence.toString()
        }
        let body = "fixed payload " + sequence +
            " · 中文 🧭 e\u{0301} · constant-size in-place update"
        for (card in ui.cards where card.id == "memory-fixed-replace") {
            card.body = body
            card.toolOutput = body
            card.markContentChanged()
            return
        }
        let card = UiCard(
            "memory-fixed-replace",
            UiCardKind.Tool,
            "Fixed payload update",
            body,
            state: "streaming",
            collapsed: true,
            footer: "diagnostic fixture"
        )
        card.toolName = "memory_fixture"
        card.toolCallId = "memory-fixed-replace"
        card.toolOutput = body
        ui.cards.add(card)
    }

    private func appendMemoryStreamCard(): Unit {
        let chunk = "memory stream · 中文 🧭 wide 界 · \u{1b}[36mANSI\u{1b}[0m\n"
        if (memoryStreamCardIndex >= 0 && memoryStreamCardIndex < ui.cards.size &&
            ui.cards[memoryStreamCardIndex].id == "memory-fixed-stream") {
            let card = ui.cards[memoryStreamCardIndex]
            card.toolOutput += chunk
            card.markContentChanged()
            return
        }
        for (index in 0..ui.cards.size where ui.cards[index].id == "memory-fixed-stream") {
            memoryStreamCardIndex = index
            ui.cards[index].toolOutput += chunk
            ui.cards[index].markContentChanged()
            return
        }
        let card = UiCard(
            "memory-fixed-stream",
            UiCardKind.Tool,
            "Fixed card stream",
            "streaming",
            state: "streaming",
            collapsed: true,
            footer: "diagnostic fixture"
        )
        card.toolName = "memory_fixture"
        card.toolCallId = "memory-fixed-stream"
        card.toolOutput = chunk
        ui.cards.add(card)
        memoryStreamCardIndex = ui.cards.size - 1
    }

    func seedDocumentPerformance(): Unit {
        var body = "# Commands\n\nType a command, or use Tab to complete it.\n\n"
        for (section in 0..12) {
            body += "## Section ${section + 1}\n\n"
            for (item in 0..12) {
                body += "- `/command-${section}-${item}` — 中文帮助 text with emoji 🧭 and a long argument description.  \n"
            }
            body += "\n"
        }
        modal = Some(TuiModalKind.Document)
        documentTitle = "Commands"
        documentBody = body
        documentRevision++
        documentScroll = 0
        documentModalCacheKey = ""
        activeModalArea = Rect(0, 0, 0, 0)
    }

    func seedAskSmoke(): Unit {
        let callId = "headless-ask-call"
        // The Ask fixture represents a turn after its initiating prompt was
        // already submitted. Seed that transcript edge explicitly before the
        // synthetic runtime enters its waiting state.
        if (!initialSubmitted && initialPrompt != "") {
            addCard(UiCardKind.User, "You", initialPrompt)
            initialSubmitted = true
        }
        mainWorking = true
        working = true
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        acceptAgentEvent(
            TuiAgentEvent.ToolStartedWithId(
                "ask",
                callId,
                "{\"questions\":[{\"id\":\"features\"}]}"
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.Ask(
                TuiAskRequest(
                    "headless-ask-request",
                    [
                        TuiAskQuestion(
                            "features",
                            "Which features should be enabled?",
                            [
                                TuiAskOption(
                                    "Export",
                                    description: "Portable reports",
                                    preview: "HTML and JSON"
                                )
                            ],
                            multi: true,
                            recommended: 0
                        ),
                        TuiAskQuestion(
                            "verification",
                            "Which verification should run?",
                            [
                                TuiAskOption(
                                    "Node tests",
                                    description: "Run the core engine contract"
                                ),
                                TuiAskOption(
                                    "Manual only",
                                    description: "Skip automated verification"
                                )
                            ],
                            recommended: 0
                        )
                    ],
                    callId: callId
                )
            )
        )
    }

    func askToolTakeoverObserved(): Bool {
        var matches: Int64 = 0
        var dedicated = false
        for (card in ui.cards where card.toolCallId == "headless-ask-call") {
            matches += 1
            dedicated = card.kind == UiCardKind.Ask && !card.body.contains("Generic tool view")
        }
        matches == 1 && dedicated
    }

    func askToolCompletionPreservesTakeoverObserved(): Bool {
        acceptAgentEvent(
            TuiAgentEvent.ToolCompletedWithId(
                "ask",
                "headless-ask-call",
                false,
                TuiToolCompletionPayload(detailPreview: "{\"answers\":[{\"id\":\"features\"}]}")
            )
        )
        var matches: Int64 = 0
        var dedicated = false
        for (card in ui.cards where card.toolCallId == "headless-ask-call") {
            matches += 1
            dedicated = card.kind == UiCardKind.Ask && !card.body.contains("Generic tool view")
        }
        matches == 1 && dedicated
    }

    func askWaitingSuppressesActivityObserved(): Bool {
        let previousArea = workingArea
        let previousMillis = workingElapsedMillis
        workingArea = Rect(0, 0, 100, 1)
        let tick = update(
            Event.Timer(
                TimerEvent(
                    AGENT_STREAM_TIMER,
                    elapsedMillis: previousMillis + 80
                )
            )
        )
        let observed = ask.isActive() && working && ui.working && !tick.renderRequested &&
            workingElapsedMillis == previousMillis
        workingArea = previousArea
        workingElapsedMillis = previousMillis
        observed
    }

    func sessionSelectorInteractionObserved(): Bool {
        let previousModal = modal
        let previousItems = modalItems
        let previousSelected = modalSelected
        let previousNodes = sessionNodes
        let previousVisible = visibleSessionNodes
        let previousFilter = sessionFilter
        let previousInput = sessionInput
        let previousMode = sessionMode
        let previousArchived = sessionShowArchived
        let previousStatus = status
        let previousActiveModalArea = activeModalArea
        let previousModalRefreshOnly = modalRefreshOnly
        let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        let root = TuiSessionNode("session-old", "Old work", "Old summary", "", "model-a", "normal", now - 2000, false)
        let current = TuiSessionNode("session-current", "Current work", "Current summary", "", "model-b", "normal", now,
            true)
        let archived = TuiSessionNode("session-archived", "", "Archived child", root.id, "model-a", "plan", now - 1000,
            false, archived: true)
        let _ = openSessionModal([current, archived, root])
        let preselected = visibleSessionNodes[modalSelected].id == current.id
        let _ = updateSessionModal(KeyEvent(KeyCode.Char(r'/')))
        activeModalArea = Rect(3, 2, 48, 12)
        let expectedSearchArea = activeModalArea
        modalRefreshOnly = false
        let searchUpdate = updateSessionModal(KeyEvent(KeyCode.Char(r'O')))
        let searchDirtyStayedLocal = match (searchUpdate.dirtyRects) {
            case Some(dirty) =>
                let rects = dirty.rects()
                rects.size == 1 && rects[0] == expectedSearchArea
            case None => false
        }
        let searchRefreshStayedLocal = searchUpdate.renderRequested && modalRefreshOnly && searchDirtyStayedLocal
        let _ = updateSessionModal(KeyEvent(KeyCode.Char(r'l')))
        let searched = visibleSessionNodes.size == 1 && visibleSessionNodes[0].id == root.id
        let _ = updateSessionModal(KeyEvent(KeyCode.Esc))
        let cleared = visibleSessionNodes.size == 3 && sessionMode == "search"
        let _ = updateSessionModal(KeyEvent(KeyCode.Esc))
        let closedAfterClear = modal.isNone()
        let _ = openSessionModal([current, archived, root])
        modalSelected = 0
        let _ = updateSessionModal(KeyEvent(KeyCode.Char(r'a')))
        let currentProtected = sessionMode == "browse" && status.contains("cannot be archived")
        modalSelected = 2
        let _ = updateSessionModal(KeyEvent(KeyCode.Char(r'a')))
        let archiveConfirmed = sessionMode == "confirm_archive"
        let _ = updateSessionModal(KeyEvent(KeyCode.Esc))
        modalSelected = 1
        let _ = updateSessionModal(KeyEvent(KeyCode.Char(r'u')))
        let restoreConfirmed = sessionMode == "confirm_restore"
        modal = previousModal
        modalItems = previousItems
        modalSelected = previousSelected
        sessionNodes = previousNodes
        visibleSessionNodes = previousVisible
        sessionFilter = previousFilter
        sessionInput = previousInput
        sessionMode = previousMode
        sessionShowArchived = previousArchived
        status = previousStatus
        activeModalArea = previousActiveModalArea
        modalRefreshOnly = previousModalRefreshOnly
        preselected && searchRefreshStayedLocal && searched && cleared && closedAfterClear && currentProtected &&
            archiveConfirmed && restoreConfirmed
    }

    func sessionSwitchRestoresTranscriptObserved(): Bool {
        let previousUi = ui
        let previousDraft = match (composer.draftText()) {
            case Some(value) => value
            case None => composer.area.value
        }
        let previousBackendDraft = backend.draft()
        let previousModel = modelLabel
        let previousFocused = focusedSubagentId
        let previousLabel = focusedConversationLabel
        let previousTask = taskLabel
        let previousTool = activeToolCardId
        let previousRound = modelRoundSequence
        let previousScroll = scrollOffset
        let previousWorking = working
        let previousStatus = status
        let previousViewport = configuredCardViewport
        let previousViewportCount = configuredCardViewportCount

        let stale = UiSnapshot()
        UiReducer.reduce(
            stale,
            UiEvent.UpsertCard(
                "session-stale",
                UiCardKind.Assistant,
                "Assistant",
                "stale session transcript",
                "completed",
                false,
                ""
            )
        )
        UiReducer.reduce(stale, UiEvent.UpsertCard("session-stale-2", UiCardKind.Tool, "Old", "old", "completed", true, ""))
        UiReducer.reduce(stale, UiEvent.UpsertCard("session-stale-3", UiCardKind.Tool, "Old", "old", "completed", true, ""))
        ui = stale
        match (virtualTranscriptSource) {
            case Some(source) => source.setSnapshot(stale)
            case None => ()
        }
        match (virtualTranscriptView) {
            case Some(view) => let _ = view.totalRows()
            case None => ()
        }
        composer.area.setValue("old draft")
        scrollOffset = 17

        var restoredDraft = "  会话草稿🙂\n"
        for (_ in 0..240) {
            restoredDraft += "跨会话大段粘贴 payload line\n"
        }
        restoredDraft += "尾部空格保留  "
        composer.restoreDraft(restoredDraft)
        let persistedExpandedDraft = match (draftForSessionSwitch()) {
            case Some(value) =>
                value == restoredDraft && backend.saveDraft(value) &&
                    backend.draft() == restoredDraft
            case None => false
        }
        composer.restoreDraft("old draft")

        let result = applyTurnAction(
            TuiTurnAction.SessionSelected(
                "Target session",
                true,
                restoredDraft,
                Some(
                    TuiConversationView(
                        "session-target",
                        "Main",
                        "ready",
                        true,
                        [
                            TuiTranscriptItem(
                                "session-target-tool",
                                UiCardKind.Tool,
                                "Run cargo test",
                                "completed",
                                collapsed: true,
                                toolName: "bash",
                                toolArguments: "{\"command\":\"cargo test\",\"cwd\":\"/tmp/project\"}",
                                toolCallId: "session-target-call",
                                toolOutput: "tests passed"
                            )
                        ]
                    )
                )
            )
        )
        let sourceRestored = match (virtualTranscriptSource) {
            case Some(source) => source.size() == 1 && source.itemId(0) == "session-target-tool"
            case None => false
        }
        let cacheRestored = match (virtualTranscriptView) {
            case Some(view) => view.metrics().cacheEntries == 1
            case None => false
        }
        let continued = match (result.flow) {
            case ControlFlow.Continue => true
            case ControlFlow.Exit => false
        }
        let collapsedDraft = composer.area.value.startsWith("[pasted ") && composer.area.value.contains(" bytes #")
        let expandedDraft = match (composer.draftText()) {
            case Some(value) => value == restoredDraft
            case None => false
        }
        let submittedDraft = match (composer.handle(KeyEvent(KeyCode.Enter))) {
            case Some(value) => value.text == restoredDraft
            case None => false
        }
        composer.restoreDraft(restoredDraft)
        let marker = composer.area.value
        composer.area.setValue(marker[..marker.size - 1])
        let damagedDraftBlocked = draftForSessionSwitch().isNone() && match (composer.lastError) {
            case Some(message) => message.contains("paste marker damaged")
            case None => false
        }
        let observed = persistedExpandedDraft && collapsedDraft && expandedDraft && submittedDraft && damagedDraftBlocked &&
            ui.cards.size == 1 &&
            ui.cards[0].id == "session-target-tool" && ui.cards[0].toolName == "bash" &&
            ui.cards[0].toolCallId == "session-target-call" && ui.cards[0].toolResult == "tests passed" &&
            sourceRestored && cacheRestored && focusedSubagentId == "" && focusedConversationLabel == "Main" && taskLabel == "" &&
            scrollOffset == 0 && continued

        ui = previousUi
        match (virtualTranscriptSource) {
            case Some(source) => source.setSnapshot(previousUi)
            case None => ()
        }
        match (virtualTranscriptView) {
            case Some(view) => let _ = view.totalRows()
            case None => ()
        }
        composer.restoreDraft(previousDraft)
        let _ = backend.saveDraft(previousBackendDraft)
        modelLabel = previousModel
        focusedSubagentId = previousFocused
        focusedConversationLabel = previousLabel
        taskLabel = previousTask
        activeToolCardId = previousTool
        modelRoundSequence = previousRound
        scrollOffset = previousScroll
        working = previousWorking
        status = previousStatus
        configuredCardViewport = previousViewport
        configuredCardViewportCount = previousViewportCount
        observed
    }

    func approvalRejectionRenderedOnce(): Bool {
        var sawApproval = false
        for (line in transcriptLines(ui.cards.toArray(), 100)) {
            if (line.text.contains("Tool result · task")) {
                return false
            }
            if (line.text.contains("Approval · Task") && line.text.contains("denied")) {
                sawApproval = true
            }
        }
        sawApproval
    }

    func approvalPausesWorkingImmediately(): Bool {
        let previousMainWorking = mainWorking
        let previousWorking = working
        let previousUiWorking = ui.working
        let previousStatus = status
        let previousApproval = ui.approvalId
        let previousCardCount = ui.cards.size
        mainWorking = true
        working = true
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        acceptAgentEvent(
            TuiAgentEvent.Approval(
                "task",
                "operation-second-task",
                "call-second-task",
                "delegate",
                "",
                "medium",
                "Delegation requires approval",
                "{\"name\":\"second-child\"}",
                "Allow this delegation for this session",
                "Approval details",
                "{\"name\":\"second-child\"}",
                ""
            )
        )
        let observed = !mainWorking && !working && !ui.working && status == "approval required" && match (ui.approvalId) {
            case Some(id) => id == "approval-operation-second-task"
            case None => false
        }
        while (ui.cards.size > previousCardCount) {
            ui.cards.remove(at: ui.cards.size - 1)
        }
        UiReducer.reduce(ui, UiEvent.ClearApproval)
        match (previousApproval) {
            case Some(id) => UiReducer.reduce(ui, UiEvent.AwaitApproval(id))
            case None => ()
        }
        UiReducer.reduce(ui, UiEvent.SetWorking(previousUiWorking))
        mainWorking = previousMainWorking
        working = previousWorking
        status = previousStatus
        observed
    }

    func approvalMailboxRefreshObserved(): Bool {
        let previousUi = ui
        let previousStatus = status
        let previousWorking = working
        let previousMainWorking = mainWorking
        let previousViewportArea = viewportArea
        let previousTranscriptArea = transcriptArea
        let previousScrollOffset = scrollOffset
        let previousMailboxChanged = mailboxChanged
        ui = UiSnapshot()
        status = "ready"
        working = true
        mainWorking = true
        viewportArea = Rect(0, 0, 80, 20)
        transcriptArea = Rect(0, 0, 80, 18)
        mailbox.push(
            TuiAgentEvent.Approval(
                "write",
                "operation-mailbox-refresh",
                "call-mailbox-refresh",
                "workspace.write",
                "child-approved.txt",
                "medium",
                "Target resolves inside the current workspace",
                "{\"path\":\"child-approved.txt\"}",
                "Allow writes inside the workspace for this session",
                "Approval details",
                "{\"path\":\"child-approved.txt\"}",
                ""
            )
        )
        let refresh = update(Event.Tick(TickEvent(deltaMillis: 16)))
        let visible = match (ui.approvalId) {
            case Some(id) => id == "approval-operation-mailbox-refresh"
            case None => false
        }
        let invalidated = updateInvalidates(refresh, viewportArea)
        ui = previousUi
        status = previousStatus
        working = previousWorking
        mainWorking = previousMainWorking
        viewportArea = previousViewportArea
        transcriptArea = previousTranscriptArea
        scrollOffset = previousScrollOffset
        mailboxChanged = previousMailboxChanged
        visible && invalidated
    }

    func approvalCancellationAndFailureSettlementObserved(): Bool {
        let previousUi = ui
        let previousStatus = status
        let previousWorking = working
        let previousMainWorking = mainWorking
        let previousIdleCtrlCArmed = idleCtrlCArmed
        let previousApprovalToolCardId = approvalToolCardId
        let previousApprovalSelected = approvalSelected
        let previousApprovalSessionLabel = approvalSessionLabel
        let previousApprovalInspectTitle = approvalInspectTitle
        let previousApprovalInspectBody = approvalInspectBody
        let previousActiveToolCardId = activeToolCardId
        let previousActiveToolCallId = activeToolCallId
        let previousActiveToolArguments = activeToolArguments
        let previousBindingCount = toolBindings.size
        ui = UiSnapshot()
        status = "working"
        working = true
        mainWorking = true
        idleCtrlCArmed = false
        acceptAgentEvent(
            TuiAgentEvent.ToolStartedWithId(
                "write",
                "call-approval-cancel",
                "{\"path\":\"/tmp/cube_lib/cube_model.js\",\"content\":\"fixture\"}"
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.Approval(
                "write",
                "operation-approval-cancel",
                "call-approval-cancel",
                "temp.write",
                "/tmp/cube_lib/cube_model.js",
                "medium",
                "Target is outside the current workspace",
                "Path    /tmp/cube_lib/cube_model.js\nAction  Create file",
                "Allow writes under /tmp/cube_lib for this session",
                "Approval details",
                "fixture",
                ""
            )
        )
        let waiting = match (toolCardForCall("call-approval-cancel")) {
            case Some(card) => card.state == "waiting"
            case None => false
        }
        let first = update(
            Event.KeyDown(KeyEvent(KeyCode.Char(r'c'), modifiers: KeyModifier(ctrl: true)))
        )
        let cancelled = ui.approvalId.isNone() && match (toolCardForCall("call-approval-cancel")) {
            case Some(card) => card.state == "cancelled"
            case None => false
        }
        let second = update(Event.KeyDown(KeyEvent(KeyCode.CtrlC)))
        let exits = match ((first.flow, second.flow)) {
            case (ControlFlow.Continue, ControlFlow.Exit) => true
            case _ => false
        }

        ui = UiSnapshot()
        status = "working"
        acceptAgentEvent(
            TuiAgentEvent.ToolStartedWithId(
                "write",
                "call-failed-settlement",
                "{\"path\":\"missing/child.txt\",\"content\":\"fixture\"}"
            )
        )
        mailbox.complete(TuiTurnResult("", "error: fixture write failed"))
        let _ = update(
            Event.AsyncCompleted(
                "agent-turn",
                Event.Message("agent-turn")
            )
        )
        let failedNotCompleted = match (toolCardForCall("call-failed-settlement")) {
            case Some(card) => card.state == "failed"
            case None => false
        }

        while (toolBindings.size > previousBindingCount) {
            toolBindings.remove(at: toolBindings.size - 1)
        }
        ui = previousUi
        status = previousStatus
        working = previousWorking
        mainWorking = previousMainWorking
        idleCtrlCArmed = previousIdleCtrlCArmed
        approvalToolCardId = previousApprovalToolCardId
        approvalSelected = previousApprovalSelected
        approvalSessionLabel = previousApprovalSessionLabel
        approvalInspectTitle = previousApprovalInspectTitle
        approvalInspectBody = previousApprovalInspectBody
        activeToolCardId = previousActiveToolCardId
        activeToolCallId = previousActiveToolCallId
        activeToolArguments = previousActiveToolArguments
        waiting && cancelled && exits && failedNotCompleted
    }

    func unifiedCardChromeObserved(): Bool {
        var sawTool = false
        var sawRejected = false
        var sawAwaiting = false
        for (line in transcriptLines(ui.cards.toArray(), 100)) {
            if (line.text.startsWith("✓ Read ") || line.text.startsWith("✓ Tool result · read · completed") ||
                line.text.startsWith("[+] Read ") || line.text.startsWith("[+] Tool result · read · completed")) {
                sawTool = true
            }
            if (line.text.startsWith("⊘ Approval · Task · denied") || line
                .text
                .startsWith("× Approval · Task · denied") || line.text.startsWith("✗ Approval · Task · denied") ||
                line.text.startsWith("[!] Approval · Task · denied")) {
                sawRejected = true
            }
            if (line.text.startsWith("? Approval · Edit file · Awaiting your decision") || line
                .text
                .startsWith("! Approval · Edit file · Awaiting your decision") || line
                .text
                .startsWith("[?] Approval · Edit file · Awaiting your decision")) {
                sawAwaiting = true
            }
        }
        sawTool && sawRejected && sawAwaiting
    }

    func toolCardPresentationObserved(): Bool {
        // Tool cards carry a human summary title (never the raw argument
        // object), a structured body (path/command + result sections), and
        // ANSI-free terminal output.
        var sawSummaryTitle = false
        var sawStructuredBody = false
        for (card in ui.cards) {
            if (card.kind == UiCardKind.Tool && card.title.startsWith("Read ")) {
                sawSummaryTitle = true
            }
            if (card.kind == UiCardKind.Tool && card.body.contains("\nresult\n")) {
                sawStructuredBody = true
            }
        }
        let runSummary = summarizeToolCall(
            "bash",
            "{\"command\":\"find . | wc -l\"}"
        )
        let readSummary = summarizeToolCall(
            "read",
            "{\"path\":\"src/main.cj\"}"
        )
        let grepSummary = summarizeToolCall(
            "grep",
            "{\"pattern\":\"TypeInfo\",\"path\":\"runtime/\"}"
        )
        let summaryOk = runSummary == "Run find . | wc -l" && readSummary == "Read src/main.cj" && grepSummary ==
            "Search \"TypeInfo\" in runtime/"
        let ansiText = stripAnsi("ok \u{1b}[32mgreen\u{1b}[0m end")
        let ansiOk = !ansiText.contains("\u{1b}") && ansiText.contains("green")
        // A running card body shows structured parameters, never the raw
        // argument JSON.
        let runningBody = beautifyToolDetail(
            "read",
            "{\"path\":\"src/main.cj\"}",
            "",
            false
        )
        let runningOk = runningBody.contains("path") && !runningBody.contains("{\"path\"")
        // Shell cards show stdout (not the raw result JSON) and the footer
        // summarizes exit code + line count.
        let bashBody = beautifyToolDetail(
            "bash",
            "{\"command\":\"ls\"}",
            "{\"exit_code\":0,\"stdout\":\"a\\nb\"}",
            false
        )
        let bashOk = bashBody.contains("a\nb") && !bashBody.contains("exit_code")
        let footerText = toolFooter(
            "bash",
            "{\"exit_code\":0,\"stdout\":\"a\\nb\"}"
        )
        let footerOk = footerText == "exit 0 · 2 lines"
        // Output windowing: 12-60 lines show first 6 + last 6 with a hidden
        // count; over 60 show first 5 + last 8.
        var longText = ""
        for (i in 0..30) {
            longText += "line " + i.toString() + "\n"
        }
        let windowed = limitToolDetail(longText, 0)
        let windowOk = windowed.contains("line 0") && windowed.contains("line 29") && windowed.contains("lines hidden")
        sawSummaryTitle && sawStructuredBody && summaryOk && ansiOk && runningOk && bashOk && footerOk && windowOk
    }

    func markdownRenderingObserved(): Bool {
        // Layout-independent markdown check: render the seeded assistant
        // card directly and require the emphasis markers to be consumed.
        var ok = false
        for (card in ui.cards where card.kind == UiCardKind.Assistant && card.body.contains("bold-sentinel")) {
            let document = renderTranscriptCardDocument(
                card,
                100,
                activeProductTheme(
                    overrideName: themeName,
                    customThemes: customThemeDefinitions
                )
            )
            var text = ""
            for (line in document.lines) {
                for (span in line.spans) {
                    text += span.text
                }
            }
            if (text.contains("bold-sentinel") && !text.contains("**bold-sentinel**")) {
                ok = true
            }
        }
        ok
    }

    func cardFocusNavigationObserved(): Bool {
        // j moves card focus, Enter toggles the focused card, and the
        // focused card title carries the › marker.
        composer.area.setValue("")
        UiReducer.reduce(ui, UiEvent.ClearApproval)
        let _ = AppTestRunner.run(
            HeadlessScript().tick(count: 2),
            {frame => render(frame)},
            {event => update(event)},
            options: HeadlessRunOptions(
                area: Rect(0, 0, 100, 28),
                ticks: 2
            )
        )
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Char(r'j'))))
        if (focusedCardIndex < 0 || focusedCardId == "") {
            return false
        }
        var before: Bool = false
        for (card in ui.cards where card.id == focusedCardId) {
            before = card.collapsed
        }
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Enter)))
        var after: Bool = before
        for (card in ui.cards where card.id == focusedCardId) {
            after = card.collapsed
        }
        var sawFocusMarker = false
        match (virtualTranscriptSource) {
            case Some(source) =>
                source.focusedCardId = focusedCardId
                var titleIndex: Int64 = -1
                for (index in 0..ui.cards.size) {
                    if (ui.cards[index].id == focusedCardId) {
                        titleIndex = index
                    }
                }
                if (titleIndex >= 0 && source.itemTitle(titleIndex).startsWith("› ")) {
                    sawFocusMarker = true
                }
            case None => ()
        }
        // Restore the seed layout: toggle the card back and drop the focus
        // so the main golden script sees the same cards as the other
        // assertions.
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Enter)))
        focusedCardIndex = -1
        focusedCardId = ""
        before != after && sawFocusMarker
    }

    func staleCardFocusToggleObserved(): Bool {
        let _ = AppTestRunner.run(
            HeadlessScript().tick(count: 1),
            {frame => render(frame)},
            {event => update(event)},
            options: HeadlessRunOptions(area: Rect(0, 0, 100, 28), ticks: 1)
        )
        focusLastCard()
        if (focusedCardId == "") {
            return false
        }
        var before = false
        for (card in ui.cards where card.id == focusedCardId) {
            before = card.collapsed
        }
        // Expanding a large card can reduce the visible range count before
        // the next key arrives.  The stable id, not this stale index, must be
        // authoritative for the toggle.
        focusedCardIndex = transcriptRanges.size + 2
        let _ = toggleFocusedCard()
        var after = before
        for (card in ui.cards where card.id == focusedCardId) {
            after = card.collapsed
        }
        let _ = toggleFocusedCard()
        focusedCardIndex = -1
        focusedCardId = ""
        before != after
    }

    func cardChromeObserved(): Bool {
        // The virtual transcript must wrap every card in the omp-style
        // rounded border: a top title row (╭── ... ╮) and a bottom row
        // (╰── ... ╯). Rendering goes through the real VirtualTranscriptView
        // so cardChrome must be enabled for the border to appear.
        let result = AppTestRunner.run(
            HeadlessScript().tick(count: 2),
            {frame => render(frame)},
            {event => update(event)},
            options: HeadlessRunOptions(
                area: Rect(0, 0, 100, 28),
                ticks: 2
            )
        )
        var sawTop = false
        var sawBottom = false
        for (snapshot in result.snapshots) {
            for (line in snapshot.split("\n")) {
                if (line.contains("╭─ ") || line.contains("+- ")) {
                    sawTop = true
                }
                if (line.contains("╰─ ") || line.contains("+- ")) {
                    sawBottom = true
                }
            }
        }
        sawTop && sawBottom
    }

    func revisionUtf8Safe(): Bool {
        // A card whose body is full of multi-byte characters must not crash
        // the revision sampler: its byte-based head/tail slices must land on
        // UTF-8 rune boundaries (previously threw IllegalArgumentException).
        var chineseBody = ""
        for (i in 0..60) {
            chineseBody += "中文内容行" + i.toString() + "\n"
        }
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard("utf8-probe", UiCardKind.Assistant, "中文标题", chineseBody, "completed", false, "")
        )
        var ok = false
        try {
            let result = AppTestRunner.run(
                HeadlessScript().tick(count: 2),
                {frame => render(frame)},
                {event => update(event)},
                options: HeadlessRunOptions(
                    area: Rect(0, 0, 100, 28),
                    ticks: 2
                )
            )
            ok = true
            // Double assertion: no exception AND the card body actually
            // rendered. Wide glyphs occupy two cells, so strip spaces.
            var sawText = false
            for (snapshot in result.snapshots) {
                if (snapshot.replace(" ", "").contains("中文内容行59")) {
                    sawText = true
                }
            }
            if (!sawText) {
                ok = false
            }
        } catch (_: Exception) {
            ok = false
        }
        for (index in 0..ui.cards.size) {
            if (ui.cards[index].id == "utf8-probe") {
                ui.cards.remove(at: index)
                break
            }
        }
        ok
    }

    func markdownUtf8Safe(): Bool {
        // Completed assistant cards render markdown through
        // cachedMarkdownDocument; a list item whose marker is followed by a
        // 4-byte character used to slice mid-rune in the task-marker check
        // and throw IllegalArgumentException.
        var listBody = ""
        for (i in 0..30) {
            listBody += "- 🎯 任务项" + i.toString() + "\n"
        }
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard("md-utf8-probe", UiCardKind.Assistant, "助理回复", listBody, "completed", false, "")
        )
        var ok = false
        try {
            let result = AppTestRunner.run(
                HeadlessScript().tick(count: 2),
                {frame => render(frame)},
                {event => update(event)},
                options: HeadlessRunOptions(
                    area: Rect(0, 0, 100, 28),
                    ticks: 2
                )
            )
            ok = true
            // Double assertion: no exception AND the emoji list rendered.
            var sawText = false
            for (snapshot in result.snapshots) {
                if (snapshot.replace(" ", "").contains("任务项29")) {
                    sawText = true
                }
            }
            if (!sawText) {
                ok = false
            }
        } catch (_: Exception) {
            ok = false
        }
        for (index in 0..ui.cards.size) {
            if (ui.cards[index].id == "md-utf8-probe") {
                ui.cards.remove(at: index)
                break
            }
        }
        ok
    }

    func utf8BoundarySamplesSafe(): Bool {
        // Shared UTF-8 boundary corpus (mirrored in cj_markdown
        // markdown_test.cj and cj_tui core virtual_transcript_test.cj).
        // Each sample must render through the real pipeline without
        // throwing AND keep its marker text in the snapshot.
        let samples = [
            ("ascii", "plain ascii body\n\n- item one\n- item two\n\n# Heading\n\n```cj\nmain()\n```\n", "item one"),
            ("two-byte", "Café résumé naïve €50\n\n- édition spéciale\n- piñata ñoño\n", "édition spéciale"),
            ("three-byte",
                "中文标题\n\n- 列表项一\n- 列表项二\n\n## 二级标题\n\n| 列A | 列B |\n| --- | --- |\n| 甲 | 乙 |\n\n这是一段很长的中文内容。\n",
                "列表项一"),
            ("four-byte", "🎯 任务列表\n\n- 🎯 任务一\n- [x] ✅ 已完成\n- 🚀 启动\n\n> 引用 🎉\n", "任务一"),
            ("zwj", "家庭 👨👩👧 组合\n\n- 👨👩👧 三个人\n- 组合 🧑🤝🧑 与 🇨🇳\n", "👨👩👧 三个人"),
            ("mixed-long",
                "🚀 综合样本\n\n# 标题一\n\n- 🎯 中文任务 éé\n- [x] ✅ 完成项\n- 👨👩👧 家庭项\n\n## 二级 **加粗中文**\n\n1. 有序一\n2. 有序二\n\n```\n代码块中文\n```\n\n| 名称 | 状态 |\n| --- | --- |\n| 中文 | ✅ |\n\n很长的一段内容…\n",
                "中文任务 éé")
        ]
        var allOk = true
        for (sample in samples) {
            UiReducer.reduce(
                ui,
                UiEvent.UpsertCard("utf8-sample-" + sample[0], UiCardKind.Assistant, "样本 " + sample[0], sample[1], "completed",
                    false, "")
            )
            var ok = false
            try {
                let result = AppTestRunner.run(
                    HeadlessScript().tick(count: 2),
                    {frame => render(frame)},
                    {event => update(event)},
                    options: HeadlessRunOptions(
                        area: Rect(0, 0, 100, 28),
                        ticks: 2
                    )
                )
                ok = true
                var sawMarker = false
                for (snapshot in result.snapshots) {
                    if (snapshot.replace(" ", "").contains(sample[2].replace(" ", ""))) {
                        sawMarker = true
                    }
                }
                if (!sawMarker) {
                    ok = false
                }
            } catch (_: Exception) {
                ok = false
            }
            for (index in 0..ui.cards.size) {
                if (ui.cards[index].id.startsWith("utf8-sample-")) {
                    ui.cards.remove(at: index)
                    break
                }
            }
            if (!ok) {
                println("utf8 boundary sample failed: " + sample[0])
                allOk = false
            }
        }
        allOk
    }

    func streamTimerAdvancesSpinnerObserved(): Bool {
        // While the mailbox is draining (streaming deltas), a stream timer
        // tick must still advance the working spinner's elapsed millis.
        // Swallowing the tick freezes the spinner mid-think.
        let previousWorking = working
        let previousMillis = workingElapsedMillis
        let previousWorkingArea = workingArea
        workingArea = Rect(0, 0, 100, 1)
        working = true
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        mailbox.push(TuiAgentEvent.ReasoningDelta("spinner-sentinel"))
        let tick = update(Event.Timer(TimerEvent(AGENT_STREAM_TIMER, elapsedMillis: 400)))
        let advanced = workingElapsedMillis == 400
        let invalidated = updateInvalidates(tick, workingArea)
        working = previousWorking
        workingElapsedMillis = previousMillis
        workingArea = previousWorkingArea
        for (index in 0..ui.cards.size) {
            if (ui.cards[index].body.contains("spinner-sentinel")) {
                ui.cards.remove(at: index)
                break
            }
        }
        advanced && invalidated
    }

    func streamingPlainTextObserved(): Bool {
        // Streaming assistant/reasoning cards render as plain wrapped text
        // (no per-token markdown re-parse); settled cards render markdown.
        // Markdown markers must be visible verbatim while streaming and
        // styled away once the card completes.
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard("stream-plain", UiCardKind.Assistant, "Assistant", "**bold-stream**", "streaming", false, "")
        )
        let plainDoc = renderTranscriptDocument(
            ui.cards.toArray(),
            80,
            axyndraTheme()
        )
        var plain = false
        for (line in plainDoc.lines) {
            if (documentLineText(line).contains("**bold-stream**")) {
                plain = true
            }
        }
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard("stream-plain", UiCardKind.Assistant, "Assistant", "**bold-stream**", "completed", false, "")
        )
        let mdDoc = renderTranscriptDocument(
            ui.cards.toArray(),
            80,
            axyndraTheme()
        )
        var rendered = false
        for (line in mdDoc.lines) {
            let t = documentLineText(line)
            if (t.contains("bold-stream") && !t.contains("**bold-stream**")) {
                rendered = true
            }
        }
        for (index in 0..ui.cards.size) {
            if (ui.cards[index].id == "stream-plain") {
                ui.cards.remove(at: index)
                break
            }
        }
        plain && rendered
    }

    func thinkingToggleDuringStreamObserved(): Bool {
        // A streaming reasoning card starts expanded; Ctrl+T collapses it and
        // the toggle dirties the transcript so the change actually renders.
        let previous = transcriptArea
        transcriptArea = Rect(0, 0, 80, 20)
        working = true
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        mailbox.push(TuiAgentEvent.ReasoningDelta("streaming-ctrl-t"))
        let _ = update(Event.Timer(TimerEvent(AGENT_STREAM_TIMER, elapsedMillis: 80)))
        var expanded = false
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card.body.contains("streaming-ctrl-t")) {
            expanded = !card.collapsed
        }
        let hide = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r't'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        var hidden = false
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card.body.contains("streaming-ctrl-t")) {
            hidden = card.collapsed
        }
        let invalidated = updateInvalidates(hide, transcriptArea)
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r't'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        var reshown = false
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card.body.contains("streaming-ctrl-t")) {
            reshown = !card.collapsed
        }
        transcriptArea = previous
        // Clean up the synthetic card and restore the seed reasoning card's
        // collapsed state that the Ctrl+T toggles expanded.
        var index: Int64 = 0
        while (index < ui.cards.size) {
            let id = ui.cards[index].id
            if ((id.startsWith("reasoning-") && ui.cards[index].body.contains("streaming-ctrl-t")) || id ==
                "streaming-ctrl-t") {
                ui.cards.remove(at: index)
            } else {
                index += 1
            }
        }
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card
            .body
            .contains("The tool completed; summarize its result.")) {
            card.collapsed = true
            card.markViewChanged()
        }
        working = false
        UiReducer.reduce(ui, UiEvent.SetWorking(false))
        expanded && hidden && invalidated && reshown
    }

    func cardClickToggleObserved(): Bool {
        // A collapsed tool card toggles open when its screen row is clicked.
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard("click-toggle-tool", UiCardKind.Tool, "Tool result · read", "line1\nline2\nline3", "completed",
                true, "")
        )
        transcriptRanges.clear()
        transcriptRanges.add(
            CardScreenRange(
                "click-toggle-tool",
                10,
                13
            )
        )
        let before = cardCollapsed("click-toggle-tool")
        let _ = toggleCardAt(11)
        let afterClick = cardCollapsed("click-toggle-tool")
        let _ = toggleCardAt(11)
        let afterSecond = cardCollapsed("click-toggle-tool")
        // Click on a row with no card must not change anything.
        transcriptRanges.clear()
        let _ = toggleCardAt(5)
        let unchanged = cardCollapsed("click-toggle-tool") == afterSecond
        // Clean up the synthetic card.
        for (index in 0..ui.cards.size) {
            if (ui.cards[index].id == "click-toggle-tool") {
                ui.cards.remove(at: index)
                break
            }
        }
        before && !afterClick && afterSecond && unchanged
    }

    func uiSnapshot(): UiSnapshot {
        ui
    }

    func scrollOffsetValue(): Int64 {
        scrollOffset
    }

    func transcriptStartLineValue(): Int64 {
        transcriptStartLine
    }

    func cardCollapsed(id: String): Bool {
        for (card in ui.cards where card.id == id) {
            return card.collapsed
        }
        false
    }

    func toolContinuationObserved(): Bool {
        var toolIndex: Int64 = -1
        var summaryIndex: Int64 = -1
        for (index in 0..ui.cards.size) {
            let card = ui.cards[index]
            if (card.title.startsWith("Read ") || card.title == "Tool result · read") {
                toolIndex = index
            }
            if (card.kind == UiCardKind.Assistant && card.body.contains("Final summary after tool completion.")) {
                summaryIndex = index
            }
        }
        toolIndex >= 0 && summaryIndex > toolIndex
    }

    func streamingInputObserved(): Bool {
        let pendingApproval = ui.approvalId
        UiReducer.reduce(ui, UiEvent.ClearApproval)
        working = true
        UiReducer.reduce(ui, UiEvent.SetWorking(true))
        composer.area.setValue("")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Char(r'字'))))
        mailbox.push(TuiAgentEvent.ReasoningDelta("streaming-thinking-sentinel"))
        let previousTranscriptArea = transcriptArea
        transcriptArea = Rect(0, 0, 80, 20)
        let _ = update(
            Event.Timer(
                TimerEvent(
                    AGENT_STREAM_TIMER,
                    elapsedMillis: 80
                )
            )
        )
        var streamed = false
        var animated = false
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card.body.contains("streaming-thinking-sentinel")) {
            streamed = true
            let first = transcriptCardDocument(
                productTranscriptItem(
                    card,
                    80,
                    activityFrame: 0
                )
            )
            let second = transcriptCardDocument(
                productTranscriptItem(
                    card,
                    80,
                    activityFrame: 1
                )
            )
            if (!first.lines.isEmpty() && !second.lines.isEmpty()) {
                animated = documentLineText(first.lines[0]) != documentLineText(second.lines[0])
            }
        }
        // A timer tick with no pending mailbox events does not redraw the
        // transcript for pure-text streaming (event-driven rendering); a
        // running tool card (spinner animation) keeps the timer-driven redraw.
        let idleTimer = update(
            Event.Timer(
                TimerEvent(
                    AGENT_STREAM_TIMER,
                    elapsedMillis: 160
                )
            )
        )
        let textStreamSkipped = !updateInvalidates(idleTimer, transcriptArea)
        // A stream tick while the mailbox still holds events must redraw the
        // transcript: streaming text is rendered on the tick (event-driven
        // rendering has no other wakeup). The idle-timer assertion above
        // covers the mailbox-empty case (no redraw).
        mailbox.push(TuiAgentEvent.ReasoningDelta("streaming-thinking-sentinel"))
        let streamTick = update(
            Event.Timer(
                TimerEvent(
                    AGENT_STREAM_TIMER,
                    elapsedMillis: 240
                )
            )
        )
        let redrawsWhileStreaming = updateInvalidates(
            streamTick,
            transcriptArea
        )
        UiReducer.reduce(
            ui,
            UiEvent.UpsertCard("perf-tool-spinner", UiCardKind.Tool, "Running tool", "spinner sentinel", "running", false, "")
        )
        let refreshWithTool = update(
            Event.Timer(
                TimerEvent(
                    AGENT_STREAM_TIMER,
                    elapsedMillis: 160
                )
            )
        )
        let toolRedraws = updateInvalidates(refreshWithTool, transcriptArea)
        transcriptArea = previousTranscriptArea
        let _ = update(
            Event.AsyncCompleted(
                "agent-turn",
                Event.Message("completed")
            )
        )
        var settled = true
        for (card in ui.cards where card.kind == UiCardKind.Reasoning && card.body.contains("streaming-thinking-sentinel")) {
            settled = settled && card.state == "completed"
        }
        var hiddenAfterCompletion = true
        let settledDocument = renderTranscriptDocument(
            ui.cards.toArray(),
            80,
            axyndraTheme()
        )
        for (line in settledDocument.lines where documentLineText(line).contains("streaming-thinking-sentinel")) {
            hiddenAfterCompletion = false
        }
        let typed = composer.area.value == "字"
        composer.area.setValue("")
        // Remove the synthetic spinner card so later assertions see a
        // clean transcript.
        for (index in 0..ui.cards.size) {
            if (ui.cards[index].id == "perf-tool-spinner") {
                ui.cards.remove(at: index)
                break
            }
        }
        match (pendingApproval) {
            case Some(id) => UiReducer.reduce(ui, UiEvent.AwaitApproval(id))
            case None => ()
        }
        typed && streamed && animated && textStreamSkipped && redrawsWhileStreaming && toolRedraws && settled &&
            hiddenAfterCompletion
    }

    func queuedInputChronologyObserved(): Bool {
        let previousWorking = working
        let previousStatus = status
        let previousTaskLabel = taskLabel
        let previousTurnSequence = turnSequence
        let previousRoundSequence = modelRoundSequence
        let previousToolCardId = activeToolCardId
        let previousQueued = ArrayList<QueuedPrompt>()
        for (queued in queuedPrompts) {
            previousQueued.add(queued)
        }
        let before = ui.cards.size
        let prompt = "queued-input-sentinel"
        turnSequence += 1
        modelRoundSequence = 0
        activeToolCardId = ""
        acceptAgentEvent(TuiAgentEvent.TextDelta("before-queue-sentinel"))
        working = true
        let _ = submitPrompt(prompt)
        let queuedId = queuedPrompts[queuedPrompts.size - 1].id
        let queuedStateVisible = queuedPromptLabel("steer", 80).startsWith("Steering · 1 · " + prompt)
        let queueArea = Rect(0, 0, 80, 20)
        let queueBuffer = Buffer(queueArea)
        render(Frame(queueArea, queueBuffer))
        let queuedAbovePrompt = bufferRowText(
            queueBuffer,
            queuedArea
        ).contains("Steering · 1 · " + prompt)
        var absentFromTranscript = true
        for (line in renderTranscriptDocument(
            ui.cards.toArray(),
            100,
            axyndraTheme()
        ).lines where documentLineText(line).contains(prompt)) {
            absentFromTranscript = false
        }
        let preservedActiveTask = taskLabel == previousTaskLabel
        acceptAgentEvent(
            TuiAgentEvent.InputInjected(
                queuedId,
                "steer",
                prompt
            )
        )
        acceptAgentEvent(TuiAgentEvent.TextDelta("after-queue-sentinel"))
        let removedAfterInjection = queuedPrompts.isEmpty()
        let ordered = ui.cards.size == before + 3 && ui.cards[before].kind == UiCardKind.Assistant &&
            ui.cards[before].body.contains("before-queue-sentinel") && ui.cards[before + 1].kind == UiCardKind.User &&
            ui.cards[before + 1].body == prompt && ui.cards[before + 2].kind == UiCardKind.Assistant &&
            ui.cards[before + 2].body.contains("after-queue-sentinel")
        while (ui.cards.size > before) {
            ui.cards.remove(at: ui.cards.size - 1)
        }
        working = previousWorking
        status = previousStatus
        taskLabel = previousTaskLabel
        turnSequence = previousTurnSequence
        modelRoundSequence = previousRoundSequence
        activeToolCardId = previousToolCardId
        queuedPrompts.clear()
        for (queued in previousQueued) {
            queuedPrompts.add(queued)
        }
        ordered && queuedStateVisible && queuedAbovePrompt && absentFromTranscript && removedAfterInjection &&
            preservedActiveTask
    }

    func inputAreaContractObserved(): Bool {
        let previousWorking = working
        let previousStatus = status
        let previousCardSequence = cardSequence
        let previousWithdrawalId = withdrawalInFlightId
        let previousValue = composer.area.value
        let previousCursor = composer.area.cursor
        let previousQueued = ArrayList<QueuedPrompt>()
        for (queued in queuedPrompts) {
            previousQueued.add(queued)
        }
        queuedPrompts.clear()
        withdrawalInFlightId = ""
        working = true

        composer.area.setValue("/he")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        let completionOpened = composer.completionVisible()
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Enter)))
        let completionAcceptedWithoutQueue = composer.area.value == "/help " && queuedPrompts.isEmpty()

        composer.area.setValue("agent_tu")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Tab)))
        let completionBeforeFollowUp = composer.completionVisible()
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Enter,
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        let followUpDoesNotAcceptCompletion = completionBeforeFollowUp && queuedPrompts.size == 1 && queuedPrompts[0]
            .kind == "follow_up" && queuedPrompts[0].text == "agent_tu"

        composer.area.setValue("follow-up shortcut")
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Enter,
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        let ctrlEnterFollowUp = queuedPrompts.size == 2 && queuedPrompts[1].kind == "follow_up"

        composer.area.setValue("steering shortcut")
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.Enter)))
        let plainEnterSteers = queuedPrompts.size == 3 && queuedPrompts[2].kind == "steer"

        composer.area.setValue("q shortcut")
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Char(r'q'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        let ctrlQFollowUp = queuedPrompts.size == 4 && queuedPrompts[3].kind == "follow_up"

        composer.area.setValue("line")
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Enter,
                    modifiers: KeyModifier(shift: true)
                )
            )
        )
        let newlineInserted = composer.area.value == "line\n"

        queuedPrompts.clear()
        queuedPrompts.add(QueuedPrompt("old-steer", "steer", "older steering"))
        queuedPrompts.add(QueuedPrompt("new-steer", "steer", "latest steering"))
        queuedPrompts.add(QueuedPrompt("new-follow", "follow_up", "latest after yield"))
        let narrowSteering = queuedPromptLabel("steer", 60)
        let narrowFollowUp = queuedPromptLabel("follow_up", 60)
        let groupedNarrow = narrowSteering.contains("Steering · 2 · latest steering") && !narrowSteering.contains(
            "older steering") && narrowFollowUp.contains("After yield · 1 · latest after yield")
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Up,
                    modifiers: KeyModifier(alt: true)
                )
            )
        )
        let newestWithdrawn = withdrawalInFlightId == "new-follow"

        composer.area.setValue("current draft")
        restoreQueuedText("withdrawn text")
        let mergedAtBoundary = composer.area.value == "withdrawn text\n\ncurrent draft" && composer.area.cursor ==
            "withdrawn text".size && !composer.completionVisible()

        let frameArea = Rect(0, 0, 32, 5)
        let frameContent = Rect(2, 1, 28, 3)
        let frameBuffer = Buffer(frameArea)
        let frameTheme = axyndraTheme()
        drawComposerFrame(
            Canvas(frameBuffer, frameArea),
            frameArea,
            frameContent,
            "1\n2\n3\n4\n5\n6",
            11,
            true,
            true,
            true,
            frameTheme
        )
        var sawScrollbar = false
        for (row in 0..frameContent.height where frameBuffer.getCell(frameArea.right - 1, frameContent.y + row).symbol ==
            "█") {
            sawScrollbar = true
        }
        let frameObserved = frameBuffer.getCell(0, 1).symbol == "│" && frameBuffer.getCell(0, 4).symbol == "╰" &&
            frameBuffer.getCell(31, 4).symbol == "╯" && sawScrollbar
        let frameStyleObserved = frameBuffer.getCell(0, 1).style ==
            Style(fg: frameTheme.warning, bg: frameTheme.background) && frameBuffer.getCell(0, 4).style ==
            Style(fg: frameTheme.warning, bg: frameTheme.background) && Style(
                fg: headerSegmentColor(frameTheme, "border", "ready"),
                bg: frameTheme.background
            ) == Style(fg: frameTheme.accent, bg: frameTheme.background)
        let footerPriority = composerFooterHint(80, true, true).contains("Alt+↑ edit") && !composerFooterHint(
            26,
            true,
            true
        ).contains("Alt+↑ edit") && composerFooterHint(26, true, true).startsWith("Enter steer")

        working = previousWorking
        status = previousStatus
        cardSequence = previousCardSequence
        withdrawalInFlightId = previousWithdrawalId
        queuedPrompts.clear()
        for (queued in previousQueued) {
            queuedPrompts.add(queued)
        }
        composer.area.setValue(previousValue, cursor: previousCursor)
        completionOpened && completionAcceptedWithoutQueue && followUpDoesNotAcceptCompletion && ctrlEnterFollowUp &&
            plainEnterSteers && ctrlQFollowUp && newlineInserted && groupedNarrow && newestWithdrawn && mergedAtBoundary &&
            frameObserved && frameStyleObserved && footerPriority
    }

    func todoStripContractObserved(): Bool {
        let previousTodoState = todos.captureProbeState()
        let previousValue = composer.area.value
        let previousCursor = composer.area.cursor
        let previousAgentHub = agentHubActive
        agentHubActive = false
        composer.area.setValue("")
        let _ = todos.applySnapshot(
            TuiTodoLoadResult(
                true,
                "## Input refactor\n" +
                    "- [x] Tab completion\n" +
                    "- [/] Pin Todo above prompt\n" +
                    "- [!] Verify narrow layout <!-- blocker: fixture -->\n" +
                    "- [ ] Capture screenshot\n",
                "fixture"
            )
        )

        let wideArea = Rect(0, 0, 100, 28)
        let wideBuffer = Buffer(wideArea)
        render(Frame(wideArea, wideBuffer))
        var wideText = ""
        for (row in 0..todoArea.height) {
            wideText += bufferRowText(
                wideBuffer,
                Rect(todoArea.x, todoArea.y + row, todoArea.width, 1)
            ) + "\n"
        }
        let pinnedAboveComposer = todoArea.height == 4 && todoArea.bottom == composerArea.y
        let allWideTasksVisible = wideText.contains("Todo 1/4") && wideText.contains("Tab completion") &&
            wideText.contains("Pin Todo above prompt") && wideText.contains("Verify narrow layout") &&
            wideText.contains("Capture screenshot") && !wideText.contains("blocker:")
        let wideTheme = activeProductTheme(
            overrideName: themeName,
            customThemes: customThemeDefinitions
        )
        let promptPlaceholderStyled = wideBuffer.getCell(composerArea.x + 2, composerArea.y + 1).symbol == "m" &&
            wideBuffer.getCell(composerArea.x + 2, composerArea.y + 1).style ==
            Style(fg: wideTheme.secondary, bg: wideTheme.background)
        let semanticArea = Rect(0, 0, 100, 4)
        let semanticBuffer = Buffer(semanticArea)
        let semanticTheme = axyndraTheme()
        todos.renderStrip(Canvas(semanticBuffer, semanticArea), semanticArea, semanticTheme)
        let firstMarkerX = 2 + displayWidth("Todo 1/4 · ")
        let nextMarkerX = 2 + displayWidth("     ")
        let semanticStyles = semanticBuffer.getCell(firstMarkerX, 0).style ==
            Style(fg: semanticTheme.success, bg: semanticTheme.background) && semanticBuffer.getCell(
                firstMarkerX + displayWidth("[x] "),
                0
            ).style == Style(fg: semanticTheme.success, bg: semanticTheme.background) && semanticBuffer.getCell(
                nextMarkerX + displayWidth("[/] "),
                1
            ).style == Style(fg: semanticTheme.warning, bg: semanticTheme.background) && semanticBuffer.getCell(
                nextMarkerX + displayWidth("[!] "),
                2
            ).style == Style(fg: semanticTheme.danger, bg: semanticTheme.background) && semanticBuffer.getCell(
                nextMarkerX + displayWidth("[ ] "),
                3
            ).style == Style(fg: semanticTheme.accent, bg: semanticTheme.background)

        let narrowArea = Rect(0, 0, 60, 18)
        let narrowBuffer = Buffer(narrowArea)
        render(Frame(narrowArea, narrowBuffer))
        var narrowText = ""
        for (row in 0..todoArea.height) {
            narrowText += bufferRowText(
                narrowBuffer,
                Rect(todoArea.x, todoArea.y + row, todoArea.width, 1)
            ) + "\n"
        }
        let narrowPrioritizesCurrent = todoArea.height == 2 && todoArea.bottom == composerArea.y &&
            narrowText.contains("Pin Todo above prompt") && narrowText.contains("Verify narrow layout") &&
            narrowText.contains("+2")

        todos.restoreProbeState(previousTodoState)
        composer.area.setValue(previousValue, cursor: previousCursor)
        agentHubActive = previousAgentHub
        pinnedAboveComposer && allWideTasksVisible && promptPlaceholderStyled && semanticStyles &&
            narrowPrioritizesCurrent
    }

    func transcriptPagingObserved(): Bool {
        let previousArea = transcriptArea
        let previousWorkingArea = workingArea
        let previousTotal = transcriptTotalLines
        let previousVisible = transcriptVisibleLines
        let previousStart = transcriptStartLine
        let previousOffset = scrollOffset
        let previousEditingTodos = todos.suspendEditorForProbe()
        // This is a focused transcript navigation contract. Scenario-specific
        // editors route PageUp/PageDown to their own TextArea, so temporarily
        // remove that overlay and restore it after the probe.
        transcriptArea = Rect(0, 0, 80, 10)
        workingArea = Rect(0, 10, 80, 1)
        transcriptTotalLines = 100
        transcriptVisibleLines = 10
        transcriptStartLine = 90
        scrollOffset = 0
        let first = update(Event.KeyDown(KeyEvent(KeyCode.PageUp)))
        let firstPage = scrollOffset == 9
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.PageUp)))
        let secondPage = scrollOffset == 18
        let _ = update(Event.KeyDown(KeyEvent(KeyCode.PageDown)))
        let pageDown = scrollOffset == 9
        let _ = update(
            Event.Mouse(
                MouseEvent(
                    MouseKind.Scroll,
                    MouseButton.WheelUp,
                    10,
                    5
                )
            )
        )
        let wheel = scrollOffset == 12
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.Home,
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        let home = scrollOffset == 90
        let _ = update(
            Event.KeyDown(
                KeyEvent(
                    KeyCode.End,
                    modifiers: KeyModifier(ctrl: true)
                )
            )
        )
        let end = scrollOffset == 0
        let bottomBoundary = update(
            Event.Mouse(
                MouseEvent(
                    MouseKind.Scroll,
                    MouseButton.WheelDown,
                    10,
                    5
                )
            )
        )
        let bottomBoundarySkipsRender = !bottomBoundary.renderRequested && scrollOffset == 0
        let invalidated = updateInvalidates(first, transcriptArea)
        transcriptArea = previousArea
        workingArea = previousWorkingArea
        transcriptTotalLines = previousTotal
        transcriptVisibleLines = previousVisible
        transcriptStartLine = previousStart
        scrollOffset = previousOffset
        todos.restoreEditorForProbe(previousEditingTodos)
        firstPage && secondPage && pageDown && wheel && home && end && bottomBoundarySkipsRender && invalidated
    }

    func todoEditorMouseCaptureObserved(): Bool {
        let previousTodoState = todos.captureProbeState()
        let previousPlanState = planReview.beginProbe()
        let previousArea = transcriptArea
        let previousTotal = transcriptTotalLines
        let previousVisible = transcriptVisibleLines
        let previousStart = transcriptStartLine
        let previousOffset = scrollOffset

        // Plan review owns mouse routing ahead of the Todo editor. Isolate the
        // probe from the screen's current modal state, then restore that state
        // exactly as the Ask editor isolation probe does below.
        let _ = planReview.open("# Competing plan review\n")
        planReview.close()
        let _ = todos.open(TuiTodoLoadResult(true, "- [ ] mouse capture\n", "fixture"))
        let frameArea = Rect(0, 0, 80, 24)
        todos.renderEditor(Frame(frameArea, Buffer(frameArea)), axyndraTheme())
        transcriptArea = frameArea
        transcriptTotalLines = 100
        transcriptVisibleLines = 10
        transcriptStartLine = 90
        scrollOffset = 0
        let mouse = MouseEvent(MouseKind.Scroll, MouseButton.WheelUp, 8, 5)

        let interactive = handleInteractive(Event.Mouse(mouse))
        let interactiveCaptured = !interactive.renderRequested && scrollOffset == 0 && todos.isEditing()
        let _ = update(Event.Mouse(mouse))
        // update() drains the asynchronous mailbox before routing interactive
        // input. A concurrently completed background action can therefore
        // request a redraw even though the Todo editor correctly owns the
        // mouse event. Ownership is proven by the editor remaining active and
        // the underlying transcript not scrolling; renderRequested describes
        // the whole frame, not just the mouse route.
        let directCaptured = scrollOffset == 0 && todos.isEditing()

        todos.restoreProbeState(previousTodoState)
        planReview.restoreProbe(previousPlanState)
        transcriptArea = previousArea
        transcriptTotalLines = previousTotal
        transcriptVisibleLines = previousVisible
        transcriptStartLine = previousStart
        scrollOffset = previousOffset
        interactiveCaptured && directCaptured
    }

    func askEditorIsolationObserved(): Bool {
        let previousAskState = ask.captureProbeState()
        let previousPlanState = planReview.beginProbe()
        let previousTodoEditing = todos.suspendEditorForProbe()
        let previousUi = ui
        let previousStatus = status
        let previousArea = transcriptArea
        let previousTotal = transcriptTotalLines
        let previousVisible = transcriptVisibleLines
        let previousStart = transcriptStartLine
        let previousOffset = scrollOffset

        planReview.close()
        ui = UiSnapshot()
        let request = TuiAskRequest(
            "ask-editor-isolation",
            [
                TuiAskQuestion(
                    "verification",
                    "Which verification should run?",
                    [TuiAskOption("Run unit tests")],
                    header: "Verification",
                    recommended: 0
                )
            ]
        )
        let began = ask.begin(request)
        syncAskCard()
        let initialRevision = if (ui.cards.isEmpty()) { -1 } else { ui.cards[0].contentRevision }
        let opened = ask.updateKey(KeyEvent(KeyCode.Char(r'n')))
        let openUpdate = applyAskTransition(opened)
        let revisionAfterOpen = if (ui.cards.isEmpty()) { -2 } else { ui.cards[0].contentRevision }
        let typed = ask.updateEditor(KeyEvent(KeyCode.Char(r'x')))
        let typeUpdate = applyAskTransition(typed)
        let revisionAfterType = if (ui.cards.isEmpty()) { -3 } else { ui.cards[0].contentRevision }
        let editorTypingStayedLocal = began && opened.changed && !opened.cardChanged && openUpdate.renderRequested &&
            typed.changed && !typed.cardChanged && typeUpdate.renderRequested && initialRevision >= 0 &&
            revisionAfterOpen == initialRevision && revisionAfterType == initialRevision

        let frameArea = Rect(0, 0, 80, 24)
        ask.renderEditor(Frame(frameArea, Buffer(frameArea)), axyndraTheme())
        transcriptArea = frameArea
        transcriptTotalLines = 100
        transcriptVisibleLines = 10
        transcriptStartLine = 90
        scrollOffset = 0
        let mouse = MouseEvent(MouseKind.Scroll, MouseButton.WheelUp, 8, 5)
        let interactive = handleInteractive(Event.Mouse(mouse))
        let interactiveCaptured = !interactive.renderRequested && scrollOffset == 0 && ask.editorActive()
        let direct = update(Event.Mouse(mouse))
        let directCaptured = !direct.renderRequested && scrollOffset == 0 && ask.editorActive()

        let saved = ask.updateEditor(
            KeyEvent(KeyCode.Char(r's'), modifiers: KeyModifier(ctrl: true))
        )
        let saveUpdate = applyAskTransition(saved)
        let revisionAfterSave = if (ui.cards.isEmpty()) { -4 } else { ui.cards[0].contentRevision }
        let saveUpdatesCard = saved.changed && saved.cardChanged && saveUpdate.renderRequested &&
            revisionAfterSave > revisionAfterType

        ask.restoreProbeState(previousAskState)
        planReview.restoreProbe(previousPlanState)
        todos.restoreEditorForProbe(previousTodoEditing)
        ui = previousUi
        match (virtualTranscriptSource) {
            case Some(source) => source.setSnapshot(previousUi)
            case None => ()
        }
        status = previousStatus
        transcriptArea = previousArea
        transcriptTotalLines = previousTotal
        transcriptVisibleLines = previousVisible
        transcriptStartLine = previousStart
        scrollOffset = previousOffset
        editorTypingStayedLocal && interactiveCaptured && directCaptured && saveUpdatesCard
    }

    func subagentConversationContractObserved(): Bool {
        let previousUi = ui
        let previousFocused = focusedSubagentId
        let previousLabel = focusedConversationLabel
        let previousStatus = status
        let previousTask = taskLabel
        let previousWorking = working
        let previousMainWorking = mainWorking
        let _ = applyConversationView(
            TuiConversationView(
                "contract-child",
                "Subagent · contract-child",
                "running",
                false,
                [
                    TuiTranscriptItem(
                        "contract-child-user",
                        UiCardKind.User,
                        "You",
                        "child transcript sentinel"
                    )
                ]
            )
        )
        status = "resuming"
        acceptAgentEvent(
            TuiAgentEvent.JobStatus(
                "contract-child",
                "task",
                "running",
                "inspect workspace",
                10,
                ""
            )
        )
        acceptAgentEvent(
            TuiAgentEvent.SubagentStream(
                "contract-child",
                TuiSubagentStreamEvent.TextDelta("child stream sentinel")
            )
        )
        let transcriptSwitched = match (virtualTranscriptSource) {
            case Some(source) =>
                var found = false
                for (index in 0..source.size()) {
                    let document = source.document(index, 72, themeName)
                    for (line in document.lines where documentLineText(line).contains("child stream sentinel")) {
                        found = true
                    }
                }
                found
            case None => false
        }
        let observed = focusedSubagentId == "contract-child" && status.startsWith("subagent contract-child · running") &&
            ui.cards.size == 3 && ui.cards[0].kind == UiCardKind.User && ui.cards[2].kind == UiCardKind.Assistant &&
            ui.cards[2].body.contains("child stream sentinel") && transcriptSwitched && modal.isNone()
        ui = previousUi
        match (virtualTranscriptSource) {
            case Some(source) => source.setSnapshot(previousUi)
            case None => ()
        }
        focusedSubagentId = previousFocused
        focusedConversationLabel = previousLabel
        status = previousStatus
        taskLabel = previousTask
        working = previousWorking
        mainWorking = previousMainWorking
        subagentItems = []
        runningSubagentIds.clear()
        observed
    }

    func subagentEscapeInterruptContractObserved(): Bool {
        let previousUi = ui
        let previousFocused = focusedSubagentId
        let previousWorking = working
        let previousStatus = status
        let previousComposer = composer.area.value
        ui = UiSnapshot()
        focusedSubagentId = "contract-child"
        working = true
        status = "subagent contract-child · running"
        composer.area.setValue("")
        let result = update(Event.KeyDown(KeyEvent(KeyCode.Esc)))
        let interrupts = match (result.command) {
            case Command.AsyncTask(id, _) => id.contains("tui-background-cancel-")
            case _ => false
        }
        ui = previousUi
        match (virtualTranscriptSource) {
            case Some(source) => source.setSnapshot(previousUi)
            case None => ()
        }
        focusedSubagentId = previousFocused
        working = previousWorking
        status = previousStatus
        composer.area.setValue(previousComposer)
        interrupts
    }

    func askSubmissionContractObserved(): Bool {
        // Headless seeds inject the Ask event directly, so there is no
        // session-side ProductAskRequest to accept; the rejection itself is
        // the correct product behavior for an unknown request id. The contract
        // is that the full interaction flow completes: note captured, editor
        // closed, submission attempted, and a clear rejection status shown.
        let snapshot = ask.probeSnapshot()
        snapshot.submissionAttempted && snapshot.submissionNote == "Prefer the portable path" && !ask.editorActive() &&
            (status == "ask answer was rejected" || status == "answer submitted" || status == "completed")
    }

    func askSingleSelectionRenderingObserved(): Bool {
        for (card in ui.cards where card.body.contains("Which verification should run?")) {
            if (card.body.contains("[x] Node tests") && !card.body.contains("( ) ")) {
                return true
            }
        }
        false
    }

    func askSubmissionContractDiagnostic(): String {
        let snapshot = ask.probeSnapshot()
        "attempted=" + snapshot.submissionAttempted.toString() + " accepted=" +
            snapshot.submissionAccepted.toString() + " note=" + snapshot.submissionNote + " editor=" +
            snapshot.editorMode + " pending=" + snapshot.active.toString() + " cursor=" + snapshot.cursor.toString() +
            " status=" + status
    }
}
