package agent_app

import agent_core.*
import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as AcpPhysicalPayment113
import process4cj as acp_process113
import yjson.JsonNode
import agent_product.*
import agent_rpc.*
import agent_runtime.*
import process4cj as frontend_process95
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import tool_runtime.*
import yjson.*
import yjson_support.*

@When[os == "Linux"]
foreign func dup(fd: Int32): Int32
@When[os == "Linux"]
foreign func dup2(original: Int32, replacement: Int32): Int32
@When[os == "Linux"]
foreign func close(fd: Int32): Int32

// Linux fixture only: duplicate the original runner descriptor, redirect the
// REAL inherited fd1 to the supervisor's separate data pipe, then restore it.
// RpcOutput still calls the unmodified SDK println/getStdOut.flush. This is
// not a callback writer and the unit reporter retains its original OS pipe.
@When[os == "Linux"]
private func withActualStdoutPipe95(action: () -> Unit): Unit {
    let descriptor = Int32(Int64.parse(getVariable("AXYNDRA_FRONTEND_DATA_FD95").getOrThrow()))
    if (descriptor < 3) { throw IllegalStateException("real data pipe descriptor missing") }
    getStdOut().flush()
    let reporter = unsafe { dup(1) }
    if (reporter < 0) { throw IllegalStateException("cannot preserve actual unit stdout descriptor") }
    if (unsafe { dup2(descriptor, 1) } != 1) {
        let _ = unsafe { close(reporter) }; throw IllegalStateException("cannot install actual inherited stdout pipe") }
    let _ = unsafe { close(descriptor) }
    try { action() }
    finally {
        try { getStdOut().flush() } catch (_: Exception) { () }
        if (unsafe { dup2(reporter, 1) } != 1) { throw IllegalStateException("cannot restore actual unit reporter stdout") }
        let _ = unsafe { close(reporter) }
    }
}

// This leaf uses the existing actual self-child cjpm invocation contract.
// Python owns only the OS pipe reader. The child runs the original Main
// writer/flush and controller, real Product/Core/SQLite, and original bank.
// There is no replacement output callback or synthetic Operation/Receipt.
@When[os == "Linux"]
private class FrontendState95 {
    var source: ?OwnedFailureRunPublication113 = Option<OwnedFailureRunPublication113>.None
    var ordinaryCalls: Int64 = 0
    let borrowed = AtomicBool(false)
    let releaseBorrow = AtomicBool(false)
}
@When[os == "Linux"]
private class FrontendObserver95 <: ToolExecutor & PreparedPostCanonicalToolObserver & PaidPreparedPostCanonicalToolObserver113 {
    let executed = AtomicInt64(0)
    let observed = AtomicInt64(0)
    let committed = AtomicBool(false)
    private let metadata: LogicalJsonOwnerReservation
    private let root: String
    private let large: Bool
    private let rpc: Bool
    init(metadata: LogicalJsonOwnerReservation, root: String, large: Bool, rpc: Bool) {
        this.metadata = metadata; this.root = root; this.large = large; this.rpc = rpc
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executed.fetchAdd(1)
        let owner = reserveProductControlMetadata113(65536)
        try {
            owner.ensureRetainedPeak(65536)
            Result.Ok(ToolResult(prepared.call.callId, textValue("original canonical success95"),
                payloadLease: Some(ToolResultPayloadLease({ => owner.close() }))))
        } catch (failure: Exception) { owner.close(); throw failure }
    }
    public func afterPreparedResultPersisted(context: ToolInvocationContext,
        plan: NormalizedOperationPlan, result: ToolResult): Result<Unit> {
        throw IllegalStateException("paid observer must not fall back to old callback")
    }
    public func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        plan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        observed.fetchAdd(1)
        @Expect(plan.toolName, "frontend_original95")
        @Expect(result.isError, false); @Expect(result.receiptId != "")
        let producer = reserveProductControlMetadata113(65536)
        try {
            // Exact fixed large fixture is paid before its Array/String and
            // full-eight-field DTO/attachments exist; no new owner bank.
            producer.ensureRetainedPeak(4194304)
            let message = "original failure雪🙂\u{0}\n" +
                if (large) { String.fromUtf8(Array<Byte>(131072, repeat: b'x')) } else { "tail95" }
            let error = AgentError(AgentErrorKind.Internal, "frontend.error雪\u{0}", message,
                retryable: true, fallbackAllowed: true,
                fields: [ErrorField("duplicate", "first"), ErrorField("duplicate", "second雪\u{0}")],
                attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError,
                    diagnostics: AttemptFailureDiagnostics(elapsedMillis: 11, softDeadlineMillis: 12,
                        hardDeadlineMillis: 13, enteredCompletionGrace: true,
                        lastProgressKind: AttemptProgressKind.ToolArgumentProgress, lastProgressAgeMillis: 14,
                        providerTerminalObserved: true, openContentBlockCount: 15,
                        toolCallsStarted: 16, toolCallsCompleted: 17))),
                observation: Some(OperationObservation("{\"original\":\"雪\\u0000🙂\"}")))
            let answer = captureOwnedFailureData113<Unit>(error, { _ => producer.deriveRetainedLease() })
            if (rpc) {
                metadata.ensureRetainedPeak(65536)
                File.writeTo(root + "/canonical-ready95", "actual canonical receipt accepted\n".toArray())
                committed.store(true)
                let until = MonoTime.now() + Duration.second * 10
                while (!exists(Path(root + "/release-observer95")) && MonoTime.now() < until) {
                    sleep(Duration.millisecond * 5)
                }
                if (!exists(Path(root + "/release-observer95"))) {
                    throw IllegalStateException("real pipe supervisor did not release original observer") }
            }
            Some(answer)
        } finally { producer.close() }
    }
}
@When[os == "Linux"]
private class FrontendOrdinary95 <: OwnedAgentEventSink {
    public func emit(event: OwnedAgentEvent): Result<Unit> {
        match (event.withEvent(65536, { _ => Result<Unit>.Ok(()) })) {
            case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        event.closeAfterEventRetirement()
    }
}
@When[os == "Linux"]
private class ActualFrontendFixture95 {
    let product: ProductRuntime
    let metadata: LogicalJsonOwnerReservation
    let observer: FrontendObserver95
    let state: FrontendState95
    let session: ApplicationSession
    let cli: ActualCliFailureFacade95
    init(root: String, large: Bool, rpc!: Bool = false) {
        // This original process-wide Native reservation funds the fixture,
        // pointer cells and facade BEFORE construction and subscriptions.
        let paid = reserveProductControlMetadata113(65536)
        paid.ensureRetainedPeak(65536)
        let opened = openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        let actual = FrontendObserver95(paid, root, large, rpc)
        @Expect(opened.registerTool(ToolDescriptor(ModelToolDefinition("frontend_original95",
            "Real frontend pipe witness", objectValue([ValueField("type", textValue("object")),
                ValueField("properties", objectValue([]))])), Capability(CapabilityKind.WorkspaceRead),
            implementationVersion: "actual95", implementationFingerprint: "actual95"), actual).isOk())
        let app = opened.applicationSession(sessionId: Some(SessionId("frontend-io95")))
        let facade = ActualCliFailureFacade95(paid, true)
        facade.bindSession(app)
        if (!rpc) { app.subscribeOwned({ _ => () }, FrontendOrdinary95(), failures: Some(facade)) }
        this.product = opened; this.metadata = paid
        this.observer = actual; this.state = FrontendState95(); this.session = app; this.cli = facade
    }
    func enqueue(): Unit {
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("frontend-call95", "frontend_original95", objectValue([]))
    }
    func start(): AgentError {
        enqueue()
        let marker = session.submit("Run the original paid checkpoint observer once95.").error().getOrThrow()
        @Expect(session.hasOwnedCheckpointFailure113(marker))
        // Read exact identity in the genuine false handoff. No new ownership
        // or reconstructed Source: only this paid pointer cell survives.
        @Expect(!session.admitOwnedCheckpointFailure113(marker, { value =>
            match (value) {
                case OwnedAgentRunResult113.Failed(source) =>
                    source.withError({ _, fund => fund(32768) }).value().getOrThrow()
                    state.source = Some(source)
                case _ => throw IllegalStateException("actual fixture did not reach its full publication") }
            false }))
        marker
    }
    func canonical(): Unit {
        @Expect(observer.executed.load(), 1); @Expect(observer.observed.load(), 1)
        let (committed, completed, unknown, results) = productFixtureCanonicalCounts95(product, metadata)
        @Expect(committed, 1); @Expect(completed, 1); @Expect(unknown, 0); @Expect(results, 1)
    }
    func record(root: String, phase: String, marker: AgentError): Unit {
        metadata.ensureRetainedPeak(131072)
        let (committed, completed, unknown, results) = productFixtureCanonicalCounts95(product, metadata)
        let (owners, bytes) = productControlMetadataUsage113()
        File.writeTo(root + "/" + phase + ".json", encodeAgentValue(objectValue([
            ValueField("phase", textValue(phase)), ValueField("source_ack", boolValue(state.source.getOrThrow().isAcknowledged())),
            ValueField("marker_in_slot", boolValue(session.hasOwnedCheckpointFailure113(marker))),
            ValueField("cli_pending", boolValue(cli.hasPending())), ValueField("executed", integerValue(observer.executed.load())),
            ValueField("observed", integerValue(observer.observed.load())),
            ValueField("committed_operations", integerValue(committed)),
            ValueField("completed_receipts", integerValue(completed)),
            ValueField("unknown_receipts", integerValue(unknown)),
            ValueField("canonical_items", integerValue(results)),
            ValueField("owners", integerValue(owners)),
            ValueField("bytes", integerValue(bytes))])).toArray())
    }
}
@When[os == "Linux"]
private func actualCliChild95(root: String, mode: String): Unit {
    let f = ActualFrontendFixture95(root, mode == "partial")
    let marker = f.start(); let source = f.state.source.getOrThrow()
    f.canonical(); f.record(root, "before", marker)
    if (mode == "pressure") {
        let pressure = ArrayList<LogicalJsonOwnerReservation>()
        try {
            try { while (true) { pressure.add(reserveProductControlMetadata113(65536)) } }
            catch (_: LogicalJsonPayloadError) { () }
            // This actual same-bank invoice is valid but cannot grow under
            // current aggregate pressure. False preserves the ORIGINAL slot.
            @Expect(!f.session.admitOwnedCheckpointFailure113(marker, { value =>
                match (value) {
                    case OwnedAgentRunResult113.Failed(actual) => actual.withError({ _, fund => fund(33554432) }).isOk()
                    case _ => false } }))
            @Expect(f.session.hasOwnedCheckpointFailure113(marker)); @Expect(!source.isAcknowledged())
            f.canonical(); f.record(root, "pressure-refused", marker)
        } finally { for (owner in pressure) { owner.close() }; pressure.clear() }
    }
    if (mode == "borrow") {
        let loan = spawn {
            source.withError({ _, fund =>
                fund(4096).value().getOrThrow(); f.state.borrowed.store(true)
                let until = MonoTime.now() + Duration.second * 5
                while (!f.state.releaseBorrow.load() && MonoTime.now() < until) { sleep(Duration.millisecond * 5) }
                if (!f.state.releaseBorrow.load()) { throw IllegalStateException("actual original error loan did not retire") }
                Result<Unit>.Ok(())
            }).value().getOrThrow()
        }
        try {
            let until = MonoTime.now() + Duration.second * 5
            while (!f.state.borrowed.load() && MonoTime.now() < until) { sleep(Duration.millisecond * 5) }
            @Expect(f.state.borrowed.load())
            @Expect(f.cli.consumeCaller(f.session, marker)); @Expect(!source.isAcknowledged()); @Expect(f.cli.hasPending())
            f.record(root, "borrow-held", marker)
        } finally { f.state.releaseBorrow.store(true); loan.get() }
        @Expect(f.cli.finishMode(0), 0)
    } else {
        @Expect(f.cli.consumeCaller(f.session, marker))
        if (mode == "partial") {
            @Expect(!source.isAcknowledged()); @Expect(f.cli.hasPending()); @Expect(f.cli.finishMode(0), 1)
            f.record(root, "partial-retained", marker)
            // Second progress is an ACK poll, not a repeated writer offer.
            @Expect(f.cli.finishMode(0), 1); @Expect(!source.isAcknowledged()); f.canonical()
            f.record(root, "done", marker)
            return // retained Root/controller is deliberately not refunded
        }
    }
    @Expect(source.isAcknowledged()); @Expect(!f.cli.hasPending()); f.canonical()
    f.record(root, "retired", marker)
    let charged = productControlMetadataUsage113()
    @Expect(f.cli.finishMode(0), 0); expectActualUsageFields163_2(productControlMetadataUsage113(), charged)
    @Expect(!f.cli.consumeCaller(f.session, marker)); f.canonical(); f.record(root, "done", marker)
    f.product.close().value().getOrThrow()
    // The subscribed controller still retains Root metadata; do NOT close it.
}
@When[os == "Linux"]
private func actualRpcChild95(root: String, once: Bool): Unit {
    let f = ActualFrontendFixture95(root, true, rpc: true)
    let controller = RpcFrontendShutdown113(f.metadata)
    let actual = controller.install113(f.product)
    controller.startStartup113()
    let until = MonoTime.now() + Duration.second * 5
    while (!controller.startupReturned113() && MonoTime.now() < until) {
        controller.collectFinishedTasks113(); sleep(Duration.millisecond * 5) }
    @Expect(controller.startupReturned113())
    f.enqueue()
    let command = spawn { controller.server113().handle("{\"id\":\"physical95\",\"type\":\"prompt\",\"message\":\"original full paid failure95\"}") }
    if (once) {
        @Expect(command.get().contains("\"success\":true"))
        File.writeTo(root + "/once-returned95", "actual handle returned\n".toArray())
    }
    let entered = MonoTime.now() + Duration.second * 10
    while (!f.observer.committed.load() && MonoTime.now() < entered) { sleep(Duration.millisecond * 5) }
    @Expect(f.observer.committed.load())
    while (!exists(Path(root + "/release-observer95")) && MonoTime.now() < entered) { sleep(Duration.millisecond * 5) }
    @Expect(exists(Path(root + "/release-observer95")))
    sleep(Duration.millisecond * 200)
    // For EOF this is the ACTUAL inherited fd0 after its real pipe peer closed.
    // Once is instead authorized by the actual command.get() above.
    if (!once) { @Expect(PollingJsonlInput().poll(0).eof) }
    let (heldOwners, heldBytes) = productControlMetadataUsage113()
    let started = MonoTime.now()
    @Expect(controller.finishObservedExit113(0, true), 1)
    let elapsed = MonoTime.now() - started
    @Expect(elapsed >= Duration.millisecond * RPC_FRONTEND_OBSERVED_EXIT_MILLIS113)
    @Expect(elapsed < Duration.millisecond * 6500)
    @Expect(!controller.server113().collectRunWorkerRetirement113())
    let (owners, bytes) = productControlMetadataUsage113()
    @Expect(bytes >= heldBytes)
    f.metadata.ensureRetainedPeak(131072)
    File.writeTo(root + "/window-expired.json", encodeAgentValue(objectValue([
        ValueField("mono_lower_bound_millis", integerValue(5000)), ValueField("mono_upper_bound_millis", integerValue(6500)),
        ValueField("bytes", integerValue(bytes)), ValueField("held_bytes", integerValue(heldBytes)),
        ValueField("held_owners", integerValue(heldOwners)), ValueField("owners", integerValue(owners)),
        ValueField("executed", integerValue(f.observer.executed.load())), ValueField("observed", integerValue(f.observer.observed.load()))])).toArray())
    // The peer now drains the SAME OS pipe. Only real producer/Future return
    // and exact frame/alias ACK may make these actual server queries true.
    let drained = MonoTime.now() + Duration.second * 10
    while (MonoTime.now() < drained) {
        controller.server113().collectOwnedCheckpointFailures113()
        controller.collectFinishedTasks113()
        if (controller.server113().collectFrontendOutputRetirement113() &&
            controller.server113().collectRunWorkerRetirement113()) { break }
        sleep(Duration.millisecond * 5)
    }
    @Expect(controller.server113().collectFrontendOutputRetirement113())
    @Expect(controller.server113().collectRunWorkerRetirement113())
    if (!once) { @Expect(command.get().contains("\"success\":true")) }
    f.canonical()
    File.writeTo(root + "/rpc-done.json", "{\"workers_retired\":true,\"output_retired\":true,\"executed\":1,\"observed\":1}".toArray())
    f.product.close().value().getOrThrow()
}
@When[os == "Linux"]
private class FrontendPipeDrain95 {
    var count: Int64 = 0
    func drain(input: InputStream): Unit {
        let buffer = Array<Byte>(8192, repeat: 0u8)
        while (true) {
            let n = input.read(buffer); if (n == 0) { return }
            count += n; if (count > 1048576) { throw IllegalStateException("real supervisor report exceeded one MiB") }
        }
    }
}
@When[os == "Linux"]
private func frontendRealPipe95(caseName: String, mode: String): Unit {
    match (getVariable("AXYNDRA_FRONTEND_IO_CHILD95")) {
        case Some(root) =>
            withActualStdoutPipe95({ =>
                if (mode.startsWith("rpc-")) { actualRpcChild95(root, mode == "rpc-once") }
                else { actualCliChild95(root, mode) }
            }); return
        case None => () }
    let paid = reserveProductControlMetadata113(65536)
    try { frontendRealPipeParentFrame95(caseName, mode, paid) }
    finally { paid.close() } // Whole process/drain/helper frame has returned.
}
@When[os == "Linux"]
private func frontendRealPipeParentFrame95(caseName: String, mode: String,
    paid: LogicalJsonOwnerReservation): Unit {
    paid.ensureRetainedPeak(4194304)
    let repo = getVariable("AXYNDRA_REPO_ROOT").getOrThrow()
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    let environment = HashMap<String, String>()
    var environmentBytes: Int64 = repo.size + root.size + caseName.size + mode.size
    for ((name, value) in getVariables()) {
        if (name.size > Int64.Max - value.size || environmentBytes > Int64.Max - name.size - value.size) {
            throw IllegalStateException("real child environment extent overflow") }
        environmentBytes += name.size + value.size
        if (environmentBytes > (Int64.Max - 4194304) / 8) {
            throw IllegalStateException("real child environment invoice overflow") }
        paid.ensureRetainedPeak(4194304 + environmentBytes * 8)
        environment[name] = value
    }
    let child = frontend_process95.startProcess(frontend_process95.ProcessCommand("/usr/bin/python3",
        arguments: [repo + "/scripts/frontend_real_io95.py", "--repo", repo, "--root", root,
            "--case", caseName, "--mode", mode], workingDirectory: repo, environment: environment,
        maxOutputBytes: 1048576, terminateProcessTree: true))
    let out = FrontendPipeDrain95(); let err = FrontendPipeDrain95()
    let stdout = spawn { out.drain(child.stdout) }; let stderr = spawn { err.drain(child.stderr) }
    try {
        let status = child.wait(); stdout.get(); stderr.get()
        @Expect(status.succeeded); @Expect(!child.isAlive()); @Expect(child.close())
        @Expect(exists(Path(root + "/physical-pipe-proof95.json")))
    } finally {
        let _ = child.terminate(force: true); let _ = child.wait()
        try { stdout.get() } finally { try { stderr.get() } finally { let _ = child.close() } }
        // Retain actual pipe/child raw logs and state receipts for Root review.
    }
}
@When[os == "Linux"]
@Test
class ActualFrontendPhysicalIO95Tests {
    @TestCase
    func cliCompleteEightFieldsReachRealPipeOnceAndOnlyThenOriginalSourceAcknowledges(): Unit {
        frontendRealPipe95("ActualFrontendPhysicalIO95Tests.cliCompleteEightFieldsReachRealPipeOnceAndOnlyThenOriginalSourceAcknowledges", "success") }
    @TestCase
    func cliOriginalActiveBorrowRefusesSourceAckThenReturnedFutureRetiresWithoutResending(): Unit {
        frontendRealPipe95("ActualFrontendPhysicalIO95Tests.cliOriginalActiveBorrowRefusesSourceAckThenReturnedFutureRetiresWithoutResending", "borrow") }
    @TestCase
    func cliActualNativeBankPressureFalseHandoffPreservesCallerThenReleaseConsumesOnce(): Unit {
        frontendRealPipe95("ActualFrontendPhysicalIO95Tests.cliActualNativeBankPressureFalseHandoffPreservesCallerThenReleaseConsumesOnce", "pressure") }
    @TestCase
    func cliRealPartialBrokenStdoutKeepsOriginalSourceControlAndSecondaryWithoutResend(): Unit {
        frontendRealPipe95("ActualFrontendPhysicalIO95Tests.cliRealPartialBrokenStdoutKeepsOriginalSourceControlAndSecondaryWithoutResend", "partial") }
    @TestCase
    func rpcObservedActualEofBoundsBlockedStdoutShutdownThenRealFuturesAndAliasesRetire(): Unit {
        frontendRealPipe95("ActualFrontendPhysicalIO95Tests.rpcObservedActualEofBoundsBlockedStdoutShutdownThenRealFuturesAndAliasesRetire", "rpc-eof") }
    @TestCase
    func rpcActualOnceCompletionBoundsBlockedStdoutShutdownThenRealFuturesAndAliasesRetire(): Unit {
        frontendRealPipe95("ActualFrontendPhysicalIO95Tests.rpcActualOnceCompletionBoundsBlockedStdoutShutdownThenRealFuturesAndAliasesRetire", "rpc-once") }
}

private func expectActualUsageFields163_2(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
}

// All fixture/cell/closure metadata is paid by the caller before this class
// exists. Store/Core/Pipeline alone produces the actual canonical Receipt.
@When[os == "Linux"]
private enum AcpPhysicalOutputAlias113 {
    Publication(OwnedFailureRunPublication113) | Data(OwnedFailureDataConsumer113)
    func acknowledged113(): Bool { match (this) {
        case Publication(value) => value.isAcknowledged()
        case Data(value) => value.isAcknowledged() } }
}
@When[os == "Linux"]
private class AcpPhysicalState113 {
    private let lock = Mutex()
    private var source: ?AcpPhysicalOutputAlias113 = None<AcpPhysicalOutputAlias113>
    private var offers: Int64 = 0
    private var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var secondaryVerified = false
    private let root: String
    init(root: String) { this.root = root }
    func install113(value: AcpPhysicalOutputAlias113): Unit {
        lock.lock(); try {
            offers++
            if (source.isSome()) { throw IllegalStateException("actual original output received a second failure offer") }
            source=Some(value)
            File.writeTo(root+"/actual-source-admitted113", "actual original Main output child admitted once\n".toArray())
        } finally { lock.unlock() }
    }
    func hasSource113(): Bool { lock.lock(); try { source.isSome() } finally { lock.unlock() } }
    func isAcknowledged113(): Bool {
        lock.lock(); try { source.getOrThrow().acknowledged113() } finally { lock.unlock() }
    }
    func offers113(): Int64 { lock.lock(); try { offers } finally { lock.unlock() } }
    func observeActualSecondary113(answer: OwnedFailureDataOutcome113<Unit>): OwnedFailureDataOutcome113<Unit> {
        match (answer) {
            case OwnedFailureDataOutcome113.Value(_) => ()
            case OwnedFailureDataOutcome113.Failure(actual) =>
                lock.lock(); try { secondary = Some(actual) } finally { lock.unlock() }
        }
        answer
    }
    func verifyActualSecondaryLoan113(): Unit {
        lock.lock(); let actual = try { secondary.getOrThrow() } finally { lock.unlock() }
        @Expect(!actual.isAcknowledged())
        match (actual.withError({ error, _ =>
            // All eight actual original output-exception fields are checked
            // inside the real paid loan. No String/error alias escapes it.
            @Expect(error.kind, AgentErrorKind.Transport)
            @Expect(error.code, "rpc.failure_frame_write_failed"); @Expect(error.message != "")
            @Expect(!error.retryable); @Expect(!error.fallbackAllowed)
            @Expect(error.fields.size, 0); @Expect(error.attemptFailure.isNone()); @Expect(error.observation.isNone())
        })) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
        lock.lock(); try { secondaryVerified = true } finally { lock.unlock() }
    }
    func retainedSecondary113(): Bool { lock.lock(); try { secondary.isSome() && !secondary.getOrThrow().isAcknowledged() } finally { lock.unlock() } }
    func verifiedSecondary113(): Bool { lock.lock(); try { secondaryVerified } finally { lock.unlock() } }

}
// This adapter observes ONLY the exact child given to the original Main port.
// It delegates the unmodified render/write/flush/ACK operation; it is not a
// replacement writer or a callback-return acknowledgement. Core's observer
// consumer may legitimately retire after publication derives its own share.
@When[os == "Linux"]
private class AcpPhysicalOutput113 <: OwnedRpcFailureOutput113 & AcpOwnedResponseOutput113 {
    private let original=RpcOutput()
    private let state: AcpPhysicalState113
    init(state: AcpPhysicalState113) { this.state=state }
    public func writeAcpResponse113(value: AcpOwnedResponse113): OwnedFailureDataOutcome113<Unit> {
        original.writeAcpResponse113(value)
    }
    public func writeFailureFrame113(value: OwnedFailureRunPublication113,
        render: (AgentError,(Int64)->Result<Unit>)->Result<String>): OwnedFailureDataOutcome113<Unit> {
        state.install113(AcpPhysicalOutputAlias113.Publication(value))
        state.observeActualSecondary113(original.writeFailureFrame113(value,render))
    }
    public func writeFailureFrame113(value: OwnedFailureDataConsumer113,
        render: (AgentError,(Int64)->Result<Unit>)->Result<String>): OwnedFailureDataOutcome113<Unit> {
        state.install113(AcpPhysicalOutputAlias113.Data(value))
        state.observeActualSecondary113(original.writeFailureFrame113(value,render))
    }
}
// The actual scheduler captures only this paid cell. The dynamic action,
// server/input/Product captures and Future reference clear only AFTER the
// complete original Future.get helper returned; tryGet(None) is not join.
@When[os == "Linux"]
private class AcpPhysicalMainTask113 {
    private var action: ?(() -> Int64) = None<() -> Int64>
    private var task: ?Future<Int64> = None<Future<Int64>>
    func start113(value: () -> Int64): Unit {
        if (task.isSome() || action.isSome()) { throw IllegalStateException("actual Main body was offered twice") }
        action=Some(value); task=Some(spawn { runAction113() })
    }
    private func runAction113(): Int64 { action.getOrThrow()() }
    func hasReturned113(): Bool { task.getOrThrow().tryGet().isSome() }
    private func getWholeHelper113(): Int64 { task.getOrThrow().get() }
    func getAndClear113(): Int64 {
        let status=getWholeHelper113()
        action=None<() -> Int64>; task=None<Future<Int64>>
        status
    }
}
@When[os == "Linux"]
private class AcpPhysicalFixture113 {
    let product: ProductRuntime
    let host: ProductRuntime
    let state: AcpPhysicalState113
    let observer: FrontendObserver95
    let control: AcpOwnedWorkerControl113
    let server: ProductAcpServer
    let input: AcpOwnedJsonlInput113
    let pump: AcpPhysicalMainTask113
    private let payment: AcpPhysicalPayment113
    private let root: String
    init(root: String, payment: AcpPhysicalPayment113) {
        this.root=root; this.payment=payment
        this.state=AcpPhysicalState113(root)
        this.observer=FrontendObserver95(payment,root,true,true)
        this.product=openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root+"/settings", stateRoot: root+"/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        @Expect(product.registerTool(ToolDescriptor(ModelToolDefinition("frontend_original95",
            "Actual ACP stdout checkpoint witness", objectValue([ValueField("type",textValue("object")),
                ValueField("properties",objectValue([]))])), Capability(CapabilityKind.WorkspaceRead),
            implementationVersion: "actual95", implementationFingerprint: "actual95"), observer).isOk())
        this.host=openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root+"/host-settings", stateRoot: root+"/host-state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        this.control=newAcpOwnedWorkerControl113()
        let actualProduct=product
        let output=AcpPhysicalOutput113(state)
        this.server=ProductAcpServer(host, { _ => Result.Ok(actualProduct) },
            { _ => throw IllegalStateException("physical ACP has no bare String fallback") },
            control113: control, ownedFailureOutput113: Some(output), ownedResponseOutput113: Some(output))
        control.ensureFrontendRegistryMetadata113(65536)
        control.registerAtExitServer113(server)
        let actualControl = control
        // The real callback keeps the paid Root and its actual failed server
        // reachable until physical child shutdown. Return/exit is never ACK.
        atExit({ => actualControl.closeRegisteredServerAtExit113() })
        let inputPaid=control.prepareFrontendCustody113()
        this.input=AcpOwnedJsonlInput113(control,inputPaid)
        control.installFrontendCustody113(input)
        this.pump=AcpPhysicalMainTask113()
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("frontend-call95", "frontend_original95", objectValue([]))
    }
    func start113(): Unit {
        // Existing fixture payment precedes this action allocation/spawn.
        payment.ensureRetainedPeak(4194304)
        let actualServer=server; let actualInput=input
        pump.start113({ => serveOwnedAcpBody113(actualServer,actualInput) })
    }
    func canonical113(): Unit {
        @Expect(observer.executed.load(),1); @Expect(observer.observed.load(),1)
        let (committed,completed,unknown,items)=productFixtureCanonicalCounts95(product,payment)
        @Expect(committed,1); @Expect(completed,1); @Expect(unknown,0); @Expect(items,1)
    }
    func record113(phase: String, status: Int64): Unit {
        payment.ensureRetainedPeak(4194304)
        let (committed,completed,unknown,items)=productFixtureCanonicalCounts95(product,payment)
        let (owners,bytes)=productControlMetadataUsage113()
        File.writeTo(root+"/"+phase+".json",encodeAgentValue(objectValue([
            ValueField("output_child_ack",boolValue(state.isAcknowledged113())),
            ValueField("failure_offers",integerValue(state.offers113())),
            ValueField("secondary_retained",boolValue(state.retainedSecondary113())),
            ValueField("secondary_full8_loan_verified",boolValue(state.verifiedSecondary113())),
            ValueField("body_status",integerValue(status)), ValueField("owners",integerValue(owners)),
            ValueField("bytes",integerValue(bytes)), ValueField("executed",integerValue(observer.executed.load())),
            ValueField("observed",integerValue(observer.observed.load())),
            ValueField("committed_operations",integerValue(committed)), ValueField("completed_receipts",integerValue(completed)),
            ValueField("unknown_receipts",integerValue(unknown)), ValueField("canonical_items",integerValue(items))])).toArray())
    }
}
@When[os == "Linux"]
private func acpPhysicalWait113(test: () -> Bool, seconds: Int64): Bool {
    let end=MonoTime.now()+Duration.second*seconds
    while (!test() && MonoTime.now()<end) { sleep(Duration.millisecond*5) }
    test()
}
@When[os == "Linux"]
private func acpPhysicalChildBody113(root: String, partial: Bool,
    payment: AcpPhysicalPayment113): Unit {
    let f=AcpPhysicalFixture113(root,payment)
    f.start113()
    @Expect(acpPhysicalWait113({ => f.observer.committed.load() },10))
    @Expect(acpPhysicalWait113({ => exists(Path(root+"/stdin-peer-closed113")) },10))
    // Prompt has actually entered its canonical observer; every input byte
    // was already consumed. This second reader observes ONLY real OS EOF.
    @Expect(PollingJsonlInput().poll(0).eof)
    @Expect(acpPhysicalWait113({ => f.state.hasSource113() },10))
    sleep(Duration.millisecond*200)
    @Expect(!f.pump.hasReturned113()); @Expect(!f.state.isAcknowledged113())
    f.canonical113(); f.record113("blocked113",-1)
    @Expect(acpPhysicalWait113({ => f.pump.hasReturned113() },10))
    let status=f.pump.getAndClear113() // WHOLE get then real action/Future clear
    if (partial) {
        @Expect(status,1); @Expect(!f.state.isAcknowledged113())
        f.state.verifyActualSecondaryLoan113()
        f.record113("partial-retained113",status)
        // Progress cannot resend the partly written original response.
        let _=f.server.collectOwnedCheckpointFailures113()
        @Expect(!f.state.isAcknowledged113()); f.canonical113()
        f.record113("done113",status)
        return // genuine failed output/secondary stay paid until child exit
    }
    @Expect(acpPhysicalWait113({ =>
        f.server.collectOwnedCheckpointFailures113()
        f.state.isAcknowledged113()
    },5))
    f.canonical113(); f.record113("done113",status)
    // Explicitly query the original closure only AFTER real stdout/get return.
    // Body status is recorded unchanged; no exit/close Unit is used as ACK.
    let actualClose113 = f.server.closeOwned113()
    @Expect(match (actualClose113) { case AcpOwnedCloseStatus113.Complete => true; case _ => false })
    @Expect(f.server.detachFailedInputAfterClosedFrontendReturn113())
    @Expect(f.input.destroyInputAfterFailedFrontendReturn113())
    @Expect(f.server.retireOwnedCloseAfterFrontendHelperReturn113())
    @Expect(f.control.collectFrontendAfterHelperReturn113())
    @Expect(f.control.clearAtExitServerAfterFrontendReturn113(f.server))
}
@When[os == "Linux"]
private class AcpPhysicalDrain113 {
    private var input: ?InputStream=None<InputStream>
    private var task: ?Future<Unit> = None<Future<Unit>>
    private var bytes: Int64=0
    private var joined=false
    func start113(value: InputStream): Unit { input=Some(value); task=Some(spawn { drainHelper113() }) }
    private func drainHelper113(): Unit {
        let buffer=Array<Byte>(8192,repeat:0u8)
        while (true) {
            let count=input.getOrThrow().read(buffer); if (count==0) { return }
            bytes+=count
            if (bytes>1048576) { throw IllegalStateException("actual ACP child report exceeded one MiB") }
        }
    }
    private func getWholeHelper113(): Unit { task.getOrThrow().get() }
    func joinAndClear113(): Unit {
        if (joined) { return }
        getWholeHelper113(); input=None<InputStream>; task=None<Future<Unit>>; joined=true
    }
}
@When[os == "Linux"]
private func acpPhysicalParentFrame113(caseName: String, mode: String,
    payment: AcpPhysicalPayment113): Unit {
    payment.ensureRetainedPeak(4194304)
    let repo=getVariable("AXYNDRA_REPO_ROOT").getOrThrow()
    if (!exists(Path("target"))) { Directory.create("target",recursive:true) }
    let root=Directory.createTemp("target").toString()
    let environment=HashMap<String,String>()
    var bytes: Int64=repo.size+root.size+caseName.size+mode.size
    for ((name,value) in getVariables()) {
        if (name.size>Int64.Max-value.size || bytes>Int64.Max-name.size-value.size) {
            throw IllegalStateException("actual ACP environment invoice overflow") }
        bytes+=name.size+value.size
        if (bytes>(Int64.Max-4194304)/8) { throw IllegalStateException("actual ACP environment invoice overflow") }
        payment.ensureRetainedPeak(4194304+bytes*8); environment[name]=value
    }
    let child=acp_process113.startProcess(acp_process113.ProcessCommand("/usr/bin/python3",
        arguments:[repo+"/scripts/acp_physical_pipe113.py","--repo",repo,"--root",root,
            "--case",caseName,"--mode",mode],workingDirectory:repo,environment:environment,
        maxOutputBytes:1048576,terminateProcessTree:true))
    let out=AcpPhysicalDrain113(); let err=AcpPhysicalDrain113()
    out.start113(child.stdout); err.start113(child.stderr)
    try {
        let status=child.wait(); out.joinAndClear113(); err.joinAndClear113()
        @Expect(status.succeeded); @Expect(!child.isAlive()); @Expect(child.close())
        @Expect(exists(Path(root+"/physical-pipe-proof113.json")))
    } finally {
        let _=child.terminate(force:true); let _=child.wait()
        try { out.joinAndClear113() } finally { try { err.joinAndClear113() } finally { let _=child.close() } }
    }
}
@When[os == "Linux"]
private func acpPhysicalCase113(caseName: String, mode: String): Unit {
    let payment=reserveProductControlMetadata113(65536)
    // The fixed original observation-buffer charge conservatively retains
    // empty scheduler carriers, whose SDK release has no validated source
    // witness. No Root-zero claim is made for this explicit child fixture.
    let carrier=reserveProductObservationBuffer113()
    match (getVariable("AXYNDRA_ACP_PHYSICAL_CHILD113")) {
        case Some(root) =>
            payment.ensureRetainedPeak(4194304)
            withActualStdoutPipe95({ => acpPhysicalChildBody113(root,mode=="partial",payment) })
            // Failed output children remain reachable/paid until OS exit;
            // physical exit is never counted as consumption ACK.
            return
        case None => ()
    }
    try { acpPhysicalParentFrame113(caseName,mode,payment) }
    finally { payment.close() } // Complete child/drain/capture-clear helper return.
    // carrier remains conservatively charged for unknown empty SDK captures.
}
@When[os == "Linux"]
@Test
class ActualAcpPhysicalOwnership113Tests {
    @TestCase
    func realEofAndBlockedStdoutPreserveOriginalCanonicalFailureUntilFullPipeDrain(): Unit {
        acpPhysicalCase113("ActualAcpPhysicalOwnership113Tests.realEofAndBlockedStdoutPreserveOriginalCanonicalFailureUntilFullPipeDrain","eof")
    }
    @TestCase
    func realPartialBrokenStdoutKeepsActualOutputChildAndSecondaryWithoutASecondOffer(): Unit {
        acpPhysicalCase113("ActualAcpPhysicalOwnership113Tests.realPartialBrokenStdoutKeepsActualOutputChildAndSecondaryWithoutASecondOffer","partial")
    }
}
