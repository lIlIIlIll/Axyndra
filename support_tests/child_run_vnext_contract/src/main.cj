package child_run_vnext_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_runtime.*

main(): Int64 {
    capabilityCeilingContract()
    budgetReservationContract()
    isolatedResultContract()
    remoteExecutionRealmContract()
    println("vNext child run contract passed")
    0
}

func remoteExecutionRealmContract(): Unit {
    let realm = RemoteExecutionRealm(
        "worker-eu-1", "https://worker.example/rpc", "worker-key-1",
        "remote-fs-1", "remote-process-1",
        services: [RemoteServiceKind.FileSystem, RemoteServiceKind.Process,
            RemoteServiceKind.Terminal, RemoteServiceKind.Lsp]
    )
    expect(realm.supports(RemoteServiceKind.FileSystem) && realm.supports(RemoteServiceKind.Process) &&
        realm.fileSystemServiceIdentity == "remote-fs-1" &&
        realm.processServiceIdentity == "remote-process-1",
        "filesystem and process services are co-located in one Remote Execution Realm")
    let capabilities = CapabilitySet(values: [
        Capability(CapabilityKind.WorkspaceRead, resource: "/repo"),
        Capability(CapabilityKind.ProcessSpawn, resource: "sandbox")
    ])
    let envelope = sealRemoteCapabilityEnvelope(SignedRemoteCapabilityEnvelope(
        "route-envelope-1", RunId("remote-run"), LaneId("remote-lane"), realm.id,
        capabilities, 100, 200, "nonce-1"
    ), "signature-1")
    let transport = RecordingRemoteTransport()
    let router = RemoteExecutionRouter(realm, capabilities, FixedRemoteVerifier(true), transport)
    let result = router.route(envelope, RemoteExecutionRequest(
        OperationId("remote-operation"), RemoteServiceKind.Process,
        objectValue([ValueField("command", textValue("cjc --version"))]), "lane:remote-lane"
    ), 150)
    expect(result.isOk() && result.value().getOrThrow().field("realm").getOrThrow().text == realm.id &&
        transport.dispatches == 1,
        "distributed router dispatches a signed request through the selected Realm")
    expect(RemoteExecutionRouter(
        realm, capabilities, FixedRemoteVerifier(false), transport
    ).route(envelope, RemoteExecutionRequest(
        OperationId("bad-signature"), RemoteServiceKind.Process, objectValue([]), "lane:remote-lane"
    ), 150).isError(), "invalid remote signature fails before transport")
    expect(router.route(envelope, RemoteExecutionRequest(
        OperationId("expired"), RemoteServiceKind.Process, objectValue([]), "lane:remote-lane"
    ), 200).isError(), "expired distributed authority cannot be routed")
    let expanded = sealRemoteCapabilityEnvelope(SignedRemoteCapabilityEnvelope(
        "route-envelope-expanded", RunId("remote-run"), LaneId("remote-lane"), realm.id,
        CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess)]),
        100, 200, "nonce-2"
    ), "signature-2")
    expect(router.route(expanded, RemoteExecutionRequest(
        OperationId("expanded"), RemoteServiceKind.Process, objectValue([]), "lane:remote-lane"
    ), 150).isError(), "remote worker authority cannot exceed the frozen parent ceiling")
    expect(router.route(envelope, RemoteExecutionRequest(
        OperationId("unbound"), RemoteServiceKind.Dap, objectValue([]), "lane:remote-lane"
    ), 150).isError() && transport.dispatches == 1,
        "unbound remote services fail closed without transport dispatch")
}

class FixedRemoteVerifier <: RemoteCapabilitySignatureVerifier {
    private let valid: Bool
    init(valid: Bool) { this.valid = valid }
    public func verify(_envelope: SignedRemoteCapabilityEnvelope, transportIdentity: String): Bool {
        let _ = _envelope
        valid && transportIdentity == "worker-key-1"
    }
}

class RecordingRemoteTransport <: RemoteWorkerTransport {
    var dispatches: Int64 = 0
    public func dispatch(realm: RemoteExecutionRealm, _envelope: SignedRemoteCapabilityEnvelope, request: RemoteExecutionRequest): Result<AgentValue> {
        let _ = _envelope
        dispatches += 1
        Result.Ok(objectValue([
            ValueField("realm", textValue(realm.id)),
            ValueField("route", textValue(request.routeKey))
        ]))
    }
}

func capabilityCeilingContract(): Unit {
    let parent = CapabilitySet(values: [
        Capability(CapabilityKind.WorkspaceRead),
        Capability(CapabilityKind.WorkspaceWrite, resource: "/repo"),
        Capability(CapabilityKind.NetworkAccess, resource: "api.example")
    ])
    let role = CapabilitySet(values: [
        Capability(CapabilityKind.WorkspaceRead),
        Capability(CapabilityKind.WorkspaceWrite),
        Capability(CapabilityKind.NetworkAccess, resource: "other.example")
    ])
    let sandbox = CapabilitySet(values: [
        Capability(CapabilityKind.WorkspaceRead),
        Capability(CapabilityKind.WorkspaceWrite, resource: "/repo")
    ])
    let effective = effectiveChildCapabilities(parent, role, sandbox)
    expect(effective.allows(CapabilityKind.WorkspaceRead) &&
        effective.allows(CapabilityKind.WorkspaceWrite, resource: "/repo") &&
        !effective.allows(CapabilityKind.NetworkAccess, resource: "api.example"),
        "child authority is parent intersect role intersect sandbox")
}

func budgetReservationContract(): Unit {
    let pool = ChildBudgetPool(ExecutionBudget(
        maxTurns: 10, maxToolCalls: 20, maxConcurrentTools: 4,
        maxInputTokens: 1000, maxOutputTokens: 500,
        maxTotalInputTokens: 1000, maxTotalOutputTokens: 500, maxCostMicros: 100
    ), 2)
    let child = ExecutionBudget(
        maxTurns: 4, maxToolCalls: 8, maxConcurrentTools: 2,
        maxInputTokens: 400, maxOutputTokens: 200,
        maxTotalInputTokens: 400, maxTotalOutputTokens: 200, maxCostMicros: 40
    )
    let first = pool.reserve("first", child).value().getOrThrow()
    let second = pool.reserve("second", child).value().getOrThrow()
    expect(pool.reserve("third", child).isError(), "child concurrency is reserved up front")
    let boundedParent = ChildBudgetPool(ExecutionBudget(maxCostMicros: 10), 1)
    expect(boundedParent.reserve("unbounded", ExecutionBudget()).isError(),
        "bounded parent rejects an unbounded child cost reservation")
    let settled = first.settle(ExecutionUsage(
        turns: 2, toolCalls: 3, inputTokens: 100, outputTokens: 50, costMicros: 10
    )).value().getOrThrow()
    expect(settled.totalChildrenStarted == 2 && settled.activeReservations == 1 &&
        settled.consumed.turns == 2 &&
        settled.reserved.turns == 0 && settled.reserved.inputTokens == 400,
        "actual usage is consumed and unused aggregate budget is released")
    expect(first.settle(ExecutionUsage()).isError(), "budget lease settles exactly once")
    second.settle(ExecutionUsage()).value().getOrThrow()
    expect(pool.reserve("after-settle", child).isError(),
        "maxChildren is a lifetime Run limit, not only active child concurrency")

    let concurrencyPool = ChildBudgetPool(ExecutionBudget(
        maxTurns: 20, maxToolCalls: 30, maxConcurrentTools: 4,
        maxInputTokens: 2000, maxOutputTokens: 1000
    ), 3, maxConcurrentChildren: 2)
    let twoTools = ExecutionBudget(
        maxTurns: 2, maxToolCalls: 4, maxConcurrentTools: 2,
        maxInputTokens: 100, maxOutputTokens: 100
    )
    let _ = concurrencyPool.reserve("tools-a", twoTools).value().getOrThrow()
    let _ = concurrencyPool.reserve("tools-b", twoTools).value().getOrThrow()
    expect(concurrencyPool.reserve("tools-c", ExecutionBudget(
        maxTurns: 1, maxToolCalls: 1, maxConcurrentTools: 1,
        maxInputTokens: 1, maxOutputTokens: 1
    )).isError(), "child reservations cannot exceed parent child concurrency")
}

func isolatedResultContract(): Unit {
    let result = ChildRunResult(
        "researched", artifactReferences: ["sha256:abc"],
        evidence: ["test:passed"], changeSetReference: "changeset:1"
    )
    expect(result.summary == "researched" && result.artifactReferences.size == 1,
        "parent receives summary, artifacts, evidence and changes only")
    var rejected = false
    let source = CancellationSource()
    try {
        let _ = ChildRunSpec(
            RunId("child"), "edit", emptyProjection(),
            ChildWorkspaceView("workspace", "/repo", ChildWorkspaceMode.SharedReadOnly),
            ToolSetSnapshot("tools", []), [], ExecutionBudget(),
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)]),
            source.token
        )
    } catch (_: Exception) { rejected = true }
    source.close()
    expect(rejected, "shared read-only child cannot inherit write authority")
}

func emptyProjection(): ModelContextProjection {
    ModelContextProjection(0, None, [], objectValue([]), 0, false)
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
