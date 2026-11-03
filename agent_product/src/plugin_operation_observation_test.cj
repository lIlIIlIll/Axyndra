package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func observationRootResult(database: SqliteDatabase, thread: String): AgentValue {
    for (item in SqliteThreadCommitSink(database).loadThread(ThreadId(thread)).items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(id, _, _, output, isError) =>
                if (id.value == "observed-call") {
                    if (!isError) { throw IllegalStateException("Unknown root was stored as successful") }
                    return output
                }
            case _ => ()
        }
    }
    throw IllegalStateException("actual canonical observed ToolResult is missing")
}

func observationProductContract(committed: Bool): Unit {
    let fixture = LifecycleManagerFixture(approval: if (committed) { ApprovalMode.AlwaysAsk } else { ApprovalMode.Yolo },
        completeCapabilities: true)
    let thread = if (committed) { "observation-model" } else { "observation-direct" }
    let actualHex = "7061727469616c20e99baa0a" // actual cat output: partial 雪\n
    var reopened: ?ProductRuntime = None
    try {
        let _ = lifecycleTestRequire(fixture.startProtocol(thread, thread + "-maintenance"))
        let input = channelTestInput(actualHex, mode: "unknown_after_read")
        if (committed) {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId(thread)))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("observed-call", fixture.name, input)
            lifecycleTestRequire(session.submit("Run the exact channel call after approval."))
            let approval = session.approval().getOrThrow()
            @Expect(channelTestHandoffs(fixture, thread), 0)
            let result = session.decide(approval.operationId.value, ApprovalDecision.Approve)
            @Expect(result.isError())
        } else {
            // The actual operator's Yolo policy admits this Direct call;
            // no model Decision or internal host-service origin is invented.
            let result = fixture.product.vnext.executeCanonicalTool(SessionId(thread), fixture.ceiling(),
                ToolCall("observed-call", fixture.name, input),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            @Expect(result.isError())
            if (result.isError()) { @Expect(result.error().getOrThrow().observation.isSome()) }
        }
        channelTestAwaitReleased(fixture)
        @Expect(channelTestChildren(fixture, thread, "completed"), 1)
        @Expect(channelTestHandoffs(fixture, thread), 1)
        let rows = fixture.database.query("SELECT receipt.id,receipt.detail,operation.retry_disposition " +
            "FROM operation_receipts receipt JOIN operations operation ON operation.id=receipt.operation_id " +
            "JOIN runs run ON run.id=operation.run_id WHERE run.thread_id=? AND receipt.outcome='unknown'",
            [SqlParameter.Text(thread)])
        @Expect(rows.size, 1)
        @Expect(rows[0].required(2), "never")
        let observed = decodeStoredValue(rows[0].required(1)).field("observation").getOrThrow()
        @Expect(lifecycleText(observed, "schema"), "axyndra.operation-observation/v1")
        @Expect(lifecycleText(observed, "trust"), "untrusted_data")
        @Expect(!observed.field("authorizes_effects").getOrThrow().asBool())
        let content = observed.field("content").getOrThrow()
        @Expect(lifecycleText(content, "status"), "unknown")
        @Expect(!content.field("retry_safe").getOrThrow().asBool())
        @Expect(lifecycleText(content, "error"), "channel_fixture.observed_unknown")
        let remote = content.field("result").getOrThrow()
        @Expect(lifecycleText(remote, "bytes_hex"), actualHex)
        let children = fixture.database.query("SELECT receipt.id FROM operation_receipts receipt " +
            "JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id " +
            "WHERE effect.tool_id=? AND receipt.outcome='completed'", [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)])
        @Expect(children.size, 1)
        @Expect(lifecycleText(remote, "receipt_id"), children[0].required(0))
        let output = observationRootResult(fixture.database, thread)
        @Expect(lifecycleText(output, "outcome"), "unknown")
        @Expect(output.field("reconciliation_required").getOrThrow().asBool())
        @Expect(canonicalAgentValue(output.field("error").getOrThrow().field("observation").getOrThrow()),
            canonicalAgentValue(observed))
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") > 0, committed)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
        @Expect(!fixture.visible(Some(ThreadId(thread))))
        let beforeOperations = fixture.database.scalarInt("SELECT COUNT(*) FROM operations")
        let beforeReceipts = fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
        let beforeDecisions = fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions")
        lifecycleTestRequire(fixture.manager.close())
        lifecycleTestRequire(fixture.processes.close())
        lifecycleTestRequire(fixture.product.close())
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: fixture.files.workspace,
            settingsRoot: fixture.files.settings, stateRoot: fixture.files.root + "/state", fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)))
        reopened = Some(product)
        let session = product.applicationSession(sessionId: Some(SessionId(thread)))
        let resumed = session.resumeStartup()
        // Reconciliation can reject startup, or startup can expose no resumable
        // model request. Neither permits a second dispatch of the old cell.
        if (resumed.isOk()) { @Expect(resumed.value().getOrThrow().isNone()) }
        let disk = SqliteDatabase(fixture.files.root + "/state/state.db")
        try {
            @Expect(canonicalAgentValue(observationRootResult(disk, thread)), canonicalAgentValue(output))
            let retained = disk.query("SELECT detail,outcome FROM operation_receipts WHERE id=?", [SqlParameter.Text(rows[0].required(0))])
            @Expect(retained.size, 1)
            @Expect(retained[0].required(0), rows[0].required(1))
            @Expect(retained[0].required(1), "unknown")
            @Expect(disk.scalarInt("SELECT COUNT(*) FROM operations"), beforeOperations)
            @Expect(disk.scalarInt("SELECT COUNT(*) FROM operation_receipts"), beforeReceipts)
            @Expect(disk.scalarInt("SELECT COUNT(*) FROM model_decisions"), beforeDecisions)
            // A canonical ToolResult already exists, so recovery must not
            // synthesize another dispatch or finalization action.
            @Expect(OperationRecoveryPlanner(disk).inspect(ThreadId(thread)).isEmpty())
            @Expect(disk.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='" + thread + "' AND state='recovery_required'"), 1)
            @Expect(disk.query("PRAGMA foreign_key_check").isEmpty())
        } finally { disk.close() }
        @Expect(product.pluginServiceStatuses().isEmpty())
        @Expect(managedRejected(product.vnext.executeCanonicalTool(SessionId(thread), fixture.ceiling(),
            ToolCall("new-id-cannot-resume-old-service", fixture.name, input))))
        @Expect(channelTestHandoffs(fixture, thread), 1)
    } finally {
        match (reopened) { case Some(value) => let _ = value.close(); case None => () }
        fixture.close()
    }
}

@Test
class PluginOperationObservationTests {
    @TestCase
    func directUnknownPersistsActualObservedBytesAndSurvivesProductReopen(): Unit {
        observationProductContract(false)
    }

    @TestCase
    func committedUnknownRetainsReceiptAndCanonicalToolResultWithoutReplay(): Unit {
        observationProductContract(true)
    }
}
