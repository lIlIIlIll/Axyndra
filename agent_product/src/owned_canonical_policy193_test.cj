package agent_product

import agent_domain.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real installed Native calls, original Direct admission and real SQLite.
// The scalar observes only independent public metadata exports. It neither
// acknowledges arbitrary result aliases nor claims a whole-bank baseline.
private func actualCanonicalCallFrame193(f: CompactionPolicyFixture, tool: String,
    field: String, text: String): Unit {
    let result = lifecycleTestRequire(f.product.invokeLocalTool(f.session, tool,
        objectValue([ValueField(field, textValue(text))])))
    try {
        @Expect(!result.isError)
        @Expect(result.output.field(field).getOrThrow().text, text)
    } finally { result.releasePayload() }
}

@Test
class OwnedCanonicalPolicy193Tests {
    @TestCase
    func actualNativeProjectionKeepsFullProvenanceWithoutPublicMetadataExports(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let host = f.product.vnext.javascriptPlugins
            let before = host.canonicalProjectionPublicTextDebtCount193()
            actualCanonicalCallFrame193(f, "plugin.axyndra:compaction.checkpoint", "goal", "Preserve private 雪 policy metadata.")
            @Expect(host.canonicalProjectionPublicTextDebtCount193(), before)
            actualCanonicalCallFrame193(f, "plugin.axyndra:compaction.rewind", "report", "Verified the actual private Native policy route.")
            @Expect(host.canonicalProjectionPublicTextDebtCount193(), before)
            let saved = f.database.query("SELECT payload,covers_through_item_ordinal FROM context_checkpoints WHERE thread_id=?",
                [SqlParameter.Text(f.session.value)])
            @Expect(saved.size, 1)
            let summary = decodeStoredValue(saved[0].required(0)).field("structured_summary").getOrThrow()
            @Expect(summary.field("checkpoint_goal").getOrThrow().text, "Preserve private 雪 policy metadata.")
            @Expect(summary.field("deterministic_summary").getOrThrow().text.contains(
                "Checkpoint investigation report:\nVerified the actual private Native policy route."))
            let rows = f.database.query("SELECT o.normalized_plan,o.state,r.outcome,i.ordinal,r.id FROM operations o " +
                "JOIN operation_effect_records e ON e.operation_id=o.id " +
                "JOIN operation_receipts r ON r.id=e.reserved_receipt_id AND r.operation_id=o.id " +
                "JOIN items i ON i.id=e.reserved_result_item_id ORDER BY i.ordinal")
            @Expect(rows.size, 2)
            @Expect(saved[0].required(1), rows[1].required(3))
            @Expect(rows[0].required(4) != rows[1].required(4))
            for (row in rows) { @Expect(row.required(1), "committed"); @Expect(row.required(2), "completed") }
            let binding = decodeStoredValue(rows[1].required(0)).field("arguments").getOrThrow().field("projection_binding").getOrThrow()
            let provenance = summary.field("structured_policy").getOrThrow()
            @Expect(httpIntentExactFields(provenance, ["namespace", "provider", "package_digest",
                "configuration_digest", "source_projection_digest", "authoritative"]))
            for (name in ["namespace", "provider", "package_digest", "configuration_digest"]) {
                @Expect(provenance.field(name).getOrThrow().text, binding.field(name).getOrThrow().text)
            }
            @Expect(provenance.field("namespace").getOrThrow().text, "axyndra:compaction")
            @Expect(provenance.field("provider").getOrThrow().text, "summarize")
            @Expect(!provenance.field("authoritative").getOrThrow().asBool())
            @Expect(provenance.field("source_projection_digest").getOrThrow().text.startsWith("sha256:"))
            @Expect(provenance.field("source_projection_digest").getOrThrow().text.size, 71)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualReceiptMutationStillRollsBackWithoutExportingPrivateMetadata(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let host = f.product.vnext.javascriptPlugins
            let before = host.canonicalProjectionPublicTextDebtCount193()
            actualCanonicalCallFrame193(f, "plugin.axyndra:compaction.checkpoint", "goal", "Keep the original completed Receipt.")
            f.database.execute("CREATE TRIGGER canonical_policy_receipt193 AFTER INSERT ON context_checkpoints BEGIN " +
                "UPDATE operation_receipts SET outcome='unknown' WHERE operation_id IN (" +
                "SELECT e.operation_id FROM operation_effect_records e JOIN items i ON i.id=e.reserved_result_item_id " +
                "WHERE i.thread_id=NEW.thread_id AND i.ordinal=NEW.covers_through_item_ordinal); END")
            @Expect(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind", objectValue([
                ValueField("report", textValue("Reject mutated canonical evidence without rerunning Native effects."))])).isError())
            @Expect(host.canonicalProjectionPublicTextDebtCount193(), before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            f.database.execute("DROP TRIGGER canonical_policy_receipt193")
        } finally { f.close() }
    }
}
