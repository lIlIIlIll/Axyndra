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
        @Expect(value.field("n").getOrThrow().asNumberText(), "1e0")
        @Expect(value.field("ok").getOrThrow().asBool(), true)
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
    func arrayViewsRemainLive() {
        let first = parseUnifiedJson("[1,2]")
        let second = parseUnifiedJson("[1,2]")
        let firstItems = first.items
        first.add(jsonNumber("3"))
        second.add(jsonNumber("4"))
        @Expect(firstItems.size, 3)
        @Expect(firstItems[2].asNumberText(), "3")
        @Expect(first.items.size, 3)
        @Expect(first.items[2].asNumberText(), "3")
        @Expect(second.items.size, 3)
        @Expect(second.items[2].asNumberText(), "4")
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
    @TestCase
    func gatesValidationVocabularyWithoutDisablingApplicators() {
        let dialect = "https://example.test/dialect"
        let registry = JsonSchemaRegistry()
        registry.register(dialect,
            "{\"$vocabulary\":{\"https://json-schema.org/draft/2020-12/vocab/core\":true," +
                "\"https://json-schema.org/draft/2020-12/vocab/applicator\":true}}")
        let config = JsonSchemaConfig(resolver: Some<UriResolver>(registry))

        let validationOnly = JsonSchema.fromValue(parseUnifiedJson(
            "{\"$schema\":\"https://example.test/dialect\",\"enum\":[1],\"const\":1,\"type\":\"integer\"," +
                "\"minLength\":4,\"maxLength\":8,\"pattern\":\"^z$\",\"required\":[\"missing\"]}"
        ), config: config)
        @Expect(validationOnly.isValid(parseUnifiedJson("\"x\"")), true)

        let objectValidation = JsonSchema.fromValue(parseUnifiedJson(
            "{\"$schema\":\"https://example.test/dialect\",\"minProperties\":2,\"required\":[\"missing\"]," +
                "\"dependentRequired\":{\"present\":[\"missing\"]}}"
        ), config: config)
        @Expect(objectValidation.isValid(parseUnifiedJson("{\"present\":true}")), true)

        let arrayValidation = JsonSchema.fromValue(parseUnifiedJson(
            "{\"$schema\":\"https://example.test/dialect\",\"minItems\":2,\"uniqueItems\":true," +
                "\"minContains\":2,\"contains\":{}}"
        ), config: config)
        @Expect(arrayValidation.isValid(parseUnifiedJson("[1]")), true)

        let applicator = JsonSchema.fromValue(parseUnifiedJson(
            "{\"$schema\":\"https://example.test/dialect\",\"enum\":[1],\"not\":{}}"
        ), config: config)
        @Expect(applicator.isValid(parseUnifiedJson("1")), false)
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
