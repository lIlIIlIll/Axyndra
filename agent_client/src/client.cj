package agent_client

import agent_core.*
import agent_domain.*
import run_control.*

public interface AgentClient {
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
    private let runs: RunService

    public init(runs: RunService) { this.runs = runs }

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
