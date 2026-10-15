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

    @TestCase
    func actualCoreSemanticArgumentsCannotReplaceFrozenCallData(): Unit {
        checkpointSemanticArgumentControl11314()
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
        let marker = "6:digests"
        // The real Store plan codec frames the binding digest as the key
        // "digest" followed by the string form "s<decimal length>:<decimal
        // digits>". The original approval hash is a decimal UInt64, so its
        // width varies; a fixed 64-character hexadecimal assumption is wrong.
        let afterMarker = "(instr(normalized_plan," + sqliteText(marker) + ")+length(" +
            sqliteText(marker) + "))"
        let lengthColon = "instr(substr(normalized_plan," + afterMarker + "),':')"
        let digitsStart = "(" + afterMarker + "+" + lengthColon + ")"
        let digitCount = "CAST(substr(normalized_plan," + afterMarker + "," + lengthColon + "-1) AS INTEGER)"
        let zeros = "substr(" +
            sqliteText("0000000000000000000000000000000000000000000000000000000000000000") +
            ",1," + digitCount + ")"
        if (changePlan) {
            // The original real normalizer supplies the complete binding. Change
            // only its digest digits, keeping the declared length and every other
            // field intact, so BOTH SQL plan copies stay equal in length and shape.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE " + digitCount + " BETWEEN 1 AND 20"), 1)
            let changed = "substr(normalized_plan,1," + digitsStart + "-1)||" + zeros +
                "||substr(normalized_plan," + digitsStart + "+" + digitCount + ")"
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
        // No surviving plan may carry an all-zero binding digest: that is the
        // exact shape the real trigger tries to plant, so its absence proves the
        // canonical Store rejected the whole corrupted projection.
        let corruptedDigest = "(instr(normalized_plan," + sqliteText(marker) + ")>0 AND substr(normalized_plan," +
            digitsStart + "," + digitCount + ")=" + zeros + ")"
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE " + corruptedDigest), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE " + corruptedDigest), 0)
        f.database.execute("DROP TRIGGER checkpoint_integrity11314")
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
    } finally { f.close() }
}

private func checkpointSemanticArgumentControl11314(): Unit {
    let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
    try {
        let session = f.product.applicationSession(sessionId: Some(f.session))
        let goal = objectValue([ValueField("goal", textValue("Retain the original semantic call data."))])
        f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("checkpoint-semantic-original11314",
            "plugin.axyndra:compaction.checkpoint", goal)
        @Expect(session.submit("Create the actual checkpoint owner.").isOk())
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
        let report = objectValue([ValueField("report", textValue("The frozen semantic report remains original 雪."))])
        let originalArguments = encodeStoredValue(report)
        let substitutedArguments = encodeStoredValue(objectValue([
            ValueField("report", textValue("A different valid semantic report replaces only history 雨."))]))
        // The actual executor/Root commits its known result. Change only the
        // preceding call's semantic DATA at that INSERT, before checkpoint
        // readback/digest calculation; both complete plan copies stay original.
        // Replacing a complete encoded value preserves nested byte framing.
        f.database.execute("CREATE TRIGGER checkpoint_semantic_arguments11314 AFTER INSERT ON items " +
            "WHEN NEW.kind='tool_result' BEGIN UPDATE items SET payload=replace(payload," +
            sqliteText(originalArguments) + "," + sqliteText(substitutedArguments) + ") " +
            "WHERE thread_id=NEW.thread_id AND id IN (SELECT tool_call_item_id FROM operation_effect_records " +
            "WHERE reserved_result_item_id=NEW.id); END")
        f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("rewind-semantic-substitution11314",
            "plugin.axyndra:compaction.rewind", report)
        @Expect(session.submit("Commit the known result without accepting substituted call data.").isError())
        // This mutation belongs to the earlier canonical transaction, not the
        // disposable projection. Prove the changed call is present while the
        // original plan and both known completions survive without replay.
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call' AND instr(payload," +
            sqliteText(substitutedArguments) + ")>0"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE instr(normalized_plan," +
            sqliteText(originalArguments) + ")>0"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE instr(normalized_plan," +
            sqliteText(originalArguments) + ")>0"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE instr(normalized_plan," +
            sqliteText(substitutedArguments) + ")>0"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations o JOIN operation_effect_records e " +
            "ON e.operation_id=o.id WHERE CAST(o.normalized_plan AS BLOB)=CAST(e.normalized_plan AS BLOB)"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        f.database.execute("DROP TRIGGER checkpoint_semantic_arguments11314")
    } finally { f.close() }
}
