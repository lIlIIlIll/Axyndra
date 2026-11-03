package agent_product

import agent_domain.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual installed provider, actual committed ToolResult/Receipt and real
// post-canonical Store TX. No test constructs a Prepared plan or Root Source.
@Test
class InstalledCheckpointNativeSave11315Tests {
    @TestCase
    func actualDirectNativeSaveRetainsCompleteFragmentedUnicodeReport(): Unit {
        checkpointNativeSaveControl11315(true)
    }
    @TestCase
    func actualCoreNativeSaveRetainsCompleteFragmentedUnicodeReport(): Unit {
        checkpointNativeSaveControl11315(false)
    }
}

private func checkpointNativeSaveControl11315(direct: Bool): Unit {
    let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
    try {
        let session = f.product.applicationSession(sessionId: Some(f.session))
        let goal = "Investigate original 雪\u{0000} checkpoint."
        let report = " \tComplete 雪\u{0000} " + String.fromUtf8(Array<UInt8>(300000, repeat: b'x')) + " report tail\r\n "
        if (direct) {
            let checkpoint = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint", objectValue([ValueField("goal", textValue(goal))])).value().getOrThrow()
            try { @Expect(!checkpoint.isError) } finally { checkpoint.releasePayload() }
            let rewind = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind", objectValue([ValueField("report", textValue(report))])).value().getOrThrow()
            try { @Expect(!rewind.isError) } finally { rewind.releasePayload() }
        } else {
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("checkpoint-native-save11315", "plugin.axyndra:compaction.checkpoint", objectValue([ValueField("goal", textValue(goal))]))
            @Expect(session.submit("Create the exact real checkpoint.").isOk())
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("rewind-native-save11315", "plugin.axyndra:compaction.rewind", objectValue([ValueField("report", textValue(report))]))
            @Expect(session.submit("Commit the full actual investigation report.").isOk())
        }
        let saved = f.database.query("SELECT covers_through_item_ordinal,payload FROM context_checkpoints WHERE thread_id=?", [SqlParameter.Text(f.session.value)])
        @Expect(saved.size, 1)
        let payload = decodeStoredValue(saved[0].required(1))
        let projection = payload.field("structured_summary").getOrThrow()
        @Expect(projection.field("checkpoint_goal").getOrThrow().text, goal)
        @Expect(payload.field("active_goal").getOrThrow().text, goal)
        @Expect(projection.field("deterministic_summary").getOrThrow().text.endsWith("\n\nCheckpoint investigation report:\n" + report.trimAscii()))
        let canonical = f.database.query("SELECT i.ordinal,o.state,receipt.outcome,receipt.detail FROM operations o " +
            "JOIN operation_effect_records e ON e.operation_id=o.id " +
            "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
            "JOIN items i ON i.id=e.reserved_result_item_id AND i.kind='tool_result' WHERE i.thread_id=? ORDER BY i.ordinal", [SqlParameter.Text(f.session.value)])
        @Expect(canonical.size, 2)
        @Expect(saved[0].required(0), canonical[1].required(0))
        @Expect(decodeStoredValue(canonical[1].required(3)).field("report").getOrThrow().text, report.trimAscii())
        for (row in canonical) { @Expect(row.required(1), "committed"); @Expect(row.required(2), "completed") }
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
    } finally { f.close() }
}
