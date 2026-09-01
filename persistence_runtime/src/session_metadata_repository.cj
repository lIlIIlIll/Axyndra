package persistence_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_store.*
import model_adapters.*
import std.convert.*

public interface SessionMetadataRepository {
    func name(sessionId: SessionId): Result<String>
    func setName(sessionId: SessionId, name: String): Result<Unit>
    func summary(sessionId: SessionId): Result<String>
    func setSummary(sessionId: SessionId, value: String): Result<Unit>
    func updatedAt(sessionId: SessionId): Result<Int64>
    func setUpdatedAt(sessionId: SessionId, value: Int64): Result<Unit>
    func model(sessionId: SessionId): Result<String>
    func setModel(sessionId: SessionId, model: String): Result<Unit>
    func workspaceRoot(sessionId: SessionId): Result<String>
    func workspaceCwd(sessionId: SessionId): Result<String>
    func setWorkspaceBinding(sessionId: SessionId, workspaceRoot: String, cwd: String): Result<Unit>
    func fastMode(sessionId: SessionId): Result<Bool>
    func setFastMode(sessionId: SessionId, enabled: Bool): Result<Unit>
    func parentSession(sessionId: SessionId): Result<String>
    func setParentSession(sessionId: SessionId, parentSession: String): Result<Unit>
    func workMode(sessionId: SessionId): Result<String>
    func setWorkMode(sessionId: SessionId, mode: String): Result<Unit>
    func draft(sessionId: SessionId): Result<String>
    func setDraft(sessionId: SessionId, value: String): Result<Unit>
    func todoPhases(sessionId: SessionId): Result<AgentValue>
    func setTodoPhases(sessionId: SessionId, phases: AgentValue): Result<Unit>
    func goalState(sessionId: SessionId): Result<AgentValue>
    func setGoalState(sessionId: SessionId, state: AgentValue): Result<Unit>
    func clearGoalState(sessionId: SessionId): Result<Unit>
    func copy(source: SessionId, target: SessionId): Result<Unit>
}

public class SqliteSessionMetadataRepository <: SessionMetadataRepository {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func name(sessionId: SessionId): Result<String> { textField(sessionId, "name") }

    public func setName(sessionId: SessionId, name: String): Result<Unit> {
        let value = name.trimAscii()
        if (value == "") {
            return metadataInvalid("persistence.session_name_empty", "session name must not be empty")
        }
        setTextField(sessionId, "name", value)
    }

    public func summary(sessionId: SessionId): Result<String> { textField(sessionId, "summary") }

    public func setSummary(sessionId: SessionId, value: String): Result<Unit> {
        setTextField(sessionId, "summary", value.trimAscii())
    }

    public func updatedAt(sessionId: SessionId): Result<Int64> {
        match (textField(sessionId, "updated_at_millis")) {
            case Result.Ok("") => Result.Ok(0)
            case Result.Ok(value) => try {
                Result.Ok(Int64.parse(value))
            } catch (_: Exception) {
                metadataRecovery("persistence.session_updated_invalid", "session update timestamp is corrupt")
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func setUpdatedAt(sessionId: SessionId, value: Int64): Result<Unit> {
        setIntegerField(sessionId, "updated_at_millis", max(0, value))
    }

    public func model(sessionId: SessionId): Result<String> { textField(sessionId, "model") }

    public func setModel(sessionId: SessionId, model: String): Result<Unit> {
        let value = model.trimAscii()
        if (value == "") {
            return metadataInvalid("persistence.session_model_empty", "session model must not be empty")
        }
        setTextField(sessionId, "model", value)
    }

    public func workspaceRoot(sessionId: SessionId): Result<String> {
        textField(sessionId, "workspace_root")
    }

    public func workspaceCwd(sessionId: SessionId): Result<String> { textField(sessionId, "cwd") }

    public func setWorkspaceBinding(
        sessionId: SessionId,
        workspaceRoot: String,
        cwd: String
    ): Result<Unit> {
        let canonicalRoot = match (canonicalSessionWorkspacePath(workspaceRoot, "workspace_root")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let canonicalCwd = match (canonicalSessionWorkspacePath(cwd, "cwd")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (canonicalCwd != canonicalRoot && !canonicalCwd.startsWith(canonicalRoot + "/")) {
            return metadataInvalid(
                "persistence.session_workspace_cwd_outside_root",
                "session cwd must resolve inside its workspace root"
            )
        }
        try {
            database.transaction<Unit>({ transaction =>
                ensureMetadataRow(transaction, sessionId)
                transaction.execute(
                    "UPDATE thread_metadata SET workspace_root=" + sqliteText(canonicalRoot) +
                        ",cwd=" + sqliteText(canonicalCwd) + " WHERE thread_id=" +
                        sqliteText(sessionId.value)
                )
            })
            Result.Ok(())
        } catch (error: Exception) {
            metadataStorage("persistence.session_workspace_write", error.message)
        }
    }

    public func fastMode(sessionId: SessionId): Result<Bool> {
        match (textField(sessionId, "fast_mode")) {
            case Result.Ok("1") => Result.Ok(true)
            case Result.Ok("0") | Result.Ok("") => Result.Ok(false)
            case Result.Ok(_) => metadataRecovery("persistence.session_fast_mode_invalid", "session fast mode is corrupt")
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func setFastMode(sessionId: SessionId, enabled: Bool): Result<Unit> {
        setIntegerField(sessionId, "fast_mode", if (enabled) { 1 } else { 0 })
    }

    public func parentSession(sessionId: SessionId): Result<String> {
        textField(sessionId, "parent_thread_ref")
    }

    public func setParentSession(sessionId: SessionId, parentSession: String): Result<Unit> {
        let value = parentSession.trimAscii()
        if (value == "") {
            return metadataInvalid("persistence.session_parent_empty", "parent session must not be empty")
        }
        setTextField(sessionId, "parent_thread_ref", value)
    }

    public func workMode(sessionId: SessionId): Result<String> { textField(sessionId, "work_mode") }

    public func setWorkMode(sessionId: SessionId, mode: String): Result<Unit> {
        let value = mode.trimAscii()
        if (value != "" && value != "plan" && value != "vibe") {
            return metadataInvalid(
                "persistence.session_work_mode_invalid",
                "session work mode must be plan, vibe, or empty"
            )
        }
        setTextField(sessionId, "work_mode", value)
    }

    public func draft(sessionId: SessionId): Result<String> { textField(sessionId, "draft") }

    public func setDraft(sessionId: SessionId, value: String): Result<Unit> {
        setTextField(sessionId, "draft", value)
    }

    public func todoPhases(sessionId: SessionId): Result<AgentValue> {
        valueField(sessionId, "todo_payload", listValue([]))
    }

    public func setTodoPhases(sessionId: SessionId, phases: AgentValue): Result<Unit> {
        if (phases.unifiedKind != ValueKind.List) {
            return metadataInvalid("persistence.todo_phases_not_list", "todo phases must be a list")
        }
        setTextField(sessionId, "todo_payload", encodeAgentValue(phases))
    }

    public func goalState(sessionId: SessionId): Result<AgentValue> {
        valueField(sessionId, "goal_payload", nullValue())
    }

    public func setGoalState(sessionId: SessionId, state: AgentValue): Result<Unit> {
        if (state.unifiedKind != ValueKind.Object) {
            return metadataInvalid("persistence.goal_state_not_object", "goal state must be an object")
        }
        setTextField(sessionId, "goal_payload", encodeAgentValue(state))
    }

    public func clearGoalState(sessionId: SessionId): Result<Unit> {
        setTextField(sessionId, "goal_payload", encodeAgentValue(nullValue()))
    }

    public func copy(source: SessionId, target: SessionId): Result<Unit> {
        try {
            database.transaction<Unit>({ transaction =>
                let rows = transaction.query(
                    "SELECT name,summary,updated_at_millis,model,workspace_root,cwd,fast_mode," +
                        "parent_thread_ref,work_mode,draft,todo_payload,goal_payload " +
                        "FROM thread_metadata WHERE thread_id=" + sqliteText(source.value)
                )
                if (rows.isEmpty()) { return }
                let row = rows[0]
                transaction.execute("DELETE FROM thread_metadata WHERE thread_id=" + sqliteText(target.value))
                transaction.execute(
                    "INSERT INTO thread_metadata(thread_id,name,summary,updated_at_millis,model," +
                        "workspace_root,cwd,fast_mode,parent_thread_ref,work_mode,draft,todo_payload,goal_payload) VALUES(" +
                        sqliteText(target.value) + "," + sqliteText(row.required(0)) + "," +
                        sqliteText(row.required(1)) + "," + row.required(2) + "," +
                        sqliteText(row.required(3)) + "," + sqliteText(row.required(4)) + "," +
                        sqliteText(row.required(5)) + "," + row.required(6) + "," +
                        sqliteText(row.required(7)) + "," + sqliteText(row.required(8)) + "," +
                        sqliteText(row.required(9)) + "," + sqliteText(row.required(10)) + "," +
                        sqliteText(row.required(11)) + ")"
                )
            })
            Result.Ok(())
        } catch (error: Exception) {
            metadataStorage("persistence.session_metadata_copy", error.message)
        }
    }

    private func textField(sessionId: SessionId, field: String): Result<String> {
        try {
            let rows = database.query(
                "SELECT " + field + " FROM thread_metadata WHERE thread_id=" +
                    sqliteText(sessionId.value)
            )
            if (rows.isEmpty()) { Result.Ok("") } else { Result.Ok(rows[0].required(0)) }
        } catch (error: Exception) {
            metadataStorage("persistence.session_metadata_read", error.message)
        }
    }

    private func setTextField(sessionId: SessionId, field: String, value: String): Result<Unit> {
        try {
            database.transaction<Unit>({ transaction =>
                ensureMetadataRow(transaction, sessionId)
                transaction.execute(
                    "UPDATE thread_metadata SET " + field + "=" + sqliteText(value) +
                        " WHERE thread_id=" + sqliteText(sessionId.value)
                )
            })
            Result.Ok(())
        } catch (error: Exception) {
            metadataStorage("persistence.session_metadata_write", error.message)
        }
    }

    private func setIntegerField(sessionId: SessionId, field: String, value: Int64): Result<Unit> {
        try {
            database.transaction<Unit>({ transaction =>
                ensureMetadataRow(transaction, sessionId)
                transaction.execute(
                    "UPDATE thread_metadata SET " + field + "=" + value.toString() +
                        " WHERE thread_id=" + sqliteText(sessionId.value)
                )
            })
            Result.Ok(())
        } catch (error: Exception) {
            metadataStorage("persistence.session_metadata_write", error.message)
        }
    }

    private func valueField(
        sessionId: SessionId,
        field: String,
        fallback: AgentValue
    ): Result<AgentValue> {
        match (textField(sessionId, field)) {
            case Result.Ok("") => Result.Ok(fallback)
            case Result.Ok(source) => decodeAgentValue(source)
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func ensureMetadataRow(transaction: SqliteTransaction, sessionId: SessionId): Unit {
    transaction.execute(
        "INSERT OR IGNORE INTO thread_metadata(thread_id,name,summary,updated_at_millis,model," +
            "workspace_root,cwd,fast_mode,parent_thread_ref,work_mode,draft,todo_payload,goal_payload) VALUES(" +
            sqliteText(sessionId.value) + ",'','',0,'','','',0,'','','','[]','null')"
    )
}

func metadataInvalid<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}

func metadataRecovery<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message))
}

func metadataStorage<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Internal, code, message))
}
