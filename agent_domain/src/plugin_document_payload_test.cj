package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func documentPayloadTestValue(): AgentValue {
    objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref", textValue("blob:sha256:" + modelPolicySha256Text("null"))),
        ValueField("encoding", textValue("utf8")), ValueField("bytes", integerValue(4)),
        ValueField("sha256", textValue(modelPolicySha256Text("null"))),
        ValueField("content_type", textValue("text/plain; charset=utf-8"))])
}

func documentPayloadTestIntent(write!: Bool = false): AgentValue {
    objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_INTENT_SCHEMA)),
        ValueField("binding", documentTestBinding()), ValueField("intent", objectValue([
            ValueField("id", textValue("todo-1")), ValueField("key", textValue("todo")),
            ValueField("mode", textValue(if (write) { "compare_exchange" } else { "read" })),
            ValueField("expected_revision", integerValue(0)), ValueField("expected_payload", documentPayloadTestValue()),
            ValueField("next_payload", if (write) { documentPayloadTestValue() } else { nullValue() })]))])
}

@Test
class PluginDocumentPayloadTests {
    @TestCase
    func referenceIntentFreezesBothContentDescriptorsWithoutRawJson(): Unit {
        let value = documentPayloadTestIntent(write: true)
        let parsed = parsePluginDocumentIntent(value).value().getOrThrow()
        value.field("intent").getOrThrow().field("expected_payload").getOrThrow().put("bytes", integerValue(100))
        parsed.toValue().field("intent").getOrThrow().field("next_payload").getOrThrow().put("bytes", integerValue(100))
        @Expect(parsed.referencesPayload); @Expect(parsed.expectedPayload.getOrThrow().bytes, 4)
        @Expect(parsed.nextPayload.getOrThrow().bytes, 4); @Expect(parsed.expectedJson, "")
        @Expect(parsed.nextJson.isNone())
        @Expect(httpIntentText(parsed.result(), "schema"), PLUGIN_DOCUMENT_PAYLOAD_RESULT_SCHEMA)
        @Expect(parsed.result().field("revision").getOrThrow().asNumberText(), "1")
        @Expect(parsed.result().field("json").isNone())
    }
    @TestCase
    func referenceIntentRejectsMixedInlineAuthorityAbsenceAndOverflow(): Unit {
        for (field in [ValueField("expected_json", textValue("null")), ValueField("expected_sha256", textValue(modelPolicySha256Text("null"))),
            ValueField("next_json", textValue("null")), ValueField("source", textValue("trusted")),
            ValueField("expected_revision", integerValue(-1)), ValueField("expected_revision", integerValue(9223372036854775807))]) {
            let value = documentPayloadTestIntent(write: true)
            value.field("intent").getOrThrow().put(field.name, field.value)
            @Expect(parsePluginDocumentIntent(value).isError())
        }
        let read = documentPayloadTestIntent()
        read.field("intent").getOrThrow().put("next_payload", documentPayloadTestValue())
        @Expect(parsePluginDocumentIntent(read).isError())
        let absent = documentPayloadTestIntent()
        absent.field("intent").getOrThrow().field("expected_payload").getOrThrow().put("bytes", integerValue(3))
        @Expect(parsePluginDocumentIntent(absent).isError())
    }
    @TestCase
    func parentVersionSelectsOneRepresentationAndNeverAcceptsDuplicateKeys(): Unit {
        let raw = documentPayloadTestIntent().field("intent").getOrThrow()
        let host = objectValue([ValueField("version", textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA)),
            ValueField("binding", documentTestBinding()), ValueField("intents", listValue([raw]))])
        let parent = objectValue([ValueField("input", objectValue([])), ValueField("configuration", objectValue([])), ValueField("host_plan", host)])
        @Expect(pluginDocumentChildArguments(parent, "todo-1").isOk())
        @Expect(pluginDocumentChildArguments(parent, "other").isError())
        host.put("version", textValue(PLUGIN_DOCUMENT_PARENT_SCHEMA))
        @Expect(pluginDocumentChildArguments(parent, "todo-1").isError())
        host.put("version", textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA))
        let duplicate = parseUnifiedJson(stringifyUnifiedJson(raw)); duplicate.put("id", textValue("todo-2"))
        host.put("intents", listValue([raw, duplicate]))
        @Expect(pluginDocumentChildArguments(parent, "todo-1").isError())
    }
    @TestCase
    func referenceShapeRejectsForeignPathsEncodingMimeAuthorityAndBounds(): Unit {
        for (field in [ValueField("artifact_ref", textValue("/tmp/document")), ValueField("encoding", textValue("hex")),
            ValueField("content_type", textValue("application/json")), ValueField("authority", boolValue(true)),
            ValueField("bytes", integerValue(-1)), ValueField("bytes", integerValue(8388609)),
            ValueField("bytes", numberValue("4.0")), ValueField("bytes", textValue("4")),
            ValueField("sha256", textValue(modelPolicySha256Text("other")))]) {
            let value = documentPayloadTestValue(); value.put(field.name, field.value)
            @Expect(parsePluginDocumentPayloadReference(value).isError())
        }
        let value = documentPayloadTestValue(); value.put("bytes", integerValue(8388608))
        @Expect(parsePluginDocumentPayloadReference(value).isOk())
    }
    @TestCase
    func frozenReferenceDoesNotRetainMutableCallerOrReturnedValues(): Unit {
        let source = documentPayloadTestValue()
        let frozen = parsePluginDocumentPayloadReference(source).value().getOrThrow()
        source.put("bytes", integerValue(100))
        frozen.value().put("sha256", textValue(modelPolicySha256Text("mutated")))
        @Expect(frozen.bytes, 4); @Expect(frozen.digest, modelPolicySha256Text("null"))
    }
    @TestCase
    func absenceIsExactNullWhileExistingCorruptContentRemainsDescriptive(): Unit {
        let value = objectValue([ValueField("key", textValue("todo")), ValueField("revision", integerValue(0)),
            ValueField("payload", documentPayloadTestValue())])
        @Expect(pluginDocumentPayloadSnapshotValid(value, "todo"))
        @Expect(!pluginDocumentPayloadSnapshotValid(value, "goal"))
        value.field("payload").getOrThrow().put("bytes", integerValue(3))
        @Expect(!pluginDocumentPayloadSnapshotValid(value, "todo"))
        value.put("revision", integerValue(1))
        @Expect(pluginDocumentPayloadSnapshotValid(value, "todo"))
        value.put("json", textValue("forged unverified hydration"))
        @Expect(!pluginDocumentPayloadSnapshotValid(value, "todo"))
    }
    @TestCase
    func referenceReadHasDistinctFrozenVersionAndCannotMixInlineRows(): Unit {
        let request = objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA)),
            ValueField("binding", documentTestBinding()), ValueField("projection_digest", textValue(modelPolicySha256Text("projection"))),
            ValueField("keys", listValue([textValue("todo")]))])
        let result = objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_READ_RESULT_SCHEMA)),
            ValueField("request_digest", textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("documents", listValue([objectValue([ValueField("key", textValue("todo")),
                ValueField("revision", integerValue(0)), ValueField("payload", documentPayloadTestValue())])]))])
        @Expect(pluginDocumentReadRequestValid(request)); @Expect(pluginDocumentReadResultValid(result, request))
        result.put("schema", textValue(PLUGIN_DOCUMENT_READ_RESULT_SCHEMA))
        @Expect(!pluginDocumentReadResultValid(result, request))
        request.put("schema", textValue(PLUGIN_DOCUMENT_READ_SCHEMA))
        result.put("request_digest", textValue(modelPolicySha256Text(canonicalAgentValue(request))))
        @Expect(!pluginDocumentReadResultValid(result, request))
    }
}
