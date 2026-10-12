package agent_product

import agent_domain.*
import agent_ports.*
import process4cj as channel_process
import std.collection.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Candidate-only tests. These launch actual Python children through the real
// ManagedProcess implementation. They prove the raw transport, not lifecycle
// authorization, a Product sandbox factory, IPC admission or an MCP adapter.
class RawChannelFixture {
    let root: String
    let source: CancellationSource
    let command: channel_process.ManagedProcess
    let channel: ProductProcessChannel
    let releases: AtomicInt64

    init(label: String, body: String, setup!: String = "",
        timeoutMillis!: Int64 = 10000, maxInputBytes!: Int64 = 262144,
        maxOutputBytes!: Int64 = 262144, initialOutputWindowBytes!: ?Int64 = None) {
        let directory = pluginContractTemp("raw-channel-" + label)
        Directory.create(directory, recursive: true)
        this.root = directory
        let cancellation = CancellationSource()
        this.source = cancellation
        let count = AtomicInt64(0)
        this.releases = count
        let program = "import os, sys, time\nfrom pathlib import Path\n" +
            "root = Path(sys.argv[1])\n" + setup + "\n" +
            "(root / 'ready').write_text('ready')\n" + body + "\n"
        File.writeTo(directory + "/fixture.py", program.toArray())
        let started = channel_process.startProcess(channel_process.ProcessCommand("/usr/bin/python3",
            arguments: [directory + "/fixture.py", directory], workingDirectory: directory,
            terminateProcessTree: true, maxOutputBytes: 16777216))
        this.command = started
        try {
            this.channel = ProductProcessChannel(started, cancellation.token,
                timeoutMillis, maxInputBytes, maxOutputBytes,
                { => let _ = count.fetchAdd(1); () }, initialOutputWindowBytes: initialOutputWindowBytes)
            rawChannelAwaitFile(directory + "/ready")
        } catch (error: Exception) {
            let _ = started.terminate(force: true)
            let _ = started.close()
            cancellation.close()
            throw error
        }
    }

    func close(): Unit {
        // Only this fixture's exact ManagedProcess ownership is terminated.
        // ProductProcessChannel.close must independently remain bounded.
        let _ = command.terminate(force: true)
        let _ = channel.close()
        source.close()
        remove(root, recursive: true)
    }
}

func rawChannelAwaitFile(path: String): Unit {
    let deadline = MonoTime.now() + Duration.second * 5
    while (!exists(Path(path)) && MonoTime.now() < deadline) {
        sleep(Duration.millisecond * 5)
    }
    if (!exists(Path(path))) { throw IllegalStateException("process fixture readiness missing: " + path) }
}

func rawChannelSameBytes(first: Array<Byte>, second: Array<Byte>): Bool {
    if (first.size != second.size) { return false }
    for (index in 0..first.size) { if (first[index] != second[index]) { return false } }
    true
}

func rawChannelReadAll(channel: ProcessChannel, stream: ProcessChannelStream,
    maxBytes!: Int64 = 4096): Array<Byte> {
    let collected = ArrayList<Byte>()
    let deadline = MonoTime.now() + Duration.second * 3
    while (MonoTime.now() < deadline) {
        match (channel.read(stream, maxBytes, 25)) {
            case Result.Err(error) => throw IllegalStateException("channel drain failed: " + error.describe())
            case Result.Ok(value) =>
                for (byte in value.bytes) { collected.add(byte) }
                if (value.eof) { return collected.toArray() }
        }
    }
    throw IllegalStateException("channel drain exceeded its test deadline")
}

func rawChannelReadCount(channel: ProcessChannel, stream: ProcessChannelStream, count: Int64): Array<Byte> {
    let collected = ArrayList<Byte>()
    let deadline = MonoTime.now() + Duration.second * 3
    while (collected.size < count && MonoTime.now() < deadline) {
        match (channel.read(stream, count - collected.size, 25)) {
            case Result.Err(error) => throw IllegalStateException("channel read failed: " + error.describe())
            case Result.Ok(value) =>
                for (byte in value.bytes) { collected.add(byte) }
                if (value.eof && collected.size < count) { throw IllegalStateException("channel ended before expected bytes") }
        }
    }
    if (collected.size != count) { throw IllegalStateException("channel byte count did not arrive") }
    collected.toArray()
}

func rawChannelAwaitError(channel: ProcessChannel, stream: ProcessChannelStream): AgentError {
    let deadline = MonoTime.now() + Duration.second * 3
    while (MonoTime.now() < deadline) {
        match (channel.read(stream, 4096, 25)) {
            case Result.Err(error) => return error
            case Result.Ok(_) => ()
        }
    }
    throw IllegalStateException("channel never reported the required terminal failure")
}

class RawChannelPending {
    let started = AtomicBool(false)
    let completed = AtomicBool(false)
    private let lock = Mutex()
    private var result: ?Result<Unit> = None
    private var failure: ?String = None
    private var worker: ?Future<Unit> = None

    init(action: () -> Result<Unit>) {
        worker = Some(spawn {
            started.store(true)
            try {
                let value = action()
                lock.lock(); try { result = Some(value) } finally { lock.unlock() }
            } catch (error: Exception) {
                lock.lock(); try { failure = Some(error.message) } finally { lock.unlock() }
            } finally { completed.store(true) }
        })
    }
    func value(): Result<Unit> {
        lock.lock()
        try {
            match (failure) {
                case Some(message) => throw IllegalStateException("channel action threw: " + message)
                case None => result.getOrThrow()
            }
        } finally { lock.unlock() }
    }
}

func rawChannelAwaitUnit(pending: RawChannelPending): Result<Unit> {
    let deadline = MonoTime.now() + Duration.second * 3
    while (MonoTime.now() < deadline) {
        if (pending.completed.load()) { return pending.value() }
        sleep(Duration.millisecond * 5)
    }
    throw IllegalStateException("channel future did not settle within three seconds")
}

func rawChannelUnitError(result: Result<Unit>): String {
    match (result) {
        case Result.Err(error) => error.code
        case Result.Ok(_) => throw IllegalStateException("expected channel error, got success")
    }
}

func rawChannelReadError(result: Result<ProcessChannelRead>): String {
    match (result) {
        case Result.Err(error) => error.code
        case Result.Ok(_) => throw IllegalStateException("expected channel read error, got success")
    }
}

// This wrapper injects exactly one failed native termination attempt without
// sending a signal; every other method uses an actual Linux-owned process.
class RawChannelTerminationFault <: channel_process.ProcessPlatformProcess {
    let inner: channel_process.ProcessPlatformProcess
    let attempts = AtomicInt64(0)
    private let throwsFirst: Bool
    init(inner: channel_process.ProcessPlatformProcess, throwsFirst: Bool) {
        this.inner = inner; this.throwsFirst = throwsFirst
    }
    public prop pid: Int64 { get() { inner.pid } }
    public prop stdout: InputStream { get() { inner.stdout } }
    public prop stderr: InputStream { get() { inner.stderr } }
    public func writeInput(data: Array<Byte>): Unit { inner.writeInput(data) }
    public func flushInput(): Unit { inner.flushInput() }
    public func closeInput(): Unit { inner.closeInput() }
    public func inputCloseSupported(): Bool { inner.inputCloseSupported() }
    public func wait(): Int64 { inner.wait() }
    public func isAlive(): Bool { inner.isAlive() }
    public func close(): Unit { inner.close() }
    public func terminate(force: Bool, processTree: Bool): Bool {
        if (attempts.fetchAdd(1) == 0) {
            if (throwsFirst) { throw channel_process.ProcessError(channel_process.ProcessErrorKind.Io, "injected signal rejection") }
            return false
        }
        inner.terminate(force, processTree)
    }
}

class RawChannelTerminationFaultBackend <: channel_process.ProcessBackend {
    private let throwsFirst: Bool
    var launched: ?RawChannelTerminationFault = None
    init(throwsFirst: Bool) { this.throwsFirst = throwsFirst }
    public func launchProcess(command: channel_process.ProcessCommand): channel_process.ProcessPlatformProcess {
        let value = RawChannelTerminationFault(channel_process.LinuxProcessBackend().launchProcess(command), throwsFirst)
        launched = Some(value)
        value
    }
}

func rawChannelFailedTerminationContract(throwsFirst: Bool): Unit {
    let source = CancellationSource()
    let backend = RawChannelTerminationFaultBackend(throwsFirst)
    let process = channel_process.startProcess(channel_process.ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
    let unrelated = channel_process.startProcess(channel_process.ProcessCommand("/bin/sleep", arguments: ["30"]))
    let releases = AtomicInt64(0)
    let channel = ProductProcessChannel(process, source.token, 10000, 65536, 65536,
        { => let _ = releases.fetchAdd(1); () })
    try {
        let first = rawChannelAwaitUnit(RawChannelPending({ => channel.close() }))
        if (rawChannelUnitError(first) != "process.channel_close_failed" ||
            releases.load() != 0 || !process.isAlive() || process.terminationRequested(force: true)) {
            throw IllegalStateException("failed termination must remain alive, retained and retryable")
        }
        if (backend.launched.getOrThrow().attempts.load() != 1) {
            throw IllegalStateException("first cleanup unexpectedly retried or released process")
        }
        let second = rawChannelAwaitUnit(RawChannelPending({ => channel.close() }))
        if (!second.isOk() || releases.load() != 1 ||
            backend.launched.getOrThrow().attempts.load() != 2 || !process.terminationRequested(force: true)) {
            throw IllegalStateException("second cleanup did not terminate and release the real process exactly once")
        }
        if (exists(Path("/proc/" + process.pid.toString())) || !unrelated.isAlive()) {
            throw IllegalStateException("cleanup lost exact process ownership")
        }
        if (rawChannelReadError(channel.read(ProcessChannelStream.Stdout, 1, 0)) != "process.channel_closed") {
            throw IllegalStateException("cleanup retry changed the first terminal cause")
        }
    } finally {
        // Bypass the injected fault for test cleanup even against the old
        // implementation; do not leave a failing regression's actual child.
        let _ = backend.launched.getOrThrow().inner.terminate(true, true)
        let _ = process.close()
        let _ = channel.close()
        let _ = unrelated.close()
        source.close()
    }
}

@Test
class ProductProcessChannelTests {
    @TestCase
    func queuedChunksCoalesceWithinReadLimitAndPreservePartialHeadAndEof(): Unit {
        let queue = ProductProcessChannelQueue()
        @Expect(queue.append([0, 1, 2]))
        @Expect(queue.append([3, 4]))
        @Expect(queue.append([5, 6, 7, 8]))
        let first = queue.poll(4).value().getOrThrow()
        @Expect(rawChannelSameBytes(first.bytes, [0, 1, 2, 3]))
        @Expect(!first.eof)
        let second = queue.poll(2).value().getOrThrow()
        @Expect(rawChannelSameBytes(second.bytes, [4, 5]))
        @Expect(!second.eof)
        queue.finish()
        let last = queue.poll(65536).value().getOrThrow()
        @Expect(rawChannelSameBytes(last.bytes, [6, 7, 8]))
        @Expect(last.eof)
        let drained = queue.poll(1).value().getOrThrow()
        @Expect(drained.eof && drained.bytes.isEmpty())
    }

    @TestCase
    func shortQueuedReadReturnsWithoutWaitingForMoreAndEmptyChunksDoNotHideEof(): Unit {
        let queue = ProductProcessChannelQueue()
        @Expect(queue.append([]))
        @Expect(queue.append([255]))
        @Expect(queue.append([]))
        let read = queue.poll(65536).value().getOrThrow()
        @Expect(rawChannelSameBytes(read.bytes, [255]))
        @Expect(!read.eof)
        queue.finish()
        let finalRead = queue.poll(65536).value().getOrThrow()
        @Expect(finalRead.bytes.isEmpty() && finalRead.eof)
    }

    @TestCase
    func failedQueueDiscardsAllPendingChunksBeforeAnyFurtherDelivery(): Unit {
        let queue = ProductProcessChannelQueue()
        @Expect(queue.append([1, 2]))
        @Expect(queue.append([3, 4]))
        queue.finish(error: Some(AgentError(AgentErrorKind.Cancelled,
            "fixture.queue_cancelled", "cancelled queue")))
        @Expect(rawChannelReadError(queue.poll(65536)), "fixture.queue_cancelled")
        @Expect(!queue.append([5]))
        @Expect(rawChannelReadError(queue.poll(1)), "fixture.queue_cancelled")
    }

    @TestCase
    func rejectedNativeTerminationRetainsLeaseAndRetriesRealCleanup(): Unit {
        rawChannelFailedTerminationContract(false)
    }

    @TestCase
    func throwingNativeTerminationRetainsLeaseAndRetriesRealCleanup(): Unit {
        rawChannelFailedTerminationContract(true)
    }

    @TestCase
    func binaryRoundTripAndReturnedByteCopiesPreserveExactData(): Unit {
        let fixture = RawChannelFixture("binary", "data = sys.stdin.buffer.read(4)\n" +
            "sys.stdout.buffer.write(data)\nsys.stdout.buffer.flush()")
        try {
            let payload: Array<Byte> = [0, 255, 65, 10]
            @Expect(fixture.channel.write(payload).isOk(), true)
            let received = rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout, maxBytes: 2)
            @Expect(rawChannelSameBytes(received, payload), true)
            @Expect(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stderr).isEmpty(), true)
            let original: Array<Byte> = [0, 255]
            let result = ProcessChannelRead(original, false)
            original[0] = 17
            let first = result.bytes
            first[1] = 19
            @Expect(rawChannelSameBytes(result.bytes, [0, 255]), true)
        } finally { fixture.close() }
    }

    @TestCase
    func bothPipesDrainConcurrentlyWithoutCombiningTheirBytes(): Unit {
        let fixture = RawChannelFixture("dual", "import threading\n" +
            "def emit(fd, byte):\n    for _ in range(16):\n        os.write(fd, byte * 4096)\n" +
            "worker = threading.Thread(target=emit, args=(2, b'E'))\nworker.start()\n" +
            "emit(1, b'O')\nworker.join()", maxOutputBytes: 131072)
        try {
            let output = rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout)
            let err = rawChannelReadAll(fixture.channel, ProcessChannelStream.Stderr)
            @Expect(rawChannelSameBytes(output, Array<Byte>(65536, repeat: 79)), true)
            @Expect(rawChannelSameBytes(err, Array<Byte>(65536, repeat: 69)), true)
        } finally { fixture.close() }
    }

    @TestCase
    func inputReservationIsCumulativeAndRejectedBytesNeverReachChild(): Unit {
        let fixture = RawChannelFixture("input-cap", "while True:\n" +
            "    value = os.read(0, 1)\n    if not value: break\n    os.write(1, value)", maxInputBytes: 4)
        try {
            @Expect(fixture.channel.write("AB".toArray()).isOk(), true)
            @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stdout, 2)), "AB")
            @Expect(fixture.channel.write("CD".toArray()).isOk(), true)
            @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stdout, 2)), "CD")
            @Expect(rawChannelUnitError(fixture.channel.write("X".toArray())), "process.channel_input_limit")
            match (fixture.channel.read(ProcessChannelStream.Stdout, 16, 25)) {
                case Result.Err(error) => throw IllegalStateException(error.describe())
                case Result.Ok(value) => @Expect(value.bytes.isEmpty(), true); @Expect(value.eof, false)
            }
        } finally { fixture.close() }
    }

    @TestCase
    func outputReservationDoesNotResetAfterConsumerDrainsTheQueue(): Unit {
        let fixture = RawChannelFixture("output-cap", "while os.read(0, 1):\n    os.write(1, b'AB')", maxOutputBytes: 4)
        try {
            for (_ in 0..2) {
                @Expect(fixture.channel.write([1]).isOk(), true)
                @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stdout, 2)), "AB")
            }
            @Expect(fixture.channel.write([1]).isOk(), true)
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stdout).code, "process.channel_output_limit")
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stderr).code, "process.channel_output_limit")
        } finally { fixture.close() }
    }

    @TestCase
    func outputReservationIsSharedAcrossStdoutAndStderr(): Unit {
        let fixture = RawChannelFixture("shared-cap", "os.read(0, 1)\nos.write(1, b'AB')\n" +
            "os.write(2, b'CDE')\ntime.sleep(30)", maxOutputBytes: 4)
        try {
            @Expect(fixture.channel.write([1]).isOk(), true)
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stdout).code, "process.channel_output_limit")
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stderr).code, "process.channel_output_limit")
        } finally { fixture.close() }
    }

    @TestCase
    func stalledConsumerBackpressuresAtSameQueueBoundAndLaterDrainsExactBudgetedBytes(): Unit {
        let fixture = RawChannelFixture("queue-cap", "os.write(2,b'S')\n" +
            "os.write(1,b'X'*(3*1024*1024))\n(root/'emitted').write_text('done')\n" +
            "os.write(2,b'D')\ntime.sleep(30)", maxOutputBytes: 4194304)
        try {
            @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stderr, 1)), "S")
            sleep(Duration.millisecond * 250)
            @Expect(fixture.command.isAlive())
            @Expect(!exists(Path(fixture.root + "/emitted")))
            let pending = lifecycleTestRequire(fixture.channel.read(ProcessChannelStream.Stderr, 1, 25))
            @Expect(pending.bytes.isEmpty() && !pending.eof)
            let collected = ArrayList<Byte>()
            let deadline = MonoTime.now() + Duration.second * 3
            while (collected.size < 3145728 && MonoTime.now() < deadline) {
                let part = lifecycleTestRequire(fixture.channel.read(ProcessChannelStream.Stdout,
                    min(65536, 3145728 - collected.size), 25))
                collected.add(all: part.bytes)
                @Expect(!part.eof)
            }
            @Expect(rawChannelSameBytes(collected.toArray(), Array<Byte>(3145728, repeat: b'X')))
            @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stderr, 1)), "D")
            @Expect(exists(Path(fixture.root + "/emitted")))
            @Expect(fixture.channel.close().isOk())
            @Expect(fixture.releases.load(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func blockedOutputPumpUnblocksForCancellationDeadlineAndCloseWithoutEarlyRelease(): Unit {
        for (mode in ["cancel", "deadline", "close"]) {
            let fixture = RawChannelFixture("queue-stop-" + mode, "os.write(2,b'S')\n" +
                "os.write(1,b'X'*(3*1024*1024))\n(root/'emitted').write_text('done')\ntime.sleep(30)",
                maxOutputBytes: 4194304, timeoutMillis: if (mode == "deadline") { 750 } else { 10000 })
            try {
                @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stderr, 1)), "S")
                sleep(Duration.millisecond * 100)
                @Expect(fixture.command.isAlive())
                @Expect(!exists(Path(fixture.root + "/emitted")))
                @Expect(fixture.releases.load(), 0)
                let started = MonoTime.now()
                if (mode == "cancel") { let _ = fixture.source.cancel() }
                else if (mode == "deadline") { sleep(Duration.millisecond * 800) }
                if (mode != "close") {
                    @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stderr).code,
                        if (mode == "cancel") { "process.channel_cancelled" } else { "process.channel_deadline" })
                }
                @Expect(rawChannelAwaitUnit(RawChannelPending({ => fixture.channel.close() })).isOk())
                @Expect(MonoTime.now() - started < Duration.second * 3)
                @Expect(!fixture.command.isAlive())
                @Expect(fixture.releases.load(), 1)
                @Expect(fixture.channel.close().isOk())
                @Expect(fixture.releases.load(), 1)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func exitedLeaderRetainsCancellationAndDeadlineWhileOutputPumpIsBackpressured(): Unit {
        for (mode in ["cancel", "deadline"]) {
            let fixture = RawChannelFixture("exited-queue-" + mode, "child = os.fork()\n" +
                "if child == 0:\n    os.write(2,b'S')\n    os.write(1,b'X'*(3*1024*1024))\n" +
                "    (root/'emitted').write_text('done')\n    os._exit(0)\n" +
                "os.read(0,1)\nos._exit(0)", maxOutputBytes: 4194304,
                timeoutMillis: if (mode == "deadline") { 2500 } else { 10000 })
            try {
                @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stderr, 1)), "S")
                sleep(Duration.millisecond * 250)
                let bytes = lifecycleTestRequire(fixture.channel.receivedOutputBytes())
                @Expect(bytes > 0 && bytes < 3145728)
                sleep(Duration.millisecond * 100)
                @Expect(lifecycleTestRequire(fixture.channel.receivedOutputBytes()), bytes)
                @Expect(!exists(Path(fixture.root + "/emitted")))
                @Expect(fixture.channel.write("G".toArray()).isOk())
                let exitedBy = MonoTime.now() + Duration.second
                while (lifecycleTestRequire(fixture.channel.terminalStatus()).isNone() && MonoTime.now() < exitedBy) {
                    sleep(Duration.millisecond * 5)
                }
                @Expect(lifecycleTestRequire(fixture.channel.terminalStatus()), Some(Int64(0)))
                @Expect(fixture.releases.load(), 0)
                if (mode == "cancel") { let _ = fixture.source.cancel() }
                // Do not drain stdout: this is precisely the queue wait that
                // used to lose its monitor after the leader's natural exit.
                @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stderr).code,
                    if (mode == "cancel") { "process.channel_cancelled" } else { "process.channel_deadline" })
                @Expect(rawChannelAwaitUnit(RawChannelPending({ => fixture.channel.close() })).isOk())
                @Expect(fixture.releases.load(), 1)
                @Expect(!fixture.command.isAlive())
            } finally { fixture.close() }
        }
    }

    @TestCase
    func boundedPollAndInvalidArgumentsCannotWriteOrPretendEof(): Unit {
        let fixture = RawChannelFixture("bounds", "while True:\n" +
            "    value = os.read(0, 1024)\n    if not value: break\n    os.write(1, value)")
        try {
            let started = MonoTime.now()
            match (fixture.channel.read(ProcessChannelStream.Stdout, 1, 25)) {
                case Result.Err(error) => throw IllegalStateException(error.describe())
                case Result.Ok(value) => @Expect(value.bytes.isEmpty(), true); @Expect(value.eof, false)
            }
            @Expect(MonoTime.now() - started < Duration.second, true)
            for (size in [Int64(0), Int64(65537)]) {
                @Expect(rawChannelReadError(fixture.channel.read(ProcessChannelStream.Stdout, size, 0)), "process.channel_read_bounds")
            }
            for (wait in [Int64(-1), Int64(1001)]) {
                @Expect(rawChannelReadError(fixture.channel.read(ProcessChannelStream.Stderr, 1, wait)), "process.channel_read_bounds")
            }
            @Expect(rawChannelUnitError(fixture.channel.write([])), "process.channel_write_bounds")
            @Expect(rawChannelUnitError(fixture.channel.write(Array<Byte>(65537, repeat: 1))), "process.channel_write_bounds")
            @Expect(fixture.channel.write("R".toArray()).isOk(), true)
            @Expect(String.fromUtf8(rawChannelReadCount(fixture.channel, ProcessChannelStream.Stdout, 1)), "R")
        } finally { fixture.close() }
    }

    @TestCase
    func silentProcessDeadlineSettlesReadersAndClose(): Unit {
        let fixture = RawChannelFixture("deadline", "time.sleep(30)", timeoutMillis: 500)
        try {
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stdout).code, "process.channel_deadline")
            let started = MonoTime.now()
            @Expect(rawChannelAwaitUnit(RawChannelPending({ => fixture.channel.close() })).isOk(), true)
            @Expect(MonoTime.now() - started < Duration.second * 2, true)
            @Expect(fixture.releases.load(), 1)
            @Expect(exists(Path("/proc/" + fixture.command.pid.toString())), false)
            @Expect(rawChannelReadError(fixture.channel.read(ProcessChannelStream.Stdout, 1, 0)), "process.channel_deadline")
        } finally { fixture.close() }
    }

    @TestCase
    func cancellationUnblocksActuallyFullStdinWithoutWaitingForItsLock(): Unit {
        let fixture = RawChannelFixture("blocked-write", "time.sleep(30)",
            setup: "import fcntl\nfcntl.fcntl(0, fcntl.F_SETPIPE_SZ, 4096)")
        try {
            let pending = RawChannelPending({ => fixture.channel.write(Array<Byte>(65536, repeat: 7)) })
            let startedBy = MonoTime.now() + Duration.second
            while (!pending.started.load() && MonoTime.now() < startedBy) { sleep(Duration.millisecond) }
            @Expect(pending.started.load(), true)
            sleep(Duration.millisecond * 100)
            @Expect(pending.completed.load(), false)
            let started = MonoTime.now()
            let _ = fixture.source.cancel()
            @Expect(rawChannelAwaitUnit(pending).isOk(), false)
            @Expect(rawChannelAwaitError(fixture.channel, ProcessChannelStream.Stdout).code, "process.channel_cancelled")
            @Expect(rawChannelAwaitUnit(RawChannelPending({ => fixture.channel.close() })).isOk(), true)
            @Expect(MonoTime.now() - started < Duration.second * 2, true)
            @Expect(fixture.releases.load(), 1)
            @Expect(rawChannelReadError(fixture.channel.read(ProcessChannelStream.Stdout, 1, 0)), "process.channel_cancelled")
        } finally { fixture.close() }
    }

    @TestCase
    func abortAndConcurrentCloseReleaseOnceAndLeaveUnrelatedProcessAlive(): Unit {
        let fixture = RawChannelFixture("close-race", "time.sleep(30)")
        let unrelated = channel_process.startProcess(channel_process.ProcessCommand("/usr/bin/python3",
            arguments: ["-c", "import time; time.sleep(30)"], terminateProcessTree: true))
        try {
            let first = RawChannelPending({ => fixture.channel.close() })
            let second = RawChannelPending({ => fixture.channel.close() })
            let aborted = RawChannelPending({ => fixture.channel.abort() })
            @Expect(rawChannelAwaitUnit(first).isOk(), true)
            @Expect(rawChannelAwaitUnit(second).isOk(), true)
            @Expect(rawChannelAwaitUnit(aborted).isOk(), true)
            @Expect(fixture.releases.load(), 1)
            @Expect(fixture.channel.write([1]).isOk(), false)
            @Expect(unrelated.isAlive(), true)
            @Expect(exists(Path("/proc/" + fixture.command.pid.toString())), false)
        } finally {
            let _ = unrelated.close()
            fixture.close()
        }
    }

    @TestCase
    func exitedLeaderCannotLeaveEscapedDescendantHoldingEitherPipe(): Unit {
        let fixture = RawChannelFixture("escaped-pipe", "child = os.fork()\n" +
            "if child == 0:\n    os.setsid()\n    (root / 'descendant.pid').write_text(str(os.getpid()))\n" +
            "    while True:\n        (root / 'heartbeat').write_text(str(time.monotonic_ns()))\n        time.sleep(0.02)\n" +
            "while not (root / 'heartbeat').exists(): time.sleep(0.005)\nos._exit(0)")
        let unrelated = channel_process.startProcess(channel_process.ProcessCommand("/usr/bin/python3",
            arguments: ["-c", "import time; time.sleep(30)"], terminateProcessTree: true))
        try {
            rawChannelAwaitFile(fixture.root + "/descendant.pid")
            rawChannelAwaitFile(fixture.root + "/heartbeat")
            let descendant = String.fromUtf8(File.readFrom(fixture.root + "/descendant.pid")).trimAscii()
            @Expect(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout).isEmpty(), true)
            @Expect(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stderr).isEmpty(), true)
            let started = MonoTime.now()
            @Expect(rawChannelAwaitUnit(RawChannelPending({ => fixture.channel.close() })).isOk(), true)
            @Expect(MonoTime.now() - started < Duration.second * 2, true)
            let heartbeat = File.readFrom(fixture.root + "/heartbeat")
            sleep(Duration.millisecond * 150)
            @Expect(rawChannelSameBytes(heartbeat, File.readFrom(fixture.root + "/heartbeat")), true)
            let goneBy = MonoTime.now() + Duration.second
            while (exists(Path("/proc/" + descendant)) && MonoTime.now() < goneBy) { sleep(Duration.millisecond * 5) }
            @Expect(exists(Path("/proc/" + descendant)), false)
            @Expect(exists(Path("/proc/" + fixture.command.pid.toString())), false)
            @Expect(unrelated.isAlive(), true)
            @Expect(fixture.releases.load(), 1)
        } finally {
            let _ = unrelated.close()
            fixture.close()
        }
    }
}
