package agent_client

import agent_core.*
import agent_domain.*
import run_control.*

// Typed server dispatch uses the actual RunService entry. It never converts a
// failed recovery command into Start or an old RunningModel resume request.
public class RunServiceAgentRpcTransport <: AgentRpcTransport {
    private let runs: RunService

    public init(runs: RunService) { this.runs = runs }

    public func exchange(command: AgentRpcCommand, events: AgentEventSink): Result<AgentRpcReply> {
        match (command) {
            case AgentRpcCommand.ResumeContextBoundary(request) =>
                rpcRunOutcome(runs.resumeContextBoundary(request, events))
            case AgentRpcCommand.Start(request) => rpcRunOutcome(runs.start(request, events))
            case AgentRpcCommand.Decide(request, approval, decision) =>
                rpcRunOutcome(runs.decide(request, approval, decision, events))
            case AgentRpcCommand.Find(run) => rpcRunSnapshot(runs.find(run))
            case AgentRpcCommand.Events(run, after) =>
                match (runs.events(run, after)) {
                    case Result.Ok(value) => Result.Ok(AgentRpcReply.EventPageReply(value))
                    case Result.Err(error) => Result.Ok(AgentRpcReply.Failure(error))
                }
            case AgentRpcCommand.Cancel(run) =>
                match (runs.cancel(run)) {
                    case Result.Ok(_) => rpcRunSnapshot(runs.find(run))
                    case Result.Err(error) => Result.Ok(AgentRpcReply.Failure(error))
                }
        }
    }
}

private func rpcRunOutcome(value: Result<AgentRunOutcome>): Result<AgentRpcReply> {
    match (value) {
        case Result.Ok(result) => Result.Ok(AgentRpcReply.RunOutcome(result))
        case Result.Err(error) => Result.Ok(AgentRpcReply.Failure(error))
    }
}

private func rpcRunSnapshot(value: Result<RunSnapshot>): Result<AgentRpcReply> {
    match (value) {
        case Result.Ok(result) => Result.Ok(AgentRpcReply.RunSnapshot(result))
        case Result.Err(error) => Result.Ok(AgentRpcReply.Failure(error))
    }
}
