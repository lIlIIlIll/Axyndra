package agent_product

import agent_domain.*
import agent_ports.*
import agent_store.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func outputWindowAwaitCount(channel: ProcessChannel, count: Int64): Int64 {
    let deadline = MonoTime.now() + Duration.second * 3
    var actual: Int64 = 0
    while (MonoTime.now() < deadline) {
        actual = lifecycleTestRequire(channel.receivedOutputBytes())
        if (actual >= count) { return actual }
        sleep(Duration.millisecond)
    }
    throw IllegalStateException("raw output meter did not reach " + count.toString() + ": " + actual.toString())
}

@Test
class ProcessOutputWindowTests {
    @TestCase
    func initialWindowChargesBothPipesBeforeAnyConsumerAndCannotPromoteOverflow(): Unit {
        let fixture = RawChannelFixture("phase-both-pipes",
            "os.read(0,1)\nos.write(1,b'ab')\nos.write(2,b'cde')\ntime.sleep(30)",
            maxOutputBytes: 64, initialOutputWindowBytes: Some(4))
        try {
            let ticket = lifecycleTestRequire(fixture.channel.currentOutputWindow()).getOrThrow()
            @Expect(ticket.baselineBytes, 0)
            @Expect(ticket.maximumBytes, 4)
            lifecycleTestRequire(fixture.channel.write("x".toArray()))
            @Expect(outputWindowAwaitCount(fixture.channel, 5), 5)
            // Neither pipe was read by this test. Queued and over-limit bytes
            // already consume the common meter and terminal state is latched.
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stdout).code, "process.channel_output_limit")
            @Expect(fixture.channel.endOutputWindow(ticket).isError())
            @Expect(fixture.channel.beginOutputWindow(64, false).isError())
            @Expect(lifecycleTestRequire(fixture.channel.receivedOutputBytes()), 5)
        } finally { fixture.close() }
        @Expect(fixture.releases.load(), 1)
    }

    @TestCase
    func exactTicketPromotionAndRefreshNeverResetTheLifetimeMeter(): Unit {
        let fixture = RawChannelFixture("phase-promotion",
            "os.read(0,1)\nos.write(1,b'abc')\nos.read(0,1)\nos.write(1,b'defg')\nos.read(0,1)\nos.write(1,b'hi')\ntime.sleep(30)",
            maxOutputBytes: 8, initialOutputWindowBytes: Some(3))
        try {
            let initial = lifecycleTestRequire(fixture.channel.currentOutputWindow()).getOrThrow()
            let forged = ProcessChannelOutputWindow(initial.baselineBytes, initial.maximumBytes)
            @Expect(fixture.channel.endOutputWindow(forged).isError())
            lifecycleTestRequire(fixture.channel.write("a".toArray()))
            @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stdout, 3)), "abc")
            @Expect(lifecycleTestRequire(fixture.channel.endOutputWindow(initial)), 3)
            @Expect(fixture.channel.endOutputWindow(initial).isError())
            let refresh = lifecycleTestRequire(fixture.channel.beginOutputWindow(4, false))
            @Expect(refresh.baselineBytes, 3)
            @Expect(refresh.maximumBytes, 4)
            @Expect(fixture.channel.beginOutputWindow(1, false).isError())
            @Expect(fixture.channel.endOutputWindow(initial).isError())
            lifecycleTestRequire(fixture.channel.write("b".toArray()))
            @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stdout, 4)), "defg")
            @Expect(lifecycleTestRequire(fixture.channel.endOutputWindow(refresh)), 7)
            // A larger requested window is intersected with the original
            // lifetime allowance, not a fresh allocation after each phase.
            let last = lifecycleTestRequire(fixture.channel.beginOutputWindow(4, false))
            @Expect(last.baselineBytes, 7)
            @Expect(last.maximumBytes, 1)
            lifecycleTestRequire(fixture.channel.write("c".toArray()))
            @Expect(outputWindowAwaitCount(fixture.channel, 9), 9)
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stdout).code, "process.channel_output_limit")
            @Expect(fixture.channel.endOutputWindow(last).isError())
        } finally { fixture.close() }
        @Expect(fixture.releases.load(), 1)
    }

    @TestCase
    func lateRestrictionCannotForgetAlreadyQueuedIngress(): Unit {
        let fixture = RawChannelFixture("phase-late-restrict", "os.write(1,b'abcde')\ntime.sleep(30)", maxOutputBytes: 64)
        try {
            @Expect(outputWindowAwaitCount(fixture.channel, 5), 5)
            @Expect(fixture.channel.beginOutputWindow(4, true).isError())
            @Expect(fixture.channel.currentOutputWindow().isError())
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stdout).code, "process.channel_output_limit")
            @Expect(fixture.channel.beginOutputWindow(64, false).isError())
            @Expect(lifecycleTestRequire(fixture.channel.receivedOutputBytes()), 5)
        } finally { fixture.close() }
        @Expect(fixture.releases.load(), 1)
    }

    @TestCase
    func filteredSecretPrefixConsumesTheSameInitialWindowAndCloseInvalidatesTicket(): Unit {
        let fixture = RawChannelFixture("phase-secret-prefix",
            "os.read(0,1)\nos.write(1,b'abc')\nos.read(0,1)\nos.write(2,b'd')\ntime.sleep(30)",
            maxOutputBytes: 64, initialOutputWindowBytes: Some(3))
        let filtered = ProductProcessSecretChannel(fixture.channel, ["abcdef"], 64)
        try {
            let ticket = lifecycleTestRequire(filtered.currentOutputWindow()).getOrThrow()
            lifecycleTestRequire(filtered.write("a".toArray()))
            @Expect(outputWindowAwaitCount(filtered, 3), 3)
            let withheld = lifecycleTestRequire(filtered.read(ProcessChannelStream.Stdout, 16, 25))
            @Expect(withheld.bytes.size, 0)
            @Expect(!withheld.eof)
            lifecycleTestRequire(filtered.write("b".toArray()))
            @Expect(outputWindowAwaitCount(filtered, 4), 4)
            @Expect(filtered.endOutputWindow(ticket).isError())
            @Expect(filtered.read(ProcessChannelStream.Stderr, 16, 25).isError())
            @Expect(filtered.close().isOk())
            @Expect(filtered.endOutputWindow(ticket).isError())
        } finally { fixture.close() }
        @Expect(fixture.releases.load(), 1)
    }

    @TestCase
    func closingOrAnotherChannelCannotReleaseAWindowTicket(): Unit {
        let first = RawChannelFixture("phase-ticket-a", "time.sleep(30)", initialOutputWindowBytes: Some(3))
        let second = RawChannelFixture("phase-ticket-b", "time.sleep(30)", initialOutputWindowBytes: Some(3))
        try {
            let ticket = lifecycleTestRequire(first.channel.currentOutputWindow()).getOrThrow()
            @Expect(second.channel.endOutputWindow(ticket).isError())
            ticket.invalidate()
            @Expect(first.channel.endOutputWindow(ticket).isError())
            @Expect(first.channel.close().isOk())
            @Expect(first.channel.endOutputWindow(ticket).isError())
            @Expect(first.channel.beginOutputWindow(3, false).isError())
            @Expect(lifecycleTestRequire(second.channel.currentOutputWindow()).isSome())
        } finally { try { first.close() } finally { second.close() } }
        @Expect(first.releases.load(), 1)
        @Expect(second.releases.load(), 1)
    }
}

func outputWindowConfigureMcp(fixture: McpProductFixture, startup: Int64, refresh: Int64): Unit {
    let path = fixture.files.settings + "/plugins/lifecycle.json"
    let document = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
    let service = document.field("plugins").getOrThrow().items[0].field("services").getOrThrow().items[0]
    service.field("startup").getOrThrow().put("max_output_bytes", integerValue(startup))
    service.field("refresh").getOrThrow().put("max_output_bytes", integerValue(refresh))
    fixture.files.write(document)
}

@Test
class PluginOutputWindowTests {
    @TestCase
    func realStartupOverflowCannotPublishDespiteLargerLifetimeGrant(): Unit {
        let fixture = McpProductFixture(refresh: true)
        try {
            outputWindowConfigureMcp(fixture, 1, 65536)
            let result = fixture.start("startup-window-overflow")
            @Expect(result.isError() || managedCompleted(result).isError)
            @Expect(!fixture.active("startup-window-overflow"))
            @Expect(!fixture.visible("startup-window-overflow"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            fixture.waitReleased()
        } finally { fixture.close() }
    }

    @TestCase
    func realRefreshOverflowKeepsStartupFactsButCannotRestoreActiveAllowance(): Unit {
        let fixture = McpProductFixture(mode: "refresh-change", refresh: true)
        try {
            outputWindowConfigureMcp(fixture, 65536, 1)
            @Expect(!managedCompleted(fixture.start("refresh-window-overflow")).isError)
            let before = fixture.database.query("SELECT detail FROM operation_receipts WHERE outcome='completed'")[0].required(0)
            let result = mcpRefresh(fixture, "refresh-window-overflow")
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
            @Expect(!fixture.active("refresh-window-overflow"))
            @Expect(!fixture.visible("refresh-window-overflow"))
            @Expect(mcpRefreshReceiptCount(fixture, "unknown"), 1)
            @Expect(mcpRefreshReceiptCount(fixture, "completed"), 0)
            @Expect(fixture.database.query("SELECT detail FROM operation_receipts WHERE outcome='completed'")[0].required(0), before)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            fixture.waitReleased()
        } finally { fixture.close() }
    }

    @TestCase
    func actualCompletedRefreshProofRestoresAllowanceForTheNextMaintenanceWindow(): Unit {
        let fixture = McpProductFixture(mode: "refresh-change", refresh: true)
        try {
            @Expect(!managedCompleted(fixture.start("window-promotions")).isError)
            for (revision in [2, 3]) {
                @Expect(!managedCompleted(mcpRefresh(fixture, "window-promotions")).isError)
                @Expect(mcpRefreshRevision(fixture, "window-promotions"), revision)
                @Expect(fixture.active("window-promotions"))
                @Expect(mcpRefreshReceiptCount(fixture, "completed"), revision - 1)
            }
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 3)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }
}

// Only metadata return timing is held. The child, both pipes, window meter,
// cancellation and close acknowledgement are real LocalProcessPort resources.
class OutputAttachMetadataChannel <: ProcessChannel {
    let inner: ProcessChannel
    let entered = AtomicBool(false)
    let released = AtomicBool(false)
    let fail = AtomicBool(false)
    init(inner: ProcessChannel) { this.inner = inner }
    public func currentOutputWindow(): Result<?ProcessChannelOutputWindow> {
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 4
        while (!released.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        if (!released.load() || fail.load()) {
            return Result.Err(AgentError(AgentErrorKind.Transport, "fixture.window_metadata_failed", "window metadata withheld"))
        }
        inner.currentOutputWindow()
    }
    public func beginOutputWindow(maximumBytes: Int64, fromStart: Bool): Result<ProcessChannelOutputWindow> {
        inner.beginOutputWindow(maximumBytes, fromStart)
    }
    public func endOutputWindow(ticket: ProcessChannelOutputWindow): Result<Int64> { inner.endOutputWindow(ticket) }
    public func receivedOutputBytes(): Result<Int64> { inner.receivedOutputBytes() }
    public func read(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        inner.read(stream, maxBytes, waitMillis)
    }
    public func write(bytes: Array<Byte>): Result<Unit> { inner.write(bytes) }
    public func abort(): Result<Unit> { inner.abort() }
    public func close(): Result<Unit> { inner.close() }
}

class OutputAttachProbePort <: ProcessPort {
    let inner: LocalProcessPort
    private let lock = Mutex()
    private var value: ?OutputAttachMetadataChannel = None
    init(workspace: String) { inner = LocalProcessPort(LocalWorkspace(workspace), sandboxEnabled: true) }
    func captured(): ?OutputAttachMetadataChannel { lock.lock(); try { value } finally { lock.unlock() } }
    public func execute(request: ProcessRequest): Result<ProcessResult> { inner.execute(request) }
    public func reserveOperation(operationId: OperationId): Unit { inner.reserveOperation(operationId) }
    public func releaseOperation(operationId: OperationId): Unit { inner.releaseOperation(operationId) }
    public func cancel(operationId: OperationId): Result<Unit> { inner.cancel(operationId) }
    public func closeChannelOperation(operationId: OperationId): Result<Unit> { inner.closeChannelOperation(operationId) }
    public func openChannel(request: ProcessRequest, cancellation: CancellationToken, maxInputBytes: Int64): Result<ProcessChannel> {
        match (inner.openChannel(request, cancellation, maxInputBytes)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(channel) =>
                let wrapped = OutputAttachMetadataChannel(channel)
                lock.lock(); try { value = Some(wrapped) } finally { lock.unlock() }
                Result.Ok(wrapped)
        }
    }
}

func outputAttachAwait(port: OutputAttachProbePort): OutputAttachMetadataChannel {
    let deadline = MonoTime.now() + Duration.second * 3
    while (MonoTime.now() < deadline) {
        match (port.captured()) { case Some(value) => if (value.entered.load()) { return value }; case None => () }
        sleep(Duration.millisecond)
    }
    throw IllegalStateException("actual channel never entered its delayed metadata boundary")
}

func outputAttachCleanup(owner: ProductPluginLifecycleOwner, port: OutputAttachProbePort): Unit {
    match (port.captured()) { case Some(value) => value.released.store(true); case None => () }
    let deadline = MonoTime.now() + Duration.second * 5
    var closed = false
    while (!closed && MonoTime.now() < deadline) {
        closed = owner.close().isOk()
        if (!closed) { sleep(Duration.millisecond * 5) }
    }
    let released = port.inner.close().isOk()
    if (!closed || !released) { throw IllegalStateException("delayed metadata retained native cleanup ownership") }
}

@Test
class PluginOutputWindowAttachTests {
    @TestCase
    func metadataDelayDoesNotLookLikeTwoCompletedOutputPumps(): Unit {
        let fixture = LifecycleOwnerFixture(registerControl: false)
        let port = OutputAttachProbePort(fixture.configuration.workspace)
        let owner = ProductPluginLifecycleOwner(fixture.database, port, operations: fixture.product.vnext.operations)
        let control = ProductPluginLifecycleControl(owner)
        let caller = CancellationSource()
        @Expect(!fixture.product.unregisterTool(PLUGIN_LIFECYCLE_TOOL))
        lifecycleTestRequire(fixture.product.registerTool(control.descriptor(), control))
        let pending = spawn {
            control.launch(fixture.product.vnext, SessionId("metadata-delayed-startup"), fixture.grant("metadata-instance"),
                fixture.ceiling(), { lease, _, _ => Result.Ok(lifecycleControlEcho(lease, "abc")) },
                approvalDecision: Some(ApprovalDecision.Approve), callerCancellation: Some(caller.token))
        }
        try {
            let channel = outputAttachAwait(port)
            // Observe across several actual 25ms monitor ticks while metadata
            // remains held and no owner pump has been created yet.
            let until = MonoTime.now() + Duration.millisecond * 100
            while (MonoTime.now() < until) {
                @Expect(channel.inner.currentOutputWindow().isOk())
                @Expect(owner.retainedCount(), 1)
                sleep(Duration.millisecond * 5)
            }
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            channel.released.store(true)
            let launched = lifecycleTestRequire(pending.get())
            @Expect(launched.lease.getOrThrow().isActive())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally {
            match (port.captured()) { case Some(value) => value.released.store(true); case None => () }
            let _ = caller.cancel()
            try { let _ = pending.get() } finally {
                try { outputAttachCleanup(owner, port) } finally { caller.close(); fixture.close() }
            }
        }
    }

    @TestCase
    func failureOrCancellationDuringMetadataStillClearsOpeningAndReaps(): Unit {
        for (cancelled in [false, true]) {
            let fixture = LifecycleOwnerFixture(registerControl: false)
            let port = OutputAttachProbePort(fixture.configuration.workspace)
            let owner = ProductPluginLifecycleOwner(fixture.database, port, operations: fixture.product.vnext.operations)
            let control = ProductPluginLifecycleControl(owner)
            let caller = CancellationSource()
            @Expect(!fixture.product.unregisterTool(PLUGIN_LIFECYCLE_TOOL))
            lifecycleTestRequire(fixture.product.registerTool(control.descriptor(), control))
            let calls = AtomicInt64(0)
            let pending = spawn {
                control.launch(fixture.product.vnext, SessionId("metadata-failed-startup"), fixture.grant("metadata-failed"),
                    fixture.ceiling(), { _, _, _ => let _ = calls.fetchAdd(1); Result.Ok(objectValue([])) },
                    approvalDecision: Some(ApprovalDecision.Approve), callerCancellation: Some(caller.token))
            }
            try {
                let channel = outputAttachAwait(port)
                if (cancelled) { let _ = caller.cancel() } else { channel.fail.store(true) }
                channel.released.store(true)
                let outcome = pending.get()
                @Expect(outcome.isError() || outcome.value().getOrThrow().lease.isNone())
                @Expect(calls.load(), 0)
                outputAttachCleanup(owner, port)
                @Expect(owner.retainedCount(), 0)
                for (row in fixture.database.query("SELECT id FROM operations")) {
                    @Expect(!port.inner.hasActiveOperation(OperationId(row.required(0))))
                }
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            } finally {
                match (port.captured()) { case Some(value) => value.released.store(true); case None => () }
                let _ = caller.cancel()
                try { let _ = pending.get() } finally {
                    try { outputAttachCleanup(owner, port) } finally { caller.close(); fixture.close() }
                }
            }
        }
    }
}
