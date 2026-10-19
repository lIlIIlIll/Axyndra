package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func documentTestBinding(): AgentValue {
    let digest = modelPolicySha256Text("fixture")
    objectValue([ValueField("namespace", textValue("axyndra:workflow")),
        ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("7")),
        ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue("thread")),
        ValueField("lane_id", textValue("main")), ValueField("run_id", textValue("run")),
        ValueField("epoch", integerValue(3)), ValueField("parent_call_id", textValue("parent")),
        ValueField("contribution", textValue("plugin.axyndra:workflow.todo")),
        ValueField("implementation_fingerprint", textValue("owned-v1:" + digest)), ValueField("schema_digest", textValue(digest))])
}
func documentTestIntent(read!: Bool = false, revision!: Int64 = 0, previous!: String = "null"): AgentValue {
    objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_INTENT_SCHEMA)), ValueField("binding", documentTestBinding()),
        ValueField("intent", objectValue([ValueField("id", textValue("mutation-1")), ValueField("key", textValue("todo")),
            ValueField("mode", textValue(if (read) { "read" } else { "compare_exchange" })),
            ValueField("expected_revision", integerValue(revision)), ValueField("expected_json", textValue(previous)),
            ValueField("expected_sha256", textValue(modelPolicySha256Text(previous))),
            ValueField("next_json", if (read) { nullValue() } else { textValue("{\"rows\":[]}") })]))])
}
func documentTestParent(value: AgentValue, duplicate!: Bool = false): AgentValue {
    let intent = value.field("intent").getOrThrow()
    objectValue([ValueField("input", objectValue([])), ValueField("configuration", objectValue([])),
        ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_DOCUMENT_PARENT_SCHEMA)),
            ValueField("binding", value.field("binding").getOrThrow()),
            ValueField("intents", listValue(if (duplicate) { [intent, intent] } else { [intent] }))]))])
}
func documentTestPlan(args: AgentValue, parent: Bool, effect!: OperationEffectClass = OperationEffectClass.ExternalMutation): NormalizedOperationPlan {
    let binding = if (parent) { args.field("host_plan").getOrThrow().field("binding").getOrThrow() } else { args.field("binding").getOrThrow() }
    NormalizedOperationPlan(if (parent) { httpIntentText(binding, "contribution") } else { HOST_PLUGIN_DOCUMENT_TOOL },
        args, [Capability(CapabilityKind.ExtensionInvoke, resource: httpIntentText(binding, "namespace"))],
        effect, OperationRetryDisposition.Never, "document-plan",
        toolVersion: if (parent) { "fixture-v1" } else { HOST_PLUGIN_DOCUMENT_FINGERPRINT },
        implementationFingerprint: if (parent) { httpIntentText(binding, "implementation_fingerprint") } else { HOST_PLUGIN_DOCUMENT_FINGERPRINT },
        schemaDigest: httpIntentText(binding, "schema_digest"))
}

@Test
class PluginDocumentIntentTests {
    @TestCase
    func frozenAllocationProfileCannotRedirectOrWidenTheDocumentIntent(): Unit {
        let child = documentTestIntent()
        let parent = documentTestParent(child)
        let host = parent.field("host_plan").getOrThrow()
        host.put("tool_payload_limits", OrdinaryToolPayloadLimits("todo").value())
        @Expect(pluginDocumentParentAllows(documentTestPlan(parent, true), documentTestPlan(child, false)))
        host.put("tool_payload_limits", OrdinaryToolPayloadLimits("goal").value())
        @Expect(pluginDocumentChildArguments(parent, "mutation-1").isError())
        host.put("tool_payload_limits", nullValue())
        @Expect(pluginDocumentChildArguments(parent, "mutation-1").isError())
        let profile = OrdinaryToolPayloadLimits("todo").value(); profile.put("authority", boolValue(true))
        host.put("tool_payload_limits", profile)
        @Expect(pluginDocumentChildArguments(parent, "mutation-1").isError())
    }
    @TestCase
    func frozenIntentOwnsBindingAndReturnedValuesCannotMutateIt(): Unit {
        let input = documentTestIntent()
        let frozen = parsePluginDocumentIntent(input).value().getOrThrow()
        input.field("binding").getOrThrow().put("thread_id", textValue("foreign"))
        input.field("intent").getOrThrow().put("next_json", textValue("null"))
        frozen.binding().put("generation", textValue("99"))
        frozen.toValue().field("intent").getOrThrow().put("key", textValue("other"))
        @Expect(httpIntentText(frozen.binding(), "thread_id"), "thread")
        @Expect(httpIntentText(frozen.binding(), "generation"), "7")
        @Expect(frozen.key, "todo")
        @Expect(frozen.nextJson.getOrThrow(), "{\"rows\":[]}")
        @Expect(frozen.result().field("revision").getOrThrow().asNumberText(), "1")
    }
    @TestCase
    func invalidNumbersHashesFieldsModesAndPathsFailBeforeAPlanExists(): Unit {
        for (name in ["key", "id"]) {
            let value = documentTestIntent(); value.field("intent").getOrThrow().put(name, textValue("../goal"))
            @Expect(parsePluginDocumentIntent(value).isError())
        }
        for (revision in [numberValue("1.0"), numberValue("1e0"), integerValue(-1)]) {
            let value = documentTestIntent(); value.field("intent").getOrThrow().put("expected_revision", revision)
            @Expect(parsePluginDocumentIntent(value).isError())
        }
        for (field in [ValueField("expected_sha256", textValue(modelPolicySha256Text("other"))),
            ValueField("mode", textValue("append")), ValueField("next_json", textValue(" { } ")),
            ValueField("artifact_ref", textValue("sha256:untrusted"))]) {
            let value = documentTestIntent(); value.field("intent").getOrThrow().put(field.name, field.value)
            @Expect(parsePluginDocumentIntent(value).isError())
        }
        for (field in [ValueField("generation", textValue("00")), ValueField("epoch", integerValue(0)),
            ValueField("contribution", textValue("plugin.other.todo")), ValueField("authority", boolValue(true))]) {
            let value = documentTestIntent(); value.field("binding").getOrThrow().put(field.name, field.value)
            @Expect(parsePluginDocumentIntent(value).isError())
        }
        @Expect(parsePluginDocumentIntent(documentTestIntent(revision: 9223372036854775807, previous: "null")).isError())
        @Expect(parsePluginDocumentIntent(documentTestIntent(revision: 0, previous: "corrupt")).isError())
    }
    @TestCase
    func tombstonesAdvanceAndHistoricalCorruptBytesAreNotSilentlyRepaired(): Unit {
        let raw = " old corrupt \u{0000} bytes "
        let value = documentTestIntent(revision: 9, previous: raw)
        value.field("intent").getOrThrow().put("next_json", textValue("null"))
        let frozen = parsePluginDocumentIntent(value).value().getOrThrow()
        @Expect(frozen.expectedJson, raw)
        @Expect(frozen.result().field("revision").getOrThrow().asNumberText(), "10")
        @Expect(httpIntentText(frozen.result(), "json"), "null")
        let read = documentTestIntent(read: true, revision: 9223372036854775807, previous: raw)
        @Expect(parsePluginDocumentIntent(read).value().getOrThrow().expectedJson, raw)
        read.field("intent").getOrThrow().put("next_json", textValue("null"))
        @Expect(parsePluginDocumentIntent(read).isError())
    }
    @TestCase
    func exactParentCannotRedirectAChildOrMakeAWriteReadOnly(): Unit {
        let child = documentTestIntent()
        let parent = documentTestParent(child)
        let selected = pluginDocumentChildArguments(parent, "mutation-1").value().getOrThrow()
        @Expect(pluginDocumentParentAllows(documentTestPlan(parent, true), documentTestPlan(selected, false)))
        @Expect(!pluginDocumentParentAllows(documentTestPlan(parent, true, effect: OperationEffectClass.ReadOnly), documentTestPlan(selected, false)))
        @Expect(!pluginDocumentParentAllows(documentTestPlan(parent, true), documentTestPlan(selected, false, effect: OperationEffectClass.ReadOnly)))
        @Expect(pluginDocumentChildArguments(parent, "foreign").isError())
        @Expect(pluginDocumentChildArguments(documentTestParent(child, duplicate: true), "mutation-1").isError())
        selected.field("intent").getOrThrow().put("next_json", textValue("null"))
        @Expect(!pluginDocumentParentAllows(documentTestPlan(parent, true), documentTestPlan(selected, false)))
        let read = documentTestIntent(read: true)
        @Expect(pluginDocumentParentAllows(documentTestPlan(documentTestParent(read), true, effect: OperationEffectClass.ReadOnly),
            documentTestPlan(read, false, effect: OperationEffectClass.ReadOnly)))
    }
}
