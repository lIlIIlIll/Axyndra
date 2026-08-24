package agent_tui

import core.*

func headlessBuffersEqual(left: ?Buffer, right: ?Buffer): Bool {
    match ((left, right)) {
        case (Some(expected), Some(actual)) =>
            if (expected.area != actual.area) { return false }
            for (y in expected.area.y..expected.area.bottom) {
                for (x in expected.area.x..expected.area.right) {
                    if (expected.getCell(x, y) != actual.getCell(x, y)) { return false }
                }
            }
            true
        case (None, None) => true
        case _ => false
    }
}

func runHeadless(screen: AgentScreen): Int64 {
    if (headlessComposerPerformance()) {
        return runHeadlessComposerPerformance(screen)
    }
    if (headlessDocumentPerformance()) {
        return runHeadlessDocumentPerformance(screen)
    }
    if (headlessLongPerformance()) {
        return runHeadlessLongPerformance(screen)
    }
    if (headlessPerformance()) {
        return runHeadlessPerformance(screen)
    }
    let setupMode = headlessSetup()
    let cardMode = headlessCards()
    let todoMode = headlessTodo()
    let askMode = headlessAsk()
    if (cardMode) {
        screen.seedCardSmoke()
    }
    if (askMode) {
        screen.seedAskSmoke()
        if (!screen.askToolTakeoverObserved()) {
            println("headless cjtui ask tool takeover assertion failed")
            return 1
        }
        if (!screen.askToolCompletionPreservesTakeoverObserved()) {
            println("headless cjtui ask tool completion takeover assertion failed")
            return 1
        }
        if (!screen.askWaitingSuppressesActivityObserved()) {
            println("headless cjtui ask waiting activity assertion failed")
            return 1
        }
    }
    if (!setupMode && !cardMode && !todoMode && !askMode) {
        screen.seedDefaultGoldenSmoke()
    }
    tuiGoldenStage("fixture_ready", if (cardMode) {
        "cards_seeded"
    } else if (todoMode) {
        "todo_ready"
    } else if (askMode) {
        "ask_seeded"
    } else {
        "default_ready"
    })

    if (!agentOverlayChromeObserved()) {
        println("headless cjtui agent overlay assertion failed")
        return 1
    }
    if (!screen.sessionSelectorInteractionObserved()) {
        println("headless cjtui session selector interaction assertion failed")
        return 1
    }
    if (!screen.sessionSwitchRestoresTranscriptObserved()) {
        println("headless cjtui session transcript restore assertion failed")
        return 1
    }
    if (!screen.planReviewInteractionObserved()) {
        println("headless cjtui plan review interaction assertion failed")
        return 1
    }
    if (!setupMode && !cardMode && !askMode && !todoMode && !screen.composerHistoryNavigationObserved()) {
        println("headless cjtui composer history navigation assertion failed")
        return 1
    }

    if (cardMode && !screen.toolContinuationObserved()) {
        println("headless cjtui tool continuation assertion failed")
        return 1
    }
    if (cardMode && !screen.streamingInputObserved()) {
        println("headless cjtui streaming input assertion failed")
        return 1
    }
    if (cardMode && !screen.queuedInputChronologyObserved()) {
        println("headless cjtui queued input chronology assertion failed")
        return 1
    }
    if (cardMode && !screen.subagentConversationContractObserved()) {
        println("headless cjtui subagent conversation assertion failed")
        return 1
    }
    if (cardMode && !screen.subagentEscapeInterruptContractObserved()) {
        println("headless cjtui subagent escape interrupt assertion failed")
        return 1
    }
    if (cardMode && !screen.approvalRejectionRenderedOnce()) {
        println("headless cjtui approval rejection dedupe assertion failed")
        return 1
    }
    if (cardMode && !screen.approvalPausesWorkingImmediately()) {
        println("headless cjtui approval visibility assertion failed")
        return 1
    }
    if (cardMode && !screen.approvalMailboxRefreshObserved()) {
        println("headless cjtui approval mailbox refresh assertion failed")
        return 1
    }
    if (cardMode && !screen.approvalCancellationAndFailureSettlementObserved()) {
        println("headless cjtui approval cancellation/state settlement assertion failed")
        return 1
    }
    if (cardMode && !screen.unifiedCardChromeObserved()) {
        println("headless cjtui unified card chrome assertion failed")
        return 1
    }
    if (cardMode && !screen.cardChromeObserved()) {
        println("headless cjtui card chrome assertion failed")
        return 1
    }
    if (cardMode && !screen.toolCardPresentationObserved()) {
        println("headless cjtui tool card presentation assertion failed")
        return 1
    }
    if (cardMode && !screen.cardFocusNavigationObserved()) {
        println("headless cjtui card focus navigation assertion failed")
        return 1
    }
    if (cardMode && !screen.staleCardFocusToggleObserved()) {
        println("headless cjtui stale card focus toggle assertion failed")
        return 1
    }
    if (cardMode && !screen.markdownRenderingObserved()) {
        println("headless cjtui markdown rendering assertion failed")
        return 1
    }
    if (cardMode && !screen.revisionUtf8Safe()) {
        println("headless cjtui revision utf8 assertion failed")
        return 1
    }
    if (cardMode && !screen.markdownUtf8Safe()) {
        println("headless cjtui markdown utf8 assertion failed")
        return 1
    }
    if (cardMode && !screen.utf8BoundarySamplesSafe()) {
        println("headless cjtui utf8 boundary samples assertion failed")
        return 1
    }

    if (cardMode && !screen.cardClickToggleObserved()) {
        println("headless cjtui card click toggle assertion failed")
        return 1
    }
    if (cardMode && !screen.thinkingToggleDuringStreamObserved()) {
        println("headless cjtui thinking toggle during stream assertion failed")
        return 1
    }
    if (cardMode && !screen.streamTimerAdvancesSpinnerObserved()) {
        println("headless cjtui stream timer spinner assertion failed")
        return 1
    }
    if (cardMode && !screen.streamingPlainTextObserved()) {
        println("headless cjtui streaming plain text assertion failed")
        return 1
    }
    if (cardMode) {
        var bigBody = "completed"
        for (i in 0..60) {
            bigBody += "\nresult line " + i.toString()
        }
        UiReducer.reduce(
            screen.uiSnapshot(),
            UiEvent.UpsertCard("tool-0-1", UiCardKind.Tool, "Tool result · read", bigBody, "completed", true, "")
        )
        // Expanding a tool result must not pin the scroll position: the
        // scroll anchor captured before the expansion used to drag scrollTop
        // back on the next render, freezing the wheel. Click the header row
        // to expand, then wheel twice: the offset must advance each time.
        let run = {
            script: HeadlessScript => AppTestRunner.run(
                script,
                {frame => screen.render(frame)},
                {event => screen.update(event)},
                options: HeadlessRunOptions(
                    area: Rect(0, 0, 100, 28),
                    ticks: 2
                )
            )
        }
        let _ = run(HeadlessScript().mouse(MouseEvent(MouseKind.Down, MouseButton.Left, 10, 2)).tick(count: 4))
        let afterExpand = screen.scrollOffsetValue()
        let _ = run(HeadlessScript().mouse(MouseEvent(MouseKind.Scroll, MouseButton.WheelUp, 10, 10)).tick(count: 4))
        let wheel1 = screen.scrollOffsetValue()
        let _ = run(HeadlessScript().mouse(MouseEvent(MouseKind.Scroll, MouseButton.WheelUp, 10, 10)).tick(count: 4))
        let wheel2 = screen.scrollOffsetValue()
        if (wheel1 <= afterExpand || wheel2 <= wheel1) {
            println(
                "headless cjtui scroll after expand assertion failed:" + " afterExpand=" + afterExpand.toString() +
                    " wheel1=" + wheel1.toString() + " wheel2=" + wheel2.toString())
            return 1
        }
        // Restore the collapsed card and bottom scroll so the main script
        // below renders the same seed layout the other assertions expect.
        for (card in screen.uiSnapshot().cards where card.id == "tool-0-1") {
            card.collapsed = true
            card.markViewChanged()
        }
        let _ = run(HeadlessScript().key(KeyEvent(KeyCode.End, modifiers: KeyModifier(ctrl: true))).tick(count: 4))

        // Scroll-state matrix on the real virtual transcript: (A) bottom
        // follow while content is appended (streaming), (B) anchored
        // scrolling after PageUp pins the viewport (wheel advances,
        // PageDown returns to the bottom and re-enables follow).
        for (i in 0..40) {
            UiReducer.reduce(
                screen.uiSnapshot(),
                UiEvent.UpsertCard(
                    "scroll-extra-" + i.toString(),
                    UiCardKind.Assistant,
                    "Assistant",
                    "extra line " + i.toString() + "\nmore content",
                    "completed",
                    false,
                    ""
                )
            )
        }
        let _ = run(HeadlessScript().tick(count: 4))
        let followOffset = screen.scrollOffsetValue()
        let followStart = screen.transcriptStartLineValue()
        let _ = run(HeadlessScript().key(KeyEvent(KeyCode.PageUp)).tick(count: 4))
        let pinned = screen.scrollOffsetValue()
        let _ = run(HeadlessScript().mouse(
            MouseEvent(
                MouseKind.Scroll,
                MouseButton.WheelUp,
                10,
                10
            )
        ).tick(count: 4))
        let anchoredWheelUp = screen.scrollOffsetValue()
        let _ = run(HeadlessScript().mouse(
            MouseEvent(
                MouseKind.Scroll,
                MouseButton.WheelDown,
                10,
                10
            )
        ).tick(count: 4))
        let anchoredWheelDown = screen.scrollOffsetValue()
        let _ = run(HeadlessScript().key(KeyEvent(KeyCode.PageDown)).tick(count: 4))
        let backToBottom = screen.scrollOffsetValue()
        if (followOffset != 0 || followStart <= 0) {
            println(
                "headless cjtui scroll follow assertion failed:" + " offset=" + followOffset.toString() + " start=" +
                    followStart.toString())
            return 1
        }
        if (pinned <= 0 || anchoredWheelUp <= pinned || anchoredWheelDown >= anchoredWheelUp || backToBottom != 0) {
            println(
                "headless cjtui scroll anchor matrix assertion failed:" + " pinned=" + pinned.toString() + " wheelUp=" +
                    anchoredWheelUp.toString() + " wheelDown=" + anchoredWheelDown.toString() + " back=" +
                    backToBottom.toString())
            return 1
        }
        // Remove the synthetic cards and re-pin to the bottom so the main
        // script below sees the same seed layout as the other assertions.
        for (i in 0..40) {
            let id = "scroll-extra-" + i.toString()
            for (index in 0..screen.uiSnapshot().cards.size) {
                if (screen.uiSnapshot().cards[index].id == id) {
                    screen.uiSnapshot().cards.remove(at: index)
                    break
                }
            }
        }
        let _ = run(HeadlessScript().key(KeyEvent(KeyCode.End, modifiers: KeyModifier(ctrl: true))).tick(count: 4))
    }
    let script = if (setupMode) {
        HeadlessScript()
            .key(KeyEvent(KeyCode.Enter))
            .paste("contract-model")
            .key(KeyEvent(KeyCode.Enter))
            .paste("AXYNDRA_CONTRACT_KEY")
            .key(KeyEvent(KeyCode.Enter))
            .paste("headless-secret-contract")
            .key(KeyEvent(KeyCode.Enter))
            .tick(count: 4)
            .paste("/session")
            .key(KeyEvent(KeyCode.Enter))
            .tick(count: 4)
            .key(KeyEvent(KeyCode.Enter))
            .tick(count: 4)
            .resize(Rect(0, 0, 120, 36))
            .resize(Rect(0, 0, 80, 24))
            .resize(Rect(0, 0, 60, 18))
    } else if (todoMode) {
        HeadlessScript()
            .paste("/todo edit")
            .key(KeyEvent(KeyCode.Enter))
            .tick(count: 4)
            .paste("- [ ] Headless todo\n")
            .key(
                KeyEvent(
                    KeyCode.Char(r's'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
            .tick(count: 4)
            .paste("/todo")
            .key(KeyEvent(KeyCode.Enter))
            .waitMillis(250)
            .tick(count: 4)
            .paste("/todo copy")
            .key(KeyEvent(KeyCode.Enter))
            .tick(count: 4)
            .resize(Rect(0, 0, 120, 36))
            .resize(Rect(0, 0, 80, 24))
            .resize(Rect(0, 0, 60, 18))
    } else if (askMode) {
        HeadlessScript()
            .tick(count: 2)
            .waitMillis(250)
            .key(KeyEvent(KeyCode.Char(r' ')))
            .tick(count: 2)
            .key(KeyEvent(KeyCode.Char(r'n')))
            .paste("Prefer the portable path")
            .key(
                KeyEvent(
                    KeyCode.Char(r's'),
                    modifiers: KeyModifier(ctrl: true)
                )
            )
            .tick(count: 2)
            .key(KeyEvent(KeyCode.PageUp))
            .tick()
            .key(KeyEvent(KeyCode.Tab))
            .paste("Portable archive")
            .tick()
            .key(KeyEvent(KeyCode.Enter))
            .tick(count: 2)
            .key(KeyEvent(KeyCode.Down))
            .key(KeyEvent(KeyCode.Enter))
            .key(KeyEvent(KeyCode.Enter))
            .tick(count: 8)
            .key(KeyEvent(KeyCode.PageUp))
            .key(KeyEvent(KeyCode.PageDown))
            .resize(Rect(0, 0, 120, 36))
            .resize(Rect(0, 0, 80, 24))
            .resize(Rect(0, 0, 60, 18))
    } else if (cardMode) {
        // Card golden coverage owns a pre-seeded transcript. Running the
        // general slash-command journey here starts unrelated model/session
        // background work and used to leave the cards scenario waiting for a
        // state it never needed. Keep this scenario deterministic and bounded.
        HeadlessScript()
            .tick(count: 2)
            .key(KeyEvent(KeyCode.PageUp))
            .key(KeyEvent(KeyCode.PageDown))
            .resize(Rect(0, 0, 120, 36))
            .resize(Rect(0, 0, 80, 24))
            .resize(Rect(0, 0, 60, 18))
            .tick(count: 2)
    } else {
        // The default golden validates chrome, Unicode and composer layout.
        // Slash-command behavior is covered by the focused contract methods
        // above; replaying branch/session/debug commands here duplicated
        // backend work and could leave an async draft save alive at shutdown.
        HeadlessScript()
            .resize(Rect(0, 0, 120, 36))
            .resize(Rect(0, 0, 80, 24))
            .paste("你好\nfrom cjtui")
            .resize(Rect(0, 0, 60, 18))
            .tick(count: 2)
    }
    tuiGoldenStage("input_sent", "headless_script_ready")
    tuiGoldenStage("snapshot_started", "capturing_frames")
    let result = AppTestRunner.run(
        script,
        {frame => screen.render(frame)},
        {event => screen.update(event)},
        options: HeadlessRunOptions(
            area: Rect(0, 0, 100, 28),
            ticks: 2
        )
    )
    tuiGoldenStage("snapshot_completed", "frames_captured")

    if (
        !result.passed() ||
        (!setupMode && !todoMode && (screen.transcriptSize() == 0 || !screen.initialPromptObserved()))
    ) {
        println("headless cjtui smoke failed")
        return 1
    }
    if (askMode && !screen.askSubmissionContractObserved()) {
        println("headless cjtui ask submission assertion failed: " + screen.askSubmissionContractDiagnostic())
        return 1
    }
    if (!setupMode && !todoMode && !askMode && !cardMode && !screen.ompShortcutContractObserved()) {
        println("headless cjtui omp shortcut assertion failed")
        return 1
    }
    if (!screen.themeAwareUserMessageObserved()) {
        println("headless cjtui user message theme assertion failed")
        return 1
    }
    if (!screen.transcriptPagingObserved()) {
        println("headless cjtui transcript paging assertion failed")
        return 1
    }
    if (!screen.todoEditorMouseCaptureObserved()) {
        println("headless cjtui todo editor mouse capture assertion failed")
        return 1
    }
    if (!screen.askEditorIsolationObserved()) {
        println("headless cjtui ask editor isolation assertion failed")
        return 1
    }
    if (!setupMode && !todoMode && !askMode && !cardMode && !screen.inputAreaContractObserved()) {
        println("headless cjtui input area assertion failed")
        return 1
    }
    if (!setupMode && !screen.todoStripContractObserved()) {
        println("headless cjtui todo strip assertion failed")
        return 1
    }
    if (!setupMode && !todoMode && !askMode && !cardMode) {
        let viewport = Rect(0, 0, 60, 18)
        let grew = screen.update(Event.Paste("1\n2\n3\n4\n5\n6\n7\n8"))
        let _ = screen.update(Event.KeyDown(KeyEvent(KeyCode.Backspace)))
        let shrank = screen.update(Event.KeyDown(KeyEvent(KeyCode.Backspace)))
        if (!updateInvalidates(grew, viewport) || !updateInvalidates(shrank, viewport)) {
            println("headless cjtui composer resize invalidation failed")
            return 1
        }
    }
    let headerArea = Rect(0, 0, 180, 1)
    let headerBuffer = Buffer(headerArea)
    drawTuiHeader(
        Canvas(headerBuffer, headerArea),
        0,
        0,
        180,
        "DEEPSEEK/deepseek-v4-flash",
        "medium",
        "auto",
        "/workspace",
        "main",
        "session-1",
        "",
        0,
        0,
        "ready",
        axyndraTheme()
    )
    var sawColoredHeader = false
    let headerBorder = headerBuffer.getCell(0, 0)
    for (x in 0..headerArea.width) {
        let cell = headerBuffer.getCell(x, 0)
        if (headerBorder.symbol == "╭" && cell.symbol == "◆" && headerBorder.style != cell.style) {
            sawColoredHeader = true
        }
    }
    if (!sawColoredHeader) {
        println("headless cjtui colored header assertion failed")
        return 1
    }
    let toolPreview = compactToolPreview(
        "{\"paths\":\"README.md\\nagent_app/src/main.cj\\n" + "tail-sentinel.cj\",\"count\":3}",
        24
    )
    if (displayWidth(toolPreview) > 24 || toolPreview.contains("tail-sentinel.cj")) {
        println("headless cjtui tool preview assertion failed")
        return 1
    }
    let failedToolDetail = productCardDetail(
        UiCard(
            "failed-tool",
            UiCardKind.Error,
            "Tool result · task",
            "failed\n{\"error\":\"batch task requires non-empty context\"}",
            state: "failed"
        ),
        100
    )
    if (!failedToolDetail.contains("batch task requires non-empty context")) {
        println("headless cjtui failed tool detail assertion failed")
        return 1
    }
    var sawSmallChinese = false
    var sawLargeStatus = false
    var sawCards = false
    var sawToolCard = cardMode && screen.toolContinuationObserved()
    var sawApprovalRisk = false
    var sawInlineApprovalChoices = false
    var sawBranch = false
    var sawTodoEditor = false
    var sawTodoSaved = false
    var sawTodoCopy = false
    var sawTodoStrip = false
    var sawAsk = false
    var sawAskSelected = false
    var sawAskSingleSquare = false
    var sawAskSingleSelected = false
    var sawAskNote = false
    var sawAskCustom = false
    var sawAskTabText = false
    var sawAskInline = false
    var sawDiagnostics = false
    var sawComposer = false
    var sawMultilineComposer = false
    var sawMarkdown = false
    var saw120x36 = false
    var saw80x24 = false
    var saw60x18 = false
    var sawSessionTree = false
    var sawExtensions = false
    var sawInlineAgentHub = false
    for (snapshot in result.snapshots) {
        if (cardMode && snapshot.contains("The tool completed; summarize its result.")) {
            println("headless cjtui collapsed reasoning assertion failed")
            return 1
        }
        if (cardMode && snapshot.contains("Permission · edit")) {
            println("headless cjtui compatibility approval overlay assertion failed")
            return 1
        }
        if (snapshot.contains("headless-secret-contract")) {
            println("headless cjtui leaked a setup credential")
            return 1
        }
        if (setupMode && snapshot.contains("configuration saved")) {
            sawSmallChinese = true
        } else if (snapshot.contains("你") && snapshot.contains("好")) {
            sawSmallChinese = true
        }
        if (snapshot.contains("Welcome back!") || snapshot.contains("◆ ")) {
            sawLargeStatus = true
        }
        if (snapshot.contains("branch created; selected")) {
            sawBranch = true
        }
        if (snapshot.contains("Tool result") || snapshot.contains("Read ") || snapshot.contains("Run ")) {
            sawToolCard = true
        }
        if (snapshot.contains("MEDIUM RISK") && (snapshot.contains("! Approval · Edit file") || snapshot.contains(
            "? Approval · Edit file") || snapshot.contains("[!] Approval · Edit file") || snapshot.contains(
            "[?] Approval · Edit file"))) {
            sawApprovalRisk = true
        }
        if ((snapshot.contains("! Approval · Edit file") || snapshot.contains("? Approval · Edit file") ||
            snapshot.contains("[!] Approval · Edit file") || snapshot.contains("[?] Approval · Edit file")) &&
            snapshot.contains("Allow once") && (snapshot.contains("Deny") || snapshot.contains("Reject"))) {
            sawInlineApprovalChoices = true
        }
        sawCards = sawToolCard && sawApprovalRisk
        if (snapshot.contains("Todo Markdown") && snapshot.contains("Headless todo")) {
            sawTodoEditor = true
        }
        if (snapshot.contains("Saved ") && snapshot.contains(" phase(s), ") && snapshot.contains(" task(s).")) {
            sawTodoSaved = true
        }
        if (snapshot.contains("Clipboard payload encoded")) {
            sawTodoCopy = true
        }
        if (snapshot.contains("Todo 0/1") && snapshot.contains("Headless todo")) {
            sawTodoStrip = true
        }
        if (snapshot.contains("Which features should be enabled?") && snapshot.contains("Export (Recommended)")) {
            sawAsk = true
        }
        if (askMode && snapshot.contains("Awaiting your decision") &&
            (snapshot.contains("Generic tool view") || snapshot.contains(" Working…"))) {
            println("headless cjtui ask waiting state leaked generic activity")
            return 1
        }
        if (snapshot.contains("[x] Export")) {
            sawAskSelected = true
        }
        if (snapshot.contains("Which verification should run?") && snapshot.contains("[ ] Node tests")) {
            sawAskSingleSquare = true
        }
        if (snapshot.contains("Which verification should run?") && snapshot.contains("[x] Node tests")) {
            sawAskSingleSelected = true
        }
        if (askMode && snapshot.contains("( ) ")) {
            println("headless cjtui ask single-choice marker assertion failed")
            return 1
        }
        if (snapshot.contains("Prefer the portable path")) {
            sawAskNote = true
        }
        if (snapshot.contains("Portable archive")) {
            sawAskCustom = true
        }
        if (snapshot.contains("Tab edit Other")) {
            sawAskTabText = true
        }
        if (snapshot.contains("Other: Portable archive") && snapshot.contains("Enter save · Esc cancel")) {
            sawAskInline = true
        }
        if (snapshot.contains("Diagnostics") && snapshot.contains("Debug snapshot:")) {
            sawDiagnostics = true
        }
        if (snapshot.contains("message")) {
            sawComposer = true
        }
        if (cardMode && screen.markdownRenderingObserved()) {
            sawMarkdown = true
        }
        if (snapshotHasAdjacentText(
            snapshot,
            "│ 你",
            "│ from cjtui"
        )) {
            sawMultilineComposer = true
        }
        if (cardMode && snapshot.contains("bold-sentinel") && snapshot.contains("code-sentinel") &&
            !snapshot.contains("**bold-sentinel**") && !snapshot.contains("`code-sentinel`")) {
            sawMarkdown = true
        }
        if (snapshotHasSize(snapshot, 120, 36)) {
            saw120x36 = true
        }
        if (snapshotHasSize(snapshot, 80, 24)) {
            saw80x24 = true
        }
        if (snapshotHasSize(snapshot, 60, 18)) {
            saw60x18 = true
        }
        if (snapshot.contains("Session tree")) {
            sawSessionTree = true
        }
        if (snapshot.contains("Extensions") && snapshot.contains("No external extensions are installed.")) {
            sawExtensions = true
        }
        if (snapshot.contains("Agent Hub") && snapshot.contains("Main") && snapshot.contains("task spawns appear here") &&
            snapshot.contains("Enter switch") && !snapshot.contains("Select subagent") &&
            !snapshot.contains("╰─ message") && snapshot.split("╭── ◆").size <= 2) {
            sawInlineAgentHub = true
        }
    }
    // TestBackend snapshots may trim fully blank trailing rows. Buffer areas
    // are the authoritative terminal dimensions for resize coverage.
    for (buffer in result.frames) {
        if (buffer.area.width == 120 && buffer.area.height == 36) {
            saw120x36 = true
        }
        if (buffer.area.width == 80 && buffer.area.height == 24) {
            saw80x24 = true
        }
        if (buffer.area.width == 60 && buffer.area.height == 18) {
            saw60x18 = true
        }
    }
    if (askMode && screen.askSingleSelectionRenderingObserved()) {
        sawAskSingleSelected = true
    }
    if ((!todoMode && !askMode && !cardMode && !sawSmallChinese) || !sawLargeStatus || (todoMode && (!sawTodoEditor ||
        !sawTodoSaved || !sawTodoCopy || !sawTodoStrip)) || (askMode && (!sawAsk || !sawAskSelected ||
        !sawAskSingleSquare || !sawAskSingleSelected || !sawAskNote || !sawAskCustom || !sawAskTabText ||
        !sawAskInline)) ||
        (cardMode && (!sawCards || !sawInlineApprovalChoices || !sawMarkdown)) ||
        (!setupMode && !todoMode && !askMode && !cardMode && !sawMultilineComposer) ||
        !sawComposer || !saw120x36 || !saw80x24 || !saw60x18) {
        println(
            "headless cjtui snapshot assertion failed:" + " chinese=" + sawSmallChinese.toString() + " status=" +
                sawLargeStatus.toString() + " cards=" + sawCards.toString() + " tool-card=" + sawToolCard.toString() +
                " approval-risk=" + sawApprovalRisk.toString() + " branch=" + sawBranch.toString() + " diagnostics=" +
                sawDiagnostics.toString() + " tree=" + sawSessionTree.toString() + " extensions=" +
                sawExtensions.toString() + " agent-hub=" + sawInlineAgentHub.toString() + " todo=" +
                sawTodoEditor.toString() + " todo-saved=" + sawTodoSaved.toString() + " todo-copy=" +
                sawTodoCopy.toString() + " todo-strip=" + sawTodoStrip.toString() + " ask=" + sawAsk.toString() +
                " ask-single-square=" + sawAskSingleSquare.toString() + " ask-single-selected=" +
                sawAskSingleSelected.toString() + " ask-custom=" + sawAskCustom.toString() + " ask-tab-text=" +
                sawAskTabText.toString() + " ask-inline=" + sawAskInline.toString() + " composer=" + sawComposer.toString() +
                " multiline-composer=" + sawMultilineComposer.toString() + " markdown=" + sawMarkdown.toString() +
                " sizes=" + saw120x36.toString() + "/" + saw80x24.toString() + "/" + saw60x18.toString() +
                " final-status=" + screen.statusText())
        return 1
    }
    if (result.frames.isEmpty()) {
        println("headless cjtui prompt style assertion failed: no frame")
        return 1
    }
    let expectedPromptBorder = if (screen.unicodeMode()) {
        "╰"
    } else {
        "+"
    }
    var promptStyleObserved = false
    for (buffer in result.frames) {
        let promptY = buffer.area.bottom - 1
        let promptBorder = buffer.getCell(buffer.area.x, promptY)
        let promptEnd = buffer.getCell(buffer.area.right - 1, promptY)
        let promptSide = buffer.getCell(buffer.area.x, promptY - 1)
        if (promptBorder.symbol == expectedPromptBorder && (promptEnd.symbol == "╯" || promptEnd.symbol == "+") &&
            (promptSide.symbol == "│" || promptSide.symbol == "|")) {
            promptStyleObserved = true
        }
    }
    if (!promptStyleObserved) {
        let lastFrame = result.frames[result.frames.size - 1]
        let promptY = lastFrame.area.bottom - 1
        let promptBorder = lastFrame.getCell(lastFrame.area.x, promptY)
        let promptEnd = lastFrame.getCell(lastFrame.area.right - 1, promptY)
        let promptSide = lastFrame.getCell(lastFrame.area.x, promptY - 1)
        println(
            "headless cjtui prompt frame assertion failed: border=" + promptBorder.symbol + " end=" + promptEnd
                .symbol + " side=" + promptSide.symbol)
        return 1
    }
    let approvalCard = approvalCardBody(
        "edit",
        "workspace.write",
        "workspace/note.txt",
        "medium",
        "Target is a critical project file",
        "{\"path\":\"note.txt\"}"
    )
    if (!approvalCard.contains("MEDIUM RISK · workspace.write") || !approvalCard.contains("Target  workspace/note.txt") ||
        !approvalCard.contains("workspace/note.txt") || approvalCard.contains("operation:") || approvalCard.contains(
        "call:") || approvalCard.contains("arguments:")) {
        println("headless cjtui approval card assertion failed")
        return 1
    }
    tuiGoldenStage("expected_state_reached", "golden_contract_satisfied")
    println("tui golden ok sizes=120x36,80x24,60x18 " + "semantics=welcome,user-strip,composer,status,wide-char")
    0
}

func runHeadlessPerformance(screen: AgentScreen): Int64 {
    screen.seedPerformanceSmoke()
    let script = HeadlessScript()
        .tick(count: 2)
        .key(KeyEvent(KeyCode.PageUp))
        .tick(count: 1)
        .key(KeyEvent(KeyCode.PageDown))
        .key(KeyEvent(KeyCode.End))
        .resize(Rect(0, 0, 120, 36))
        .resize(Rect(0, 0, 80, 24))
        .resize(Rect(0, 0, 60, 18))
        .tick(count: 3)
        .key(KeyEvent(KeyCode.End))
    let result = AppTestRunner.run(
        script,
        {frame => screen.render(frame)},
        {event => screen.update(event)},
        options: HeadlessRunOptions(
            area: Rect(0, 0, 100, 28),
            ticks: 0,
            captureBuffers: false,
            captureSnapshots: false
        )
    )
    if (!result.passed() || screen.transcriptSize() == 0) {
        println("headless cjtui performance journey failed")
        return 1
    }
    var renderMillis: Int64 = 0
    var drawMillis: Int64 = 0
    for (frame in result.metrics.frames()) {
        renderMillis += frame.renderMillis
        drawMillis += frame.drawMillis
    }
    println(
        "tui headless performance frames=${result.metrics.frames().size}" +
            " render=${renderMillis}ms draw=${drawMillis}ms")
    0
}

func runHeadlessLongPerformance(screen: AgentScreen): Int64 {
    if (!screen.selectivePaintDifferentialObserved()) {
        println("tui selective/full differential failed")
        return 1
    }
    let backend = TestBackend(area: Rect(0, 0, 100, 28))
    let terminal = Terminal(backend, renderMode: RenderMode.Diff)
    var renderMillis: Int64 = 0
    var maximumRenderMillis: Int64 = 0
    var frames: Int64 = 0
    let initial = terminal.draw({frame => screen.render(frame)})
    renderMillis += initial.renderMillis
    maximumRenderMillis = max(maximumRenderMillis, initial.renderMillis)
    frames++
    for (direction in [MouseButton.WheelUp, MouseButton.WheelDown]) {
        for (_ in 0..120) {
            let update = screen.update(Event.Mouse(MouseEvent(MouseKind.Scroll, direction, 40, 10)))
            if (!update.renderRequested) {
                continue
            }
            let metrics = terminal.draw(
                {frame => screen.render(frame)},
                dirtyRects: update.dirtyRects
            )
            renderMillis += metrics.renderMillis
            maximumRenderMillis = max(maximumRenderMillis, metrics.renderMillis)
            frames++
        }
    }
    let documentCalls = screen.transcriptDocumentCalls()
    println(
        "tui long transcript frames=${frames}" +
            " render=${renderMillis}ms max=${maximumRenderMillis}ms documents=${documentCalls}")
    let cardCount = longTranscriptPerformanceCards()
    let maximumDocuments = min(cardCount, 200)
    let transcriptSize = screen.transcriptSize()
    let expectedFinalCount = screen.selectivePaintDifferentialExpectedFinalCount()
    let contentPreserved = screen.longTranscriptFixtureContentPreserved()
    println(
        "tui long transcript gates configured=${cardCount}" +
            " transcript_expected=${expectedFinalCount}" +
            " transcript_actual=${transcriptSize}" +
            " content_preserved=${contentPreserved}" +
            " documents_expected<=${maximumDocuments}" +
            " documents_actual=${documentCalls}")
    if (transcriptSize != expectedFinalCount || !contentPreserved || documentCalls > maximumDocuments) {
        println("headless cjtui long transcript journey failed")
        return 1
    }
    0
}

func runHeadlessDocumentPerformance(screen: AgentScreen): Int64 {
    screen.seedDocumentPerformance()
    let backend = TestBackend(area: Rect(0, 0, 100, 28))
    let terminal = Terminal(backend, renderMode: RenderMode.Diff)
    var renderMillis: Int64 = 0
    var drawMillis: Int64 = 0
    var maximumRenderMillis: Int64 = 0
    var frames: Int64 = 0
    var scrollRenderMillis: Int64 = 0
    var typingRenderMillis: Int64 = 0
    let initial = terminal.draw({frame => screen.render(frame)})
    renderMillis += initial.renderMillis
    drawMillis += initial.drawMillis
    maximumRenderMillis = max(maximumRenderMillis, initial.renderMillis)
    frames++
    for (direction in [MouseButton.WheelDown, MouseButton.WheelUp]) {
        for (_ in 0..120) {
            let update = screen.update(Event.Mouse(MouseEvent(MouseKind.Scroll, direction, 50, 14)))
            if (!update.renderRequested) {
                continue
            }
            let metrics = terminal.draw({frame => screen.render(frame)}, dirtyRects: update.dirtyRects)
            renderMillis += metrics.renderMillis
            scrollRenderMillis += metrics.renderMillis
            drawMillis += metrics.drawMillis
            maximumRenderMillis = max(maximumRenderMillis, metrics.renderMillis)
            frames++
        }
    }
    let afterRoundTrip = screen.documentScrollPosition()
    for (_ in 0..120) {
        let update = screen.update(Event.KeyDown(KeyEvent(KeyCode.Char(r'x'))))
        let metrics = terminal.draw({frame => screen.render(frame)}, dirtyRects: update.dirtyRects)
        renderMillis += metrics.renderMillis
        typingRenderMillis += metrics.renderMillis
        drawMillis += metrics.drawMillis
        maximumRenderMillis = max(maximumRenderMillis, metrics.renderMillis)
        frames++
    }
    let layouts = screen.documentLayoutCalls()
    println(
        "tui document performance frames=${frames}" +
            " render=${renderMillis}ms scroll=${scrollRenderMillis}ms typing=${typingRenderMillis}ms" +
            " draw=${drawMillis}ms max=${maximumRenderMillis}ms layouts=${layouts}")
    let averageRenderMillis = renderMillis / max(1, frames)
    let averageTypingMillis = typingRenderMillis / 120
    if (afterRoundTrip != 0 || layouts >= 30 || averageRenderMillis > 25 || averageTypingMillis > 8 ||
        maximumRenderMillis > 250) {
        println("headless cjtui document performance journey failed")
        return 1
    }
    0
}

func runHeadlessComposerPerformance(screen: AgentScreen): Int64 {
    screen.seedLongTranscriptPerformance()
    let backend = TestBackend(area: Rect(0, 0, 100, 28))
    let terminal = Terminal(backend, renderMode: RenderMode.Diff)
    var renderMillis: Int64 = 0
    var maximumRenderMillis: Int64 = 0
    var frames: Int64 = 0
    _ = terminal.draw({frame => screen.render(frame)})
    for (index in 0..180) {
        let rune = if (index % 12 == 0) {
            r'界'
        } else {
            r'x'
        }
        let update = screen.update(Event.KeyDown(KeyEvent(KeyCode.Char(rune))))
        let metrics = terminal.draw({frame => screen.render(frame)}, dirtyRects: update.dirtyRects)
        renderMillis += metrics.renderMillis
        maximumRenderMillis = max(maximumRenderMillis, metrics.renderMillis)
        frames++
    }
    let sizeAfterTyping = screen.composerValueSize()
    for (_ in 0..90) {
        let update = screen.update(Event.KeyDown(KeyEvent(KeyCode.Backspace)))
        let metrics = terminal.draw({frame => screen.render(frame)}, dirtyRects: update.dirtyRects)
        renderMillis += metrics.renderMillis
        maximumRenderMillis = max(maximumRenderMillis, metrics.renderMillis)
        frames++
    }
    let averageRenderMillis = renderMillis / max(1, frames)
    println(
        "tui composer performance frames=${frames} render=${renderMillis}ms" +
            " average=${averageRenderMillis}ms max=${maximumRenderMillis}ms size=${sizeAfterTyping}")
    if (sizeAfterTyping <= screen.composerValueSize() || averageRenderMillis > 12 || maximumRenderMillis > 80) {
        println("headless cjtui composer performance journey failed")
        return 1
    }
    0
}

func snapshotHasSize(
    snapshot: String,
    width: Int64,
    height: Int64
): Bool {
    let lines = snapshot.split("\n")
    if (lines.size != height) {
        return false
    }
    !lines.isEmpty() && displayWidth(lines[0]) == width
}

func agentOverlayChromeObserved(): Bool {
    let theme = axyndraTheme()
    let plan = planReviewDocument(
        "Latest plan:\n\n# Goal\n\nShip the event-card migration.",
        1,
        theme
    )
    let unicodeBackend = TestBackend(area: Rect(0, 0, 60, 18))
    let unicodeTerminal = Terminal(unicodeBackend, renderMode: RenderMode.Diff)
    _ = unicodeTerminal.draw({
        frame => renderAgentOverlay(
            frame,
            frame.area,
            "Plan review",
            plan,
            0,
            "↑↓ choose · Enter confirm · Esc cancel",
            theme,
            true,
            document: true
        )
    })
    let unicodeSnapshot = unicodeBackend.snapshot()
    if (!unicodeSnapshot.contains("╭─ Plan review") || !unicodeSnapshot.contains("› 2. Keep planning") ||
        !unicodeSnapshot.contains("╰─") || unicodeSnapshot.contains("+-- Plan review")) {
        return false
    }

    let asciiBackend = TestBackend(area: Rect(0, 0, 40, 12))
    let asciiTerminal = Terminal(asciiBackend, renderMode: RenderMode.Diff)
    _ = asciiTerminal.draw({
        frame => renderAgentOverlay(
            frame,
            frame.area,
            "Select model",
            modalBody(["model-a", "model-b"], 0, theme),
            0,
            "j/k select · Enter confirm · Esc cancel",
            theme,
            false,
            itemCount: 2
        )
    })
    let asciiSnapshot = asciiBackend.snapshot()
    asciiSnapshot.contains("+- Select model") && asciiSnapshot.contains("› model-a") && asciiSnapshot.contains(
        "+- j/k select")
}

func bufferRowText(buffer: Buffer, area: Rect): String {
    if (area.height <= 0) {
        return ""
    }
    var output = ""
    for (x in area.x..area.right) {
        output += buffer.getCell(x, area.y).symbol
    }
    output
}

func snapshotHasAdjacentText(
    snapshot: String,
    first: String,
    second: String
): Bool {
    let lines = snapshot.split("\n")
    if (lines.size < 2) {
        return false
    }
    for (index in 0..(lines.size - 1)) {
        if (lines[index].contains(first) && lines[index + 1].contains(second)) {
            return true
        }
    }
    false
}

func updateInvalidates(result: UpdateResult, area: Rect): Bool {
    match (result.dirtyRects) {
        case Some(rects) => rects.covers(area)
        case None => false
    }
}
