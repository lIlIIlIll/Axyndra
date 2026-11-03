package dap4cj

import process4cj.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func dapPreparedRequire<T>(result: DapResult<T>): T {
    match (result) { case DapResult.Ok(value) => value; case DapResult.Err(error) => throw error }
}
func dapPreparedCode<T>(result: DapResult<T>): String {
    match (result) { case DapResult.Ok(_) => "unexpected-success"; case DapResult.Err(error) => error.code }
}

@Test
class DapPreparedChannelTests {
    @TestCase
    func leaderOnlyFactoryRejectsBeforeAttemptingSpawn(): Unit {
        let result = DapClient.`spawn`(ProcessCommand("/definitely-not-a-protocol-executable",
            terminateProcessTree: false))
        @Expect(dapPreparedCode(result), "dap.channel_tree_required")
    }

    @TestCase
    func purePreparationRetainsSequenceAndActualExactAdapterBytes(): Unit {
        let channel = PreparedObservedChannel(dapFixtureScript()); let client = DapClient(channel)
        try {
            let arguments = jsonObject([JsonObjectEntry("expression", jsonString("frozen"))])
            let prepared = dapPreparedRequire(client.prepareRequest("host-run-call", "echo", arguments))
            let same = dapPreparedRequire(client.prepareRequest("host-run-call", "echo", arguments))
            @Expect(prepared.sequence, same.sequence)
            @Expect(channel.writes.load(), 0)
            @Expect(client.pendingCount(), 0)
            arguments.put("expression", jsonString("changed"))
            @Expect(dapPreparedCode(client.prepareRequest("host-run-call", "echo", arguments)), "dap.prepared_changed")
            let exported = prepared.framedBytes(); exported[0] = 0
            let response = dapPreparedRequire(client.dispatchPrepared(prepared, timeoutMillis: 1000))
            @Expect(response.field("expression").getOrThrow().text, "frozen")
            @Expect(channel.lastWrite(), String.fromUtf8(prepared.framedBytes()))
            @Expect(channel.writes.load(), 1)
            @Expect(dapPreparedCode(client.dispatchPrepared(prepared)), "dap.prepared_reused")
            @Expect(client.request("echo", jsonObject([]), timeoutMillis: 1000).isOk(), true)
            @Expect(channel.writes.load(), 2)
        } finally { let _ = client.close() }
    }

    @TestCase
    func foreignAndFailedDispatchNeverReuseReservedSequence(): Unit {
        let channel = PreparedObservedChannel(dapFixtureScript()); let client = DapClient(channel)
        let otherChannel = PreparedObservedChannel(dapFixtureScript()); let other = DapClient(otherChannel)
        try {
            let frozen = dapPreparedRequire(client.prepareRequest("frozen", "echo", jsonObject([])))
            @Expect(dapPreparedCode(other.dispatchPrepared(frozen)), "dap.prepared_foreign")
            @Expect(otherChannel.writes.load(), 0)
            channel.reject.store(true)
            @Expect(dapPreparedCode(client.dispatchPrepared(frozen)), "dap.write_failed")
            channel.reject.store(false)
            @Expect(dapPreparedCode(client.dispatchPrepared(frozen)), "dap.prepared_reused")
            @Expect(channel.writes.load(), 1)
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close(); let _ = other.close() }
    }

    @TestCase
    func deadlineClosesActualAdapterWithoutUnapprovedCancelRequest(): Unit {
        let channel = PreparedObservedChannel(dapFixtureScript()); let client = DapClient(channel)
        try {
            let frozen = dapPreparedRequire(client.prepareRequest("hang", "hang", jsonObject([])))
            @Expect(dapPreparedCode(client.dispatchPrepared(frozen, timeoutMillis: 30)), "dap.prepared_deadline")
            @Expect(channel.writes.load(), 1)
            @Expect(channel.lastWrite(), String.fromUtf8(frozen.framedBytes()))
            @Expect(client.pendingCount(), 0)
        } finally { let _ = client.close() }
    }

    @TestCase
    func failedCleanupCanBeRetriedWithoutReopeningTheAdapter(): Unit {
        let channel = PreparedObservedChannel(dapFixtureScript(), rejectFirstStop: true); let client = DapClient(channel)
        try {
            @Expect(dapPreparedCode(client.close()), "dap.cleanup_pending")
            @Expect(client.close().isOk(), true)
            @Expect(channel.stops.load(), 2)
            @Expect(client.close().isOk(), true)
            @Expect(channel.stops.load(), 2)
        } finally { let _ = client.close() }
    }
}

class PreparedObservedChannel <: ProcessDuplexChannel {
    private let delegate: ManagedProcessDuplexChannel
    private let lock = Mutex()
    private var last = ""
    let writes = AtomicInt64(0)
    let stops = AtomicInt64(0)
    let reject = AtomicBool(false)
    let rejectFirstStop: Bool
    init(script: String, rejectFirstStop!: Bool = false) {
        delegate = ManagedProcessDuplexChannel(startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", script])))
        this.rejectFirstStop = rejectFirstStop
    }
    public prop stdout: InputStream { get() { delegate.stdout } }
    public prop stderr: InputStream { get() { delegate.stderr } }
    public func write(bytes: Array<Byte>): Unit {
        writes.fetchAdd(1)
        lock.lock(); try { last = String.fromUtf8(bytes) } finally { lock.unlock() }
        if (reject.load()) { throw ProcessError(ProcessErrorKind.BrokenPipe, "callback-private-secret") }
        delegate.write(bytes)
    }
    func lastWrite(): String { lock.lock(); try { last } finally { lock.unlock() } }
    public func flush(): Unit { delegate.flush() }
    public func abort(): Unit { delegate.abort() }
    public func stop(gracefulShutdownMillis: Int64): Unit {
        let previous = stops.fetchAdd(1)
        if (rejectFirstStop && previous == 0) { throw IllegalStateException("callback-private-secret") }
        delegate.stop(gracefulShutdownMillis)
    }
    public func close(): Unit { delegate.close() }
}
