package agent_product

import agent_host_runtime

import agent_host_runtime.*

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*

public func installLocalTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    uriRouter!: InternalUriRouter = InternalUriRouter(),
    taskRuntime!: ?ProductTaskRuntime = None,
    checkpointDatabase!: ?SqliteDatabase = None,
    checkpointSummary!: ?(SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure> = None,
    checkpointPolicy!: ?ProductCheckpointExecutionPolicy = None<ProductCheckpointExecutionPolicy>,
    askRuntime!: AskRuntime = AskRuntime(),
    artifactStore!: ?ProductArtifactStore = None,
    allowUnsafeDirectLaunchForTests!: Bool = false,
    sandboxCaBundle!: String = ""
): Result<Unit> {
    match (installProductToolGroups(
        catalog,
        workspace,
        processes,
        uriRouter: uriRouter,
        taskRuntime: taskRuntime,
        checkpointDatabase: checkpointDatabase,
        checkpointSummary: checkpointSummary,
        checkpointPolicy: checkpointPolicy,
        askRuntime: askRuntime,
        artifactStore: artifactStore,
        allowUnsafeDirectLaunchForTests: allowUnsafeDirectLaunchForTests,
        sandboxCaBundle: sandboxCaBundle
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(())
}

func installProductToolGroups(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    uriRouter!: InternalUriRouter = InternalUriRouter(),
    taskRuntime!: ?ProductTaskRuntime = None,
    checkpointDatabase!: ?SqliteDatabase = None,
    checkpointSummary!: ?(SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure> = None,
    checkpointPolicy!: ?ProductCheckpointExecutionPolicy = None<ProductCheckpointExecutionPolicy>,
    askRuntime!: AskRuntime = AskRuntime(),
    artifactStore!: ?ProductArtifactStore = None,
    allowUnsafeDirectLaunchForTests!: Bool = false,
    shellNetworkMode!: ShellNetworkMode = ShellNetworkMode.Restricted,
    sandboxCaBundle!: String = ""
): Result<Unit> {
    match (installRequiredToolGroups(
        catalog,
        workspace,
        processes,
        uriRouter,
        taskRuntime,
        checkpointDatabase,
        checkpointSummary,
        checkpointPolicy,
        askRuntime,
        artifactStore,
        allowUnsafeDirectLaunchForTests,
        shellNetworkMode,
        sandboxCaBundle
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    Result<Unit>.Ok(())
}

func installRequiredToolGroups(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    uriRouter: InternalUriRouter,
    taskRuntime: ?ProductTaskRuntime,
    checkpointDatabase: ?SqliteDatabase,
    checkpointSummary: ?(SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure>,
    checkpointPolicy: ?ProductCheckpointExecutionPolicy,
    askRuntime: AskRuntime,
    artifactStore: ?ProductArtifactStore,
    allowUnsafeDirectLaunchForTests: Bool,
    shellNetworkMode: ShellNetworkMode,
    sandboxCaBundle: String
): Result<Unit> {
    match (installWorkspaceTools(
        catalog,
        workspace,
        processes,
        uriRouter,
        askRuntime,
        artifactStore
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    // The historical bare adapters are only explicit unsafe Support
    // fixtures. Normal production uses the actual installed Native Tool;
    // absent/disabled/missing canonical-data selection has no Host fallback.
    if (allowUnsafeDirectLaunchForTests) {
        match (installCheckpointTools(catalog, checkpointDatabase, summary: checkpointSummary, policy: checkpointPolicy)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    Result<Unit>.Ok(())
}


func installWorkspaceTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    uriRouter: InternalUriRouter,
    askRuntime: AskRuntime,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    match (registerAskTool(catalog, askRuntime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    registerProductResourceRoots(catalog, workspace, uriRouter, artifactStore)
}

func registerAskTool(
    catalog: ToolCatalog,
    askRuntime: AskRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "ask",
                "Ask the user one or more interactive questions. Answers provide information only; they cannot " +
                    "grant capabilities, change work mode, or approve a plan.",
                objectSchema([schemaAskQuestionsProperty()], ["questions"])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        AskTool(askRuntime)
    )
}

func installCheckpointTools(
    catalog: ToolCatalog,
    database: ?SqliteDatabase,
    summary!: ?(SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure> = None,
    policy!: ?ProductCheckpointExecutionPolicy = None<ProductCheckpointExecutionPolicy>,
    savePolicy!: ?ProductCheckpointSavePolicy113 = None<ProductCheckpointSavePolicy113>,
    ownedSavePolicy113!: ?ProductOwnedCheckpointSavePolicy113 = None<ProductOwnedCheckpointSavePolicy113>
): Result<Unit> {
    match (database) {
        case Some(value) =>
            let checkpoints = CheckpointRuntime(value, summary: summary, policy: policy, savePolicy: savePolicy,
                ownedSavePolicy113: ownedSavePolicy113)
            match (catalog.register(
                ToolDescriptor(
                    ModelToolDefinition(
                        "checkpoint",
                        "Create a context checkpoint before exploratory work.",
                        objectSchema([schemaProperty("goal", "string")], ["goal"])
                    ),
                    Capability(CapabilityKind.WorkspaceRead)
                ),
                CheckpointTool(checkpoints)
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (catalog.register(
                ToolDescriptor(
                    ModelToolDefinition(
                        "rewind",
                        "Replace checkpoint exploration with a concise report.",
                        objectSchema([schemaProperty("report", "string")], ["report"])
                    ),
                    Capability(CapabilityKind.WorkspaceRead)
                ),
                RewindTool(checkpoints)
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        case None => ()
    }
    Result.Ok(())
}

















func requiredString(call: ToolCall, name: String): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                Result.Ok(value.text)
            } else {
                invalidArgument(call, name, "argument must be a string")
            }
        case None => invalidArgument(call, name, "required argument is missing")
    }
}

func optionalString(call: ToolCall, name: String, fallback: String): String {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                value.text
            } else {
                fallback
            }
        case None => fallback
    }
}

func optionalInteger(call: ToolCall, name: String, fallback: Int64): Int64 {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Number) {
                try {
                    Int64.parse(value.asNumberText())
                } catch (_: Exception) {
                    fallback
                }
            } else {
                fallback
            }
        case None => fallback
    }
}

func optionalBoolean(call: ToolCall, name: String, fallback: Bool): Bool {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Boolean) {
                value.asBool()
            } else {
                fallback
            }
        case None => fallback
    }
}

func validEnvironmentName(value: String): Bool {
    if (value == "") {
        return false
    }
    let bytes = unsafe { value.rawData() }
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let allowed = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || (index > 0 && byte >= 48 &&
            byte <= 57)
        if (!allowed) {
            return false
        }
    }
    true
}

func shellQuote(value: String): String {
    "'" + value.replace("'", "'\"'\"'") + "'"
}

func invalidArgument<T>(
    call: ToolCall,
    name: String,
    message: String
): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "tool.invalid_argument",
            message,
            fields: [
                ErrorField("tool", call.name),
                ErrorField("argument", name)
            ]
        )
    )
}

func schemaProperty(name: String, kind: String): ValueField {
    agent_host_runtime.hostSchemaProperty(name, kind)
}



func schemaStringMapProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("object")),
                ValueField(
                    "additionalProperties",
                    objectValue([ValueField("type", textValue("string"))])
                )
            ]
        )
    )
}

func schemaStringListProperty(name: String): ValueField {
    agent_host_runtime.hostSchemaStringListProperty(name)
}

func schemaAskQuestionsProperty(): ValueField {
    ValueField(
        "questions",
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField("minItems", integerValue(1)),
                ValueField(
                    "items",
                    objectValue(
                        [
                            ValueField("type", textValue("object")),
                            ValueField(
                                "properties",
                                objectValue(
                                    [
                                        schemaProperty("id", "string"),
                                        schemaProperty("question", "string"),
                                        schemaProperty("header", "string"),
                                        ValueField(
                                            "options",
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
                                                                            schemaProperty("label", "string"),
                                                                            schemaProperty("description", "string"),
                                                                            schemaProperty("preview", "string")
                                                                        ]
                                                                    )
                                                                ),
                                                                ValueField("required", listValue([textValue("label")])),
                                                                ValueField(
                                                                    "additionalProperties",
                                                                    boolValue(false)
                                                                )
                                                            ]
                                                        )
                                                    )
                                                ]
                                            )
                                        ),
                                        schemaProperty("multi", "boolean"),
                                        schemaProperty("recommended", "number")
                                    ]
                                )
                            ),
                            ValueField(
                                "required",
                                listValue(
                                    [
                                        textValue("id"),
                                        textValue("question"),
                                        textValue("options")
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

func schemaAnyProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField(
                    "type",
                    listValue(
                        [
                            textValue("object"),
                            textValue("boolean"),
                            textValue("string"),
                            textValue("null")
                        ]
                    )
                )
            ]
        )
    )
}



func schemaNetworkPolicyProperty(): ValueField {
    let egressItem = objectValue([
        ValueField("type", textValue("object")),
        ValueField(
            "properties",
            objectValue([
                schemaProperty("host", "string"),
                schemaProperty("port", "number"),
                ValueField(
                    "private_addresses",
                    objectValue([
                        ValueField("type", textValue("array")),
                        ValueField(
                            "items",
                            objectValue([ValueField("type", textValue("string"))])
                        )
                    ])
                )
            ])
        ),
        ValueField("required", listValue([textValue("host"), textValue("port")])),
        ValueField("additionalProperties", boolValue(false))
    ])
    let publishItem = objectValue([
        ValueField("type", textValue("object")),
        ValueField(
            "properties",
            objectValue([
                schemaProperty("host_port", "number"),
                schemaProperty("target_port", "number")
            ])
        ),
        ValueField(
            "required",
            listValue([textValue("host_port"), textValue("target_port")])
        ),
        ValueField("additionalProperties", boolValue(false))
    ])
    ValueField(
        "network",
        objectValue([
            ValueField("type", textValue("object")),
            ValueField(
                "properties",
                objectValue([
                    schemaEnumProperty("mode", ["denied", "proxy", "host"]),
                    ValueField(
                        "egress",
                        objectValue([
                            ValueField("type", textValue("array")),
                            ValueField("items", egressItem)
                        ])
                    ),
                    ValueField(
                        "publish",
                        objectValue([
                            ValueField("type", textValue("array")),
                            ValueField("items", publishItem)
                        ])
                    )
                ])
            ),
            ValueField("required", listValue([textValue("mode")])),
            ValueField("additionalProperties", boolValue(false))
        ])
    )
}

func objectSchema(
    properties: Array<ValueField>,
    required: Array<String>
): AgentValue {
    agent_host_runtime.hostObjectSchema(properties, required)
}











type ProductProcessOperations = HostProcessOperations

func processOperations(processes: ProcessPort, prefix: String): ProductProcessOperations {
    hostProcessOperations(processes, prefix)
}
