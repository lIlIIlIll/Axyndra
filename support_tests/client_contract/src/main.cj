package client_contract

import agent_cli.*
import agent_client.*
import agent_core.*
import agent_domain.*
import agent_ports.*
import run_control.*

main(): Int64 {
    let router = CommandRouter()
    expect(match (router.route("explain this code").value().getOrThrow()) {
        case RoutedInput.Prompt(value) => value == "explain this code"
        case _ => false
    }, "natural prompts remain model input")
    expect(match (router.route("/approve operation-1")
                  .value().getOrThrow()) {
        case RoutedInput.Command(ClientCommand.Approve(value)) =>
            value == "operation-1"
        case _ => false
    }, "commands are typed")
    expect(
        router.route("/made-up").isError(),
        "unknown slash input is rejected locally"
    )
    expect(match (router.route("/model").value().getOrThrow()) {
        case RoutedInput.Command(ClientCommand.Builtin(name, _)) =>
            name == "model"
        case _ => false
    }, "OMP built-ins are routed locally")

    let transport = FixtureTransport()
    let client = RpcAgentClient(transport)
    let snapshot = client.find(RunId("run-1")).value().getOrThrow()
    expect(snapshot.runId.value == "run-1",
           "RPC client preserves typed domain replies")
    expect(transport.calls == 1, "client uses transport boundary")
    recoveryDelegationContracts()
    println("client contract passed")
    0
}

func recoveryDelegationContracts(): Unit {
    let request = AgentRunRequest(
        RunId("resume-run"), SessionId("resume-session"),
        "fixture", "resume the exact durable request"
    )
    let serviceRunner = CountingRunner()
    let service = CoreRunService(serviceRunner, FixtureRuns())
    expect(service.resume(request, {_ => ()}).isOk() &&
        serviceRunner.resumeCalls == 1 && serviceRunner.startCalls == 0,
        "CoreRunService delegates recovery to resume exactly once and never start")

    let clientRunner = CountingRunner()
    let client = InProcessAgentClient(CoreRunService(clientRunner, FixtureRuns()))
    expect(client.resume(request, {_ => ()}).isOk() &&
        clientRunner.resumeCalls == 1 && clientRunner.startCalls == 0,
        "InProcessAgentClient delegates recovery to resume exactly once and never start")

    let frozenTransport = FixtureTransport()
    let rpc = RpcAgentClient(frozenTransport)
    let resumed = rpc.resume(request, {_ => ()})
    expect(match (resumed) {
        case Result.Err(error) => error.kind == AgentErrorKind.RecoveryRequired &&
            error.code == "client.rpc_resume_unavailable"
        case Result.Ok(_) => false
    } && frozenTransport.calls == 0 && frozenTransport.startCalls == 0,
        "RPC resume uses the frozen RecoveryRequired default without falling back to Start")
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException("contract failed: ${message}")
    }
}

class FixtureTransport <: AgentRpcTransport {
    var calls: Int64 = 0
    var startCalls: Int64 = 0

    public func exchange(
        command: AgentRpcCommand,
        events: AgentEventSink
    ): Result<AgentRpcReply> {
        let _ = events
        calls += 1
        match (command) {
            case AgentRpcCommand.Start(_) =>
                startCalls += 1
                Result.Ok(AgentRpcReply.Failure(AgentError(
                    AgentErrorKind.Internal,
                    "fixture.start_must_not_run",
                    "startup recovery must not fall back to Start"
                )))
            case AgentRpcCommand.Find(runId) =>
                Result.Ok(AgentRpcReply.RunSnapshot(RunSnapshot(
                    runId,
                    SessionId("session"),
                    RunState.Running
                )))
            case _ => Result.Ok(AgentRpcReply.Failure(AgentError(
                AgentErrorKind.Protocol,
                "fixture.unsupported",
                "fixture command is unsupported"
            )))
        }
    }
}

class CountingRunner <: AgentRunner {
    var startCalls: Int64 = 0
    var resumeCalls: Int64 = 0

    public func start(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        let _ = sink
        startCalls += 1
        Result.Ok(AgentRunOutcome.Completed(RunSnapshot(
            request.runId, request.sessionId, RunState.Completed
        )))
    }

    public func resume(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        let _ = sink
        resumeCalls += 1
        Result.Ok(AgentRunOutcome.Completed(RunSnapshot(
            request.runId, request.sessionId, RunState.Completed
        )))
    }

    public func cancel(runId: RunId): Result<Unit> {
        let _ = runId
        Result.Ok(())
    }

    public func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        let _ = approval
        let _ = decision
        let _ = sink
        Result.Ok(AgentRunOutcome.Completed(RunSnapshot(
            request.runId, request.sessionId, RunState.Completed
        )))
    }
}

class FixtureRuns <: RunRepository {
    public func save(snapshot: RunSnapshot): Result<Unit> {
        let _ = snapshot
        Result.Ok(())
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        Result.Ok(RunSnapshot(
            runId, SessionId("resume-session"), RunState.Running
        ))
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        let _ = runId
        let _ = after
        Result.Ok(EventPage([], 0))
    }

    public func append(event: AgentEvent): Result<Unit> {
        let _ = event
        Result.Ok(())
    }
}
