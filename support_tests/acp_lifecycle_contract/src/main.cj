package acp_lifecycle_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import agent_rpc.*
import model_adapters.*
import std.fs.*
import std.sync.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        runDurableBindingAndOwnership(root)
        runCloseFailureContract(root)
        println("ACP lifecycle contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func runDurableBindingAndOwnership(root: String): Unit {
    let state = root + "/state"
    let settings = root + "/settings"
    let hostWorkspace = root + "/host"
    let firstWorkspace = root + "/first"
    let secondWorkspace = root + "/second"
    for (path in [hostWorkspace, firstWorkspace, secondWorkspace]) {
        Directory.create(path, recursive: true)
    }
    let host = fixtureProduct(settings, state, hostWorkspace)
    let factoryCount = AtomicInt64(0)
    let sessionCloseCount = AtomicInt64(0)
    let hostCloseCount = AtomicInt64(0)
    let server = ProductAcpServer(
        host,
        {cwd =>
            factoryCount.fetchAdd(1)
            Result.Ok(fixtureProduct(settings, state, cwd))
        },
        {_ => ()},
        closer: {product =>
            if (product.workspace.rootPath() == hostWorkspace) {
                hostCloseCount.fetchAdd(1)
            } else {
                sessionCloseCount.fetchAdd(1)
            }
            Result.Ok(())
        }
    )
    let _ = acpCall(server, 1, "initialize", objectValue([]))
    let created = acpCall(server, 2, "session/new", acpSessionParams(firstWorkspace))
    let sessionId = created.field("result").getOrThrow()
        .field("sessionId").getOrThrow().text
    expect(factoryCount.load() == 1, "session/new opens one workspace product")

    let listed = acpCall(server, 3, "session/list", objectValue([]))
    let descriptor = listed.field("result").getOrThrow()
        .field("sessions").getOrThrow().items[0]
    expect(
        descriptor.field("cwd").getOrThrow().text == firstWorkspace &&
            descriptor.field("workspace").getOrThrow().text == firstWorkspace,
        "session/list reports the durable session workspace"
    )

    let _ = acpCall(server, 4, "session/close", objectValue([
        ValueField("sessionId", textValue(sessionId))
    ]))
    let _ = acpCall(server, 5, "session/close", objectValue([
        ValueField("sessionId", textValue(sessionId))
    ]))
    expect(sessionCloseCount.load() == 1, "session/close closes its product exactly once")

    let rebound = acpCall(server, 6, "session/load", objectValue([
        ValueField("sessionId", textValue(sessionId)),
        ValueField("cwd", textValue(secondWorkspace)),
        ValueField("mcpServers", listValue([]))
    ]))
    expect(
        rebound.field("error").getOrThrow().field("data").getOrThrow()
            .field("code").getOrThrow().text == "acp.session_workspace_mismatch" &&
            factoryCount.load() == 1,
        "absolute caller cwd cannot rebind a durable ACP session"
    )

    let _ = acpCall(server, 7, "session/load", objectValue([
        ValueField("sessionId", textValue(sessionId)),
        ValueField("cwd", textValue(firstWorkspace)),
        ValueField("mcpServers", listValue([]))
    ]))
    let forked = acpCall(server, 8, "session/fork", objectValue([
        ValueField("sessionId", textValue(sessionId)),
        ValueField("cwd", textValue(firstWorkspace)),
        ValueField("mcpServers", listValue([]))
    ]))
    let forkId = forked.field("result").getOrThrow()
        .field("sessionId").getOrThrow().text
    let _ = acpCall(server, 9, "session/close", objectValue([
        ValueField("sessionId", textValue(sessionId))
    ]))
    expect(
        sessionCloseCount.load() == 1,
        "a shared fork keeps its product owner alive"
    )
    let _ = acpCall(server, 10, "session/close", objectValue([
        ValueField("sessionId", textValue(forkId))
    ]))
    expect(
        sessionCloseCount.load() == 2,
        "the last shared session closes its product once"
    )

    let _ = acpCall(server, 11, "session/new", acpSessionParams(secondWorkspace))
    expect(server.close().isOk(), "server shutdown closes remaining products")
    expect(
        sessionCloseCount.load() == 3 && hostCloseCount.load() == 1,
        "server shutdown closes the live session product and host once"
    )
    expect(server.close().isOk(), "server shutdown is idempotent")
    expect(
        sessionCloseCount.load() == 3 && hostCloseCount.load() == 1,
        "repeated shutdown does not close products again"
    )
}

func runCloseFailureContract(root: String): Unit {
    let state = root + "/failure-state"
    let settings = root + "/failure-settings"
    let hostWorkspace = root + "/failure-host"
    let workspace = root + "/failure-workspace"
    Directory.create(hostWorkspace, recursive: true)
    Directory.create(workspace, recursive: true)
    let closeCount = AtomicInt64(0)
    let server = ProductAcpServer(
        fixtureProduct(settings, state, hostWorkspace),
        {cwd => Result.Ok(fixtureProduct(settings, state, cwd))},
        {_ => ()},
        closer: {_ =>
            closeCount.fetchAdd(1)
            Result.Err(AgentError(
                AgentErrorKind.Internal,
                "fixture.close_failed",
                "fixture close failed"
            ))
        }
    )
    let _ = acpCall(server, 20, "initialize", objectValue([]))
    let _ = acpCall(server, 21, "session/new", acpSessionParams(workspace))
    let first = server.close().error().getOrThrow()
    expect(
        first.code == "acp.server_shutdown_failed" &&
            first.field("failure_count") == Some("2") &&
            closeCount.load() == 2,
        "shutdown aggregates typed session and host close failures"
    )
    let second = server.close().error().getOrThrow()
    expect(
        second.code == "acp.server_shutdown_failed" && closeCount.load() == 2,
        "failed shutdown preserves its typed result without retrying close"
    )
}

func fixtureProduct(
    settings: String,
    state: String,
    workspace: String
): ProductRuntime {
    openProduct(config: ProductConfig(
        settingsRoot: settings,
        stateRoot: state,
        workspaceRoot: workspace,
        fixture: true,
        asyncEnabled: false
    )).value().getOrThrow()
}

func acpSessionParams(cwd: String): AgentValue {
    objectValue([
        ValueField("cwd", textValue(cwd)),
        ValueField("mcpServers", listValue([]))
    ])
}

func acpCall(
    server: ProductAcpServer,
    id: Int64,
    method: String,
    params: AgentValue
): AgentValue {
    let response = server.handle(encodeAgentValue(objectValue([
        ValueField("jsonrpc", textValue("2.0")),
        ValueField("id", integerValue(id)),
        ValueField("method", textValue(method)),
        ValueField("params", params)
    ])))
    decodeAgentValue(response).value().getOrThrow()
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
