package agent_product

import agent_domain.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These controls enter the actual Core through ApplicationSession.submit.
// The fixture provider proposes ToolCalls; the kernel creates their real
// decisions, operation plans, Receipts, ToolResults and BudgetUpdated events.
// No test DTO supplies a cut, Root Source or completed operation.
@Test
class PostCanonicalCheckpoint113Tests {
    @TestCase
    func actualCoreBudgetAndCanonicalReceiptPrecedeInstalledRewindProjection(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let session = f.product.applicationSession(sessionId: Some(f.session))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 0)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("checkpoint-core1135", "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("Investigate the 雪 parser boundary."))]))
            @Expect(session.submit("Create the exact checkpoint before investigation.").isOk())
            @Expect(session.approval().isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events WHERE json_valid(payload)=1 " +
                "AND json_extract(payload,'$.payload_type')='budget_updated'" ) > 0)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("rewind-core1135", "plugin.axyndra:compaction.rewind",
                objectValue([ValueField("report", textValue("The 雪 parser boundary is in decode()."))]))
            @Expect(session.submit("Finish the investigation with this exact report.").isOk())
            @Expect(session.approval().isNone())
            let saved = f.database.query("SELECT covers_through_item_ordinal,source_digest,payload FROM context_checkpoints " +
                "WHERE thread_id=?", [SqlParameter.Text(f.session.value)])
            @Expect(saved.size, 1)
            let checkpoint = decodeStoredValue(saved[0].required(2))
            let summary = checkpoint.field("structured_summary").getOrThrow()
            @Expect(summary.field("checkpoint_goal").getOrThrow().text, "Investigate the 雪 parser boundary.")
            @Expect(summary.field("rewind_call_id").getOrThrow().text, "rewind-core1135")
            @Expect(summary.field("deterministic_summary").getOrThrow().text.contains(
                "Checkpoint investigation report:\nThe 雪 parser boundary is in decode()."))
            let roots = f.database.query("SELECT o.state,receipt.outcome,result.ordinal FROM operations o " +
                "JOIN operation_effect_records e ON e.operation_id=o.id " +
                "JOIN operation_receipts receipt ON receipt.id=e.reserved_receipt_id AND receipt.operation_id=o.id " +
                "JOIN items result ON result.id=e.reserved_result_item_id AND result.kind='tool_result' " +
                "JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? ORDER BY result.ordinal",
                [SqlParameter.Text(f.session.value)])
            @Expect(roots.size, 2)
            for (row in roots) { @Expect(row.required(0), "committed"); @Expect(row.required(1), "completed") }
            @Expect(saved[0].required(0), roots[1].required(2))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
        } finally { f.close() }
    }

    @TestCase
    func realPostCanonicalSqlFailureCannotRollbackOrReplayTheKnownTool(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let session = f.product.applicationSession(sessionId: Some(f.session))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("checkpoint-before-abort1135", "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("Keep canonical exploration immutable."))]))
            @Expect(session.submit("Create the investigation checkpoint.").isOk())
            f.database.execute("CREATE TRIGGER checkpoint_abort1135 BEFORE INSERT ON context_checkpoints " +
                "BEGIN SELECT RAISE(ABORT,'post-canonical checkpoint control'); END")
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("rewind-known-before-abort1135", "plugin.axyndra:compaction.rewind",
                objectValue([ValueField("report", textValue("The original investigation is already complete."))]))
            @Expect(session.submit("Complete the report; projection persistence will fail.").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events WHERE json_valid(payload)=1 " +
                "AND json_extract(payload,'$.payload_type')='budget_updated'") > 0)
            // No second submit, no effect replay and no rewritten Receipt.
            f.database.execute("DROP TRIGGER checkpoint_abort1135")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        } finally { f.close() }
    }

    @TestCase
    func sameTransactionWrittenDigestMutationRollsBackOnlyTheDisposableProjection(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let session = f.product.applicationSession(sessionId: Some(f.session))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("checkpoint-before-mutate1135", "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("Bind the exact canonical prefix."))]))
            @Expect(session.submit("Create the exact source-bound checkpoint.").isOk())
            f.database.execute("CREATE TRIGGER checkpoint_mutate1135 AFTER INSERT ON context_checkpoints " +
                "BEGIN UPDATE context_checkpoints SET source_digest='changed-during-insert' WHERE id=NEW.id; END")
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("rewind-before-mutate1135", "plugin.axyndra:compaction.rewind",
                objectValue([ValueField("report", textValue("The canonical result must remain known."))]))
            @Expect(session.submit("Persist the result while the projection is independently corrupted.").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
            f.database.execute("DROP TRIGGER checkpoint_mutate1135")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        } finally { f.close() }
    }
}
