package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func hostServiceEntryTestOrigin(): HostServiceOrigin {
    HostServiceOrigin("fixture.service", "axyndra:service-fixture",
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "host-service-instance-1", HostServiceAction.Start, "host-request-approved")
}

class HostServiceEntryProbe <: ToolExecutor {
    var calls: Int64 = 0
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let source = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value
            case _ => return Result.Err(AgentError(AgentErrorKind.Internal,
                "fixture.service_source_missing", "fixture requires the real canonical Direct source"))
        }
        if (!context.trustedControl || source.runId.value != context.runId.value || source.epoch != context.epoch ||
            !sameDirectCallOrigin(source.origin, DirectCallOrigin.HostService(hostServiceEntryTestOrigin()))) {
            return Result.Err(AgentError(AgentErrorKind.Internal,
                "fixture.service_source_invalid", "fixture did not receive the expected host-owned source"))
        }
        calls += 1
        Result.Ok(ToolResult(prepared.call.callId, objectValue([
            ValueField("input", prepared.operationPlan.canonicalArguments),
            ValueField("origin", directCallOriginValue(source.origin))
        ])))
    }
}

class HostServiceEntryFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let probe: HostServiceEntryProbe
    init(label: String) {
        root = pluginContractTemp("host-service-entry-" + label)
        Directory.create(root, recursive: true)
        product = match (openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.describe())
        }
        var openedDatabase: ?SqliteDatabase = None
        try {
            database = SqliteDatabase(root + "/state/state.db")
            openedDatabase = Some(database)
            probe = HostServiceEntryProbe()
            product.registerTool(ToolDescriptor(ModelToolDefinition("fixture_host_control",
                "Host-only fixture operation", objectValue([ValueField("type", textValue("object"))])),
                Capability(CapabilityKind.WorkspaceRead), sideEffecting: true, controlOnly: true,
                implementationVersion: "host-service-entry-fixture-v1", neverReplay: true), probe).value().getOrThrow()
        } catch (error: Exception) {
            let _ = product.close()
            match (openedDatabase) { case Some(value) => value.close(); case None => () }
            remove(root, recursive: true)
            throw error
        }
    }
    func call(id: String): ToolCall {
        ToolCall(id, "fixture_host_control", objectValue([
            ValueField("source", textValue("external")), ValueField("principal", textValue("root"))]))
    }
    func ceiling(): CapabilitySet { CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]) }
    func close(): Unit { let _ = product.close(); database.close(); remove(root, recursive: true) }
}

func hostServiceEntryCompleted(result: Result<ToolInvocationResult>): ToolResult {
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => value
        case Result.Err(error) => throw IllegalStateException(error.code)
        case _ => throw IllegalStateException("host service did not complete")
    }
}

func hostServiceEntrySucceeded(result: Result<ToolInvocationResult>): Bool {
    match (result) { case Result.Ok(ToolInvocationResult.Completed(value)) => !value.isError; case _ => false }
}

@Test
class ProductHostServiceEntryTests {
    @TestCase
    func approvedServiceUsesSystemNoteCanonicalSourceAndSingleReceipt(): Unit {
        let fixture = HostServiceEntryFixture("approved")
        try {
            let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            let output = hostServiceEntryCompleted(fixture.product.vnext.executeHostServiceTool(
                SessionId("maintenance-approved"), hostServiceEntryTestOrigin(), fixture.ceiling(),
                fixture.call("service-approved"), approvalDecision: Some(ApprovalDecision.Approve), budget: budget))
            @Expect(output.isError, false)
            @Expect(fixture.probe.calls, 1)
            @Expect(output.output.field("input").getOrThrow().field("principal").getOrThrow().text, "root")
            @Expect(sameDirectCallOrigin(directCallOriginFromValue(output.output.field("origin").getOrThrow()),
                DirectCallOrigin.HostService(hostServiceEntryTestOrigin())), true)
            let items = fixture.database.query("SELECT kind,provenance FROM items ORDER BY ordinal")
            @Expect(items.size, 3)
            @Expect(items[0].required(0), "system_note")
            @Expect(items[1].required(0), "tool_call")
            @Expect(items[2].required(0), "tool_result")
            @Expect(sameDirectCallOrigin(effectiveDirectCallOrigin(decodeStoredProvenance(items[0].required(1))),
                effectiveDirectCallOrigin(decodeStoredProvenance(items[1].required(1)))), true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals WHERE decision='approved'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_host_origin_bound'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='maintenance-approved' AND state='completed'"), 1)
            @Expect(fixture.database.query("SELECT kind FROM lane_inbox_entries")[0].required(0), "host_service")
        } finally { fixture.close() }
    }

    @TestCase
    func originCannotBypassApprovalCapabilitiesOrPublicAndHiddenBoundaries(): Unit {
        let fixture = HostServiceEntryFixture("denied")
        try {
            let missingApproval = fixture.product.vnext.executeHostServiceTool(SessionId("maintenance-unapproved"),
                hostServiceEntryTestOrigin(), fixture.ceiling(), fixture.call("unapproved"))
            @Expect(match (missingApproval) {
                case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => true
                case _ => false
            }, true)
            let deniedCapability = fixture.product.vnext.executeHostServiceTool(SessionId("maintenance-no-capability"),
                hostServiceEntryTestOrigin(), CapabilitySet(values: []), fixture.call("no-capability"),
                approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(hostServiceEntrySucceeded(deniedCapability), false)
            let deniedApproval = fixture.product.vnext.executeHostServiceTool(SessionId("maintenance-rejected"),
                hostServiceEntryTestOrigin(), fixture.ceiling(), fixture.call("rejected"),
                approvalDecision: Some(ApprovalDecision.Reject))
            @Expect(hostServiceEntrySucceeded(deniedApproval), false)
            @Expect(hostServiceEntryCompleted(deniedApproval).output.field("error").getOrThrow().text,
                "tool.approval_rejected")
            let publicGuess = fixture.product.vnext.executeCanonicalTool(SessionId("public-control-guess"),
                fixture.ceiling(), fixture.call("public-guess"))
            @Expect(hostServiceEntrySucceeded(publicGuess), false)
            @Expect(hostServiceEntryCompleted(publicGuess).output.field("error").getOrThrow().text, "tool.not_found")
            let hiddenGuess = fixture.product.vnext.executeHostServiceTool(SessionId("maintenance-hidden-guess"),
                hostServiceEntryTestOrigin(), fixture.ceiling(), ToolCall("hidden-guess", PLUGIN_READONLY_PROCESS_TOOL,
                    objectValue([])), approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(hostServiceEntrySucceeded(hiddenGuess), false)
            @Expect(hostServiceEntryCompleted(hiddenGuess).output.field("error").getOrThrow().text, "tool.not_found")
            @Expect(fixture.probe.calls, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id LIKE 'maintenance-%' AND kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='public-control-guess' AND kind='user_message'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func spentServiceBudgetSettlesKnownFailureBeforeExecutorHandoff(): Unit {
        let fixture = HostServiceEntryFixture("budget")
        try {
            let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            budget.reserve(BudgetCharge(toolCalls: 1)).value().getOrThrow()
            let result = fixture.product.vnext.executeHostServiceTool(SessionId("maintenance-spent"),
                hostServiceEntryTestOrigin(), fixture.ceiling(), fixture.call("spent"),
                approvalDecision: Some(ApprovalDecision.Approve), budget: budget)
            @Expect(result.error().getOrThrow().code, "budget.tool_calls_exceeded")
            @Expect(fixture.probe.calls, 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='failed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='maintenance-spent' AND state='failed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
        } finally { fixture.close() }
    }
}
