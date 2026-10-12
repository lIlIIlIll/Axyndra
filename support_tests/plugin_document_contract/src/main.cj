package plugin_document_contract

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import std.fs.*
import std.convert.*
import yjson.*
import yjson_support.*

func expect(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
func require<T>(value: Result<T>): T {
    match (value) { case Result.Ok(result) => result; case Result.Err(error) => throw IllegalStateException(error.describe()) }
}
func allow(_: SqliteTransaction): Result<Unit> { Result.Ok(()) }
func read(store: SqlitePluginDocumentRepository, thread!: String = "thread", lane!: String = "main",
    namespace!: String = "axyndra:workflow", key!: String = "todo"): PluginDocumentSnapshot {
    require(store.read(ThreadId(thread), LaneId(lane), namespace, key))
}
main(): Int64 {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/canonical.sqlite")
    var cases: Int64 = 0
    try {
        expect(database.scalarInt("PRAGMA user_version") == 28, "schema28 required")
        let store = SqlitePluginDocumentRepository(database)
        let empty = read(store)
        expect(empty.revision == 0 && empty.encoded == "null", "absent value is descriptive, not a grant")
        let first = require(store.compareExchange(empty, textValue("first"), allow))
        expect(first.revision == 1 && require(first.decode()).text == "first", "first canonical database CAS")
        cases += 1

        let otherDb = SqliteDatabase(root + "/canonical.sqlite")
        try {
            let other = SqlitePluginDocumentRepository(otherDb)
            let stale = read(other)
            let second = require(store.compareExchange(first, textValue("second"), allow))
            expect(other.compareExchange(stale, textValue("lost"), allow).isError(), "second connection cannot lose first update")
            expect(read(other).encoded == second.encoded, "both real connections see canonical value")
        } finally { otherDb.close() }
        cases += 1

        let prior = read(store)
        let changed = require(store.compareExchange(prior, textValue("intermediate"), allow))
        let returned = require(store.compareExchange(changed, require(prior.decode()), allow))
        expect(returned.encoded == prior.encoded && returned.revision != prior.revision, "ABA keeps advancing revision")
        expect(store.compareExchange(prior, textValue("stale"), allow).isError(), "same content cannot resurrect stale revision")
        cases += 1

        let cleared = require(store.compareExchange(returned, nullValue(), allow))
        expect(cleared.revision > 1 && cleared.encoded == "null", "clear is a revisioned tombstone")
        expect(store.compareExchange(empty, textValue("reset"), allow).isError(), "clear never restores revision zero")
        cases += 1

        let forged = PluginDocumentSnapshot(cleared.threadId, cleared.laneId, cleared.namespace, cleared.key,
            cleared.revision, "\"forged prior bytes\"")
        expect(store.compareExchange(forged, textValue("forged"), allow).isError(), "exact raw prior payload required")
        for (snapshot in [read(store, thread: "another-thread"), read(store, lane: "branch"),
            read(store, namespace: "other:plugin"), read(store, key: "goal")]) {
            expect(snapshot.revision == 0, "thread lane namespace and key are isolated")
            let _ = require(store.compareExchange(snapshot, textValue("separate"), allow))
        }
        expect(read(store).revision == cleared.revision, "other namespaces cannot mutate this row")
        cases += 1

        // This distinguishes Cangjie Result.Err from transaction rollback:
        // returning Err normally would COMMIT the sentinel. The repository
        // must throw internally, roll back, then return this exact typed error.
        database.execute("CREATE TABLE guard_sentinel(value TEXT)")
        let guarded = store.compareExchange(cleared, textValue("never"), { transaction =>
            transaction.execute("INSERT INTO guard_sentinel VALUES('must-rollback')")
            Result.Err(AgentError(AgentErrorKind.Cancelled, "fixture.document_cancelled", "actual Host guard denied"))
        })
        expect(guarded.error().getOrThrow().code == "fixture.document_cancelled", "preserve original typed guard failure")
        expect(database.scalarInt("SELECT COUNT(*) FROM guard_sentinel") == 0, "guard-side writes roll back on Err")
        expect(read(store).revision == cleared.revision, "guard failure does not advance revision")
        cases += 1

        database.execute("CREATE TRIGGER document_write_failure BEFORE UPDATE ON plugin_documents BEGIN SELECT RAISE(ABORT,'injected'); END")
        expect(store.compareExchange(cleared, textValue("never"), allow).isError(), "real SQLite write fault surfaces")
        expect(read(store).encoded == cleared.encoded, "write fault retains prior document")
        database.execute("DROP TRIGGER document_write_failure")
        cases += 1

        let metadata = SqliteSessionMetadataRepository(database)
        require(metadata.copy(SessionId("thread"), SessionId("fork")))
        let forked = read(store, thread: "fork")
        expect(forked.encoded == cleared.encoded && forked.revision == cleared.revision, "fork copies stored immutable bytes")
        let _ = require(store.compareExchange(forked, textValue("fork-only"), allow))
        expect(read(store).encoded == cleared.encoded, "fork writes remain isolated")
        expect(metadata.copy(SessionId("thread"), SessionId("fork")).isError(), "existing target documents cannot be overwritten")
        cases += 1
    } finally { database.close() }

    // Build an actual old metadata payload using the same database, then
    // reopen through the real Cangjie migration. No Thread is fabricated.
    let before = SqliteDatabase(root + "/migration.sqlite")
    let todo = " [ {\"name\": \"雪\", \"tasks\": []} ] "
    let goal = "corrupt-history-must-remain-visible"
    try {
        let metadata = SqliteSessionMetadataRepository(before)
        require(metadata.setName(SessionId("orphan"), "legacy"))
        before.execute("UPDATE thread_metadata SET todo_payload=?,goal_payload=? WHERE thread_id='orphan'", [SqlParameter.Text(todo), SqlParameter.Text(goal)])
        before.execute("DROP TABLE plugin_documents")
        before.execute("PRAGMA user_version=27")
    } finally { before.close() }
    let migrated = SqliteDatabase(root + "/migration.sqlite")
    try {
        let store = SqlitePluginDocumentRepository(migrated)
        expect(migrated.scalarInt("PRAGMA user_version") == 28, "real constructor applies data migration")
        expect(read(store, thread: "orphan").encoded == todo, "migration keeps exact legacy formatting and Unicode")
        let invalid = read(store, thread: "orphan", key: "goal")
        expect(invalid.encoded == goal && invalid.decode().isError(), "corrupt old value is retained with explicit decode failure")
        let row = migrated.query("SELECT todo_payload,goal_payload FROM thread_metadata WHERE thread_id='orphan'")[0]
        expect(row.required(0) == todo && row.required(1) == goal, "legacy archive columns remain unchanged")
        cases += 1
    } finally { migrated.close() }
    println("plugin document contracts passed: " + cases.toString())
    0
}
