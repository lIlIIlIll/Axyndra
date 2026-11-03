package process4cj

import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Only termination is fault-injected. Launch, stdio, wait, liveness and close
// use the real native backend and an actual owned subprocess/supervisor.
class TerminationFaultPlatform <: ProcessPlatformProcess {
    let inner: ProcessPlatformProcess
    let attempts = AtomicInt64(0)
    let forcedAttempts = AtomicInt64(0)
    private let lock = Mutex()
    private var remaining: Int64 = 1
    private let throwsFirst: Bool
    private let forcedOnly: Bool

    init(inner: ProcessPlatformProcess, throwsFirst: Bool, forcedOnly: Bool) {
        this.inner = inner; this.throwsFirst = throwsFirst; this.forcedOnly = forcedOnly
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
        let _ = attempts.fetchAdd(1)
        if (force) { let _ = forcedAttempts.fetchAdd(1) }
        var reject = false
        lock.lock()
        try {
            if (remaining > 0 && (!forcedOnly || force)) { remaining -= 1; reject = true }
        } finally { lock.unlock() }
        if (reject) {
            if (throwsFirst) { throw ProcessError(ProcessErrorKind.Io, "injected termination failure before signal") }
            return false
        }
        inner.terminate(force, processTree)
    }
    func emergencyCleanup(): Unit { let _ = inner.terminate(true, true) }
}

class TerminationFaultBackend <: ProcessBackend {
    private let throwsFirst: Bool
    private let forcedOnly: Bool
    var launched: ?TerminationFaultPlatform = None
    init(throwsFirst!: Bool = false, forcedOnly!: Bool = true) {
        this.throwsFirst = throwsFirst; this.forcedOnly = forcedOnly
    }
    public func launchProcess(command: ProcessCommand): ProcessPlatformProcess {
        let platform = TerminationFaultPlatform(LinuxProcessBackend().launchProcess(command), throwsFirst, forcedOnly)
        launched = Some(platform)
        platform
    }
    func cleanup(): Unit {
        match (launched) { case Some(value) => value.emergencyCleanup(); case None => () }
    }
}

func terminationRequireAccepted(process: ManagedProcess): Unit {
    if (!process.terminate(force: true)) {
        throw IllegalStateException("retry did not reach the native termination backend")
    }
}

@Test
class ManagedProcessTerminationRetryTests {
    @TestCase
    func rejectedForcedSignalDoesNotSuppressRealRetryOrInventAcknowledgement() {
        let backend = TerminationFaultBackend()
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        try {
            @Expect(process.terminationRequested(force: true), false)
            @Expect(process.terminate(force: true), false)
            @Expect(process.terminationRequested(force: true), false)
            @Expect(process.isAlive(), true)
            terminationRequireAccepted(process)
            @Expect(process.terminationRequested(force: true), true)
            @Expect(process.terminationRequested(), true)
            @Expect(process.terminate(force: true), false)
            @Expect(backend.launched.getOrThrow().forcedAttempts.load(), 2)
            @Expect(process.wait().code != 0, true)
            @Expect(process.close(), true)
            @Expect(process.close(), false)
        } finally { backend.cleanup(); let _ = process.close() }
    }

    @TestCase
    func throwingTerminationLeavesAcceptedLevelUnchangedAndRetriesNativeKill() {
        let backend = TerminationFaultBackend(throwsFirst: true)
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        try {
            var threw = false
            try { let _ = process.terminate(force: true) }
            catch (_: ProcessError) { threw = true }
            @Expect(threw, true)
            @Expect(process.terminationRequested(force: true), false)
            @Expect(process.isAlive(), true)
            terminationRequireAccepted(process)
            @Expect(backend.launched.getOrThrow().forcedAttempts.load(), 2)
            @Expect(process.wait().code != 0, true)
            @Expect(process.close(), true)
        } finally { backend.cleanup(); let _ = process.close() }
    }

    @TestCase
    func rejectedForcedEscalationRetainsOnlyAcceptedGracefulLevel() {
        let backend = TerminationFaultBackend()
        let process = startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c",
            "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(30)"]), backend: backend)
        try {
            let ready = Array<Byte>(6, repeat: 0)
            var offset: Int64 = 0
            while (offset < ready.size) {
                let part = Array<Byte>(ready.size - offset, repeat: 0)
                let count = process.stdout.read(part)
                if (count == 0) { throw IllegalStateException("signal fixture exited before ready") }
                for (index in 0..count) { ready[offset + index] = part[index] }
                offset += count
            }
            @Expect(String.fromUtf8(ready), "ready\n")
            @Expect(process.terminate(), true)
            @Expect(process.terminationRequested(), true)
            @Expect(process.terminationRequested(force: true), false)
            @Expect(process.terminate(force: true), false)
            @Expect(process.terminationRequested(force: true), false)
            @Expect(process.terminationRequested(), true)
            @Expect(process.isAlive(), true)
            terminationRequireAccepted(process)
            @Expect(process.terminationRequested(force: true), true)
            @Expect(backend.launched.getOrThrow().attempts.load(), 3)
            @Expect(process.wait().code != 0, true)
            @Expect(process.close(), true)
        } finally { backend.cleanup(); let _ = process.close() }
    }

    @TestCase
    func rejectedGracefulAttemptDoesNotConsumeTheGracefulIdempotenceSlot() {
        let backend = TerminationFaultBackend(forcedOnly: false)
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        try {
            @Expect(process.terminate(), false)
            @Expect(process.terminationRequested(), false)
            @Expect(process.isAlive(), true)
            let accepted = process.terminate()
            @Expect(accepted, true)
            if (!accepted) { throw IllegalStateException("rejected TERM poisoned retry") }
            @Expect(process.terminationRequested(), true)
            @Expect(process.terminate(), false)
            @Expect(backend.launched.getOrThrow().attempts.load(), 2)
            @Expect(process.wait().code != 0, true)
            @Expect(process.close(), true)
        } finally { backend.cleanup(); let _ = process.close() }
    }
}
