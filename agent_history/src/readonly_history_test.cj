package agent_history

import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MinimalReadOnlyHistoryTests {
    @TestCase
    func readonlyConnectionObservesCurrentWalAndCannotMutateCanonicalFacts(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let path = root + "/state.db"
        let writer = SqliteDatabase(path)
        try {
            seedInspectionRun(writer)
            let reader = SqliteDatabase(path, readOnly: true)
            try {
                @Expect(reader.scalarInt("PRAGMA query_only") == 1)
                let projection = RunInspectionProjection(reader)
                @Expect(projection.latestRunId(ThreadId("inspection-thread")).value().getOrThrow().value == "inspection-run")
                @Expect(projection.inspect(ThreadId("inspection-thread"), RunId("inspection-run"), 0, 10).isOk())
                writer.execute("UPDATE threads SET revision=revision+1 WHERE id='inspection-thread'")
                @Expect(reader.scalarInt("SELECT revision FROM threads WHERE id='inspection-thread'") == 2)
                var rejected = false
                try { reader.execute("DELETE FROM runs") } catch (_: Exception) { rejected = true }
                @Expect(rejected && writer.scalarInt("SELECT COUNT(*) FROM runs") == 1)
                @Expect(projection.inspect(ThreadId("foreign-thread"), RunId("inspection-run"), 0, 10).isError())
                @Expect(projection.inspect(ThreadId("inspection-thread"), RunId("inspection-run"), 0, 101).isError())
            } finally { reader.close() }
        } finally { writer.close(); remove(root, recursive: true) }
    }

    @TestCase
    func historyOpenNeverCreatesMissingDatabaseOrItsParent(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        try {
            var rejected = false
            try { let reader = SqliteDatabase(root + "/missing/state.db", readOnly: true); reader.close() }
            catch (_: Exception) { rejected = true }
            @Expect(rejected && !exists(Path(root + "/missing")))
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func readonlyFutureSchemaLeavesItsBytesAndVersionUntouched(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let path = root + "/state.db"
        let writer = SqliteDatabase(path)
        try {
            seedInspectionRun(writer)
            writer.execute("PRAGMA user_version=999")
            let reader = SqliteDatabase(path, readOnly: true)
            try {
                @Expect(reader.scalarInt("PRAGMA user_version") == 999)
                @Expect(RunInspectionProjection(reader).latestRunId(ThreadId("inspection-thread")).isOk())
                @Expect(reader.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0)
            } finally { reader.close() }
            @Expect(writer.scalarInt("PRAGMA user_version") == 999)
            @Expect(writer.scalarInt("SELECT COUNT(*) FROM runs") == 1)
        } finally { writer.close(); remove(root, recursive: true) }
    }
}
