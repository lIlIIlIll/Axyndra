package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_mcp.*
import agent_protocol.*
import model_adapters.*
import tool_runtime.*
import std.collection.*
import std.sync.*

public class ProductMcpServerOptions {
    public let sessionId: SessionId
    public let capabilities: CapabilitySet
    public let instructions: String

    public init(
        sessionId: SessionId,
        capabilities: CapabilitySet,
        instructions!: String = ""
    ) {
        this.sessionId = sessionId
        this.capabilities = capabilities
        this.instructions = instructions
    }
}

class ProductMcpActiveCall {
    let requestId: JsonRpcId
    let runId: RunId

    init(requestId: JsonRpcId, runId: RunId) {
        this.requestId = requestId
        this.runId = runId
    }
}

class ProductMcpToolHost <: McpToolHost {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let ids: ProductIds
    private let vnext: ProductVnextControl
    private let options: ProductMcpServerOptions
    private let active = ArrayList<ProductMcpActiveCall>()
    private let lock = Mutex()

    init(
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        ids: ProductIds,
        vnext: ProductVnextControl,
        options: ProductMcpServerOptions
    ) {
        this.catalog = catalog
        this.pipeline = pipeline
        this.ids = ids
        this.vnext = vnext
        this.options = options
    }

    public func listTools(cursor: String): Result<McpToolListPage> {
        if (cursor != "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "mcp.product_cursor_invalid",
                "the product tool directory is returned as one bounded page"
            ))
        }
        let tools = ArrayList<McpTool>()
        for (definition in catalog.definitionsFor(options.capabilities)) {
            tools.add(McpTool(
                definition.name,
                definition.description,
                definition.inputSchema
            ))
        }
        Result.Ok(McpToolListPage(
            tools.toArray(),
            ttlMillis: 0,
            cacheScope: "private"
        ))
    }

    public func callTool(
        requestId: JsonRpcId,
        name: String,
        arguments: AgentValue,
        continuation: McpToolCallContinuation
    ): Result<McpCallToolOutcome> {
        if (continuation.isRetry()) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "mcp.product_continuation_unsupported",
                "product tools do not advertise input_required continuations"
            ))
        }
        let runId = ids.nextRunId()
        let requestKey = productMcpRequestKey(requestId)
        // MCP requests can overlap on one server session. Each request gets its
        // own canonical Thread/Run owner, then the inactive ephemeral Thread is
        // discarded after the request settles.
        let executionSessionId = SessionId(
            options.sessionId.value + "::mcp-request-" + runId.value
        )
        addActive(requestId, runId)
        try {
            match (vnext.executeCanonicalTool(
                executionSessionId,
                options.capabilities,
                ToolCall("mcp-server-" + requestKey, name, arguments),
                runId: Some(runId)
            )) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(ToolInvocationResult.Completed(result)) =>
                    Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                        [objectValue([
                            ValueField("type", textValue("text")),
                            ValueField(
                                "text",
                                textValue(encodeAgentValue(result.output))
                            )
                        ])],
                        structuredContent: result.output,
                        isError: result.isError
                    )))
                case Result.Ok(ToolInvocationResult.NeedsApproval(approval)) =>
                    Result.Err(AgentError(
                        AgentErrorKind.PermissionDenied,
                        "mcp.product_tool_approval_required",
                        "tool invocation requires host approval",
                        fields: [
                            ErrorField("tool", name),
                            ErrorField(
                                "operation_id",
                                approval.operationId.value
                            )
                        ]
                    ))
                case Result.Ok(ToolInvocationResult.Denied(denial)) =>
                    Result.Err(denial.reason)
            }
        } finally {
            removeActive(requestId, runId)
            let _ = vnext.discardInactiveThread(executionSessionId)
        }
    }

    public func cancel(
        requestId: JsonRpcId,
        reason: String
    ): Result<Unit> {
        let _ = reason
        let targets = activeRuns(requestId)
        for (runId in targets) {
            match (pipeline.cancel(runId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }

    private func addActive(requestId: JsonRpcId, runId: RunId): Unit {
        lock.lock()
        try { active.add(ProductMcpActiveCall(requestId, runId)) } finally {
            lock.unlock()
        }
    }

    private func removeActive(requestId: JsonRpcId, runId: RunId): Unit {
        lock.lock()
        try {
            for (index in 0..active.size where
                 sameJsonRpcId(active[index].requestId, requestId) &&
                 active[index].runId.value == runId.value) {
                active.remove(at: index)
                break
            }
        } finally {
            lock.unlock()
        }
    }

    private func activeRuns(requestId: JsonRpcId): Array<RunId> {
        lock.lock()
        try {
            let values = ArrayList<RunId>()
            for (item in active where sameJsonRpcId(item.requestId, requestId)) {
                values.add(item.runId)
            }
            values.toArray()
        } finally {
            lock.unlock()
        }
    }
}

func productMcpRequestKey(requestId: JsonRpcId): String {
    match (requestId.kind) {
        case JsonRpcIdKind.Text => "text:" + requestId.value
        case JsonRpcIdKind.Number => "number:" + requestId.value
        case JsonRpcIdKind.Null => "null"
    }
}

func buildProductMcpServer(
    catalog: ToolCatalog,
    pipeline: ToolPipeline,
    ids: ProductIds,
    vnext: ProductVnextControl,
    options: ProductMcpServerOptions
): McpServer {
    McpServer(
        McpDiscoverResult(
            serverInfo: McpImplementationInfo("axyndra", "1.0.0", title: "axyndra"),
            instructions: options.instructions
        ),
        ProductMcpToolHost(catalog, pipeline, ids, vnext, options),
        requestOwner: options.sessionId.value
    )
}
