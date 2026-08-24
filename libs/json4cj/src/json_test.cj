package json4cj

import std.unittest.*
import std.unittest.testmacro.*

@Test
class Json4CjTests {
    @TestCase
    func roundTripStructuredValue() {
        let value = parseJson("{\"text\":\"你好\\nworld\",\"n\":-1.25e+3,\"a\":[true,null]}")
        let encoded = encodeJson(value)
        @Expect(encodeJson(parseJson(encoded)), encoded)
        @Expect(value.field("text").getOrThrow().text, "你好\nworld")
    }

    @TestCase
    func rejectsInvalidDocumentsAndNumbers() {
        @ExpectThrows[JsonParseError](parseJson("{\"a\":1,\"a\":2}"))
        @ExpectThrows[JsonParseError](parseJson("01"))
        @ExpectThrows[JsonParseError](parseJson("\"\\uD800\""))
        @ExpectThrows[JsonEncodeError](encodeJson(JsonValue.numberValue("NaN")))
    }

    @TestCase
    func enforcesParseLimits() {
        @ExpectThrows[JsonLimitError](parseJson("[[]]", maxDepth: 1))
        @ExpectThrows[JsonLimitError](parseJson("\"abcd\"", maxStringBytes: 3))
        @ExpectThrows[JsonLimitError](parseJson("[1,2]", maxArrayElements: 1))
        @ExpectThrows[JsonLimitError](parseJson("{\"a\":1,\"b\":2}", maxObjectMembers: 1))
        @ExpectThrows[JsonLimitError](parseJson("true", maxBytes: 3))
    }

    @TestCase
    func enforcesEncodeLimits() {
        let value = JsonValue.arrayValue([JsonValue.stringValue("large")])
        @ExpectThrows[JsonEncodeError](encodeJson(
            value,
            options: JsonEncodeOptions(maxStringBytes: 4)
        ))
        @ExpectThrows[JsonEncodeError](encodeJson(
            value,
            options: JsonEncodeOptions(maxBytes: 4)
        ))
    }

    @TestCase
    func escapesEveryControlCharacter() {
        @Expect(encodeJson(JsonValue.stringValue("\u{0000}\b\f\n\r\t")), "\"\\u0000\\b\\f\\n\\r\\t\"")
    }

    @TestCase
    func parserOwnsTemporarySourcesAcrossConcurrentWork() {
        let first = spawn { parseJson("{\"index\":1,\"enabled\":true,\"value\":null}") }
        let second = spawn { parseJson("{\"index\":2,\"enabled\":true,\"value\":null}") }
        let third = spawn { parseJson("{\"index\":3,\"enabled\":true,\"value\":null}") }
        @Expect(first.get().field("enabled").getOrThrow().boolean, true)
        @Expect(second.get().field("enabled").getOrThrow().boolean, true)
        @Expect(third.get().field("enabled").getOrThrow().boolean, true)
    }
}
