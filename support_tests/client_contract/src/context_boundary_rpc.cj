package client_contract

import agent_client.*
import agent_core.*
import agent_domain.*
import run_control.*

// Carrier/delegation controls only. These are not a durable recovery or Source
// fixture: the separate real Core contract owns the SIGKILL/SQLite probes.
func contextBoundaryRpcContracts(): Unit {
    let request = AgentRunRequest(RunId("cut-rpc-run"), SessionId("cut-rpc-thread"),
        "fixture", "untrusted caller data")
    let runner = CutRpcRunner()
    let service = CoreRunService(runner, FixtureRuns())
    let client = RpcAgentClient(RunServiceAgentRpcTransport(service))
    // The mutable holder avoids capturing a var through a non-immediate call.
    let observed = CutRpcEvents()
    let result = client.resumeContextBoundary(request, { event => observed.accept(event) })
    expect(result.isOk() && runner.boundaryCalls == 1 && runner.startCalls == 0 && runner.oldResumeCalls == 0,
        "RPC command delegates to the distinct real RunService boundary method exactly once")
    expect(observed.count == 1, "RPC boundary forwards the original event sink")

    runner.fail = true
    let denied = client.resumeContextBoundary(request, {_ => ()})
    expect(match (denied) {
        case Result.Err(error) => error.kind == AgentErrorKind.RecoveryRequired && error.code == "cut.rpc_fixture_current_rejected"
        case _ => false
    } && runner.boundaryCalls == 2 && runner.startCalls == 0 && runner.oldResumeCalls == 0,
        "service rejection is preserved without Start or old resume fallback")

    let unsupported = RpcAgentClient(RunServiceAgentRpcTransport(CoreRunService(CountingRunner(), FixtureRuns())))
    expect(unsupported.resumeContextBoundary(request, {_ => ()}).isError(),
        "a runner without the new recovery entry remains fail closed")
    let wrong = RpcAgentClient(CutRpcWrongReply())
    expect(match (wrong.resumeContextBoundary(request, {_ => ()})) {
        case Result.Err(error) => error.kind == AgentErrorKind.Protocol && error.code == "client.unexpected_rpc_reply"
        case _ => false
    }, "a reply for another command cannot become a recovery outcome")

    let old = client.resume(request, {_ => ()})
    expect(match (old) {
        case Result.Err(error) => error.code == "client.rpc_resume_unavailable"
        case _ => false
    } && runner.oldResumeCalls == 0, "old RPC model recovery default remains byte-for-byte closed")
}

class CutRpcEvents {
    var count: Int64 = 0
    func accept(event: AgentEvent): Unit { let _ = event; count += 1 }
}

class CutRpcWrongReply <: AgentRpcTransport {
    public func exchange(command: AgentRpcCommand, events: AgentEventSink): Result<AgentRpcReply> {
        let _ = command; let _ = events
        Result.Ok(AgentRpcReply.EventPageReply(EventPage([], 0)))
    }
}

class CutRpcRunner <: AgentRunner {
    var boundaryCalls: Int64 = 0
    var startCalls: Int64 = 0
    var oldResumeCalls: Int64 = 0
    var fail = false
    public func resumeContextBoundary(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        boundaryCalls += 1
        if (fail) { return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "cut.rpc_fixture_current_rejected", "actual recovery entry rejected current state")) }
        events(AgentEvent(EventMeta(1, TraceId("cut-rpc-carrier"), request.runId), AgentEventPayload.RunStarted))
        Result.Ok(AgentRunOutcome.Completed(RunSnapshot(request.runId, request.sessionId, RunState.Completed)))
    }
    public func start(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        let _ = request; let _ = events; startCalls += 1
        Result.Err(AgentError(AgentErrorKind.Internal, "cut.rpc_start_forbidden", "must not restart"))
    }
    public func resume(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        let _ = request; let _ = events; oldResumeCalls += 1
        Result.Err(AgentError(AgentErrorKind.Internal, "cut.rpc_old_resume_forbidden", "must not replay"))
    }
    public func cancel(run: RunId): Result<Unit> { let _ = run; Result.Ok(()) }
    public func decide(request: AgentRunRequest, approval: ApprovalRequest, decision: ApprovalDecision,
        events: AgentEventSink): Result<AgentRunOutcome> {
        let _ = approval; let _ = decision
        start(request, events)
    }
}
