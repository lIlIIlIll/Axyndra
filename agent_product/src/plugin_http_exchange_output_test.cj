package agent_product

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginHttpExchangeOutputTests {
    @TestCase
    func reflectionAcrossEverySplitWithholdsEveryCandidatePrefix(): Unit {
        let secret = "axY/9+ key"
        for (encoded in [secret, "axY\\/9+ key", "\\u0061xY/9+ key",
            "a\\u0078\\u0059/9+ key", "axY%2f9%2B%20key", "axY%2F9%2b%20key",
            productBase64Bytes(secret.toArray()), "[REDACTED]"]) {
            let bytes = encoded.toArray()
            for (split in 0..bytes.size + 1) {
                let gate = ProductHttpExchangeOutputGate([secret])
                @Expect(lifecycleTestRequire(gate.push("safe|".toArray())), "safe|".toArray())
                let first = gate.push(bytes[..split])
                if (first.isOk()) {
                    @Expect(lifecycleTestRequire(first).isEmpty())
                    @Expect(gate.push(bytes[split..], eof: true).isError())
                } else { @Expect(split, bytes.size) }
                @Expect(gate.push("later-safe".toArray(), eof: true).isError())
            }
        }
    }

    @TestCase
    func harmlessOpenEventStreamFlushesWithoutWaitingForEof(): Unit {
        let secret = "secret-value"
        let text = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n"
        let gate = ProductHttpExchangeOutputGate([secret])
        @Expect(lifecycleTestRequire(gate.push(text.toArray())), text.toArray())
        @Expect(lifecycleTestRequire(gate.push("next-event\n\n".toArray())), "next-event\n\n".toArray())
        @Expect(lifecycleTestRequire(gate.push([], eof: true)).isEmpty())
        @Expect(gate.push([]).isError())

        let overlap = ProductHttpExchangeOutputGate(["ababac"])
        @Expect(lifecycleTestRequire(overlap.push("ababa".toArray())).isEmpty())
        @Expect(lifecycleTestRequire(overlap.push("bax|".toArray())), "abababax|".toArray())
        @Expect(lifecycleTestRequire(overlap.push("ababa".toArray())).isEmpty())
        @Expect(overlap.push("c".toArray()).isError())
    }

    @TestCase
    func unicodeAndSurrogatesAreCheckedBeforeRawBytesEscape(): Unit {
        for ((secret, encoded) in [("钥匙", "\\u94a5\\u5319"),
            ("x🔒y", "x\\ud83d\\udd12y"), ("x🔒y", "x%f0%9F%94%92y")]) {
            let gate = ProductHttpExchangeOutputGate([secret])
            let bytes = encoded.toArray()
            for (index in 0..bytes.size - 1) {
                @Expect(lifecycleTestRequire(gate.push(bytes[index..index + 1])).isEmpty())
            }
            @Expect(gate.push(bytes[bytes.size - 1..]).isError())
        }
        let binary = [255u8, 0u8, 195u8, 40u8, 92u8, 117u8, 48u8]
        let safe = ProductHttpExchangeOutputGate(["unrelated"])
        let first = lifecycleTestRequire(safe.push(binary))
        let last = lifecycleTestRequire(safe.push([], eof: true))
        let whole = ArrayList<Byte>(); whole.add(all: first); whole.add(all: last)
        @Expect(whole.toArray(), binary)
    }

    @TestCase
    func byteBoundsAreCumulativeAndPrivateMetadataUsesTheSameBoundary(): Unit {
        let exact = ProductHttpExchangeOutputGate([], maxBytes: 3)
        @Expect(lifecycleTestRequire(exact.push([0u8, 255u8])), [0u8, 255u8])
        @Expect(lifecycleTestRequire(exact.push([1u8], eof: true)), [1u8])
        let over = ProductHttpExchangeOutputGate([], maxBytes: 3)
        @Expect(lifecycleTestRequire(over.push([0u8, 255u8])), [0u8, 255u8])
        @Expect(over.push([1u8, 2u8]).isError())
        @Expect(over.push([], eof: true).isError())
        @Expect(ProductHttpExchangeOutputGate([]).push(Array<Byte>(8193, repeat: 1u8)).isError())

        let metadata = ProductHttpExchangeOutputGate(["secret-value"], maxBytes: 1024)
        let rejected = metadata.push("application/secret-value".toArray(), eof: true)
        @Expect(rejected.isError())
        @Expect(!rejected.error().getOrThrow().describe().contains("secret-value"))
        let harmless = ProductHttpExchangeOutputGate(["secret-value"], maxBytes: 1024)
        @Expect(lifecycleTestRequire(harmless.push("text/event-stream".toArray(), eof: true)),
            "text/event-stream".toArray())
    }

    @TestCase
    func maximumSecretDoesNotBufferUnrelatedTrafficOrMissLateReflection(): Unit {
        let secret = String.fromUtf8(Array<Byte>(8192, repeat: 120u8))
        let gate = ProductHttpExchangeOutputGate([secret], maxBytes: 262144)
        let harmless = Array<Byte>(8192, repeat: 121u8)
        for (_ in 0..8) { @Expect(lifecycleTestRequire(gate.push(harmless)), harmless) }
        let encoded = ArrayList<Byte>()
        for (_ in 0..8192) { encoded.add(all: "\\u0078".toArray()) }
        let bytes = encoded.toArray()
        var offset: Int64 = 0
        while (offset + 8192 < bytes.size) {
            @Expect(lifecycleTestRequire(gate.push(bytes[offset..offset + 8192])).isEmpty())
            offset += 8192
        }
        @Expect(gate.push(bytes[offset..]).isError())
    }
}


@Test
class PluginHttpOutputLiteralPathTests {
    @TestCase
    func literalPathPreservesOldDecodedBytesOffsetsAndPendingPrefixes(): Unit {
        let samples = ArrayList<Array<Byte>>()
        for (text in ["normal text",
            "x\\\\y\\/z\\\"tail",
            "\\u0061x\\u94a5\\u5319",
            "\\ud83d\\udd12",
            "\\ud83d\\u1234tail",
            "\\udc00",
            "\\u0x21",
            "\\u000",
            "%aB%2f%F0%9f%94%92",
            "%z1x%0tail",
            "partial%",
            "partial%2",
            "partial\\",
            "\\n\\r\\t\\b\\f\\q",
            "雪🙂 mixed \\u96ea%20tail"]) { samples.add(text.toArray()) }
        let allBytes = Array<Byte>(256, { index => UInt8(index) }); samples.add(allBytes)
        for (json in [true, false]) {
            for (sample in samples) {
                let original = ProductHttpOutputDecoder(json)
                let optimized = ProductHttpOutputDecoder(json)
                let expected = ArrayList<ProductHttpOutputByte>()
                let actual = ArrayList<ProductHttpOutputByte>()
                for (index in 0..sample.size) {
                    expected.add(all: original.push(sample[index], index))
                    if (optimized.mayPassLiteral(sample[index])) { actual.add(ProductHttpOutputByte(sample[index], index)) }
                    else { actual.add(all: optimized.push(sample[index], index)) }
                    @Expect(optimized.earliest(index + 1), original.earliest(index + 1))
                }
                expected.add(all: original.finish()); actual.add(all: optimized.finish())
                @Expect(actual.size, expected.size)
                for (index in 0..expected.size) {
                    @Expect(actual[index].value, expected[index].value)
                    @Expect(actual[index].source, expected[index].source)
                }
            }
        }
    }

    @TestCase
    func multiMiBLiteralStreamRetainsExactBytesAndStillWithholdsLateEscapedSecret(): Unit {
        let bytes = Array<Byte>(8192, repeat: b'q')
        let maximum: Int64 = 8388608
        let gate = ProductHttpExchangeOutputGate(["never-reflect-this"], maxBytes: maximum)
        for (_ in 0..1024) { @Expect(lifecycleTestRequire(gate.push(bytes)), bytes) }
        @Expect(lifecycleTestRequire(gate.push([], eof: true)).isEmpty())
        let late = ProductHttpExchangeOutputGate(["secret-value"], maxBytes: 262144)
        for (_ in 0..16) { @Expect(lifecycleTestRequire(late.push(bytes)), bytes) }
        @Expect(lifecycleTestRequire(late.push("\\u0073ecret-".toArray())).isEmpty())
        @Expect(late.push("value".toArray(), eof: true).isError())
    }
}
