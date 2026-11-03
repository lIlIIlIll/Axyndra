package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func mcpRefresh(fixture: McpProductFixture, thread: String,
    decision!: ApprovalDecision = ApprovalDecision.Approve): Result<ToolInvocationResult> {
    fixture.product.refreshPluginService(SessionId(thread), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio",
        approvalDecision: decision, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
}
func mcpRefreshRevision(fixture: McpProductFixture, thread: String): Int64 {
    for (status in fixture.product.pluginServiceStatuses() where lifecycleText(status, "target_thread_id") == thread) {
        return lifecycleInt(status, "directory_revision", 2147483647)
    }
    throw IllegalStateException("refresh test has no retained service status")
}
func mcpRefreshName(fixture: McpProductFixture): String {
    "plugin." + productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.stdio.t_" + modelPolicySha256Text("remote.updated:雪")
}
func mcpRefreshVisible(fixture: McpProductFixture, thread: String, name: String): Bool {
    for (definition in fixture.product.tools(threadId: Some(ThreadId(thread))) where definition.name == name) { return true }
    false
}
func mcpRefreshReceiptCount(fixture: McpProductFixture, outcome: String): Int64 {
    fixture.database.query("SELECT r.id FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id " +
        "WHERE e.tool_id=? AND r.outcome=?", [SqlParameter.Text(PLUGIN_LIFECYCLE_REFRESH_TOOL), SqlParameter.Text(outcome)]).size
}

@Test
class PluginMcpRefreshTests {
    @TestCase
    func missingWindowAndRejectedApprovalSendNoMcpFramesAndKeepPriorService(): Unit {
        let missing = McpProductFixture()
        try {
            @Expect(!managedCompleted(missing.start("refresh-missing")).isError)
            let denied = mcpRefresh(missing, "refresh-missing")
            @Expect(denied.isError())
            @Expect(denied.error().getOrThrow().code, "plugin.lifecycle_refresh_not_granted")
            @Expect(missing.observed().size, 2)
            @Expect(missing.active("refresh-missing") && missing.visible("refresh-missing"))
            @Expect(missing.database.scalarInt("SELECT COUNT(*) FROM operations"), 1)
        } finally { missing.close() }
        let rejected = McpProductFixture(refresh: true, approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(rejected.start("refresh-reject")).isError)
            @Expect(managedRejected(mcpRefresh(rejected, "refresh-reject", decision: ApprovalDecision.Reject)))
            @Expect(rejected.observed().size, 2)
            @Expect(rejected.active("refresh-reject") && rejected.visible("refresh-reject"))
            @Expect(mcpRefreshReceiptCount(rejected, "completed"), 0)
            @Expect(rejected.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            let session = rejected.product.applicationSession(sessionId: Some(SessionId("refresh-reject")))
            rejected.product.fixtureProbe.getOrThrow().enqueueToolCallReply("prior-directory-still-usable", rejected.name, objectValue([]))
            lifecycleTestRequire(session.submit("Approve one request using the unchanged prior MCP directory."))
            let pending = session.approval().getOrThrow()
            @Expect(rejected.calls(), 0)
            @Expect(rejected.childReceipts("completed"), 0)
            lifecycleTestRequire(session.decide(pending.operationId.value, ApprovalDecision.Approve))
            rejected.awaitCalls(1)
            @Expect(lifecycleText(mcpProductOutput(rejected.database, "refresh-reject", "prior-directory-still-usable"), "status"), "complete")
            @Expect(rejected.calls(), 1)
            @Expect(rejected.childReceipts("completed"), 1)
        } finally { rejected.close() }
    }

    @TestCase
    func approvedRefreshUsesSameLeaseAndRealMaintenanceReceiptBeforeAtomicNewDirectory(): Unit {
        let fixture = McpProductFixture(mode: "refresh-change", refresh: true)
        try {
            @Expect(!managedCompleted(fixture.start("refresh-target")).isError)
            @Expect(!managedCompleted(fixture.call("refresh-target", "before-refresh")).isError)
            let before = fixture.database.query("SELECT o.normalized_plan FROM operations o JOIN derived_operation_admissions a ON a.operation_id=o.id " +
                "WHERE a.request_key='channel-service:before-refresh:mcp-call'")[0].required(0)
            let beforeBinding = decodeStoredValue(before).field("arguments").getOrThrow().field("binding").getOrThrow()
            let beforeUserMessages = fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'")
            @Expect(beforeUserMessages, 1)
            let refreshed = managedCompleted(mcpRefresh(fixture, "refresh-target"))
            @Expect(!refreshed.isError)
            @Expect(lifecycleText(refreshed.output, "schema"), "axyndra.lifecycle-refresh-result/v1")
            @Expect(mcpRefreshRevision(fixture, "refresh-target"), 2)
            @Expect(!fixture.visible("refresh-target"))
            @Expect(mcpRefreshVisible(fixture, "refresh-target", mcpRefreshName(fixture)))
            @Expect(!mcpRefreshVisible(fixture, "other-target", mcpRefreshName(fixture)))
            @Expect(fixture.observed().size, 4)
            @Expect(lifecycleText(parseUnifiedJson(fixture.observed()[3]), "method"), "tools/list")
            @Expect(mcpRefreshReceiptCount(fixture, "completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), beforeUserMessages)
            let rows = fixture.database.query("SELECT r.state,i.provenance FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN items i ON i.id=o.tool_call_item_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",
                [SqlParameter.Text(PLUGIN_LIFECYCLE_REFRESH_TOOL)])
            @Expect(rows.size, 1)
            @Expect(rows[0].required(0), "completed")
            let origins = fixture.database.query("SELECT r.thread_id,r.id,r.epoch FROM runs r JOIN operations o ON o.run_id=r.id " +
                "JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id IN (?,?) ORDER BY r.epoch",
                [SqlParameter.Text(PLUGIN_LIFECYCLE_TOOL), SqlParameter.Text(PLUGIN_LIFECYCLE_REFRESH_TOOL)])
            @Expect(origins.size, 2)
            @Expect(origins[0].required(0), origins[1].required(0))
            @Expect(origins[0].required(0) != "refresh-target")
            @Expect(fixture.database.query("SELECT id FROM items WHERE kind='user_message' AND thread_id=?",
                [SqlParameter.Text(origins[0].required(0))]).size, 0)
            @Expect(origins[0].required(1) != origins[1].required(1))
            @Expect(origins[0].required(2) != origins[1].required(2))
            match (effectiveDirectCallOrigin(decodeStoredProvenance(rows[0].required(1)))) {
                case DirectCallOrigin.HostService(origin) => @Expect(origin.action, HostServiceAction.Refresh)
                case _ => @Expect(false)
            }
            @Expect(managedRejected(fixture.call("refresh-target", "retired-name")))
            let result = managedCompleted(fixture.product.vnext.executeCanonicalTool(SessionId("refresh-target"), productCapabilities(),
                ToolCall("after-refresh", mcpRefreshName(fixture), objectValue([])),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1)))
            @Expect(!result.isError)
            fixture.awaitCalls(2)
            let latest = fixture.database.query("SELECT o.normalized_plan FROM operations o JOIN derived_operation_admissions a ON a.operation_id=o.id " +
                "WHERE a.request_key='channel-service:after-refresh:mcp-call'")[0].required(0)
            let afterBinding = decodeStoredValue(latest).field("arguments").getOrThrow().field("binding").getOrThrow()
            for (key in ["lease_id", "endpoint_identity", "instance_identity", "launch_digest", "startup_operation_id"]) {
                @Expect(lifecycleText(afterBinding, key), lifecycleText(beforeBinding, key))
            }
            @Expect(lifecycleInt(afterBinding, "directory_revision", 2147483647), 2)
            @Expect(lifecycleText(afterBinding, "implementation_fingerprint") != lifecycleText(beforeBinding, "implementation_fingerprint"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.plugin.lifecycle.start'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func approvalPreparedBeforeRefreshCannotRedirectToNewDirectory(): Unit {
        let fixture = McpProductFixture(mode: "refresh-change", refresh: true, approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("refresh-pending")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("refresh-pending")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("old-prepared-call", fixture.name, objectValue([]))
            lifecycleTestRequire(session.submit("Review the original MCP directory request."))
            let pending = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0)
            @Expect(fixture.calls(), 0)
            @Expect(!managedCompleted(mcpRefresh(fixture, "refresh-pending")).isError)
            let _ = session.decide(pending.operationId.value, ApprovalDecision.Approve)
            @Expect(fixture.calls(), 0)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0), frozen)
            @Expect(fixture.childReceipts("completed"), 0)
            @Expect(fixture.active("refresh-pending"))
            @Expect(mcpRefreshRevision(fixture, "refresh-pending"), 2)
            @Expect(mcpRefreshVisible(fixture, "refresh-pending", mcpRefreshName(fixture)))
        } finally { fixture.close() }
    }

    @TestCase
    func emptyRefreshIsActiveAndMalformedRefreshWithdrawsWithoutPartialPublication(): Unit {
        let empty = McpProductFixture(mode: "refresh-empty", refresh: true)
        try {
            @Expect(!managedCompleted(empty.start("refresh-empty")).isError)
            @Expect(!managedCompleted(mcpRefresh(empty, "refresh-empty")).isError)
            @Expect(empty.active("refresh-empty") && !empty.visible("refresh-empty"))
            @Expect(mcpRefreshRevision(empty, "refresh-empty"), 2)
            @Expect(empty.observed().size, 3)
            @Expect(mcpRefreshReceiptCount(empty, "completed"), 1)
        } finally { empty.close() }
        let invalid = McpProductFixture(mode: "refresh-malformed", refresh: true)
        try {
            @Expect(!managedCompleted(invalid.start("refresh-invalid")).isError)
            let result = mcpRefresh(invalid, "refresh-invalid")
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
            @Expect(!invalid.active("refresh-invalid") && !invalid.visible("refresh-invalid"))
            @Expect(!mcpRefreshVisible(invalid, "refresh-invalid", mcpRefreshName(invalid)))
            @Expect(mcpRefreshRevision(invalid, "refresh-invalid"), 1)
            @Expect(mcpRefreshReceiptCount(invalid, "unknown"), 1)
            @Expect(invalid.observed().size, 3)
            invalid.waitReleased()
        } finally { invalid.close() }
    }

    @TestCase
    func catalogConflictPreservesSuccessfulDiscoveryReceiptButNeverReportsApplied(): Unit {
        let fixture = McpProductFixture(mode: "refresh-change", refresh: true)
        try {
            @Expect(!managedCompleted(fixture.start("refresh-conflict")).isError)
            lifecycleTestRequire(fixture.product.registerTool(ToolDescriptor(ModelToolDefinition(mcpRefreshName(fixture),
                "immutable conflict sentinel", objectValue([ValueField("type", textValue("object"))])),
                Capability(CapabilityKind.ExtensionInvoke), sideEffecting: false), ManagedConflictExecutor()))
            let result = mcpRefresh(fixture, "refresh-conflict")
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().code, "plugin.lifecycle_refresh_publication_failed")
            @Expect(mcpRefreshReceiptCount(fixture, "completed"), 1)
            @Expect(!fixture.active("refresh-conflict") && !fixture.visible("refresh-conflict"))
            @Expect(mcpRefreshRevision(fixture, "refresh-conflict"), 1)
            var diagnostic = false
            for (status in fixture.product.pluginServiceStatuses() where lifecycleText(status, "target_thread_id") == "refresh-conflict") {
                diagnostic = lifecycleText(status, "refresh_error") == "plugin.lifecycle_refresh_not_published"
            }
            @Expect(diagnostic)
            @Expect(fixture.observed().size, 3)
            fixture.waitReleased()
        } finally { fixture.close() }
    }

    @TestCase
    func stopDuringActualRefreshSettlesUnknownAndReclaimsBothChannels(): Unit {
        let fixture = McpProductFixture(mode: "refresh-hang", refresh: true)
        try {
            @Expect(!managedCompleted(fixture.start("refresh-cancel")).isError)
            let running = spawn { mcpRefresh(fixture, "refresh-cancel") }
            try {
                let deadline = MonoTime.now() + Duration.second * 5
                while (fixture.observed().size < 3 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
                @Expect(fixture.observed().size, 3)
                let _ = fixture.product.stopPluginService(SessionId("refresh-cancel"), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio")
                @Expect(running.get().isError())
                fixture.waitReleased()
                @Expect(!fixture.visible("refresh-cancel"))
                @Expect(mcpRefreshReceiptCount(fixture, "unknown"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing')"), 0)
                @Expect(fixture.observed().size, 3)
            } finally {
                let _ = fixture.product.stopPluginService(SessionId("refresh-cancel"), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio")
                let _ = running.get()
            }
        } finally { fixture.close() }
    }

    @TestCase
    func operatorConfigurationChangeRevokesExistingServiceInsteadOfChangingItsGrant(): Unit {
        let fixture = McpProductFixture(refresh: true)
        try {
            @Expect(!managedCompleted(fixture.start("refresh-config")).isError)
            let path = fixture.files.settings + "/plugins/lifecycle.json"
            let document = parseUnifiedJson(String.fromUtf8(File.readFrom(path)), maxBytes: 262144)
            document.field("plugins").getOrThrow().items[0].field("configuration").getOrThrow()
                .put("request_timeout_ms", integerValue(1000))
            fixture.files.write(document)
            @Expect(mcpRefresh(fixture, "refresh-config").isError())
            fixture.waitReleased()
            @Expect(fixture.observed().size, 2)
            @Expect(!fixture.active("refresh-config") && !fixture.visible("refresh-config"))
            @Expect(mcpRefreshReceiptCount(fixture, "completed"), 0)
        } finally { fixture.close() }
    }
}
