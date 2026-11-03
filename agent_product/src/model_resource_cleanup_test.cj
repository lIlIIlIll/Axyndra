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

// Delay only the close acknowledgement of a real isolated Python process.
// The production debt task is used unchanged, with a real Core-claimed Attempt
// and actual LocalProcessPort resource identity. No fake DTO admits the process.
class PendingModelResourceProbe {
    let owner: ProcessResourceOwner
    let debt: ModelProviderResourceDebt
    let allowClose: AtomicBool
    let closeEntered: AtomicBool
    private let opening: AtomicBool
    private let dispatch: ModelProviderDispatch
    private let port: LocalProcessPort
    private let root: String
    init(dispatch: ModelProviderDispatch, port: LocalProcessPort, root: String) {
        let id = ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "pending-cleanup-probe")
        let allowed = AtomicBool(false); let entered = AtomicBool(false); let launching = AtomicBool(true)
        let owned = ModelProviderResourceDebt(dispatch, { =>
            entered.store(true)
            // cancelResource(ModelAttempt) performs full close. Withhold the
            // actual close call until this fault gate opens, not its result
            // after the OS owner has already been released. Run cancellation
            // still reaches the real channel's token monitor independently.
            if (launching.load() || !allowed.load()) {
                return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "fixture.model_close_pending", "actual model channel close ACK is withheld"))
            }
            let _ = port.cancelResource(id)
            match (port.closeChannelResource(id)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (port.hasActiveResource(id)) { return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "fixture.model_close_pending", "actual model channel still owns resources")) }
            Result.Ok(())
        })
        this.owner = id; this.debt = owned; this.allowClose = allowed; this.closeEntered = entered
        this.opening = launching; this.dispatch = dispatch; this.port = port; this.root = root
    }
    func open(gate: ProductModelProviderDispatchGate): Unit {
        match (debt.admit()) { case Result.Err(error) => opening.store(false); throw IllegalStateException(error.code); case Result.Ok(_) => () }
        try {
            let channel = port.openModelChannel(modelResourceRequest(root, owner), dispatch, gate, 4096).value().getOrThrow()
            @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n")
        } finally { opening.store(false) }
    }
    func release(): Unit {
        allowClose.store(true); debt.requestClose()
        let deadline = MonoTime.now() + Duration.second * 5
        while (!debt.isReleased() && MonoTime.now() < deadline) {
            let _ = debt.close(); sleep(Duration.millisecond * 5)
        }
        if (!debt.isReleased() || port.hasActiveResource(owner)) { throw IllegalStateException("model cleanup did not acknowledge actual release") }
        @Expect(debt.close().isOk())
    }
}

func modelCleanupRuntime(fixture: ModelProviderProductFixture): AgentThreadRuntime {
    let facts = fixture.reader.read(fixture.gate.request.getOrThrow(), fixture.gate.snapshot).value().getOrThrow()
    fixture.runtimes.acquire(facts.threadId, facts.workspaceId).value().getOrThrow()
}

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
        let fixture = ModelProviderProductFixture(); let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        let probes = ArrayList<PendingModelResourceProbe>()
        try {
            fixture.factory.beforeOpen = { dispatch =>
                let probe = PendingModelResourceProbe(dispatch, port, root); probes.add(probe)
                probe.open(fixture.gate.actual)
                let runtime = modelCleanupRuntime(fixture)
                @Expect(runtime.requireModelBoundary(dispatch.runId, dispatch.epoch).error().getOrThrow().code,
                    "runtime.model_resources_unsettled")
                let active = runtime.activeRun().getOrThrow()
                @Expect(runtime.replaceToolSetAtSafeCut(dispatch.runId, dispatch.epoch, active.lane,
                    active.lane.toolSet).error().getOrThrow().code, "run.model_lane_cleanup_pending")
                // Same admitted Attempt can still access its own resources.
                @Expect(fixture.gate.actual.verifyProcessOwner(dispatch, probe.owner).isOk())
                @Expect(probe.debt.close().isError())
                @Expect(probe.closeEntered.load() && !probe.debt.isReleased() && port.hasActiveResource(probe.owner))
                throw IllegalStateException("fixture ends model execution while actual cleanup remains pending")
            }
            @Expect(fixture.run().isError())
            @Expect(probes.size, 1)
            @Expect(!probes[0].debt.isReleased())
            @Expect(port.hasActiveResource(probes[0].owner))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE id='provider-run' AND state='recovery_required'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            probes[0].release()
            // A late ACK releases resources, not permission to rewrite history
            // as successful or replay the already completed model Attempt.
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
        } finally {
            try { for (probe in probes) { probe.release() } }
            finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
        }
    }

    @TestCase
    func actualAckClearsOnlyModelDebtAndPreservesOrdinaryBackgroundTasks(): Unit {
        let fixture = ModelProviderProductFixture(); let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        let probes = ArrayList<PendingModelResourceProbe>(); let backgroundRelease = AtomicBool(false)
        try {
            fixture.factory.beforeOpen = { dispatch =>
                let runtime = modelCleanupRuntime(fixture)
                let background = spawn { while (!backgroundRelease.load()) { sleep(Duration.millisecond) } }
                @Expect(runtime.ownTask("ordinary-background-probe", background,
                    expectedRunId: Some(dispatch.runId), expectedEpoch: Some(dispatch.epoch)).isOk())
                @Expect(runtime.requireModelBoundary(dispatch.runId, dispatch.epoch).isOk())
                let probe = PendingModelResourceProbe(dispatch, port, root); probes.add(probe)
                probe.open(fixture.gate.actual)
                @Expect(probe.debt.close().isError())
                probe.release()
                let deadline = MonoTime.now() + Duration.second * 3
                while (runtime.requireModelBoundary(dispatch.runId, dispatch.epoch).isError() && MonoTime.now() < deadline) {
                    sleep(Duration.millisecond * 5)
                }
                @Expect(runtime.requireModelBoundary(dispatch.runId, dispatch.epoch).isOk())
                backgroundRelease.store(true)
            }
            @Expect(fixture.run().isOk())
            @Expect(probes.size, 1)
            @Expect(probes[0].debt.isReleased() && !port.hasActiveResource(probes[0].owner))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally {
            backgroundRelease.store(true)
            try { for (probe in probes) { probe.release() } }
            finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
        }
    }

    @TestCase
    func actualPendingCleanupPreventsCreatingRetryAttempt(): Unit {
        let fixture = ModelProviderProductFixture(); let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        let probes = ArrayList<PendingModelResourceProbe>()
        try {
            fixture.factory.openingFailure = Some(AgentError(AgentErrorKind.RateLimited,
                "fixture.retryable_provider_failure", "injected retryable failure after real resource launch",
                retryable: true, attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderTransportError))))
            fixture.factory.beforeOpen = { dispatch =>
                let probe = PendingModelResourceProbe(dispatch, port, root); probes.add(probe)
                probe.open(fixture.gate.actual)
            }
            let result = fixture.run(autoRetry: true)
            @Expect(result.isError())
            @Expect(probes.size, 1)
            @Expect(!probes[0].debt.isReleased() && port.hasActiveResource(probes[0].owner))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='abandoned'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='recovery_required'"), 1)
            @Expect(fixture.factory.count(), 0)
        } finally {
            try { for (probe in probes) { probe.release() } }
            finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
        }
    }

    @TestCase
    func actualRunCancellationDoesNotCompletePendingCleanupTask(): Unit {
        let fixture = ModelProviderProductFixture(); let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        let probes = ArrayList<PendingModelResourceProbe>(); let ready = AtomicBool(false)
        fixture.factory.beforeOpen = { dispatch =>
            let probe = PendingModelResourceProbe(dispatch, port, root); probes.add(probe)
            probe.open(fixture.gate.actual); ready.store(true)
            let deadline = MonoTime.now() + Duration.second * 10
            while (!dispatch.cancellation.isCancelled() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            if (!dispatch.cancellation.isCancelled()) { throw IllegalStateException("model cancellation did not arrive") }
        }
        let running = spawn { fixture.run() }
        try {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!ready.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(ready.load())
            @Expect(fixture.core.cancel(RunId("provider-run")).isOk())
            @Expect(running.get().isError())
            @Expect(probes.size, 1)
            @Expect(probes[0].closeEntered.load() && !probes[0].debt.isReleased())
            @Expect(port.hasActiveResource(probes[0].owner))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='recovery_required'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally {
            let _ = fixture.core.cancel(RunId("provider-run"))
            try { try { let _ = running.get() } finally { for (probe in probes) { probe.release() } } }
            finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
        }
    }
}
