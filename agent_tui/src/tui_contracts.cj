package agent_tui

import agent_cli.*
import std.deriving.*

public enum TuiPlanReviewDisposition {
    NotApplicable
    | Retain
    | Consumed
}

public class TuiTurnResult {
    public let text: String
    public let status: String
    public let action: TuiTurnAction
    public let planReviewDisposition: TuiPlanReviewDisposition

    public init(
        text: String,
        status: String,
        action!: TuiTurnAction = TuiTurnAction.NoAction,
        planReviewDisposition!: TuiPlanReviewDisposition = TuiPlanReviewDisposition.NotApplicable
    ) {
        this.text = text
        this.status = status
        this.action = action
        this.planReviewDisposition = planReviewDisposition
    }
}

public enum TuiTurnAction {
    NoAction
    | Exit
    | OpenProviderSetup
    | OpenModelSelector
    | OpenBranchSelector
    | OpenPlanReview(String)
    | OpenDocument(String, String)
    | ModelsLoaded(Array<String>)
    | ThemeSelected(String, Bool, Array<TuiThemeDefinition>)
    | SessionsLoaded(Array<TuiSessionNode>)
    | BranchesLoaded(Array<String>)
    | SessionTreeLoaded(Array<TuiSessionNode>)
    | SubagentsLoaded(Array<TuiSubagentInfo>)
    | ConversationFocused(TuiConversationView)
    | ExtensionsLoaded(Array<TuiExtensionInfo>)
    | TodoLoaded(TuiTodoLoadResult)
    | ModelSelected(String, Bool, String)
    | SessionSelected(String, Bool, String, ?TuiConversationView)
    | BranchSelected(Bool, String)
    | ExtensionToggled(String, Bool, Array<TuiExtensionInfo>)
    | ResetCompleted(String)
    | SetupConfigured(String)
    | TodoSaved(TuiTodoSaveResult)
    | DraftLoaded(String)
    | UiStatus(String)
}

public enum TuiAgentEvent {
    AttemptStarted(TuiAttemptScope)
    | AttemptTextDelta(TuiAttemptScope, String)
    | AttemptReasoningDelta(TuiAttemptScope, String)
    | AttemptToolStarted(TuiAttemptScope, String, String)
    | AttemptToolArguments(TuiAttemptScope, String, String)
    | AttemptFailed(TuiAttemptScope, String)
    | AttemptCancelled(TuiAttemptScope)
    | AttemptAborted(TuiAttemptScope)
    | AttemptRetryScheduled(TuiAttemptScope)
    | DecisionCommitted(TuiAttemptScope, String)
    | TextDelta(String)
    | ReasoningDelta(String)
    | ToolStarted(String, String)
    | ToolStartedWithId(String, String, String)
    | ToolOutput(String, String, Bool)
    | ToolCompleted(String, Bool, TuiToolCompletionPayload)
    | ToolCompletedWithId(String, String, Bool, TuiToolCompletionPayload)
    | InputInjected(String, String, String)
    | JobStatus(String, String, String, String, Int64, String)
    | SubagentStatus(TuiSubagentInfo, Int64, String)
    | SubagentStream(String, TuiSubagentStreamEvent)
    | Approval(
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        String
    )
    | ApprovalReview(
        String,
        String,
        String,
        String,
        String,
        String,
        String,
        Int64,
        String
    )
    | Ask(TuiAskRequest)
    | PlanReviewConsumed(String)
    | Usage(Int64, Int64)
    | Setup(String)
    | Plan(String, String)
    | Warning(String, String)
    | Compaction(Int64, Int64, String)
    | Summary(String)
    | Error(String)
}

public class TuiAttemptScope {
    public let runId: String
    public let semanticRequestId: String
    public let attemptId: String
    public let sequence: Int64
    public init(runId: String, semanticRequestId: String, attemptId: String, sequence: Int64) {
        this.runId = runId
        this.semanticRequestId = semanticRequestId
        this.attemptId = attemptId
        this.sequence = sequence
    }
}

public enum TuiSubagentStreamEvent {
    AttemptStarted(TuiAttemptScope)
    | AttemptTextDelta(TuiAttemptScope, String)
    | AttemptReasoningDelta(TuiAttemptScope, String)
    | AttemptToolStarted(TuiAttemptScope, String, String)
    | AttemptToolArguments(TuiAttemptScope, String, String)
    | AttemptFailed(TuiAttemptScope)
    | AttemptCancelled(TuiAttemptScope)
    | AttemptAborted(TuiAttemptScope)
    | DecisionCommitted(TuiAttemptScope)
    | TextDelta(String)
    | ReasoningDelta(String)
    | ToolStarted(String, String)
    | ToolStartedWithId(String, String, String)
    | ToolOutput(String, String, Bool)
    | ToolCompleted(String, Bool, TuiToolCompletionPayload)
    | ToolCompletedWithId(String, String, Bool, TuiToolCompletionPayload)
    | InputInjected(String, String, String)
    | Usage(Int64, Int64)
    | Error(String)
}

public type TuiAgentEventSink = (TuiAgentEvent) -> Unit

// Tool results can be arbitrarily large while a terminal card only needs a
// bounded preview plus a handful of exact completion facts. Keeping that
// distinction in the event contract prevents the renderer from retaining and
// repeatedly parsing the complete provider/tool payload.
public class TuiToolCompletionPayload {
    public let detailPreview: String
    public let stdoutPreview: String
    public let stderrPreview: String
    public let exitCode: String
    public let stdoutBytes: Int64
    public let stderrBytes: Int64
    public let sourceTruncated: Bool
    public let previewTruncated: Bool
    public let artifactId: String

    public init(
        detailPreview!: String = "",
        stdoutPreview!: String = "",
        stderrPreview!: String = "",
        exitCode!: String = "",
        stdoutBytes!: Int64 = -1,
        stderrBytes!: Int64 = -1,
        sourceTruncated!: Bool = false,
        previewTruncated!: Bool = false,
        artifactId!: String = ""
    ) {
        this.detailPreview = detailPreview
        this.stdoutPreview = stdoutPreview
        this.stderrPreview = stderrPreview
        this.exitCode = exitCode
        this.stdoutBytes = stdoutBytes
        this.stderrBytes = stderrBytes
        this.sourceTruncated = sourceTruncated
        this.previewTruncated = previewTruncated
        this.artifactId = artifactId
    }
}

public enum TuiApprovalDecision {
    AllowOnce | AllowSession | Reject(String)
}

@Derive[Equatable]
public enum TuiPlanReviewDecision {
    // Keep the original variants for source compatibility. The dedicated
    // Plan Review surface uses the context-explicit variants below.
    ApproveAndExecute
    | ApproveFresh
    | ApproveCompact
    | ApproveKeep
    | Refine
    | UpdatePlan
    | KeepPlanning
    | Reject
}

@Derive[Equatable]
enum PlanReviewFocus {
    Toc | Body | Actions
}

class PlanReviewSection {
    let title: String
    let level: Int64
    let sourceOffset: Int64
    var renderedLine: Int64

    init(title: String, level: Int64, sourceOffset: Int64) {
        this.title = title
        this.level = level
        this.sourceOffset = sourceOffset
        this.renderedLine = 0
    }
}

class PlanReviewAnnotation {
    let section: String
    let line: String
    let note: String
    let removeSection: Bool

    init(
        section: String,
        line: String,
        note: String,
        removeSection!: Bool = false
    ) {
        this.section = section
        this.line = line
        this.note = note
        this.removeSection = removeSection
    }
}

public enum TuiQueueWithdrawal {
    | Withdrawn(String, String)
    | AlreadyDelivered
    | Failed(String)
}

public func planContentHash(value: String): String {
    planReviewHash(value)
}

public class TuiAskOption {
    public let label: String
    public let description: String
    public let preview: String

    public init(
        label: String,
        description!: String = "",
        preview!: String = ""
    ) {
        this.label = label
        this.description = description
        this.preview = preview
    }
}

public class TuiAskQuestion {
    public let id: String
    public let question: String
    public let header: String
    public let options: Array<TuiAskOption>
    public let multi: Bool
    public let recommended: ?Int64

    public init(
        id: String,
        question: String,
        options: Array<TuiAskOption>,
        header!: String = "",
        multi!: Bool = false,
        recommended!: ?Int64 = None
    ) {
        this.id = id
        this.question = question
        this.options = options
        this.header = header
        this.multi = multi
        this.recommended = recommended
    }
}

public class TuiAskRequest {
    public let requestId: String
    public let questions: Array<TuiAskQuestion>
    public let callId: String

    public init(
        requestId: String,
        questions: Array<TuiAskQuestion>,
        callId!: String = ""
    ) {
        this.requestId = requestId
        this.questions = questions
        this.callId = callId
    }
}

public class TuiAskAnswer {
    public let id: String
    public let selectedOptions: Array<String>
    public let customInput: ?String
    public let note: ?String
    public let timedOut: Bool

    public init(
        id: String,
        selectedOptions!: Array<String> = [],
        customInput!: ?String = None,
        note!: ?String = None,
        timedOut!: Bool = false
    ) {
        this.id = id
        this.selectedOptions = selectedOptions
        this.customInput = customInput
        this.note = note
        this.timedOut = timedOut
    }
}

public enum TuiAskResolution {
    Answers(Array<TuiAskAnswer>)
    | Chat
    | Cancelled
}

public class TuiTodoSaveResult {
    public let saved: Bool
    public let message: String

    public init(saved: Bool, message: String) {
        this.saved = saved
        this.message = message
    }
}

public class TuiTodoLoadResult {
    public let loaded: Bool
    public let markdown: String
    public let message: String

    public init(loaded: Bool, markdown: String, message: String) {
        this.loaded = loaded
        this.markdown = markdown
        this.message = message
    }
}

public class TuiSetupRequest {
    public let profileId: String
    public let provider: String
    public let protocol: String
    public let model: String
    public let baseUrl: String
    public let apiKeyEnv: String
    public let credential: String

    public init(
        profileId: String,
        provider: String,
        protocol: String,
        model: String,
        baseUrl: String,
        apiKeyEnv: String,
        credential: String
    ) {
        this.profileId = profileId
        this.provider = provider
        this.protocol = protocol
        this.model = model
        this.baseUrl = baseUrl
        this.apiKeyEnv = apiKeyEnv
        this.credential = credential
    }
}

public class TuiSessionNode {
    public let id: String
    public let name: String
    public let summary: String
    public let parentId: String
    public let model: String
    public let workMode: String
    public let updatedAt: Int64
    public let current: Bool
    public let archived: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        parentId: String,
        model: String,
        workMode: String,
        updatedAt: Int64,
        current: Bool,
        archived!: Bool = false
    ) {
        this.id = id
        this.name = name
        this.summary = summary
        this.parentId = parentId
        this.model = model
        this.workMode = workMode
        this.updatedAt = updatedAt
        this.current = current
        this.archived = archived
    }

    public func label(): String {
        if (name != "") {
            name
        } else if (summary != "") {
            summary
        } else {
            id
        }
    }
}

public class TuiExtensionInfo {
    public let id: String
    public let source: String
    public let enabled: Bool
    public let tools: Array<String>

    public init(
        id: String,
        source: String,
        enabled: Bool,
        tools: Array<String>
    ) {
        this.id = id
        this.source = source
        this.enabled = enabled
        this.tools = tools
    }
}

public class TuiSubagentInfo {
    public let id: String
    public let agent: String
    public let status: String
    public let task: String

    public init(
        id: String,
        agent: String,
        status: String,
        task: String
    ) {
        this.id = id
        this.agent = agent
        this.status = status
        this.task = task
    }

    public func label(): String {
        id + " · " + agent + " · " + status
    }
}

public class TuiTranscriptItem {
    public let id: String
    public let kind: UiCardKind
    public let title: String
    public let body: String
    public let state: String
    public let collapsed: Bool
    public let toolName: String
    public let toolArguments: String
    public let toolCallId: String
    public let toolOutput: String

    public init(
        id: String,
        kind: UiCardKind,
        title: String,
        body: String,
        state!: String = "completed",
        collapsed!: Bool = false,
        toolName!: String = "",
        toolArguments!: String = "",
        toolCallId!: String = "",
        toolOutput!: String = ""
    ) {
        this.id = id
        this.kind = kind
        this.title = title
        this.body = body
        this.state = state
        this.collapsed = collapsed
        this.toolName = toolName
        this.toolArguments = toolArguments
        this.toolCallId = toolCallId
        this.toolOutput = toolOutput
    }
}

public class TuiConversationView {
    public let id: String
    public let label: String
    public let status: String
    public let isMain: Bool
    public let items: Array<TuiTranscriptItem>
    public let nextBeforeOrdinal: Int64
    public let hasMore: Bool
    public let provisionalEvents: Array<TuiAgentEvent>

    public init(
        id: String,
        label: String,
        status: String,
        isMain: Bool,
        items: Array<TuiTranscriptItem>,
        nextBeforeOrdinal!: Int64 = 0,
        hasMore!: Bool = false,
        provisionalEvents!: Array<TuiAgentEvent> = []
    ) {
        if (nextBeforeOrdinal < 0 || (hasMore && nextBeforeOrdinal == 0)) {
            throw IllegalArgumentException("conversation paging cursor is inconsistent")
        }
        this.id = id
        this.label = label
        this.status = status
        this.isMain = isMain
        this.items = items
        this.nextBeforeOrdinal = nextBeforeOrdinal
        this.hasMore = hasMore
        this.provisionalEvents = provisionalEvents
    }
}

// Immutable transcript page returned by the product backend. The TUI owns
// presentation state; the backend owns only the stable canonical cursor.
public class TuiTranscriptPage {
    public let items: Array<TuiTranscriptItem>
    public let nextBeforeOrdinal: Int64
    public let hasMore: Bool

    public init(
        items: Array<TuiTranscriptItem>,
        nextBeforeOrdinal: Int64,
        hasMore: Bool
    ) {
        if (nextBeforeOrdinal < 0 || (hasMore && nextBeforeOrdinal == 0)) {
            throw IllegalArgumentException("transcript page cursor is inconsistent")
        }
        this.items = items
        this.nextBeforeOrdinal = nextBeforeOrdinal
        this.hasMore = hasMore
    }
}

public interface AgentTuiBackend {
    func observe(events: TuiAgentEventSink): Unit
    func welcome(): Array<TuiAgentEvent>
    func submit(
        prompt: String,
        events: TuiAgentEventSink
    ): TuiTurnResult
    func steer(correlationId: String, prompt: String): Bool
    func followUp(correlationId: String, prompt: String): Bool
    func withdrawQueued(correlationId: String): TuiQueueWithdrawal
    func decide(
        operationId: String,
        decision: TuiApprovalDecision,
        events: TuiAgentEventSink
    ): TuiTurnResult
    func reviewPlan(
        contentHash: String,
        decision: TuiPlanReviewDecision,
        feedback: String,
        events: TuiAgentEventSink
    ): TuiTurnResult
    func answerAsk(
        requestId: String,
        resolution: TuiAskResolution
    ): Bool
    func cancel(): Unit

    func currentModel(): String
    func currentSession(): String
    func currentThinking(): String
    func currentWorkMode(): String
    func currentTheme(): String
    func currentBranch(): String
    func workspace(): String
    func models(): Array<String>
    func customThemes(): Array<TuiThemeDefinition>
    func selectTheme(name: String): Bool
    func sessions(includeArchived: Bool): Array<TuiSessionNode>
    func sessionTree(): Array<TuiSessionNode>
    func renameSession(sessionId: String, name: String): Bool
    func archiveSession(sessionId: String): Bool
    func restoreSession(sessionId: String): Bool
    func subagents(): Array<TuiSubagentInfo>
    func subagentTranscript(id: String): String
    func focusSubagent(id: String): TuiConversationView
    func focusMain(): TuiConversationView
    func loadMainTranscriptPage(beforeOrdinal: Int64, limit: Int64): TuiTranscriptPage
    func extensions(): Array<TuiExtensionInfo>
    func setExtensionEnabled(id: String, enabled: Bool): Bool
    func draft(): String
    func saveDraft(value: String): Bool
    func branchMessages(): Array<String>
    func selectModel(model: String): Bool
    func selectSession(sessionId: String): Bool
    func selectBranch(entryId: String): ?String
    func configureSetup(request: TuiSetupRequest): String
    func archiveAndReset(): String
    func todoMarkdown(): TuiTodoLoadResult
    func saveTodoMarkdown(markdown: String): TuiTodoSaveResult
    func copyTodoMarkdown(): String
    func copyTextToClipboard(text: String): String
}
