package agent_product

import agent_domain.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Every control enters the actual installed Native executor. The mutation is
// AFTER the disposable checkpoint INSERT in its actual SQL transaction. No
// test supplies a Root, Prepared plan, Receipt or synthetic completion.
@Test
class PostCanonicalCheckpointIntegrity11314Tests {
    @TestCase
    func actualCoreReceiptDetailSubstitutionCannotPublishProjection(): Unit {
        checkpointIntegrityControl11314(false, false)
    }

    @TestCase
    func actualDirectReceiptDetailSubstitutionCannotPublishProjection(): Unit {
        checkpointIntegrityControl11314(true, false)
    }

    @TestCase
    func actualCoreEqualSqlPlanCopiesCannotReplaceOriginalBinding(): Unit {
        checkpointIntegrityControl11314(false, true)
    }

    @TestCase
    func actualDirectEqualSqlPlanCopiesCannotReplaceOriginalBinding(): Unit {
        checkpointIntegrityControl11314(true, true)
    }
}

private func checkpointIntegrityControl11314(direct: Bool, changePlan: Bool): Unit {
    let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
    try {
        let session = f.product.applicationSession(sessionId: Some(f.session))
        let goal = objectValue([ValueField("goal", textValue("Retain the complete actual invocation."))])
        if (direct) {
            let first = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint", goal).value().getOrThrow()
            try { @Expect(!first.isError) } finally { first.releasePayload() }
        } else {
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("checkpoint-integrity-core11314", "plugin.axyndra:compaction.checkpoint", goal)
            @Expect(session.submit("Create the exact original checkpoint.").isOk())
        }
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
        let target = "SELECT e.operation_id FROM operation_effect_records e JOIN items i " +
            "ON i.id=e.reserved_result_item_id WHERE i.thread_id=NEW.thread_id " +
            "AND i.ordinal=NEW.covers_through_item_ordinal"
        let replacement = encodeStoredValue(objectValue([
            ValueField("report", textValue("A different valid completed output 雪."))]))
        let marker = "6:digests64:"
        let zeros = "0000000000000000000000000000000000000000000000000000000000000000"
        if (changePlan) {
            // The original real normalizer supplies the complete SHA binding.
            // Change only its 64 data bytes; StoredValue framing and all other
            // fields remain valid, and BOTH SQL plan copies stay equal.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE instr(normalized_plan," +
                sqliteText(marker) + ")>0"), 1)
            let changed = "substr(normalized_plan,1,instr(normalized_plan," + sqliteText(marker) +
                ")+length(" + sqliteText(marker) + ")-1)||" + sqliteText(zeros) +
                "||substr(normalized_plan,instr(normalized_plan," + sqliteText(marker) +
                ")+length(" + sqliteText(marker) + ")+64)"
            f.database.execute("CREATE TRIGGER checkpoint_integrity11314 AFTER INSERT ON context_checkpoints BEGIN " +
                "UPDATE operations SET normalized_plan=" + changed + " WHERE id IN (" + target + "); " +
                "UPDATE operation_effect_records SET normalized_plan=(SELECT o.normalized_plan FROM operations o " +
                "WHERE o.id=operation_effect_records.operation_id) WHERE operation_id IN (" + target + "); END")
        } else {
            f.database.execute("CREATE TRIGGER checkpoint_integrity11314 AFTER INSERT ON context_checkpoints BEGIN " +
                "UPDATE operation_receipts SET detail=" + sqliteText(replacement) +
                " WHERE operation_id IN (" + target + "); END")
        }
        let report = objectValue([ValueField("report", textValue("The original investigation has a known result."))])
        if (direct) {
            @Expect(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind", report).isError())
        } else {
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("rewind-integrity-core11314", "plugin.axyndra:compaction.rewind", report)
            @Expect(session.submit("Commit the real result before saving its projection.").isError())
        }
        // The canonical transaction precedes this projection transaction. Its
        // known result stays committed; no second invocation or retry occurs.
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE CAST(detail AS BLOB)=CAST(" +
            sqliteText(replacement) + " AS BLOB)"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE instr(normalized_plan," +
            sqliteText(marker + zeros) + ")>0"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE instr(normalized_plan," +
            sqliteText(marker + zeros) + ")>0"), 0)
        f.database.execute("DROP TRIGGER checkpoint_integrity11314")
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
    } finally { f.close() }
}
