package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func rowWindowTestReference(raw:String):AgentValue{
    PluginDocumentPayloadReference(modelPolicySha256Text(raw),raw.size).value()
}
func rowWindowTestRequest():AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA)),ValueField("binding",documentTestBinding()),
        ValueField("projection_digest",textValue(modelPolicySha256Text("projection"))),ValueField("key",textValue("memory")),
        ValueField("window",objectValue([ValueField("kind",textValue("manifest"))])),ValueField("prior_facts",listValue([]))])
}
func rowWindowTestIntent(append:Bool):AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA)),ValueField("binding",documentTestBinding()),
        ValueField("intent",objectValue([ValueField("id",textValue("append-1")),ValueField("key",textValue("memory")),
            ValueField("mode",textValue(if(append){"append"}else{"read"})),ValueField("expected_revision",integerValue(1)),
            ValueField("manifest_payload",rowWindowTestReference("actual-manifest")),
            ValueField("next_payload",if(append){rowWindowTestReference("actual-proposal")}else{nullValue()})]))])
}

@Test
class PluginDocumentRowJournalWindowTests{
    @TestCase
    func toolBindingAndManifestOrdinalCannotBeReplacedByParentlessOrPluginAuthority():Unit{
        let value=rowWindowTestRequest();@Expect(pluginDocumentRowJournalReadRequestValid(value))
        @Expect(!pluginDocumentReadRequestValid(value))
        value.field("binding").getOrThrow().put("parent_call_id",textValue(""));@Expect(!pluginDocumentRowJournalReadRequestValid(value))
        let authority=rowWindowTestRequest();authority.put("grant",boolValue(true));@Expect(!pluginDocumentRowJournalReadRequestValid(authority))
        let body=rowWindowTestRequest();body.put("window",objectValue([ValueField("kind",textValue("rows")),
            ValueField("manifest_fact",integerValue(0)),ValueField("offset",integerValue(0)),ValueField("count",integerValue(1))]))
        @Expect(!pluginDocumentRowJournalReadRequestValid(body))
    }
    @TestCase
    func pureReadAuthorityIsLimitedToTheExactExtensionNamespace():Unit{
        let request=rowWindowTestRequest()
        @Expect(pluginDocumentRowJournalReadAuthority(documentReadTestPlan(request,Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow"))))
        @Expect(!pluginDocumentRowJournalReadAuthority(documentReadTestPlan(request,Capability(CapabilityKind.WorkspaceRead))))
        @Expect(!pluginDocumentRowJournalReadAuthority(documentReadTestPlan(request,Capability(CapabilityKind.ExtensionInvoke,resource:"other"))))
    }
    @TestCase
    func newResultRequiresTheWholeActualRequestDigestAndPositiveManifestReference():Unit{
        let request=rowWindowTestRequest()
        let result=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_READ_RESULT_SCHEMA)),
            ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request)))),
            ValueField("documents",listValue([objectValue([ValueField("key",textValue("memory")),ValueField("revision",integerValue(1)),
                ValueField("payload",rowWindowTestReference("actual-empty-manifest"))])]))])
        @Expect(pluginDocumentRowJournalReadResultValid(result,request))
        result.field("documents").getOrThrow().items[0].put("revision",integerValue(0));@Expect(!pluginDocumentRowJournalReadResultValid(result,request))
        result.field("documents").getOrThrow().items[0].put("revision",integerValue(1))
        result.put("request_digest",textValue(modelPolicySha256Text("foreign")));@Expect(!pluginDocumentRowJournalReadResultValid(result,request))
        result.put("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(request))))
        result.field("documents").getOrThrow().items[0].field("payload").getOrThrow().put("authority",boolValue(true))
        @Expect(!pluginDocumentRowJournalReadResultValid(result,request))
    }
    @TestCase
    func intentBindingIsImmutableAndLogicalRevisionDoesNotBorrowTheEventCount():Unit{
        let raw=rowWindowTestIntent(true);let intent=parsePluginDocumentRowJournalIntent(raw).value().getOrThrow()
        raw.field("binding").getOrThrow().put("thread_id",textValue("other"))
        raw.field("intent").getOrThrow().put("expected_revision",integerValue(9000))
        intent.binding().put("generation",textValue("999"))
        @Expect(httpIntentText(intent.binding(),"thread_id"),"thread")
        @Expect(httpIntentText(intent.binding(),"generation"),"7")
        @Expect(intent.result().field("revision").getOrThrow().asNumberText(),"2")
        @Expect(httpIntentText(intent.result(),"schema"),PLUGIN_DOCUMENT_ROW_JOURNAL_RESULT_SCHEMA)
        @Expect(intent.result().field("manifest_payload").getOrThrow().field("sha256").getOrThrow().text,modelPolicySha256Text("actual-manifest"))
    }
    @TestCase
    func oldCompareExchangeAndUndeclaredCopyFieldsCannotEnterTheAppendDialect():Unit{
        @Expect(parsePluginDocumentIntent(rowWindowTestIntent(true)).isError())
        let bad=rowWindowTestIntent(true);bad.field("intent").getOrThrow().put("mode",textValue("compare_exchange"))
        @Expect(parsePluginDocumentRowJournalIntent(bad).isError())
        let absent=rowWindowTestIntent(true);absent.field("intent").getOrThrow().put("expected_revision",integerValue(0))
        @Expect(parsePluginDocumentRowJournalIntent(absent).isError())
        let extra=rowWindowTestIntent(true);extra.field("intent").getOrThrow().put("file",textValue("/tmp/foreign"))
        @Expect(parsePluginDocumentRowJournalIntent(extra).isError())
        let read=rowWindowTestIntent(false);read.field("intent").getOrThrow().put("next_payload",rowWindowTestReference("mutation"))
        @Expect(parsePluginDocumentRowJournalIntent(read).isError())
    }
    @TestCase
    func optionalExpiryOnlyRestrictsLiveUseAndCannotDecodeAsTheOldParent():Unit{
        let parent=documentTestParent(rowWindowTestIntent(true));let host=parent.field("host_plan").getOrThrow()
        host.put("version",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA));host.put("result_payload",rowWindowTestReference("{}"))
        host.put("result_codec",textValue("axyndra.agent-value-json/v1"));host.put("is_error",boolValue(false))
        @Expect(pluginDocumentRowJournalFrozenResultValid(host));@Expect(!pluginDocumentFrozenResultBaseValid(host))
        @Expect(!pluginDocumentRowJournalFrozenResultCurrent(host,99).isError())
        host.put("valid_until_millis",integerValue(100));@Expect(pluginDocumentRowJournalFrozenResultValid(host))
        @Expect(!pluginDocumentRowJournalFrozenResultCurrent(host,99).isError())
        @Expect(pluginDocumentRowJournalFrozenResultCurrent(host,100).isError())
        @Expect(pluginDocumentRowJournalFrozenResultValid(host))
        host.put("valid_until_millis",numberValue("1e2"));@Expect(!pluginDocumentRowJournalFrozenResultValid(host))
        host.put("valid_until_millis",integerValue(0));@Expect(!pluginDocumentRowJournalFrozenResultValid(host))
    }
}
