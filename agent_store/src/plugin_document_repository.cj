package agent_store

import agent_domain.*
import std.convert.*

class PluginDocumentGuardFailure <: Exception {
    let failure: AgentError
    init(failure: AgentError) { super(failure.message); this.failure = failure }
}

// A data snapshot, never an execution capability. The trusted caller must
// independently bind the actual Thread/lane, installed namespace and source.
public class PluginDocumentSnapshot {
    public let threadId: ThreadId
    public let laneId: LaneId
    public let namespace: String
    public let key: String
    public let revision: Int64
    public let encoded: String
    public init(threadId: ThreadId, laneId: LaneId, namespace: String, key: String,
        revision: Int64, encoded: String) {
        this.threadId = threadId; this.laneId = laneId; this.namespace = namespace
        this.key = key; this.revision = revision; this.encoded = encoded
    }
    public func decode(): Result<AgentValue> { decodeAgentValue(encoded, maxBytes: 8388608) }
}

// Uses the canonical database connection and its existing transaction owner.
// This repository is never handed to a plugin process or serialized to IPC.
public class SqlitePluginDocumentRepository {
    private let database: SqliteDatabase
    public init(database: SqliteDatabase) { this.database = database }

    public func read(threadId: ThreadId, laneId: LaneId, namespace: String,
        key: String): Result<PluginDocumentSnapshot> {
        if (!documentIdentity(threadId, laneId, namespace, key)) { return documentFailure("plugin.document_identity") }
        try {
            match(database.readDocumentStorageBackend(threadId,laneId,namespace,key)){case Some(snapshot)=>return Result.Ok(snapshot);case None=>()}
            let rows = database.query("SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
                [SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value), SqlParameter.Text(namespace), SqlParameter.Text(key)])
            if (rows.isEmpty()) { return Result.Ok(PluginDocumentSnapshot(threadId, laneId, namespace, key, 0, "null")) }
            let revision = Int64.parse(rows[0].required(0))
            if (revision <= 0 || rows[0].required(1).size > 8388608) { return documentFailure("plugin.document_corrupt") }
            Result.Ok(PluginDocumentSnapshot(threadId, laneId, namespace, key, revision, rows[0].required(1)))
        } catch (error: Exception) { documentFailure("plugin.document_read", message: error.message) }
    }

    // Exact revision and raw prior payload exclude lost updates and ABA. A
    // clear stores a null tombstone with a new revision; it never resets zero.
    // guard runs inside the same transaction immediately before SQL writes.
    // It is a Host callback and must not call back into this database lock.
    public func compareExchange(expected: PluginDocumentSnapshot, next: AgentValue,
        guard: (SqliteTransaction) -> Result<Unit>): Result<PluginDocumentSnapshot> {
        if (!documentIdentity(expected.threadId, expected.laneId, expected.namespace, expected.key) ||
            expected.revision < 0 || expected.revision == 9223372036854775807 ||
            expected.encoded.size > 8388608 || (expected.revision == 0 && expected.encoded != "null")) {
            return documentFailure("plugin.document_expected_invalid") }
        let encoded = encodeAgentValue(next)
        if (encoded.size > 8388608) { return documentFailure("plugin.document_size") }
        try {
            database.transaction<Result<PluginDocumentSnapshot>>({ transaction =>
                requirePluginDocumentVersion(transaction, expected)
                match (guard(transaction)) { case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(_) => () }
                Result.Ok(compareExchangePluginDocumentInTransaction(transaction, expected, encoded))
            })
        } catch (error: PluginDocumentGuardFailure) { Result.Err(error.failure) }
        catch (error: Exception) { documentFailure("plugin.document_write", message: error.message) }
    }
}

func documentIdentity(threadId: ThreadId, laneId: LaneId, namespace: String, key: String): Bool {
    for (value in [threadId.value, laneId.value, namespace, key]) {
        if (value.trimAscii() == "" || value.size > 256 || value.contains("\u{0000}")) { return false }
    }
    true
}
func documentFailure<T>(code: String, message!: String = "plugin document data contract failed"): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Internal, code, message))
}
