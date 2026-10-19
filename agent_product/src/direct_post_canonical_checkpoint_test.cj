package agent_product

import agent_domain.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Enter the actual installed Native policy through Product's Direct gateway.
// Tests never construct a DirectToolCallRef, normalized plan or Receipt.
@Test
class DirectPostCanonicalCheckpoint113Tests {
    @TestCase
    func actualDirectReceiptAndOriginalBudgetPrecedeRewindProjection(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let checkpoint = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("Investigate the Direct 雪 parser."))])).value().getOrThrow()
            try { @Expect(!checkpoint.isError) } finally { checkpoint.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            let rewind = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind",
                objectValue([ValueField("report", textValue("The Direct 雪 boundary is in decode()."))])).value().getOrThrow()
            try {
                @Expect(!rewind.isError)
                let saved = f.database.query("SELECT covers_through_item_ordinal,payload FROM context_checkpoints WHERE thread_id=?",
                    [SqlParameter.Text(f.session.value)])
                @Expect(saved.size, 1)
                let value = decodeStoredValue(saved[0].required(1)).field("structured_summary").getOrThrow()
                @Expect(value.field("checkpoint_goal").getOrThrow().text, "Investigate the Direct 雪 parser.")
                @Expect(value.field("rewind_call_id").getOrThrow().text, rewind.callId)
                @Expect(value.field("deterministic_summary").getOrThrow().text.contains(
                    "Checkpoint investigation report:\nThe Direct 雪 boundary is in decode()."))
                let canonical = f.database.query("SELECT i.ordinal,o.state,receipt.outcome,r.budget FROM operations o " +
                    "JOIN operation_effect_records e ON e.operation_id=o.id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
                    "JOIN items i ON i.id=e.reserved_result_item_id AND i.kind='tool_result' " +
                    "JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? ORDER BY i.ordinal", [SqlParameter.Text(f.session.value)])
                @Expect(canonical.size, 2)
                @Expect(saved[0].required(0), canonical[1].required(0))
                for (row in canonical) {
                    @Expect(row.required(1), "committed"); @Expect(row.required(2), "completed")
                    let budget = decodeStoredValue(row.required(3))
                    @Expect(budget.field("run_kind").getOrThrow().text, "direct_tool")
                    @Expect(budget.field("max_concurrent_tools").getOrThrow().asNumberText(), "1")
                }
            } finally { rewind.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func realProjectionTriggerCannotChangeTheAlreadyKnownDirectReceipt(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let checkpoint = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("Keep the original known Receipt."))])).value().getOrThrow()
            checkpoint.releasePayload()
            f.database.execute("CREATE TRIGGER checkpoint_receipt_mutate1138 AFTER INSERT ON context_checkpoints BEGIN " +
                "UPDATE operation_receipts SET outcome='unknown' WHERE operation_id IN (" +
                "SELECT e.operation_id FROM operation_effect_records e JOIN items i ON i.id=e.reserved_result_item_id " +
                "WHERE i.thread_id=NEW.thread_id AND i.ordinal=NEW.covers_through_item_ordinal); END")
            @Expect(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind", objectValue([
                ValueField("report", textValue("The canonical investigation must stay completed."))])).isError())
            // The new projection TX rolls back its own trigger mutation. The
            // earlier canonical TX is immutable and no Native effect reruns.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            f.database.execute("DROP TRIGGER checkpoint_receipt_mutate1138")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        } finally { f.close() }
    }

    @TestCase
    func realDirectBudgetSubstitutionCannotPublishTheDisposableProjection(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let checkpoint = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("Use the original Direct ledger."))])).value().getOrThrow()
            checkpoint.releasePayload()
            let changed = encodeStoredValue(objectValue([
                ValueField("run_kind", textValue("direct_tool")), ValueField("read_only", boolValue(false)),
                ValueField("max_tool_calls", integerValue(1000)), ValueField("max_concurrent_tools", integerValue(1)),
                ValueField("deadline_millis", integerValue(0))]))
            f.database.execute("CREATE TRIGGER checkpoint_budget_mutate1138 AFTER INSERT ON context_checkpoints BEGIN " +
                "UPDATE runs SET budget=" + sqliteText(changed) + " WHERE id IN (SELECT e.run_id " +
                "FROM operation_effect_records e JOIN items i ON i.id=e.reserved_result_item_id " +
                "WHERE i.thread_id=NEW.thread_id AND i.ordinal=NEW.covers_through_item_ordinal); END")
            @Expect(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind", objectValue([
                ValueField("report", textValue("The original charged ledger must be kept."))])).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE CAST(budget AS BLOB)=CAST(" + sqliteText(changed) + " AS BLOB)"), 0)
            f.database.execute("DROP TRIGGER checkpoint_budget_mutate1138")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        } finally { f.close() }
    }
}
