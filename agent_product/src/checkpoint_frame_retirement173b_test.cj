package agent_product

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual installed Native, real Pipeline and real SQLite. No test creates
// Prepared/Source/Receipt or calls the frame-retirement callback itself.
private func mountedDirectResultFrame173b(f: CompactionPolicyFixture): Int64 {
    let result = lifecycleTestRequire(f.product.invokeLocalTool(f.session,
        "plugin.axyndra:compaction.checkpoint", objectValue([ValueField("goal", textValue("frame雪\u{0}"))])))
    try {
        @Expect(!result.isError)
        @Expect(result.output.field("goal").getOrThrow().text, "frame雪\u{0}")
        @Expect(result.output.field("content").getOrThrow().text,
            "Checkpoint created.\nGoal: frame雪\u{0}\nRun your investigation, then call rewind with a concise report.")
        // Empty error-cell metadata is gone; actual result remains paid.
        @Expect(f.product.vnext.javascriptPlugins.canonicalProjectionExecutionCellCount173(), 0)
        nativeControlMetadataUsage113()[1]
    } finally { result.releasePayload() }
}
@Test
class MountedExecutionFrameRetirement173bTests {
    @TestCase
    func actualDirectFrameRetiresOnlyEmptyCellWhileResultHasIndependentCallerLease173b(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        try {
            let retainedResultPeak = mountedDirectResultFrame173b(f)
            // The entire real result consumer/helper has now returned.
            @Expect(nativeControlMetadataUsage113()[1] < retainedResultPeak)
            @Expect(f.product.vnext.javascriptPlugins.canonicalProjectionExecutionCellCount173(), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }
    @TestCase
    func actualCoreCompletedCheckpointAndRewindCannotAccumulateEmptyExecutionCells173b(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let session = f.product.applicationSession(sessionId: Some(f.session))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("core-checkpoint173b",
                "plugin.axyndra:compaction.checkpoint", objectValue([ValueField("goal", textValue("fullframe雪"))]))
            @Expect(session.submit("Create the original canonical checkpoint.").isOk())
            @Expect(f.product.vnext.javascriptPlugins.canonicalProjectionExecutionCellCount173(), 0)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("core-rewind173b",
                "plugin.axyndra:compaction.rewind", objectValue([ValueField("report", textValue("whole helper returned雪"))]))
            @Expect(session.submit("Finish with the canonical report.").isOk())
            @Expect(f.product.vnext.javascriptPlugins.canonicalProjectionExecutionCellCount173(), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        } finally { f.close() }
    }
}
