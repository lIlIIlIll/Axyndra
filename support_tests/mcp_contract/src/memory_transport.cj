package mcp_contract

import mcp4cj.*
import agent_protocol.*
import std.collection.*
import std.sync.*

// Test-only in-memory fault injector. The real stdio and HTTP sections use the
// production library transports; no Product facade or authorization is copied.
class FakeMcpTransport <: McpTransport {
    private let server: McpServer
    private let lock = Mutex()
    private let requests = ArrayList<JsonRpcRequest>()
    private var notifications: Int64 = 0
    private var stopped = false
    private var drop = false
    init(server: McpServer) { this.server = server }
    public func kind(): McpTransportKind { McpTransportKind.Memory }
    public func state(): McpLifecycleState {
        lock.lock(); try { if (stopped) { McpLifecycleState.Stopped } else { McpLifecycleState.Ready } } finally { lock.unlock() }
    }
    public func request(request: JsonRpcRequest): McpResult<JsonRpcResponse> {
        lock.lock()
        let lose = try {
            if (stopped) { return McpResult.Err(McpError(McpErrorKind.Transport, "mcp.transport_closed", "closed")) }
            requests.add(request)
            let value = drop; drop = false; value
        } finally { lock.unlock() }
        let response = server.handleRequest(request)
        if (lose) { return McpResult.Err(McpError(McpErrorKind.Transport, "mcp.response_lost_after_dispatch", "response lost after dispatch", retrySafe: false)) }
        McpResult.Ok(response)
    }
    public func openSubscription(request: JsonRpcRequest): McpResult<McpSubscriptionHandle> {
        let _ = request
        McpResult.Err(McpError(McpErrorKind.Protocol, "mcp.fixture_subscription_unsupported", "fixture has no subscription provider"))
    }
    public func notify(notification: JsonRpcNotification): McpResult<Unit> {
        lock.lock(); try { notifications += 1 } finally { lock.unlock() }
        server.handleNotification(notification)
    }
    public func cancel(requestId: JsonRpcId, reason: String, meta: McpRequestMeta): McpResult<Unit> {
        notify(mcpCancellationNotification(requestId, reason, meta: meta))
    }
    public func registerTools(tools: Array<McpTool>): McpResult<Unit> { let _ = tools; McpResult.Ok(()) }
    public func close(): McpResult<Unit> { lock.lock(); try { stopped = true } finally { lock.unlock() }; McpResult.Ok(()) }
    func failNextAfterDispatch(): Unit { lock.lock(); try { drop = true } finally { lock.unlock() } }
    func requestCount(): Int64 { lock.lock(); try { requests.size } finally { lock.unlock() } }
    func notificationCount(): Int64 { lock.lock(); try { notifications } finally { lock.unlock() } }
    func requestSnapshot(): Array<JsonRpcRequest> { lock.lock(); try { requests.toArray() } finally { lock.unlock() } }
}
