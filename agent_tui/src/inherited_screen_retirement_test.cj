package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.unittest.*
import std.unittest.testmacro.*

class ActualInheritedScreenOrdinaryBackend <: AgentTuiBackend {
    var observer: ?TuiAgentEventSink = None
    public func observe(events: TuiAgentEventSink): Unit { observer = Some(events) }
    public func welcome(): Array<TuiAgentEvent> { [] }
    public func submit(
        prompt: String,
        events: TuiAgentEventSink
    ): TuiTurnResult { throw Exception("unused ordinary Screen control method") }
    public func steer(correlationId: String, prompt: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func followUp(correlationId: String, prompt: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func withdrawQueued(correlationId: String): TuiQueueWithdrawal { throw Exception("unused ordinary Screen control method") }
    public func decide(
        operationId: String,
        decision: TuiApprovalDecision,
        events: TuiAgentEventSink
    ): TuiTurnResult { throw Exception("unused ordinary Screen control method") }
    public func loadPluginView(routeName: String): TuiTurnResult { throw Exception("unused ordinary Screen control method") }
    public func pluginViewAction(viewId: String, revision: String, actionId: String,
        fields: Array<TuiPluginViewField>, events: TuiAgentEventSink): TuiTurnResult {
        throw Exception("unused ordinary Screen control method")
    }
    public func confirmPluginView(viewId: String, revision: String, requestDigest: String, confirmed: Bool,
        events: TuiAgentEventSink): TuiTurnResult { throw Exception("unused ordinary Screen control method") }
    public func closePluginView(viewId: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func answerAsk(
        requestId: String,
        resolution: TuiAskResolution
    ): Bool { throw Exception("unused ordinary Screen control method") }
    public func pluginCommands(): Array<String> { throw Exception("unused ordinary Screen control method") }
    public func runPluginCommand(
        routeName: String,
        arguments: String,
        events: TuiAgentEventSink
    ): TuiTurnResult { throw Exception("unused ordinary Screen control method") }
    public func cancel(): Unit { throw Exception("unused ordinary Screen control method") }
    public func currentModel(): String { "held model" }
    public func currentSession(): String { throw Exception("unused ordinary Screen control method") }
    public func currentThinking(): String { throw Exception("unused ordinary Screen control method") }
    public func currentWorkMode(): String { throw Exception("unused ordinary Screen control method") }
    public func currentShellNetworkMode(): String { throw Exception("unused ordinary Screen control method") }
    public func currentTheme(): String { "axyndra" }
    public func currentBranch(): String { throw Exception("unused ordinary Screen control method") }
    public func workspace(): String { "held workspace" }
    public func models(): Array<String> { throw Exception("unused ordinary Screen control method") }
    public func customThemes(): Array<TuiThemeDefinition> { [] }
    public func selectTheme(name: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func sessions(includeArchived: Bool): Array<TuiSessionNode> { throw Exception("unused ordinary Screen control method") }
    public func sessionTree(): Array<TuiSessionNode> { throw Exception("unused ordinary Screen control method") }
    public func renameSession(sessionId: String, name: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func archiveSession(sessionId: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func restoreSession(sessionId: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func subagents(): Array<TuiSubagentInfo> { throw Exception("unused ordinary Screen control method") }
    public func subagentTranscript(id: String): String { throw Exception("unused ordinary Screen control method") }
    public func focusSubagent(id: String): TuiConversationView { throw Exception("unused ordinary Screen control method") }
    public func focusMain(): TuiConversationView { throw Exception("unused ordinary Screen control method") }
    public func loadMainTranscriptPage(beforeOrdinal: Int64, limit: Int64): TuiTranscriptPage { throw Exception("unused ordinary Screen control method") }
    public func draft(): String { "" }
    public func saveDraft(value: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func branchMessages(): Array<String> { throw Exception("unused ordinary Screen control method") }
    public func selectModel(model: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func selectSession(sessionId: String): Bool { throw Exception("unused ordinary Screen control method") }
    public func selectBranch(entryId: String): ?String { throw Exception("unused ordinary Screen control method") }
    public func configureSetup(request: TuiSetupRequest): String { throw Exception("unused ordinary Screen control method") }
    public func archiveAndReset(): String { throw Exception("unused ordinary Screen control method") }
    public func todoMarkdown(): TuiTodoLoadResult { TuiTodoLoadResult(true, "", "") }
    public func saveTodoMarkdown(markdown: String): TuiTodoSaveResult { throw Exception("unused ordinary Screen control method") }
    public func copyTodoMarkdown(): String { throw Exception("unused ordinary Screen control method") }
    public func copyTextToClipboard(text: String): String { throw Exception("unused ordinary Screen control method") }
}

@Test
class InheritedScreenRetirementTests {
    @TestCase
    func ActualUnretiredScreenKeepsOriginalInitialPromptAndCannotMintReceipt(): Unit {
        let backend = ActualInheritedScreenOrdinaryBackend()
        let prompt = "\u{0000}完整 inherited prompt"
        let screen = AgentScreen(backend, "held title", prompt)
        @Expect(screen.hasInitialPrompt(), true)
        @Expect(backend.observer.isSome(), true)
        @Expect(RetiredOwnedTuiScreenReferences.retire(screen).isNone(), true)
        @Expect(screen.hasInitialPrompt(), true)
        @Expect(prompt, "\u{0000}完整 inherited prompt")
        // An ordinary retained observer is not a physical producer ACK.
    }

    @TestCase
    func RealInheritedFieldHelperClearsScreenReferencesButKeepsExternalOwnersAndPayment(): Unit {
        let backend = ActualInheritedScreenOrdinaryBackend()
        let prompt = "\u{0000}完整 inherited prompt"
        let screen = AgentScreen(backend, "held title", prompt)
        let queued = QueuedPrompt("queue", "follow_up", prompt)
        let withdrawal = CompletedQueueWithdrawal("withdrawal", TuiQueueWithdrawal.Withdrawn("follow_up", prompt))
        let node = TuiSessionNode("session", prompt, prompt, "parent", "model", "mode", 1, true)
        let nodes = [node]
        let agent = TuiSubagentInfo("agent", "model", "running", prompt)
        let agents = [agent]
        let pluginDocument = prompt
        let theme = TuiThemeDefinition(prompt, "", "", "", "", "", "", "", "", "", "", "", "")
        let themes = [theme]
        let bank = LogicalJsonOwnerBudget(); let original = bank.acquire(1)
        let display = OwnedTuiToolDisplay(original.acquireCopiedDisplayAllocation(65536).value().getOrThrow(), 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStarted("bash", prompt)).isOk(), true)
        original.close(); let paid = bank.usage()[1]
        @Expect(screen.observeInheritedFieldClearWithoutReceipt(queued, withdrawal, nodes, agents, pluginDocument, themes), true)
        @Expect(screen.hasInitialPrompt(), false)
        @Expect(screen.statusText(), "")
        @Expect(queued.text, prompt); @Expect(nodes[0].summary, prompt)
        @Expect(agents[0].task, prompt); @Expect(pluginDocument, prompt)
        @Expect(themes[0].name, prompt); @Expect(backend.observer.isSome(), true)
        @Expect(RetiredOwnedTuiScreenReferences.retire(screen).isNone(), true)
        @Expect(bank.usage()[1], paid); @Expect(display.isAcknowledged(), false)
        // The REAL field helper was exercised without any fake native frame,
        // notifier, custom backend, StdOut, global data or bank-zero ACK.
    }
}
