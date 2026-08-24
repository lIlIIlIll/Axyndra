package agent_mcp

import agent_domain.*
import agent_protocol.*
import mcp4cj as library

// Product handler boundary. Implementations may route calls through
// ToolPipeline; the generic server never sees Agent authorization state.
public interface McpToolHost {
    func listTools(cursor: String): Result<McpToolListPage>
    func callTool(
        requestId: JsonRpcId,
        name: String,
        arguments: AgentValue,
        continuation: McpToolCallContinuation
    ): Result<McpCallToolOutcome>
    func cancel(requestId: JsonRpcId, reason: String): Result<Unit>
}

public class McpServer {
    private let primitive: library.McpServer

    public init(discovery: McpDiscoverResult, host: McpToolHost) {
        primitive = library.McpServer(discovery, McpToolHostBridge(host))
    }

    public func state(): McpLifecycleState { primitive.state() }
    public func handleRequest(request: JsonRpcRequest): JsonRpcResponse {
        primitive.handleRequest(request)
    }
    public func handleNotification(notification: JsonRpcNotification): Result<Unit> {
        mapMcpResult(primitive.handleNotification(notification))
    }
    public func cancelRequest(requestId: JsonRpcId, reason: String): Result<Unit> {
        handleNotification(mcpCancellationNotification(
            requestId, reason, McpRequestMeta(McpImplementationInfo("Axyndra-adapter", "1"))
        ))
    }
    public func handle(envelope: JsonRpcEnvelope): Result<?JsonRpcEnvelope> {
        mapMcpResult(primitive.handle(envelope))
    }
    func libraryServer(): library.McpServer { primitive }
    public func close(): Result<Unit> { mapMcpResult(primitive.close()) }
}

class McpToolHostBridge <: library.McpToolHost {
    private let product: McpToolHost
    init(product: McpToolHost) { this.product = product }
    public func listTools(cursor: String): library.McpResult<McpToolListPage> {
        unmapMcpResult(product.listTools(cursor))
    }
    public func callTool(
        requestId: JsonRpcId,
        name: String,
        arguments: AgentValue,
        continuation: McpToolCallContinuation
    ): library.McpResult<McpCallToolOutcome> {
        unmapMcpResult(product.callTool(requestId, name, arguments, continuation))
    }
    public func cancel(requestId: JsonRpcId, reason: String): library.McpResult<Unit> {
        unmapMcpResult(product.cancel(requestId, reason))
    }
}

public type McpToolHandler = (
    String, AgentValue, McpToolCallContinuation
) -> Result<McpCallToolOutcome>

public class MemoryMcpToolHost <: McpToolHost {
    private let primitive: library.MemoryMcpToolHost

    public init(
        tools: Array<McpTool>,
        handler: McpToolHandler,
        generation!: Int64 = 1,
        pageSize!: Int64 = 50,
        ttlMillis!: Int64 = 300000,
        cacheScope!: String = "private"
    ) {
        primitive = library.MemoryMcpToolHost(
            tools,
            { name: String, arguments: AgentValue, continuation: McpToolCallContinuation =>
                unmapMcpResult(handler(name, arguments, continuation))
            },
            generation: generation,
            pageSize: pageSize,
            ttlMillis: ttlMillis,
            cacheScope: cacheScope
        )
    }

    public func listTools(cursor: String): Result<McpToolListPage> {
        mapMcpResult(primitive.listTools(cursor))
    }
    public func callTool(
        requestId: JsonRpcId,
        name: String,
        arguments: AgentValue,
        continuation: McpToolCallContinuation
    ): Result<McpCallToolOutcome> {
        mapMcpResult(primitive.callTool(requestId, name, arguments, continuation))
    }
    public func cancel(requestId: JsonRpcId, reason: String): Result<Unit> {
        mapMcpResult(primitive.cancel(requestId, reason))
    }
    public func cancellations(): Array<String> { primitive.cancellations() }
}
