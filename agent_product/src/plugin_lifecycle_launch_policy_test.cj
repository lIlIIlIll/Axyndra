package agent_product

import agent_domain.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProductLifecycleLaunchPolicyTests {
    @TestCase
    func actualLaunchPlanWithOnlyReplayDispositionChangedFailsTheOwnersPolicyPredicate(): Unit {
        let fixture = LifecycleOwnerFixture()
        let captured = LifecycleOwnerCaptured()
        try {
            let _ = lifecycleTestRequire(fixture.control.launch(fixture.product.vnext,
                SessionId("replay-policy-maintenance"), fixture.grant("replay-policy-instance"), fixture.ceiling(),
                { lease, context, prepared =>
                    captured.lease = Some(lease); captured.context = Some(context); captured.prepared = Some(prepared)
                    Result.Ok(lifecycleControlEcho(lease, "actual-policy-startup\n"))
                }, approvalDecision: Some(ApprovalDecision.Approve)))
            let plan = captured.prepared.getOrThrow().operationPlan
            @Expect(lifecycleNonReplayableLaunchPlan(plan))
            let changed = NormalizedOperationPlan(plan.toolName, plan.canonicalArguments, plan.requiredCapabilities,
                plan.effectClass, plan.retryDisposition, plan.bindingDigest, resolvedPaths: plan.resolvedPaths,
                resolvedHosts: plan.resolvedHosts, networkPolicy: Some(plan.networkPolicy), cwd: plan.cwd,
                relevantEnvironment: plan.relevantEnvironment, approvalMetadata: Some(plan.approvalMetadata),
                idempotencyKey: plan.idempotencyKey, replayDisposition: Some(ReplayDisposition.SafeReplay),
                toolVersion: plan.implementation.toolVersion, implementationFingerprint: plan.implementation.implementationFingerprint,
                schemaDigest: plan.implementation.schemaDigest, effectiveArgumentsDigest: plan.implementation.effectiveArgumentsDigest,
                replayContractVersion: plan.implementation.replayContractVersion)
            // This is a pure policy counterexample derived from an actual
            // captured launch, not a forged Prepared or an authority token.
            @Expect(!lifecycleNonReplayableLaunchPlan(changed))
            @Expect(fixture.processes.opens, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
        } finally { fixture.close() }
    }
}
