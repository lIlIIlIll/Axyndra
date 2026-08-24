package run_lifecycle_vnext_contract

import std.sync.*
import agent_domain.*
import agent_runtime.*

main(): Int64 {
    stateMachineContract()
    completedJoinContract()
    failedChildContract()
    structuredCancellationContract()
    quarantineContract()
    println("vNext run lifecycle contract passed")
    0
}

func failedChildContract(): Unit {
    let lifecycle = RunLifecycle()
    lifecycle.start().value().getOrThrow()
    lifecycle.scope.own("reviewer", spawn {
        throw IllegalStateException("review failed")
    }).value().getOrThrow()
    let (transition, report) = lifecycle.settle(RunState.Completed, 1000)
    expect(transition.to == RunState.Failed && report.failedCount() == 1 &&
        transition.reason == "owned_failures=1",
        "owned child failure cannot be published as a completed Run")
}

func completedJoinContract(): Unit {
    let lifecycle = RunLifecycle()
    lifecycle.start().value().getOrThrow()
    let worker = spawn { sleep(Duration.millisecond * 2) }
    lifecycle.scope.own("model", worker).value().getOrThrow()
    let (transition, report) = lifecycle.settle(RunState.Completed, 1000)
    expect(transition.to == RunState.Completed &&
        report.settlements[0].outcome == OwnedTaskOutcome.Joined,
        "completed state is published only after owned work joins")
}

func stateMachineContract(): Unit {
    let machine = RunStateMachine()
    expect(machine.transition(RunState.WaitingApproval).isError(),
        "created run cannot skip running")
    expect(machine.transition(RunState.Running).isOk(), "created run starts")
    expect(machine.transition(RunState.WaitingExternal).isOk(),
        "run represents external waiting explicitly")
    expect(machine.transition(RunState.Running).isOk(), "external wait resumes")
    expect(machine.transition(RunState.Completed).isOk(), "run completes")
    expect(machine.transition(RunState.Running).isError(),
        "terminal run cannot be revived")
}

func structuredCancellationContract(): Unit {
    let lifecycle = RunLifecycle()
    lifecycle.start().value().getOrThrow()
    let childToken = lifecycle.scope.childToken()
    let worker = spawn {
        while (!childToken.isCancelled()) { sleep(Duration.millisecond) }
    }
    lifecycle.scope.own("tool/process", worker).value().getOrThrow()
    lifecycle.requestCancel().value().getOrThrow()
    expect(childToken.isCancelled(), "parent Run cancellation reaches child token")
    let (transition, report) = lifecycle.settleCancelled(1000)
    expect(transition.to == RunState.Cancelled,
        "cancel is terminal only after bounded join")
    expect(report.settlements.size == 1 &&
        report.settlements[0].outcome == OwnedTaskOutcome.Joined,
        "cooperative child is joined")
    expect(lifecycle.scope.own("late", spawn {}).isError(),
        "settled run scope rejects detached late work")
}

func quarantineContract(): Unit {
    let lifecycle = RunLifecycle()
    lifecycle.start().value().getOrThrow()
    let release = AtomicBool(false)
    let stubborn = spawn {
        while (!release.load()) { sleep(Duration.millisecond) }
    }
    lifecycle.scope.own("mcp/ambiguous", stubborn).value().getOrThrow()
    lifecycle.requestCancel().value().getOrThrow()
    let (transition, report) = lifecycle.settleCancelled(5)
    expect(report.quarantinedCount() == 1 &&
        transition.to == RunState.RecoveryRequired,
        "uncooperative child is quarantined and forces recovery")
    release.store(true)
    stubborn.get()
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
