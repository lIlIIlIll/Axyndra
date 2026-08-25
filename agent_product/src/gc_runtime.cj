package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*

let GC_DAY_MILLIS: Int64 = 86400000
let GC_WRITE_GRACE_MILLIS: Int64 = 300000

public class ProductGcOptions {
    public let agentDir: String
    public let apply: Bool
    public let runBlobs: Bool
    public let runArchive: Bool
    public let runWal: Bool
    public let coldArchiveAfterDays: Int64
    public let retainNewestGlobal: Int64
    public let retainNewestPerCwd: Int64
    public let activeSessionId: String

    public init(
        agentDir: String,
        apply!: Bool = false,
        runBlobs!: Bool = true,
        runArchive!: Bool = true,
        runWal!: Bool = true,
        coldArchiveAfterDays!: Int64 = 30,
        retainNewestGlobal!: Int64 = 20,
        retainNewestPerCwd!: Int64 = 10,
        activeSessionId!: String = ""
    ) {
        this.agentDir = absoluteGcPath(agentDir)
        this.apply = apply
        this.runBlobs = runBlobs
        this.runArchive = runArchive
        this.runWal = runWal
        this.coldArchiveAfterDays = max(coldArchiveAfterDays, 0)
        this.retainNewestGlobal = max(retainNewestGlobal, 0)
        this.retainNewestPerCwd = max(retainNewestPerCwd, 0)
        this.activeSessionId = activeSessionId
    }
}

public class ProductBlobGcResult {
    public let referenced: Int64
    public let candidates: Int64
    public let wouldDelete: Int64
    public let deleted: Int64
    public let bytes: Int64
    public let errors: Array<String>

    public init(
        referenced: Int64,
        candidates: Int64,
        wouldDelete: Int64,
        deleted: Int64,
        bytes: Int64,
        errors!: Array<String> = []
    ) {
        this.referenced = referenced
        this.candidates = candidates
        this.wouldDelete = wouldDelete
        this.deleted = deleted
        this.bytes = bytes
        this.errors = errors
    }
}

public class ProductArchiveGcResult {
    public let scanned: Int64
    public let skippedActive: Int64
    public let keptNewestGlobal: Int64
    public let keptNewestPerCwd: Int64
    public let wouldArchive: Int64
    public let archived: Int64
    public let historyRowsDeleted: Int64
    public let ftsRebuilt: Bool
    public let errors: Array<String>

    public init(
        scanned: Int64,
        skippedActive: Int64,
        keptNewestGlobal: Int64,
        keptNewestPerCwd: Int64,
        wouldArchive: Int64,
        archived: Int64,
        historyRowsDeleted!: Int64 = 0,
        ftsRebuilt!: Bool = false,
        errors!: Array<String> = []
    ) {
        this.scanned = scanned
        this.skippedActive = skippedActive
        this.keptNewestGlobal = keptNewestGlobal
        this.keptNewestPerCwd = keptNewestPerCwd
        this.wouldArchive = wouldArchive
        this.archived = archived
        this.historyRowsDeleted = historyRowsDeleted
        this.ftsRebuilt = ftsRebuilt
        this.errors = errors
    }
}

public class ProductWalCheckpointResult {
    public let dbPath: String
    public let walBytes: Int64
    public let wouldCheckpoint: Bool
    public let checkpointed: Bool
    public let busy: Int64
    public let log: Int64
    public let checkpointedFrames: Int64

    public init(
        dbPath: String,
        walBytes: Int64,
        wouldCheckpoint: Bool,
        checkpointed: Bool,
        busy!: Int64 = 0,
        log!: Int64 = 0,
        checkpointedFrames!: Int64 = 0
    ) {
        this.dbPath = dbPath
        this.walBytes = walBytes
        this.wouldCheckpoint = wouldCheckpoint
        this.checkpointed = checkpointed
        this.busy = busy
        this.log = log
        this.checkpointedFrames = checkpointedFrames
    }
}

public class ProductWalGcResult {
    public let databases: Array<ProductWalCheckpointResult>
    public let walBytes: Int64
    public let wouldCheckpoint: Bool
    public let checkpointed: Bool

    public init(databases: Array<ProductWalCheckpointResult>) {
        this.databases = databases
        var bytes: Int64 = 0
        var would = false
        var did = false
        for (database in databases) {
            bytes += database.walBytes
            if (database.wouldCheckpoint) {
                would = true
            }
            if (database.checkpointed) {
                did = true
            }
        }
        this.walBytes = bytes
        this.wouldCheckpoint = would
        this.checkpointed = did
    }
}

public class ProductGcResult {
    public let agentDir: String
    public let apply: Bool
    public let blobs: ?ProductBlobGcResult
    public let archive: ?ProductArchiveGcResult
    public let wal: ?ProductWalGcResult
    public let lockPath: String

    public init(
        agentDir: String,
        apply: Bool,
        lockPath: String,
        blobs!: ?ProductBlobGcResult = None,
        archive!: ?ProductArchiveGcResult = None,
        wal!: ?ProductWalGcResult = None
    ) {
        this.agentDir = agentDir
        this.apply = apply
        this.blobs = blobs
        this.archive = archive
        this.wal = wal
        this.lockPath = lockPath
    }
}

class ProductGcRuntime {
    private let database: SqliteDatabase
    private let threadRuntimes: ThreadRuntimeRegistry

    init(database: SqliteDatabase, threadRuntimes: ThreadRuntimeRegistry) {
        this.database = database
        this.threadRuntimes = threadRuntimes
    }

    func run(options: ProductGcOptions): Result<ProductGcResult> {
        let lock = GcLock(options.agentDir)
        match (lock.acquire()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            var blobs: ?ProductBlobGcResult = None
            var archive: ?ProductArchiveGcResult = None
            var wal: ?ProductWalGcResult = None
            if (options.runBlobs) {
                blobs = match (runBlobGc(options)) {
                    case Result.Ok(value) => Some(value)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
            if (options.runArchive) {
                archive = Some(runArchiveGc(options))
            }
            if (options.runWal) {
                wal = Some(runWalGc(options))
            }
            Result.Ok(
                ProductGcResult(
                    options.agentDir,
                    options.apply,
                    lock.path,
                    blobs: blobs,
                    archive: archive,
                    wal: wal
                )
            )
        } catch (error: Exception) {
            gcError<ProductGcResult>(
                "gc.run_failed",
                error.message,
                options.agentDir
            )
        } finally {
            lock.release()
        }
    }

    private func runBlobGc(options: ProductGcOptions): Result<ProductBlobGcResult> {
        let firstScan = collectRequiredBlobReferences(database)
        if (!firstScan.errors.isEmpty()) {
            if (options.apply) {
                return gcReferenceScanError(options.agentDir, firstScan.errors)
            }
            return Result.Ok(ProductBlobGcResult(
                firstScan.references.size,
                0,
                0,
                0,
                0,
                errors: firstScan.errors
            ))
        }
        let candidateErrors = ArrayList<String>()
        let candidates = collectBlobCandidates(
            options.agentDir + "/blobs",
            candidateErrors
        )
        if (!candidateErrors.isEmpty()) {
            if (options.apply) {
                return gcReferenceScanError(options.agentDir, candidateErrors.toArray())
            }
            return Result.Ok(ProductBlobGcResult(
                firstScan.references.size,
                candidates.size,
                0,
                0,
                0,
                errors: candidateErrors.toArray()
            ))
        }
        var referenced = firstScan.references
        // Writers do not share the GC lock. Re-scan every durable reference
        // root after candidate enumeration and require the content generation
        // to remain identical before apply. The artifact write grace covers
        // the remaining narrow window for newly-produced outputs.
        if (options.apply) {
            let fencedScan = collectRequiredBlobReferences(database)
            if (!fencedScan.errors.isEmpty()) {
                return gcReferenceScanError(options.agentDir, fencedScan.errors)
            }
            if (!sameGcStrings(firstScan.generations, fencedScan.generations)) {
                return gcError<ProductBlobGcResult>(
                    "gc.reference_generation_changed",
                    "artifact reference roots changed while garbage collection was preparing to delete",
                    options.agentDir
                )
            }
            referenced = fencedScan.references
        }
        let errors = ArrayList<String>()
        let deleteBefore = gcNowMillis() - GC_WRITE_GRACE_MILLIS
        var wouldDelete: Int64 = 0
        var deleted: Int64 = 0
        var bytes: Int64 = 0
        for (candidate in candidates) {
            if (containsGcString(referenced, candidate.hash) || candidate.modifiedMillis > deleteBefore) {
                continue
            }
            wouldDelete += candidate.paths.size
            bytes += candidate.bytes
            if (!options.apply) {
                continue
            }
            var candidateFailed = false
            for (path in candidate.paths) {
                try {
                    if (removeIfExists(path)) {
                        deleted++
                    }
                } catch (error: Exception) {
                    candidateFailed = true
                    errors.add(path + ": " + error.message)
                }
            }
            if (!candidateFailed) {
                try {
                    database.execute(
                        "DELETE FROM artifacts WHERE hash=" + sqliteText(candidate.hash)
                    )
                } catch (error: Exception) {
                    errors.add(candidate.hash + ": " + error.message)
                }
            }
        }
        Result.Ok(ProductBlobGcResult(
            referenced.size,
            candidates.size,
            wouldDelete,
            deleted,
            bytes,
            errors: errors.toArray()
        ))
    }

    private func runArchiveGc(options: ProductGcOptions): ProductArchiveGcResult {
        let errors = ArrayList<String>()
        let sessions = collectGcThreads(database, errors)
        let graceBefore = gcNowMillis() - GC_WRITE_GRACE_MILLIS
        let coldBefore = gcNowMillis() - options.coldArchiveAfterDays * GC_DAY_MILLIS
        let candidates = ArrayList<GcThreadCandidate>()
        var skippedActive: Int64 = 0
        var keptGlobal: Int64 = 0
        var keptPerCwd: Int64 = 0
        var inactiveSeen: Int64 = 0
        let cwdSeen = HashMap<String, Int64>()
        for (session in sessions) {
            if (session.id == options.activeSessionId || session.active ||
                session.updatedAtMillis > graceBefore) {
                skippedActive++
                continue
            }
            let keepGlobal = inactiveSeen < options.retainNewestGlobal
            let seenForCwd = match (cwdSeen.get(session.cwd)) {
                case Some(value) => value
                case None => 0
            }
            let keepPerCwd = seenForCwd < options.retainNewestPerCwd
            inactiveSeen++
            cwdSeen[session.cwd] = seenForCwd + 1
            if (keepGlobal) {
                keptGlobal++
                continue
            }
            if (keepPerCwd) {
                keptPerCwd++
                continue
            }
            if (options.coldArchiveAfterDays > 0 && session.updatedAtMillis > coldBefore) {
                continue
            }
            candidates.add(session)
        }
        var archived: Int64 = 0
        if (options.apply) {
            for (candidate in candidates) {
                match (threadRuntimes.releaseInactive(ThreadId(candidate.id))) {
                    case Result.Err(error) => errors.add(candidate.id + ": " + error.message)
                    case Result.Ok(_) =>
                        try {
                            database.execute(
                                "UPDATE threads SET status='closed' WHERE id=" +
                                    sqliteText(candidate.id) + " AND status='open'"
                            )
                            archived++
                        } catch (error: Exception) {
                            errors.add(candidate.id + ": " + error.message)
                        }
                }
            }
        }
        ProductArchiveGcResult(
            sessions.size,
            skippedActive,
            keptGlobal,
            keptPerCwd,
            candidates.size,
            archived,
            errors: errors.toArray()
        )
    }

    private func runWalGc(options: ProductGcOptions): ProductWalGcResult {
        let values = ArrayList<ProductWalCheckpointResult>()
        let dbPath = options.agentDir + "/state.db"
        let walBytes = gcFileSize(dbPath + "-wal")
        let wouldCheckpoint = walBytes > 0
        if (!options.apply || !wouldCheckpoint) {
            values.add(ProductWalCheckpointResult(dbPath, walBytes, wouldCheckpoint, false))
        } else {
            try {
                let row = database.checkpointWal()
                values.add(ProductWalCheckpointResult(
                    dbPath, walBytes, true, row[0] == 0,
                    busy: row[0], log: row[1], checkpointedFrames: row[2]
                ))
            } catch (_: Exception) {
                values.add(ProductWalCheckpointResult(dbPath, walBytes, true, false))
            }
        }
        ProductWalGcResult(values.toArray())
    }
}

class GcLock {
    let path: String
    private let ownerPath: String
    private let pid: Int64
    private var held = false

    init(agentDir: String) {
        this.path = agentDir + "/gc.lock"
        this.ownerPath = this.path + "/owner"
        this.pid = getProcessId()
    }

    func acquire(): Result<Unit> {
        try {
            if (!exists(Path(Path(path).parent.toString()))) {
                Directory.create(
                    Path(path).parent.toString(),
                    recursive: true
                )
            }
            if (exists(Path(path))) {
                if (!stale()) {
                    return gcError<Unit>(
                        "gc.already_running",
                        "GC already running: " + path,
                        path
                    )
                }
                let _ = removeIfExists(path, recursive: true)
            }
            Directory.create(path)
            File.writeTo(
                ownerPath,
                (pid.toString() + "\n" + gcNowMillis().toString() + "\n").toArray()
            )
            held = true
            Result.Ok(())
        } catch (error: Exception) {
            gcError<Unit>(
                "gc.lock_failed",
                "cannot acquire GC lock: " + error.message,
                path
            )
        }
    }

    func release(): Unit {
        if (!held) {
            return
        }
        try {
            if (exists(Path(ownerPath))) {
                let owner = String.fromUtf8(File.readFrom(ownerPath)).split("\n")
                if (!owner.isEmpty() && owner[0].trimAscii() == pid.toString()) {
                    let _ = removeIfExists(path, recursive: true)
                }
            }
        } catch (_: Exception) {
            ()
        }
        held = false
    }

    private func stale(): Bool {
        if (!exists(Path(ownerPath))) {
            return true
        }
        try {
            let lines = String.fromUtf8(File.readFrom(ownerPath)).split("\n")
            if (lines.isEmpty()) {
                return true
            }
            let ownerPid = Int64.parse(lines[0].trimAscii())
            !exists(Path("/proc/" + ownerPid.toString()))
        } catch (_: Exception) {
            true
        }
    }
}

class GcBlobCandidate {
    let hash: String
    let paths = ArrayList<String>()
    var bytes: Int64 = 0
    var modifiedMillis: Int64 = 0

    init(hash: String) {
        this.hash = hash
    }
}

class GcBlobReferenceScan {
    let references: Array<String>
    let generations: Array<String>
    let errors: Array<String>

    init(
        references: Array<String>,
        generations: Array<String>,
        errors: Array<String>
    ) {
        this.references = references
        this.generations = generations
        this.errors = errors
    }
}

class GcThreadCandidate {
    let id: String
    let cwd: String
    let updatedAtMillis: Int64
    let active: Bool

    init(id: String, cwd: String, updatedAtMillis: Int64, active: Bool) {
        this.id = id
        this.cwd = cwd
        this.updatedAtMillis = updatedAtMillis
        this.active = active
    }
}

func collectGcThreads(
    database: SqliteDatabase,
    errors: ArrayList<String>
): Array<GcThreadCandidate> {
    let values = ArrayList<GcThreadCandidate>()
    try {
        for (row in database.query(
            "SELECT t.id,COALESCE(m.cwd,'')," +
                "MAX(COALESCE(m.updated_at_millis,0)," +
                "COALESCE((SELECT MAX(i.created_at_millis) FROM items i WHERE i.thread_id=t.id),0)," +
                "COALESCE((SELECT MAX(r.started_at_millis) FROM runs r WHERE r.thread_id=t.id),0))," +
                "CASE WHEN EXISTS(SELECT 1 FROM runs r WHERE r.thread_id=t.id AND " +
                "r.state IN ('created','running','waiting_approval','waiting_external','cancelling','recovery_required')) " +
                "THEN 1 ELSE 0 END FROM threads t LEFT JOIN thread_metadata m ON m.thread_id=t.id " +
                "WHERE t.status='open' ORDER BY 3 DESC,t.id"
        )) {
            values.add(GcThreadCandidate(
                row.required(0), row.required(1), Int64.parse(row.required(2)),
                row.required(3) == "1"
            ))
        }
    } catch (error: Exception) {
        errors.add("state.db: " + error.message)
    }
    values.toArray()
}

func collectRequiredBlobReferences(database: SqliteDatabase): GcBlobReferenceScan {
    let references = ArrayList<String>()
    let generations = ArrayList<String>()
    let errors = ArrayList<String>()
    let sources = [
        "SELECT payload FROM items",
        "SELECT provenance FROM items",
        "SELECT payload FROM run_journal",
        "SELECT payload FROM app_run_events",
        "SELECT payload FROM approval_decisions",
        "SELECT payload FROM tool_operation_intents",
        "SELECT payload FROM tool_operation_intent_receipts",
        "SELECT payload FROM session_permission_grants",
        "SELECT summary||draft||todo_payload||goal_payload FROM thread_metadata",
        "SELECT lane_snapshot||skill_snapshot||budget||usage||COALESCE(app_snapshot,'') FROM runs",
        "SELECT payload FROM run_continuations",
        "SELECT normalized_plan||capability_requirement||resource_scope FROM operations",
        "SELECT detail||verification FROM operation_receipts",
        "SELECT operation_digest||capability_ceiling FROM approvals",
        "SELECT payload FROM capability_grants",
        "SELECT payload FROM audit_events",
        "SELECT payload FROM context_checkpoints",
        "SELECT payload FROM memories",
        "SELECT payload FROM memory_events",
        "SELECT payload FROM task_snapshots"
    ]
    try {
        for (sql in sources) {
            for (row in database.query(sql)) {
                let source = match (row[0]) { case Some(value) => value case None => "" }
                extractBlobHashes(source, references)
            }
        }
        for (reference in references) { generations.add(reference) }
    } catch (error: Exception) {
        errors.add("state.db: " + error.message)
    }
    GcBlobReferenceScan(references.toArray(), generations.toArray(), errors.toArray())
}

func extractBlobHashes(
    source: String,
    values: ArrayList<String>
): Unit {
    let prefix = "blob:sha256:"
    var offset: Int64 = 0
    while (offset < source.size) {
        let found = source.indexOf(prefix, offset)
        if (found.isNone()) {
            break
        }
        let start = found.getOrThrow() + prefix.size
        if (start + 64 <= source.size) {
            let hash = source[start..start + 64].toAsciiLower()
            if (isGcHash(hash) && !containsGcString(values, hash)) {
                insertGcString(values, hash)
            }
        }
        offset = start
    }
}

func collectBlobCandidates(
    root: String,
    errors: ArrayList<String>
): Array<GcBlobCandidate> {
    let values = ArrayList<GcBlobCandidate>()
    if (!exists(Path(root))) {
        return values.toArray()
    }
    try {
        for (entry in Directory.readFrom(root)) {
            let hash = blobHashFromName(entry.name)
            if (hash == "") {
                continue
            }
            let path = Path(root).join(entry.name).toString()
            try {
                let info = FileInfo(Path(path))
                if (!info.isRegular() || info.isSymbolicLink()) {
                    errors.add(path + ": artifact candidate must be a real regular file")
                    continue
                }
                var candidate = findGcBlob(values, hash)
                match (candidate) {
                    case Some(value) =>
                        value.paths.add(path)
                        value.bytes += info.size
                        value.modifiedMillis = max(
                            value.modifiedMillis,
                            gcModificationMillis(info)
                        )
                    case None =>
                        let value = GcBlobCandidate(hash)
                        value.paths.add(path)
                        value.bytes = info.size
                        value.modifiedMillis = gcModificationMillis(info)
                        insertGcBlob(values, value)
                }
            } catch (error: Exception) {
                errors.add(path + ": " + error.message)
            }
        }
    } catch (error: Exception) {
        errors.add(root + ": " + error.message)
    }
    values.toArray()
}

func blobHashFromName(name: String): String {
    if (name.size < 64) {
        return ""
    }
    let hash = name[0..64]
    if (!isGcHash(hash)) {
        return ""
    }
    if (name.size == 64) {
        return hash
    }
    if (name[64] != b'.' || name.size > 96) {
        return ""
    }
    for (rune in name[65..].runes()) {
        let allowed = (rune >= r'a' && rune <= r'z') || (rune >= r'A' && rune <= r'Z') || (rune >= r'0' && rune <= r'9') ||
            rune == r'.' || rune == r'_' || rune == r'-'
        if (!allowed) {
            return ""
        }
    }
    hash
}

func isGcHash(value: String): Bool {
    if (value.size != 64) {
        return false
    }
    for (rune in value.runes()) {
        if (!((rune >= r'0' && rune <= r'9') || (rune >= r'a' && rune <= r'f') || (rune >= r'A' && rune <= r'F'))) {
            return false
        }
    }
    true
}

func findGcBlob(
    values: ArrayList<GcBlobCandidate>,
    hash: String
): ?GcBlobCandidate {
    for (value in values where value.hash == hash) {
        return Some(value)
    }
    None
}

func insertGcBlob(
    values: ArrayList<GcBlobCandidate>,
    value: GcBlobCandidate
): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 && values[index].hash < values[index - 1].hash) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index--
    }
}

func insertGcString(
    values: ArrayList<String>,
    value: String
): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 && values[index] < values[index - 1]) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index--
    }
}

func containsGcString(
    values: ArrayList<String>,
    expected: String
): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func containsGcString(
    values: Array<String>,
    expected: String
): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func sameGcStrings(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) {
        return false
    }
    for (index in 0..left.size) {
        if (left[index] != right[index]) {
            return false
        }
    }
    true
}

func gcModificationMillis(info: FileInfo): Int64 {
    info.lastModificationTime.toUnixTimeStamp().toMilliseconds()
}

func gcFileSize(path: String): Int64 {
    if (!exists(Path(path))) {
        return 0
    }
    try {
        let info = FileInfo(Path(path))
        if (info.isRegular()) {
            info.size
        } else {
            0
        }
    } catch (_: Exception) {
        0
    }
}

func gcNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func absoluteGcPath(path: String): String {
    let authored = if (path.trimAscii() == "") {
        "."
    } else {
        path
    }
    let parsed = Path(authored)
    if (parsed.isAbsolute()) {
        parsed.normalize().toString()
    } else {
        getWorkingDirectory().join(parsed).normalize().toString()
    }
}

func gcError<T>(
    code: String,
    message: String,
    path: String
): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.Internal,
            code,
            if (message == "") {
                "storage garbage collection failed"
            } else {
                message
            },
            fields: [ErrorField("path", path)]
        )
    )
}

func gcReferenceScanError(
    agentDir: String,
    errors: Array<String>
): Result<ProductBlobGcResult> {
    let first = if (errors.isEmpty()) {
        "unknown artifact reference scan failure"
    } else {
        errors[0]
    }
    gcError<ProductBlobGcResult>(
        "gc.reference_scan_failed",
        "artifact deletion stopped because a required reference root could not be scanned: " + first,
        agentDir
    )
}
