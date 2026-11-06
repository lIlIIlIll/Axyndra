package agent_product

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import model_provider_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Positive resource cases below use the real installed Host factory and its
// original debt tasks. Unowned descriptive dispatches still fail admission.
@Test
class ModelResourceCleanupTests {
    @TestCase
    func descriptiveDispatchCannotOwnOrReleaseResources(): Unit {
        let source = CancellationSource(); let called = AtomicBool(false)
        let dispatch = ModelProviderDispatch(ModelAttemptId("guessed"), RunId("guessed-run"), ThreadId("guessed-thread"), 1,
            "guessed-request", modelPolicySha256Text("binding"), modelPolicySha256Text("input"), source.token, { => Result.Ok(()) })
        try {
            let debt = ModelProviderResourceDebt(dispatch, { => called.store(true); Result.Ok(()) })
            @Expect(debt.admit().error().getOrThrow().code, "model.resource_task_unowned")
            debt.requestClose()
            @Expect(debt.close().isError())
            @Expect(!called.load() && !debt.isReleased())
        } finally { dispatch.close(); source.close() }
    }

    @TestCase
    func actualPendingCloseBlocksSafeCutAndQuarantinesFailedRun(): Unit {
        installedModelPendingCleanup204()
    }

    @TestCase
    func actualAckClearsOnlyModelDebtAndPreservesOrdinaryBackgroundTasks(): Unit {
        installedModelAckPreservesBackground204()
    }

    @TestCase
    func actualPendingCleanupPreventsCreatingRetryAttempt(): Unit {
        installedModelPendingCleanup204(retry: true)
    }

    @TestCase
    func actualRunCancellationDoesNotCompletePendingCleanupTask(): Unit {
        installedModelCancelledPendingCleanup204()
    }
}
