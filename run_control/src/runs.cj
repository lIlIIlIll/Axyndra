package run_control

import agent_core.*
import agent_domain.*
import agent_ports.*

public interface RunService {
    func start(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome>
    func resume(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome>
    func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        sink: AgentEventSink
    ): Result<AgentRunOutcome>
    func find(runId: RunId): Result<RunSnapshot>
    func events(runId: RunId, after: Int64): Result<EventPage>
    func cancel(runId: RunId): Result<Unit>
}

public class CoreRunService <: RunService {
    private let runner: AgentRunner
    private let runs: RunRepository

    public init(runner: AgentRunner, runs: RunRepository) {
        this.runner = runner
        this.runs = runs
    }

    public func start(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        runner.start(request, sink)
    }

    public func resume(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        runner.resume(request, sink)
    }

    public func decide(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        runner.decide(request, approval, decision, sink)
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        runs.find(runId)
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        runs.events(runId, after)
    }

    public func cancel(runId: RunId): Result<Unit> {
        runner.cancel(runId)
    }

    public func start(request: AgentRunRequest): Result<AgentRunOutcome> {
        start(request, { _ => () })
    }
}
