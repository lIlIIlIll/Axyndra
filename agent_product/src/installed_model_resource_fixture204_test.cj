package agent_product

import agent_core.*
import agent_domain.*
import agent_host_runtime
import agent_plugin_registry
import agent_ports.*
import agent_runtime.*
import agent_store.*
import model_provider_runtime.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Native composition instrumentation only. The original installed Host creates
// every claim; the original LocalProcessPort verifies it and performs all I/O.
// A withheld cleanup report is an injected backend failure, never an ACK.
class InstalledResourceLauncher204 <: agent_host_runtime.HostModelProcessLauncher {
    let actual: LocalProcessPort
    let allowClose = AtomicBool(true)
    let closeEntered = AtomicBool(false)
    let opened = AtomicInt64(0)
    var afterOpen: (ProcessRequest, agent_host_runtime.HostModelProcessLaunchClaim, ProcessChannel) -> Unit = { _, _, _ => () }
    var openingFailure: ?AgentError = None<AgentError>
    init(actual: LocalProcessPort) { this.actual = actual }
    public func openClaimedModelChannel(request: ProcessRequest,
        claim: agent_host_runtime.HostModelProcessLaunchClaim, maximum: Int64): Result<ProcessChannel> {
        let channel = match (actual.openClaimedModelChannel(request, claim, maximum)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        opened.fetchAdd(1)
        afterOpen(request, claim, channel)
        match (openingFailure) { case Some(error) => return Result.Err(error); case None => () }
        Result.Ok(channel)
    }
    public func openClaimedModelHttpExchange(owner: ProcessResourceOwner,
        claim: agent_host_runtime.HostModelProcessLaunchClaim, request: AgentValue, root: String,
        policy: NetworkPolicy, credentials: Array<agent_host_runtime.HostPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte>, expanded!: Bool): Result<agent_host_runtime.HostHttpExchangeReader> {
        actual.openClaimedModelHttpExchange(owner, claim, request, root, policy, credentials, limits,
            payloadBody: payloadBody, expanded: expanded)
    }
    public func cancelResource(owner: ProcessResourceOwner): Result<Unit> { actual.cancelResource(owner) }
    public func closeChannelResource(owner: ProcessResourceOwner): Result<Unit> {
        closeEntered.store(true)
        if (!allowClose.load()) { return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "fixture.installed_close_pending", "actual backend cleanup acknowledgement is withheld")) }
        actual.closeChannelResource(owner)
    }
    public func hasActiveResource(owner: ProcessResourceOwner): Bool { actual.hasActiveResource(owner) }
}

// Observe only after the original helper returns. Forward the exact request,
// policy checks, transcript loan and Returned/Held envelope without alteration.
class InstalledResourceModelPort204 <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    let actual: agent_host_runtime.HostInstalledModelPort
    var afterReturn: () -> Unit = { => () }
    init(actual: agent_host_runtime.HostInstalledModelPort) { this.actual = actual }
    public func validatePolicySnapshot(model: String, snapshot: ?ModelExecutionCapabilitiesSnapshot): Result<Unit> {
        actual.validatePolicySnapshot(model, snapshot)
    }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        let result = actual.execute(request, events); afterReturn(); result
    }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        funding: ModelInputDataBudget159): ModelInputReturn159 {
        let result = actual.executeReturningInput159(request, events, funding); afterReturn(); result
    }
    public func transcriptSnapshot(request: ModelRequest): ?String { actual.transcriptSnapshot(request) }
    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        actual.transcriptSnapshotReturning159(request, loan)
    }
    public func validateTranscriptSnapshot(snapshot: String): Bool { actual.validateTranscriptSnapshot(snapshot) }
    public func cancel(requestId: String): Result<Unit> { actual.cancel(requestId) }
}

class InstalledModelResourceFixture204 {
    let installed: InstalledModelProductFixture
    let database: SqliteDatabase
    let processes: LocalProcessPort
    let launcher: InstalledResourceLauncher204
    let model: agent_host_runtime.HostInstalledModelPort
    let observedModel: InstalledResourceModelPort204
    let runtimes: ThreadRuntimeRegistry
    let core: AgentCore
    let template: AgentRunRequest
    let runId = RunId("installed-resource-run")
    let threadId = ThreadId("installed-resource-thread")
    init() {
        let opened = InstalledModelProductFixture("chat", timeoutMillis: 0)
        var native: ?LocalProcessPort = None<LocalProcessPort>
        try {
            // Obtain the real selected policy without starting a second Run or
            // creating another mutable Runtime for the tested Thread.
            let seed = lifecycleTestRequire(opened.product.prepareRequest("capability snapshot only",
                sessionId: Some(SessionId("installed-resource-policy-only")), thinking: ThinkingLevel.Off))
            let db = opened.database
            let port = LocalProcessPort(LocalWorkspace(opened.root), sandboxEnabled: true); native = Some(port)
            let instrumented = InstalledResourceLauncher204(port)
            let registry = SqliteThreadRuntimeRegistry(db,
                ContextProjector("installed-model-resource-contract", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
            let catalog = ToolCatalog(); let operations = DurableOperationStore(db)
            let selected = agent_host_runtime.HostInstalledModelPort(opened.product.vnext.javascriptPlugins,
                opened.root + "/settings", db, registry, instrumented,
                ProductArtifactStore(opened.root + "/state", database: Some(db), operations: Some(operations)))
            let observed = InstalledResourceModelPort204(selected)
            let runner = AgentCore(observed, SqliteRunRepository(db),
                ToolPipeline(catalog, operations, SqliteAuditRepository(db), ProviderFixtureIds()), catalog,
                threadRuntimes: Some(registry), operationRuntime: Some(operations),
                modelDecisionRuntime: Some(SqliteModelDecisionStore(db)),
                contextManifestRuntime: Some(ProductContextManifestRuntime(db)))
            this.installed = opened; this.database = db; this.processes = port; this.launcher = instrumented
            this.model = selected; this.observedModel = observed; this.runtimes = registry; this.core = runner; this.template = seed
        } catch (error: Exception) {
            try { match (native) { case Some(value) => let _ = value.close(); case None => () } }
            finally { opened.close() }
            throw error
        }
    }
    func runtime(): AgentThreadRuntime { lifecycleTestRequire(runtimes.acquire(threadId, "workspace:default")) }
    func run(autoRetry!: Bool = false): Result<AgentRunOutcome> {
        let result = core.start(AgentRunRequest(runId, SessionId(threadId.value), template.model, "hello",
            thinking: ThinkingLevel.Off, modelCapabilitiesSnapshot: Some(template.modelCapabilitiesSnapshot),
            autoRetry: autoRetry, budget: ResourceBudget(maxModelRequests: if (autoRetry) { 2 } else { 1 },
                maxWallMillis: 10000, maxIdleMillis: 10000)))
        match (result) { case Result.Err(error) => println("INSTALLED_RESOURCE_RESULT " + error.code); case _ => () }
        result
    }
    func owner(request: ProcessRequest, key: String): ProcessResourceOwner {
        match (request.resourceOwner) {
            case ProcessResourceOwner.ModelAttempt(id, _) => ProcessResourceOwner.ModelAttempt(id, key)
            case _ => throw IllegalStateException("actual installed model Attempt required") }
    }
    func token(claim: agent_host_runtime.HostModelProcessLaunchClaim): CancellationToken {
        lifecycleTestRequire(agent_host_runtime.hostInstalledModelProcessClaimCancellation(claim))
    }
    func open(root: String, owner: ProcessResourceOwner, claim: agent_host_runtime.HostModelProcessLaunchClaim,
        timeout!: Int64 = 5000, maximum!: Int64 = 4096): ProcessChannel {
        lifecycleTestRequire(processes.openClaimedModelChannel(modelLifetimeRequest(root, owner, timeout), claim, maximum))
    }
    func release(owner: ProcessResourceOwner): Unit { modelResourceClose(processes, owner) }
    func releasePending(): Unit {
        launcher.allowClose.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (model.closeModelInputData159().isError() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        lifecycleTestRequire(model.closeModelInputData159())
    }
    func assertNoOperations(): Unit { @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0) }
    func close(): Unit {
        let _ = core.cancel(runId)
        try { releasePending() }
        finally { try { lifecycleTestRequire(processes.close()) } finally { installed.close() } }
    }
}

func installedModelLifetime204(): Unit {
    for (timeout in [0, 3600001]) {
        let f = InstalledModelResourceFixture204(); let root = modelResourceRoot()
        let ordinary = CancellationSource(); let checked = AtomicBool(false)
        try {
            let raw = ProcessResourceOwner.Operation(OperationId("raw-limits"))
            if (timeout == 0) {
                var rejected = false
                try { let _ = modelLifetimeRequest(root, raw, timeout) } catch (_: IllegalArgumentException) { rejected = true }
                @Expect(rejected)
            } else { @Expect(f.processes.openChannel(modelLifetimeRequest(root, raw, timeout), ordinary.token, 4096).error().getOrThrow().code,
                "process.channel_limits_invalid") }
            let guessed = ProcessResourceOwner.ModelAttempt(ModelAttemptId("guessed-lifetime"), "worker")
            @Expect(f.processes.openChannel(modelLifetimeRequest(root, guessed, timeout), ordinary.token, 4096).error().getOrThrow().code,
                "model.process_admission_denied")
            @Expect(!f.processes.hasActiveResource(guessed))
            @Expect(f.processes.openChannel(modelLifetimeRequest(root, raw, 5000), ordinary.token, 67108864).error().getOrThrow().code,
                "process.channel_limits_invalid")
            @Expect(!f.processes.hasActiveResource(raw))
            f.launcher.afterOpen = { request, claim, _ =>
                let owner = f.owner(request, "lifetime-probe")
                let channel = f.open(root, owner, claim, timeout: timeout, maximum: 67108864)
                try {
                    @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n")
                    lifecycleTestRequire(channel.write("ping\n".toArray()))
                    @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 5)), "PONG\n")
                    @Expect(f.processes.hasActiveResource(owner))
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE dispatch_state='dispatch_claimed'"), 1)
                    checked.store(true)
                } finally { f.release(owner) }
            }
            @Expect(f.run().isOk() && checked.load()); @Expect(f.launcher.opened.load(), 1)
            f.assertNoOperations()
        } finally { try { f.close() } finally { ordinary.close(); remove(root, recursive: true) } }
    }
}

func installedModelLargeInput204(): Unit {
    let f = InstalledModelResourceFixture204(); let root = modelResourceRoot(); let checked = AtomicBool(false)
    let total: Int64 = 17825792
    File.writeTo(root + "/resource.py", ("import sys\nprint('READY',flush=True)\nremaining=17825792\n" +
        "while remaining:\n data=sys.stdin.buffer.read(min(65536,remaining))\n if not data: raise SystemExit(2)\n" +
        " if data != b'x'*len(data): raise SystemExit(3)\n remaining-=len(data)\n" +
        "print('EXACT',flush=True)\nsys.stdin.buffer.read()\n").toArray())
    try {
        f.launcher.afterOpen = { request, claim, _ =>
            let owner = f.owner(request, "large-input-probe"); let channel = f.open(root, owner, claim, timeout: 0, maximum: total)
            try {
                @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n")
                let chunk = Array<Byte>(65536, repeat: b'x')
                for (_ in 0..(total / 65536)) { lifecycleTestRequire(channel.write(chunk)) }
                @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "EXACT\n")
                @Expect(channel.write("x".toArray()).error().getOrThrow().code, "process.channel_input_limit")
                checked.store(true)
            } finally { f.release(owner) }
        }
        @Expect(f.run().isOk() && checked.load()); f.assertNoOperations()
    } finally { try { f.close() } finally { remove(root, recursive: true) } }
}

func installedModelResourceIsolation204(): Unit {
    let f = InstalledModelResourceFixture204(); let root = modelResourceRoot()
    let ordinary = CancellationSource(); let checked = AtomicBool(false)
    try {
        f.launcher.afterOpen = { request, claim, _ =>
            let first = f.owner(request, "probe-worker"); let sibling = f.owner(request, "probe-http")
            let attempt = match (request.resourceOwner) { case ProcessResourceOwner.ModelAttempt(id, _) => id
                case _ => throw IllegalStateException("actual installed Attempt required") }
            let operation = ProcessResourceOwner.Operation(OperationId(attempt.value))
            let firstChannel = f.open(root, first, claim); let other = f.open(root, sibling, claim)
            let raw = lifecycleTestRequire(f.processes.openChannel(modelResourceRequest(root, operation), ordinary.token))
            try {
                for (channel in [firstChannel, other, raw]) { @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n") }
                @Expect(f.processes.openClaimedModelChannel(modelResourceRequest(root, first), claim, 4096).error().getOrThrow().code,
                    "process.channel_operation_duplicate")
                lifecycleTestRequire(f.processes.cancel(OperationId(attempt.value))); f.release(operation)
                lifecycleTestRequire(firstChannel.write("ping\n".toArray()))
                @Expect(String.fromUtf8(rawChannelReadCount(firstChannel, ProcessChannelStream.Stdout, 5)), "PONG\n")
                lifecycleTestRequire(f.processes.cancelResource(first)); f.release(first)
                lifecycleTestRequire(other.write("ping\n".toArray()))
                @Expect(String.fromUtf8(rawChannelReadCount(other, ProcessChannelStream.Stdout, 5)), "PONG\n")
                @Expect(!ordinary.token.isCancelled())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE dispatch_state='dispatch_claimed'"), 1)
                f.assertNoOperations()
                checked.store(true)
            } finally { f.release(first); f.release(sibling); f.release(operation) }
        }
        @Expect(f.run().isOk() && checked.load()); @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
        f.assertNoOperations()
    } finally { try { f.close() } finally { ordinary.close(); remove(root, recursive: true) } }
}

func installedModelCancellation204(zeroTimeout!: Bool = false, operatorCancellation!: Bool = false): Unit {
    let f = InstalledModelResourceFixture204(); let root = modelResourceRoot()
    let ready = AtomicBool(false); let checked = AtomicBool(false)
    f.launcher.afterOpen = { request, claim, _ =>
        let owners = if (zeroTimeout) { [f.owner(request, "zero-deadline-probe")] }
            else { [f.owner(request, "run-worker-probe"), f.owner(request, "run-http-probe")] }
        let channels = ArrayList<ProcessChannel>()
        try {
            for (owner in owners) {
                let channel = f.open(root, owner, claim, timeout: if (zeroTimeout) { 0 } else { 5000 },
                    maximum: if (zeroTimeout) { 67108864 } else { 4096 })
                channels.add(channel)
                @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "READY\n")
            }
            let token = f.token(claim); ready.store(true)
            let deadline = MonoTime.now() + Duration.second * 10
            while (!token.isCancelled() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            if (!token.isCancelled()) { throw IllegalStateException("actual installed cancellation was not delivered") }
            @Expect(agent_host_runtime.hostVerifyInstalledModelProcessClaim(claim, owners[0]).isError())
            for (owner in owners) { f.release(owner); @Expect(!f.processes.hasActiveResource(owner)) }
            for (channel in channels) {
                lifecycleTestRequire(channel.close())
                @Expect(channel.write("late\n".toArray()).isError())
            }
            @Expect(f.processes.openClaimedModelChannel(modelLifetimeRequest(root, owners[0], 5000), claim, 4096).isError())
            checked.store(true)
        } finally { for (owner in owners) { f.release(owner) } }
    }
    let running = spawn { f.run() }
    try {
        let deadline = MonoTime.now() + Duration.second * 10
        while (!ready.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        @Assert(ready.load())
        if (operatorCancellation) {
            match (f.installed.product.setPluginEnabled(productRegistryCopyText83(
                f.installed.record.descriptor.copyText(agent_plugin_registry.PluginDescriptorText.Namespace)), false)) {
                case agent_plugin_registry.PluginRegistryResult.Ok(record) => record.close()
                case agent_plugin_registry.PluginRegistryResult.Err(error) =>
                    let code = error.code; error.close(); throw IllegalStateException(code)
            }
        } else { @Expect(f.core.cancel(f.runId).isOk()) }
        @Expect(running.get().isError() && checked.load())
        @Expect(f.launcher.opened.load(), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        @Expect(f.installed.observed().isEmpty())
        f.assertNoOperations()
    } finally {
        let _ = f.core.cancel(f.runId)
        try { let _ = running.get() } finally { try { f.close() } finally { remove(root, recursive: true) } }
    }
}

func installedModelDebtBoundary204(f: InstalledModelResourceFixture204): Unit {
    let runtime = f.runtime(); let active = runtime.activeRun().getOrThrow()
    @Expect(runtime.requireModelBoundary(active.runId, active.epoch).error().getOrThrow().code,
        "runtime.model_resources_unsettled")
    @Expect(runtime.replaceToolSetAtSafeCut(active.runId, active.epoch, active.lane,
        active.lane.toolSet).error().getOrThrow().code, "run.model_lane_cleanup_pending")
}

func installedModelPendingCleanup204(retry!: Bool = false): Unit {
    let f = InstalledModelResourceFixture204(); let checked = AtomicBool(false); let returned = AtomicBool(false)
    f.launcher.allowClose.store(false)
    f.launcher.openingFailure = Some(AgentError(if (retry) { AgentErrorKind.RateLimited } else { AgentErrorKind.Transport },
        "fixture.installed_open_failure", "injected failure after actual installed worker launch", retryable: retry,
        attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderTransportError))))
    try {
        f.launcher.afterOpen = { request, claim, _ =>
            @Expect(agent_host_runtime.hostVerifyInstalledModelProcessClaim(claim, request.resourceOwner).isOk())
            installedModelDebtBoundary204(f); checked.store(true)
        }
        f.observedModel.afterReturn = { =>
            // The model Future is still current. The original factory's
            // withheld cleanup report must retain its real boundary task.
            installedModelDebtBoundary204(f); returned.store(true)
        }
        @Expect(f.run(autoRetry: retry).isError())
        @Expect(checked.load() && returned.load() && f.launcher.closeEntered.load())
        @Expect(f.launcher.opened.load(), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='abandoned'"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='recovery_required'"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        @Expect(f.installed.observed().isEmpty()); f.assertNoOperations()
        // Query only after the actual failure is durably quarantined: closing
        // the port must not itself be the cause that prevents a retry.
        @Expect(f.model.closeModelInputData159().isError())
        f.releasePending()
    } finally { f.close() }
}

class InstalledResourceTaskSlot204 {
    private let lock = Mutex()
    private var task: ?Future<Unit> = None<Future<Unit>>
    func adopt(value: Future<Unit>): Unit {
        lock.lock(); try {
            if (task.isSome()) { throw IllegalStateException("one actual background task required") }
            task = Some(value)
        } finally { lock.unlock() }
    }
    func join(): Unit {
        let selected = { => lock.lock(); try { task } finally { lock.unlock() } }()
        match (selected) { case Some(value) => value.get(); case None => () }
    }
}

func installedModelAckPreservesBackground204(): Unit {
    let f = InstalledModelResourceFixture204(); let release = AtomicBool(false)
    let backgroundFinished = AtomicBool(false); let checked = AtomicBool(false)
    let background = InstalledResourceTaskSlot204()
    try {
        f.launcher.afterOpen = { _, _, _ =>
            let runtime = f.runtime(); let active = runtime.activeRun().getOrThrow()
            let task = spawn {
                try { while (!release.load()) { sleep(Duration.millisecond) } }
                finally { backgroundFinished.store(true) }
            }
            background.adopt(task)
            lifecycleTestRequire(runtime.ownTask("ordinary-installed-background", task,
                expectedRunId: Some(active.runId), expectedEpoch: Some(active.epoch)))
            installedModelDebtBoundary204(f)
        }
        f.observedModel.afterReturn = { =>
            // The complete original installed model helper returned and its
            // own resource tasks acknowledged closure. The ordinary task
            // still runs; no synthetic ACK clears either task collection.
            let runtime = f.runtime(); let active = runtime.activeRun().getOrThrow()
            @Expect(runtime.requireModelBoundary(active.runId, active.epoch).isOk())
            @Expect(!backgroundFinished.load()); checked.store(true); release.store(true)
        }
        @Expect(f.run().isOk() && checked.load())
        @Expect(f.launcher.closeEntered.load()); @Expect(f.launcher.opened.load(), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
        f.assertNoOperations()
    } finally {
        release.store(true)
        try { background.join() } finally { f.close() }
    }
}

func installedModelCancelledPendingCleanup204(): Unit {
    let f = InstalledModelResourceFixture204(); let ready = AtomicBool(false); let checked = AtomicBool(false)
    f.launcher.allowClose.store(false)
    f.launcher.afterOpen = { _, claim, _ =>
        installedModelDebtBoundary204(f)
        let token = f.token(claim); ready.store(true)
        let deadline = MonoTime.now() + Duration.second * 10
        while (!token.isCancelled() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (!token.isCancelled()) { throw IllegalStateException("actual installed Run cancellation was not delivered") }
        checked.store(true)
    }
    let running = spawn { f.run() }
    try {
        let deadline = MonoTime.now() + Duration.second * 5
        while (!ready.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        @Assert(ready.load()); @Expect(f.core.cancel(f.runId).isOk())
        @Expect(running.get().isError() && checked.load())
        @Expect(f.launcher.closeEntered.load()); @Expect(f.launcher.opened.load(), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='recovery_required'"), 1)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        @Expect(f.installed.observed().isEmpty()); f.assertNoOperations()
        @Expect(f.model.closeModelInputData159().isError())
        f.releasePending()
    } finally {
        let _ = f.core.cancel(f.runId)
        try { let _ = running.get() } finally { f.close() }
    }
}
