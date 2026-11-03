package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func latestViewDescriptorTestPolicy():AgentValue{
    objectValue([ValueField("schema",textValue(ROW_JOURNAL_LATEST_VIEW_SCHEMA)),
        ValueField("group_key_path",listValue([textValue("record"),textValue("id")])),
        ValueField("ordinal",textValue("event-primary-key")),ValueField("fold",textValue("last-value-first-position"))])
}
func latestViewDescriptorTestRequest(context:Bool):AgentValue{
    let value=journalStreamDescriptorTestRequest(context)
    value.put("schema",textValue(if(context){PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA}
        else{PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA}))
    value.put("view_policy_digest",textValue(modelPolicySha256Text("frozen descriptive view")));value
}
@Test
class RowJournalLatestViewDescriptorTests {
    @TestCase
    func MechanicalOperatorPolicyRejectsCallerSqlAndUnsupportedFoldOrKeyShapes():Unit{
        let value=latestViewDescriptorTestPolicy();let parsed=RowJournalLatestView.parse(value)
        @Expect(parsed.digest,modelPolicySha256Text(canonicalAgentValue(value)))
        for(field in ["sql","table","value_path","source","grant","namespace"]){
            let candidate=latestViewDescriptorTestPolicy();candidate.put(field,textValue("caller choice"));var refused=false
            try{let _=RowJournalLatestView.parse(candidate)}catch(_:Exception){refused=true};@Expect(refused,true)}
        for(field in ["schema","ordinal","fold"]){
            let candidate=latestViewDescriptorTestPolicy();candidate.put(field,textValue("unsupported"));var refused=false
            try{let _=RowJournalLatestView.parse(candidate)}catch(_:Exception){refused=true};@Expect(refused,true)}
        for(path in [listValue([]),listValue([numberValue("1")]),listValue([textValue("")])]){
            let candidate=latestViewDescriptorTestPolicy();candidate.put("group_key_path",path);var refused=false
            try{let _=RowJournalLatestView.parse(candidate)}catch(_:Exception){refused=true};@Expect(refused,true)}
    }
    @TestCase
    func ToolAndParentlessContextScopesCannotCrossV3OrReplaceEitherFrozenPolicyDigest():Unit{
        for(context in [false,true]){
            let request=latestViewDescriptorTestRequest(context)
            @Expect(pluginDocumentLatestJournalStreamReadRequestValid(request),!context)
            @Expect(pluginDocumentContextLatestJournalStreamReadRequestValid(request),context)
            @Expect(pluginDocumentJournalStreamReadRequestValid(request),false)
            @Expect(pluginDocumentContextJournalStreamReadRequestValid(request),false)
            request.put("schema",textValue(if(context){PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA}
                else{PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA}))
            @Expect(pluginDocumentLatestJournalStreamReadRequestValid(request),false)
            @Expect(pluginDocumentContextLatestJournalStreamReadRequestValid(request),false)
            for(field in ["access_policy_digest","view_policy_digest"]){
                let candidate=latestViewDescriptorTestRequest(context);candidate.put(field,textValue("caller policy"))
                @Expect(pluginDocumentLatestJournalStreamReadRequestValid(candidate),false)
                @Expect(pluginDocumentContextLatestJournalStreamReadRequestValid(candidate),false)}
        }
        for(field in ["group_key_path","sql","table","private_fence","prior_facts"]){
            let candidate=latestViewDescriptorTestRequest(false);candidate.put(field,latestViewDescriptorTestPolicy())
            @Expect(pluginDocumentLatestJournalStreamReadRequestValid(candidate),false)}
    }
    @TestCase
    func PublicReferenceAllowsLargeAggregateButNoPrivateBlindStateOrOldDialect():Unit{
        for(bytes in [66060288,67108865,268435456,Int64.Max]){
            let value=journalStreamDescriptorTestReference(bytes)
            value.put("schema",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_REFERENCE_SCHEMA))
            value.put("encoding",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_ENCODING))
            value.put("content_type",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_CONTENT_TYPE))
            @Expect(parsePluginDocumentLatestJournalStreamReference(value).value().getOrThrow().bytes,bytes)
            @Expect(parsePluginDocumentJournalStreamReference(value).isError(),true)
            value.put("blind_state",textValue(modelPolicySha256Text("unapproved private data")))
            @Expect(parsePluginDocumentLatestJournalStreamReference(value).isError(),true)
        }
    }
}
