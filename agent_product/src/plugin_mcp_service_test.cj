package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func mcpTestConfiguration(): AgentValue {
    objectValue([ValueField("version", integerValue(1)), ValueField("transport", textValue("stdio")),
        ValueField("request_timeout_ms", integerValue(10000)), ValueField("directory", objectValue([
            ValueField("max_pages", integerValue(8)), ValueField("max_tools", integerValue(64))]))])
}
func mcpTestRefreshWindow(): AgentValue {
    objectValue([ValueField("timeout_ms", integerValue(10000)), ValueField("max_input_bytes", integerValue(16384)),
        ValueField("max_output_bytes", integerValue(65536)), ValueField("max_writes", integerValue(8))])
}

// Shared schema/directory setup lives in LifecycleConfigurationFixture. This
// thin fixture changes only the actual installed package and approved backend.
// It does not fake the plugin host, channel, model decision, Operation or Receipt.
class McpProductFixture {
    let files = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let record: ProductPluginRecord
    let database: SqliteDatabase
    let transcript: String
    let name: String
    private let payloadTranscript: Bool
    init(mode!: String = "echo", approval!: ApprovalMode = ApprovalMode.Yolo, refresh!: Bool = false,
        configuration!: ?AgentValue = None, readOnlyTools!: Array<String> = [],
        capacityProfile!: ?AgentValue = None, peerPath!: ?String = None, payloadProfile!: ?AgentValue = None) {
        payloadTranscript = payloadProfile.isSome()
        var openedProduct: ?ProductRuntime = None
        var openedDatabase: ?SqliteDatabase = None
        try {
            product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: files.workspace,
                settingsRoot: files.settings, stateRoot: files.root + "/state", fixture: true,
                approvalMode: approval, asyncEnabled: false)))
            openedProduct = Some(product)
            let packageRoot = getVariable("AXYNDRA_MCP_CLIENT_PLUGIN_PACKAGE").getOrThrow()
            record = match (product.importLocalPlugin(packageRoot)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:mcp-client") {
                throw IllegalStateException("real MCP client package namespace is required")
            }
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            let peer = files.external + "/mcp-peer.py"
            File.writeTo(peer, File.readFrom(peerPath ?? getVariable("AXYNDRA_MCP_TEST_SERVER").getOrThrow()))
            transcript = files.workspace + "/actual-mcp-frames.jsonl"
            File.writeTo(transcript, "".toArray())
            let service = files.service()
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue([textValue("-u"), textValue(peer), textValue(mode), textValue(transcript)]))
            service.put("read_only_mounts", listValue([textValue(files.external)]))
            // The peer's append-only instrumentation is explicitly covered by
            // this operator grant. Endpoint itself retains zero ambient access.
            service.put("workspace_mode", textValue("workspace_readwrite"))
            service.put("lifetime_ms", integerValue(180000))
            service.put("max_input_bytes", integerValue(131072))
            let startup = service.field("startup").getOrThrow()
            startup.put("timeout_ms", integerValue(30000))
            startup.put("max_input_bytes", integerValue(16384))
            startup.put("max_output_bytes", integerValue(65536))
            startup.put("max_writes", integerValue(10))
            if (capacityProfile.isSome()) {
                service.put("protocol_limits", capacityProfile.getOrThrow())
                service.put("max_input_bytes", integerValue(16777216)); service.put("max_output_bytes", integerValue(16777216))
                let resources = service.field("resources").getOrThrow()
                resources.put("max_output_bytes", integerValue(16777216)); resources.put("file_size_bytes", integerValue(16777216))
                startup.put("max_output_bytes", integerValue(4194304)); startup.put("max_writes", integerValue(32))
            }
            match (payloadProfile) { case Some(value) => service.put("payload_limits", value); case None => () }
            if (refresh) {
                let window = mcpTestRefreshWindow()
                if (capacityProfile.isSome()) {
                    window.put("max_output_bytes", integerValue(4194304)); window.put("max_writes", integerValue(32))
                }
                service.put("refresh", window)
            }
            if (!readOnlyTools.isEmpty()) { service.put("read_only_tools", listValue(readOnlyTools.map { name => textValue(name) })) }
            let document = files.document(service: Some(service))
            let plugin = document.field("plugins").getOrThrow().items[0]
            plugin.put("configuration", match (configuration) { case Some(value) => value; case None => mcpTestConfiguration() })
            plugin.put("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))))
            plugin.put("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
            files.write(document)
            // Product's public startup entry loads the exact operator config
            // itself and lazily owns the one manager/Port. No test-only manager.
            database = SqliteDatabase(files.root + "/state/state.db")
            openedDatabase = Some(database)
            name = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.stdio.t_" + modelPolicySha256Text("remote.echo:雪")
        } catch (error: Exception) {
            try { match (openedProduct) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedDatabase) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            files.close(); throw error
        }
    }
    func start(thread: String, decision!: ApprovalDecision = ApprovalDecision.Approve): Result<ToolInvocationResult> {
        product.startPluginService(SessionId(thread), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio", "session", approvalDecision: decision,
            budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func call(thread: String, call: String, input!: AgentValue = objectValue([]), maxCalls!: Int64 = 2,
        capabilities!: CapabilitySet = productCapabilities()): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread), capabilities, ToolCall(call, name, input),
            budget: ExecutionBudget(maxToolCalls: maxCalls, maxConcurrentTools: 1))
    }
    func observed(): Array<String> {
        let lines = ArrayList<String>()
        let bytes = File.readFrom(transcript)
        if (bytes.size > (if (payloadTranscript) { 33554432 } else { 1048576 })) { throw IllegalStateException("MCP transcript exceeded fixture limit") }
        let parts = String.fromUtf8(bytes).split("\n")
        // Only complete physical frames count while the peer is appending.
        for (index in 0..parts.size - 1 where parts[index] != "") { lines.add(parts[index]) }
        lines.toArray()
    }
    func calls(): Int64 {
        var count: Int64 = 0
        for (line in observed() where lifecycleText(parseUnifiedJson(line, maxBytes: if (payloadTranscript) { 8388608 } else { 262144 }), "method") == "tools/call") { count += 1 }
        count
    }
    func awaitCalls(count: Int64): Unit {
        let deadline = MonoTime.now() + Duration.second * 15
        while (calls() < count && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (calls() != count) { throw IllegalStateException("actual MCP tools/call count differs from expected count") }
    }
    func childReceipts(outcome: String): Int64 {
        database.query("SELECT receipt.id FROM operation_receipts receipt " +
            "JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id " +
            "WHERE effect.tool_id=? AND receipt.outcome=?",
            [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL), SqlParameter.Text(outcome)]).size
    }
    func visible(thread: String): Bool {
        for (definition in product.tools(threadId: Some(ThreadId(thread))) where definition.name == name) { return true }
        false
    }
    func active(thread: String): Bool {
        for (status in product.pluginServiceStatuses() where lifecycleText(status, "target_thread_id") == thread &&
            lifecycleText(status, "state") == "ready") { return true }
        false
    }
    func retained(): Int64 {
        var count: Int64 = 0
        for (status in product.pluginServiceStatuses() where !status.field("cleanup_acknowledged").getOrThrow().asBool()) { count += 1 }
        count
    }
    func waitReleased(): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        while (retained() != 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (retained() != 0) { throw IllegalStateException("MCP manager still retains native cleanup ownership") }
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 10
        var closed = false
        while (!closed && MonoTime.now() < deadline) {
            closed = product.close().isOk()
            if (!closed) { sleep(Duration.millisecond * 10) }
        }
        if (!closed) { throw IllegalStateException("MCP fixture native cleanup did not acknowledge release") }
        database.close()
        files.close()
    }
}

func mcpProductOutput(database: SqliteDatabase, thread: String, call: String): AgentValue {
    for (item in SqliteThreadCommitSink(database).loadThread(ThreadId(thread)).items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(id, _, _, output, isError) =>
                if (id.value == call) {
                    if (isError) { throw IllegalStateException("actual MCP canonical result is an error") }
                    return output
                }
            case _ => ()
        }
    }
    throw IllegalStateException("actual MCP canonical result is missing")
}

@Test
class PluginMcpServiceTests {
    @TestCase
    func actualPackagedClientDirectCallUsesExactDerivedBytesAndSingleSlot(): Unit {
        let fixture = McpProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("mcp-direct")).isError)
            @Expect(fixture.active("mcp-direct"))
            @Expect(fixture.observed().size, 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.visible("mcp-direct") && !fixture.visible("another-thread"))
            let input = objectValue([ValueField("query", textValue("雪 &=+?#/%\n\\\""))])
            let result = managedCompleted(fixture.call("mcp-direct", "mcp-direct-call", input: input))
            @Expect(!result.isError)
            @Expect(lifecycleText(result.output, "status"), "complete")
            fixture.awaitCalls(1)
            let physical = fixture.observed()[2] + "\n"
            @Expect(result.output.field("result").getOrThrow().field("content").getOrThrow().items[0]
                .field("text").getOrThrow().text + "\n", physical)
            let rows = fixture.database.query("SELECT child.normalized_plan,admission.request_key,run.id,run.epoch " +
                "FROM operations child JOIN derived_operation_admissions admission ON admission.operation_id=child.id " +
                "JOIN operation_effect_records effect ON effect.operation_id=child.id " +
                "JOIN runs run ON run.id=child.run_id WHERE effect.tool_id=?",
                [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)])
            @Expect(rows.size, 1)
            let childArgs = decodeStoredValue(rows[0].required(0)).field("arguments").getOrThrow()
            let approvedBytes = lifecycleTestRequire(channelServiceWriteBytes(childArgs.field("intent").getOrThrow()))
            @Expect(String.fromUtf8(approvedBytes), physical)
            @Expect(rows[0].required(1), "channel-service:mcp-direct-call:mcp-call")
            let rpc = parseUnifiedJson(physical)
            let stable = "host-" + modelPolicySha256Text(stringifyUnifiedJson(listValue([
                textValue("mcp-direct"), textValue(rows[0].required(2)), integerValue(Int64.parse(rows[0].required(3))), textValue("mcp-direct-call")
            ])))
            @Expect(lifecycleText(rpc, "id"), stable)
            @Expect(canonicalAgentValue(rpc.field("params").getOrThrow().field("arguments").getOrThrow()), canonicalAgentValue(input))
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='mcp-direct' AND state='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(managedRejected(fixture.call("another-thread", "wrong-thread")))
            @Expect(managedRejected(fixture.call("mcp-direct", "wrong-domain",
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]))))
            @Expect(fixture.calls(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func actualCommittedPreparationWaitsForApprovalAndPreservesOneFrozenRequest(): Unit {
        let fixture = McpProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("mcp-approved")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("mcp-approved")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("mcp-reject-call", fixture.name, objectValue([]))
            lifecycleTestRequire(session.submit("Review this actual MCP call before execution."))
            let rejected = session.approval().getOrThrow()
            @Expect(fixture.calls(), 0)
            lifecycleTestRequire(session.decide(rejected.operationId.value, ApprovalDecision.Reject))
            @Expect(fixture.calls(), 0)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("mcp-approved-call", fixture.name,
                objectValue([ValueField("approved", boolValue(true))]))
            lifecycleTestRequire(session.submit("Approve the exact prepared MCP request."))
            let pending = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0)
            @Expect(fixture.calls(), 0)
            @Expect(fixture.childReceipts("completed"), 0)
            lifecycleTestRequire(session.decide(pending.operationId.value, ApprovalDecision.Approve))
            fixture.awaitCalls(1)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0), frozen)
            let output = mcpProductOutput(fixture.database, "mcp-approved", "mcp-approved-call")
            @Expect(lifecycleText(output, "status"), "complete")
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM canonical_decision_items") >= 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 1)
            let plan = decodeStoredValue(frozen).field("arguments").getOrThrow().field("host_plan").getOrThrow()
            let expected = lifecycleTestRequire(channelServiceWriteBytes(plan.field("intents").getOrThrow().items[0]))
            @Expect(String.fromUtf8(expected), fixture.observed()[2] + "\n")
        } finally { fixture.close() }
    }

    @TestCase
    func actualWrittenRequestWithoutMcpResponseKeepsRootUnknownAndNeverRetries(): Unit {
        let fixture = McpProductFixture(mode: "eof")
        try {
            @Expect(!managedCompleted(fixture.start("mcp-unknown")).isError)
            let pending = spawn { fixture.call("mcp-unknown", "mcp-lost-response") }
            try {
            fixture.awaitCalls(1)
            let deadline = MonoTime.now() + Duration.second * 5
            while (fixture.childReceipts("completed") == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
            @Expect(fixture.childReceipts("completed"), 1)
            // Causal release after the real write Receipt; the peer then loses
            // its response. Do not race backend exit against write settlement.
            File.writeTo(fixture.files.workspace + "/release-eof", "release".toArray())
            let result = pending.get()
            @Expect(result.isError())
            println("MCP_EOF_ACTUAL_ERROR: " + result.error().getOrThrow().describe())
            @Expect(result.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
            fixture.awaitCalls(1)
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='mcp-unknown' AND state='recovery_required'"), 1)
            @Expect(!fixture.active("mcp-unknown") && !fixture.visible("mcp-unknown"))
            @Expect(managedRejected(fixture.call("mcp-unknown", "must-not-retry")))
            @Expect(fixture.calls(), 1)
            fixture.waitReleased()
            } finally {
                File.writeTo(fixture.files.workspace + "/release-eof", "release".toArray())
                let _ = pending.get()
            }
        } finally { fixture.close() }
    }

    @TestCase
    func actualCommittedCancellationSettlesRootAndClosesBothOwnedProcesses(): Unit {
        let fixture = McpProductFixture(mode: "hang")
        try {
            @Expect(!managedCompleted(fixture.start("mcp-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("mcp-cancel")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("mcp-cancel-call", fixture.name, objectValue([]))
            let running = spawn { session.submit("Invoke and wait for the MCP peer.") }
            try {
            fixture.awaitCalls(1)
            let receiptDeadline = MonoTime.now() + Duration.second * 5
            while (fixture.childReceipts("completed") == 0 && MonoTime.now() < receiptDeadline) { sleep(Duration.millisecond * 10) }
            @Expect(fixture.childReceipts("completed"), 1)
            let started = agentUtcMillis()
            lifecycleTestRequire(session.cancel())
            let _ = running.get()
            @Expect(agentUtcMillis() - started < 5000)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='mcp-cancel' AND state='cancelled'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing')"), 0)
            @Expect(!fixture.active("mcp-cancel") && !fixture.visible("mcp-cancel"))
            fixture.waitReleased()
            @Expect(fixture.calls(), 1)
            @Expect(fixture.observed().size, 3)
            } finally { try { let _ = session.cancel() } finally { let _ = running.get() } }
        } finally { fixture.close() }
    }

    @TestCase
    func startupRejectionHasZeroFramesAndEmptyServerDirectoryNeedsNoFakeTool(): Unit {
        let fixture = McpProductFixture(mode: "empty", approval: ApprovalMode.AlwaysAsk)
        try {
            let rejected = fixture.start("mcp-empty", decision: ApprovalDecision.Reject)
            @Expect(managedRejected(rejected))
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(!managedCompleted(fixture.start("mcp-empty")).isError)
            @Expect(fixture.active("mcp-empty") && !fixture.visible("mcp-empty"))
            @Expect(fixture.observed().size, 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            let _ = fixture.product.stopPluginService(SessionId("mcp-empty"), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio")
            fixture.waitReleased()
        } finally { fixture.close() }
    }
}

func channelTestTerminal(status: String, error: AgentValue, result!: AgentValue = objectValue([])): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.service-call-result/v1")), ValueField("status", textValue(status)),
        ValueField("result", result), ValueField("error", error), ValueField("retry_safe", boolValue(false))])
}

@Test
class PluginChannelTerminalTests {
    @TestCase
    func completeBusinessFailureIsDistinctFromUnknownAndMalformedAfterWrite(): Unit {
        // The same transport error has different meaning when the actual
        // canonical caller remains live versus when its own token is cancelled.
        let caller = CancellationSource()
        let context = ToolInvocationContext(RunId("terminal-run"), SessionId("terminal-thread"),
            CapabilitySet(), cancellation: caller.token)
        let transport = AgentError(AgentErrorKind.Cancelled, "extension.cancelled", "endpoint was revoked")
        @Expect(!managedChannelCallerCancelled(context))
        @Expect(managedChannelFailure<Unit>(transport, true,
            callerCancelled: managedChannelCallerCancelled(context)).error().getOrThrow().kind,
            AgentErrorKind.RecoveryRequired)
        let _ = caller.cancel()
        @Expect(managedChannelCallerCancelled(context))
        @Expect(managedChannelFailure<Unit>(transport, true,
            callerCancelled: managedChannelCallerCancelled(context)).error().getOrThrow().kind,
            AgentErrorKind.Cancelled)
        caller.close()
        let opaque = objectValue([ValueField("arbitrary_protocol_data", textValue("not parsed by host"))])
        let success = lifecycleTestRequire(managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(
            channelTestTerminal("complete", nullValue(), result: opaque), false), true))
        @Expect(!success.isError)
        @Expect(canonicalAgentValue(success.output.field("result").getOrThrow()), canonicalAgentValue(opaque))
        let failure = lifecycleTestRequire(managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(
            channelTestTerminal("complete", textValue("remote.business_error"), result: opaque), true), true))
        @Expect(failure.isError)
        let input = lifecycleTestRequire(managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(
            channelTestTerminal("input_required", textValue("service.input_required"), result: opaque), true), true))
        @Expect(input.isError)
        @Expect(canonicalAgentValue(input.output.field("result").getOrThrow()), canonicalAgentValue(opaque))
        let unknown = managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(
            channelTestTerminal("unknown", textValue("service.unknown")), true), true)
        @Expect(unknown.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
        for (value in [objectValue([]), channelTestTerminal("complete", textValue("contradicts_ok")),
            channelTestTerminal("input_required", nullValue()), channelTestTerminal("unknown", nullValue()),
            channelTestTerminal("unsupported", nullValue()), channelTestTerminal("complete", textValue(""))]) {
            let beforeWrite = managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(value, false), false)
            @Expect(beforeWrite.error().getOrThrow().kind, AgentErrorKind.Protocol)
            let afterWrite = managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(value, false), true)
            @Expect(afterWrite.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
        }
        let liedRetry = channelTestTerminal("complete", nullValue()); liedRetry.put("retry_safe", boolValue(true))
        @Expect(managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(liedRetry, false), true)
            .error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
        @Expect(managedChannelTerminal("call", ProductJavaScriptPluginInvocationResult(
            channelTestTerminal("complete", nullValue()), true), true).error().getOrThrow().kind,
            AgentErrorKind.RecoveryRequired)
    }

    @TestCase
    func observerGateRejectsDuplicateForeignAndEveryRequestAfterClosure(): Unit {
        let gate = ProductManagedChannelGate()
        @Expect(gate.progress("invoke-actual"))
        @Expect(gate.accept("invoke-actual", "request-1"))
        @Expect(!gate.accept("invoke-actual", "request-1"))
        @Expect(!gate.accept("invoke-foreign", "request-2"))
        @Expect(!gate.progress("invoke-foreign"))
        @Expect(gate.accept("invoke-actual", "request-2"))
        gate.close(); gate.close()
        @Expect(!gate.isOpen())
        @Expect(!gate.accept("invoke-actual", "request-3"))
        @Expect(!gate.progress("invoke-actual"))
    }
}
