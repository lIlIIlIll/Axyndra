package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

// These tests prove the data transaction primitive, NOT canonical source
// admission. Source/Operation/Receipt and installed-plugin tests are required
// before enabling the corresponding service or migrating any live writers.
@Test
class PluginDocumentTransactionTests {
    @TestCase
    func receiptStageFailureRollsBackTheDocumentInTheSameSqliteTransaction(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(root + "/documents.sqlite")
        try {
            let repository = SqlitePluginDocumentRepository(database)
            let empty = repository.read(ThreadId("thread"), LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow()
            var failed = false
            try {
                database.transaction { transaction =>
                    let _ = compareExchangePluginDocumentInTransaction(transaction, empty, "{\"rows\":[]}")
                    // A failure in the future outer Receipt insertion must
                    // unwind this SAME transaction, not a nested repository Tx.
                    throw IllegalStateException("fixture outer settlement failure")
                }
            } catch (_: Exception) { failed = true }
            @Expect(failed)
            @Expect(repository.read(empty.threadId, empty.laneId, empty.namespace, empty.key).value().getOrThrow().revision, 0)
            let inserted = database.transaction { transaction =>
                compareExchangePluginDocumentInTransaction(transaction, empty, "{\"rows\":[]}") }
            @Expect(inserted.revision, 1)
            @Expect(repository.read(empty.threadId, empty.laneId, empty.namespace, empty.key).value().getOrThrow().encoded, inserted.encoded)
        } finally { database.close(); remove(root, recursive: true) }
    }
    @TestCase
    func sameBytesAtANewerRevisionAndForgedRawBytesCannotPassCas(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(root + "/documents.sqlite")
        try {
            let repository = SqlitePluginDocumentRepository(database)
            let empty = repository.read(ThreadId("thread"), LaneId("main"), "axyndra:workflow", "goal").value().getOrThrow()
            let first = repository.compareExchange(empty, textValue("one"), { _ => Result.Ok(()) }).value().getOrThrow()
            let second = repository.compareExchange(first, textValue("two"), { _ => Result.Ok(()) }).value().getOrThrow()
            let third = repository.compareExchange(second, textValue("one"), { _ => Result.Ok(()) }).value().getOrThrow()
            @Expect(first.encoded, third.encoded)
            @Expect(repository.compareExchange(first, nullValue(), { _ => Result.Ok(()) }).isError())
            let forged = PluginDocumentSnapshot(third.threadId, third.laneId, third.namespace, third.key, third.revision, "\"forged\"")
            @Expect(repository.compareExchange(forged, nullValue(), { _ => Result.Ok(()) }).isError())
            let cleared = repository.compareExchange(third, nullValue(), { _ => Result.Ok(()) }).value().getOrThrow()
            @Expect(cleared.revision, 4)
            @Expect(repository.compareExchange(empty, textValue("reset"), { _ => Result.Ok(()) }).isError())
        } finally { database.close(); remove(root, recursive: true) }
    }
    @TestCase
    func guardCannotSwapTheInspectedRowBeforeTheFinalCas(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(root + "/documents.sqlite")
        try {
            let repository = SqlitePluginDocumentRepository(database)
            let empty = repository.read(ThreadId("thread"), LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow()
            let first = repository.compareExchange(empty, textValue("one"), { _ => Result.Ok(()) }).value().getOrThrow()
            let result = repository.compareExchange(first, textValue("wrong"), { transaction =>
                transaction.execute("UPDATE plugin_documents SET revision=revision+1,payload='null' WHERE namespace='axyndra:workflow'")
                Result.Ok(())
            })
            @Expect(result.isError())
            let actual = repository.read(first.threadId, first.laneId, first.namespace, first.key).value().getOrThrow()
            @Expect(actual.revision, first.revision)
            @Expect(actual.encoded, first.encoded)
        } finally { database.close(); remove(root, recursive: true) }
    }
}
