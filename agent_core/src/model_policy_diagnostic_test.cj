package agent_core

import agent_domain.*
import agent_ports.*
import std.unittest.*
import std.unittest.testmacro.*

// Boundary-unit probe only. Actual installed/no-network evidence belongs to
// Product's InstalledModelPolicyDiagnosticTests, not this provider double.
class PolicyDiagnosticProbe <: ModelPort {
    let denyAt: Int64
    var validations: Int64 = 0
    var executions: Int64 = 0
    var selectedModel = ""
    var snapshotModel = ""
    init(denyAt: Int64) { this.denyAt = denyAt }
    public func validatePolicySnapshot(model: String, snapshot: ?ModelExecutionCapabilitiesSnapshot): Result<Unit> {
        validations += 1; selectedModel = model
        snapshotModel = match (snapshot) { case Some(value) => value.modelId; case None => "" }
        if (validations >= denyAt) { return Result.Err(AgentError(AgentErrorKind.Configuration,
            "test.policy_diagnostic", "diagnostic boundary probe")) }
        Result.Ok(())
    }
    public func execute(_request: ModelRequest, _events: ModelEventSink): Result<ModelReply> {
        executions += 1
        Result.Err(AgentError(AgentErrorKind.RateLimited, "test.retry", "retry probe", retryable: true,
            fields: [ErrorField(RETRY_AFTER_MILLIS_FIELD, "1")]))
    }
}

@Test
class ModelPolicyDiagnosticBoundaryTests {
    @TestCase
    func controlledWrapperPreservesTheExactDiagnosticAndSnapshot(): Unit {
        let provider = PolicyDiagnosticProbe(1)
        let parent = AgentRunRequest(RunId("policy-wrapper"), SessionId("policy-wrapper"), "parent-model", "probe")
        let result = ControlledModelPort(provider).validatePolicySnapshot("parent-model", Some(parent.modelCapabilitiesSnapshot))
        @Expect(result.error().getOrThrow().code, "test.policy_diagnostic")
        @Expect(provider.validations, 1)
        @Expect(provider.selectedModel, "parent-model")
        @Expect(provider.snapshotModel, "parent-model")
        @Expect(provider.executions, 0)
    }

    @TestCase
    func internalSelectedModelDoesNotBorrowTheAccountingParentSnapshot(): Unit {
        let provider = PolicyDiagnosticProbe(1)
        let parent = AgentRunRequest(RunId("policy-review"), SessionId("policy-review"), "parent-model", "probe")
        let request = ModelRequest("reviewer-model", [], requestId: "policy-review", tools: [],
            parallelToolCalls: false, toolChoice: ModelToolChoice.NoTools)
        let result = ControlledModelPort(provider).executeInternal(request,
            InternalModelCallOptions(parent: Some(parent), standaloneAccounting: true))
        @Expect(result.error().getOrThrow().code, "test.policy_diagnostic")
        @Expect(provider.selectedModel, "reviewer-model")
        @Expect(provider.snapshotModel, "")
        @Expect(provider.executions, 0)
    }

    @TestCase
    func internalRetryRechecksPolicyBeforeAnotherExecution(): Unit {
        // Entry + first loop validate successfully; a changed configuration is
        // rejected at the second loop before its model-request reservation.
        let provider = PolicyDiagnosticProbe(3)
        let parent = AgentRunRequest(RunId("policy-retry"), SessionId("policy-retry"), "same-model", "probe",
            budget: ResourceBudget(maxModelRequests: 2))
        let request = ModelRequest("same-model", [], requestId: "policy-retry", tools: [],
            parallelToolCalls: false, toolChoice: ModelToolChoice.NoTools)
        let result = ControlledModelPort(provider).executeInternal(request,
            InternalModelCallOptions(parent: Some(parent), standaloneAccounting: true, maxAttempts: 2))
        @Expect(result.error().getOrThrow().code, "test.policy_diagnostic")
        @Expect(provider.validations, 3)
        @Expect(provider.snapshotModel, "same-model")
        @Expect(provider.executions, 1)
    }
}
