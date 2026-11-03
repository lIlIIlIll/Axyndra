package workspace_legacy_oracle

import agent_domain.*
import agent_host_runtime
import std.collection.*
import agent_product.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Historical test oracle only. It borrows the fixture's real SQLite handle
// and actual catalog; no production module imports this package.
public class LegacyTodoRepository {
    private let database: SqliteDatabase
    public init(database: SqliteDatabase){this.database=database}
    public func todoPhases(sessionId: SessionId): Result<AgentValue>{
        match(SqliteSessionMetadataRepository(database).legacyTodoBytes(sessionId)){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(raw)=>decodeAgentValue(raw)}
    }
    public func setTodoPhases(sessionId: SessionId, phases: AgentValue): Result<Unit> {
        if (phases.unifiedKind != ValueKind.List) {
            return metadataInvalid("persistence.todo_phases_not_list", "todo phases must be a list")
        }
        setTextField(sessionId, "todo_payload", encodeAgentValue(phases))
    }

    private func setTextField(sessionId: SessionId, field: String, value: String): Result<Unit> {
        if(field!="todo_payload"){return metadataInvalid("oracle.todo_field_invalid","historical Todo oracle has one fixed cold field")}
        try {
            database.transaction<Unit>({ transaction =>
                ensureMetadataRow(transaction, sessionId)
                transaction.execute("UPDATE thread_metadata SET todo_payload="+sqliteText(value)+" WHERE thread_id="+sqliteText(sessionId.value))
            })
            Result.Ok(())
        }catch(error:Exception){metadataStorage("persistence.session_metadata_write",error.message)}
    }
}

func ensureMetadataRow(transaction: SqliteTransaction, sessionId: SessionId): Unit {
    transaction.execute(
        "INSERT OR IGNORE INTO thread_metadata(thread_id,name,summary,updated_at_millis,model," +
            "workspace_root,cwd,fast_mode,parent_thread_ref,work_mode,draft,todo_payload,goal_payload) VALUES(" +
            sqliteText(sessionId.value) + ",'','',0,'','','',0,'','','','','')"
    )
}

func metadataInvalid<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}

func metadataStorage<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Internal, code, message))
}
func installLegacyTodoTools(
    catalog: ToolCatalog,
    todoRepository: ?LegacyTodoRepository
): Result<Unit> {
    match (todoRepository) {
        case Some(repository) => match (catalog.register(
            ToolDescriptor(
                ModelToolDefinition(
                    "todo",
                    "Manage a structured todo list for this session.",
                    objectSchema(
                        [
                            schemaEnumProperty(
                                "op",
                                [
                                    "init",
                                    "start",
                                    "done",
                                    "rm",
                                    "drop",
                                    "block",
                                    "unblock",
                                    "append",
                                    "view"
                                ]
                            ),
                            todoInitListSchemaProperty(),
                            schemaProperty("task", "string"),
                            schemaProperty("phase", "string"),
                            schemaStringListProperty("items"),
                            schemaProperty("reason", "string")
                        ],
                        ["op"]
                    )
                ),
                Capability(CapabilityKind.WorkspaceRead)
            ),
            TodoTool(repository)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        case None => ()
    }
    Result.Ok(())
}

func todoInitListSchemaProperty(): ValueField {
    ValueField(
        "list",
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField(
                    "items",
                    objectValue(
                        [
                            ValueField("type", textValue("object")),
                            ValueField(
                                "properties",
                                objectValue(
                                    [
                                        schemaProperty("phase", "string"),
                                        ValueField(
                                            "items",
                                            objectValue(
                                                [
                                                    ValueField("type", textValue("array")),
                                                    ValueField("items",
                                                        objectValue([ValueField("type", textValue("string"))])),
                                                    ValueField("minItems", integerValue(1))
                                                ]
                                            )
                                        )
                                    ]
                                )
                            ),
                            ValueField(
                                "required",
                                listValue(
                                    [
                                        textValue("phase"),
                                        textValue("items")
                                    ]
                                )
                            ),
                            ValueField("additionalProperties", boolValue(false))
                        ]
                    )
                )
            ]
        )
    )
}

func schemaEnumProperty(
    name: String,
    values: Array<String>
): ValueField {
    let encoded = ArrayList<AgentValue>()
    for (value in values) {
        encoded.add(textValue(value))
    }
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("string")),
                ValueField("enum", listValue(encoded.toArray()))
            ]
        )
    )
}

func schemaStringListProperty(name: String): ValueField {
    agent_host_runtime.hostSchemaStringListProperty(name)
}

