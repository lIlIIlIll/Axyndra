package product_rpc_contract

import yjson_support.*

import yjson.*

import agent_cli.*
import agent_core.*
import agent_domain.*
import agent_product.*
import agent_rpc.*
import model_adapters.*
import std.collection.*
import std.env.*
import std.fs.*
import std.sync.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        let product = openProduct(
            config: ProductConfig(
                settingsRoot: root,
                stateRoot: root + "/sessions",
                workspaceRoot: root,
                fixture: true,
                approvalMode: ApprovalMode.Yolo,
                asyncEnabled: false
            )
        ).value().getOrThrow()
        let output = FrameCollector()
        let application = product.applicationSession()
        let server = ProductJsonlRpcServer(
            application,
            {frame => output.add(frame)}
        )
        expect(
            server.ready().contains("\"type\":\"ready\"") && server.ready().contains("\"maxFrameBytes\":1048576") &&
                server.ready().contains("\"supportedProtocolVersions\":[1,2]"),
            "RPC advertises its frame contract"
        )
        let approvalWire = productApprovalFrame(
            ApprovalRequest(
                OperationId("approval-1"),
                "call-1",
                "write",
                Capability(
                    CapabilityKind.WorkspaceWrite,
                    resource: "workspace/note.txt"
                ),
                preview: objectValue([ValueField("path", textValue("note.txt"))])
            )
        )
        expect(
            approvalWire.field("operationId").getOrThrow().text == "approval-1" &&
                approvalWire.field("callId").getOrThrow().text == "call-1" &&
                approvalWire.field("tool").getOrThrow().text == "write" &&
                approvalWire.field("capability").getOrThrow().text == "workspace.write" &&
                approvalWire.field("resource").getOrThrow().text == "workspace/note.txt" &&
                approvalWire.field("risk").getOrThrow().text == "medium" &&
                approvalWire.field("preview").getOrThrow().field("path").getOrThrow().text == "note.txt",
            "RPC approval frame exposes the shared structured preview"
        )
        let expectedCommands = [
            "negotiate_protocol",
            "prompt",
            "steer",
            "follow_up",
            "abort",
            "abort_and_prompt",
            "new_session",
            "get_state",
            "set_fast_mode",
            "get_available_commands",
            "set_todos",
            "set_host_tools",
            "set_host_uri_schemes",
            "set_subagent_subscription",
            "get_subagents",
            "get_subagent_messages",
            "set_model",
            "cycle_model",
            "get_available_models",
            "set_thinking_level",
            "cycle_thinking_level",
            "set_steering_mode",
            "set_follow_up_mode",
            "set_interrupt_mode",
            "compact",
            "set_auto_compaction",
            "set_auto_retry",
            "abort_retry",
            "bash",
            "abort_bash",
            "get_session_stats",
            "export_html",
            "switch_session",
            "branch",
            "get_branch_messages",
            "get_last_assistant_text",
            "set_session_name",
            "handoff",
            "get_messages",
            "get_messages_page",
            "get_login_providers",
            "login"
        ]
        expect(
            availableRpcCommands().size == expectedCommands.size && allCommandsPresent(expectedCommands),
            "RPC exports the pinned 42-command inventory"
        )
        let discovery = decodeAgentValue(
            server.handle(
                "{\"id\":\"commands\",\"type\":\"get_available_commands\"}"
            )
        ).value().getOrThrow().field("data").getOrThrow().field("commands").getOrThrow()
        expect(
            discovery.unifiedKind == ValueKind.List &&
                discovery.items.size == slashCommandDefinitions().size &&
                allSlashDescriptorsPresent(discovery.items) &&
                !hasSlashDescriptor(discovery.items, "negotiate_protocol"),
            "RPC discovers typed slash descriptors independently from its protocol inventory"
        )
        let helpDescriptor = slashDescriptor(discovery.items, "help").getOrThrow()
        expect(
            helpDescriptor.field("description").isSome() &&
                helpDescriptor.field("aliases").isNone() &&
                helpDescriptor.field("usage").isNone() &&
                helpDescriptor.field("input").isNone() &&
                helpDescriptor.field("subcommands").isNone(),
            "RPC omits absent optional fields for a no-argument slash command"
        )
        let todoDescriptor = slashDescriptor(discovery.items, "todo").getOrThrow()
        expect(
            todoDescriptor.field("usage").isNone() &&
                todoDescriptor.field("input").getOrThrow().field("hint").getOrThrow().text == "[subcommand]" &&
                todoDescriptor.field("subcommands").getOrThrow().items.size == 11,
            "RPC includes input and subcommand metadata when the slash command defines it"
        )
        let state = server.handle("{\"id\":\"s1\",\"type\":\"get_state\"}")
        expect(
            state.contains("\"command\":\"get_state\"") && state.contains("\"success\":true") && state.contains(
                "\"sessionRef\":") && state.contains("\"workMode\":\"none\"") && state.contains(
                "\"loopModeEnabled\":false") && state.contains("\"systemPrompt\":[]") && state.contains(
                "\"dumpTools\":[{\"name\":\"ast_grep\"") && state.contains(
                "\"contextUsage\":{\"tokens\":null," + "\"contextWindow\":null,\"percent\":null}"),
            "RPC returns correlated state with its real session and tool " + "catalog surfaces"
        )
        expect(
            server
                .handle("{\"id\":\"fast-on\",\"type\":\"set_fast_mode\"," + "\"enabled\":true}")
                .contains("\"error\":\"Fast mode is unavailable for the current model.\"") &&
                server
                .handle("{\"id\":\"fast-off\",\"type\":\"set_fast_mode\"," + "\"enabled\":false}")
                .contains("\"success\":true"),
            "RPC rejects unsupported fast mode instead of claiming success"
        )
        expect(
            server
                .handle("{\"id\":\"sub-subscribe\",\"type\":" + "\"set_subagent_subscription\",\"level\":\"events\"}")
                .contains("\"level\":\"events\"") &&
                server
                .handle(
                    "{\"id\":\"sub-subscribe-invalid\",\"type\":" + "\"set_subagent_subscription\",\"level\":\"all\"}")
                .contains("\"success\":false") &&
                server.handle("{\"id\":\"sub-list\",\"type\":\"get_subagents\"}").contains("\"subagents\":[]") &&
                server
                .handle("{\"id\":\"sub-messages\",\"type\":" + "\"get_subagent_messages\",\"subagentId\":\"missing\"}")
                .contains("\"error\":\"Unknown subagent: missing\""),
            "RPC configures the subagent event bus and validates selectors"
        )
        expect(
            server
                .handle("{\"id\":\"retry-off\",\"type\":\"set_auto_retry\"," + "\"enabled\":false}")
                .contains("\"success\":true") && !application.autoRetryEnabled() &&
                server
                .handle("{\"id\":\"retry-on\",\"type\":\"set_auto_retry\"," + "\"enabled\":true}")
                .contains("\"success\":true") && application.autoRetryEnabled() &&
                server.handle("{\"id\":\"retry-abort\",\"type\":\"abort_retry\"}").contains("\"success\":true"),
            "RPC controls the provider retry policy and abort signal"
        )
        expect(
            server
                .handle("{\"id\":\"compact-off\",\"type\":" + "\"set_auto_compaction\",\"enabled\":false}")
                .contains("\"success\":true") && !application.autoCompactionEnabled() &&
                server
                .handle("{\"id\":\"compact-on\",\"type\":" + "\"set_auto_compaction\",\"enabled\":true}")
                .contains("\"success\":true") && application.autoCompactionEnabled(),
            "RPC controls automatic compaction at completed-turn boundaries"
        )
        expect(
            server
                .handle("{\"id\":\"steering-all\",\"type\":" + "\"set_steering_mode\",\"mode\":\"all\"}")
                .contains("\"success\":true") && application.steeringMode() == QueueDeliveryMode.All &&
                server
                .handle("{\"id\":\"follow-one\",\"type\":" + "\"set_follow_up_mode\",\"mode\":\"one-at-a-time\"}")
                .contains("\"success\":true") && application.followUpMode() == QueueDeliveryMode.OneAtATime &&
                server
                .handle("{\"id\":\"interrupt-wait\",\"type\":" + "\"set_interrupt_mode\",\"mode\":\"wait\"}")
                .contains("\"success\":true") && application.interruptMode() == RunInterruptMode.Wait,
            "RPC queue modes alter the ApplicationSession interaction source"
        )
        let _ = server.handle("{\"id\":\"interrupt-reset\",\"type\":" + "\"set_interrupt_mode\",\"mode\":\"immediate\"}")
        let originalSession = application.id()
        expect(
            server
                .handle(
                    "{\"id\":\"model-a\",\"type\":\"set_model\"," + "\"provider\":\"fixture\"," +
                        "\"modelId\":\"fixture\"}")
                .contains("\"success\":true"),
            "RPC selects a model for the current session"
        )
        expect(
            server
                .handle("{\"id\":\"thinking-high\",\"type\":" + "\"set_thinking_level\",\"level\":\"high\"}")
                .contains("\"success\":true") && application.thinking() == ThinkingLevel.High &&
                server
                .handle("{\"id\":\"thinking-cycle\",\"type\":" + "\"cycle_thinking_level\"}")
                .contains("\"level\":\"xhigh\"") && application.thinking() == ThinkingLevel.XHigh,
            "RPC thinking controls alter subsequent model requests"
        )
        expect(
            server
                .handle(
                    "{\"id\":\"todos-valid\",\"type\":\"set_todos\"," + "\"phases\":[{\"name\":\"Build\",\"tasks\":[" +
                        "{\"content\":\"wire RPC\",\"status\":\"in_progress\"}," +
                        "{\"content\":\"prove persistence\",\"status\":\"blocked\"," + "\"blocker\":\"contract\"}]}]}")
                .contains("\"success\":true") &&
                product.applicationSession(sessionId: originalSession).todoPhases().value().getOrThrow().size == 1 &&
                server
                .handle(
                    "{\"id\":\"todos-invalid\",\"type\":\"set_todos\"," + "\"phases\":[{\"name\":\"Build\",\"tasks\":[" +
                        "{\"content\":\"bad\",\"status\":\"unknown\"}]}]}")
                .contains("\"success\":false"),
            "RPC validates typed todo phases and persists them by session"
        )
        let parentLineage = root + "/parent-session.jsonl"
        expect(
            server
                .handle("{\"id\":\"new-model\",\"type\":\"new_session\"," + "\"parentSession\":\"" + parentLineage +
                    "\"}")
                .contains("\"success\":true") && application.parentSession().value().getOrThrow() == parentLineage &&
                server.handle("{\"id\":\"new-state\",\"type\":\"get_state\"}").contains("\"id\":\"fixture\"") &&
                server.handle("{\"id\":\"new-todos\",\"type\":\"get_state\"}").contains("\"todoPhases\":[]"),
            "RPC new session reports the default model and fresh todo state"
        )
        expect(
            server
                .handle(
                    "{\"id\":\"restore-model\",\"type\":\"switch_session\"," + "\"sessionPath\":\"" + originalSession
                        .value + "\"}")
                .contains("\"success\":true") &&
                server.handle("{\"id\":\"restored-state\",\"type\":\"get_state\"}").contains("\"id\":\"fixture\"") &&
                server
                .handle("{\"id\":\"restored-todos\",\"type\":\"get_state\"}")
                .contains("\"content\":\"wire RPC\""),
            "RPC session switch restores durable model and typed todo state"
        )
        let branchSource = SessionId("rpc-branch-source")
        expect(
            product.replaceMessages(
                branchSource,
                [
                    ModelMessage(
                        ModelRole.User,
                        [ModelBlock(ModelBlockKind.Text, text: "first prompt")]
                    ),
                    ModelMessage(
                        ModelRole.Assistant,
                        [ModelBlock(ModelBlockKind.Text, text: "first answer")]
                    ),
                    ModelMessage(
                        ModelRole.User,
                        [ModelBlock(ModelBlockKind.Text, text: "second prompt")]
                    ),
                    ModelMessage(
                        ModelRole.Assistant,
                        [ModelBlock(ModelBlockKind.Text, text: "second answer")]
                    )
                ]
            ).isOk() && application.switchSession(branchSource).isOk(),
            "RPC branch fixture installs a linear durable transcript"
        )
        let branchChoices = server.handle("{\"id\":\"branch-choices\",\"type\":" + "\"get_branch_messages\"}")
        expect(
            branchChoices.contains("\"entryId\":\"rpc-branch-source:0:4\"," + "\"text\":\"first prompt\"") &&
                branchChoices.contains("\"entryId\":\"rpc-branch-source:2:4\"," + "\"text\":\"second prompt\"") &&
                server
                .handle("{\"id\":\"branch-second\",\"type\":\"branch\"," + "\"entryId\":\"rpc-branch-source:2:4\"}")
                .contains("\"text\":\"second prompt\",\"cancelled\":false") &&
                application.messages().value().getOrThrow().size == 2 &&
                application.parentSession().value().getOrThrow() == product.sessionReference(branchSource) &&
                server
                .handle("{\"id\":\"branch-stale\",\"type\":\"branch\"," + "\"entryId\":\"rpc-branch-source:2:4\"}")
                .contains("\"success\":false") && application.switchSession(originalSession).isOk(),
            "RPC branches at the selected user entry, returns its draft, " + "and rejects stale entry IDs"
        )
        let handoffSource = SessionId("rpc-handoff-source")
        expect(
            product.replaceMessages(
                handoffSource,
                [
                    ModelMessage(
                        ModelRole.User,
                        [
                            ModelBlock(
                                ModelBlockKind.Text,
                                text: "implement RPC handoff"
                            )
                        ]
                    ),
                    ModelMessage(
                        ModelRole.Assistant,
                        [
                            ModelBlock(
                                ModelBlockKind.Text,
                                text: "handoff work is in progress"
                            )
                        ]
                    )
                ]
            ).isOk() && application.switchSession(handoffSource).isOk(),
            "RPC handoff fixture installs a completed turn"
        )
        let sessionsBeforeHandoff = product.sessions().value().getOrThrow().size
        let handoffResponse = server.handle(
            "{\"id\":\"handoff-real\",\"type\":\"handoff\"," + "\"customInstructions\":\"preserve RPC decisions\"}")
        let handoffMessages = application.messages().value().getOrThrow()
        expect(
            handoffResponse.contains("\"success\":true") && handoffMessages.size == 1 &&
                userMessageTextForContract(handoffMessages[0]).contains("<handoff-context>") &&
                userMessageTextForContract(handoffMessages[0]).contains("preserve RPC decisions") &&
                application.parentSession().value().getOrThrow() == product.sessionReference(handoffSource) &&
                product.sessions().value().getOrThrow().size == sessionsBeforeHandoff + 1 &&
                application.switchSession(originalSession).isOk(),
            "RPC handoff generates a model-authored document, starts a " +
                "lineage-linked session, and removes its side transcript"
        )
        let help = server.handle("{\"id\":\"h1\",\"type\":\"prompt\"," + "\"message\":\"/help\"}")
        expect(
            help.contains("\"command\":\"prompt\"") && help.contains("\"success\":true"),
            "RPC accepts a local prompt"
        )
        expect(
            output.awaitContains("\"type\":\"prompt_result\",\"id\":\"h1\"," + "\"agentInvoked\":false"),
            "local RPC command reports agentInvoked false"
        )
        expect(
            server
                .handle("{\"id\":\"task-prompt\",\"type\":\"prompt\"," + "\"message\":\"fixture task\"}")
                .contains("\"success\":true") && output.awaitContains(
                "\"type\":\"subagent_lifecycle\",\"payload\":{" + "\"id\":\"fixture-child\"") && output.awaitContains(
                "\"type\":\"subagent_progress\"") && output.awaitContains("\"type\":\"subagent_event\"") &&
                output.awaitContains("\"type\":\"prompt_result\",\"id\":\"task-prompt\"," + "\"agentInvoked\":true"),
            "RPC streams real task lifecycle, progress, and child events"
        )
        expect(
            server.handle("{\"id\":\"sub-finished\",\"type\":\"get_subagents\"}").contains("\"subagents\":[]") &&
                server
                .handle(
                    "{\"id\":\"sub-transcript\",\"type\":" + "\"get_subagent_messages\",\"subagentId\":" +
                        "\"fixture-child\",\"fromItem\":0}")
                .contains("\"answer\":\"reviewed\""),
            "RPC resolves durable child transcripts after task completion"
        )
        let taskSession = application.id()
        expect(
            application.newSession().isOk() && application.allSubagents().isEmpty() &&
                application.subagentTranscript(subagentId: "fixture-child").isError() &&
                application.switchSession(taskSession).isOk() &&
                application.subagentTranscript(subagentId: "fixture-child").isOk(),
            "subagent snapshots and transcripts are scoped to the active " + "parent session"
        )
        let toolCountBeforeHost = application.tools().size
        let hostToolsResponse = server.handle(
            "{\"id\":\"host-tools\",\"type\":\"set_host_tools\"," + "\"tools\":[{\"name\":\"host_echo\"," +
                "\"description\":\"Echo through the RPC host.\"," +
                "\"parameters\":{\"type\":\"object\",\"properties\":{" +
                "\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}]}")
        expect(
            hostToolsResponse.contains("\"toolNames\":[\"host_echo\"]") && application.tools().size ==
                toolCountBeforeHost + 1 && hasTool(application.tools(), "eval") && hasTool(application.tools(),
                "host_echo"),
            "RPC host tool definitions refresh the active model catalog"
        )
        expect(
            server
                .handle("{\"id\":\"host-prompt\",\"type\":\"prompt\"," + "\"message\":\"fixture host tool\"}")
                .contains("\"success\":true") && output.awaitContains(
                "\"type\":\"host_tool_call\",\"id\":\"host-1\"," + "\"toolCallId\":\"fixture-host-call\"," +
                    "\"toolName\":\"host_echo\""),
            "model host-tool calls are forwarded to the RPC host"
        )
        expect(
            server.handle(
                "{\"type\":\"host_tool_result\",\"id\":\"host-1\"," + "\"result\":{\"content\":[{\"type\":\"text\"," +
                    "\"text\":\"host result\"}]}}") == "" && output.awaitContains(
                "\"type\":\"prompt_result\",\"id\":\"host-prompt\"," + "\"agentInvoked\":true"),
            "RPC host results resume the same agent tool loop"
        )
        expect(
            server
                .handle("{\"id\":\"host-tools-clear\",\"type\":\"set_host_tools\"," + "\"tools\":[]}")
                .contains("\"toolNames\":[]") && application.tools().size == toolCountBeforeHost && hasTool(
                application.tools(), "eval") && !hasTool(application.tools(), "host_echo") &&
                server
                .handle(
                    "{\"id\":\"host-tools-invalid\",\"type\":\"set_host_tools\"," +
                        "\"tools\":[{\"name\":\"bad\",\"description\":\"\"," + "\"parameters\":{}}]}")
                .contains("\"success\":false"),
            "RPC host tools can be replaced and invalid definitions are rejected"
        )
        expect(
            server
                .handle(
                    "{\"id\":\"host-uris\",\"type\":" + "\"set_host_uri_schemes\",\"schemes\":[{" +
                        "\"scheme\":\"HostDoc\",\"description\":\"Host docs\"," +
                        "\"writable\":true,\"immutable\":true}]}")
                .contains("\"schemes\":[\"hostdoc\"]") && application.uriSchemes().size == 1 &&
                server
                .handle(
                    "{\"id\":\"host-uris-invalid\",\"type\":" + "\"set_host_uri_schemes\",\"schemes\":[{" +
                        "\"scheme\":\"9bad\"}]}")
                .contains("\"success\":false"),
            "RPC validates and installs normalized host URI schemes"
        )
        expect(
            server
                .handle("{\"id\":\"host-uri-read\",\"type\":\"prompt\"," + "\"message\":\"fixture host uri read\"}")
                .contains("\"success\":true") && output.awaitContains(
                "\"type\":\"host_uri_request\",\"id\":\"uri-1\"," + "\"operation\":\"read\",\"url\":\"hostdoc://guide\""),
            "read dispatches registered URI schemes to the RPC host"
        )
        expect(
            server.handle(
                "{\"type\":\"host_uri_result\",\"id\":\"uri-1\"," + "\"content\":\"host document\",\"contentType\":" +
                    "\"text/markdown\",\"notes\":[\"from host\"]}") == "" && output.awaitContains(
                "\"type\":\"prompt_result\",\"id\":\"host-uri-read\"," + "\"agentInvoked\":true"),
            "host URI read results resume the same agent tool loop"
        )
        expect(
            server
                .handle("{\"id\":\"host-uri-write\",\"type\":\"prompt\"," + "\"message\":\"fixture host uri write\"}")
                .contains("\"success\":true") && output.awaitContains(
                "\"type\":\"host_uri_request\",\"id\":\"uri-2\"," +
                    "\"operation\":\"write\",\"url\":\"hostdoc://guide\"," + "\"content\":\"updated by fixture\""),
            "write dispatches writable URI schemes to the RPC host"
        )
        expect(
            server.handle("{\"type\":\"host_uri_result\",\"id\":\"uri-2\"}") == "" && output.awaitContains(
                "\"type\":\"prompt_result\",\"id\":\"host-uri-write\"," + "\"agentInvoked\":true"),
            "host URI writes complete through the same agent loop"
        )
        let cancelPromptAccepted = server
                .handle("{\"id\":\"host-uri-cancel\",\"type\":\"prompt\"," + "\"message\":\"fixture host uri read\"}")
                .contains("\"success\":true")
        let cancelRequestVisible = output.awaitContains(
            "\"type\":\"host_uri_request\",\"id\":\"uri-3\"," +
                "\"operation\":\"read\",\"url\":\"hostdoc://guide\"")
        let abortResponse = server.handle(
            "{\"id\":\"abort-host-uri\",\"type\":\"abort\"}"
        )
        let abortAccepted = abortResponse.contains("\"success\":true")
        let cancelFrameVisible = output.awaitContains(
            "\"type\":\"host_uri_cancel\",\"id\":\"uri-4\"," +
                "\"targetId\":\"uri-3\"")
        let cancelResponseVisible = output.awaitContains(
                "\"type\":\"response\",\"id\":\"host-uri-cancel\"," + "\"command\":\"prompt\",\"success\":false," +
                    "\"error\":\"host URI request was cancelled\"")
        expect(
            cancelPromptAccepted && cancelRequestVisible && abortAccepted &&
                cancelFrameVisible && cancelResponseVisible,
            "cancelling a run cancels the pending host URI request; prompt=" +
                cancelPromptAccepted.toString() + ", request=" + cancelRequestVisible.toString() +
                ", abort=" + abortAccepted.toString() + ", cancelFrame=" +
                cancelFrameVisible.toString() + ", response=" + cancelResponseVisible.toString() +
                ", abortResponse=" + abortResponse
        )
        expect(
            server
                .handle("{\"id\":\"host-uris-clear\",\"type\":" + "\"set_host_uri_schemes\",\"schemes\":[]}")
                .contains("\"schemes\":[]") && application.uriSchemes().isEmpty(),
            "host URI schemes can be unregistered"
        )
        expect(
            server.handle("{\"id\":\"stats-session\",\"type\":\"new_session\"}").contains("\"success\":true"),
            "RPC statistics contract starts from a clean public session"
        )
        let prompt = server.handle("{\"id\":\"p1\",\"type\":\"prompt\"," + "\"message\":\"hello rpc\"}")
        expect(
            prompt.contains("\"success\":true"),
            "RPC accepts an agent prompt"
        )
        expect(
            output.awaitContains("\"type\":\"prompt_result\",\"id\":\"p1\"," + "\"agentInvoked\":true") &&
                output.contains("\"event\":{\"code\":\"model.text_delta\"," +
                    "\"text\":\"fixture response for hello rpc\"}"),
            "RPC streams events and reports agent invocation"
        )
        let stats = server.handle("{\"id\":\"stats-real\",\"type\":\"get_session_stats\"}")
        expect(
            stats.contains("\"userMessages\":1") && stats.contains("\"assistantMessages\":1") && stats.contains(
                "\"input\":1") && stats.contains("\"output\":1") && stats.contains("\"reasoning\":0") &&
                stats.contains("\"cacheRead\":0") && stats.contains("\"cacheWrite\":0") &&
                stats.contains("\"total\":2") && stats.contains("\"costMicros\":null") &&
                stats.contains("\"cost\":null") && stats.contains("\"lastRequest\":{"),
            "RPC session stats expose canonical usage while unknown prices remain null"
        )
        for (command in expectedCommands) {
            if (command == "prompt" || command == "steer" || command == "follow_up" || command == "abort_and_prompt") {
                continue
            }
            let response = server.handle(requestFor(command, root))
            expect(
                response.contains("\"command\":\"" + command + "\"") && !response.contains("unknown RPC command"),
                "RPC decodes pinned command: " + command
            )
        }
        expect(
            server
                .handle("{\"id\":\"protocol-v2\",\"type\":" + "\"negotiate_protocol\",\"protocolVersion\":2}")
                .contains("\"protocolVersion\":2"),
            "RPC negotiates protocol v2"
        )
        var large = "x"
        for (_ in 0..21) {
            large += large
        }
        let largeSession = SessionId("large-import")
        match (product.replaceMessages(
            largeSession,
            [
                ModelMessage(
                    ModelRole.User,
                    [ModelBlock(ModelBlockKind.Text, text: large)]
                )
            ]
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => throw IllegalStateException(
                "large history setup failed: " + error.code + " " + error.message)
        }
        expect(
            application.switchSession(largeSession).isOk(),
            "large history fixture is imported without product writes to OMP"
        )
        let chunked = server.handle("{\"id\":\"large\",\"type\":\"get_messages\"}")
        expect(
            chunked.startsWith("{\"type\":\"rpc_chunk\"") && chunked.contains("\"byteLength\":") && chunked.contains(
                "\n{\"type\":\"rpc_chunk\""),
            "protocol v2 emits uninterrupted lossless chunk frames"
        )
        expect(
            server.handle("{\"id\":\"bad\",\"type\":\"not_real\"}").contains("\"success\":false"),
            "unknown RPC command is rejected"
        )
        let asyncProduct = openProduct(
            config: ProductConfig(
                settingsRoot: root + "/async-rpc-settings",
                stateRoot: root + "/async-rpc-state",
                workspaceRoot: root,
                fixture: true,
                approvalMode: ApprovalMode.Yolo,
                asyncEnabled: true
            )
        ).value().getOrThrow()
        let asyncApplication = asyncProduct.applicationSession()
        let asyncOutput = FrameCollector()
        let asyncServer = ProductJsonlRpcServer(
            asyncApplication,
            {frame => asyncOutput.add(frame)}
        )
        expect(
            asyncServer
                .handle("{\"id\":\"async-task\",\"type\":\"prompt\"," + "\"message\":\"fixture task\"}")
                .contains("\"success\":true"),
            "RPC accepts an asynchronous task prompt"
        )
        let asyncJobStarted = asyncOutput.awaitContains("\"type\":\"async_job\",\"kind\":\"started\"")
        let settledJobs = asyncApplication.waitForAsyncJobs(
            [],
            timeoutMillis: 5000
        )
        expect(
            asyncJobStarted && settledJobs.size == 1 && settledJobs[0].status == "completed" &&
                asyncOutput.awaitContains("\"type\":\"async_job\",\"kind\":\"settled\"") && asyncOutput.awaitContains(
                "\"id\":\"fixture-child\",\"agentId\":" + "\"fixture-child\""),
            "RPC streams managed job start and settled result frames"
        )
        let asyncBashApplication = asyncProduct.applicationSession()
        let asyncBashOutput = FrameCollector()
        let asyncBashServer = ProductJsonlRpcServer(
            asyncBashApplication,
            {frame => asyncBashOutput.add(frame)}
        )
        expect(
            asyncBashServer
                .handle("{\"id\":\"async-bash\",\"type\":\"prompt\"," + "\"message\":\"fixture async bash\"}")
                .contains("\"success\":true") && asyncBashOutput.awaitContains(
                "\"type\":\"async_job\",\"kind\":\"started\""),
            "RPC accepts and announces an asynchronous bash job"
        )
        let settledBashJobs = asyncBashApplication.waitForAsyncJobs(
            [],
            timeoutMillis: 5000
        )
        expect(
            settledBashJobs.size == 1 && settledBashJobs[0].jobType == "bash" && settledBashJobs[0].status == "completed" &&
                asyncBashOutput.awaitContains("\"type\":\"bash\",\"status\":\"completed\""),
            "RPC streams the captured asynchronous bash result: " +
                asyncBashOutput.snapshot()
        )

        let providerRoot = root + "/rpc-provider"
        Directory.create(providerRoot, recursive: true)
        File.writeTo(
            providerRoot + "/config.yml",
            "default_model: local-a/a-model\n".toArray()
        )
        File.writeTo(
            providerRoot + "/models.yml",
            ("models:\n" + "  - id: a-model\n" + "    provider: local-a\n" +
                "    context_window: 200000\n" + "    max_output_tokens: 8192\n" +
                "    thinking:\n" + "      mode: effort\n" +
                "      levels: [minimal, low, medium, high, xhigh, max]\n" +
                "    input_modalities: [text, image]\n" + "    output_modalities: [text]\n" +
                "    input_cost_micros_per_million: 1000000\n" +
                "    output_cost_micros_per_million: 2000000\n" +
                "    cache_read_cost_micros_per_million: 250000\n" +
                "    cache_write_cost_micros_per_million: 1250000\n" +
                "    fast_service_tier: priority\n" + "  - id: b-model\n" +
                "    provider: local-b\n" + "    thinking:\n" + "      mode: none\n").toArray()
        )
        File.writeTo(
            providerRoot + "/providers.yml",
            ("providers:\n" + "  - id: local-a\n" + "    provider: custom\n" + "    protocol: completions\n" +
                "    dialect: generic_chat\n" +
                "    base_url: http://127.0.0.1:11434\n" + "    api_key_env: RPC_LOCAL_A_KEY\n" + "  - id: local-b\n" +
                "    provider: custom\n" + "    protocol: completions\n" + "    dialect: generic_chat\n" +
                "    base_url: http://127.0.0.1:11435\n" +
                "    api_key_env: RPC_LOCAL_B_KEY\n").toArray()
        )
        let providerProduct = openProduct(
            config: ProductConfig(
                settingsRoot: providerRoot,
                stateRoot: root + "/rpc-provider-state",
                workspaceRoot: root
            )
        ).value().getOrThrow()
        let providerApplication = providerProduct.applicationSession()
        let providerServer = ProductJsonlRpcServer(
            providerApplication,
            {_ => ()}
        )
        let providerCatalog = providerServer.handle("{\"id\":\"provider-list\",\"type\":" + "\"get_login_providers\"}")
        expect(
            providerCatalog.contains("\"id\":\"local-a\"") && providerCatalog.contains("\"id\":\"local-b\"") &&
                providerCatalog.contains("\"available\":true") && providerCatalog.contains("\"authenticated\":false"),
            "RPC returns the complete configured provider/auth catalog"
        )
        let modelCatalog = providerServer.handle("{\"id\":\"models\",\"type\":\"get_available_models\"}")
        expect(
            modelCatalog.contains("\"provider\":\"custom\",\"id\":\"a-model\"") && modelCatalog.contains(
                "\"provider\":\"custom\",\"id\":\"b-model\"") && modelCatalog.contains(
                "\"contextWindow\":200000") && modelCatalog.contains("\"maxTokens\":8192") &&
                modelCatalog.contains("\"reasoning\":true") && modelCatalog.contains(
                "\"input\":[\"text\",\"image\"]") && modelCatalog.contains("\"output\":[\"text\"]") &&
                modelCatalog.contains("\"fastServiceTier\":\"priority\"") && modelCatalog.contains(
                "\"costMicrosPerMillion\":{\"input\":1000000,\"output\":2000000," +
                    "\"cacheRead\":250000,\"cacheWrite\":1250000}") && modelCatalog.contains(
                "\"id\":\"b-model\",\"contextWindow\":null,\"maxTokens\":null,\"reasoning\":false," +
                    "\"input\":null,\"output\":null,\"fastServiceTier\":null") &&
                providerServer
                .handle("{\"id\":\"provider-fast-on\",\"type\":\"set_fast_mode\",\"enabled\":true}")
                .contains("\"enabled\":true") && providerServer
                .handle("{\"id\":\"provider-fast-state\",\"type\":\"get_state\"}")
                .contains("\"fastModeEnabled\":true,\"fastModeActive\":true") && providerServer
                .handle("{\"id\":\"provider-context-state\",\"type\":\"get_state\"}")
                .contains("\"contextUsage\":{\"tokens\":0,\"contextWindow\":200000,\"percent\":0.000000}") &&
                providerServer
                .handle(
                    "{\"id\":\"select-b\",\"type\":\"set_model\"," + "\"provider\":\"custom\",\"modelId\":\"b-model\"}")
                .contains("\"provider\":\"custom\",\"id\":\"b-model\"") && providerApplication.model() ==
                "local-b/b-model" &&
                providerServer
                .handle(
                    "{\"id\":\"select-missing\",\"type\":\"set_model\"," +
                        "\"provider\":\"wrong\",\"modelId\":\"b-model\"}")
                .contains("\"success\":false"),
            "RPC exposes real optional metadata, persistent fast/context state, and selects by exact provider/model pair"
        )
        setVariable("RPC_LOCAL_B_KEY", "rpc-provider-secret")
        expect(
            providerServer
                .handle("{\"id\":\"login-b\",\"type\":\"login\"," + "\"providerId\":\"local-b\"}")
                .contains("\"providerId\":\"local-b\"") && exists(Path(providerRoot + "/credentials/local-b.key")) &&
                !exists(Path(providerRoot + "/credentials/local-a.key")) &&
                providerServer
                .handle("{\"id\":\"login-missing\",\"type\":\"login\"," + "\"providerId\":\"missing\"}")
                .contains("\"success\":false"),
            "RPC login validates and authenticates the requested provider"
        )
        removeVariable("RPC_LOCAL_B_KEY")
        println("product_rpc contract passed")
        0
    } finally {
        removeVariable("RPC_LOCAL_A_KEY")
        removeVariable("RPC_LOCAL_B_KEY")
        let _ = removeIfExists(root, recursive: true)
    }
}

func allCommandsPresent(expected: Array<String>): Bool {
    for (name in expected) {
        var found = false
        for (actual in availableRpcCommands() where actual == name) {
            found = true
        }
        if (!found) {
            return false
        }
    }
    true
}

func allSlashDescriptorsPresent(actual: Array<AgentValue>): Bool {
    for (definition in slashCommandDefinitions()) {
        var matched = false
        for (command in actual where
             command.field("name").getOrThrow().text == definition.name) {
            matched = optionalTextItemsMatch(
                command.field("aliases"),
                definition.aliases
            ) && optionalTextMatch(
                command.field("description"),
                definition.description
            ) && command.field("usage").isNone() && optionalInputMatches(
                command.field("input"),
                definition.inputHint()
            ) && optionalSubcommandsMatch(
                command.field("subcommands"),
                definition.subcommands
            ) && command.field("source").getOrThrow().text == definition.source
        }
        if (!matched) {
            return false
        }
    }
    true
}

func optionalTextItemsMatch(
    actual: ?AgentValue,
    expected: Array<String>
): Bool {
    if (expected.isEmpty()) {
        return actual.isNone()
    }
    if (actual.isNone()) {
        return false
    }
    textItemsMatch(actual.getOrThrow(), expected)
}

func textItemsMatch(actual: AgentValue, expected: Array<String>): Bool {
    if (actual.unifiedKind != ValueKind.List || actual.items.size != expected.size) {
        return false
    }
    for (index in 0..expected.size) {
        if (actual.items[index].unifiedKind != ValueKind.Text ||
            actual.items[index].text != expected[index]) {
            return false
        }
    }
    true
}

func optionalTextMatch(actual: ?AgentValue, expected: String): Bool {
    if (expected == "") {
        return actual.isNone()
    }
    actual.isSome() && actual.getOrThrow().unifiedKind == ValueKind.Text &&
        actual.getOrThrow().text == expected
}

func optionalInputMatches(actual: ?AgentValue, expected: String): Bool {
    if (expected == "") {
        return actual.isNone()
    }
    actual.isSome() &&
        actual.getOrThrow().field("hint").getOrThrow().text == expected
}

func optionalSubcommandsMatch(
    actual: ?AgentValue,
    expected: Array<String>
): Bool {
    if (expected.isEmpty()) {
        return actual.isNone()
    }
    if (actual.isNone()) {
        return false
    }
    subcommandsMatch(actual.getOrThrow(), expected)
}

func subcommandsMatch(actual: AgentValue, expected: Array<String>): Bool {
    if (actual.unifiedKind != ValueKind.List || actual.items.size != expected.size) {
        return false
    }
    for (index in 0..expected.size) {
        let item = actual.items[index]
        if (item.field("name").getOrThrow().text != expected[index] ||
            item.field("description").isSome() ||
            item.field("usage").isSome()) {
            return false
        }
    }
    true
}

func slashDescriptor(actual: Array<AgentValue>, name: String): ?AgentValue {
    for (command in actual where
         command.field("name").getOrThrow().text == name) {
        return Some(command)
    }
    None
}

func hasSlashDescriptor(actual: Array<AgentValue>, name: String): Bool {
    slashDescriptor(actual, name).isSome()
}

func requestFor(command: String, root: String): String {
    let suffix = match (command) {
        case "negotiate_protocol" => ",\"protocolVersion\":2"
        case "set_fast_mode" | "set_auto_compaction" | "set_auto_retry" => ",\"enabled\":true"
        case "set_todos" => ",\"phases\":[]"
        case "set_host_tools" => ",\"tools\":[]"
        case "set_host_uri_schemes" => ",\"schemes\":[]"
        case "set_subagent_subscription" => ",\"level\":\"off\""
        case "set_model" => ",\"provider\":\"fixture\"," + "\"modelId\":\"fixture\""
        case "set_thinking_level" => ",\"level\":\"high\""
        case "set_steering_mode" | "set_follow_up_mode" => ",\"mode\":\"all\""
        case "set_interrupt_mode" => ",\"mode\":\"immediate\""
        case "bash" => ",\"command\":\"printf rpc-bash\""
        case "export_html" => ",\"outputPath\":\"" + root + "/rpc-export.html\""
        case "switch_session" => ",\"sessionPath\":\"rpc-switch\""
        case "branch" => ",\"entryId\":\"root\""
        case "set_session_name" => ",\"name\":\"rpc session\""
        case "login" => ",\"providerId\":\"fixture\""
        case "get_messages_page" => ",\"limit\":1"
        case _ => ""
    }
    "{\"id\":\"inventory-" + command + "\",\"type\":\"" + command + "\"" + suffix + "}"
}

func userMessageTextForContract(message: ModelMessage): String {
    var text = ""
    for (block in message.blocks where block.kind == ModelBlockKind.Text) {
        text += block.text
    }
    text
}

class FrameCollector {
    private let lock = Mutex()
    private let values = ArrayList<String>()

    func add(value: String): Unit {
        lock.lock()
        try {
            values.add(value)
        } finally {
            lock.unlock()
        }
    }

    func contains(fragment: String): Bool {
        lock.lock()
        try {
            for (value in values where value.contains(fragment)) {
                return true
            }
            false
        } finally {
            lock.unlock()
        }
    }

    func awaitContains(fragment: String): Bool {
        for (_ in 0..100) {
            if (contains(fragment)) {
                return true
            }
            sleep(Duration.millisecond * 10)
        }
        false
    }

    func snapshot(): String {
        lock.lock()
        try { values.toArray().toString() } finally { lock.unlock() }
    }

}

func hasTool(
    definitions: Array<ModelToolDefinition>,
    name: String
): Bool {
    for (definition in definitions where definition.name == name) {
        return true
    }
    false
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}
