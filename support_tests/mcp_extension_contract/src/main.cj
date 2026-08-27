package mcp_extension_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_extensions.*
import agent_mcp.*
import tool_runtime.*

main(): Int64 {
    let tool = McpTool(
        "read-file",
        "Read a fixture file through MCP.",
        objectValue([
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue([]))
        ]),
        annotations: objectValue([
            ValueField("readOnlyHint", boolValue(true))
        ])
    )
    let host = MemoryMcpToolHost(
        [tool],
        {name, arguments, continuation =>
            let _ = continuation
            Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                [objectValue([
                    ValueField("type", textValue("text")),
                    ValueField("text", textValue("fixture"))
                ])],
                structuredContent: objectValue([
                    ValueField("name", textValue(name)),
                    ValueField("arguments", arguments)
                ])
            )))
        }
    )
    let client = McpClient(
        FakeMcpTransport(McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("bridge-server", "1")),
            host
        )),
        McpRequestMeta(clientInfo: McpImplementationInfo("bridge-client", "1"))
    )
    let extension = discoverMcpExtension(
        "fixture server",
        client,
        1000
    ).value().getOrThrow()
    let contributions = extension.tools()
    expect(
        extension.id() == "mcp:fixture server" &&
            contributions.size == 1 &&
            contributions[0].descriptor.definition.name ==
                "mcp__fixture_server__read_file" &&
            contributions[0].descriptor.sideEffecting,
        "untrusted remote readOnlyHint cannot suppress host approval"
    )
    let trusted = discoverMcpExtension(
        "fixture server",
        client,
        1001,
        trustedReadOnlyTools: ["read-file"]
    ).value().getOrThrow()
    expect(
        !trusted.tools()[0].descriptor.sideEffecting,
        "an exact local trust policy may mark one MCP tool read-only"
    )
    let result = contributions[0].executor.execute(
        ToolInvocationContext(
            RunId("mcp-run"),
            SessionId("mcp-session"),
            CapabilitySet(values: [
                Capability(CapabilityKind.ExtensionInvoke, resource: "fixture server")
            ])
        ),
        ToolCall(
            "mcp-call",
            contributions[0].descriptor.definition.name,
            objectValue([ValueField("path", textValue("README.md"))])
        )
    ).value().getOrThrow()
    expect(
        !result.isError && result.callId == "mcp-call" &&
            result.output.field("structuredContent").getOrThrow()
                .field("name").getOrThrow().text == "read-file",
        "MCP Tool Runtime executor invokes the original remote tool and maps its result"
    )
    expect(client.close().isOk(), "MCP extension client closes its transport")

    let taskError = executeOutcome(
        McpCallToolOutcome.Task(McpTask(
            "task-1",
            McpTaskStatus.Working,
            "2026-08-27T00:00:00Z",
            "2026-08-27T00:00:00Z",
            None
        )),
        clientCapabilities: McpClientCapabilities(extensions: objectValue([
            ValueField("io.modelcontextprotocol/tasks", objectValue([]))
        ]))
    ).error().getOrThrow()
    expect(
        taskError.kind == AgentErrorKind.Conflict &&
            taskError.code == "mcp.tool_task_pending" &&
            errorField(taskError, "task_id") == "task-1",
        "generic MCP extension executor preserves task identity without claiming completion"
    )

    let extensionError = executeOutcome(McpCallToolOutcome.Extension(
        "com.example/custom-result",
        objectValue([ValueField("resultType", textValue("com.example/custom-result"))])
    )).error().getOrThrow()
    expect(
        extensionError.kind == AgentErrorKind.Protocol &&
            extensionError.code == "mcp.tool_result_type_unsupported" &&
            errorField(extensionError, "result_type") == "com.example/custom-result",
        "generic MCP extension executor rejects result types without an explicit product adapter"
    )
    println("mcp extension contract passed")
    0
}

func executeOutcome(
    outcome: McpCallToolOutcome,
    clientCapabilities!: McpClientCapabilities = McpClientCapabilities()
): Result<ToolResult> {
    let tool = McpTool(
        "fixture-outcome",
        "Return a fixture MCP outcome.",
        objectValue([
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue([]))
        ])
    )
    let client = McpClient(
        FakeMcpTransport(McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("outcome-server", "1")),
            MemoryMcpToolHost([tool], {_, _, _ => Result.Ok(outcome)})
        )),
        McpRequestMeta(
            clientInfo: McpImplementationInfo("outcome-client", "1"),
            clientCapabilities: clientCapabilities
        )
    )
    let extension = discoverMcpExtension("outcome server", client, 2000)
        .value().getOrThrow()
    let result = extension.tools()[0].executor.execute(
        ToolInvocationContext(
            RunId("outcome-run"),
            SessionId("outcome-session"),
            CapabilitySet(values: [
                Capability(CapabilityKind.ExtensionInvoke, resource: "outcome server")
            ])
        ),
        ToolCall(
            "outcome-call",
            extension.tools()[0].descriptor.definition.name,
            objectValue([])
        )
    )
    expect(client.close().isOk(), "outcome MCP extension client closes its transport")
    result
}

func errorField(error: AgentError, name: String): String {
    for (field in error.fields where field.name == name) { return field.value }
    ""
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}
