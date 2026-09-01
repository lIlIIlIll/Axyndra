package debug_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        File.writeTo(root + "/note.txt", "before\n".toArray())
        File.writeTo(root + "/debug-target", "target\n".toArray())
        Directory.create(root + "/.omp", recursive: true)
        let adapter = canonicalize(
            Path("fixtures/fake_dap.py")
        ).toString()
        File.writeTo(
            root + "/.omp/dap.json",
            (
                "{\"adapters\":{\"contract\":{" +
                "\"command\":\"/usr/bin/python3\"," +
                "\"args\":[\"" + adapter + "\"]," +
                "\"fileTypes\":[\".contract\"]," +
                "\"launchDefaults\":{\"stopOnEntry\":true}," +
                "\"attachDefaults\":{}}}}"
            ).toArray()
        )
        let workspace = LocalWorkspace(root)
        let catalog = ToolCatalog()
        let processes = LocalProcessPort(workspace)
        expect(
            installLocalTools(
                catalog,
                workspace,
                processes,
                allowUnsafeDirectLaunchForTests: true
            ).isOk(),
            "install debug tool"
        )
        expectDebugSchema(catalog)
        let database = SqliteDatabase(root + "/state.db")
        let pipeline = ToolPipeline(
            catalog,
            SqliteToolOperationRepository(database),
            SqliteAuditRepository(database),
            ProductIds(),
            policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
        )
        let context = ToolInvocationContext(
            RunId("debug-contract"),
            SessionId("debug-contract"),
            CapabilitySet(values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite),
                Capability(CapabilityKind.ProcessSpawn)
            ])
        )
        let empty = run(
            pipeline,
            context,
            debugCall("sessions-empty", "sessions")
        )
        expect(
            empty.output.field("sessions")
                .getOrThrow().items.isEmpty(),
            "debug session registry starts empty"
        )
        let launched = run(
            pipeline,
            context,
            debugCall(
                "launch",
                "launch",
                fields: [
                    ValueField("program", textValue("debug-target")),
                    ValueField("adapter", textValue("contract")),
                    ValueField("args", listValue([
                        textValue("--contract")
                    ])),
                    ValueField("timeout", integerValue(3))
                ]
            )
        )
        let launchSnapshot = launched.output
            .field("snapshot").getOrThrow()
        expect(
            launchSnapshot.field("status").getOrThrow().text ==
                "stopped" &&
            launchSnapshot.field("threadId").getOrThrow().number == "7" &&
            launchSnapshot.field("sourcePath").getOrThrow().text ==
                root + "/note.txt",
            "launch completes initialize, reverse runInTerminal, " +
                "configurationDone and initial stack capture"
        )
        verifyBreakpoints(pipeline, context)
        verifyInspection(pipeline, context)
        verifyControl(pipeline, context)
        let output = run(
            pipeline,
            context,
            debugCall("output-check", "output")
        )
        expect(
            output.output.field("content").getOrThrow().text
                .contains("contract adapter output"),
            "debug output captures adapter output events"
        )
        let terminated = run(
            pipeline,
            context,
            debugCall("terminate", "terminate")
        )
        expect(
            terminated.output.field("snapshot").getOrThrow()
                .field("status").getOrThrow().text == "terminated",
            "terminate closes the active adapter"
        )
        let attached = run(
            pipeline,
            context,
            debugCall(
                "attach",
                "attach",
                fields: [
                    ValueField("pid", integerValue(1)),
                    ValueField("adapter", textValue("contract")),
                    ValueField("timeout", integerValue(3))
                ]
            )
        )
        expect(
            attached.output.field("snapshot").getOrThrow()
                .field("status").getOrThrow().text == "stopped",
            "attach performs the complete DAP handshake"
        )
        let _ = run(
            pipeline,
            context,
            debugCall("attach-terminate", "terminate")
        )
        processes.close()
        database.close()
        println("debug contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func verifyBreakpoints(
    pipeline: ToolPipeline,
    context: ToolInvocationContext
): Unit {
    assertAction(pipeline, context, debugCall(
        "source-breakpoint",
        "set_breakpoint",
        fields: [
            ValueField("file", textValue("note.txt")),
            ValueField("line", integerValue(1)),
            ValueField("condition", textValue("value > 0"))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "function-breakpoint",
        "set_breakpoint",
        fields: [ValueField("function", textValue("main"))]
    ))
    assertAction(pipeline, context, debugCall(
        "source-breakpoint-remove",
        "remove_breakpoint",
        fields: [
            ValueField("file", textValue("note.txt")),
            ValueField("line", integerValue(1))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "function-breakpoint-remove",
        "remove_breakpoint",
        fields: [ValueField("function", textValue("main"))]
    ))
    assertAction(pipeline, context, debugCall(
        "instruction-breakpoint",
        "set_instruction_breakpoint",
        fields: [
            ValueField(
                "instruction_reference",
                textValue("0x1000")
            ),
            ValueField("offset", integerValue(4))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "instruction-breakpoint-remove",
        "remove_instruction_breakpoint",
        fields: [
            ValueField(
                "instruction_reference",
                textValue("0x1000")
            ),
            ValueField("offset", integerValue(4))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "data-info",
        "data_breakpoint_info",
        fields: [
            ValueField("name", textValue("counter")),
            ValueField("frame_id", integerValue(70))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "data-breakpoint",
        "set_data_breakpoint",
        fields: [
            ValueField("data_id", textValue("counter-id")),
            ValueField("access_type", textValue("write"))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "data-breakpoint-remove",
        "remove_data_breakpoint",
        fields: [ValueField("data_id", textValue("counter-id"))]
    ))
}

func verifyInspection(
    pipeline: ToolPipeline,
    context: ToolInvocationContext
): Unit {
    assertAction(pipeline, context, debugCall("threads", "threads"))
    assertAction(pipeline, context, debugCall(
        "stack",
        "stack_trace",
        fields: [ValueField("levels", integerValue(2))]
    ))
    assertAction(pipeline, context, debugCall(
        "scopes",
        "scopes",
        fields: [ValueField("frame_id", integerValue(70))]
    ))
    assertAction(pipeline, context, debugCall(
        "variables",
        "variables",
        fields: [ValueField("variable_ref", integerValue(80))]
    ))
    assertAction(pipeline, context, debugCall(
        "evaluate",
        "evaluate",
        fields: [
            ValueField("expression", textValue("counter")),
            ValueField("context", textValue("watch"))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "disassemble",
        "disassemble",
        fields: [
            ValueField("instruction_count", integerValue(2)),
            ValueField("resolve_symbols", boolValue(true))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "read-memory",
        "read_memory",
        fields: [
            ValueField("memory_reference", textValue("0x1000")),
            ValueField("count", integerValue(4))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "write-memory",
        "write_memory",
        fields: [
            ValueField("memory_reference", textValue("0x1000")),
            ValueField("data", textValue("AQIDBA==")),
            ValueField("allow_partial", boolValue(false))
        ]
    ))
    assertAction(pipeline, context, debugCall(
        "modules",
        "modules",
        fields: [
            ValueField("start_module", integerValue(0)),
            ValueField("module_count", integerValue(5))
        ]
    ))
    assertAction(
        pipeline,
        context,
        debugCall("sources", "loaded_sources")
    )
    assertAction(pipeline, context, debugCall(
        "custom",
        "custom_request",
        fields: [
            ValueField("command", textValue("custom-contract")),
            ValueField("arguments", objectValue([
                ValueField("probe", boolValue(true))
            ]))
        ]
    ))
}

func verifyControl(
    pipeline: ToolPipeline,
    context: ToolInvocationContext
): Unit {
    assertAction(pipeline, context, debugCall("continue", "continue"))
    assertAction(pipeline, context, debugCall("step-over", "step_over"))
    assertAction(pipeline, context, debugCall("step-in", "step_in"))
    assertAction(pipeline, context, debugCall("step-out", "step_out"))
    assertAction(pipeline, context, debugCall("pause", "pause"))
    assertAction(pipeline, context, debugCall("output", "output"))
    assertAction(pipeline, context, debugCall("sessions", "sessions"))
}

func debugCall(
    callId: String,
    action: String,
    fields!: Array<ValueField> = []
): ToolCall {
    let values = ArrayList<ValueField>()
    values.add(ValueField("action", textValue(action)))
    for (field in fields) { values.add(field) }
    ToolCall(callId, "debug", objectValue(values.toArray()))
}

func assertAction(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    call: ToolCall
): Unit {
    let result = run(pipeline, context, call)
    expect(
        !result.isError &&
        result.output.field("success").getOrThrow().boolean,
        "debug action completes: " +
            call.arguments.field("action").getOrThrow().text
    )
}

func run(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    call: ToolCall
): ToolResult {
    match (pipeline.invoke(context, call)) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => value
        case Result.Ok(_) =>
            throw IllegalStateException(
                "debug action did not complete"
            )
        case Result.Err(error) =>
            throw IllegalStateException(
                error.code + ": " + error.message
            )
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}

func expectDebugSchema(catalog: ToolCatalog): Unit {
    let expected = [
        "action", "program", "args", "adapter", "cwd", "file",
        "line", "function", "name", "condition", "hit_condition",
        "expression", "context", "frame_id", "scope_id",
        "variable_ref", "pid", "port", "host", "levels",
        "memory_reference", "instruction_reference",
        "instruction_count", "instruction_offset", "count", "data",
        "data_id", "access_type", "command", "arguments", "offset",
        "resolve_symbols", "allow_partial", "start_module",
        "module_count", "timeout"
    ]
    for (definition in catalog.definitions()
         where definition.name == "debug") {
        let properties = definition.inputSchema
            .field("properties").getOrThrow()
        let required = definition.inputSchema
            .field("required").getOrThrow()
        expect(
            properties.unifiedKind == ValueKind.Object &&
            properties.fields.size == expected.size &&
            required.items.size == 1 &&
            required.items[0].text == "action",
            "debug schema shape matches the pinned surface"
        )
        for (name in expected) {
            expect(
                properties.field(name).isSome(),
                "debug schema includes " + name
            )
        }
        return
    }
    throw IllegalStateException("debug definition is registered")
}
