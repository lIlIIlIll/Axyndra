package agent_mcp

import agent_domain.*
import agent_protocol.*
import std.collection.*
import std.sync.*

public class FakeMcpTransport <: McpTransport {
    private let server: McpServer
    private let lifecycle = McpLifecycle()
    private let lock = Mutex()
    private let requests = ArrayList<JsonRpcRequest>()
    private let notifications = ArrayList<JsonRpcNotification>()
    private var dropAfterDispatch = false

    public init(server: McpServer) {
        this.server = server
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        let _ = lifecycle.transition(McpLifecycleState.Ready)
    }

    public func kind(): McpTransportKind { McpTransportKind.Memory }

    public func state(): McpLifecycleState { lifecycle.state() }

    public func request(request: JsonRpcRequest): Result<JsonRpcResponse> {
        if (lifecycle.state() != McpLifecycleState.Ready) {
            return mcpFailure<JsonRpcResponse>(
                AgentErrorKind.Transport,
                "mcp.transport_closed",
                "MCP transport is closed"
            )
        }
        lock.lock()
        try { requests.add(request) } finally { lock.unlock() }
        let response = server.handleRequest(request)
        let drop = takeDropAfterDispatch()
        if (drop) {
            return mcpFailure<JsonRpcResponse>(
                AgentErrorKind.RecoveryRequired,
                "mcp.response_lost_after_dispatch",
                "MCP response was lost after the tool request may have executed",
                fields: [ErrorField("retry_safe", "false")]
            )
        }
        Result.Ok(response)
    }

    public func notify(notification: JsonRpcNotification): Result<Unit> {
        if (lifecycle.state() != McpLifecycleState.Ready) {
            return mcpFailure<Unit>(
                AgentErrorKind.Transport,
                "mcp.transport_closed",
                "MCP transport is closed"
            )
        }
        lock.lock()
        try { notifications.add(notification) } finally { lock.unlock() }
        server.handleNotification(notification)
    }

    public func cancel(requestId: JsonRpcId, reason: String, meta: McpRequestMeta): Result<Unit> {
        notify(mcpCancellationNotification(requestId, reason, meta))
    }

    public func close(): Result<Unit> {
        if (lifecycle.state() == McpLifecycleState.Stopped) { return Result.Ok(()) }
        if (lifecycle.state() != McpLifecycleState.Stopping) {
            let _ = lifecycle.transition(McpLifecycleState.Stopping)
        }
        let _ = lifecycle.transition(McpLifecycleState.Stopped)
        Result.Ok(())
    }

    public func failNextAfterDispatch(): Unit {
        lock.lock()
        try { dropAfterDispatch = true } finally { lock.unlock() }
    }

    public func requestCount(): Int64 {
        lock.lock()
        try { requests.size } finally { lock.unlock() }
    }

    public func notificationCount(): Int64 {
        lock.lock()
        try { notifications.size } finally { lock.unlock() }
    }

    public func requestSnapshot(): Array<JsonRpcRequest> {
        lock.lock()
        try { requests.toArray() } finally { lock.unlock() }
    }

    private func takeDropAfterDispatch(): Bool {
        lock.lock()
        try {
            let value = dropAfterDispatch
            dropAfterDispatch = false
            value
        } finally {
            lock.unlock()
        }
    }
}
