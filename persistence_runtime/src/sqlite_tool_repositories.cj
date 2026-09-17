package persistence_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import agent_store.*
import model_adapters.*


public class SqliteAuditRepository <: AuditPort {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func append(event: AgentEvent): Result<Unit> {
        try {
            let threadRows = database.query(
                "SELECT thread_id FROM runs WHERE id=" + sqliteText(event.runId.value)
            )
            let thread = if (threadRows.size == 1) {
                sqliteText(threadRows[0].required(0))
            } else {
                "NULL"
            }
            database.execute(
                "INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(" +
                    thread + "," + sqliteText(event.runId.value) + ",NULL,'tool_audit'," +
                    sqliteText(encodeEvent(event)) + "," + agentUtcMillis().toString() + ")"
            )
            Result.Ok(())
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_audit_append", error.message)
        }
    }
}

public class SqlitePermissionRepository <: PermissionRepository {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func allows(sessionId: SessionId, scope: ApprovalGrantScope): Result<Bool> {
        try {
            let rows = database.query(
                "SELECT payload FROM session_permission_grants WHERE thread_id=" +
                    sqliteText(sessionId.value)
            )
            for (row in rows) {
                let value = match (decodeAgentValue(row.required(0), maxBytes: 67108864)) {
                    case Result.Ok(item) => item
                    case Result.Err(error) => return Result.Err(error)
                }
                if (storedApprovalGrantAllows(value, scope)) { return Result.Ok(true) }
            }
            Result.Ok(false)
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_permission_read", error.message)
        }
    }

    public func grant(sessionId: SessionId, scope: ApprovalGrantScope): Result<Unit> {
        let payload = encodeAgentValue(objectValue([
            ValueField("capability", textValue(scope.capability)),
            ValueField("path_prefix", textValue(scope.pathPrefix)),
            ValueField("tool_name", textValue(scope.toolName)),
            ValueField("host", textValue(scope.host)),
            ValueField("session_only", boolValue(true))
        ]))
        try {
            database.execute(
                "INSERT OR IGNORE INTO session_permission_grants(thread_id,digest,payload,created_at_millis) VALUES(" +
                    sqliteText(sessionId.value) + "," + sqliteText(payload) + "," +
                    sqliteText(payload) + "," + agentUtcMillis().toString() + ")"
            )
            Result.Ok(())
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_permission_grant", error.message)
        }
    }
}

func sqliteToolMissing<T>(kind: String, id: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "persistence.not_found",
        kind + " was not found",
        fields: [ErrorField(kind + "_id", id)]
    ))
}

func sqliteToolError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Internal, code, message))
}
