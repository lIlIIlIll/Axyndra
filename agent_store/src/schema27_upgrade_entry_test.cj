package agent_store

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// Start from the actual current schema, remove only its empty v28 destination,
// and retain every v27 table/index/column. This follows the existing historical
// schema fixtures. No Runtime owner, operation authority or fake receipt exists.
private func schema27EntryFixture(database: SqliteDatabase): Unit {
    @Expect(database.scalarInt("PRAGMA user_version"), 28)
    @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 0)
    @Expect(database.scalarInt("SELECT COUNT(*) FROM pragma_table_info('derived_operation_admissions') " +
        "WHERE name IN ('child_call_id','root_operation_id','depth')"), 3)
    database.execute("DROP TABLE plugin_documents")
    database.execute("PRAGMA user_version=27")
    database.execute("INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal,active_turn_id) " +
        "VALUES('schema27-thread',7,'schema27-workspace','idle',1,NULL)")
}

private func schema27EntryMetadata(database: SqliteDatabase, id: String, todo: String, goal: String): Unit {
    database.execute("INSERT INTO thread_metadata(thread_id,name,summary,updated_at_millis,model,workspace_root," +
        "cwd,fast_mode,parent_thread_ref,work_mode,draft,todo_payload,goal_payload) " +
        "VALUES(?,'original-name','original-summary',17,'original-model','/workspace','/workspace',0,'','agent','draft',?,?)",
        [SqlParameter.Text(id), SqlParameter.Text(todo), SqlParameter.Text(goal)])
}

private func schema27EntryAssertMigrated(database: SqliteDatabase, todo: String, goal: String): Unit {
    @Expect(database.scalarInt("PRAGMA user_version"), 28)
    @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"), 2)
    let copied=database.query("SELECT document_key,revision,payload FROM plugin_documents " +
        "WHERE thread_id='schema27-thread' AND lane_id='main' AND namespace='axyndra:workflow' ORDER BY document_key")
    @Expect(copied.size, 2)
    @Expect(copied[0].required(0), "goal"); @Expect(copied[0].required(1), "1"); @Expect(copied[0].required(2), goal)
    @Expect(copied[1].required(0), "todo"); @Expect(copied[1].required(1), "1"); @Expect(copied[1].required(2), todo)
    let archive=database.query("SELECT todo_payload,goal_payload,name,summary,draft FROM thread_metadata WHERE thread_id='schema27-thread'")[0]
    @Expect(archive.required(0), todo); @Expect(archive.required(1), goal)
    @Expect(archive.required(2), "original-name"); @Expect(archive.required(3), "original-summary"); @Expect(archive.required(4), "draft")
    @Expect(database.scalarInt("SELECT revision FROM threads WHERE id='schema27-thread'"), 7)
    @Expect(database.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='derived_child_call_identity'"), 1)
    @Expect(database.query("PRAGMA foreign_key_check").isEmpty())
}

@Test
class Schema27UpgradeEntryTests {
    @TestCase
    func actualSchema27ReopenPreservesMalformedUnicodeNulAndEmptyHistoricalBytes(): Unit {
        let root=Directory.createTemp("/tmp").toString(); let path=root+"/upgrade.db"
        let todo="[{\"phase\":\"雪\",\"tasks\":[]}]"
        let goal="malformed-goal:\u{0000}雪\noriginal-tail"
        try {
            let seed=SqliteDatabase(path)
            try {
                schema27EntryFixture(seed)
                schema27EntryMetadata(seed,"schema27-thread",todo,goal)
                schema27EntryMetadata(seed,"orphan-empty-history","","")
            } finally { seed.close() }
            // This real constructor was rejected before reaching v28Migration.
            let upgraded=SqliteDatabase(path)
            try {
                schema27EntryAssertMigrated(upgraded,todo,goal)
                @Expect(upgraded.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE thread_id='orphan-empty-history'"),1)
                @Expect(upgraded.scalarInt("SELECT COUNT(*) FROM plugin_documents WHERE thread_id='orphan-empty-history'"),0)
            } finally { upgraded.close() }
            let reopened=SqliteDatabase(path)
            try { schema27EntryAssertMigrated(reopened,todo,goal) } finally { reopened.close() }
        } finally { remove(root,recursive:true) }
    }

    @TestCase
    func actualFailureAfterTodoCopyRollsBackSchemaAndRowsThenColdRetrySucceeds(): Unit {
        let root=Directory.createTemp("/tmp").toString(); let path=root+"/rollback.db"
        let todo="first-copy-must-roll-back"; let goal="original-goal:\u{0000}雪"
        try {
            let keeper=SqliteDatabase(path)
            try {
                schema27EntryFixture(keeper)
                schema27EntryMetadata(keeper,"schema27-thread",todo,goal)
                // Deliberate historical-schema damage makes statement THREE
                // fail after CREATE and the actual todo INSERT succeeded.
                // It is a real SQLite error, not an injected production hook.
                keeper.execute("ALTER TABLE thread_metadata RENAME COLUMN goal_payload TO fault_goal_payload")
                var rejected=false
                try { let unexpected=SqliteDatabase(path); unexpected.close() }
                catch(error:Exception) { rejected=true; @Expect(error.message.contains("goal_payload")) }
                @Expect(rejected)
                @Expect(keeper.scalarInt("PRAGMA user_version"),27)
                @Expect(keeper.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='plugin_documents'"),0)
                let original=keeper.query("SELECT todo_payload,fault_goal_payload FROM thread_metadata WHERE thread_id='schema27-thread'")[0]
                @Expect(original.required(0),todo); @Expect(original.required(1),goal)
                @Expect(keeper.scalarInt("SELECT revision FROM threads WHERE id='schema27-thread'"),7)
                @Expect(keeper.query("PRAGMA foreign_key_check").isEmpty())
                // Restore only this test's explicit fault, then close every
                // handle. A fresh ordinary open must perform the full upgrade.
                keeper.execute("ALTER TABLE thread_metadata RENAME COLUMN fault_goal_payload TO goal_payload")
            } finally { keeper.close() }
            let retried=SqliteDatabase(path)
            try { schema27EntryAssertMigrated(retried,todo,goal) } finally { retried.close() }
        } finally { remove(root,recursive:true) }
    }

    @TestCase
    func futureSchemaStillRejectsBeforeMigrationAndReadonlyHistoryRemainsIntact(): Unit {
        let root=Directory.createTemp("/tmp").toString(); let path=root+"/future.db"
        let payload="future-data:\u{0000}雪"
        try {
            let seed=SqliteDatabase(path)
            try {
                schema27EntryMetadata(seed,"future-thread",payload,"")
                seed.execute("INSERT INTO plugin_documents VALUES('future-thread','main','axyndra:workflow','todo',4,?)",[SqlParameter.Text(payload)])
                seed.execute("PRAGMA user_version=29")
                // A DELETE header exposes configuration writes before refusal.
                seed.execute("PRAGMA journal_mode=DELETE")
            } finally { seed.close() }
            let original=File.readFrom(path)
            var rejected=false
            try { let unexpected=SqliteDatabase(path); unexpected.close() }
            catch(error:Exception) { rejected=true; @Expect(error.message.contains("Unsupported SQLite schema version 29")) }
            @Expect(rejected)
            @Expect(File.readFrom(path),original)
            @Expect(!exists(Path(path+"-wal")))
            @Expect(!exists(Path(path+"-shm")))
            let history=SqliteDatabase(path,readOnly:true)
            try {
                @Expect(history.query("PRAGMA journal_mode")[0].required(0),"delete")
                @Expect(history.scalarInt("PRAGMA user_version"),29)
                @Expect(history.query("SELECT todo_payload FROM thread_metadata WHERE thread_id='future-thread'")[0].required(0),payload)
                let row=history.query("SELECT revision,payload FROM plugin_documents WHERE thread_id='future-thread'")[0]
                @Expect(row.required(0),"4"); @Expect(row.required(1),payload)
                @Expect(history.scalarInt("SELECT COUNT(*) FROM plugin_documents"),1)
            } finally { history.close() }
            @Expect(File.readFrom(path),original)
        } finally { remove(root,recursive:true) }
    }
}
