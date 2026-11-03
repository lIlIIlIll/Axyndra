package agent_product

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import model_provider_runtime.*
import tool_runtime.*
import process4cj as provider_process
import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Test-only OS adapter. The production endpoint uses the shared ProcessChannel
// port; these tests launch only a fixed offline Python fixture. This is not
// evidence for the pending installed-package sandbox or HTTP credential owner.
class ProviderFixturePipe {
    let lock = Mutex()
    var bytes = ArrayList<Byte>()
    var eof = false
    var total: Int64 = 0
    func pump(input: InputStream): Unit {
        let buffer = Array<Byte>(8192, repeat: 0u8)
        try {
            while (true) {
                let count = input.read(buffer)
                if (count == 0) { break }
                lock.lock()
                try { total += count; if (total > 1048576) { throw IllegalStateException("fixture output limit") }
                    bytes.add(all: buffer[..count]) } finally { lock.unlock() }
            }
        } finally { lock.lock(); try { eof = true } finally { lock.unlock() } }
    }
    func take(maximum: Int64, waitMillis: Int64): ProcessChannelRead {
        let deadline = MonoTime.now() + Duration.millisecond * waitMillis
        while (true) {
            lock.lock()
            try {
                if (!bytes.isEmpty() || eof || MonoTime.now() >= deadline) {
                    let all = bytes.toArray(); let count = min(maximum, all.size)
                    bytes = ArrayList<Byte>(); bytes.add(all: all[count..])
                    return ProcessChannelRead(all[..count], eof && bytes.isEmpty())
                }
            } finally { lock.unlock() }
            sleep(Duration.millisecond)
        }
        ProcessChannelRead([], true)
    }
    func count(): Int64 { lock.lock(); try { total } finally { lock.unlock() } }
}
class ProviderFixtureChannel <: ProcessChannel {
    let process: provider_process.ManagedProcess
    let output: ProviderFixturePipe
    let errors: ProviderFixturePipe
    let outputTask: Future<Unit>
    let errorTask: Future<Unit>
    let closed = AtomicBool(false)
    init(script: String, mode: String) {
        let child = provider_process.startProcess(provider_process.ProcessCommand("/usr/bin/python3",
            arguments: [script, mode], maxOutputBytes: 1048576, terminateProcessTree: true))
        let stdout = ProviderFixturePipe(); let stderr = ProviderFixturePipe()
        this.process = child; this.output = stdout; this.errors = stderr
        this.outputTask = spawn { stdout.pump(child.stdout) }
        this.errorTask = spawn { stderr.pump(child.stderr) }
    }
    public func read(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        Result.Ok(match (stream) { case ProcessChannelStream.Stdout => output.take(maxBytes, waitMillis)
            case ProcessChannelStream.Stderr => errors.take(maxBytes, waitMillis) })
    }
    public func write(bytes: Array<Byte>): Result<Unit> {
        try { process.writeStdin(bytes); Result.Ok(()) } catch (_: Exception) {
            Result.Err(AgentError(AgentErrorKind.Transport, "fixture.pipe_closed", "fixture pipe closed")) }
    }
    public func receivedOutputBytes(): Result<Int64> { Result.Ok(output.count() + errors.count()) }
    public func abort(): Result<Unit> { let _ = process.terminate(force: true); Result.Ok(()) }
    public func close(): Result<Unit> {
        if (closed.load()) { return Result.Ok(()) }
        let _ = process.terminate(force: true)
        try { outputTask.get() } finally { try { errorTask.get() } finally { let _ = process.close() } }
        closed.store(true); Result.Ok(())
    }
}
class ProviderFixtureFactory <: ModelProviderChannelFactory {
    let mode: String
    let script: String
    let lock = Mutex()
    var channels = ArrayList<ProviderFixtureChannel>()
    var beforeOpen: (ModelProviderDispatch) -> Unit = { _ => () }
    var openingFailure: ?AgentError = None
    init(mode: String) {
        this.mode = mode
        this.script = match (getVariable("AXYNDRA_MODEL_PROVIDER_PEER")) { case Some(path) => path
            case None => throw IllegalStateException("AXYNDRA_MODEL_PROVIDER_PEER is required; this test may not skip") }
        if (!exists(Path(script))) { throw IllegalStateException("model provider peer is missing") }
    }
    public func open(dispatch: ModelProviderDispatch): Result<ProcessChannel> {
        beforeOpen(dispatch)
        match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (openingFailure) { case Some(error) => return Result.Err(error); case None => () }
        let channel = ProviderFixtureChannel(script, mode)
        lock.lock(); try { channels.add(channel) } finally { lock.unlock() }
        Result.Ok(channel)
    }
    func count(): Int64 { lock.lock(); try { channels.size } finally { lock.unlock() } }
    func allClosed(): Bool { lock.lock(); try {
        for (channel in channels where !channel.closed.load() || channel.process.isAlive()) { return false }; true
    } finally { lock.unlock() } }
}
class ProviderFixtureIds <: IdGenerator {
    public func nextRunId(): RunId { RunId("unused-provider-run") }
    public func nextSessionId(): SessionId { SessionId("unused-provider-session") }
    public func nextOperationId(): OperationId { throw IllegalStateException("model must never create an Operation") }
}
class ProviderRecordingGate <: ModelProviderDispatchGate {
    let actual: ProductModelProviderDispatchGate
    var request: ?ModelRequest = None
    var snapshot = ""
    init(actual: ProductModelProviderDispatchGate) { this.actual = actual }
    public func open(request: ModelRequest, binding: ModelProviderBinding, snapshot: String): Result<ModelProviderDispatch> {
        this.request = Some(request); this.snapshot = snapshot
        actual.open(request, binding, snapshot)
    }
}
// Test orchestration only: never synchronously wait for a Run's terminal
// state from inside that Run's own model Future. The test thread requests the
// actual cancellation after the real resource signals readiness, then joins
// both the Core result and the callback's cleanup acknowledgement.
class ModelExternalCancellationProbe {
    private let ready = AtomicBool(false)
    private let callbackFinished = AtomicBool(false)
    func awaitCancellation(dispatch: ModelProviderDispatch): Unit {
        ready.store(true)
        let deadline = MonoTime.now() + Duration.second * 10
        while (!dispatch.cancellation.isCancelled() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (!dispatch.cancellation.isCancelled()) { throw IllegalStateException("actual model cancellation was not delivered") }
    }
    func run(fixture: ModelProviderProductFixture, operatorCancellation!: Bool = false): Result<AgentRunOutcome> {
        let callback = fixture.factory.beforeOpen
        fixture.factory.beforeOpen = { dispatch =>
            try { callback(dispatch) } finally { callbackFinished.store(true) }
        }
        let pending = spawn { fixture.run() }
        try {
            let deadline = MonoTime.now() + Duration.second * 10
            while (!ready.load() && !callbackFinished.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            if (!ready.load()) { throw IllegalStateException("actual model resource did not reach the cancellation boundary") }
            if (operatorCancellation) { fixture.authorized.store(false); let _ = fixture.grantLifetime.cancel() }
            else { lifecycleTestRequire(fixture.core.cancel(RunId("provider-run"))) }
            let result = pending.get()
            let joined = MonoTime.now() + Duration.second * 5
            while (!callbackFinished.load() && MonoTime.now() < joined) { sleep(Duration.millisecond * 5) }
            if (!callbackFinished.load()) { throw IllegalStateException("model callback cleanup remains unjoined") }
            result
        } finally {
            let _ = fixture.core.cancel(RunId("provider-run"))
            let _ = pending.get()
        }
    }
}

class ModelProviderProductFixture {
    let root: String
    let database: SqliteDatabase
    let reader: SqliteModelProviderDispatchReader
    let gate: ProviderRecordingGate
    let factory: ProviderFixtureFactory
    let endpoint: NativeModelProviderEndpoint
    let port: PluginModelPort
    let core: AgentCore
    let capabilities: ModelExecutionCapabilitiesSnapshot
    let binding: ModelProviderBinding
    let authorized: AtomicBool
    let grantLifetime: CancellationSource
    let runtimes: ThreadRuntimeRegistry
    init(mode!: String = "success", thinkingCapabilities!: ?ThinkingCapabilities = None) {
        let directory = Directory.createTemp("/tmp").toString()
        let db = SqliteDatabase(directory + "/provider.db")
        let allowed = AtomicBool(true)
        let lifetime = CancellationSource()
        let thinking = match (thinkingCapabilities) {
            case Some(value) => value
            case None => ThinkingCapabilities(ThinkingControlMode.NoThinking)
        }
        let caps = ModelExecutionCapabilitiesSnapshot("fixture-model", thinking, 4096)
        let binding = ModelProviderBinding("fixture-provider", "sha256:" + modelPolicySha256Text("package"),
            modelPolicySha256Text("config"), "fixture-instance", "fixture", "fixture-model", "wire-model", caps)
        let registry = SqliteThreadRuntimeRegistry(db,
            ContextProjector("model-provider-contract", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
        let reader = SqliteModelProviderDispatchReader(db)
        let gate = ProviderRecordingGate(ProductModelProviderDispatchGate(reader, registry, binding, { =>
            if (allowed.load()) { Result.Ok(()) } else { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "fixture.provider_grant_revoked", "operator model grant revoked")) } }, lifetime.token))
        let factory = ProviderFixtureFactory(mode)
        let endpoint = NativeModelProviderEndpoint(factory)
        let port = PluginModelPort(binding, gate, endpoint)
        let catalog = ToolCatalog(); let operations = DurableOperationStore(db)
        this.root = directory; this.database = db; this.reader = reader; this.gate = gate
        this.factory = factory; this.endpoint = endpoint; this.port = port; this.binding = binding
        this.capabilities = caps; this.authorized = allowed; this.grantLifetime = lifetime
        this.runtimes = registry
        this.core = AgentCore(port, SqliteRunRepository(db),
            ToolPipeline(catalog, operations, SqliteAuditRepository(db), ProviderFixtureIds()), catalog,
            threadRuntimes: Some(registry), operationRuntime: Some(operations),
            modelDecisionRuntime: Some(SqliteModelDecisionStore(db)),
            contextManifestRuntime: Some(ProductContextManifestRuntime(db)))
    }
    func run(autoRetry!: Bool = false): Result<AgentRunOutcome> {
        core.start(AgentRunRequest(RunId("provider-run"), SessionId("provider-thread"), "fixture-model", "hello",
            thinking: ThinkingLevel.Off, modelCapabilitiesSnapshot: Some(capabilities), autoRetry: autoRetry,
            budget: ResourceBudget(maxModelRequests: if (autoRetry) { 2 } else { 1 }, maxWallMillis: 10000, maxIdleMillis: 10000)))
    }
    func directRequest(): ModelRequest { ModelRequest("fixture-model", [ModelMessage(ModelRole.User,
        [ModelBlock(ModelBlockKind.Text, text: "hello")])], thinking: ThinkingLevel.Off, requestId: "unclaimed-request") }
    func close(): Unit {
        let _ = core.cancel(RunId("provider-run"))
        let _ = endpoint.retryCleanup()
        if (!factory.allClosed()) { throw IllegalStateException("provider fixture process remains owned") }
        grantLifetime.close(); database.close(); remove(root, recursive: true)
    }
}

@Test
class ModelProviderDispatchTests {
    @TestCase
    func observedContinuationStillRejectsChangedBytesDigestAndCurrentOwnership(): Unit {
        let fixture = ModelProviderProductFixture()
        try {
            let db = fixture.database
            fixture.factory.beforeOpen = { dispatch =>
                let row = db.query("SELECT payload,digest,active_attempt_id FROM run_continuations WHERE run_id='provider-run'")[0]
                let payload = row.required(0); let digest = row.required(1); let active = row.required(2)
                let workspace = db.query("SELECT workspace_id FROM threads WHERE id='provider-thread'")[0].required(0)
                let attempt = sqliteText(dispatch.attemptId.value)
                let started = db.query("SELECT dispatch_started_at_millis FROM model_attempts WHERE id=" + attempt)[0].required(0)
                let snapshot = db.query("SELECT transcript_snapshot FROM model_attempts WHERE id=" + attempt)[0].required(0)
                @Expect(dispatch.check().isOk()); @Expect(dispatch.check().isOk())
                let changes = [
                    ("UPDATE run_continuations SET payload=" + sqliteText(payload + "x") + " WHERE run_id='provider-run'",
                        "UPDATE run_continuations SET payload=" + sqliteText(payload) + " WHERE run_id='provider-run'"),
                    ("UPDATE run_continuations SET payload=" + sqliteText(payload + String.fromUtf8([UInt8(0)]) + "x") + " WHERE run_id='provider-run'",
                        "UPDATE run_continuations SET payload=" + sqliteText(payload) + " WHERE run_id='provider-run'"),
                    ("UPDATE model_attempts SET transcript_snapshot=transcript_snapshot || CAST(X'0078' AS TEXT) WHERE id=" + attempt,
                        "UPDATE model_attempts SET transcript_snapshot=" + sqliteText(snapshot) + " WHERE id=" + attempt),
                    ("UPDATE run_continuations SET digest='bad' WHERE run_id='provider-run'",
                        "UPDATE run_continuations SET digest=" + sqliteText(digest) + " WHERE run_id='provider-run'"),
                    ("UPDATE run_continuations SET active_attempt_id=NULL WHERE run_id='provider-run'",
                        "UPDATE run_continuations SET active_attempt_id=" + sqliteText(active) + " WHERE run_id='provider-run'"),
                    ("UPDATE model_attempts SET replay_barrier='cancelled' WHERE id=" + attempt,
                        "UPDATE model_attempts SET replay_barrier='none' WHERE id=" + attempt),
                    ("UPDATE model_attempts SET dispatch_started_at_millis=NULL WHERE id=" + attempt,
                        "UPDATE model_attempts SET dispatch_started_at_millis=" + started + " WHERE id=" + attempt),
                    ("UPDATE threads SET workspace_id='changed-workspace' WHERE id='provider-thread'",
                        "UPDATE threads SET workspace_id=" + sqliteText(workspace) + " WHERE id='provider-thread'")
                ]
                for ((mutate, restore) in changes) {
                    db.execute(mutate)
                    try { @Expect(dispatch.check().isError()) } finally { db.execute(restore) }
                    @Expect(dispatch.check().isOk())
                }
                // An array element can change despite the enclosing let.
                let request = fixture.gate.request.getOrThrow()
                let original = request.messages[0]
                request.messages[0] = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "mutated")])
                try { @Expect(dispatch.check().isError()) } finally { request.messages[0] = original }
                @Expect(dispatch.check().isOk())
            }
            @Expect(fixture.run().isOk())
            @Expect(fixture.factory.count(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func observedContinuationRevalidatesLegitimatePhaseChangeAndRejectsSealedWrongPhase(): Unit {
        let fixture = ModelProviderProductFixture()
        try {
            let db = fixture.database
            fixture.factory.beforeOpen = { dispatch =>
                let row = db.query("SELECT payload,digest FROM run_continuations WHERE run_id='provider-run'")[0]
                let original = row.required(0); let originalDigest = row.required(1)
                @Expect(dispatch.check().isOk())
                try {
                    for ((phase, accepted) in [("model_settling", true), ("accepted", false), ("model_effect_pending", true)]) {
                        let fields = ArrayList<ValueField>()
                        for (field in decodeStoredValue(original).fields where field.name != "digest") {
                            fields.add(if (field.name == "phase") { ValueField("phase", textValue(phase)) } else { field })
                        }
                        let digest = modelPolicySha256Text(encodeStoredValue(objectValue(fields.toArray())))
                        fields.add(ValueField("digest", textValue(digest)))
                        let payload = encodeStoredValue(objectValue(fields.toArray()))
                        // Valid Store seal does not by itself prove an active model effect.
                        @Expect(decodeDurableRunContinuation(payload).digest, digest)
                        db.execute("UPDATE run_continuations SET payload=" + sqliteText(payload) + ",digest=" +
                            sqliteText(digest) + " WHERE run_id='provider-run'")
                        @Expect(dispatch.check().isOk(), accepted)
                        @Expect(dispatch.check().isOk(), accepted)
                    }
                } finally {
                    db.execute("UPDATE run_continuations SET payload=" + sqliteText(original) + ",digest=" +
                        sqliteText(originalDigest) + " WHERE run_id='provider-run'")
                }
                @Expect(dispatch.check().isOk())
            }
            @Expect(fixture.run().isOk())
            @Expect(fixture.factory.count(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func snapshotIsPureAndUnclaimedRequestCannotLaunch(): Unit {
        let fixture = ModelProviderProductFixture()
        try {
            let input = fixture.directRequest()
            let snapshot = fixture.port.transcriptSnapshot(input).getOrThrow()
            @Expect(fixture.port.validateTranscriptSnapshot(snapshot))
            @Expect(fixture.factory.count() == 0)
            @Expect(fixture.port.execute(input, { _ => () }).isError())
            @Expect(fixture.factory.count() == 0 && fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0)
            @Expect(MissingModelProviderPort().execute(input, { _ => () }).error().getOrThrow().code == "model.provider_plugin_missing")
            @Expect(!fixture.port.validateTranscriptSnapshot("legacy-provider-transcript"))
        } finally { fixture.close() }
    }
    @TestCase
    func actualProcessRetainsUniqueAttemptDecisionAndTypedUsage(): Unit {
        let fixture = ModelProviderProductFixture()
        try {
            let result = fixture.run()
            @Expect(result.isOk())
            @Expect(fixture.factory.count() == 1 && fixture.factory.allClosed())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL") == 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0)
            let decisions = fixture.database.query("SELECT d.id,a.id,a.provider_request_id,a.lifecycle " +
                "FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
                "JOIN runs r ON r.id=a.run_id WHERE r.id='provider-run' AND r.thread_id='provider-thread'")
            @Expect(decisions.size, 1)
            let row = decisions[0]
            let durable = SqliteModelDecisionStore(fixture.database).loadDecision(ModelDecisionId(row.required(0)))
            let request = fixture.gate.request.getOrThrow()
            @Expect(durable.decision.attemptId.value == row.required(1) && row.required(2) == request.requestId)
            @Expect(row.required(3) == "completed" && durable.canonicalCommittedAtMillis.isSome())
            let usage = durable.usage.getOrThrow()
            @Expect(usage.inputTokens == 11 && usage.outputTokens == 3 && usage.reasoningTokens == 1 &&
                usage.cacheReadTokens == 4 && usage.cacheWriteTokens == 2)
            @Expect(usage.source == ModelUsageSource.ProviderStreamFinal && usage.costMicros.isNone())
            let evidence = usage.evidence.getOrThrow()
            @Expect(evidence.protocol == "fixture" && evidence.eventKind == "usage_final" &&
                evidence.providerResponseId == "peer-response")
            @Expect(fixture.port.execute(request, { _ => () }).isError())
            @Expect(fixture.factory.count() == 1)
        } finally { fixture.close() }
    }
    @TestCase
    func protocolFailuresNeverCommitPartialDecisionOrInventRetry(): Unit {
        for (mode in ["partial_eof", "wrong_identity", "invalid_usage", "duplicate_sequence", "reply_drift", "oversize"]) {
            let fixture = ModelProviderProductFixture(mode: mode)
            try {
                @Expect(fixture.run().isError())
                @Expect(fixture.factory.count() == 1 && fixture.factory.allClosed())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0)
                if (mode == "partial_eof") {
                    // A failed stream has no Decision. Re-read its typed accounting
                    // event from SQLite, preserving the observed bill without inventing success.
                    let durableEvents = SqliteRunRepository(fixture.database).events(RunId("provider-run"), 0).value().getOrThrow().events
                    var attemptEvents: Int64 = 0
                    for (event in durableEvents) {
                        match (event.payload) {
                            case AgentEventPayload.ModelRequestAttemptCompleted(attempt) =>
                                attemptEvents++
                                @Expect(event.runId.value == "provider-run")
                                @Expect(attempt.requestId.value == fixture.gate.request.getOrThrow().requestId)
                                @Expect(attempt.attempt == 1 && attempt.outcome == ModelRequestOutcome.Failed)
                                @Expect(attempt.errorCode == "model.provider_process_eof")
                                let usage = attempt.usage.getOrThrow()
                                @Expect(usage.inputTokens == 11 && usage.outputTokens == 3 && usage.reasoningTokens == 1 &&
                                    usage.cacheReadTokens == 4 && usage.cacheWriteTokens == 2)
                                @Expect(usage.source == ModelUsageSource.ProviderStreamFinal && usage.costMicros.isNone())
                                let evidence = usage.evidence.getOrThrow()
                                @Expect(evidence.protocol == "fixture" && evidence.eventKind == "usage_final" &&
                                    evidence.providerResponseId == "peer-response")
                            case _ => ()
                        }
                    }
                    @Expect(attemptEvents, 1)
                }
            } finally { fixture.close() }
        }
    }
    @TestCase
    func currentGrantAndEveryDurableOwnerFieldAreRequiredBeforeIo(): Unit {
        let fixture = ModelProviderProductFixture()
        try {
            let db = fixture.database; let gate = fixture.gate; let reader = fixture.reader
            fixture.factory.beforeOpen = { dispatch =>
                let request = gate.request.getOrThrow(); let snapshot = gate.snapshot
                let attempt = sqliteText(dispatch.attemptId.value)
                let changes = [
                    ("UPDATE model_attempts SET dispatch_state='prepared' WHERE id=" + attempt,
                        "UPDATE model_attempts SET dispatch_state='dispatch_claimed' WHERE id=" + attempt),
                    ("UPDATE runs SET epoch=epoch+1 WHERE id='provider-run'", "UPDATE runs SET epoch=epoch-1 WHERE id='provider-run'"),
                    ("UPDATE model_attempts SET semantic_request_digest='bad' WHERE id=" + attempt,
                        "UPDATE model_attempts SET semantic_request_digest=" + sqliteText(dispatch.inputDigest) + " WHERE id=" + attempt),
                    ("UPDATE model_attempts SET transcript_snapshot='legacy' WHERE id=" + attempt,
                        "UPDATE model_attempts SET transcript_snapshot=" + sqliteText(snapshot) + " WHERE id=" + attempt)
                ]
                for ((mutate, restore) in changes) {
                    db.execute(mutate)
                    try { @Expect(dispatch.check().isError()) } finally { db.execute(restore) }
                    @Expect(reader.read(request, snapshot).isOk())
                }
                fixture.authorized.store(false)
            }
            @Expect(fixture.run().isError())
            @Expect(fixture.factory.count() == 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0)
        } finally { fixture.close() }
    }
    @TestCase
    func actualMidStreamCancelReapsOnlyItsProcessAndCannotReplay(): Unit {
        for (operatorRevocation in [false, true]) {
            let fixture = ModelProviderProductFixture(mode: "hang")
            let pending = spawn { fixture.run() }
            try {
                let deadline = MonoTime.now() + Duration.second * 5
                while (fixture.factory.count() == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                @Expect(fixture.factory.count() == 1)
                if (operatorRevocation) {
                    fixture.authorized.store(false); let _ = fixture.grantLifetime.cancel()
                } else { @Expect(fixture.core.cancel(RunId("provider-run")).isOk()) }
                @Expect(pending.get().isError())
                @Expect(fixture.factory.allClosed())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0)
            } finally { try { let _ = fixture.core.cancel(RunId("provider-run")); let _ = pending.get() }
                finally { fixture.close() } }
        }
    }
    @TestCase
    func unknownUsageRemainsUnknownInsteadOfBeingInventedFinal(): Unit {
        let fixture = ModelProviderProductFixture(mode: "unknown_usage")
        try {
            @Expect(fixture.run().isOk())
            let rows = fixture.database.query("SELECT payload FROM model_decision_usage")
            @Expect(rows.size == 1)
            // The existing Store codec, not a JSON guess, is the evidence source.
            let value = decodeStoredValue(rows[0].required(0))
            @Expect(value.field("source").getOrThrow().text == "unknown")
            @Expect(fixture.factory.allClosed())
        } finally { fixture.close() }
    }
}
