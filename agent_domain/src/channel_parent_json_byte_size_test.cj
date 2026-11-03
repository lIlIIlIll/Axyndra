package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.stringifyUnifiedJson

private class ChannelSizeUnsupportedNode <: JsonNode {
    private let advertised: JsonKind
    public var kindCalls: Int64 = 0

    init(advertised: JsonKind) { this.advertised = advertised }
    public func kind(): JsonKind { kindCalls++; advertised }
    public func size(): Int64 { 0 }
    public func toString(): String { "unsupported" }
    public func toPrettyString(indent: String): String { let _ = indent; "unsupported" }
}

func channelSizeTestNested(containers: Int64): JsonNode {
    var value: JsonNode = JsonNode.int64(7)
    for (_ in 0..containers) { value = JsonArray().add(value) }
    value
}

@Test
class ChannelParentJsonByteSizeTests {
    @TestCase
    func originalDefaultScalarsAndOrderedNestedObjectsHaveExactSizes(): Unit {
        let values: Array<JsonNode> = [JsonNode.nullValue, JsonNode.boolean(true), JsonNode.boolean(false),
            JsonNode.int64(Int64.Min), JsonNode.uint64(UInt64.Max), JsonNode.float64(1.5),
            JsonNode.number("-0"), JsonNode.number("1.00"), JsonNode.number("1e-9"),
            JsonNode.number("-2.5E+3"), JsonNode.string("雪"), JsonArray(), JsonObject()]
        for (value in values) {
            @Expect(channelParentJsonByteSize(value), stringifyUnifiedJson(value).size)
        }
        let object = JsonObject().put("second", JsonArray(values)).put("first", JsonNode.string("x"))
        @Expect(channelParentJsonByteSize(object), stringifyUnifiedJson(object).size)
        let reordered = JsonObject().put("first", JsonNode.string("x")).put("second", JsonArray(values))
        @Expect(channelParentJsonByteSize(reordered), stringifyUnifiedJson(reordered).size)
        @Expect(stringifyUnifiedJson(object) != stringifyUnifiedJson(reordered))
    }

    @TestCase
    func everyControlQuoteBackslashAndUnicodeUsesTheOriginalEscaper(): Unit {
        for (byte in 0..32) {
            let control = String.fromUtf8([UInt8(byte)])
            let value = JsonObject().put("key" + control, JsonNode.string("before" + control + "after"))
            @Expect(channelParentJsonByteSize(value), stringifyUnifiedJson(value).size)
        }
        for (text in ["\"", "\\", "\n\r\t", "雪é🙂", "<>&='", "\u{2028}\u{2029}", "a\u{0000}b"]) {
            let value = JsonObject().put(text, JsonNode.string(text))
            @Expect(channelParentJsonByteSize(value), stringifyUnifiedJson(value).size)
        }
        let html = JsonNode.string("<>&='")
        @Expect(channelParentJsonByteSize(html), html.toJson().size)
        @Expect(html.toJson().size != html.toJson(options: JsonWriteOptions.htmlSafePreset).size)
    }

    @TestCase
    func threeMibCurrentTextAndItsLastEscapingByteAreReadInFull(): Unit {
        let prefix = String.fromUtf8(Array<Byte>(3145727, repeat: b'x'))
        let value = JsonObject().put("text", JsonNode.string(prefix + "x"))
        @Expect(channelParentJsonByteSize(value), stringifyUnifiedJson(value).size)
        let before = channelParentJsonByteSize(value)
        value.put("text", JsonNode.string(prefix + "\""))
        @Expect(channelParentJsonByteSize(value), before + 1)
        @Expect(channelParentJsonByteSize(value), stringifyUnifiedJson(value).size)
        value.put("text", JsonNode.string(prefix + "\u{0000}"))
        @Expect(channelParentJsonByteSize(value), before + 5)
        @Expect(channelParentJsonByteSize(value), stringifyUnifiedJson(value).size)
        value.put("text", JsonNode.string(prefix + "雪"))
        @Expect(channelParentJsonByteSize(value), before + 2)
        @Expect(channelParentJsonByteSize(value), stringifyUnifiedJson(value).size)
    }

    @TestCase
    func originalQuotaBoundariesDoNotRoundDownOrStopAtAnEarlierLimit(): Unit {
        for (limit in [8192, 16384, 262144, 3145728, 4194304, 8388608]) {
            let exact = JsonNode.string(String.fromUtf8(Array<Byte>(limit - 2, repeat: b'x')))
            let bytes = channelParentJsonByteSize(exact)
            @Expect(bytes, limit)
            @Expect(bytes, stringifyUnifiedJson(exact).size)
            @Expect(!(bytes > limit))
            @Expect(bytes > limit - 1)
        }
        let controls = JsonNode.string(String.fromUtf8(Array<Byte>(32768, repeat: UInt8(0))))
        @Expect(channelParentJsonByteSize(controls), 196610)
        @Expect(channelParentJsonByteSize(controls), stringifyUnifiedJson(controls).size)
    }

    @TestCase
    func originalContainerDepthErrorsAndPathsComeFromTheWholeWriter(): Unit {
        let exact = channelSizeTestNested(256)
        @Expect(channelParentJsonByteSize(exact), stringifyUnifiedJson(exact).size)
        let tooDeep = JsonObject().put("deep", channelSizeTestNested(256))
        let original = @AssertThrows[JsonException](stringifyUnifiedJson(tooDeep))
        let current = @AssertThrows[JsonException](channelParentJsonByteSize(tooDeep))
        @Expect(current.code, original.code)
        @Expect(current.path, original.path)
        @Expect(current.message, original.message)
        @Expect(current.code, "max_depth")
    }

    @TestCase
    func cyclesAreRejectedAndSharedDagValuesAreCountedAtEveryOccurrence(): Unit {
        let cycle = JsonArray(); cycle.add(cycle)
        let cyclic = JsonObject().put("cycle", cycle)
        let original = @AssertThrows[JsonException](stringifyUnifiedJson(cyclic))
        let current = @AssertThrows[JsonException](channelParentJsonByteSize(cyclic))
        @Expect(current.code, "cyclic_json_node")
        @Expect(current.code, original.code)
        @Expect(current.path, original.path)
        @Expect(current.message, original.message)
        let shared = JsonArray().add(JsonNode.string("shared"))
        let dag = JsonObject().put("left", shared).put("right", shared)
        @Expect(channelParentJsonByteSize(dag), stringifyUnifiedJson(dag).size)
        shared.set(0, JsonNode.string("shared\""))
        @Expect(channelParentJsonByteSize(dag), stringifyUnifiedJson(dag).size)
    }

    @TestCase
    func customNodesCannotObtainAStringFastPathByAdvertisingAnyKind(): Unit {
        for (kind in [JsonKind.Null, JsonKind.Boolean, JsonKind.Number, JsonKind.String, JsonKind.Array, JsonKind.Object]) {
            let custom = ChannelSizeUnsupportedNode(kind)
            let value = JsonObject().put("unknown", custom)
            let original = @AssertThrows[JsonException](stringifyUnifiedJson(value))
            let current = @AssertThrows[JsonException](channelParentJsonByteSize(value))
            @Expect(current.code, original.code)
            @Expect(current.path, original.path)
            @Expect(current.message, original.message)
            @Expect(custom.kindCalls, 0)
        }
    }

    @TestCase
    func lateInvalidNumbersAndNodesStillFailAfterAnAlreadyOversizedPrefix(): Unit {
        let prefix = JsonNode.string(String.fromUtf8(Array<Byte>(262145, repeat: b'x')))
        let invalids: Array<JsonNode> = [JsonNode.float64(Float64.NaN), JsonNode.float64(Float64.Inf),
            ChannelSizeUnsupportedNode(JsonKind.String)]
        for (invalid in invalids) {
            let value = JsonObject().put("large", prefix).put("invalid", invalid)
            let original = @AssertThrows[JsonException](stringifyUnifiedJson(value))
            let current = @AssertThrows[JsonException](channelParentJsonByteSize(value))
            @Expect(current.code, original.code)
            @Expect(current.path, original.path)
            @Expect(current.message, original.message)
        }
    }
}
