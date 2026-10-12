package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func parameterTestBinding(): AgentValue {
    objectValue([ValueField("thread_id",textValue("actual-call-thread")),ValueField("run_id",textValue("actual-call-run")),
        ValueField("epoch",integerValue(2)),ValueField("call_id",textValue("actual-call")),ValueField("tool_name",textValue("plugin.workspace.write")),
        ValueField("plugin",textValue("workspace")),ValueField("contribution",textValue("write")),
        ValueField("package_digest",textValue("sha256:"+modelPolicySha256Text("installed package"))),ValueField("generation",textValue("7")),
        ValueField("configuration_digest",textValue(modelPolicySha256Text("actual operator configuration")))])
}
func parameterTestCopy(value: AgentValue): AgentValue { parseUnifiedJson(stringifyUnifiedJson(value),maxBytes:16384) }
func parameterTestRequest(reference: AgentValue): AgentValue {
    objectValue([ValueField("executable",textValue("bin/workspace-plugin")),ValueField("arguments",listValue([textValue("--view-worker-file"),textValue("write")])),
        ValueField("timeout_ms",integerValue(30000)),ValueField("input_reference",reference)])
}

@Test
class HostReadViewParameterReferenceTests {
    @TestCase
    func completeTypedTreePreservesUnknownFieldsAndMissingValuesWithoutHostGrammar(): Unit {
        let charge=reserveNativeDocumentPayload(65536)
        try {
            let input=objectValue([ValueField("unknown",listValue([nullValue(),integerValue(9),boolValue(true),
                objectValue([ValueField("content",textValue("descriptive only"))])]))])
            let actual=hostReadViewParameterReference(parameterTestBinding(),input)
            let metadata=actual.field("metadata").getOrThrow()
            @Expect(metadata.field("type").getOrThrow().text,"object")
            @Expect(metadata.field("fields").getOrThrow().items.size,1)
            @Expect(metadata.field("fields").getOrThrow().items[0].field("name").getOrThrow().text,"unknown")
            let children=metadata.field("fields").getOrThrow().items[0].field("node").getOrThrow().field("items").getOrThrow()
            @Expect(children.items.size,4)
            @Expect(children.items[0].field("type").getOrThrow().text,"null")
            @Expect(children.items[1].field("value").getOrThrow().asNumberText(),"9")
            @Expect(children.items[2].field("value").getOrThrow().asBool())
            @Expect(input.field("path").isNone());@Expect(metadata.field("value").isNone())
        } finally {charge.close()}
    }
    @TestCase
    func frozenRequestKeepsExactOriginal32768ControlBytesAndOnlyOriginalInput(): Unit {
        let charge=reserveNativeDocumentPayload(HOST_READ_VIEW_INPUT_BYTES+65536)
        try {
            let content=String.fromUtf8(Array<UInt8>(32768,repeat:1))
            let input=objectValue([ValueField("path",textValue("new.txt")),ValueField("content",textValue(content))])
            let binding=parameterTestBinding();let actual=hostReadViewParameterReference(binding,input)
            let described=actual.field("metadata").getOrThrow().field("fields").getOrThrow().items[1].field("node").getOrThrow()
            @Expect(described.field("utf8_bytes").getOrThrow().asNumberText(),"32768")
            @Expect(described.field("sha256").getOrThrow().text,modelPolicySha256Text(content))
            @Expect(!described.field("has_nul").getOrThrow().asBool());@Expect(described.field("value").isNone())
            @Expect(stringifyUnifiedJson(actual).size<16384)
            let frozen=hostReadViewReferencedRequest(binding,input,actual,parameterTestRequest(parameterTestCopy(actual))).value().getOrThrow()
            @Expect(frozen.field("input_reference").isNone())
            @Expect(stringifyUnifiedJson(frozen.field("input").getOrThrow()),stringifyUnifiedJson(input))
            @Expect(input.field("content").getOrThrow().text,content)
        } finally {charge.close()}
    }
    @TestCase
    func wrongCallDigestAndOriginalByteCountCannotBecomeAWorkerRequest(): Unit {
        let charge=reserveNativeDocumentPayload(65536)
        try {
            let input=objectValue([ValueField("arbitrary",textValue("original"))]);let binding=parameterTestBinding()
            let expected=hostReadViewParameterReference(binding,input)
            let wrongCall=parameterTestCopy(expected);wrongCall.field("binding").getOrThrow().put("call_id",textValue("different-call"))
            let wrongHash=parameterTestCopy(expected);wrongHash.put("input_sha256",textValue(modelPolicySha256Text("different input")))
            let wrongBytes=parameterTestCopy(expected);wrongBytes.put("input_bytes",integerValue(999))
            for (returned in [wrongCall,wrongHash,wrongBytes]) {
                let rejected=hostReadViewReferencedRequest(binding,input,expected,parameterTestRequest(returned))
                @Expect(rejected.isError());@Expect(rejected.error().getOrThrow().code,"read_view.parameter_reference_changed") }
        } finally {charge.close()}
    }
    @TestCase
    func alteredMetadataUnknownFieldAndInputReplacementAreRejectedBeforeCollection(): Unit {
        let charge=reserveNativeDocumentPayload(65536)
        try {
            let input=objectValue([ValueField("arbitrary",textValue("original"))]);let binding=parameterTestBinding()
            let expected=hostReadViewParameterReference(binding,input);let metadata=parameterTestCopy(expected)
            metadata.field("metadata").getOrThrow().field("fields").getOrThrow().items[0].put("name",textValue("substituted"))
            @Expect(hostReadViewReferencedRequest(binding,input,expected,parameterTestRequest(metadata)).isError())
            let extra=parameterTestRequest(parameterTestCopy(expected));extra.put("input",input)
            @Expect(hostReadViewReferencedRequest(binding,input,expected,extra).error().getOrThrow().code,"read_view.parameter_reference_invalid")
            let changed=objectValue([ValueField("arbitrary",textValue("changed after capture"))])
            @Expect(hostReadViewReferencedRequest(binding,changed,expected,parameterTestRequest(parameterTestCopy(expected))).isError())
            @Expect(input.field("arbitrary").getOrThrow().text,"original")
        } finally {charge.close()}
    }
    @TestCase
    func TransportSelectionIsExplicitAndCannotGrantReadonlyServices(): Unit {
        let empty=objectValue([]);let digest="sha256:"+modelPolicySha256Text("actual package")
        let original=HostPluginHttpConfiguration("/actual-settings","workspace",digest,empty,"configuration",[],[])
        let selected=HostPluginHttpConfiguration("/actual-settings","workspace",digest,empty,"configuration",[],[],readViewParameterReferences:["write"])
        @Expect(!original.usesReadViewParameterReference("write"));@Expect(selected.usesReadViewParameterReference("write"))
        @Expect(!selected.usesReadViewParameterReference("edit"));@Expect(selected.ordinaryReadTools.size,0);@Expect(selected.readOnlyTools.size,0)
        let plugin=objectValue([ValueField("namespace",textValue("workspace")),ValueField("package_digest",textValue(digest)),
            ValueField("configuration",empty),ValueField("requests",listValue([])),ValueField("credentials",listValue([])),
            ValueField("read_view_parameter_references",listValue([textValue("write"),textValue("write")]))])
        @Expect(!hostPluginReadViewConfigurationFields(plugin))
    }
}
