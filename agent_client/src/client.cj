package agent_client

import agent_core.*
import agent_runtime.OwnedAgentEventSink
import agent_domain.*
import run_control.*

public interface AgentClient {

    // Typed DATA stays on the original installed forwarding chain.
    func startOwnedCheckpointFailure113(request: AgentRunRequest, events: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(start(request, events))
    }
    func resumeContextBoundaryOwnedCheckpointFailure113(request: AgentRunRequest, events: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(resumeContextBoundary(request, events))
    }
    func resumeOwnedCheckpointFailure113(request: AgentRunRequest, events: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(resume(request, events))
    }
    func decideOwnedCheckpointFailure113(request: AgentRunRequest, approval: ApprovalRequest, decision: ApprovalDecision, events: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(decide(request, approval, decision, events))
    }
    func takeOwnedCheckpointFailure113(run: RunId): OwnedAgentRunResult113 { OwnedAgentRunResult113.Held }
    func prepareOwnedCheckpointWave113(run: RunId,
        events!: ?OwnedAgentEventSink): (Bool, Int64, Int64) { (false, 0, 0) }

    func ownedCheckpointEventExpectation113(run: RunId, sequence: Int64): ?Bool { None<Bool> }

    func retireOwnedCheckpointProducerWitness113(run: RunId): Unit { () }

    func startRestricted111(request: AgentRunRequest, restriction: AgentRunStartRestriction111,
        events: AgentEventSink): Result<AgentRunOutcome> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "child.start_restriction_unsupported",
            "this transport cannot carry the original live start restriction"))
    }

    func startContinuation(value: AgentContinuationStart, events: AgentEventSink): Result<AgentRunOutcome> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "continuation.client_unsupported", "this transport cannot carry a live continuation admission"))
    }

    func start(
        request: AgentRunRequest,
        events: AgentEventSink
    ): Result<AgentRunOutcome>
    func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        events: AgentEventSink
    ): Result<AgentRunOutcome>
    func find(runId: RunId): Result<RunSnapshot>
    func events(runId: RunId, after: Int64): Result<EventPage>
    func cancel(runId: RunId): Result<Unit>
    func resumeContextBoundary(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "context.boundary_client_unavailable", "client cannot recover a context boundary"))
    }

    func resume(
        request: AgentRunRequest,
        events: AgentEventSink
    ): Result<AgentRunOutcome> {
        let _ = request
        let _ = events
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "client.model_resume_unavailable",
            "agent client does not support durable model execution recovery"
        ))
    }
}

public class InProcessAgentClient <: AgentClient {

    public func startOwnedCheckpointFailure113(request: AgentRunRequest, events: AgentEventSink): OwnedAgentRunResult113 {
        runs.startOwnedCheckpointFailure113(request, events)
    }
    public func resumeContextBoundaryOwnedCheckpointFailure113(request: AgentRunRequest, events: AgentEventSink): OwnedAgentRunResult113 {
        runs.resumeContextBoundaryOwnedCheckpointFailure113(request, events)
    }
    public func resumeOwnedCheckpointFailure113(request: AgentRunRequest, events: AgentEventSink): OwnedAgentRunResult113 {
        runs.resumeOwnedCheckpointFailure113(request, events)
    }
    public func decideOwnedCheckpointFailure113(request: AgentRunRequest, approval: ApprovalRequest, decision: ApprovalDecision, events: AgentEventSink): OwnedAgentRunResult113 {
        runs.decideOwnedCheckpointFailure113(request, approval, decision, events)
    }
    public func takeOwnedCheckpointFailure113(run: RunId): OwnedAgentRunResult113 {
        runs.takeOwnedCheckpointFailure113(run)
    }
    public func prepareOwnedCheckpointWave113(run: RunId,
        events!: ?OwnedAgentEventSink = None<OwnedAgentEventSink>): (Bool, Int64, Int64) {
        runs.prepareOwnedCheckpointWave113(run, events: events)
    }

    public func ownedCheckpointEventExpectation113(run: RunId, sequence: Int64): ?Bool {
        runs.ownedCheckpointEventExpectation113(run, sequence)
    }

    public func retireOwnedCheckpointProducerWitness113(run: RunId): Unit {
        runs.retireOwnedCheckpointProducerWitness113(run)
    }

    private let runs: RunService

    public init(runs: RunService) { this.runs = runs }

    public func startRestricted111(request: AgentRunRequest, restriction: AgentRunStartRestriction111,
        events: AgentEventSink): Result<AgentRunOutcome> { runs.startRestricted111(request, restriction, events) }

    public func startContinuation(value: AgentContinuationStart, events: AgentEventSink): Result<AgentRunOutcome> {
        runs.startContinuation(value, events)
    }

    public func start(
        request: AgentRunRequest,
        events: AgentEventSink
    ): Result<AgentRunOutcome> {
        runs.start(request, events)
    }

    public func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        events: AgentEventSink
    ): Result<AgentRunOutcome> {
        runs.decide(request, approval, decision, events)
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        runs.find(runId)
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        runs.events(runId, after)
    }

    public func cancel(runId: RunId): Result<Unit> {
        runs.cancel(runId)
    }

    public func resumeContextBoundary(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        runs.resumeContextBoundary(request, events)
    }

    public func resume(
        request: AgentRunRequest,
        events: AgentEventSink
    ): Result<AgentRunOutcome> {
        runs.resume(request, events)
    }
}

public enum AgentRpcCommand {
    Start(AgentRunRequest)
    | Decide(AgentRunRequest, ApprovalRequest, ApprovalDecision)
    | Find(RunId)
    | Events(RunId, Int64)
    | Cancel(RunId)
    | ResumeContextBoundary(AgentRunRequest)
}

public enum AgentRpcReply {
    RunOutcome(AgentRunOutcome)
    | RunSnapshot(RunSnapshot)
    | EventPageReply(EventPage)
    | Failure(AgentError)
}

public interface AgentRpcTransport {
    func exchange(
        command: AgentRpcCommand,
        events: AgentEventSink
    ): Result<AgentRpcReply>

    func resume(
        request: AgentRunRequest,
        events: AgentEventSink
    ): Result<AgentRpcReply> {
        let _ = request
        let _ = events
        Result.Ok(AgentRpcReply.Failure(AgentError(
            AgentErrorKind.RecoveryRequired,
            "client.rpc_resume_unavailable",
            "RPC transport does not support durable model execution recovery"
        )))
    }
}

public class RpcAgentClient <: AgentClient {
    private let transport: AgentRpcTransport

    public init(transport: AgentRpcTransport) {
        this.transport = transport
    }

    public func start(
        request: AgentRunRequest,
        events: AgentEventSink
    ): Result<AgentRunOutcome> {
        outcome(transport.exchange(AgentRpcCommand.Start(request), events))
    }

    // This command names only the new safe-cut recovery entry. The service
    // re-reads the durable continuation; request data never supplies authority.
    public func resumeContextBoundary(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        outcome(transport.exchange(AgentRpcCommand.ResumeContextBoundary(request), events))
    }

    public func resume(
        request: AgentRunRequest,
        events: AgentEventSink
    ): Result<AgentRunOutcome> {
        outcome(transport.resume(request, events))
    }

    public func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        events: AgentEventSink
    ): Result<AgentRunOutcome> {
        outcome(transport.exchange(
            AgentRpcCommand.Decide(request, approval, decision),
            events
        ))
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        match (transport.exchange(
            AgentRpcCommand.Find(runId),
            { _ => () }
        )) {
            case Result.Ok(AgentRpcReply.RunSnapshot(value)) =>
                Result.Ok(value)
            case Result.Ok(AgentRpcReply.Failure(error)) => Result.Err(error)
            case Result.Ok(_) => protocolError()
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        match (transport.exchange(
            AgentRpcCommand.Events(runId, after),
            { _ => () }
        )) {
            case Result.Ok(AgentRpcReply.EventPageReply(value)) =>
                Result.Ok(value)
            case Result.Ok(AgentRpcReply.Failure(error)) => Result.Err(error)
            case Result.Ok(_) => protocolError()
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        match (transport.exchange(
            AgentRpcCommand.Cancel(runId),
            { _ => () }
        )) {
            case Result.Ok(AgentRpcReply.RunSnapshot(_)) => Result.Ok(())
            case Result.Ok(AgentRpcReply.Failure(error)) => Result.Err(error)
            case Result.Ok(_) => protocolError()
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func outcome(
        result: Result<AgentRpcReply>
    ): Result<AgentRunOutcome> {
        match (result) {
            case Result.Ok(AgentRpcReply.RunOutcome(value)) =>
                Result.Ok(value)
            case Result.Ok(AgentRpcReply.Failure(error)) => Result.Err(error)
            case Result.Ok(_) => protocolError()
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func protocolError<T>(): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Protocol,
        "client.unexpected_rpc_reply",
        "RPC transport returned a reply for another command"
    ))
}
