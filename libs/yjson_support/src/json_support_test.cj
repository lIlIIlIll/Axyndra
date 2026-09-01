package yjson_support

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

@Test
class YJsonSupportTests {
    @TestCase
    func parsesWithStableKindsAndNumberLiterals() {
        let value = parseUnifiedJson("{\"n\":1e0,\"ok\":true}")
        @Expect(value.unifiedKind == UnifiedJsonKind.Object, true)
        @Expect(value.field("n").getOrThrow().number, "1e0")
        @Expect(value.field("ok").getOrThrow().boolean, true)
    }

    @TestCase
    func fieldsPreserveDocumentOrder() {
        let value = parseUnifiedJson("{\"z\":1,\"a\":2,\"m\":3}")
        let fields = value.fields
        @Expect(fields.size, 3)
        @Expect(fields[0].name, "z")
        @Expect(fields[1].name, "a")
        @Expect(fields[2].name, "m")
    }

    @TestCase
    func exposesStableArrayStorage() {
        let value = parseUnifiedJson("[1,2]")
        let items = value.items
        value.add(jsonNumber("3"))
        @Expect(items.size, 3)
        @Expect(items[2].number, "3")
    }

    @TestCase
    func textCoversStringsScalarsAndContainers() {
        @Expect(jsonString("value").text, "value")
        @Expect(jsonNumber("1e0").text, "1e0")
        @Expect(jsonBool(true).text, "true")
        @Expect(jsonNull().text, "null")
        @Expect(parseUnifiedJson("[1]").text, "[1]")
        @Expect(parseUnifiedJson("{\"a\":1}").text, "{\"a\":1}")
        @Expect(jsonNumber("1").items.isEmpty(), true)
        @Expect(jsonNumber("1").fields.isEmpty(), true)
        @Expect(jsonNumber("1").field("missing").isNone(), true)
    }

    @TestCase
    func rejectsDuplicateObjectKeys() {
        @Expect(throwsJsonException({ => parseUnifiedJson("{\"a\":1,\"a\":2}"); () }), true)
    }

    @TestCase
    func enforcesByteAndDepthLimits() {
        @Expect(throwsJsonException({ => parseUnifiedJson("{\"long\":true}", maxBytes: 4); () }), true)
        @Expect(throwsJsonException({ => parseUnifiedJson("[[[0]]]", maxDepth: 2); () }), true)
    }

    @TestCase
    func projectsSchemaPathToKeyword() {
        let schema = parseUnifiedJson(
            "{\"type\":\"object\",\"required\":[\"name\"]," +
                "\"properties\":{\"name\":{\"type\":\"string\"}}}"
        )
        let required = validateUnifiedJsonSchema(schema, parseUnifiedJson("{}"))
            .getOrThrow()
        @Expect(required.path, "$")
        @Expect(required.keyword, "required")

        let wrongType = validateUnifiedJsonSchema(
            schema,
            parseUnifiedJson("{\"name\":1}")
        ).getOrThrow()
        @Expect(wrongType.path, "$[\"name\"]")
        @Expect(wrongType.keyword, "type")

        let malformed = validateUnifiedJsonSchema(
            parseUnifiedJson("{\"type\":\"object\",\"required\":\"name\"}"),
            parseUnifiedJson("{}")
        ).getOrThrow()
        @Expect(malformed.keyword, "schema")
    }
}

func throwsJsonException(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: JsonException) {
        true
    }
}
