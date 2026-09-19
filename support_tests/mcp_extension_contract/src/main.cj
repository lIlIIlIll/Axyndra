package mcp_extension_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_extensions.*
import agent_mcp.*
import agent_ports.*
import agent_runtime.*
import agent_testkit.*
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
    let result = executeContribution(
        contributions[0],
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

    let taskResult = executeOutcome(
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
    ).value().getOrThrow()
    expect(
        taskResult.isError &&
            taskResult.output.field("error_kind").getOrThrow().text == "conflict" &&
            taskResult.output.field("error").getOrThrow().text == "mcp.tool_task_pending" &&
            toolResultErrorField(taskResult, "task_id") == "task-1",
        "generic MCP extension executor preserves task identity without claiming completion"
    )

    let extensionResult = executeOutcome(McpCallToolOutcome.Extension(
        "com.example/custom-result",
        objectValue([ValueField("resultType", textValue("com.example/custom-result"))])
    )).value().getOrThrow()
    expect(
        extensionResult.isError &&
            extensionResult.output.field("error_kind").getOrThrow().text == "protocol" &&
            extensionResult.output.field("error").getOrThrow().text ==
                "mcp.tool_result_type_unsupported" &&
            toolResultErrorField(extensionResult, "result_type") ==
                "com.example/custom-result",
        "generic MCP extension executor rejects result types without an explicit product adapter"
    )
    println("mcp extension contract passed")
    0
}

func executeContribution(
    contribution: TrustedToolContribution,
    context: ToolInvocationContext,
    call: ToolCall
): Result<ToolResult> {
    let catalog = ToolCatalog()
    match (catalog.register(contribution.descriptor, contribution.executor)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    let pipeline = ToolPipeline(
        catalog,
        InMemoryOperationRuntimePort(),
        McpContractAudit(),
        McpContractIds(call.callId),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    match (executePipelineCall(pipeline, context, call)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(ToolInvocationResult.Completed(result)) =>
            Result.Ok(result)
        case Result.Ok(ToolInvocationResult.NeedsApproval(_)) =>
            Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "mcp.contract_approval_required",
                "MCP extension contract fixture unexpectedly requires approval"
            ))
        case Result.Ok(ToolInvocationResult.Denied(_)) =>
            Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "mcp.contract_denied",
                "MCP extension contract fixture unexpectedly denied the operation"
            ))
    }
}

class McpContractAudit <: AuditPort {
    public func append(event: AgentEvent): Result<Unit> {
        let _ = event
        Result.Ok(())
    }
}

class McpContractIds <: IdGenerator {
    private let operationName: String

    init(operationName: String) {
        this.operationName = operationName
    }

    public func nextRunId(): RunId { RunId("mcp-contract-run") }
    public func nextSessionId(): SessionId { SessionId("mcp-contract-session") }
    public func nextOperationId(): OperationId {
        OperationId("mcp-contract-" + operationName)
    }
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
        ]),
        execution: Some(McpToolExecution(taskSupport: McpTaskSupport.Optional))
    )
    let client = McpClient(
        FakeMcpTransport(McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("outcome-server", "1")),
            MemoryMcpToolHost([tool], {_, _, _ => Result.Ok(outcome)}),
            taskProvider: Some(ContractMcpTaskProvider())
        )),
        McpRequestMeta(
            clientInfo: McpImplementationInfo("outcome-client", "1"),
            clientCapabilities: clientCapabilities
        )
    )
    let extension = discoverMcpExtension("outcome server", client, 2000)
        .value().getOrThrow()
    let result = executeContribution(
        extension.tools()[0],
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

func toolResultErrorField(result: ToolResult, name: String): String {
    let fields = result.output.field("fields").getOrThrow()
    for (entry in fields.items) {
        if (entry.field("name").getOrThrow().text == name) {
            return entry.field("value").getOrThrow().text
        }
    }
    ""
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}

class ContractMcpTaskProvider <: McpTaskProvider {
    private let task: McpTask

    init() {
        this.task = McpTask(
            "fixture-task",
            McpTaskStatus.Working,
            "2026-08-27T00:00:00Z",
            "2026-08-27T00:00:00Z",
            None
        )
    }

    public func getTask(taskId: String): Result<McpTask> {
        let _ = taskId
        Result.Ok(task)
    }

    public func updateTask(taskId: String, inputResponses: JsonNode): Result<Unit> {
        let _ = taskId
        let _ = inputResponses
        Result.Ok(())
    }

    public func cancelTask(taskId: String): Result<Unit> {
        let _ = taskId
        Result.Ok(())
    }
}
