package mcp_extension_contract

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
            McpDiscoverResult(McpImplementationInfo("bridge-server", "1")),
            host
        )),
        McpRequestMeta(McpImplementationInfo("bridge-client", "1"))
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
    println("mcp extension contract passed")
    0
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}
