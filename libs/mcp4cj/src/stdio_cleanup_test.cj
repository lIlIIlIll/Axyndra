package mcp4cj

import process4cj.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

class RetainedMcpCleanupChannel <: McpStdioChannel {
    let child: ManagedProcess
    private let delegate: ManagedProcessMcpStdioChannel
    let allowStop = AtomicBool(false)
    let stopEntered = AtomicBool(false)
    let stopCalls = AtomicInt64(0)
    let closeCalls = AtomicInt64(0)
    let released = AtomicBool(false)
    let gateStop: Bool
    let failFirstRelease: Bool
    init(gateStop!: Bool = false, failFirstRelease!: Bool = false) {
        child = startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", "import time; time.sleep(30)"]))
        delegate = ManagedProcessMcpStdioChannel(child)
        this.gateStop = gateStop; this.failFirstRelease = failFirstRelease
    }
    public prop stdout: InputStream { get() { delegate.stdout } }
    public prop stderr: InputStream { get() { delegate.stderr } }
    public func write(bytes: Array<Byte>): Unit { delegate.write(bytes) }
    public func flush(): Unit { delegate.flush() }
    public func abort(): Unit { delegate.abort() }
    public func stop(gracefulShutdownMillis: Int64): Unit {
        let _ = stopCalls.fetchAdd(1)
        stopEntered.store(true)
        if (gateStop) {
            let deadline = MonoTime.now() + Duration.second * 10
            while (!allowStop.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            if (!allowStop.load()) { throw IllegalStateException("fixture cleanup gate expired") }
        }
        delegate.stop(gracefulShutdownMillis)
    }
    public func close(): Unit {
        let previous = closeCalls.fetchAdd(1)
        if (previous == 0 && failFirstRelease) { throw IllegalStateException("private-fixture-release-secret") }
        delegate.close()
        released.store(true)
    }
}

func retainedMcpTransport(channel: RetainedMcpCleanupChannel): StdioMcpTransport {
    match (attachStdioMcpTransport(channel, framing: McpFramingConfig(gracefulShutdownMillis: 20))) {
        case McpResult.Ok(value) => value
        case McpResult.Err(error) => throw error
    }
}

@Test
class McpOwnedCleanupTests {
    @TestCase
    func failedReleaseRemainsStoppingAndActuallyRetriesItsOwnedChannel(): Unit {
        let channel = RetainedMcpCleanupChannel(failFirstRelease: true)
        let transport = retainedMcpTransport(channel)
        let unrelated = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]))
        try {
            expectStdioError(transport.close(), "mcp.stdio_close_failed")
            @Expect(channel.child.isAlive(), false)
            @Expect(channel.released.load(), false)
            @Expect(transport.state() == McpLifecycleState.Stopping)
            @Expect(channel.closeCalls.load(), 1)
            @Expect(unrelated.isAlive())
            @Expect(transport.close().isOk())
            @Expect(channel.closeCalls.load(), 2)
            @Expect(channel.released.load())
            @Expect(transport.state() == McpLifecycleState.Stopped)
            @Expect(transport.close().isOk())
            @Expect(channel.closeCalls.load(), 2)
            @Expect(unrelated.isAlive())
        } finally {
            channel.abort()
            let _ = transport.close()
            let _ = unrelated.terminate(force: true)
            let _ = unrelated.wait()
            let _ = unrelated.close()
        }
    }

    @TestCase
    func blockedStopReturnsPendingAndKeepsOneCleanupTaskUntilActualCompletion(): Unit {
        let channel = RetainedMcpCleanupChannel(gateStop: true)
        let transport = retainedMcpTransport(channel)
        try {
            let before = MonoTime.now()
            expectStdioError(transport.close(), "mcp.stdio_close_pending")
            @Expect(MonoTime.now() < before + Duration.second * 3)
            @Expect(channel.stopEntered.load())
            @Expect(channel.stopCalls.load(), 1)
            @Expect(channel.closeCalls.load(), 0)
            @Expect(channel.child.isAlive())
            @Expect(transport.state() == McpLifecycleState.Stopping)
            channel.allowStop.store(true)
            @Expect(transport.close().isOk())
            @Expect(channel.stopCalls.load(), 1)
            @Expect(channel.closeCalls.load(), 1)
            @Expect(channel.released.load())
            @Expect(channel.child.isAlive(), false)
            @Expect(transport.state() == McpLifecycleState.Stopped)
        } finally {
            channel.allowStop.store(true)
            channel.abort()
            let _ = transport.close()
        }
    }
}
