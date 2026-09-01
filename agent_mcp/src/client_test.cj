package agent_mcp

import agent_domain.*
import agent_protocol.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class McpClientBridgeTests {
    @TestCase
    func forwardsOperationNotificationsThroughProductTransport(): Unit {
        let server = McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("fixture", "1")),
            EmptyMcpToolHost()
        )
        let notifications = ArrayList<JsonRpcNotification>()
        let client = McpClient(
            ProgressMcpTransport(FakeMcpTransport(server)),
            McpRequestMeta(clientInfo: McpImplementationInfo("client", "1")),
            notificationSink: { notification => notifications.add(notification) }
        )
        @Expect(client.discover().isOk(), true)
        @Expect(notifications.size, 1)
        @Expect(notifications[0].method, "notifications/progress")
        @Expect(client.close().isOk(), true)
    }
}

class ProgressMcpTransport <: McpTransport {
    private let inner: FakeMcpTransport
    init(inner: FakeMcpTransport) { this.inner = inner }
    public func kind(): McpTransportKind { inner.kind() }
    public func state(): McpLifecycleState { inner.state() }
    public func request(request: JsonRpcRequest): Result<JsonRpcResponse> { inner.request(request) }
    public func requestWithNotifications(
        request: JsonRpcRequest,
        notificationSink: (JsonRpcNotification) -> Unit
    ): Result<JsonRpcResponse> {
        notificationSink(JsonRpcNotification("notifications/progress", params: objectValue([])))
        inner.request(request)
    }
    public func openSubscription(request: JsonRpcRequest): Result<McpSubscriptionHandle> {
        inner.openSubscription(request)
    }
    public func notify(notification: JsonRpcNotification): Result<Unit> { inner.notify(notification) }
    public func cancel(requestId: JsonRpcId, reason: String, meta: McpRequestMeta): Result<Unit> {
        inner.cancel(requestId, reason, meta)
    }
    public func registerTools(tools: Array<McpTool>): Result<Unit> { inner.registerTools(tools) }
    public func close(): Result<Unit> { inner.close() }
}

class EmptyMcpToolHost <: McpToolHost {
    public func listTools(cursor: String): Result<McpToolListPage> {
        let _ = cursor
        Result.Ok(McpToolListPage([]))
    }
    public func callTool(
        requestId: JsonRpcId, name: String, arguments: AgentValue,
        continuation: McpToolCallContinuation
    ): Result<McpCallToolOutcome> {
        let _ = requestId; let _ = name; let _ = arguments; let _ = continuation
        Result.Err(AgentError(AgentErrorKind.InvalidInput, "fixture.not_found", "not found"))
    }
    public func cancel(requestId: JsonRpcId, reason: String): Result<Unit> {
        let _ = requestId; let _ = reason
        Result.Ok(())
    }
}
