package agent_tui

import core.*
import markdown.*
import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class AgentEventCardTests {
    @TestCase
    func cardKindNamesPreserveLegacyStableValues(): Unit {
        let cases = [
            (UiCardKind.User, "user"),
            (UiCardKind.Assistant, "assistant"),
            (UiCardKind.Reasoning, "reasoning"),
            (UiCardKind.Tool, "tool"),
            (UiCardKind.Approval, "approval"),
            (UiCardKind.Permission, "permission"),
            (UiCardKind.Ask, "ask"),
            (UiCardKind.Plan, "plan"),
            (UiCardKind.Subagent, "subagent"),
            (UiCardKind.Advisor, "advisor"),
            (UiCardKind.Reviewer, "reviewer"),
            (UiCardKind.Job, "job"),
            (UiCardKind.Warning, "warning"),
            (UiCardKind.Compaction, "compaction"),
            (UiCardKind.Summary, "summary"),
            (UiCardKind.Error, "error"),
            (UiCardKind.Steer, "steer"),
            (UiCardKind.Setup, "setup"),
            (UiCardKind.Mcp, "mcp")
        ]
        for ((kind, expected) in cases) {
            @Expect(uiCardKindName(kind), expected)
        }
    }

    @TestCase
    func reviewerFailureDoesNotReplaceDeterministicRiskReason(): Unit {
        let body = approvalReviewCardBody(
            "needs_user",
            "medium",
            "DEEPSEEK/deepseek-v4-flash",
            "Target is outside the current workspace",
            "approval reviewer failed: JSON error at byte 0",
            "model.invalid_response"
        )
        @Expect(body.contains("Reason    Target is outside the current workspace"))
        @Expect(body.contains("Failure   model.invalid_response · approval reviewer failed"))
        @Expect(!body.contains("Reason    approval reviewer failed"))
    }

    @TestCase
    func foldedToolPreservesRendererNativeChrome(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard("github-folded", UiCardKind.Tool, "GitHub", "completed", "completed", true, "")
        )
        UiReducer.reduce(
            snapshot,
            UiEvent.SetToolMetadata("github-folded", "github", "{}", "github-call", "")
        )
        let source = AgentTranscriptSource(snapshot, {_, _, _ => Document([])})
        @Expect(source.itemUsesCardChrome(0))
        @Expect(source.itemUsesCompactCardChrome(0))
        match (source.itemCardTheme(0)) {
            case Some(theme) => @Expect(!theme.fullFrame)
            case None => @Fail("tool card theme must exist")
        }

        snapshot.cards[0].footer = "Created · #142"
        snapshot.cards[0].markContentChanged()
        @Expect(!source.itemUsesCompactCardChrome(0))

        let shell = UiCard("shell-folded", UiCardKind.Tool, "Run true", "", state: "completed", collapsed: true)
        shell.toolName = "bash"
        shell.toolArguments = "{\"command\":\"true\"}"
        snapshot.cards.add(shell)
        @Expect(!source.itemUsesCompactCardChrome(1))
        match (source.itemCardTheme(1)) {
            case Some(theme) => @Expect(theme.fullFrame)
            case None => @Fail("shell card theme must exist")
        }
    }

    @TestCase
    func sessionSelectorUsesSummaryTreeDetailsAndResponsiveLayout(): Unit {
        let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        let root = TuiSessionNode(
            "session-root-12345678",
            "Approval work",
            "Implement scoped AI approval",
            "",
            "local/model",
            "normal",
            now,
            true
        )
        let child = TuiSessionNode(
            "session-child-87654321",
            "",
            "Review the session selector 中文🙂",
            root.id,
            "local/reviewer",
            "plan",
            now - 60000,
            false,
            archived: true
        )
        let nodes = [root, child]
        let labels = sessionLabels(nodes, nodes)
        @Expect(labels[0].startsWith("● "))
        @Expect(labels[1].contains("  [archived] Review the session selector"))
        for (width in [40, 80, 120]) {
            let text = documentText(sessionModalDocument(nodes, nodes, 1, monoTheme(), width, "browse", ""))
            @Expect(text.contains("Review the session selector 中文🙂"))
            @Expect(text.contains("session-child-87654321"))
            @Expect(text.contains("archived"))
        }
        let singleton = documentText(sessionModalDocument([root], [root], 0, monoTheme(), 80, "browse", ""))
        @Expect(singleton.contains("session-root-12345678"))
        @Expect(singleton.contains("Model    local/model"))
        @Expect(sessionSearchText(child).contains("session-child-87654321"))
        @Expect(sessionSearchText(child).contains("中文"))
        @Expect(dropLastSessionRune("会话🙂") == "会话")
        @Expect(sessionSelectorFooter("confirm_archive", false, "").contains("Enter confirm"))
        @Expect(sessionSelectorFooter("browse", true, "").contains("u restore"))
    }

    @TestCase
    func reducerKeepsOneCardAcrossToolLifecycle(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "call-1",
                UiCardKind.Tool,
                "Run cargo test",
                "",
                "running",
                false,
                ""
            )
        )
        UiReducer.reduce(
            snapshot,
            UiEvent.SetToolMetadata(
                "call-1",
                "bash",
                "{\"command\":\"cargo test\"}",
                "call-1",
                ""
            )
        )
        UiReducer.reduce(
            snapshot,
            UiEvent.AppendToolOutput("call-1", "\u{1B}[31mline 1\u{1B}[0m\nline 2")
        )
        UiReducer.reduce(
            snapshot,
            UiEvent.SetCardState("call-1", "completed", "completed\nresult", true)
        )
        @Expect(snapshot.cards.size, 1)
        @Expect(snapshot.cards[0].id, "call-1")
        @Expect(snapshot.cards[0].state, "completed")
        @Expect(snapshot.cards[0].toolOutput, "\u{1B}[31mline 1\u{1B}[0m\nline 2")
        @Expect(stripAnsi(snapshot.cards[0].toolOutput), "line 1\nline 2")
    }

    @TestCase
    func reducerUpdatesStatesInPlaceAndPreservesManualFold(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(snapshot, UiEvent.UpsertCard("call-2", UiCardKind.Tool, "Run test", "", "pending", true, ""))
        snapshot.cards[0].collapseTouched = true
        UiReducer.reduce(snapshot, UiEvent.SetCardState("call-2", "running", "running", false))
        UiReducer.reduce(snapshot, UiEvent.SetCardState("call-2", "failed", "failed\nerror", false))
        @Expect(snapshot.cards.size, 1)
        @Expect(snapshot.cards[0].state, "failed")
        @Expect(snapshot.cards[0].collapsed)
        snapshot.cards[0].collapsed = false
        UiReducer.reduce(snapshot, UiEvent.SetCardState("call-2", "cancelled", "cancelled", true))
        @Expect(snapshot.cards.size, 1)
        @Expect(snapshot.cards[0].state, "cancelled")
        @Expect(!snapshot.cards[0].collapsed)
    }

    @TestCase
    func lateOutputCannotResurrectSettledToolCard(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(snapshot, UiEvent.UpsertCard("call-late", UiCardKind.Tool, "Run test", "", "running", false, ""))
        UiReducer.reduce(snapshot, UiEvent.SetCardState("call-late", "completed", "completed", true))
        UiReducer.reduce(snapshot, UiEvent.AppendToolOutput("call-late", "late output"))
        UiReducer.reduce(snapshot, UiEvent.UpsertCard("call-late", UiCardKind.Tool, "Run test", "late output", "running", false, ""))
        @Expect(snapshot.cards[0].state, "completed")
        @Expect(snapshot.cards[0].toolOutput.contains("late output"))
    }

    @TestCase
    func registryUsesDifferentStructuredRenderers(): Unit {
        let shell = UiCard("shell", UiCardKind.Tool, "Run cargo test", "", state: "running")
        shell.toolName = "bash"
        let http = UiCard("http", UiCardKind.Tool, "GET https://example.test", "", state: "running")
        http.toolName = "http"
        let read = UiCard("read", UiCardKind.Tool, "Read src/TypeInfo.cj", "", state: "completed")
        read.toolName = "read"
        let search = UiCard("search", UiCardKind.Tool, "Search TypeInfo in src", "", state: "completed")
        search.toolName = "grep"
        let edit = UiCard("edit", UiCardKind.Tool, "Edit src/TypeInfo.cj", "", state: "completed")
        edit.toolName = "edit"
        @Expect(agentCardRendererKind(shell), AgentCardRendererKind.Shell)
        @Expect(agentCardRendererKind(http), AgentCardRendererKind.Http)
        @Expect(agentCardRendererKind(read), AgentCardRendererKind.Read)
        @Expect(agentCardRendererKind(search), AgentCardRendererKind.Search)
        @Expect(agentCardRendererKind(edit), AgentCardRendererKind.Edit)
    }

    @TestCase
    func rendererRegistryDescriptorsAreCompleteAndUnambiguous(): Unit {
        let registry = agentCardRendererRegistry()
        @Expect(registry.size, 20)
        @Expect(registry[registry.size - 1].renderer, AgentCardRendererKind.Generic)

        for (index in 0..registry.size) {
            let descriptor = registry[index]
            @Expect(descriptor.fixture.key != "")
            @Expect(uiCardKindName(descriptor.fixture.semanticKind) != "")
            @Expect(descriptor.fixture.title != "")
            @Expect(descriptor.fixture.semanticNeedle != "")
            @Expect(descriptor.lifecycleStates.size > 0)
            for (otherIndex in (index + 1)..registry.size) {
                let other = registry[otherIndex]
                @Expect(descriptor.fixture.key != other.fixture.key)
                @Expect(descriptor.renderer != other.renderer)
                for (alias in descriptor.toolAliases) {
                    @Expect(!stringArrayContains(other.toolAliases, alias))
                }
                for (semanticKind in descriptor.semanticKinds) {
                    for (otherKind in other.semanticKinds) {
                        @Expect(semanticKind != otherKind)
                    }
                }
            }
        }
    }

    @TestCase
    func rendererRegistryLookupPreservesLegacyPrecedenceAndAliases(): Unit {
        let cases = [
            (UiCardKind.Approval, "", "Git failed", AgentCardRendererKind.Permission),
            (UiCardKind.Ask, "", "Run question", AgentCardRendererKind.Ask),
            (UiCardKind.Plan, "", "Background plan", AgentCardRendererKind.Plan),
            (UiCardKind.Subagent, "", "Error in child", AgentCardRendererKind.Subagent),
            (UiCardKind.Advisor, "", "Advisor review", AgentCardRendererKind.Advisor),
            (UiCardKind.Job, "", "Background task", AgentCardRendererKind.Job),
            (UiCardKind.Error, "", "Run command", AgentCardRendererKind.Error),
            (UiCardKind.Warning, "", "Warning", AgentCardRendererKind.Warning),
            (UiCardKind.Compaction, "", "Compaction", AgentCardRendererKind.Compaction),
            (UiCardKind.Summary, "", "Summary", AgentCardRendererKind.Summary),
            (UiCardKind.Tool, "github", "Repository", AgentCardRendererKind.Git),
            (UiCardKind.Tool, "fixture::lookup", "Fixture", AgentCardRendererKind.Mcp),
            (UiCardKind.Tool, "web_fetch", "Fetch", AgentCardRendererKind.Http),
            (UiCardKind.Tool, "persistent_bash", "Command", AgentCardRendererKind.Shell),
            (UiCardKind.Tool, "", "Read src/a.cj", AgentCardRendererKind.Read),
            (UiCardKind.Tool, "repo_search", "Lookup", AgentCardRendererKind.Search),
            (UiCardKind.Tool, "list", "Files", AgentCardRendererKind.List),
            (UiCardKind.Tool, "edit", "Patch", AgentCardRendererKind.Edit),
            (UiCardKind.Tool, "create", "File", AgentCardRendererKind.Create),
            (UiCardKind.Tool, "custom", "Custom", AgentCardRendererKind.Generic)
        ]
        for ((kind, tool, title, expected) in cases) {
            let card = UiCard("lookup-" + agentCardRendererName(expected), kind, title, "", state: "completed")
            card.toolName = tool
            @Expect(agentCardRendererKind(card), expected)
        }
    }

    @TestCase
    func specializedSystemCardsKeepInteractionSignals(): Unit {
        let theme = monoTheme()
        let ask = UiCard(
            "ask",
            UiCardKind.Ask,
            "Choose strategy",
            "Which strategy?\n› 1. Shared renderer\n  2. Separate renderer",
            state: "awaiting"
        )
        let askText = documentText(agentCardBodyDocument(ask, 80, theme))
        @Expect(askText.contains("› 1. Shared renderer"))

        var longAskBody = "Which project shape?"
        for (index in 0..14) {
            longAskBody += "\nchoice line " + index.toString()
        }
        let longAsk = UiCard(
            "long-ask",
            UiCardKind.Ask,
            "Choose project shape",
            longAskBody,
            state: "awaiting"
        )
        let longAskText = documentText(agentCardBodyDocument(longAsk, 80, theme))
        @Expect(longAskText.contains("choice line 6"))
        @Expect(!longAskText.contains("lines hidden"))

        let permission = UiCard(
            "permission",
            UiCardKind.Permission,
            "Permission required",
            "HIGH RISK · ProcessSpawn\nTarget  /tmp/build\n$ rm -rf /tmp/build",
            state: "awaiting"
        )
        let permissionText = documentText(agentCardBodyDocument(permission, 80, theme))
        @Expect(permissionText.contains("HIGH RISK"))
        @Expect(permissionText.contains("$ rm -rf /tmp/build"))

        let subagent = UiCard(
            "subagent",
            UiCardKind.Subagent,
            "Subagent · review",
            "running · 1.2 s\nInspecting cache ownership",
            state: "running"
        )
        let subagentText = documentText(agentCardBodyDocument(subagent, 80, theme))
        @Expect(subagentText.contains("current"))
        @Expect(subagentText.contains("Inspecting cache ownership"))

        let warning = UiCard(
            "warning",
            UiCardKind.Warning,
            "Context usage is high",
            "924K / 1.1M tokens used",
            state: "warning"
        )
        @Expect(documentText(agentCardBodyDocument(warning, 80, theme)).contains("924K"))
    }

    @TestCase
    func httpSearchListAndMultiFileDiffUseStructuredBodies(): Unit {
        let theme = monoTheme()
        let http = UiCard("http", UiCardKind.Tool, "GET example.test", "", state: "completed")
        http.toolName = "http"
        http.toolArguments = "{\"method\":\"GET\",\"url\":\"https://example.test\"}"
        http.toolOutput = "{\"status\":200,\"body\":\"ok\"}"
        let httpText = documentText(agentCardBodyDocument(http, 80, theme))
        @Expect(httpText.contains("GET https://example.test"))
        @Expect(httpText.contains("200"))
        @Expect(httpText.contains("ok"))

        let search = UiCard("search", UiCardKind.Tool, "Search TypeInfo", "", state: "completed")
        search.toolName = "grep"
        search.toolArguments = "{\"pattern\":\"TypeInfo\",\"path\":\"runtime/\"}"
        search.toolOutput = "src/TypeInfo.cj:84:TypeInfo.get(type)\nsrc/EnumInfo.cj:126:return TypeInfo.get(type)"
        let searchDocument = agentCardBodyDocument(search, 80, theme)
        let searchText = documentText(searchDocument)
        @Expect(searchText.contains("src/TypeInfo.cj:84"))
        @Expect(searchText.contains("src/EnumInfo.cj:126"))
        @Expect(searchText.contains("return TypeInfo.get(type)"))
        @Expect(searchDocument.lines[searchDocument.lines.size - 1].spans.size > 1)

        let list = UiCard("list", UiCardKind.Tool, "List src", "", state: "completed")
        list.toolName = "glob"
        list.toolArguments = "{\"path\":\"src\"}"
        list.toolOutput = "[dir] runtime\nTypeInfo.cj"
        @Expect(documentText(agentCardBodyDocument(list, 80, theme)).contains("runtime/"))

        let edit = UiCard("edit", UiCardKind.Tool, "Edit files", "", state: "completed")
        edit.toolName = "edit"
        edit.toolOutput = "diff --git a/a.cj b/a.cj\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/b.cj b/b.cj\n@@ -1 +1 @@\n-before\n+after"
        let diffText = documentText(agentCardBodyDocument(edit, 100, theme))
        @Expect(diffText.contains("file  a.cj"))
        @Expect(diffText.contains("file  b.cj"))
        @Expect(diffText.contains("-old"))
        @Expect(diffText.contains("+after"))
    }

    @TestCase
    func widthsStayGraphemeSafeForCjkEmojiAndCombiningText(): Unit {
        let item = UiCard(
            "read",
            UiCardKind.Tool,
            "Read src/很长的路径/runtime/TypeInfo👩‍💻.cj",
            "completed",
            state: "completed"
        )
        item.toolName = "read"
        let budgetValues: Array<Int64> = [40, 60, 80, 120, 160]
        for (budget in budgetValues) {
            let title = fitAgentCardTitle(item.title, budget, true)
            @Expect(displayWidth(title) <= budget)
        }
        let combining = fitAgentCardTitle("Read e\u{301}/中文/emoji🙂", 12, true)
        @Expect(displayWidth(combining) <= 12)
    }

    @TestCase
    func colorLevelsKeepStateReadableWhenCapabilitiesDrop(): Unit {
        let rgb = Color.Rgb(254, 188, 56)
        match (productColor(rgb, 24)) {
            case Color.Rgb(red, green, blue) => @Expect(red == 254u8 && green == 188u8 && blue == 56u8)
            case _ => @Fail("true-color mode must preserve RGB")
        }
        match (productColor(rgb, 256)) {
            case Color.Indexed(_) => ()
            case _ => @Fail("256-color fallback must use an indexed color")
        }
        match (productColor(rgb, 16)) {
            case Color.Rgb(_, _, _) => @Fail("16-color fallback must not keep RGB")
            case _ => ()
        }
        match (productColor(rgb, 0)) {
            case Color.Reset => ()
            case _ => @Fail("no-color mode must reset styles")
        }
        match (themeColor("#123456")) {
            case Color.Rgb(red, green, blue) => @Expect(red == 18u8 && green == 52u8 && blue == 86u8)
            case _ => @Fail("hex theme color must parse as RGB")
        }
        match (themeColor("244")) {
            case Color.Indexed(value) => @Expect(value == 244u8)
            case _ => @Fail("indexed theme color must parse as an index")
        }
    }

    @TestCase
    func shellReadAndDiffBodiesKeepTerminalStructure(): Unit {
        let theme = monoTheme()
        let shell = UiCard("shell", UiCardKind.Tool, "Run cargo test", "", state: "completed")
        shell.toolName = "bash"
        shell.toolArguments = "{\"command\":\"cargo test\",\"cwd\":\"/workspace\"}"
        shell.toolOutput = "test result: ok\n[1/1] done"
        let shellDocument = agentCardBodyDocument(shell, 80, theme)
        @Expect(documentText(shellDocument).contains("$"))
        @Expect(documentText(shellDocument).contains("test result: ok"))

        let read = UiCard("read", UiCardKind.Tool, "Read src/a.cj", "", state: "completed")
        read.toolName = "read"
        read.toolArguments = "{\"path\":\"src/a.cj\",\"start_line\":\"42\"}"
        read.toolOutput = "line one\nline two"
        @Expect(documentText(agentCardBodyDocument(read, 80, theme)).contains("42"))

        let edit = UiCard("edit", UiCardKind.Tool, "Edit src/a.cj", "", state: "completed")
        edit.toolName = "edit"
        edit.toolOutput = "@@ -1 +1 @@\n-old\n+new"
        let diff = agentCardBodyDocument(edit, 80, theme)
        @Expect(documentText(diff).contains("@@ -1 +1 @@"))
        @Expect(documentText(diff).contains("-old"))
        @Expect(documentText(diff).contains("+new"))
    }

    @TestCase
    func runningShellDoesNotRenderInvocationPreviewAsOutput(): Unit {
        let theme = monoTheme()
        let shell = UiCard(
            "shell-running",
            UiCardKind.Tool,
            "Run find . -type f",
            "command\nfind . -type f",
            state: "running"
        )
        shell.toolName = "bash"
        shell.toolArguments = "{\"command\":\"find . -type f\"}"
        let text = documentText(agentCardBodyDocument(shell, 80, theme))
        @Expect(text.contains("$"))
        @Expect(text.contains("find . -type f"))
        @Expect(!text.contains("Output"))
        @Expect(!text.contains("output\nfind . -type f"))
    }

    @TestCase
    func shellOutputSectionRequiresAVisibleTerminalCell(): Unit {
        let theme = axyndraTheme()
        for ((command, value) in [
            ("true", ""),
            ("mkdir -p /tmp/axyndra-ui-test", ""),
            ("touch /tmp/axyndra-ui-test/a", ""),
            ("printf '\\n'", "\n"),
            ("printf '   '", "   "),
            ("printf '\\033[0m'", "\u{1B}[0m"),
            ("printf ansi-only", "\u{1B}[31m\u{1B}[0m")
        ]) {
            let shell = UiCard("shell-empty", UiCardKind.Tool, "Run true", "", state: "running")
            shell.toolName = "bash"
            shell.toolArguments = "{\"command\":\"" + command.replace("\"", "\\\"") + "\"}"
            shell.toolOutput = value
            @Expect(!documentText(agentCardBodyDocument(shell, 80, theme)).contains("Output"))
        }

        let shell = UiCard("shell-visible", UiCardKind.Tool, "Run build", "", state: "running")
        shell.toolName = "bash"
        shell.toolArguments = "{\"command\":\"cmake --build build\"}"
        shell.toolOutput = " \n\u{1B}[32mcompiling...\u{1B}[0m"
        let document = agentCardBodyDocument(shell, 80, theme)
        @Expect(documentText(document).contains("Output"))
        @Expect(documentText(document).contains("compiling..."))
    }

    @TestCase
    func ansiResetRestoresMutedToolOutputStyle(): Unit {
        let theme = axyndraTheme()
        let output = styledToolOutput("\u{1B}[31merror\u{1B}[0m plain", theme)
        @Expect(output.visible)
        @Expect(output.lines.size, 1)
        @Expect(output.lines[0].spans.size >= 2)
        @Expect(
            output.lines[0].spans[output.lines[0].spans.size - 1].style ==
                Style(fg: theme.toolOutput, bg: theme.background)
        )
        @Expect(documentText(Document(output.lines)).contains("error plain"))
    }

    @TestCase
    func shellCommandAndSectionStylesStayRestrained(): Unit {
        let theme = axyndraTheme()
        let command = "ssh Server 'grep -n \"replace\" /home/chenqian/run.py | head -10'"
        let spans = shellCommandSpans(command, theme)
        var blue = ""
        var green = ""
        for (span in spans) {
            @Expect(!span.style.modifier.bold)
            if (span.style == Style(fg: theme.toolExecutable, bg: theme.background)) { blue += span.text }
            if (span.style == Style(fg: theme.toolPath, bg: theme.background)) { green += span.text }
        }
        @Expect(blue, "ssh")
        @Expect(green.contains("/home/chenqian/run.py"))
        @Expect(!green.contains("grep"))
        @Expect(!green.contains("head"))

        let shell = UiCard("shell-style", UiCardKind.Tool, "Run remote query", "", state: "completed")
        shell.toolName = "bash"
        shell.toolArguments = "{\"command\":\"" + command.replace("\"", "\\\"") + "\"}"
        shell.toolOutput = "result"
        let document = agentCardBodyDocument(shell, 80, theme)
        @Expect(document.lines.size >= 3)
        @Expect(document.lines[1].spans[0].style == Style(fg: theme.toolPrompt, bg: theme.background))
    }

    @TestCase
    func shellOutputTrimsOnlyTrailingSeparationRows(): Unit {
        let theme = axyndraTheme()
        let output = styledToolOutput("line one\n\nline three\n\n   \n\u{1B}[0m", theme)
        @Expect(output.visible)
        @Expect(output.lines.size, 3)
        @Expect(toolLineHasVisibleCell(output.lines[0]))
        @Expect(!toolLineHasVisibleCell(output.lines[1]))
        @Expect(toolLineHasVisibleCell(output.lines[2]))

        let shell = UiCard("shell-spacing", UiCardKind.Tool, "Run printf", "", state: "completed")
        shell.toolName = "bash"
        shell.toolArguments = "{\"command\":\"printf result\"}"
        shell.toolOutput = "result\n\n\n"
        let document = agentCardBodyDocument(shell, 80, theme)
        @Expect(document.lines.size, 4)
        @Expect(toolLineHasVisibleCell(document.lines[2]))
        @Expect(!toolLineHasVisibleCell(document.lines[3]))
    }

    @TestCase
    func streamingShellAddsOutputOnlyAfterVisibleCells(): Unit {
        let theme = axyndraTheme()
        let snapshot = UiSnapshot()
        let shell = UiCard("shell-stream", UiCardKind.Tool, "Run build", "", state: "running")
        shell.toolName = "bash"
        shell.toolArguments = "{\"command\":\"cmake --build build -j16\"}"
        shell.toolElapsedMillis = 2300
        snapshot.cards.add(shell)
        let source = AgentTranscriptSource(snapshot, {
            item, width, _ => agentCardBodyDocument(item, width, theme)
        })
        source.setTheme(theme)
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        view.setUnicode(true)
        let backend = TestBackend(area: Rect(0, 0, 80, 12))
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw({frame => frame.renderWidget(view, frame.area)})
        let initial = backend.snapshot()
        @Expect(initial.contains("Running"))
        @Expect(!initial.contains("Output"))
        @Expect(countText(initial, "╭"), 1)
        @Expect(countText(initial, "╰"), 1)

        UiReducer.reduce(snapshot, UiEvent.AppendToolOutput(shell.id, " \n\u{1B}[0m"))
        _ = terminal.draw({frame => frame.renderWidget(view, frame.area)})
        let whitespace = backend.snapshot()
        @Expect(whitespace.contains("Running"))
        @Expect(!whitespace.contains("Output"))

        UiReducer.reduce(snapshot, UiEvent.AppendToolOutput(shell.id, "compiling...\n"))
        _ = terminal.draw({frame => frame.renderWidget(view, frame.area)})
        let visible = backend.snapshot()
        @Expect(visible.contains("Output"))
        @Expect(visible.contains("compiling..."))
        @Expect(visible.contains("Running"))
        @Expect(countText(visible, "╭"), 1)
        @Expect(countText(visible, "╰"), 1)
    }

    @TestCase
    func userAssistantAndCompactToolKeepTheirVisualHierarchy(): Unit {
        let theme = axyndraTheme()
        let user = UiCard(
            "user-style",
            UiCardKind.User,
            "You",
            "这些失败原因中哪些是标准库实现导致的",
            state: "completed"
        )
        let backend = transcriptCardBackend(user, 80, 8, theme)
        match (backend.lastBuffer()) {
            case Some(buffer) =>
                for (x in 0..80) {
                    @Expect(buffer.getCell(x, 0).style == Style(bg: theme.userMessageBg))
                    @Expect(buffer.getCell(x, 2).style == Style(bg: theme.userMessageBg))
                }
                @Expect(buffer.getCell(2, 1).symbol, "这")
                @Expect(
                    buffer.getCell(2, 1).style ==
                        Style(fg: theme.userMessageText, bg: theme.userMessageBg)
                )
                @Expect(buffer.getCell(0, 0).symbol, " ")
                @Expect(buffer.getCell(79, 2).symbol, " ")
                @Expect(buffer.getCell(0, 1).style == Style(bg: theme.userMessageBg))
                @Expect(buffer.getCell(1, 1).style == Style(bg: theme.userMessageBg))
                @Expect(buffer.getCell(79, 1).style == Style(bg: theme.userMessageBg))
            case None => @Fail("user transcript must render a buffer")
        }
        let renderedUser = backend.snapshot()
        @Expect(!renderedUser.contains("User:"))
        @Expect(!renderedUser.contains("You:"))
        @Expect(!renderedUser.contains("╭"))
        @Expect(!renderedUser.contains("›"))

        let assistant = UiCard(
            "assistant-style",
            UiCardKind.Assistant,
            "Assistant",
            "我先检查失败列表和一个具体失败用例。",
            state: "completed"
        )
        let assistantSnapshot = transcriptCardBackend(assistant, 80, 6, theme).snapshot()
        @Expect(assistantSnapshot.contains("我"))
        @Expect(!assistantSnapshot.contains("╭"))
        @Expect(!assistantSnapshot.contains("Assistant:"))

        let glob = UiCard("glob-style", UiCardKind.Tool, "Tool · glob", "", state: "completed", collapsed: true, footer: "5 entries")
        glob.toolName = "glob"
        let compactTheme = productTranscriptCardTheme(theme, glob)
        @Expect(
            compactTheme.topTitleStyle ==
                Style(fg: theme.secondary, bg: theme.background, modifier: Modifier.none())
        )
        @Expect(compactTheme.mutedStyle == Style(fg: theme.toolMetadata, bg: theme.background))
        @Expect(summarizeToolCall("glob", "{}"), "glob")
        let globSnapshot = UiSnapshot()
        globSnapshot.cards.add(glob)
        let globSource = AgentTranscriptSource(globSnapshot, {_, _, _ => Document([])})
        @Expect(!globSource.itemTitleForWidth(0, 80).contains("Tool ·"))
        @Expect(globSource.itemTitleForWidth(0, 80).contains("glob · completed"))
    }

    @TestCase
    func outputWindowPreservesHeadAndTail(): Unit {
        var output = ""
        for (index in 0..80) {
            if (output != "") {
                output += "\n"
            }
            output += "line " + index.toString()
        }
        let window = limitToolDetail(output, 0)
        @Expect(window.contains("line 0"))
        @Expect(window.contains("line 79"))
        @Expect(window.contains("lines hidden"))
        @Expect(!window.contains("line 20"))

        let theme = axyndraTheme()
        let card = UiCard("shell-window", UiCardKind.Tool, "Run many lines", "", state: "completed", collapsed: true)
        let styled = styledToolOutput(output, theme)
        let styledWindow = limitedStyledOutput(card, styled, theme)
        var hiddenStyle = Style.default()
        var foundHidden = false
        for (line in styledWindow) {
            for (span in line.spans where span.text.contains("lines hidden")) {
                hiddenStyle = span.style
                foundHidden = true
            }
        }
        @Expect(foundHidden)
        @Expect(hiddenStyle == Style(fg: theme.toolMetadata, bg: theme.background))
    }

    @TestCase
    func sensitiveFieldsAreNotEchoedByFallbackCards(): Unit {
        let safe = redactSensitiveText("{\"token\":\"do-not-show\",\"ok\":true}")
        @Expect(!safe.contains("do-not-show"))
        @Expect(safe.contains("[REDACTED]"))
        let repeated = redactSensitiveText("{\"token\":\"first-secret\",\"nested\":{\"token\":\"second-secret\"}}")
        @Expect(!repeated.contains("first-secret"))
        @Expect(!repeated.contains("second-secret"))
        let headers = redactSensitiveText(
            "Authorization: Bearer visible\nX-Api-Key: key-value\nhttps://name:password@example.test\nsk-live-secret\nghp_private")
        @Expect(!headers.contains("visible"))
        @Expect(!headers.contains("key-value"))
        @Expect(!headers.contains("password"))
        @Expect(!headers.contains("sk-live-secret"))
        @Expect(!headers.contains("ghp_private"))
    }

    @TestCase
    func specializedCardFieldsUseTheSharedRedactor(): Unit {
        let search = UiCard("search-secret", UiCardKind.Tool, "Search", "", state: "completed")
        search.toolName = "grep"
        search.toolArguments = "{\"pattern\":\"sk-live-search-secret\",\"path\":\"src\"}"
        let searchText = documentText(agentCardBodyDocument(search, 80, monoTheme()))
        @Expect(searchText.contains("[REDACTED]"))
        @Expect(!searchText.contains("sk-live-search-secret"))
        let searchTitle = summarizeToolCall("grep", search.toolArguments)
        @Expect(searchTitle.contains("[REDACTED]"))
        @Expect(!searchTitle.contains("sk-live-search-secret"))

        let mcp = UiCard("mcp-secret", UiCardKind.Mcp, "MCP", "", state: "completed")
        mcp.toolName = "mcp::read"
        mcp.toolArguments = "{\"server\":\"github\",\"resource\":\"https://name:password@example.test/item\"}"
        let mcpText = documentText(agentCardBodyDocument(mcp, 80, monoTheme()))
        @Expect(mcpText.contains("[REDACTED]@example.test/item"))
        @Expect(!mcpText.contains("password"))
    }

    @TestCase
    func diffStatsAndPermissionPreviewKeepRequiredSignals(): Unit {
        let title = toolTitleWithStats(
            "edit",
            "{\"path\":\"src/a.cj\"}",
            "@@ -1 +1 @@\n-old\n+new"
        )
        @Expect(title.contains("+1"))
        @Expect(title.contains("−1"))
        let command = "rm -rf /tmp/cangjie-build/" + repeatString("nested/", 40)
        let approval = approvalCardBody(
            "bash",
            "workspace.execute",
            "/tmp/cangjie-build",
            "high",
            "Command deletes files",
            "{\"command\":\"" + command + "\"}"
        )
        @Expect(approval.contains(command))
        @Expect(approval.contains("Reason  Command deletes files"))
        let reviewed = approvalCardBody(
            "bash",
            "process.spawn",
            "",
            "high",
            "Remote history may be rewritten",
            "{\"command\":\"git push --force origin main\"}\n\n" + "AI Reviewer\nRisk      high\nReviewer  fixture\n" +
                "Reason    explicit user confirmation required"
        )
        @Expect(reviewed.contains("AI Reviewer"))
        @Expect(reviewed.contains("explicit user confirmation required"))
    }

    @TestCase
    func writeApprovalUsesBoundedHumanReadableSummary(): Unit {
        var preview = "Path    /tmp/cube_lib/cube_model.js\nAction  Create file\nSize    7.4 KiB · 183 lines\nType    JavaScript\n\nPreview"
        for (index in 0..6) {
            preview += "\nline " + index.toString()
        }
        preview += "\n… content truncated …"
        let body = approvalCardBody(
            "write",
            "temp.write",
            "/tmp/cube_lib/cube_model.js",
            "medium",
            "Target is in a system temporary directory outside the current workspace",
            preview
        )
        @Expect(body.contains("MEDIUM RISK · temp.write"))
        @Expect(body.contains("Action  Create file"))
        @Expect(body.contains("183 lines"))
        @Expect(body.contains("outside the current workspace"))
        @Expect(!body.contains("{\"path\""))
        @Expect(!body.contains("\\n"))
    }

    @TestCase
    func unknownToolsAreBoundedAndRedacted(): Unit {
        let item = UiCard("unknown", UiCardKind.Tool, "Tool · custom_tool", "", state: "completed")
        item.toolName = "custom_tool"
        let large = "{\"token\":\"secret-token\",\"items\":\"" + repeatString("x", 6000) + "\"}"
        item.toolArguments = large
        let text = documentText(agentCardBodyDocument(item, 80, monoTheme()))
        @Expect(text.contains("Generic tool view"))
        @Expect(text.contains("[REDACTED]"))
        @Expect(!text.contains("secret-token"))
        @Expect(text.size < 4300)
        @Expect(text.contains("truncated"))
    }

    @TestCase
    func gitMcpAdvisorAndJobHaveDedicatedRenderers(): Unit {
        let git = UiCard("git", UiCardKind.Tool, "Git status", "", state: "completed")
        git.toolName = "git"
        let mcp = UiCard("mcp", UiCardKind.Mcp, "MCP · GitHub", "", state: "completed")
        mcp.toolName = "mcp::create_issue"
        let advisor = UiCard("advisor", UiCardKind.Advisor, "Advisor · review", "unsafe prefix match", state: "completed")
        let job = UiCard("job", UiCardKind.Job, "Background task", "running", state: "running")
        @Expect(agentCardRendererKind(git), AgentCardRendererKind.Git)
        @Expect(agentCardRendererKind(mcp), AgentCardRendererKind.Mcp)
        @Expect(agentCardRendererKind(advisor), AgentCardRendererKind.Advisor)
        @Expect(agentCardRendererKind(job), AgentCardRendererKind.Job)
    }

    @TestCase
    func completeCardGalleryCoversRegistryLifecycleAndWidthBoundaries(): Unit {
        let fixtures = transcriptGalleryFixtures()
        let coveredRenderers = ArrayList<String>()
        let coveredStates = ArrayList<String>()
        var userCount: Int64 = 0
        var assistantCount: Int64 = 0

        for (fixture in fixtures) {
            if (fixture.conversationRole == "user") {
                userCount++
            } else if (fixture.conversationRole == "assistant") {
                assistantCount++
            } else {
                let renderer = agentCardRendererName(fixture.renderer)
                if (!stringArrayContains(coveredRenderers.toArray(), renderer)) {
                    coveredRenderers.add(renderer)
                }
                let actual = agentCardRendererKind(galleryCard(fixture.tool, fixture.state, true))
                @Expect(actual, fixture.renderer)
            }
            if (!stringArrayContains(coveredStates.toArray(), fixture.state)) {
                coveredStates.add(fixture.state)
            }

            let semantic = renderTranscriptGallery(
                tool: fixture.tool,
                state: fixture.state,
                width: 240,
                expanded: true,
                plain: true
            )
            if (!semantic.contains(fixture.semanticNeedle)) {
                @FailExpect(
                    "gallery fixture " + fixture.key() + " is missing semantic text: " + fixture.semanticNeedle
                )
            }
            @Expect(!semantic.contains("gallery-secret"))
            @Expect(!semantic.contains("\u{1B}["))

            let coloredSemantic = renderTranscriptGallery(
                tool: fixture.tool,
                state: fixture.state,
                width: 240,
                expanded: true
            )
            @Expect(stripAnsi(coloredSemantic), semantic)

            for (width in [24]) {
                let rendered = renderTranscriptGallery(
                    tool: fixture.tool,
                    state: fixture.state,
                    width: width,
                    expanded: true
                )
                @Expect(rendered != "")
                @Expect(!rendered.contains("gallery-secret"))
                for (line in rendered.split("\n")) {
                    @Expect(displayWidth(stripAnsi(line)) <= width)
                }
            }
        }

        @Expect(userCount, 1)
        @Expect(assistantCount, 1)
        for (descriptor in agentCardRendererRegistry()) {
            if (descriptor.renderer != AgentCardRendererKind.Generic) {
                @Expect(stringArrayContains(coveredRenderers.toArray(), agentCardRendererName(descriptor.renderer)))
            }
        }
        for (state in [
            "pending",
            "queued",
            "running",
            "streaming",
            "awaiting_user",
            "completed",
            "failed",
            "denied",
            "cancelled",
            "timed_out",
            "expired"
        ]) {
            @Expect(stringArrayContains(coveredStates.toArray(), state))
        }

        let approval = renderTranscriptGallery(tool: "approval", width: 80, expanded: true)
        @Expect(approval.contains("temp.write"))
        @Expect(approval.contains("Target is outside the current workspace"))
        @Expect(approval.contains("/tmp/cube_lib/cube_model.js"))
        @Expect(approval.contains("7.4 KiB · 183 lines"))
        @Expect(approval.contains("Awaiting your decision"))

        let longShell = renderTranscriptGallery(
            tool: "bash_long",
            state: "completed",
            width: 40,
            expanded: true
        )
        @Expect(stripAnsi(longShell).startsWith("╭"))
        @Expect(longShell.contains("$ ssh"))
        @Expect(longShell.contains("Output"))
        @Expect(longShell.contains("Exit: 0"))
        let emptyShell = renderTranscriptGallery(
            tool: "bash_no_output",
            state: "completed",
            width: 80,
            expanded: true
        )
        @Expect(stripAnsi(emptyShell).startsWith("╭"))
        @Expect(!emptyShell.contains("Output"))
        @Expect(emptyShell.contains("Exit: 0"))
    }

    @TestCase
    func coloredAndPlainGalleryShareTextWhileOnlyColoredUsesAnsi(): Unit {
        let colored = renderTranscriptGallery(
            tool: "bash",
            state: "failed",
            width: 100,
            expanded: true
        )
        let plain = renderTranscriptGallery(
            tool: "bash",
            state: "failed",
            width: 100,
            expanded: true,
            plain: true
        )
        @Expect(colored.contains("\u{1B}["))
        @Expect(colored.contains("\u{1B}[0;3") || colored.contains("\u{1B}[0;4"))
        @Expect(!plain.contains("\u{1B}["))
        @Expect(stripAnsi(colored), plain)
        for (line in colored.split("\n")) {
            @Expect(line.endsWith("\u{1B}[0m"))
        }
    }

    @TestCase
    func terminalStatesDoNotRegressToRunning(): Unit {
        let timedOut = UiCard("timeout", UiCardKind.Tool, "Run command", "", state: "timed_out")
        let denied = UiCard("denied", UiCardKind.Approval, "Approval", "", state: "denied")
        let awaiting = UiCard("awaiting", UiCardKind.Approval, "Approval", "", state: "awaiting_user")
        @Expect(isTranscriptStatus(productTranscriptStatus(timedOut), "timed_out"))
        @Expect(isTranscriptStatus(productTranscriptStatus(denied), "rejected"))
        @Expect(isTranscriptStatus(productTranscriptStatus(awaiting), "awaiting"))
    }

    @TestCase
    func lifecycleLabelsAndSemanticStylesDistinguishEveryStateClass(): Unit {
        let labels = [
            ("pending", "pending"),
            ("queued", "queued"),
            ("running", "running"),
            ("streaming", "streaming"),
            ("awaiting_user", "Awaiting your decision"),
            ("completed", "completed"),
            ("failed", "failed"),
            ("denied", "denied"),
            ("cancelled", "cancelled"),
            ("timed_out", "timed out"),
            ("expired", "expired")
        ]
        for ((state, label) in labels) {
            @Expect(readableCardState(state), label)
        }

        let theme = axyndraTheme()
        for ((state, foreground) in [
            ("pending", theme.text),
            ("queued", theme.text),
            ("running", theme.accent),
            ("streaming", theme.accent),
            ("awaiting_user", theme.warning),
            ("completed", theme.success),
            ("failed", theme.danger),
            ("denied", theme.warning),
            ("cancelled", theme.text),
            ("timed_out", theme.danger),
            ("expired", theme.warning)
        ]) {
            let card = UiCard("style-" + state, UiCardKind.Approval, "Approval", "fixture", state: state)
            let cardTheme = productTranscriptCardTheme(theme, card)
            @Expect(
                cardTheme.topTitleStyle ==
                    Style(fg: foreground, bg: theme.background, modifier: Modifier.strong())
            )
        }
    }

    @TestCase
    func transcriptInternalScrollReturnsToFollowBottom(): Unit {
        let state = VirtualTranscriptState()
        state.scrollBy(8, 40, 10)
        @Expect(!state.followBottom)
        @Expect(state.scrollTop, 8)
        state.end(40, 10)
        @Expect(state.followBottom)
        @Expect(state.scrollTop, 30)
    }

    @TestCase
    func fiveHundredFoldedCardsRemainSmallInState(): Unit {
        let snapshot = UiSnapshot()
        for (index in 0..500) {
            UiReducer.reduce(
                snapshot,
                UiEvent.UpsertCard(
                    "tool-" + index.toString(),
                    UiCardKind.Tool,
                    "Read src/" + index.toString() + ".cj",
                    "completed",
                    "completed",
                    true,
                    ""
                )
        )
    }

        @Expect(snapshot.cards.size, 500)
        @Expect(snapshot.cards[499].collapsed)
    }

    @TestCase
    func xtermPaletteKeepsUserStripDistinctFromTranscriptBackground(): Unit {
        let theme = axyndraTheme()
        let transcript = match (theme.background) {
            case Color.Rgb(red, green, blue) => productRgbTo256(red, green, blue)
            case _ => UInt8(0)
        }
        let user = match (theme.userMessageBg) {
            case Color.Rgb(red, green, blue) => productRgbTo256(red, green, blue)
            case _ => UInt8(0)
        }

        @Expect(transcript, UInt8(235))
        @Expect(user, UInt8(234))
        @Expect(transcript != user)
    }

    @TestCase
    func runningNoOutputGalleryKeepsWideMetadataInsideBothBorders(): Unit {
        let rendered = renderTranscriptGallery(
            tool: "bash_no_output",
            state: "running",
            width: 80,
            expanded: true
        )
        let lines = rendered.split("\n")

        @Expect(lines.size, 4)
        for (line in lines) {
            @Expect(displayWidth(stripAnsi(line)), 80)
        }
        @Expect(stripAnsi(lines[1]).startsWith("│"))
        @Expect(stripAnsi(lines[1]).endsWith("│"))
        @Expect(stripAnsi(lines[2]).startsWith("│"))
        @Expect(stripAnsi(lines[2]).endsWith("│"))
        @Expect(!rendered.contains("Output"))
    }
}

func documentText(document: Document): String {
    var text = ""
    for (line in document.lines) {
        if (text != "") {
            text += "\n"
        }
        for (span in line.spans) {
            text += span.text
        }
    }
    text
}

func transcriptCardBackend(card: UiCard, width: Int64, height: Int64, theme: ProductTheme): TestBackend {
    let snapshot = UiSnapshot()
    snapshot.cards.add(card)
    let source = AgentTranscriptSource(snapshot, {
        item, documentWidth, _ => if (item.kind == UiCardKind.User || item.kind == UiCardKind.Assistant || item.kind == UiCardKind.Reasoning) {
            markdownDocument(
                item.body,
                theme: productMarkdownTheme(theme, kind: item.kind),
                preserveSoftBreaks: item.kind == UiCardKind.User
            )
        } else {
            agentCardBodyDocument(item, documentWidth, theme)
        }
    })
    source.setTheme(theme)
    let view = VirtualTranscriptView(source)
    view.setCardChrome(true)
    view.setUnicode(true)
    let backend = TestBackend(area: Rect(0, 0, width, height))
    let terminal = Terminal(backend, renderMode: RenderMode.Full)
    _ = terminal.draw({frame => frame.renderWidget(view, frame.area)})
    backend
}

func countText(value: String, needle: String): Int64 {
    if (needle == "") { return 0 }
    var count: Int64 = 0
    var offset: Int64 = 0
    while (offset < value.size) {
        match (value[offset..].indexOf(needle)) {
            case Some(relative) =>
                count++
                offset += relative + needle.size
            case None => break
        }
    }
    count
}

func isTranscriptStatus(status: TranscriptItemStatus, expected: String): Bool {
    match (status) {
        case TranscriptItemStatus.Pending => expected == "pending"
        case TranscriptItemStatus.Queued => expected == "queued"
        case TranscriptItemStatus.Running => expected == "running"
        case TranscriptItemStatus.Streaming => expected == "streaming"
        case TranscriptItemStatus.Done => expected == "done"
        case TranscriptItemStatus.Approved => expected == "approved"
        case TranscriptItemStatus.Failed => expected == "failed"
        case TranscriptItemStatus.Cancelled => expected == "cancelled"
        case TranscriptItemStatus.Awaiting => expected == "awaiting"
        case TranscriptItemStatus.Rejected => expected == "rejected"
        case TranscriptItemStatus.TimedOut => expected == "timed_out"
        case TranscriptItemStatus.Expired => expected == "expired"
        case TranscriptItemStatus.Conflict => expected == "conflict"
    }
}
