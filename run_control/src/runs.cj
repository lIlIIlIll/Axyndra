package run_control

import agent_core.*
import agent_runtime.OwnedAgentEventSink
import agent_domain.*
import agent_ports.*

public interface RunService {

    // Typed DATA stays on the original installed forwarding chain.
    func startOwnedCheckpointFailure113(request: AgentRunRequest, sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(start(request, sink))
    }
    func resumeContextBoundaryOwnedCheckpointFailure113(request: AgentRunRequest, sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(resumeContextBoundary(request, sink))
    }
    func resumeOwnedCheckpointFailure113(request: AgentRunRequest, sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(resume(request, sink))
    }
    func decideOwnedCheckpointFailure113(request: AgentRunRequest, approval: ApprovalRequest, decision: ApprovalDecision, sink: AgentEventSink): OwnedAgentRunResult113 {
        OwnedAgentRunResult113.Existing(decide(request, approval, decision, sink))
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
        sink: AgentEventSink
    ): Result<AgentRunOutcome>
    func resumeContextBoundary(request: AgentRunRequest, sink: AgentEventSink): Result<AgentRunOutcome> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "context.boundary_service_unavailable", "service cannot recover a context boundary"))
    }

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

    public func startOwnedCheckpointFailure113(request: AgentRunRequest, sink: AgentEventSink): OwnedAgentRunResult113 {
        runner.startOwnedCheckpointFailure113(request, sink)
    }
    public func resumeContextBoundaryOwnedCheckpointFailure113(request: AgentRunRequest, sink: AgentEventSink): OwnedAgentRunResult113 {
        runner.resumeContextBoundaryOwnedCheckpointFailure113(request, sink)
    }
    public func resumeOwnedCheckpointFailure113(request: AgentRunRequest, sink: AgentEventSink): OwnedAgentRunResult113 {
        runner.resumeOwnedCheckpointFailure113(request, sink)
    }
    public func decideOwnedCheckpointFailure113(request: AgentRunRequest, approval: ApprovalRequest, decision: ApprovalDecision, sink: AgentEventSink): OwnedAgentRunResult113 {
        runner.decideOwnedCheckpointFailure113(request, approval, decision, sink)
    }
    public func takeOwnedCheckpointFailure113(run: RunId): OwnedAgentRunResult113 {
        runner.takeOwnedCheckpointFailure113(run)
    }
    public func prepareOwnedCheckpointWave113(run: RunId,
        events!: ?OwnedAgentEventSink = None<OwnedAgentEventSink>): (Bool, Int64, Int64) {
        runner.prepareOwnedCheckpointWave113(run, events: events)
    }

    public func ownedCheckpointEventExpectation113(run: RunId, sequence: Int64): ?Bool {
        runner.ownedCheckpointEventExpectation113(run, sequence)
    }

    public func retireOwnedCheckpointProducerWitness113(run: RunId): Unit {
        runner.retireOwnedCheckpointProducerWitness113(run)
    }

    private let runner: AgentRunner
    private let runs: RunRepository

    public init(runner: AgentRunner, runs: RunRepository) {
        this.runner = runner
        this.runs = runs
    }

    public func startRestricted111(request: AgentRunRequest, restriction: AgentRunStartRestriction111,
        events: AgentEventSink): Result<AgentRunOutcome> { runner.startRestricted111(request, restriction, events) }

    public func startContinuation(value: AgentContinuationStart, events: AgentEventSink): Result<AgentRunOutcome> {
        runner.startContinuation(value, events)
    }

    public func start(
        request: AgentRunRequest,
        sink: AgentEventSink
    ): Result<AgentRunOutcome> {
        runner.start(request, sink)
    }

    public func resumeContextBoundary(request: AgentRunRequest, sink: AgentEventSink): Result<AgentRunOutcome> {
        runner.resumeContextBoundary(request, sink)
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
