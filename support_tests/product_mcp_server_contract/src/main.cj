package product_mcp_server_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_mcp.*
import agent_protocol.*
import agent_product.*
import tool_runtime.*
import std.fs.*
import std.sync.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        prepare(root)
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/state",
            workspaceRoot: root + "/workspace",
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            asyncEnabled: false
        )).value().getOrThrow()
        let fullClient = McpClient(
            FakeMcpTransport(product.mcpServer(ProductMcpServerOptions(
                SessionId("product-mcp-full"),
                CapabilitySet(values: [
                    Capability(CapabilityKind.WorkspaceRead),
                    Capability(CapabilityKind.WorkspaceWrite),
                    Capability(CapabilityKind.ProcessSpawn),
                    Capability(CapabilityKind.NetworkAccess),
                    Capability(CapabilityKind.ExtensionInvoke),
                    Capability(CapabilityKind.Delegate)
                ])
            ))),
            McpRequestMeta(clientInfo: McpImplementationInfo("contract-client", "1"))
        )
        // This is the exact capability set used by `axyndra mcp-server`
        // without any explicit --allow-* option.
        let defaultClient = McpClient(
            FakeMcpTransport(product.mcpServer(ProductMcpServerOptions(
                SessionId("product-mcp-default"),
                CapabilitySet(values: [
                    Capability(CapabilityKind.WorkspaceRead)
                ])
            ))),
            McpRequestMeta(clientInfo: McpImplementationInfo("contract-client", "1"))
        )
        try {
            runDirectoryContract(fullClient, defaultClient)
            runExecutionContract(fullClient, root + "/workspace")
            runTypedRequestIdentityContract(product)
        } finally {
            expect(fullClient.close().isOk(), "full MCP client closes")
            expect(defaultClient.close().isOk(), "default MCP client closes")
            expect(product.closeMcp().isOk(), "product closes outbound MCP runtime")
        }
        println("product MCP server contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func runTypedRequestIdentityContract(product: ProductRuntime): Unit {
    let executor = ProductMcpIdentityTool()
    expect(product.registerTool(
        ToolDescriptor(
            ModelToolDefinition(
                "mcp_identity_block",
                "typed JSON-RPC identity fixture",
                objectValue([
                    ValueField("type", textValue("object")),
                    ValueField("additionalProperties", boolValue(false))
                ])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        executor
    ).isOk(), "typed identity fixture registers")
    let server = product.mcpServer(ProductMcpServerOptions(
        SessionId("product-mcp-typed-identity"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ))
    let numeric = spawn {
        server.handleRequest(productMcpIdentityRequest(jsonRpcNumberId(1)))
    }
    let textual = spawn {
        server.handleRequest(productMcpIdentityRequest(jsonRpcTextId("1")))
    }
    try {
        var waited: Int64 = 0
        while (!executor.bothStarted() && waited < 1000) {
            sleep(Duration.millisecond)
            waited += 1
        }
        expect(
            executor.bothStarted() &&
                executor.numberCallId() == "mcp-server-number:1" &&
                executor.textCallId() == "mcp-server-text:1",
            "Product MCP ToolCall ids carry the JSON-RPC id kind prefix"
        )
        expect(server.handleNotification(mcpCancellationNotification(
            jsonRpcNumberId(1),
            "cancel numeric only",
            McpRequestMeta(clientInfo: McpImplementationInfo("typed-identity-client", "1"))
        )).isOk(), "numeric MCP cancellation is accepted")

        waited = 0
        while (numeric.tryGet().isNone() && waited < 1000) {
            sleep(Duration.millisecond)
            waited += 1
        }
        expect(
            numeric.tryGet().isSome() && textual.tryGet().isNone() &&
                executor.numberCancelled() && !executor.textCancelled(),
            "numeric id 1 cancellation does not cancel text id 1"
        )
        executor.releaseText()
        let numericResponse = numeric.get()
        let textResponse = textual.get()
        expect(
            productMcpSucceeded(numericResponse) && productMcpSucceeded(textResponse),
            "typed identity fixture calls quiesce after isolated cancellation"
        )
    } finally {
        executor.releaseAll()
        expect(product.unregisterTool("mcp_identity_block"), "typed identity fixture unregisters")
    }
}

func productMcpIdentityRequest(id: JsonRpcId): JsonRpcRequest {
    JsonRpcRequest(
        id,
        MCP_METHOD_TOOLS_CALL,
        params: objectValue([
            ValueField("name", textValue("mcp_identity_block")),
            ValueField("arguments", objectValue([])),
            ValueField("_meta", McpRequestMeta(
                clientInfo: McpImplementationInfo("typed-identity-client", "1")
            ).toValue())
        ])
    )
}

func productMcpSucceeded(response: JsonRpcResponse): Bool {
    match (response.payload) {
        case JsonRpcResponsePayload.Success(_) => true
        case JsonRpcResponsePayload.Failure(_) => false
    }
}

class ProductMcpIdentityTool <: ToolExecutor {
    private let lock = Mutex()
    private var numberRunId = ""
    private var textRunId = ""
    private var numberCallIdValue = ""
    private var textCallIdValue = ""
    private let numberStartedValue = AtomicBool(false)
    private let textStartedValue = AtomicBool(false)
    private let numberReleased = AtomicBool(false)
    private let textReleased = AtomicBool(false)
    private let numberCancelledValue = AtomicBool(false)
    private let textCancelledValue = AtomicBool(false)

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let numeric = call.callId == "mcp-server-number:1"
        lock.lock()
        try {
            if (numeric) {
                numberRunId = context.runId.value
                numberCallIdValue = call.callId
            } else {
                textRunId = context.runId.value
                textCallIdValue = call.callId
            }
        } finally {
            lock.unlock()
        }
        if (numeric) {
            numberStartedValue.store(true)
            while (!numberReleased.load()) { sleep(Duration.millisecond) }
        } else {
            textStartedValue.store(true)
            while (!textReleased.load()) { sleep(Duration.millisecond) }
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([ValueField("call_id", textValue(call.callId))])
        ))
    }

    public func cancel(runId: RunId): Result<Unit> {
        var numeric = false
        var textual = false
        lock.lock()
        try {
            numeric = numberRunId == runId.value
            textual = textRunId == runId.value
        } finally {
            lock.unlock()
        }
        if (numeric) {
            numberCancelledValue.store(true)
            numberReleased.store(true)
        }
        if (textual) {
            textCancelledValue.store(true)
            textReleased.store(true)
        }
        Result.Ok(())
    }

    func bothStarted(): Bool {
        numberStartedValue.load() && textStartedValue.load()
    }

    func numberCallId(): String {
        lock.lock()
        try { numberCallIdValue } finally { lock.unlock() }
    }

    func textCallId(): String {
        lock.lock()
        try { textCallIdValue } finally { lock.unlock() }
    }

    func numberCancelled(): Bool { numberCancelledValue.load() }

    func textCancelled(): Bool { textCancelledValue.load() }

    func releaseText(): Unit { textReleased.store(true) }

    func releaseAll(): Unit {
        numberReleased.store(true)
        textReleased.store(true)
    }
}

func runDirectoryContract(full: McpClient, defaultClient: McpClient): Unit {
    let discovery = full.discover().value().getOrThrow()
    expect(
        discovery.serverInfo.getOrThrow().name == "axyndra" && discovery.capabilities.tools.isSome(),
        "product MCP server advertises its real tool directory"
    )
    let fullPage = full.listTools().value().getOrThrow()
    expect(
        fullPage.cacheScope == "private" && containsTool(fullPage.tools, "read") &&
            containsTool(fullPage.tools, "write") &&
            containsTool(fullPage.tools, "bash") &&
            containsTool(fullPage.tools, "task"),
        "full capabilities expose product tools with a private authorization-scoped cache"
    )
    let defaultPage = defaultClient.listTools().value().getOrThrow()
    expect(
        containsTool(defaultPage.tools, "read") &&
            !containsTool(defaultPage.tools, "write") &&
            !containsTool(defaultPage.tools, "edit") &&
            !containsTool(defaultPage.tools, "bash") &&
            !containsTool(defaultPage.tools, "eval") &&
            !containsTool(defaultPage.tools, "ast_edit") &&
            !containsTool(defaultPage.tools, "github") &&
            !containsTool(defaultPage.tools, "web_search") &&
            !containsTool(defaultPage.tools, "learn") &&
            !containsTool(defaultPage.tools, "manage_skill") &&
            !containsTool(defaultPage.tools, "task") &&
            !containsTool(defaultPage.tools, "hub"),
        "default MCP catalog grants only WorkspaceRead and excludes capability-bearing side effects"
    )
}

func runExecutionContract(client: McpClient, workspace: String): Unit {
    let read = complete(client.callTool(
        "read",
        objectValue([ValueField("path", textValue("note.txt"))])
    ).value().getOrThrow())
    expect(
        !read.isError && read.structuredContent.field("content")
            .getOrThrow().text.contains("bridge-readable"),
        "read-only product tools complete through the same ToolPipeline"
    )

    let sideEffect = workspace + "/must-not-exist"
    match (client.callTool(
        "bash",
        objectValue([ValueField(
            "command",
            textValue("touch must-not-exist")
        )])
    )) {
        case Result.Err(error) => expect(
            error.code == "mcp.product_tool_approval_required" &&
                !exists(Path(sideEffect)),
            "side-effecting tools stop at host approval before execution"
        )
        case Result.Ok(_) => throw IllegalStateException(
            "approval-required bash was reported as a completed MCP call"
        )
    }

    match (client.callTool(
        "read",
        objectValue([ValueField("path", textValue("note.txt"))]),
        continuation: McpToolCallContinuation(requestState: "forged-retry")
    )) {
        case Result.Err(error) => expect(
            error.code == "mcp.product_continuation_unsupported",
            "unadvertised continuation retries fail closed"
        )
        case Result.Ok(_) => throw IllegalStateException(
            "forged product continuation was accepted"
        )
    }
}

func complete(outcome: McpCallToolOutcome): McpCallToolResult {
    match (outcome) {
        case McpCallToolOutcome.Complete(value) => value
        case McpCallToolOutcome.InputRequired(_) => throw IllegalStateException(
            "product tool unexpectedly requested MRTR input"
        )
        case McpCallToolOutcome.Task(task) => throw IllegalStateException(
            "product tool unexpectedly returned task ${task.taskId}"
        )
        case McpCallToolOutcome.Extension(resultType, _) => throw IllegalStateException(
            "product tool unexpectedly returned extension ${resultType}"
        )
    }
}

func containsTool(tools: Array<McpTool>, name: String): Bool {
    for (tool in tools where tool.name == name) { return true }
    false
}

func prepare(root: String): Unit {
    let workspace = root + "/workspace"
    let settings = root + "/config"
    Directory.create(workspace, recursive: true)
    Directory.create(settings, recursive: true)
    File.writeTo(workspace + "/note.txt", "bridge-readable\n".toArray())
    File.writeTo(
        settings + "/config.yml",
        "default_model: local/product-contract\nasync:\n  enabled: false\n".toArray()
    )
    File.writeTo(
        settings + "/models.yml",
        ("models:\n" +
            "  - id: product-contract\n" +
            "    provider: local\n" +
            "    context_window: 200000\n" +
            "    max_output_tokens: 8192\n").toArray()
    )
    File.writeTo(
        settings + "/providers.yml",
        ("providers:\n" +
            "  - id: local\n" +
            "    provider: custom\n" +
            "    protocol: completions\n" +
            "    base_url: http://127.0.0.1:11434\n" +
            "    api_key_env: PRODUCT_MCP_UNUSED_PROVIDER_KEY\n").toArray()
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
