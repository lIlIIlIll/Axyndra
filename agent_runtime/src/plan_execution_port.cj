package agent_runtime

import agent_domain.*

// Only canonical Operation receipts can settle a reservation. No caller may
// report tool success or replenish a spent attempt through this interface.
public interface PlanExecutionPort {
    func activate(executionId: String, sessionId: String, contract: PlanContract): Result<Unit>
    func executionForSession(sessionId: String): Result<?String>
    func contractForSession(sessionId: String): Result<?PlanContract>
    func inspectForSession(sessionId: String): Result<AgentValue>
    func bind(executionId: String, sessionId: String, runId: RunId, contract: PlanContract): Result<Unit>
    func executionForRun(runId: RunId): Result<?String>
    func bindRun(executionId: String, sessionId: String, runId: RunId): Result<Unit>
    func admit(runId: RunId, operationId: OperationId, stepId: String,
        actionId: String, plan: NormalizedOperationPlan): Result<Unit>
    func observe(runId: RunId, operationId: OperationId): Result<PlanStepDecision>
    func inspect(runId: RunId): Result<AgentValue>
    func requireComplete(runId: RunId): Result<Unit>
    // Idempotent confirmation after successful canonical Run settlement. The
    // concrete sink seals atomically with the owned-work completion barrier.
    func finish(runId: RunId): Result<Unit>
    func inherit(parentRunId: RunId, childSessionId: String, parentOperationId: OperationId): Result<Unit>
    // Trusted fresh-child producer has returned before any worker was queued
    // or launched. Revoke only active membership; immutable history survives.
    func abandonUnstartedChild204(parentRunId: RunId, childSessionId: String,
        parentOperationId: OperationId): Result<Unit>
    func isPlanOwner(runId: RunId): Result<Bool>
}

// Optional closed applicability query for callers without a DATA owner.
// Presence is not approval, authorization, or a consumer-return receipt. The
// concrete reader returns no execution identity, contract, or raw SQL value.
public interface PlanExecutionSessionPresence204 {
    func sessionHasExecution204(sessionId: String): Result<Bool>
}

// The production receiver admits an independent paid DATA copy. No borrowed
// prepared/catalog graph crosses this interface and Ok is not a sender ACK.
public interface PlanExecutionDataPort204 {
    func admitOwnedPlan204(runId: RunId, operationId: OperationId, stepId: String,
        actionId: String, value: PreparedPlanUtf8Owner204): Result<Unit>
}
