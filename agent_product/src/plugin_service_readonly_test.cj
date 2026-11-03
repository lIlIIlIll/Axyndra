package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func serviceReadonlyTestLocalName(): String { "t_" + modelPolicySha256Text("remote.echo:雪") }
func serviceReadonlyAssertPlans(database: SqliteDatabase, name: String, childName: String, count: Int64): Unit {
    let roots = database.query("SELECT o.effect_class,o.retry_disposition,o.normalized_plan FROM operations o " +
        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?", [SqlParameter.Text(name)])
    @Expect(roots.size, count)
    for (row in roots) {
        @Expect(row.required(0), "read_only")
        @Expect(row.required(1), "never")
        let binding = decodeStoredValue(row.required(2)).field("arguments").getOrThrow()
            .field("host_plan").getOrThrow().field("binding").getOrThrow()
        @Expect(lifecycleText(binding, "read_only_tool"), serviceReadonlyTestLocalName())
    }
    let children = database.query("SELECT o.effect_class,o.retry_disposition FROM operations o " +
        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?", [SqlParameter.Text(childName)])
    @Expect(children.size, count)
    for (row in children) {
        @Expect(row.required(0), "external_mutation")
        @Expect(row.required(1), "never")
    }
}

@Test
class PluginServiceReadOnlyTests {
    @TestCase
    func operatorStdioReadOnlyGrantAllowsActualDirectAndCommittedCallsUnderAlwaysAsk(): Unit {
        let fixture = McpProductFixture(approval: ApprovalMode.AlwaysAsk, readOnlyTools: [serviceReadonlyTestLocalName()])
        try {
            @Expect(!managedCompleted(fixture.start("stdio-readonly")).isError)
            @Expect(!managedCompleted(fixture.call("stdio-readonly", "readonly-direct")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("stdio-readonly")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("readonly-core", fixture.name, objectValue([]))
            lifecycleTestRequire(session.submit("Use the operator-declared read-only service."))
            @Expect(session.approval().isNone())
            @Expect(fixture.calls(), 2)
            @Expect(fixture.childReceipts("completed"), 2)
            serviceReadonlyAssertPlans(fixture.database, fixture.name, HOST_CHANNEL_WRITE_TOOL, 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func operatorHttpReadOnlyGrantKeepsActualPostChildrenAndNeverReplay(): Unit {
        // A read-only effect assertion does not override the independent,
        // default network-confirmation policy.
        let networkPrompt = McpHttpProductFixture(approval: ApprovalMode.AlwaysAsk,
            readOnlyTools: [serviceReadonlyTestLocalName()])
        try {
            @Expect(!managedCompleted(networkPrompt.start("http-network-prompt")).isError)
            match (lifecycleTestRequire(networkPrompt.call("http-network-prompt", "network-confirmation"))) {
                case ToolInvocationResult.NeedsApproval(request) => @Expect(request.toolName, networkPrompt.name)
                case _ => throw IllegalStateException("read-only HTTP must preserve explicit network confirmation")
            }
            @Expect(networkPrompt.calls(), 0)
            @Expect(networkPrompt.database.query("SELECT operation_id FROM operation_effect_records WHERE tool_id=?",
                [SqlParameter.Text(HOST_HTTP_STREAM_TOOL)]).size, 0)
            @Expect(networkPrompt.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            networkPrompt.assertNoSecrets()
        } finally { networkPrompt.close() }
        let fixture = McpHttpProductFixture(approval: ApprovalMode.AlwaysAsk,
            readOnlyTools: [serviceReadonlyTestLocalName()], askOnNetwork: false)
        try {
            @Expect(!managedCompleted(fixture.start("http-readonly")).isError)
            @Expect(!managedCompleted(fixture.call("http-readonly", "readonly-direct")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("http-readonly")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("readonly-core", fixture.name, objectValue([]))
            lifecycleTestRequire(session.submit("Use the operator-declared read-only HTTP service."))
            @Expect(session.approval().isNone())
            @Expect(fixture.calls(), 2)
            @Expect(fixture.childReceipts("completed"), 2)
            serviceReadonlyAssertPlans(fixture.database, fixture.name, HOST_HTTP_STREAM_TOOL, 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func remoteStdioAnnotationOrDifferentOperatorToolCannotRemoveApproval(): Unit {
        for (trusted in [Array<String>(), ["t_" + modelPolicySha256Text("some-other-tool")]]) {
            let fixture = McpProductFixture(mode: "annotation", approval: ApprovalMode.AlwaysAsk, readOnlyTools: trusted)
            try {
                @Expect(!managedCompleted(fixture.start("stdio-untrusted")).isError)
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("stdio-untrusted")))
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("untrusted", fixture.name, objectValue([]))
                lifecycleTestRequire(session.submit("Review the annotated remote call."))
                let approval = session.approval().getOrThrow()
                @Expect(fixture.calls(), 0)
                @Expect(fixture.childReceipts("completed"), 0)
                lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Reject))
                @Expect(fixture.calls(), 0)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func remoteHttpAnnotationOrDifferentOperatorToolCannotRemoveApproval(): Unit {
        for (trusted in [Array<String>(), ["t_" + modelPolicySha256Text("some-other-tool")]]) {
            let fixture = McpHttpProductFixture(mode: "annotation", approval: ApprovalMode.AlwaysAsk, readOnlyTools: trusted, askOnNetwork: false)
            try {
                @Expect(!managedCompleted(fixture.start("http-untrusted")).isError)
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("http-untrusted")))
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("untrusted", fixture.name, objectValue([]))
                lifecycleTestRequire(session.submit("Review the annotated remote HTTP call."))
                let approval = session.approval().getOrThrow()
                @Expect(fixture.calls(), 0)
                @Expect(fixture.childReceipts("completed"), 0)
                lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Reject))
                @Expect(fixture.calls(), 0)
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }

    @TestCase
    func cancellingReadOnlyStdioAfterActualWriteRetainsUnknownRootAndNoRetry(): Unit {
        let fixture = McpProductFixture(mode: "hang", approval: ApprovalMode.AlwaysAsk, readOnlyTools: [serviceReadonlyTestLocalName()])
        try {
            @Expect(!managedCompleted(fixture.start("stdio-ro-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("stdio-ro-cancel")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("readonly-cancel", fixture.name, objectValue([]))
            let running = spawn { session.submit("Wait for the operator-declared read-only service.") }
            try {
                fixture.awaitCalls(1)
                let deadline = MonoTime.now() + Duration.second * 5
                while (fixture.childReceipts("completed") == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
                @Expect(fixture.childReceipts("completed"), 1)
                lifecycleTestRequire(session.cancel())
                let _ = running.get()
                fixture.waitReleased()
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(!fixture.visible("stdio-ro-cancel"))
                @Expect(managedRejected(fixture.call("stdio-ro-cancel", "no-retry")))
                @Expect(fixture.calls(), 1)
                serviceReadonlyAssertPlans(fixture.database, fixture.name, HOST_CHANNEL_WRITE_TOOL, 1)
            } finally { let _ = session.cancel(); let _ = running.get() }
        } finally { fixture.close() }
    }

    @TestCase
    func cancellingReadOnlyHttpAfterActualWriteRetainsBothUnknownReceipts(): Unit {
        let fixture = McpHttpProductFixture(mode: "hang", approval: ApprovalMode.AlwaysAsk, readOnlyTools: [serviceReadonlyTestLocalName()], askOnNetwork: false)
        try {
            @Expect(!managedCompleted(fixture.start("http-ro-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("http-ro-cancel")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("readonly-cancel", fixture.name, objectValue([]))
            let running = spawn { session.submit("Wait for the operator-declared read-only HTTP service.") }
            try {
                fixture.awaitCalls(1)
                lifecycleTestRequire(session.cancel())
                let _ = running.get()
                fixture.awaitClosed(3); fixture.waitReleased()
                @Expect(fixture.childReceipts("unknown"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 2)
                @Expect(!fixture.visible("http-ro-cancel"))
                @Expect(managedRejected(fixture.call("http-ro-cancel", "no-retry")))
                @Expect(fixture.calls(), 1)
                serviceReadonlyAssertPlans(fixture.database, fixture.name, HOST_HTTP_STREAM_TOOL, 1)
                fixture.assertNoSecrets()
            } finally { let _ = session.cancel(); let _ = running.get() }
        } finally { fixture.close() }
    }
}
