package agent_product

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

class PluginDocumentResetFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let documents: SqlitePluginDocumentRepository
    init() {
        let directory = pluginContractTemp("plugin-document-reset")
        let opened = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: directory,
            settingsRoot: directory + "/settings", stateRoot: directory + "/state", fixture: true)))
        let connection = try { SqliteDatabase(directory + "/state/state.db") }
            catch (error: Exception) { let _ = opened.close(); remove(directory, recursive: true); throw error }
        this.root = directory; this.product = opened; this.database = connection
        this.documents = SqlitePluginDocumentRepository(connection)
    }
    func seed(): Array<PluginDocumentSnapshot> {
        let values = Array<PluginDocumentSnapshot>(2, { index =>
            let prior = lifecycleTestRequire(documents.read(ThreadId("reset-thread"),
                LaneId(if (index == 0) { "main" } else { "branch" }),
                if (index == 0) { "axyndra:workflow" } else { "other:plugin" }, "state"))
            lifecycleTestRequire(documents.compareExchange(prior, textValue(if (index == 0) { "preserved 雪" } else { "other namespace" }),
                { _ => Result<Unit>.Ok(()) }))
        })
        lifecycleTestRequire(SqliteSessionMetadataRepository(database).setName(SessionId("reset-thread"), "archived metadata"))
        values
    }
    func assertSame(values: Array<PluginDocumentSnapshot>, connection: SqliteDatabase): Unit {
        let stored = SqlitePluginDocumentRepository(connection)
        for (value in values) {
            let actual = lifecycleTestRequire(stored.read(value.threadId, value.laneId, value.namespace, value.key))
            @Expect(actual.revision, value.revision); @Expect(actual.encoded, value.encoded)
        }
    }
    func close(): Unit { database.close(); lifecycleTestRequire(product.close()); remove(root, recursive: true) }
}

@Test
class PluginDocumentResetTests {
    @TestCase
    func actualProductArchivesEveryDocumentThenClearsLiveRowsAndOldRevision(): Unit {
        let f = PluginDocumentResetFixture()
        try {
            let values = f.seed()
            lifecycleTestRequire(f.product.archiveAndReset("documents"))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata"), 0)
            let archive = SqliteDatabase(f.root + "/state/archives/documents.state.db")
            try { f.assertSame(values, archive); @Expect(archive.scalarInt("SELECT COUNT(*) FROM thread_metadata"), 1) }
            finally { archive.close() }
            let first = values[0]
            let fresh = lifecycleTestRequire(f.documents.read(first.threadId, first.laneId, first.namespace, first.key))
            @Expect(fresh.revision, 0); @Expect(fresh.encoded, "null")
            @Expect(f.documents.compareExchange(first, textValue("stale pre-reset write"), { _ => Result<Unit>.Ok(()) }).isError())
        } finally { f.close() }
    }
    @TestCase
    func failedArchiveDoesNotDeleteAnyLiveDocument(): Unit {
        let f = PluginDocumentResetFixture()
        try {
            let values = f.seed()
            Directory.create(f.root + "/state/archives", recursive: true)
            let blocked = f.root + "/state/archives/blocked.state.db"
            File.writeTo(blocked, "existing nonempty archive is never overwritten".toArray())
            let outcome = f.product.archiveAndReset("blocked")
            @Expect(outcome.isError()); @Expect(outcome.error().getOrThrow().code, "persistence.sqlite_reset_failed")
            f.assertSame(values, f.database)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata"), 1)
            @Expect(String.fromUtf8(File.readFrom(blocked)), "existing nonempty archive is never overwritten")
        } finally { f.close() }
    }
    @TestCase
    func documentDeleteFailureRollsBackWholeLiveResetButKeepsCompletedArchive(): Unit {
        let f = PluginDocumentResetFixture()
        try {
            let values = f.seed()
            f.database.execute("CREATE TRIGGER fixture_document_reset_failure BEFORE DELETE ON plugin_documents BEGIN SELECT RAISE(ABORT,'document reset fault'); END")
            let outcome = f.product.archiveAndReset("rollback")
            @Expect(outcome.isError()); @Expect(outcome.error().getOrThrow().code, "persistence.sqlite_reset_failed")
            f.assertSame(values, f.database)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata"), 1)
            let archive = SqliteDatabase(f.root + "/state/archives/rollback.state.db")
            try { f.assertSame(values, archive); @Expect(archive.scalarInt("SELECT COUNT(*) FROM thread_metadata"), 1) }
            finally { archive.close() }
            f.database.execute("DROP TRIGGER fixture_document_reset_failure")
        } finally { f.close() }
    }
}
