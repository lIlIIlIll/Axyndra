package agent_extension_runtime

import process4cj.*
import agent_sdk.*
import std.fs.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Only termination rejection / final native close are controlled. Spawn,
// streams, process identity, signalling and waits use a real native process.
class HostCleanupPlatform <: ProcessPlatformProcess {
    let inner: ProcessPlatformProcess
    let attempts = AtomicInt64(0)
    let closes = AtomicInt64(0)
    let closeEntered = AtomicBool(false)
    let allowClose = AtomicBool(false)
    let allowTermination = AtomicBool(false)
    let forceAccepted = AtomicBool(false)
    let rejectFirst: Bool
    let holdClose: Bool
    let throwFirst: Bool
    init(inner: ProcessPlatformProcess, rejectFirst: Bool, holdClose: Bool, throwFirst: Bool) {
        this.inner = inner; this.rejectFirst = rejectFirst; this.holdClose = holdClose; this.throwFirst = throwFirst
    }
    public prop pid: Int64 { get() { inner.pid } }
    public prop stdout: InputStream { get() { inner.stdout } }
    public prop stderr: InputStream { get() { inner.stderr } }
    public func writeInput(bytes: Array<Byte>): Unit { inner.writeInput(bytes) }
    public func flushInput(): Unit { inner.flushInput() }
    public func closeInput(): Unit { inner.closeInput() }
    public func inputCloseSupported(): Bool { inner.inputCloseSupported() }
    public func wait(): Int64 { inner.wait() }
    public func isAlive(): Bool { inner.isAlive() }
    public func terminate(force: Bool, tree: Bool): Bool {
        let count = attempts.fetchAdd(1)
        if (throwFirst && count == 0) { throw IllegalStateException("injected native termination failure") }
        if (rejectFirst && !allowTermination.load()) { return false }
        let accepted = inner.terminate(force, tree)
        if (force && accepted) { forceAccepted.store(true) }
        accepted
    }
    public func close(): Unit {
        closeEntered.store(true)
        while (holdClose && !allowClose.load()) { sleep(Duration.millisecond) }
        inner.close()
        let _ = closes.fetchAdd(1)
    }
}
class HostCleanupBackend <: ProcessBackend {
    var launched: ?HostCleanupPlatform = None
    let rejectFirst: Bool
    let holdClose: Bool
    let throwFirst: Bool
    init(rejectFirst!: Bool = false, holdClose!: Bool = false, throwFirst!: Bool = false) {
        this.rejectFirst = rejectFirst; this.holdClose = holdClose; this.throwFirst = throwFirst
    }
    public func launchProcess(command: ProcessCommand): ProcessPlatformProcess {
        let value = HostCleanupPlatform(LinuxProcessBackend().launchProcess(command), rejectFirst, holdClose, throwFirst)
        launched = Some(value)
        value
    }
    func emergencyRelease(): Unit {
        match (launched) {
            case Some(value) =>
                value.allowClose.store(true)
                value.allowTermination.store(true)
                let _ = value.inner.terminate(true, true)
            case None => ()
        }
    }
}
class HostCleanupFixtureLauncher <: JavaScriptHostProcessLauncher {
    let backend: HostCleanupBackend
    init(backend: HostCleanupBackend) { this.backend = backend }
    public func launch(command: ProcessCommand): JavaScriptHostResult<ManagedProcess> {
        JavaScriptHostResult.Ok(startProcess(command, backend: backend))
    }
}
func hostCleanupOwner(child: ManagedProcess): JavaScriptExtensionHost {
    // Direct construction isolates cleanup from the unrelated handshake. The
    // Product endpoint suite separately exercises the real C wire protocol.
    JavaScriptExtensionHost(JavaScriptHostLaunchRequest("/tmp", "cleanup.js",
        extensionId: "cleanup-contract", extensionVersion: "1.0.0"), child, [], [], [], None)
}
func cleanupCode(value: JavaScriptHostResult<Unit>): String {
    match (value) { case JavaScriptHostResult.Ok(_) => "ok"; case JavaScriptHostResult.Err(error) => error.code }
}

@Test
class JavaScriptHostOwnedCleanupTests {
    @TestCase
    func failedHandshakeReturnsRetainedOwnerAndRetriesWithoutAnotherCaller(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        File.writeTo(root + "/worker", ("#!/usr/bin/python3\nimport sys,time\n" +
            "sys.stdin.readline()\nprint('{\"type\":\"broken\"}',flush=True)\ntime.sleep(30)\n").toArray())
        let _ = FileInfo(root + "/worker").setExecutable(true)
        let backend = HostCleanupBackend(rejectFirst: true)
        var cleanup: ?JavaScriptExtensionHost = None
        try {
            match (startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(root, "worker",
                profile: JavaScriptHostLaunchProfile.NativeExecutable,
                extensionId: "failed-cleanup", extensionVersion: "1.0.0",
                contributions: [PluginContributionDefinition("session", PluginContributionKind.Service)]),
                HostCleanupFixtureLauncher(backend))) {
                case JavaScriptHostResult.Ok(value) => cleanup = Some(value); throw IllegalStateException("invalid handshake succeeded")
                case JavaScriptHostResult.Err(error) =>
                    @Expect(error.code, "extension.handshake_invalid")
                    cleanup = error.cleanupHost
            }
            let owner = cleanup.getOrThrow()
            @Expect(owner.isClosed, true)
            @Expect(owner.cleanupComplete, false)
            @Expect(backend.launched.getOrThrow().isAlive(), true)
            backend.launched.getOrThrow().allowTermination.store(true)
            let deadline = MonoTime.now() + Duration.second * 3
            // No additional close/requestAbort: the existing task owns retry.
            while (!owner.cleanupComplete && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(owner.cleanupComplete, true)
            @Expect(backend.launched.getOrThrow().closes.load(), 1)
        } finally {
            backend.emergencyRelease()
            match (cleanup) { case Some(value) => let _ = value.awaitCleanup(timeoutMillis: 2000); case None => () }
            remove(root, recursive: true)
        }
    }

    @TestCase
    func rejectedSignalsRetainProcessAndOwnedRetryReclaimsExactlyOnce(): Unit {
        let backend = HostCleanupBackend(rejectFirst: true)
        let child = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        let host = hostCleanupOwner(child)
        try {
            @Expect(cleanupCode(host.awaitCleanup(timeoutMillis: 500)), "extension.cleanup_failed")
            @Expect(host.isClosed, true)
            @Expect(host.cleanupComplete, false)
            @Expect(child.isAlive(), true)
            @Expect(child.terminationRequested(force: true), false)
            @Expect(backend.launched.getOrThrow().closes.load(), 0)
            backend.launched.getOrThrow().allowTermination.store(true)
            @Expect(cleanupCode(host.awaitCleanup(timeoutMillis: 2000)), "ok")
            @Expect(host.cleanupComplete, true)
            @Expect(backend.launched.getOrThrow().attempts.load() >= 2, true)
            @Expect(backend.launched.getOrThrow().closes.load(), 1)
            @Expect(cleanupCode(host.awaitCleanup(timeoutMillis: 0)), "ok")
            @Expect(backend.launched.getOrThrow().closes.load(), 1)
        } finally { backend.emergencyRelease(); let _ = host.awaitCleanup(timeoutMillis: 2000) }
    }

    @TestCase
    func acceptedSignalAndExitedLeaderDoNotAcknowledgeBlockedNativeClose(): Unit {
        let backend = HostCleanupBackend(holdClose: true)
        let child = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        let host = hostCleanupOwner(child)
        try {
            let started = MonoTime.now()
            @Expect(cleanupCode(host.awaitCleanup(timeoutMillis: 100)), "extension.cleanup_pending")
            @Expect((MonoTime.now() - started).toMilliseconds() < 1000, true)
            let closeDeadline = MonoTime.now() + Duration.second * 2
            while (!backend.launched.getOrThrow().closeEntered.load() && MonoTime.now() < closeDeadline) {
                sleep(Duration.millisecond)
            }
            // ManagedProcess.close holds its termination lock while this
            // fixture deliberately gates platform.close. Observe the actual
            // backend acknowledgement without blocking the gate's owner.
            @Expect(backend.launched.getOrThrow().forceAccepted.load(), true)
            @Expect(child.tryExit().isSome(), true)
            @Expect(backend.launched.getOrThrow().closeEntered.load(), true)
            @Expect(host.cleanupComplete, false)
            backend.launched.getOrThrow().allowClose.store(true)
            @Expect(cleanupCode(host.awaitCleanup(timeoutMillis: 2000)), "ok")
            @Expect(host.cleanupComplete, true)
            @Expect(backend.launched.getOrThrow().closes.load(), 1)
        } finally { backend.emergencyRelease(); let _ = host.awaitCleanup(timeoutMillis: 2000) }
    }

    @TestCase
    func abortBreaksRealFullStdinWithoutWriterLockOrUnrelatedSignal(): Unit {
        let unrelated = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]))
        let child = startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c",
            "import fcntl,os,time; fcntl.fcntl(0,fcntl.F_SETPIPE_SZ,4096); print('ready',flush=True); time.sleep(30)"]))
        let host = hostCleanupOwner(child)
        let started = AtomicBool(false)
        let finished = AtomicBool(false)
        var writer: ?Future<Unit> = None
        try {
            @Expect(readLineBounded(child.stdout, 64).getOrThrow(), "ready")
            writer = Some(spawn {
                started.store(true)
                try { child.writeStdin(Array<Byte>(1048576, repeat: b'x')) }
                catch (_: Exception) {}
                finally { finished.store(true) }
            })
            let deadline = MonoTime.now() + Duration.second
            while (!started.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            sleep(Duration.millisecond * 25)
            @Expect(started.load() && !finished.load(), true)
            let began = MonoTime.now()
            host.requestAbort()
            @Expect((MonoTime.now() - began).toMilliseconds() < 500, true)
            @Expect(cleanupCode(host.awaitCleanup(timeoutMillis: 2000)), "ok")
            writer.getOrThrow().get()
            @Expect(finished.load(), true)
            @Expect(child.tryExit().isSome(), true)
            @Expect(unrelated.isAlive(), true)
        } finally {
            host.requestAbort()
            let _ = host.awaitCleanup(timeoutMillis: 2000)
            try { match (writer) { case Some(value) => value.get(); case None => () } }
            finally { let _ = unrelated.close() }
        }
    }

    @TestCase
    func gracefulCloseSignalExceptionStillReapsTheOwnedNativeProcess(): Unit {
        let backend = HostCleanupBackend(throwFirst: true)
        let child = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        let host = hostCleanupOwner(child)
        try {
            // Before the fix, this threw after marking the host closed and
            // never started cleanup. No extra caller requests teardown here.
            host.close()
            let deadline = MonoTime.now() + Duration.second * 3
            while (!host.cleanupComplete && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(host.isClosed && host.cleanupComplete, true)
            @Expect(child.tryExit().isSome(), true)
            @Expect(backend.launched.getOrThrow().attempts.load() >= 2, true)
            @Expect(backend.launched.getOrThrow().closes.load(), 1)
        } finally { backend.emergencyRelease(); let _ = host.awaitCleanup(timeoutMillis: 2000) }
    }

    @TestCase
    func cancellationSignalExceptionStillReapsWithoutAnotherCancelCaller(): Unit {
        let backend = HostCleanupBackend(throwFirst: true)
        let child = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        let host = hostCleanupOwner(child)
        try {
            host.closeForCancellation(CancellationCause(CancellationKind.Explicit,
                "test.cancel", "stop the actual owned process"))
            let deadline = MonoTime.now() + Duration.second * 3
            while (!host.cleanupComplete && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(host.isClosed && host.cleanupComplete, true)
            @Expect(child.tryExit().isSome(), true)
            @Expect(backend.launched.getOrThrow().attempts.load() >= 2, true)
            @Expect(backend.launched.getOrThrow().closes.load(), 1)
        } finally { backend.emergencyRelease(); let _ = host.awaitCleanup(timeoutMillis: 2000) }
    }

}
