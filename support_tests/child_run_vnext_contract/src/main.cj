package child_run_vnext_contract

import agent_domain.*
import agent_runtime.*

main(): Int64 {
    capabilityCeilingContract()
    budgetReservationContract()
    isolatedResultContract()
    println("vNext child run contract passed")
    0
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
