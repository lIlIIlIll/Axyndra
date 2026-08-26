package persistence_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import agent_store.*
import model_adapters.*

// Pre-canonical ToolPipeline intent state. Agent-owned calls are promoted into
// the canonical operations table by DurableOperationStore after the ToolCall
// Item commit; direct product tools remain auditable here without file races.
public class SqliteToolOperationRepository <: OperationRepository {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func prepare(record: OperationRecord): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let rows = transaction.query(
                    "SELECT payload FROM tool_operation_intents WHERE id=" +
                        sqliteText(record.operationId.value)
                )
                if (rows.size == 1) {
                    return match (decodeOperation(rows[0].required(0))) {
                        case Result.Ok(existing) => if (
                            existing.runId.value == record.runId.value &&
                            existing.requestDigest == record.requestDigest
                        ) { Result.Ok(()) } else {
                            operationConflict<Unit>("operation id has a different request digest")
                        }
                        case Result.Err(error) => Result.Err(error)
                    }
                }
                transaction.execute(
                    "INSERT INTO tool_operation_intents(id,run_id,state,payload,revision) VALUES(" +
                        sqliteText(record.operationId.value) + "," + sqliteText(record.runId.value) + "," +
                        sqliteText(operationStatusName(record.status)) + "," +
                        sqliteText(encodeOperation(record)) + ",1)"
                )
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_operation_prepare", error.message)
        }
    }

    public func transition(
        operationId: OperationId,
        expected: OperationStatus,
        next: OperationStatus
    ): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let rows = transaction.query(
                    "SELECT payload,state FROM tool_operation_intents WHERE id=" + sqliteText(operationId.value)
                )
                if (rows.size != 1) { return sqliteToolMissing<Unit>("operation", operationId.value) }
                if (rows[0].required(1) != operationStatusName(expected)) {
                    return operationConflict<Unit>("operation state changed concurrently")
                }
                let current = match (decodeOperation(rows[0].required(0))) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let updated = OperationRecord(
                    current.operationId, current.runId, next, current.capability,
                    current.requestDigest, call: current.call
                )
                transaction.execute(
                    "UPDATE tool_operation_intents SET state=" +
                        sqliteText(operationStatusName(next)) + ",payload=" +
                        sqliteText(encodeOperation(updated)) + ",revision=revision+1 WHERE id=" +
                        sqliteText(operationId.value) + " AND state=" +
                        sqliteText(operationStatusName(expected))
                )
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_operation_transition", error.message)
        }
    }

    public func find(operationId: OperationId): Result<OperationRecord> {
        try {
            let rows = database.query(
                "SELECT payload FROM tool_operation_intents WHERE id=" + sqliteText(operationId.value)
            )
            if (rows.size != 1) { return sqliteToolMissing<OperationRecord>("operation", operationId.value) }
            decodeOperation(rows[0].required(0))
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_operation_read", error.message)
        }
    }

    public func receipt(operationId: OperationId): Result<OperationReceipt> {
        try {
            let rows = database.query(
                "SELECT payload FROM tool_operation_intent_receipts WHERE operation_id=" +
                    sqliteText(operationId.value)
            )
            if (rows.size != 1) { return sqliteToolMissing<OperationReceipt>("receipt", operationId.value) }
            match (decodeReceipt(rows[0].required(0))) {
                case Result.Ok(value) => if (value.operationId.value == operationId.value) {
                    Result.Ok(value)
                } else {
                    operationConflict<OperationReceipt>("receipt operation binding is corrupt")
                }
                case Result.Err(error) => Result.Err(error)
            }
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_receipt_read", error.message)
        }
    }

    public func saveReceipt(receipt: OperationReceipt): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                if (transaction.query(
                    "SELECT id FROM tool_operation_intents WHERE id=" +
                        sqliteText(receipt.operationId.value)
                ).size != 1) {
                    return sqliteToolMissing<Unit>("operation", receipt.operationId.value)
                }
                let rows = transaction.query(
                    "SELECT payload FROM tool_operation_intent_receipts WHERE operation_id=" +
                        sqliteText(receipt.operationId.value)
                )
                if (rows.size == 1) {
                    return match (decodeReceipt(rows[0].required(0))) {
                        case Result.Ok(existing) => if (
                            existing.committed == receipt.committed &&
                            existing.isError == receipt.isError &&
                            agentValuesEqual(existing.detail, receipt.detail)
                        ) { Result.Ok(()) } else {
                            operationConflict<Unit>("operation receipt cannot be overwritten")
                        }
                        case Result.Err(error) => Result.Err(error)
                    }
                }
                transaction.execute(
                    "INSERT INTO tool_operation_intent_receipts(operation_id,payload,created_at_millis) VALUES(" +
                        sqliteText(receipt.operationId.value) + "," +
                        sqliteText(encodeReceipt(receipt)) + "," + agentUtcMillis().toString() + ")"
                )
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteToolError("persistence.sqlite_receipt_save", error.message)
        }
    }
}

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
