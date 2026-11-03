package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func seedActualCompletedForkCheckpoint173d2(f: CompactionPolicyFixture): Unit {
    let session = f.product.applicationSession(sessionId: Some(f.session))
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("fork-checkpoint173d2", "plugin.axyndra:compaction.checkpoint",
        objectValue([ValueField("goal", textValue("Actual checkpoint before a legal SQL trigger"))]))
    @Expect(session.submit("Create the genuine completed checkpoint.").isOk())
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("fork-rewind173d2", "plugin.axyndra:compaction.rewind",
        objectValue([ValueField("report", textValue("Whole original report 雪🙂\u{0} tail"))]))
    @Expect(session.submit("Commit the genuine original report.").isOk())
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
}

class ForkPostconditionConsumer173d2 { var value: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113> }

@Test
class CompletedForkPaidPostcondition173d2Tests {
    @TestCase
    func actualSixteenMiBTriggerColumnsRejectByFullSqlEqualityWithoutReadingThemIntoCj173d2(): Unit {
        // The original Native Root pays the complete real SQLite fixture
        // construction/transient SUM before these actual INSERT triggers run.
        // No new owner, capacity, smaller test payload or fake database exists.
        for (mode in ["lane", "budget", "item", "copied_checkpoint", "source_checkpoint"]) {
            let f = CompactionPolicyFixture()
            let session = f.product.applicationSession(sessionId: Some(f.session))
            let capture = ForkPostconditionConsumer173d2()
            let oracle = reserveNativeControlMetadata(67108864)
            try {
                seedActualCompletedForkCheckpoint173d2(f)
                let operations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
                let receipts = f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
                let attempts = f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
                let sourceCells = f.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id=" + sqliteText(f.session.value))
                let sourceCheckpoints = f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints WHERE thread_id=" + sqliteText(f.session.value))
                // Exactly 16 MiB of ASCII plus two quote bytes; a valid JSON
                // value well beyond the original 8 MiB Store cell boundary.
                // Its bytes are generated in actual SQLite, never in a Cj
                // snapshot or mock target reader. All comparison results below
                // are COUNT/fixed scalars while this paid fixture frame lives.
                let giant = "char(34)||hex(zeroblob(8388608))||char(34)"
                let mutation = if (mode == "lane" || mode == "budget") {
                    "UPDATE runs SET " + (if (mode == "lane") { "lane_snapshot" } else { "budget" }) + "=" + giant +
                        " WHERE thread_id='amplified-fork173d2';"
                } else if (mode == "item") {
                    "UPDATE items SET payload=" + giant + " WHERE id=NEW.id;"
                } else if (mode == "copied_checkpoint") {
                    "UPDATE context_checkpoints SET payload=" + giant + " WHERE id=NEW.id;"
                } else {
                    "UPDATE context_checkpoints SET payload=" + giant + " WHERE thread_id=" + sqliteText(f.session.value) + ";"
                }
                let table = if (mode == "item") { "items" } else { "context_checkpoints" }
                f.database.execute("CREATE TRIGGER amplifiedActualFork173d2 AFTER INSERT ON " + table +
                    " WHEN NEW.thread_id='amplified-fork173d2' BEGIN " + mutation + " END")
                let result = f.product.forkSession(f.session, SessionId("amplified-fork173d2"))
                @Expect(result.isError())
                let marker = result.error().getOrThrow()
                @Expect(session.admitOwnedCheckpointFailure113(marker, { value =>
                    let actual = match (value) { case OwnedAgentRunResult113.Pending(actual) => actual
                        case _ => throw IllegalStateException("historical copy does not create a new canonical Run") }
                    capture.value = Some(actual)
                    @Expect(actual.withError({ error, _ =>
                        @Expect(error.kind, if (mode == "item") { AgentErrorKind.Conflict } else { AgentErrorKind.RecoveryRequired })
                        @Expect(error.code, if (mode == "item") { "thread.seed_failed" } else { "context.checkpoint_commit_failed" })
                        @Expect(error.message, if (mode == "item") { "completed seed Item changed" }
                            else if (mode == "lane" || mode == "budget") { "completed seed Run changed" }
                            else if (mode == "copied_checkpoint") { "checkpoint id already has different content" }
                            else { "checkpoint source changed after its copy" })
                        @Expect(!error.retryable && !error.fallbackAllowed)
                        @Expect(error.fields.size, if (mode == "item") { 1 } else { 0 })
                        if (mode == "item") { @Expect(error.fields[0].value, "amplified-fork173d2") }
                        @Expect(error.attemptFailure.isNone() && error.observation.isNone())
                        @Expect(actual.acknowledgeAfterConsumption().isError())
                    }).isOk())
                    false }))
                @Expect(!capture.value.getOrThrow().isAcknowledged())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='amplified-fork173d2'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), receipts)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), attempts)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id=" + sqliteText(f.session.value)), sourceCells)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints WHERE thread_id=" + sqliteText(f.session.value)), sourceCheckpoints)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints WHERE thread_id=" + sqliteText(f.session.value) +
                    " AND length(CAST(payload AS BLOB))>8388608"), 0)
                @Expect(session.admitOwnedCheckpointFailure113(marker, { value =>
                    let actual = match (value) { case OwnedAgentRunResult113.Pending(actual) => actual
                        case _ => throw IllegalStateException("historical copy has no new Run") }
                    @Expect(refEq(actual, capture.value.getOrThrow())); true }))
                @Expect(capture.value.getOrThrow().acknowledgeAfterConsumption().isOk())
                capture.value = None<OwnedFailureDataConsumer113>
                session.collectOwnedCheckpointFailure113()
                @Expect(!session.hasOwnedCheckpointFailure113(marker))
            } finally {
                match (capture.value) { case Some(value) => let _ = value.acknowledgeAfterConsumption(); case None => () }
                capture.value = None<OwnedFailureDataConsumer113>; session.collectOwnedCheckpointFailure113()
                oracle.close(); f.close()
            }
        }
    }
}
