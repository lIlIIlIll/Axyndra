package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func frozenDocumentResultTestParent():AgentValue{
    objectValue([ValueField("input",objectValue([])),ValueField("configuration",objectValue([])),ValueField("host_plan",objectValue([
        ValueField("version",textValue(PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA)),ValueField("binding",documentTestBinding()),
        ValueField("intents",listValue([documentPayloadTestIntent(write:true).field("intent").getOrThrow()])),
        ValueField("result_payload",documentPayloadTestValue()),ValueField("result_codec",textValue("axyndra.agent-value-json/v1")),
        ValueField("is_error",boolValue(false))]))])
}

@Test
class PluginDocumentFrozenResultTests{
    @TestCase
    func resultDescriptionDoesNotGrantASecondChildOrBroadenTheFrozenIntent():Unit{
        let parent=frozenDocumentResultTestParent();let host=parent.field("host_plan").getOrThrow()
        @Expect(pluginDocumentFrozenResultValid(host))
        let child=pluginDocumentChildArguments(parent,"todo-1").value().getOrThrow()
        @Expect(canonicalAgentValue(child),canonicalAgentValue(documentPayloadTestIntent(write:true)))
        @Expect(pluginDocumentChildArguments(parent,"result").isError())
        host.put("result_authority",objectValue([ValueField("key",textValue("foreign"))]))
        @Expect(!pluginDocumentFrozenResultValid(host));@Expect(pluginDocumentChildArguments(parent,"todo-1").isError())
    }
    @TestCase
    func malformedFrozenResultNeverDerivesAnOtherwiseValidDocumentChild():Unit{
        for(field in [ValueField("result_codec",textValue("axyndra.stored-value/v1")),ValueField("is_error",textValue("false")),
            ValueField("result_payload",textValue("blob:sha256:"+modelPolicySha256Text("null"))),ValueField("result_payload",nullValue())]){
            let parent=frozenDocumentResultTestParent();let host=parent.field("host_plan").getOrThrow()
            host.put(field.name,field.value)
            @Expect(!pluginDocumentFrozenResultValid(host));@Expect(pluginDocumentChildArguments(parent,"todo-1").isError())
        }
        for(bytes in [0,8388609]){
            let parent=frozenDocumentResultTestParent();let host=parent.field("host_plan").getOrThrow()
            host.field("result_payload").getOrThrow().put("bytes",integerValue(bytes))
            @Expect(!pluginDocumentFrozenResultValid(host));@Expect(pluginDocumentChildArguments(parent,"todo-1").isError())
        }
    }
}
