package gc_contract

import agent_domain.*
import agent_product.*
import agent_store.*
import model_adapters.*
import std.fs.*
import std.process.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        let state = root + "/state"
        let database = SqliteDatabase(state + "/state.db")
        let artifacts = ProductArtifactStore(state, database: Some(database))
        let referenced = artifacts.persistText("referenced").value().getOrThrow()
        let orphan = artifacts.persistText("orphan").value().getOrThrow()
        seedThread(database, "old", referenced.reference, 1)
        seedThread(database, "live", "live", 2)
        database.execute(
            "INSERT INTO thread_metadata(thread_id,name,summary,updated_at_millis,model,workspace_root,cwd," +
                "fast_mode,parent_thread_ref,work_mode,draft,todo_payload,goal_payload) VALUES" +
                "('old','old','',1,'fixture','" + root + "','" + root + "',0,'','build','','','')," +
                "('live','live','',2,'fixture','" + root + "','" + root + "',0,'','build','','','')"
        )
        database.close()
        ageFiles([blobPath(state, referenced.sha256), blobPath(state, orphan.sha256)])

        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: state,
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )).value().getOrThrow()
        let preview = product.garbageCollect(ProductGcOptions(
            state, runWal: false, coldArchiveAfterDays: 0,
            retainNewestGlobal: 0, retainNewestPerCwd: 0,
            activeSessionId: "live"
        )).value().getOrThrow()
        expect(preview.blobs.getOrThrow().referenced == 1 &&
            preview.blobs.getOrThrow().candidates == 2 &&
            preview.blobs.getOrThrow().wouldDelete == 1 &&
            preview.archive.getOrThrow().scanned == 2 &&
            preview.archive.getOrThrow().skippedActive == 1 &&
            preview.archive.getOrThrow().wouldArchive == 1,
            "dry-run derives exact reachability and cold Thread candidates from state.db")
        expect(exists(Path(blobPath(state, orphan.sha256))) && product.archivedSessions().isEmpty(),
            "dry-run never mutates canonical or blob state")

        let applied = product.garbageCollect(ProductGcOptions(
            state, apply: true, runWal: false, coldArchiveAfterDays: 0,
            retainNewestGlobal: 0, retainNewestPerCwd: 0,
            activeSessionId: "live"
        )).value().getOrThrow()
        expect(applied.blobs.getOrThrow().deleted == 1 &&
            exists(Path(blobPath(state, referenced.sha256))) &&
            !exists(Path(blobPath(state, orphan.sha256))) &&
            applied.archive.getOrThrow().archived == 1 &&
            product.archivedSessions() == ["old"],
            "apply deletes only unreachable blobs and closes cold canonical Threads")

        let wal = product.garbageCollect(ProductGcOptions(
            state, runBlobs: false, runArchive: false, runWal: true
        )).value().getOrThrow().wal.getOrThrow()
        expect(wal.databases.size == 1 && wal.databases[0].dbPath == state + "/state.db",
            "WAL maintenance targets only the owned vNext database")

        Directory.create(state + "/gc.lock")
        File.writeTo(state + "/gc.lock/owner", ("1\n0\n").toArray())
        expect(product.garbageCollect(ProductGcOptions(
            state, runBlobs: false, runArchive: false, runWal: false
        )).isError(), "a live owner prevents concurrent GC")
        let _ = removeIfExists(state + "/gc.lock", recursive: true)
        Directory.create(state + "/gc.lock")
        File.writeTo(state + "/gc.lock/owner", "9223372036854775807\n0\n".toArray())
        expect(product.garbageCollect(ProductGcOptions(
            state, runBlobs: false, runArchive: false, runWal: false
        )).isOk(), "a stale GC owner is safely replaced")
        product.close().value().getOrThrow()
        println("gc contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func seedThread(database: SqliteDatabase, id: String, text: String, created: Int64): Unit {
    let snapshot = completedThreadSeedSnapshot(
        ThreadId(id), "workspace",
        [
            ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: text)]),
            ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.Text, text: "done")])
        ],
        createdAtMillis: created
    )
    SqliteThreadSeedStore(database).createCompleted(snapshot).value().getOrThrow()
}

func ageFiles(paths: Array<String>): Unit {
    for (path in paths) {
        let process = launch(
            "/usr/bin/touch", ["-d", "2000-01-01T00:00:00Z", path],
            stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe
        )
        let (code, _, error) = process.waitOutput()
        if (code != 0) { throw IllegalStateException(String.fromUtf8(error)) }
    }
}

func blobPath(state: String, hash: String): String { state + "/blobs/" + hash + ".txt" }

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
