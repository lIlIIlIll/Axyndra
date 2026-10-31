package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func documentContextTestRequest():AgentValue{
    let digest=String.fromUtf8(Array<Byte>(64,repeat:b'a'))
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_CONTEXT_READ_SCHEMA)),
        ValueField("projection_digest",textValue(digest)),ValueField("keys",listValue([textValue("goal")])),
        ValueField("binding",objectValue([ValueField("namespace",textValue("axyndra:workflow")),ValueField("package_digest",textValue("sha256:"+digest)),
            ValueField("generation",textValue("1")),ValueField("configuration_digest",textValue(digest)),
            ValueField("thread_id",textValue("thread")),ValueField("lane_id",textValue("main")),ValueField("run_id",textValue("run")),
            ValueField("epoch",integerValue(1)),ValueField("provider",textValue("goal_context"))]))])}

@Test
class PluginDocumentContextReadTests{
    @TestCase
    func separateReadProfileCannotBorrowAToolParentOrWriteField():Unit{
        let request=documentContextTestRequest();@Expect(pluginDocumentContextReadRequestValid(request));@Expect(pluginDocumentReadRequestValid(request))
        for(name in ["parent_call_id","contribution","implementation_fingerprint","schema_digest"]){
            let copy=documentContextTestRequest();copy.field("binding").getOrThrow().put(name,textValue("borrowed"))
            @Expect(!pluginDocumentReadRequestValid(copy))}
        request.put("write",boolValue(true));@Expect(!pluginDocumentReadRequestValid(request))
    }
    @TestCase
    func unknownSchemaAndMalformedCurrentIdentityRemainClosed():Unit{
        for(schema in ["axyndra.plugin-document-context-read/v2",PLUGIN_DOCUMENT_READ_SCHEMA,PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA]){
            let request=documentContextTestRequest();request.put("schema",textValue(schema));@Expect(!pluginDocumentReadRequestValid(request))}
        for(generation in ["0","01","-1","18446744073709551616"]){
            let request=documentContextTestRequest();request.field("binding").getOrThrow().put("generation",textValue(generation))
            @Expect(!pluginDocumentReadRequestValid(request))}
        let request=documentContextTestRequest();request.field("binding").getOrThrow().put("epoch",integerValue(0))
        @Expect(!pluginDocumentReadRequestValid(request))
    }
    @TestCase
    func onlyExactUniqueLogicalKeysWithinTheOriginalEightKeyLimit():Unit{
        let request=documentContextTestRequest();request.put("keys",listValue(Array<AgentValue>(8,{index=>textValue("key"+index.toString())})))
        @Expect(pluginDocumentReadRequestValid(request))
        request.put("keys",listValue(Array<AgentValue>(9,{index=>textValue("key"+index.toString())})));@Expect(!pluginDocumentReadRequestValid(request))
        for(keys in [listValue([]),listValue([textValue("goal"),textValue("goal")]),listValue([textValue("../goal")]),listValue([integerValue(1)])]){
            let copy=documentContextTestRequest();copy.put("keys",keys);@Expect(!pluginDocumentReadRequestValid(copy))}
    }
}
