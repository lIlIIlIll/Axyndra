package agent_store

import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*

private let SQLITE_OK: Int32 = 0
private let SQLITE_ROW: Int32 = 100
private let SQLITE_DONE: Int32 = 101
private let SQLITE_OPEN_READWRITE: Int32 = 0x00000002
private let SQLITE_OPEN_CREATE: Int32 = 0x00000004
private let SQLITE_OPEN_FULLMUTEX: Int32 = 0x00010000

public class SqliteRow {
    private let values: Array<?String>

    public init(values: Array<?String>) {
        this.values = values
    }

    public prop size: Int64 { get() { values.size } }

    public operator func [](index: Int64): ?String {
        values[index]
    }

    public func required(index: Int64): String {
        match (values[index]) {
            case Some(value) => value
            case None => throw IllegalStateException("SQLite column is null")
        }
    }
}

public enum SqlParameter {
    Text(String)
    | Int64Value(Int64)
    | Blob(Array<UInt8>)
    | Null
}

public class SqliteTransaction {
    private let executeFn: (String) -> Unit
    private let queryFn: (String) -> Array<SqliteRow>
    private let executeBoundFn: (String, Array<SqlParameter>) -> Unit
    private let queryBoundFn: (String, Array<SqlParameter>) -> Array<SqliteRow>

    public init(
        executeFn: (String) -> Unit,
        queryFn: (String) -> Array<SqliteRow>,
        executeBoundFn: (String, Array<SqlParameter>) -> Unit,
        queryBoundFn: (String, Array<SqlParameter>) -> Array<SqliteRow>
    ) {
        this.executeFn = executeFn
        this.queryFn = queryFn
        this.executeBoundFn = executeBoundFn
        this.queryBoundFn = queryBoundFn
    }

    public func execute(sql: String): Unit { executeFn(sql) }

    public func query(sql: String): Array<SqliteRow> { queryFn(sql) }

    public func execute(sql: String, parameters: Array<SqlParameter>): Unit {
        executeBoundFn(sql, parameters)
    }

    public func query(
        sql: String,
        parameters: Array<SqlParameter>
    ): Array<SqliteRow> {
        queryBoundFn(sql, parameters)
    }
}

// SqliteDatabase deliberately exposes a small synchronous boundary. The
// ThreadCoordinator remains the semantic owner; this class only serializes one
// connection and transaction. Async workers never receive it.
public class SqliteDatabase {
    private let lock = Mutex()
    private var handle: CPointer<Unit>
    private var closed: Bool = false

    public init(path: String) {
        if (path.trimAscii() == "") {
            throw IllegalArgumentException("SQLite path must not be empty")
        }
        let parent = Path(path).parent
        if (parent.toString() != "" && !exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        let out = unsafe { LibC.malloc<CPointer<Unit>>() }
        if (out.isNull()) {
            throw IllegalStateException("failed to allocate SQLite handle")
        }
        unsafe { out.write(CPointer<Unit>()) }
        let rawPath = unsafe { LibC.mallocCString(path) }
        var opened = CPointer<Unit>()
        try {
            let code = unsafe {
                sqlite3_open_v2(
                    rawPath,
                    out,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                    CString(CPointer<UInt8>())
                )
            }
            opened = unsafe { out.read() }
            if (code != SQLITE_OK || opened.isNull()) {
                if (!opened.isNull()) { unsafe { let _ = sqlite3_close_v2(opened) } }
                throw IllegalStateException("SQLite open failed with code " + code.toString())
            }
        } finally {
            unsafe {
                LibC.free(rawPath)
                LibC.free(out)
            }
        }
        this.handle = opened
        try {
            configure()
            migrate()
        } catch (error: Exception) {
            unsafe { let _ = sqlite3_close_v2(handle) }
            closed = true
            throw error
        }
    }

    public func close(): Unit {
        lock.lock()
        try {
            if (!closed) {
                let code = unsafe { sqlite3_close_v2(handle) }
                if (code != SQLITE_OK) {
                    throw IllegalStateException(
                        "SQLite close failed with code " + code.toString()
                    )
                }
                closed = true
                handle = CPointer<Unit>()
            }
        } finally {
            lock.unlock()
        }
    }

    public func execute(sql: String): Unit {
        lock.lock()
        try { executeLocked(sql) } finally { lock.unlock() }
    }

    public func query(sql: String): Array<SqliteRow> {
        lock.lock()
        try { queryLocked(sql) } finally { lock.unlock() }
    }

    public func execute(sql: String, parameters: Array<SqlParameter>): Unit {
        lock.lock()
        try { executeBoundLocked(sql, parameters) } finally { lock.unlock() }
    }

    public func query(
        sql: String,
        parameters: Array<SqlParameter>
    ): Array<SqliteRow> {
        lock.lock()
        try { queryBoundLocked(sql, parameters) } finally { lock.unlock() }
    }

    public func scalarInt(sql: String): Int64 {
        let rows = query(sql)
        if (rows.size != 1 || rows[0].size < 1) {
            throw IllegalStateException("SQLite scalar query returned no row")
        }
        try { Int64.parse(rows[0].required(0)) } catch (_: Exception) {
            throw IllegalStateException("SQLite scalar query returned a non-integer")
        }
    }

    // Produces a transactionally consistent SQLite snapshot without moving or
    // reopening the live WAL database.
    public func backupTo(path: String): Unit {
        if (path.trimAscii() == "") {
            throw IllegalArgumentException("SQLite backup path must not be empty")
        }
        let parent = Path(path).parent
        if (parent.toString() != "" && !exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        lock.lock()
        try { executeLocked("VACUUM INTO " + sqliteText(path)) } finally { lock.unlock() }
    }

    // Checkpoint the live WAL through the owned connection. Maintenance code
    // must not open a second sqlite3 process against the same state database.
    // SQLite returns one row: busy, log frames, checkpointed frames.
    public func checkpointWal(truncate!: Bool = true): Array<Int64> {
        lock.lock()
        try {
            let mode = if (truncate) { "TRUNCATE" } else { "PASSIVE" }
            let rows = queryLocked("PRAGMA wal_checkpoint(" + mode + ")")
            if (rows.size != 1 || rows[0].size < 3) {
                throw IllegalStateException("SQLite WAL checkpoint returned an invalid row")
            }
            [
                Int64.parse(rows[0].required(0)),
                Int64.parse(rows[0].required(1)),
                Int64.parse(rows[0].required(2))
            ]
        } finally {
            lock.unlock()
        }
    }

    public func transaction<T>(body: (SqliteTransaction) -> T): T {
        lock.lock()
        try {
            ensureOpenLocked()
            executeLocked("BEGIN IMMEDIATE")
            try {
                let transaction = SqliteTransaction(
                    { sql => executeLocked(sql) },
                    { sql => queryLocked(sql) },
                    { sql, parameters => executeBoundLocked(sql, parameters) },
                    { sql, parameters => queryBoundLocked(sql, parameters) }
                )
                let result = body(transaction)
                executeLocked("COMMIT")
                result
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } finally {
            lock.unlock()
        }
    }

    // A deferred transaction gives paging/list readers one consistent SQLite
    // snapshot without acquiring the WAL writer reservation used by mutations.
    public func readTransaction<T>(body: (SqliteTransaction) -> T): T {
        lock.lock()
        try {
            ensureOpenLocked()
            executeLocked("BEGIN")
            try {
                let transaction = SqliteTransaction(
                    { sql => executeLocked(sql) },
                    { sql => queryLocked(sql) },
                    { sql, parameters => executeBoundLocked(sql, parameters) },
                    { sql, parameters => queryBoundLocked(sql, parameters) }
                )
                let result = body(transaction)
                executeLocked("COMMIT")
                result
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } finally {
            lock.unlock()
        }
    }

    private func configure(): Unit {
        executeLocked("PRAGMA journal_mode=WAL")
        executeLocked("PRAGMA synchronous=FULL")
        executeLocked("PRAGMA foreign_keys=ON")
        executeLocked("PRAGMA busy_timeout=5000")
        let mode = queryLocked("PRAGMA journal_mode")[0].required(0).toAsciiLower()
        if (mode != "wal") {
            throw IllegalStateException("SQLite WAL mode could not be enabled")
        }
        if (scalarIntLocked("PRAGMA foreign_keys") != 1) {
            throw IllegalStateException("SQLite foreign keys could not be enabled")
        }
    }

    private func migrate(): Unit {
        let version = scalarIntLocked("PRAGMA user_version")
        if (version == 0) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v1Schema()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=18")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 1) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v2Migration()) { executeLocked(statement) }
                for (statement in v3Migration()) { executeLocked(statement) }
                for (statement in v4Migration()) { executeLocked(statement) }
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 2) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v3Migration()) { executeLocked(statement) }
                for (statement in v4Migration()) { executeLocked(statement) }
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 3) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v4Migration()) { executeLocked(statement) }
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 4) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 5) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 6) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 7) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 8) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 9) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 10) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 11) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 12) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 13) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 14) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version != 15 && version != 16 && version != 17 && version != 18) {
            throw IllegalStateException(
                "unsupported SQLite schema version " + version.toString()
            )
        }
        // v16 is isolated so an interrupted upgrade remains restartable from
        // the fully valid v15 boundary.
        if (version >= 1 && version <= 15) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v16Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=16")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v17 makes Step input enclosure optional so every model request can
        // own a Step even when no new Inbox entry caused it.
        if (version >= 1 && version <= 16) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v17Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=17")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v18 adds the durable fenced ownership register used by Lane actors.
        if (version >= 1 && version <= 17) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v18Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=18")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
    }

    private func executeLocked(sql: String): Unit {
        ensureOpenLocked()
        if (sql.trimAscii() == "") {
            throw IllegalArgumentException("SQLite statement must not be empty")
        }
        let raw = unsafe { LibC.mallocCString(sql) }
        try {
            let code = unsafe {
                sqlite3_exec(
                    handle, raw, CPointer<Unit>(), CPointer<Unit>(), CPointer<CString>()
                )
            }
            if (code != SQLITE_OK) { failLocked("execute", code) }
        } finally {
            unsafe { LibC.free(raw) }
        }
    }

    private func queryLocked(sql: String): Array<SqliteRow> {
        queryBoundLocked(sql, [])
    }

    private func executeBoundLocked(
        sql: String,
        parameters: Array<SqlParameter>
    ): Unit {
        let rows = runPreparedLocked(sql, parameters, false)
        let _ = rows
    }

    private func queryBoundLocked(
        sql: String,
        parameters: Array<SqlParameter>
    ): Array<SqliteRow> {
        runPreparedLocked(sql, parameters, true)
    }

    private func runPreparedLocked(
        sql: String,
        parameters: Array<SqlParameter>,
        collectRows: Bool
    ): Array<SqliteRow> {
        ensureOpenLocked()
        if (sql.trimAscii() == "") {
            throw IllegalArgumentException("SQLite statement must not be empty")
        }
        let raw = unsafe { LibC.mallocCString(sql) }
        let out = unsafe { LibC.malloc<CPointer<Unit>>() }
        if (out.isNull()) {
            unsafe { LibC.free(raw) }
            throw IllegalStateException("failed to allocate SQLite statement handle")
        }
        unsafe { out.write(CPointer<Unit>()) }
        var statement = CPointer<Unit>()
        let textValues = ArrayList<CString>()
        let blobValues = ArrayList<CPointer<UInt8>>()
        try {
            let prepared = unsafe {
                sqlite3_prepare_v2(handle, raw, -1, out, CPointer<CString>())
            }
            statement = unsafe { out.read() }
            if (prepared != SQLITE_OK || statement.isNull()) {
                failLocked("prepare", prepared)
            }
            bindParametersLocked(statement, parameters, textValues, blobValues)
            let rows = ArrayList<SqliteRow>()
            while (true) {
                let step = unsafe { sqlite3_step(statement) }
                if (step == SQLITE_DONE) { break }
                if (step != SQLITE_ROW) { failLocked("step", step) }
                if (!collectRows) { continue }
                let count = unsafe { sqlite3_column_count(statement) }
                let values = ArrayList<?String>()
                for (index in 0..Int64(count)) {
                    let text = unsafe { sqlite3_column_text(statement, Int32(index)) }
                    if (text.isNull()) {
                        values.add(None)
                    } else {
                        let size = unsafe { sqlite3_column_bytes(statement, Int32(index)) }
                        let bytes = Array<UInt8>(Int64(size), { offset =>
                            unsafe { text.read(offset) }
                        })
                        values.add(Some(String.fromUtf8(bytes)))
                    }
                }
                rows.add(SqliteRow(values.toArray()))
            }
            rows.toArray()
        } finally {
            if (!statement.isNull()) { unsafe { let _ = sqlite3_finalize(statement) } }
            unsafe {
                for (value in textValues) { LibC.free(value) }
                for (value in blobValues) { LibC.free(value) }
                LibC.free(raw)
                LibC.free(out)
            }
        }
    }

    private func bindParametersLocked(
        statement: CPointer<Unit>,
        parameters: Array<SqlParameter>,
        textValues: ArrayList<CString>,
        blobValues: ArrayList<CPointer<UInt8>>
    ): Unit {
        for (offset in 0..parameters.size) {
            let index = Int32(offset + 1)
            let code = match (parameters[offset]) {
                case SqlParameter.Text(value) =>
                    let raw = unsafe { LibC.mallocCString(value) }
                    textValues.add(raw)
                    unsafe { sqlite3_bind_text(statement, index, raw, -1, CPointer<Unit>()) }
                case SqlParameter.Int64Value(value) =>
                    unsafe { sqlite3_bind_int64(statement, index, value) }
                case SqlParameter.Blob(value) =>
                    if (value.isEmpty()) {
                        unsafe { sqlite3_bind_zeroblob(statement, index, 0) }
                    } else {
                        let raw = unsafe { LibC.malloc<UInt8>(count: value.size) }
                        for (byteIndex in 0..value.size) {
                            unsafe { raw.write(byteIndex, value[byteIndex]) }
                        }
                        blobValues.add(raw)
                        unsafe {
                            sqlite3_bind_blob(
                                statement,
                                index,
                                raw,
                                Int32(value.size),
                                CPointer<Unit>()
                            )
                        }
                    }
                case SqlParameter.Null => unsafe { sqlite3_bind_null(statement, index) }
            }
            if (code != SQLITE_OK) { failLocked("bind", code) }
        }
    }

    private func scalarIntLocked(sql: String): Int64 {
        let rows = queryLocked(sql)
        if (rows.size != 1 || rows[0].size < 1) {
            throw IllegalStateException("SQLite scalar query returned no row")
        }
        Int64.parse(rows[0].required(0))
    }

    private func failLocked(action: String, code: Int32): Nothing {
        let detail = unsafe {
            let value = sqlite3_errmsg(handle)
            if (value.isNull()) { "" } else { CString(value).toString() }
        }
        throw IllegalStateException(
            "SQLite " + action + " failed with code " + code.toString() +
                if (detail == "") { "" } else { ": " + detail }
        )
    }

    private func ensureOpenLocked(): Unit {
        if (closed || handle.isNull()) {
            throw IllegalStateException("SQLite database is closed")
        }
    }
}

public func sqliteText(value: String): String {
    "'" + value.replace("'", "''") + "'"
}

@When[os != "Windows"]
foreign func sqlite3_open_v2(
    filename: CString,
    database: CPointer<CPointer<Unit>>,
    flags: Int32,
    vfs: CString
): Int32
@When[os != "Windows"]
foreign func sqlite3_close_v2(database: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_exec(
    database: CPointer<Unit>,
    sql: CString,
    callback: CPointer<Unit>,
    context: CPointer<Unit>,
    error: CPointer<CString>
): Int32
@When[os != "Windows"]
foreign func sqlite3_prepare_v2(
    database: CPointer<Unit>,
    sql: CString,
    bytes: Int32,
    statement: CPointer<CPointer<Unit>>,
    tail: CPointer<CString>
): Int32
@When[os != "Windows"]
foreign func sqlite3_step(statement: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_text(
    statement: CPointer<Unit>,
    index: Int32,
    value: CString,
    bytes: Int32,
    destructor: CPointer<Unit>
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_int64(
    statement: CPointer<Unit>,
    index: Int32,
    value: Int64
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_blob(
    statement: CPointer<Unit>,
    index: Int32,
    value: CPointer<UInt8>,
    bytes: Int32,
    destructor: CPointer<Unit>
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_zeroblob(
    statement: CPointer<Unit>,
    index: Int32,
    bytes: Int32
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_null(statement: CPointer<Unit>, index: Int32): Int32
@When[os != "Windows"]
foreign func sqlite3_finalize(statement: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_column_count(statement: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_column_text(statement: CPointer<Unit>, column: Int32): CPointer<UInt8>
@When[os != "Windows"]
foreign func sqlite3_column_bytes(statement: CPointer<Unit>, column: Int32): Int32
@When[os != "Windows"]
foreign func sqlite3_errmsg(database: CPointer<Unit>): CPointer<UInt8>
