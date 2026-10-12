package agent_domain

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func contextWindowTestReplace(value:AgentValue,key:String,next:AgentValue):AgentValue{
    let fields=ArrayList<ValueField>()
    for(field in value.fields){fields.add(if(field.name==key){ValueField(key,next)}else{field})}
    objectValue(fields.toArray())
}
func contextWindowTestRequest():AgentValue{
    let digest=modelPolicySha256Text("window-test")
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_CONTEXT_WINDOW_READ_SCHEMA)),
        ValueField("binding",objectValue([ValueField("namespace",textValue("axyndra:memory")),
            ValueField("package_digest",textValue("sha256:"+digest)),ValueField("generation",textValue("1")),
            ValueField("configuration_digest",textValue(digest)),ValueField("thread_id",textValue("thread")),
            ValueField("lane_id",textValue("lane")),ValueField("run_id",textValue("run")),
            ValueField("epoch",integerValue(1)),ValueField("provider",textValue("prepare_window_context"))])),
        ValueField("projection_digest",textValue(digest)),ValueField("key",textValue("journal")),
        ValueField("window",objectValue([ValueField("kind",textValue("manifest"))])),ValueField("prior_facts",listValue([]))])
}
func contextWindowTestLink(parent:Bool):ContextReadFactLink{
    let digest=modelPolicySha256Text("window-test")
    let origin=if(parent){ContextReadOrigin("axyndra:memory","sha256:"+digest,digest,digest,digest,"request","parent",
        parentKind:"direct",parentOperationId:"parent-op")}
        else{ContextReadOrigin("axyndra:memory","sha256:"+digest,digest,digest,digest,"request","")}
    ContextReadFactLink(OperationId("op"),RunId("run"),ItemId("source"),ItemId("result"),"receipt",origin,digest,10)
}

@Test
class PluginDocumentContextWindowReadTests{
    @TestCase
    func contextNineAndToolTwelveDescriptorsRemainSeparate():Unit{
        let request=contextWindowTestRequest()
        @Expect(pluginDocumentContextWindowReadRequestValid(request))
        @Expect(!pluginDocumentRowJournalReadRequestValid(request))
        @Expect(!pluginDocumentContextReadRequestValid(request))
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(request,"schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA))))
        let binding=request.field("binding").getOrThrow()
        let fields=ArrayList<ValueField>(binding.fields.toArray());fields.add(ValueField("parent_call_id",textValue("parent")))
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(request,"binding",objectValue(fields.toArray()))))
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(request,"binding",contextWindowTestReplace(binding,"epoch",numberValue("1e0")))))
    }
    @TestCase
    func fullPriorPrefixRequiresUniqueParentlessReferencesAndCanonicalWindow():Unit{
        let first=contextWindowTestRequest()
        let rows=objectValue([ValueField("kind",textValue("rows")),ValueField("manifest_fact",integerValue(0)),
            ValueField("offset",integerValue(0)),ValueField("count",integerValue(1))])
        let next=contextWindowTestReplace(contextWindowTestReplace(first,"window",rows),"prior_facts",contextReadFactLinksValue([contextWindowTestLink(false)]))
        @Expect(pluginDocumentContextWindowReadRequestValid(next))
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(next,"prior_facts",contextReadFactLinksValue([contextWindowTestLink(true)]))))
        let link=contextWindowTestLink(false).toValue()
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(next,"prior_facts",listValue([link,link]))))
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(next,"window",contextWindowTestReplace(rows,"count",integerValue(0)))))
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(next,"window",contextWindowTestReplace(rows,"offset",numberValue("0.0")))))
        @Expect(!pluginDocumentContextWindowReadRequestValid(contextWindowTestReplace(next,"window",first.field("window").getOrThrow())))
    }
    @TestCase
    func descriptiveResultMustMatchTheExactContextRequestDigest():Unit{
        let request=contextWindowTestRequest();let raw="{}";let digest=modelPolicySha256Text(raw)
        let payload=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
            ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
            ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(digest)),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])
        let result=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_READ_RESULT_SCHEMA)),
            ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("documents",listValue([objectValue([ValueField("key",textValue("journal")),ValueField("revision",integerValue(1)),ValueField("payload",payload)])]))])
        @Expect(pluginDocumentContextWindowReadResultValid(result,request))
        @Expect(!pluginDocumentContextWindowReadResultValid(contextWindowTestReplace(result,"request_digest",textValue(digest)),request))
        @Expect(!pluginDocumentContextWindowReadResultValid(result,contextWindowTestReplace(request,"key",textValue("other"))))
    }
}
