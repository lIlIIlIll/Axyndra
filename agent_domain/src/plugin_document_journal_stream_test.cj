package agent_domain

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

func journalStreamDescriptorTestReference(bytes:Int64):AgentValue{
    let digest=modelPolicySha256Text("actual descriptive fixture, never a Source")
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_REFERENCE_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_ENCODING)),
        ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE))])
}
func journalStreamDescriptorTestRequest(context:Bool):AgentValue{
    let digest=modelPolicySha256Text("fixture")
    objectValue([ValueField("schema",textValue(if(context){PLUGIN_DOCUMENT_CONTEXT_JOURNAL_STREAM_READ_SCHEMA}else{PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA})),
        ValueField("binding",if(context){contextWindowTestRequest().field("binding").getOrThrow()}else{documentTestBinding()}),
        ValueField("projection_digest",textValue(digest)),ValueField("key",textValue("journal")),ValueField("access_policy_digest",textValue(digest))])
}
@Test
class PluginDocumentJournalStreamDescriptorTests {
    @TestCase
    func NewStreamReferenceCanDescribeSixtyThreeMiBAndLargerAggregateWithoutAllocatingItsBody():Unit{
        for(bytes in [1,66060288,67108865,268435456,Int64.Max]){
            let value=journalStreamDescriptorTestReference(bytes)
            let reference=parsePluginDocumentJournalStreamReference(value).value().getOrThrow()
            @Expect(reference.bytes,bytes);@Expect(canonicalAgentValue(reference.toValue()),canonicalAgentValue(value))
            @Expect(parsePluginDocumentPayloadReference(value).isError(),true)
        }
    }
    @TestCase
    func UnknownEncodingPathHashOrNoncanonicalLengthCannotBecomeAStreamDescriptor():Unit{
        for(field in ["artifact_ref","encoding","sha256","content_type","schema"]){
            let value=journalStreamDescriptorTestReference(1);value.put(field,textValue("changed"))
            @Expect(parsePluginDocumentJournalStreamReference(value).isError(),true)}
        for(bytes in [integerValue(0),integerValue(-1),numberValue("1e0"),numberValue("1.0"),textValue("1")]){
            let value=journalStreamDescriptorTestReference(1);value.put("bytes",bytes)
            @Expect(parsePluginDocumentJournalStreamReference(value).isError(),true)}
        let extra=journalStreamDescriptorTestReference(1);extra.put("path",textValue("/tmp/private"))
        @Expect(parsePluginDocumentJournalStreamReference(extra).isError(),true)
    }
    @TestCase
    func ToolTwelveAndParentlessContextNineBindingsCannotCrossTheNewStrictDialects():Unit{
        for(context in [false,true]){
            let request=journalStreamDescriptorTestRequest(context)
            @Expect(pluginDocumentContextJournalStreamReadRequestValid(request),context)
            @Expect(pluginDocumentJournalStreamReadRequestValid(request),!context)
            @Expect(pluginDocumentReadRequestValid(request),false)
            @Expect(pluginDocumentRowJournalReadRequestValid(request),false)
            @Expect(pluginDocumentContextWindowReadRequestValid(request),false)
            request.put("schema",textValue(if(context){PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA}else{PLUGIN_DOCUMENT_CONTEXT_JOURNAL_STREAM_READ_SCHEMA}))
            @Expect(pluginDocumentContextJournalStreamReadRequestValid(request),false)
            @Expect(pluginDocumentJournalStreamReadRequestValid(request),false)
        }
    }
    @TestCase
    func NativeCannotSelectSqlFieldsTablesOffsetsOrAnUnfrozenAccessPolicy():Unit{
        for(field in ["sql","table","path","fields","window","offset","prior_facts"]){
            let request=journalStreamDescriptorTestRequest(false);request.put(field,textValue("caller choice"))
            @Expect(pluginDocumentJournalStreamReadRequestValid(request),false)}
        let request=journalStreamDescriptorTestRequest(true);request.put("access_policy_digest",textValue("not a frozen digest"))
        @Expect(pluginDocumentContextJournalStreamReadRequestValid(request),false)
    }
    @TestCase
    func WholeReferenceLogicalRevisionAndActualRequestDigestAreAllRequiredForTheResult():Unit{
        for(context in [false,true]){
            let request=journalStreamDescriptorTestRequest(context)
            let item=objectValue([ValueField("key",textValue("journal")),ValueField("revision",integerValue(1)),
                ValueField("stream",journalStreamDescriptorTestReference(66060288))])
            let result=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_RESULT_SCHEMA)),
                ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),ValueField("documents",listValue([item]))])
            @Expect(pluginDocumentJournalStreamReadResultDataValid(result,modelPolicySha256Text(canonicalAgentValue(request)),"journal"),true)
            @Expect(pluginDocumentJournalStreamReadResultValid(result,request),!context)
            @Expect(pluginDocumentContextJournalStreamReadResultValid(result,request),context)
            result.field("documents").getOrThrow().items[0].put("revision",integerValue(0))
            @Expect(pluginDocumentJournalStreamReadResultDataValid(result,modelPolicySha256Text(canonicalAgentValue(request)),"journal"),false)
        }
    }
}
