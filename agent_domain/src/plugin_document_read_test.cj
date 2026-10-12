package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func documentReadTestRequest(): AgentValue {
    objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_READ_SCHEMA)), ValueField("binding", documentTestBinding()),
        ValueField("projection_digest", textValue(modelPolicySha256Text("projection"))), ValueField("keys", listValue([textValue("todo")]))])
}
func documentReadTestPlan(value: AgentValue, capability: Capability): NormalizedOperationPlan {
    NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL, value, [capability], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never, "document-read-test", toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION,
        implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
}

@Test
class PluginDocumentReadTests {
    @TestCase
    func usageObservationIsStrictCurrentScopeDataWithCheckedTotals(): Unit {
        let request = documentReadTestRequest(); let binding = request.field("binding").getOrThrow()
        let value = objectValue([ValueField("schema", textValue("axyndra.document-observation/v1")),
            ValueField("thread_id", binding.field("thread_id").getOrThrow()), ValueField("run_id", binding.field("run_id").getOrThrow()),
            ValueField("observed_at_millis", integerValue(10)), ValueField("input_tokens", integerValue(5)), ValueField("output_tokens", integerValue(7))])
        @Expect(pluginDocumentObservationValid(value, request))
        value.put("thread_id", textValue("other")); @Expect(!pluginDocumentObservationValid(value, request))
        value.put("thread_id", binding.field("thread_id").getOrThrow())
        value.put("input_tokens", integerValue(9223372036854775807)); @Expect(!pluginDocumentObservationValid(value, request))
        value.put("input_tokens", integerValue(5)); value.put("allowance", boolValue(true)); @Expect(!pluginDocumentObservationValid(value, request))
    }
    @TestCase
    func exactDocumentReadNeverWidensTheWorkspaceReadBranch(): Unit {
        let value = documentReadTestRequest()
        @Expect(pluginDocumentReadRequestValid(value))
        let capability = Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow")
        let plan = documentReadTestPlan(value, capability)
        @Expect(isContextReadPlan(plan)); @Expect(pluginDocumentReadAuthority(plan))
        @Expect(!isContextReadPlan(documentReadTestPlan(value, Capability(CapabilityKind.WorkspaceRead))))
        @Expect(!isContextReadPlan(documentReadTestPlan(value, Capability(CapabilityKind.ExtensionInvoke, resource: "other"))))
        let changed = documentReadTestRequest(); changed.field("binding").getOrThrow().put("parent_call_id", textValue("other-parent"))
        @Expect(contextReadPlanDigest(plan) != contextReadPlanDigest(documentReadTestPlan(changed, capability)))
        for (keys in [listValue([]), listValue([textValue("todo"), textValue("todo")]), listValue([textValue("../todo")])]) {
            let bad = documentReadTestRequest(); bad.put("keys", keys); @Expect(!pluginDocumentReadRequestValid(bad)) }
        value.put("requires_approval", boolValue(false)); @Expect(!pluginDocumentReadRequestValid(value))
    }
    @TestCase
    func readResultRequiresExactRequestOrderRevisionAndRawBytes(): Unit {
        let request = documentReadTestRequest()
        let result = objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_READ_RESULT_SCHEMA)),
            ValueField("request_digest", textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("documents", listValue([objectValue([ValueField("key", textValue("todo")), ValueField("revision", integerValue(3)),
                ValueField("json", textValue(" historical malformed bytes ")), ValueField("sha256", textValue(modelPolicySha256Text(" historical malformed bytes ")))] )]))])
        @Expect(pluginDocumentReadResultValid(result, request))
        result.field("documents").getOrThrow().items[0].put("revision", integerValue(0))
        @Expect(!pluginDocumentReadResultValid(result, request))
        result.field("documents").getOrThrow().items[0].put("revision", integerValue(3))
        result.field("documents").getOrThrow().items[0].put("json", textValue("changed"))
        @Expect(!pluginDocumentReadResultValid(result, request))
    }
}
