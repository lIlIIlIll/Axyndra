package run_lifecycle_vnext_contract

import std.sync.*
import agent_domain.*
import agent_runtime.*

main(): Int64 {
    stateMachineContract()
    completedJoinContract()
    failedChildContract()
    emptyFailureContract()
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
    let started = lifecycle.start().value().getOrThrow()
    let childToken = lifecycle.scope.childToken()
    let worker = spawn {
        while (!childToken.isCancelled()) { sleep(Duration.millisecond) }
    }
    lifecycle.scope.own("tool/process", worker).value().getOrThrow()
    let cancelling = lifecycle.requestCancel().value().getOrThrow()
    expect(childToken.isCancelled(), "parent Run cancellation reaches child token")
    let (transition, report) = lifecycle.settleCancelled(1000)
    let (state, sequence) = lifecycle.machine.snapshot()
    let late = lifecycle.scope.own("late", spawn {})
    let lateCode = match (late) {
        case Result.Err(error) => error.code
        case Result.Ok(_) => ""
    }
    expect(
        started.sequence == 1 && started.from == RunState.Created &&
            started.to == RunState.Running && started.reason == "" &&
            cancelling.sequence == 2 && cancelling.from == RunState.Running &&
            cancelling.to == RunState.Cancelling &&
            cancelling.reason == "cancel_requested" &&
            transition.sequence == 3 && transition.from == RunState.Cancelling &&
            transition.to == RunState.Cancelled && transition.reason == "joined" &&
            state == RunState.Cancelled && sequence == 3,
        "cancellation emits the exact Created/Running/Cancelling/Cancelled trace"
    )
    expect(
        report.settlements.size == 1 &&
            report.settlements[0].name == "tool/process" &&
            report.settlements[0].outcome == OwnedTaskOutcome.Joined &&
            lateCode == "run.scope_settling",
        "cooperative cancellation joins its worker and rejects late ownership"
    )
}

func quarantineContract(): Unit {
    let lifecycle = RunLifecycle()
    let started = lifecycle.start().value().getOrThrow()
    let release = AtomicBool(false)
    let stubborn = spawn {
        while (!release.load()) { sleep(Duration.millisecond) }
    }
    lifecycle.scope.own("mcp/ambiguous", stubborn).value().getOrThrow()
    let cancelling = lifecycle.requestCancel().value().getOrThrow()
    let (transition, report) = lifecycle.settleCancelled(5)
    expect(
        started.sequence == 1 && cancelling.sequence == 2 &&
            cancelling.from == RunState.Running &&
            cancelling.to == RunState.Cancelling &&
            cancelling.reason == "cancel_requested" && transition.sequence == 3 &&
            transition.from == RunState.Cancelling &&
            transition.to == RunState.RecoveryRequired &&
            transition.reason == "quarantined=1" &&
            report.settlements.size == 1 &&
            report.settlements[0].name == "mcp/ambiguous" &&
            report.settlements[0].outcome == OwnedTaskOutcome.Quarantined,
        "uncooperative cancellation records one quarantined MCP worker"
    )
    release.store(true)
    stubborn.get()
    let (state, sequence) = lifecycle.machine.snapshot()
    expect(
        state == RunState.RecoveryRequired && sequence == 3 &&
            lifecycle.scope.own("late", spawn {}).isError(),
        "quarantine remains RecoveryRequired after the worker eventually exits"
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}

func emptyFailureContract(): Unit {
    let lifecycle = RunLifecycle()
    lifecycle.start().value().getOrThrow()
    lifecycle.scope.own("empty", spawn { throw Exception("") }).value().getOrThrow()
    let (transition, report) = lifecycle.settle(RunState.Completed, 1000)
    expect(transition.to == RunState.Failed && report.failedCount() == 1,
        "empty exception message still represents failed owned work")
}
