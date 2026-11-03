package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func coreScopedBinding(): ToolContributionBinding {
    ToolContributionBinding("sha256:" + modelPolicySha256Text("core scoped package"),
        modelPolicySha256Text("core scoped configuration"), "core-scoped-instance", 1)
}

func coreScopedPublication(catalog: ToolCatalog, thread: String, tool: EchoTool): Unit {
    let owner = catalog.createContributionOwner("core-scoped-owner", "plugin.core.", threadId: Some(ThreadId(thread)))
        .value().getOrThrow()
    catalog.replaceOwnedBatch(owner, 0, coreScopedBinding(), [ToolCatalogRegistration(
        ToolDescriptor(ModelToolDefinition("plugin.core.echo", "directory for " + thread, objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), implementationVersion: "core-scope-v1",
            implementationFingerprint: "core-scope-adapter"), tool)]).value().getOrThrow()
}

func coreScopedModelProjectionContract(): Unit {
    let catalog = ToolCatalog()
    let a = EchoTool()
    let b = EchoTool()
    coreScopedPublication(catalog, "core-scope-a", a)
    coreScopedPublication(catalog, "core-scope-b", b)
    for (thread in ["core-scope-a", "core-scope-b"]) {
        let model = TwoStepModel(toolName: "plugin.core.echo")
        let registry = resumeThreadRegistry("scope-model-" + thread)
        let request = AgentRunRequest(RunId("scope-core-run-" + thread), SessionId(thread), "fixture", "invoke scoped tool",
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
        let core = AgentCore(model, MemoryRuns(), ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()),
            catalog, threadRuntimes: Some(registry))
        let outcome = core.start(request)
        expect(outcome.isOk() && match (outcome.value().getOrThrow()) {
            case AgentRunOutcome.Completed(snapshot) => snapshot.status == RunState.Completed
            case _ => false
        } && model.requests.size == 2 && model.requests[0].tools.size == 1 && model.requests[1].tools.size == 1 &&
            model.requests[0].tools[0].description == "directory for " + thread &&
            model.requests[1].tools[0].description == "directory for " + thread,
            "real AgentCore model turns advertise and dispatch only their Thread-owned directory")
    }
    expect(a.executions == 1 && b.executions == 1 && a.persistedResults == 1 && b.persistedResults == 1,
        "scoped Core Runs each commit exactly one result through their own retained executor")
    let model = ScopedEmptyDirectoryModel()
    let childCore = AgentCore(model, MemoryRuns(), ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog)
    let child = childCore.start(AgentRunRequest(RunId("scope-fresh-child-run"), SessionId("scope-fresh-child"),
        "fixture", "fresh Thread must not inherit its parent's mutable directory",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])))
    expect(child.isOk() && model.calls == 1 && model.exposedTools == 0 && a.executions == 1 && b.executions == 1,
        "a fresh child Thread has no implicitly copied owner, executor, or service lease")
}

class ScopedEmptyDirectoryModel <: ModelPort {
    var calls: Int64 = 0
    var exposedTools: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        exposedTools = request.tools.size
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "no inherited directory")], stopReason: "end_turn"))
    }
}

func coreScopedRecoveryGuardContract(): Unit {
    let runs = MemoryRuns(failClaimBeforeCommitAt: 1)
    let decisions = InMemoryModelDecisionRuntimePort()
    let model = ResumeAnswerModel()
    let catalog = ToolCatalog()
    coreScopedPublication(catalog, "scope-recovery-a", EchoTool())
    let capabilities = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    let request = AgentRunRequest(RunId("scope-recovery-run"), SessionId("scope-recovery-a"),
        "fixture", "recover with another Thread's snapshot", capabilities: capabilities)
    let first = AgentCore(model, runs, ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog,
        threadRuntimes: Some(resumeThreadRegistry("scope-recovery-original")), modelDecisionRuntime: Some(decisions)).start(request)
    expect(first.isError() && model.calls == 0 && runs.modelAttempts.size == 1,
        "scope recovery fixture persists a prepared attempt before the injected dispatch failure")
    let brokenThreads = resumeThreadRegistry("scope-recovery-broken")
    let runtime = brokenThreads.acquire(ThreadId(request.sessionId.value), "workspace:default").value().getOrThrow()
    // Even an empty foreign projection is invalid; no missing implementation
    // identity can account for this rejection.
    let lane = ModelLane(ModelLaneRole.Main, "configured", request.model, "agent-core",
        ModelLaneCapabilitiesSnapshot(tools: true), request.contextWindow, request.budget.maxOutputTokens,
        request.providerSafetyMargin, "conservative-v1", "never", "default",
        catalog.toolSetSnapshot("foreign-empty", capabilities, threadId: Some(ThreadId("scope-recovery-b"))), "system-v1")
    runtime.startTurn(SemanticTurnId("turn-" + request.runId.value), request.runId, ItemId("user-" + request.runId.value),
        ThreadItemContent.UserMessage(textMessageParts(request.prompt)), lane, request.contextSnapshot, createdAtMillis: 1)
        .value().getOrThrow()
    let resumed = AgentCore(model, runs, ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixtureIds()), catalog,
        threadRuntimes: Some(brokenThreads), modelDecisionRuntime: Some(decisions)).resume(request)
    expect(resumed.isError() && resumed.error().getOrThrow().code == "run.tool_snapshot_thread_mismatch" &&
        model.calls == 0 && runs.modelAttempts.size == 1,
        "Core refuses a foreign durable scope before model I/O, including a global-only or empty projection")
}

func threadScopedCoreCatalogContracts(): Unit {
    coreScopedModelProjectionContract()
    coreScopedRecoveryGuardContract()
    println("Thread-scoped AgentCore catalog contract passed (2 groups)")
}
