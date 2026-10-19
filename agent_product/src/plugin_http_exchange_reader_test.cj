package agent_product

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Deterministic byte-owner tests, not evidence of a real curl/gateway launch.
class HttpExchangeReaderFixtureChannel <: ProcessChannel {
    private let chunks: Array<Array<Byte>>
    private let keepOpen: Bool
    private var index: Int64 = 0
    var aborted: Int64 = 0
    var closes: Int64 = 0
    var pendingClose = false
    var exitCode: Int64 = 0
    var statusPending = false
    init(chunks: Array<Array<Byte>>, keepOpen!: Bool = false) {
        this.chunks = chunks.map { value => value.clone() }; this.keepOpen = keepOpen
    }
    public func read(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        let _ = waitMillis
        match (stream) { case ProcessChannelStream.Stderr => return Result.Ok(ProcessChannelRead("private stderr".toArray(),
            !keepOpen && index >= chunks.size)); case _ => () }
        if (aborted > 0) { return Result.Err(httpExchangeReadFailure()) }
        if (index >= chunks.size) { return Result.Ok(ProcessChannelRead([], !keepOpen)) }
        let value = chunks[index].clone(); index += 1
        if (value.size > maxBytes) { throw IllegalStateException("fixture chunk exceeds requested limit") }
        Result.Ok(ProcessChannelRead(value, !keepOpen && index == chunks.size))
    }
    public func write(_: Array<Byte>): Result<Unit> { throw IllegalStateException("response reader cannot write") }
    public func abort(): Result<Unit> { aborted += 1; Result.Ok(()) }
    public func terminalStatus(): Result<?Int64> {
        if (aborted > 0) { return Result.Err(httpExchangeReadFailure()) }
        Result.Ok(if (!keepOpen && index >= chunks.size && !statusPending) { Some(exitCode) } else { None })
    }
    public func close(): Result<Unit> {
        closes += 1
        if (pendingClose) { Result.Err(httpExchangeReadFailure()) } else { Result.Ok(()) }
    }
}

@Test
class PluginHttpExchangeReaderTests {
    @TestCase
    func metadataAndBinaryBodyAreSeparateAndOnlyCloseAcknowledgesResources(): Unit {
        let channel = HttpExchangeReaderFixtureChannel([
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n".toArray(),
            "Content-Length: 3\r\nSet-Cookie: private-stderr-secret\r\n\r\n".toArray(), [0u8, 255u8, 1u8]])
        let caller = CancellationSource()
        let owner = ProductHttpExchangeReader(channel, caller.token, ["private-stderr-secret"])
        try {
            @Expect(lifecycleTestRequire(owner.pollHead(waitMillis: 0)).isNone())
            let head = lifecycleTestRequire(owner.pollHead(waitMillis: 0)).getOrThrow()
            @Expect(head.status, 200)
            @Expect(head.bodySize.getOrThrow(), 3)
            @Expect(!owner.closeAcknowledged())
            let first = lifecycleTestRequire(owner.readBody(2, waitMillis: 0))
            @Expect(first.bytes, [0u8, 255u8]); @Expect(!first.eof)
            let last = lifecycleTestRequire(owner.readBody(2, waitMillis: 0))
            @Expect(last.bytes, [1u8]); @Expect(last.eof)
            @Expect(!owner.closeAcknowledged())
            @Expect(owner.close().isOk()); @Expect(owner.closeAcknowledged())
            @Expect(owner.close().isOk()); @Expect(channel.closes, 1)
            @Expect(owner.readBody(2).isError())
        } finally { let _ = owner.close(); caller.close() }
    }

    @TestCase
    func openEventResponseCanBeConsumedAndExplicitlyClosedBeforeRemoteEof(): Unit {
        let body = "data: {\"id\":1,\"result\":{}}\n\n"
        let channel = HttpExchangeReaderFixtureChannel([
            "HTTP/2 200\r\nContent-Type: text/event-stream\r\n\r\n".toArray(), body.toArray()], keepOpen: true)
        let caller = CancellationSource()
        let owner = ProductHttpExchangeReader(channel, caller.token, ["secret-value"])
        try {
            @Expect(lifecycleTestRequire(owner.pollHead()).getOrThrow().contentType, "text/event-stream")
            let response = lifecycleTestRequire(owner.readBody(16384))
            @Expect(response.bytes, body.toArray()); @Expect(!response.eof)
            @Expect(!owner.closeAcknowledged())
            @Expect(owner.close().isOk()); @Expect(owner.closeAcknowledged())
            @Expect(channel.aborted, 1)
            @Expect(owner.pollHead().isError())
        } finally { let _ = owner.close(); caller.close() }
    }

    @TestCase
    func bodyAndMetadataReflectionAbortWithoutReflectingPrivateBytes(): Unit {
        for (metadata in [false, true]) {
            let chunks = if (metadata) { ["HTTP/1.1 200 OK\r\nContent-Type: secret-value\r\n\r\n".toArray()] }
                else { ["HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".toArray(),
                    "secret-".toArray(), "value".toArray()] }
            let channel = HttpExchangeReaderFixtureChannel(chunks, keepOpen: true)
            let caller = CancellationSource()
            let owner = ProductHttpExchangeReader(channel, caller.token, ["secret-value"])
            try {
                let error = if (metadata) { owner.pollHead().error().getOrThrow() } else {
                    @Expect(lifecycleTestRequire(owner.pollHead()).isSome())
                    @Expect(lifecycleTestRequire(owner.readBody(16384)).bytes.isEmpty())
                    owner.readBody(16384).error().getOrThrow()
                }
                @Expect(error.kind, AgentErrorKind.RecoveryRequired)
                @Expect(!error.describe().contains("secret-value"))
                @Expect(channel.aborted > 0)
                @Expect(!owner.closeAcknowledged())
                @Expect(owner.close().isOk())
            } finally { let _ = owner.close(); caller.close() }
        }
    }

    @TestCase
    func eofMismatchCancellationAndPendingCleanupRemainDistinct(): Unit {
        let channel = HttpExchangeReaderFixtureChannel([
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".toArray(), "abc".toArray()])
        let caller = CancellationSource()
        let owner = ProductHttpExchangeReader(channel, caller.token, [])
        try {
            @Expect(lifecycleTestRequire(owner.pollHead()).isSome())
            @Expect(owner.readBody(16384).error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
            channel.pendingClose = true
            @Expect(owner.close().error().getOrThrow().code, "http.exchange_cleanup_pending")
            @Expect(!owner.closeAcknowledged())
            channel.pendingClose = false
            @Expect(owner.close().isOk()); @Expect(owner.closeAcknowledged()); @Expect(channel.closes, 2)
        } finally { let _ = owner.close(); caller.close() }

        let active = HttpExchangeReaderFixtureChannel([], keepOpen: true)
        let cancelled = CancellationSource()
        let second = ProductHttpExchangeReader(active, cancelled.token, [])
        try {
            let _ = cancelled.cancel()
            @Expect(second.pollHead().error().getOrThrow().kind, AgentErrorKind.Cancelled)
            @Expect(!second.closeAcknowledged())
            @Expect(second.close().isOk())
        } finally { let _ = second.close(); cancelled.close() }
    }

    @TestCase
    func unknownLengthEofNeedsVerifiedZeroExitAndNeverInventsCleanupAck(): Unit {
        for (code in [0, 18]) {
            let channel = HttpExchangeReaderFixtureChannel([
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".toArray(), "{}".toArray()])
            channel.exitCode = code; channel.statusPending = true
            let caller = CancellationSource()
            let owner = ProductHttpExchangeReader(channel, caller.token, [])
            try {
                @Expect(lifecycleTestRequire(owner.pollHead()).isSome())
                let partial = lifecycleTestRequire(owner.readBody(16384))
                @Expect(partial.bytes, "{}".toArray()); @Expect(!partial.eof)
                @Expect(!lifecycleTestRequire(owner.readBody(16384)).eof)
                channel.statusPending = false
                let terminal = owner.readBody(16384)
                if (code == 0) { @Expect(lifecycleTestRequire(terminal).eof) }
                else { @Expect(terminal.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired) }
                @Expect(!owner.closeAcknowledged())
                @Expect(owner.close().isOk())
            } finally { let _ = owner.close(); caller.close() }
        }
    }

    @TestCase
    func lazyDeadlineCallbackCanCloseTheReaderWithoutReenteringItsStateLock(): Unit {
        let channel = HttpExchangeReaderFixtureChannel([], keepOpen: true)
        let deadline = agentUtcMillis() + 1000
        let caller = CancellationSource(deadlineMillis: deadline)
        let owner = ProductHttpExchangeReader(channel, caller.token, [])
        let invoked = AtomicBool(false)
        let registration = caller.token.onCancel({ _ =>
            let _ = owner.close(); invoked.store(true)
        })
        try {
            @Expect(!invoked.load())
            while (agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
            // Reading this marker does not poll the token. The expired
            // deadline must first invoke its callback from pollHead below.
            @Expect(!invoked.load())
            @Expect(owner.pollHead().error().getOrThrow().kind, AgentErrorKind.Cancelled)
            @Expect(invoked.load()); @Expect(owner.closeAcknowledged())
        } finally { registration.dispose(); let _ = owner.close(); caller.close() }
    }
}
