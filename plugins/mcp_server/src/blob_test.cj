package mcp_server_plugin

import std.unittest.*
import std.unittest.testmacro.*

func decoderBlobCode(action: () -> Unit): String {
    try { action(); "unexpected-success" } catch (error: PluginFailure) { error.code }
}

@Test
class DecoderBlobBudgetTests {
    @TestCase
    func denseConsumerReservationPrecedesParsingAndLivesUntilConsumerClose(): Unit {
        let bytes = Array<Byte>(120001, repeat: b',')
        bytes[0] = b'['; bytes[120000] = b']'
        for (index in 0..60000) { bytes[1 + index * 2] = b'0' }
        let source = String.fromUtf8(bytes)
        let blob = DecoderBlob(bytes.size, sha(source), 4194304, 131072, true)
        var blockedA: ?PayloadCharge = None; var blockedB: ?PayloadCharge = None
        var reader: ?DecoderBlobRead = None
        try {
            blob.append(0, bytes)
            blockedA = Some(payloadPool.acquire(33554432, transfer: false)) // 64 MiB
            blockedB = Some(payloadPool.acquire(25165824, transfer: false)) // 48 MiB
            @Expect(decoderBlobCode({ => let read = blob.read(); read.close() }), "mcp_server.payload_capacity")
            blockedB.getOrThrow().close(); blockedB = None
            reader = Some(blob.read())
            @Expect(reader.getOrThrow().text, source)
            @Expect(decoderBlobCode({ => let acquired = payloadPool.acquire(25165824, transfer: false); acquired.close() }), "mcp_server.payload_capacity")
            reader.getOrThrow().close(); reader = None
            blockedB = Some(payloadPool.acquire(25165824, transfer: false))
            @Expect(blockedB.isSome(), true)
        } finally {
            match (reader) { case Some(value) => value.close(); case None => () }
            match (blockedA) { case Some(value) => value.close(); case None => () }
            match (blockedB) { case Some(value) => value.close(); case None => () }
            blob.close()
        }
    }

    @TestCase
    func onlyFullyVerifiedBlobBecomesImmutableAndBadHashCannotBeConsumed(): Unit {
        let raw = "{\"complete\":true}".toArray()
        let bad = DecoderBlob(raw.size, sha("different"), 4194304, 131072, true)
        let good = DecoderBlob(raw.size, sha(String.fromUtf8(raw)), 4194304, 131072, true)
        try {
            @Expect(decoderBlobCode({ => bad.append(0, raw) }), "mcp_server.blob_digest")
            @Expect(decoderBlobCode({ => let read = bad.read(); read.close() }), "mcp_server.blob_incomplete")
            good.append(0, raw); raw[0] = b'['
            let read = good.read()
            try { @Expect(read.text, "{\"complete\":true}") } finally { read.close() }
            @Expect(decoderBlobCode({ => good.append(0, raw) }), "mcp_server.blob_expired")
        } finally { bad.close(); good.close() }
    }
}
