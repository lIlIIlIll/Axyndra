package memory_contract

import agent_domain.*
import agent_product.*
import persistence_runtime.*
import std.collection.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        verifyRegisteredSchemas(root)
        verifyDurableMemoryLifecycle(root)
        verifyManagedSkills(root)
        println("memory contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func verifyRegisteredSchemas(root: String): Unit {
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/settings",
        stateRoot: root + "/product-state",
        workspaceRoot: root,
        fixture: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
    expectToolSchema(
        product,
        "memory_edit",
        [
            "op", "id", "content", "context", "importance", "kind",
            "scope", "scope_key", "expires_at", "replacement_id",
            "conflict_ids", "reason"
        ],
        ["op", "id"]
    )
    expectToolSchema(product, "retain", ["items"], ["items"])
    expectToolSchema(
        product,
        "recall",
        ["query", "scope", "scope_key", "kinds", "limit"],
        ["query"]
    )
    expectToolSchema(
        product,
        "reflect",
        ["query", "context", "scope", "scope_key", "kinds", "limit"],
        ["query"]
    )
    expectToolSchema(
        product,
        "learn",
        [
            "memory", "context", "importance", "kind", "scope",
            "scope_key", "expires_at", "skill"
        ],
        ["memory"]
    )
    expectToolSchema(
        product,
        "manage_skill",
        ["action", "name", "description", "body"],
        ["action", "name"]
    )
    let retain = toolDefinition(product, "retain")
    let items = retain.inputSchema.field("properties").getOrThrow()
        .field("items").getOrThrow()
    expect(
        items.field("minItems").getOrThrow().number == "1" &&
        propertyNames(items.field("items").getOrThrow()) ==
            [
                "content", "context", "importance", "kind", "scope",
                "scope_key", "expires_at"
            ] &&
        requiredNames(items.field("items").getOrThrow()) == ["content"],
        "retain exposes the Memory v3 kind, scope, importance, and expiry schema"
    )
    let edit = toolDefinition(product, "memory_edit")
    expect(
        enumNames(
            edit.inputSchema.field("properties").getOrThrow()
                .field("op").getOrThrow()
        ) == [
            "correct", "update", "delete", "forget", "invalidate",
            "mark_conflict", "resolve_conflict"
        ],
        "memory_edit exposes correction, tombstone, and conflict operations"
    )
    let learn = toolDefinition(product, "learn")
    let skill = learn.inputSchema.field("properties").getOrThrow()
        .field("skill").getOrThrow()
    expect(
        propertyNames(skill) ==
            ["action", "name", "description", "body"] &&
        requiredNames(skill) ==
            ["action", "name", "description", "body"] &&
        enumNames(
            skill.field("properties").getOrThrow()
                .field("action").getOrThrow()
        ) == ["create", "update"],
        "learn skill payload is fully represented instead of ignored"
    )
}

func verifyDurableMemoryLifecycle(root: String): Unit {
    let stateRoot = root + "/memory-state"
    let settingsRoot = root + "/memory-settings"
    let runtime = memoryRuntime(stateRoot, settingsRoot, root)
    let context = memoryContext(root)
    let retained = invoke(
        runtime,
        context,
        ToolCall(
            "retain",
            "retain",
            objectValue([
                ValueField("items", listValue([
                    objectValue([
                        ValueField(
                            "content",
                            textValue("DeepSeek uses DEEPSEEK_API_KEY")
                        ),
                        ValueField(
                            "context",
                            textValue("provider configuration")
                        ),
                        ValueField("importance", numberValue("0.8")),
                        ValueField("kind", textValue("project_fact")),
                        ValueField("scope", textValue("workspace")),
                        ValueField("scope_key", textValue(root))
                    ]),
                    objectValue([
                        ValueField(
                            "content",
                            textValue("Memory ids must remain stable")
                        ),
                        ValueField("kind", textValue("constraint")),
                        ValueField("scope", textValue("session")),
                        ValueField("scope_key", textValue("memory-session"))
                    ]),
                    objectValue([
                        ValueField(
                            "content",
                            textValue("Temporary release freeze")
                        ),
                        ValueField("kind", textValue("observation")),
                        ValueField("scope", textValue("workspace")),
                        ValueField("scope_key", textValue(root)),
                        ValueField("expires_at", integerValue(1))
                    ])
                ]))
            ])
        )
    )
    let ids = retained.output.field("ids").getOrThrow().items
    let retainedRecords = retained.output.field("memories").getOrThrow().items
    expect(
        retained.output.field("content").getOrThrow().text ==
            "3 memories stored." &&
        ids.size == 3 &&
        ids[0].text.startsWith("memv3-") &&
        ids[0].text != ids[1].text &&
        retainedRecords[0].field("kind").getOrThrow().text == "project_fact" &&
        retainedRecords[0].field("scope").getOrThrow().text == "workspace" &&
        retainedRecords[1].field("scope").getOrThrow().text == "session" &&
        retainedRecords[2].field("expiresAt").getOrThrow().number == "1",
        "retain writes real Memory v3 kind, scope, and expiry records"
    )

    let restarted = memoryRuntime(stateRoot, settingsRoot, root)
    let recalled = invoke(
        restarted,
        context,
        ToolCall(
            "recall",
            "recall",
            objectValue([
                ValueField("query", textValue("DeepSeek API key")),
                ValueField("scope", textValue("workspace")),
                ValueField("scope_key", textValue(root)),
                ValueField("kinds", listValue([textValue("project_fact")])),
                ValueField("limit", integerValue(1))
            ])
        )
    )
    expect(
        recalled.output.field("count").getOrThrow().number == "1" &&
        recalled.output.field("content").getOrThrow().text
            .contains("(id: " + ids[0].text + ")") &&
        recalled.output.field("memories").getOrThrow().items[0]
            .field("content").getOrThrow().text ==
                "DeepSeek uses DEEPSEEK_API_KEY" &&
        recalled.output.field("memories").getOrThrow().items[0]
            .field("kind").getOrThrow().text == "project_fact" &&
        recalled.output.field("memories").getOrThrow().items[0]
            .field("scopeKey").getOrThrow().text == root &&
        recalled.output.field("strategy").getOrThrow().text == "lexical",
        "recall applies real durable scope, kind, and limit filters after restart"
    )
    let sessionRecall = invoke(
        restarted,
        context,
        ToolCall(
            "session-recall",
            "recall",
            objectValue([
                ValueField("query", textValue("stable memory ids")),
                ValueField("scope", textValue("session")),
                ValueField("scope_key", textValue("memory-session")),
                ValueField("kinds", listValue([textValue("constraint")]))
            ])
        )
    )
    expect(
        sessionRecall.output.field("count").getOrThrow().number == "1" &&
        sessionRecall.output.field("memories").getOrThrow().items[0]
            .field("scope").getOrThrow().text == "session",
        "recall can explicitly access the active session scope"
    )
    expect(
        restarted.recall(
            context,
            ToolCall(
                "other-workspace",
                "recall",
                objectValue([
                    ValueField("query", textValue("DeepSeek")),
                    ValueField("scope", textValue("workspace")),
                    ValueField("scope_key", textValue(root + "/other"))
                ])
            )
        ).isError() &&
        restarted.recall(
            context,
            ToolCall(
                "other-session",
                "recall",
                objectValue([
                    ValueField("query", textValue("stable")),
                    ValueField("scope", textValue("session")),
                    ValueField("scope_key", textValue("other-session"))
                ])
            )
        ).isError(),
        "memory tools cannot cross the active workspace or session scope"
    )
    let foreignRecord = restarted.repository().retain(MemoryV3Draft(
        MemoryKind.ProjectFact,
        MemoryScope(MemoryScopeKind.Workspace, key: root + "/other"),
        "Foreign workspace secret"
    )).value().getOrThrow()
    expect(
        restarted.edit(
            context,
            ToolCall(
                "foreign-delete",
                "memory_edit",
                objectValue([
                    ValueField("op", textValue("delete")),
                    ValueField("id", textValue(foreignRecord.id))
                ])
            )
        ).isError() &&
        restarted.repository().get(foreignRecord.id)
            .value().getOrThrow().getOrThrow().status == MemoryStatus.Active,
        "memory mutation cannot cross the active workspace scope by id"
    )
    let expiredRecall = invoke(
        restarted,
        context,
        ToolCall(
            "expired-recall",
            "recall",
            objectValue([
                ValueField("query", textValue("release freeze")),
                ValueField("scope", textValue("workspace")),
                ValueField("scope_key", textValue(root))
            ])
        )
    )
    expect(
        expiredRecall.output.field("count").getOrThrow().number == "0" &&
        restarted.repository().get(ids[2].text)
            .value().getOrThrow().getOrThrow().status == MemoryStatus.Expired,
        "expired memories stay auditable but are withheld from real product recall"
    )
    let _ = invoke(
        restarted,
        context,
        ToolCall(
            "unicode-retain",
            "retain",
            objectValue([
                ValueField("items", listValue([
                    objectValue([
                        ValueField(
                            "content",
                            textValue("中文记忆必须遵守 UTF-8 字节预算并保持有效编码")
                        ),
                        ValueField("kind", textValue("constraint"))
                    ])
                ]))
            ])
        )
    )
    let automaticContext = restarted.contextFor(
        "DeepSeek stable release Foreign",
        SessionId("memory-session"),
        root,
        4096
    ).value().getOrThrow()
    let unicodeContext = restarted.contextFor(
        "UTF-8 字节预算",
        SessionId("memory-session"),
        root,
        128
    ).value().getOrThrow()
    expect(
        automaticContext.contains("DeepSeek uses DEEPSEEK_API_KEY") &&
        automaticContext.contains("Memory ids must remain stable") &&
        !automaticContext.contains("Temporary release freeze") &&
        !automaticContext.contains("Foreign workspace secret") &&
        memoryUtf8Size(automaticContext) <= 4096 &&
        memoryUtf8Size(unicodeContext) <= 128 &&
        restarted.contextFor(
            "anything",
            SessionId("memory-session"),
            root,
            0
        ).isError() &&
        restarted.contextFor(
            "anything",
            SessionId("memory-session"),
            root + "/other",
            4096
        ).isError() &&
        restarted.contextFor(
            "   ",
            SessionId("memory-session"),
            root,
            4096
        ).value().getOrThrow() == "",
        "request-time context is ranked, scoped, lifecycle-filtered, and UTF-8 byte bounded"
    )
    let reflected = invoke(
        restarted,
        context,
        ToolCall(
            "reflect",
            "reflect",
            objectValue([
                ValueField(
                    "query",
                    textValue("How is DeepSeek configured?")
                ),
                ValueField(
                    "context",
                    textValue("provider authentication")
                ),
                ValueField("scope", textValue("workspace")),
                ValueField("scope_key", textValue(root)),
                ValueField("kinds", listValue([textValue("project_fact")]))
            ])
        )
    )
    expect(
        reflected.output.field("content").getOrThrow().text
            .startsWith("Based on recalled memories:") &&
        reflected.output.field("content").getOrThrow().text
            .contains("DEEPSEEK_API_KEY"),
        "reflect synthesizes a grounded answer from recalled records"
    )
    let corrected = invoke(
        restarted,
        context,
        ToolCall(
            "correct",
            "memory_edit",
            objectValue([
                ValueField("op", textValue("correct")),
                ValueField("id", textValue(ids[0].text)),
                ValueField(
                    "content",
                    textValue("DeepSeek authentication uses DEEPSEEK_API_KEY")
                ),
                ValueField("context", textValue("corrected provider configuration")),
                ValueField("importance", numberValue("2.0")),
                ValueField("kind", textValue("decision"))
            ])
        )
    )
    let correctedMemory = corrected.output.field("memory").getOrThrow()
    let correctedId = correctedMemory.field("id").getOrThrow().text
    let original = restarted.repository().get(ids[0].text)
        .value().getOrThrow().getOrThrow()
    expect(
        corrected.output.field("status").getOrThrow().text == "corrected" &&
        correctedId != ids[0].text &&
        correctedMemory.field("correctionOf").getOrThrow().text == ids[0].text &&
        correctedMemory.field("kind").getOrThrow().text == "decision" &&
        correctedMemory.field("importance").getOrThrow().number == "1.000" &&
        original.status == MemoryStatus.Corrected &&
        original.replacementId == correctedId,
        "memory_edit correct appends a replacement and preserves the old record"
    )
    let correctedRecall = invoke(
        restarted,
        context,
        ToolCall(
            "corrected-recall",
            "recall",
            objectValue([
                ValueField("query", textValue("DeepSeek authentication")),
                ValueField("scope", textValue("workspace")),
                ValueField("scope_key", textValue(root)),
                ValueField("kinds", listValue([textValue("decision")]))
            ])
        )
    )
    expect(
        correctedRecall.output.field("count").getOrThrow().number == "1" &&
        correctedRecall.output.field("memories").getOrThrow().items[0]
            .field("id").getOrThrow().text == correctedId,
        "recall returns the active correction rather than the corrected record"
    )
    let forgotten = invoke(
        restarted,
        context,
        ToolCall(
            "forget",
            "memory_edit",
            objectValue([
                ValueField("op", textValue("forget")),
                ValueField("id", textValue(ids[1].text)),
                ValueField("reason", textValue("user requested deletion"))
            ])
        )
    )
    let tombstone = restarted.repository().get(ids[1].text)
        .value().getOrThrow().getOrThrow()
    expect(
        forgotten.output.field("status").getOrThrow().text == "deleted" &&
        tombstone.status == MemoryStatus.Deleted &&
        tombstone.deletionReason == "user requested deletion" &&
        tombstone.deletedAt > 0,
        "forget creates a durable deletion tombstone instead of erasing history"
    )
    let conflictSeeds = invoke(
        restarted,
        context,
        ToolCall(
            "conflict-seeds",
            "retain",
            objectValue([
                ValueField("items", listValue([
                    objectValue([
                        ValueField("content", textValue("The default port is 8080")),
                        ValueField("kind", textValue("project_fact"))
                    ]),
                    objectValue([
                        ValueField("content", textValue("The default port is 9090")),
                        ValueField("kind", textValue("project_fact"))
                    ])
                ]))
            ])
        )
    )
    let conflictIds = conflictSeeds.output.field("ids").getOrThrow().items
    let conflicted = invoke(
        restarted,
        context,
        ToolCall(
            "mark-conflict",
            "memory_edit",
            objectValue([
                ValueField("op", textValue("mark_conflict")),
                ValueField("id", textValue(conflictIds[0].text)),
                ValueField(
                    "conflict_ids",
                    listValue([textValue(conflictIds[1].text)])
                ),
                ValueField(
                    "reason",
                    textValue("two configuration sources disagree")
                )
            ])
        )
    )
    let conflictRecall = invoke(
        restarted,
        context,
        stringCall("conflict-recall", "recall", "query", "default port")
    )
    expect(
        conflicted.output.field("status").getOrThrow().text == "conflicted" &&
        conflicted.output.field("memories").getOrThrow().items.size == 2 &&
        conflictRecall.output.field("count").getOrThrow().number == "0",
        "mark_conflict withholds unresolved product memories from recall"
    )
    let resolved = invoke(
        restarted,
        context,
        ToolCall(
            "resolve-conflict",
            "memory_edit",
            objectValue([
                ValueField("op", textValue("resolve_conflict")),
                ValueField("id", textValue(conflictIds[1].text))
            ])
        )
    )
    let winner = restarted.repository().get(conflictIds[1].text)
        .value().getOrThrow().getOrThrow()
    let loser = restarted.repository().get(conflictIds[0].text)
        .value().getOrThrow().getOrThrow()
    expect(
        resolved.output.field("status").getOrThrow().text == "resolved" &&
        winner.status == MemoryStatus.Active &&
        loser.status == MemoryStatus.Corrected &&
        loser.replacementId == winner.id,
        "resolve_conflict preserves the winner and links the losing record"
    )
    expect(
        restarted.edit(
            context,
            ToolCall(
                "invalid-update",
                "memory_edit",
                objectValue([
                    ValueField("op", textValue("update")),
                    ValueField("id", textValue(ids[0].text))
                ])
            )
        ).isError() &&
        restarted.retain(
            context,
            ToolCall(
                "empty-retain",
                "retain",
                objectValue([
                    ValueField("items", listValue([]))
                ])
            )
        ).isError(),
        "memory mutations reject empty and incomplete requests"
    )
    let finalRestart = memoryRuntime(stateRoot, settingsRoot, root)
    expect(
        finalRestart.repository().get(correctedId)
            .value().getOrThrow().getOrThrow().content ==
                "DeepSeek authentication uses DEEPSEEK_API_KEY" &&
        finalRestart.repository().get(ids[1].text)
            .value().getOrThrow().getOrThrow().status == MemoryStatus.Deleted &&
        finalRestart.repository().get(conflictIds[0].text)
            .value().getOrThrow().getOrThrow().replacementId == conflictIds[1].text,
        "Memory v3 correction, tombstone, and conflict state replay after restart"
    )
}

func verifyManagedSkills(root: String): Unit {
    let stateRoot = root + "/learn-state"
    let settingsRoot = root + "/learn-settings"
    let runtime = memoryRuntime(stateRoot, settingsRoot, root)
    let context = memoryContext(root)
    let learned = invoke(
        runtime,
        context,
        ToolCall(
            "learn",
            "learn",
            objectValue([
                ValueField(
                    "memory",
                    textValue("Use the fixed OMP commit for compatibility")
                ),
                ValueField(
                    "skill",
                    objectValue([
                        ValueField("action", textValue("create")),
                        ValueField("name", textValue("OMP-AUDIT")),
                        ValueField(
                            "description",
                            textValue("Audit <skills> safely\nand consistently")
                        ),
                        ValueField(
                            "body",
                            textValue("# Audit\n\nCompare semantic events.")
                        )
                    ])
                )
            ])
        )
    )
    let skillPath = settingsRoot +
        "/managed-skills/omp-audit/SKILL.md"
    expect(
        learned.output.field("content").getOrThrow().text ==
            "Lesson stored. Created managed skill \"omp-audit\"." &&
        learned.output.field("memoryId").getOrThrow().text
            .startsWith("memv3-") &&
        exists(Path(skillPath)) &&
        String.fromUtf8(File.readFrom(skillPath))
            .contains("description: \"Audit skills safely and consistently\""),
        "learn persists the lesson and creates a bounded isolated skill"
    )
    let updated = invoke(
        runtime,
        context,
        ToolCall(
            "skill-update",
            "manage_skill",
            objectValue([
                ValueField("action", textValue("update")),
                ValueField("name", textValue("omp-audit")),
                ValueField(
                    "description",
                    textValue("Audit the fixed compatibility baseline")
                ),
                ValueField(
                    "body",
                    textValue("# Updated\n\nRun executable gates.")
                )
            ])
        )
    )
    expect(
        updated.output.field("content").getOrThrow().text ==
            "Updated managed skill \"omp-audit\" " +
                "(managed-skills/omp-audit/SKILL.md)." &&
        String.fromUtf8(File.readFrom(skillPath))
            .contains("Run executable gates."),
        "manage_skill updates an existing managed skill atomically"
    )
    let authored = settingsRoot + "/skills/reserved"
    Directory.create(authored, recursive: true)
    File.writeTo(
        authored + "/SKILL.md",
        "# Authored\n".toArray()
    )
    let before = runtime.repository().list()
        .value().getOrThrow().size
    let shadowed = invoke(
        runtime,
        context,
        ToolCall(
            "learn-shadowed",
            "learn",
            objectValue([
                ValueField(
                    "memory",
                    textValue("The lesson remains even when skill is shadowed")
                ),
                ValueField(
                    "skill",
                    objectValue([
                        ValueField("action", textValue("create")),
                        ValueField("name", textValue("reserved")),
                        ValueField(
                            "description",
                            textValue("Would be shadowed")
                        ),
                        ValueField("body", textValue("# Hidden"))
                    ])
                )
            ])
        )
    )
    expect(
        shadowed.isError &&
        shadowed.output.field("shadowed").getOrThrow().boolean &&
        runtime.repository().list().value().getOrThrow().size ==
            before + 1 &&
        !exists(Path(
            settingsRoot + "/managed-skills/reserved/SKILL.md"
        )),
        "learn reports the real partial outcome when an authored skill wins"
    )
    expect(
        runtime.manageSkill(
            context,
            ToolCall(
                "unsafe-name",
                "manage_skill",
                objectValue([
                    ValueField("action", textValue("create")),
                    ValueField("name", textValue("../escape")),
                    ValueField("description", textValue("unsafe")),
                    ValueField("body", textValue("# Unsafe"))
                ])
            )
        ).isError(),
        "managed skill names cannot escape their isolated directory"
    )
    let deleted = invoke(
        runtime,
        context,
        ToolCall(
            "skill-delete",
            "manage_skill",
            objectValue([
                ValueField("action", textValue("delete")),
                ValueField("name", textValue("omp-audit"))
            ])
        )
    )
    expect(
        deleted.output.field("content").getOrThrow().text ==
            "Deleted managed skill \"omp-audit\"." &&
        !exists(Path(skillPath)),
        "manage_skill deletes only the selected managed skill"
    )
}

func memoryRuntime(
    stateRoot: String,
    settingsRoot: String,
    workspaceRoot: String
): ProductMemoryRuntime {
    ProductMemoryRuntime(
        MemoryV3Repository(stateRoot),
        DiskManagedSkillRepository(settingsRoot),
        settingsRoot,
        workspaceRoot
    )
}

func memoryContext(workspaceRoot: String): ToolInvocationContext {
    ToolInvocationContext(
        RunId("memory-run"),
        SessionId("memory-session"),
        CapabilitySet(values: [
            Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.WorkspaceWrite)
        ]),
        toolContext: ToolContextDescriptor(
            workspaceRoot: workspaceRoot,
            cwd: workspaceRoot
        )
    )
}

func invoke(
    runtime: ProductMemoryRuntime,
    context: ToolInvocationContext,
    call: ToolCall
): ToolResult {
    match (call.name) {
        case "retain" => runtime.retain(context, call)
            .value().getOrThrow()
        case "recall" => runtime.recall(context, call)
            .value().getOrThrow()
        case "reflect" => runtime.reflect(context, call)
            .value().getOrThrow()
        case "memory_edit" => runtime.edit(context, call)
            .value().getOrThrow()
        case "learn" => runtime.learn(context, call)
            .value().getOrThrow()
        case "manage_skill" => runtime.manageSkill(context, call)
            .value().getOrThrow()
        case _ => throw IllegalStateException("unknown memory tool")
    }
}

func stringCall(
    id: String,
    name: String,
    field: String,
    value: String
): ToolCall {
    ToolCall(
        id,
        name,
        objectValue([
            ValueField(field, textValue(value))
        ])
    )
}

func expectToolSchema(
    product: ProductRuntime,
    name: String,
    properties: Array<String>,
    required: Array<String>
): Unit {
    let definition = toolDefinition(product, name)
    expect(
        propertyNames(definition.inputSchema) == properties &&
        requiredNames(definition.inputSchema) == required,
        name + " exposes the exact pinned root schema"
    )
}

func toolDefinition(
    product: ProductRuntime,
    name: String
): ModelToolDefinition {
    for (definition in product.tools() where definition.name == name) {
        return definition
    }
    throw IllegalStateException("missing product tool: " + name)
}

func propertyNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    let properties = schema.field("properties").getOrThrow()
    for (field in properties.fields) { names.add(field.name) }
    names.toArray()
}

func requiredNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("required").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func enumNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("enum").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func memoryUtf8Size(value: String): Int64 {
    unsafe { value.rawData().size }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
