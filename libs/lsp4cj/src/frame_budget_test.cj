package lsp4cj

import process4cj.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ObservedLspFrameBudget <: ProtocolFrameBudget {
    let active = AtomicInt64(0)
    let decoded = AtomicInt64(0)
    let released = AtomicInt64(0)
    let rejectDecode: Bool
    let refuseFirstRelease = AtomicBool(false)
    init(rejectDecode!: Bool = false, refuseFirstRelease!: Bool = false) {
        this.rejectDecode = rejectDecode; this.refuseFirstRelease.store(refuseFirstRelease)
    }
    public func reserve(bytes: Int64): ProtocolFrameReservation {
        if (bytes < 0 || bytes > 4194304) { throw IllegalStateException("private budget rejected") }
        active.fetchAdd(1)
        ObservedLspFrameReservation(this)
    }
}
class ObservedLspFrameReservation <: ProtocolFrameReservation {
    let owner: ObservedLspFrameBudget
    let lock = Mutex()
    var closed = false
    init(owner: ObservedLspFrameBudget) { this.owner = owner }
    public func beforeDecode(bytes: Array<Byte>): Unit {
        owner.decoded.fetchAdd(1)
        if (owner.rejectDecode) { throw IllegalStateException("private budget rejected") }
    }
    public func close(): Unit {
        lock.lock()
        try {
            if (closed) { return }
            if (owner.refuseFirstRelease.load()) { owner.refuseFirstRelease.store(false); throw IllegalStateException("private cleanup text") }
            closed = true; owner.active.fetchAdd(-1); owner.released.fetchAdd(1)
        } finally { lock.unlock() }
    }
}
func malformedLspPeer(bytesLiteral: String): String {
    "import sys\nr=sys.stdin.buffer\nh={}\nwhile True:\n l=r.readline()\n if l==b'\\r\\n': break\n k,v=l.split(b':',1);h[k.lower()]=v.strip()\nr.read(int(h[b'content-length']))\nsys.stdout.buffer.write(" + bytesLiteral + ");sys.stdout.buffer.flush()\nsys.stdin.buffer.read()\n"
}

@Test
class LspFrameBudgetTests {
    @TestCase
    func refusedConsumerReleaseRetainsOwnershipUntilAcknowledged(): Unit {
        let budget = ObservedLspFrameBudget(refuseFirstRelease: true)
        let client = LspClient(PreparedObservedChannel(preparedLspScript()), frameBudget: Some(budget))
        try {
            let _ = lspPreparedRequire(client.request("echo", jsonObject([]), timeoutMillis: 1000))
            var rejected = false
            try { client.releaseConsumedResponses() }
            catch (error: Exception) { rejected = true; @Expect(!error.message.contains("private")) }
            @Expect(rejected, true); @Expect(budget.active.load(), 1)
            client.releaseConsumedResponses()
            @Expect(budget.active.load(), 0); @Expect(budget.released.load(), 1)
        } finally { let _ = client.close() }
    }
    @TestCase
    func realResponseRetainsDecodedFrameUntilConsumerAcknowledges(): Unit {
        let budget = ObservedLspFrameBudget()
        let channel = PreparedObservedChannel(preparedLspScript())
        let client = LspClient(channel, frameBudget: Some(budget))
        try {
            let input = parseUnifiedJson("{\"value\":\"actual response\"}")
            let value = lspPreparedRequire(client.request("echo", input, timeoutMillis: 1000))
            @Expect(value.field("params").getOrThrow().field("value").getOrThrow().text, "actual response")
            @Expect(budget.active.load(), 1)
            @Expect(budget.decoded.load(), 1)
            client.releaseConsumedResponses()
            @Expect(budget.active.load(), 0)
            client.releaseConsumedResponses()
            @Expect(budget.released.load(), 1)
        } finally { let _ = client.close() }
        @Expect(budget.active.load(), 0)
    }

    @TestCase
    func notificationsReleaseAfterCallbackWhileResponseRemainsCharged(): Unit {
        let budget = ObservedLspFrameBudget(); let called = AtomicBool(false)
        let channel = PreparedObservedChannel(preparedLspScript())
        let client = LspClient(channel, frameBudget: Some(budget),
            notificationHandler: { _, value => called.store(value.field("uri").getOrThrow().text == "file:///a") })
        try {
            let notification = LspNotification("textDocument/didOpen", parseUnifiedJson("{\"textDocument\":{\"uri\":\"file:///a\",\"version\":1,\"text\":\"v\"}}"))
            let request = lspPreparedRequire(client.prepareRequest("owned", "echo", jsonObject([]), notifications: [notification]))
            let _ = lspPreparedRequire(client.dispatchPrepared(request, timeoutMillis: 1000))
            @Expect(called.load(), true)
            @Expect(budget.decoded.load(), 2)
            @Expect(budget.active.load(), 1)
            @Expect(budget.released.load(), 1)
        } finally { let _ = client.close() }
        @Expect(budget.active.load(), 0)
        @Expect(budget.released.load(), 2)
    }

    @TestCase
    func decoderReservationFailureIsTypedAndReleasesRawFrame(): Unit {
        let budget = ObservedLspFrameBudget(rejectDecode: true)
        let client = LspClient(PreparedObservedChannel(preparedLspScript()), frameBudget: Some(budget))
        try {
            let result = client.request("echo", jsonObject([]), timeoutMillis: 1000)
            @Expect(lspPreparedCode(result), "lsp.frame_budget_exceeded")
            match (result) { case LspResult.Err(error) => @Expect(!error.message.contains("private")); case _ => @Expect(false) }
        } finally { let _ = client.close() }
        @Expect(budget.active.load(), 0)
        @Expect(budget.released.load(), 1)
    }

    @TestCase
    func malformedFramesKeepLegacyTypedCodesAndReleaseReservations(): Unit {
        for ((wire, expected) in [
            ("b'Content-Length: nope\\r\\n\\r\\n'", "lsp.frame_invalid"),
            ("b'Content-Length: 1\\r\\n\\r\\n{'", "lsp.json_invalid"),
            ("b'Content-Length: 1\\r\\n\\r\\n\\xff'", "lsp.utf8_invalid")]) {
            let budget = ObservedLspFrameBudget()
            let client = LspClient(PreparedObservedChannel(malformedLspPeer(wire)), frameBudget: Some(budget))
            try { @Expect(lspPreparedCode(client.request("echo", jsonObject([]), timeoutMillis: 1000)), expected) }
            finally { let _ = client.close() }
            @Expect(budget.active.load(), 0)
        }
    }

    @TestCase
    func capabilityStorageAndReturnedCopyHaveSeparateActualLifetimes(): Unit {
        let script = preparedLspScript().replace("'params':p,'documents':docs", "'params':p,'documents':docs,'capabilities':{'hoverProvider':True}")
        let budget = ObservedLspFrameBudget()
        let client = LspClient(PreparedObservedChannel(script), frameBudget: Some(budget))
        try {
            let _ = lspPreparedRequire(client.initialize(jsonObject([]), timeoutMillis: 1000))
            @Expect(budget.active.load(), 2)
            client.releaseConsumedResponses()
            @Expect(budget.active.load(), 1)
            let view = client.serverCapabilities()
            @Expect(view.field("hoverProvider").getOrThrow().asBool(), true)
            @Expect(budget.active.load(), 2)
            view.put("hoverProvider", jsonBool(false))
            client.releaseConsumedResponses()
            let again = client.serverCapabilities()
            @Expect(again.field("hoverProvider").getOrThrow().asBool(), true)
            client.releaseConsumedResponses()
            @Expect(budget.active.load(), 1)
        } finally { let _ = client.close() }
        @Expect(budget.active.load(), 0)
    }
}
