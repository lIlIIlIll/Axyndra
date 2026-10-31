package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func rowPageTestHeader(key:String,raw:String,first:Int64):AgentValue{
    objectValue([ValueField("key",textValue(key)),ValueField("kind",textValue("opaque")),ValueField("revision",integerValue(1)),
        ValueField("payload_sha256",textValue(modelPolicySha256Text(raw))),ValueField("payload_bytes",integerValue(raw.size)),
        ValueField("payload_json_bytes",integerValue(stringifyUnifiedJson(textValue(raw)).size)),ValueField("first_event_id",integerValue(first))])
}
func rowPageTestManifest(headers:Array<AgentValue>):AgentValue{
    objectValue([ValueField("schema",textValue(OPAQUE_ROW_JOURNAL_MANIFEST_SCHEMA)),ValueField("layout",textValue("opaque-fact-events-v3")),
        ValueField("state",objectValue([ValueField("sha256",textValue(modelPolicySha256Text("full-state"))),
            ValueField("chain_sha256",textValue(modelPolicySha256Text("full-history"))),ValueField("next_event_id",integerValue(headers.size+1)),
            ValueField("rows",integerValue(headers.size)),ValueField("events",integerValue(headers.size))])),
        ValueField("rows",listValue(headers)),ValueField("annotations",objectValue([ValueField("workspace_root",textValue("/actual-workspace")),
            ValueField("settings_root",textValue("/actual-settings")),ValueField("thread_id",textValue("actual-thread")),ValueField("lane_id",textValue("main"))]))])
}

@Test
class HostDocumentRowJournalPageTests{
    @TestCase
    func sixMiBActualAsciiBodyFitsTheOriginalEightMiBBoundary():Unit{
        let raw=String.fromUtf8(Array<Byte>(6291456,repeat:b'x'))
        let manifest=rowPageTestManifest([rowPageTestHeader("large",raw,1)])
        let digest=modelPolicySha256Text(stringifyUnifiedJson(manifest))
        let pages=hostRowJournalPages(manifest,digest).value().getOrThrow()
        @Expect(pages.items.size,1);@Expect(pages.items[0].field("count").getOrThrow().asNumberText(),"1")
        let body=objectValue([ValueField("schema",textValue(OPAQUE_ROW_JOURNAL_ROWS_SCHEMA)),ValueField("manifest_sha256",textValue(digest)),
            ValueField("offset",integerValue(0)),ValueField("rows",listValue([objectValue([ValueField("key",textValue("large")),
                ValueField("revision",integerValue(1)),ValueField("payload_sha256",textValue(modelPolicySha256Text(raw))),ValueField("payload",textValue(raw))])]))])
        @Expect(opaqueRowJournalRowsValid(body,manifest,digest,0,1))
        @Expect(pages.items[0].field("bytes").getOrThrow().asNumberText(),integerValue(stringifyUnifiedJson(body).size).asNumberText())
        @Expect(stringifyUnifiedJson(body).size<PLUGIN_DOCUMENT_MAX_BYTES)
    }
    @TestCase
    func allThreeThousandAndOneHeadersRemainInContiguousPages():Unit{
        let headers=ArrayList<AgentValue>()
        for(i in 0..3001){headers.add(rowPageTestHeader("record-"+i.toString(),"{\"content\":\"snow雪\"}",i+1))}
        let manifest=rowPageTestManifest(headers.toArray());let digest=modelPolicySha256Text(stringifyUnifiedJson(manifest))
        let pages=hostRowJournalPages(manifest,digest).value().getOrThrow()
        @Expect(pages.items.size,1);@Expect(pages.items[0].field("offset").getOrThrow().asNumberText(),"0")
        @Expect(pages.items[0].field("count").getOrThrow().asNumberText(),"3001")
    }
    @TestCase
    func quotedControlBytesAreCountedAndCannotWidenTheOriginalPayloadLimit():Unit{
        let raw="\u{0000}\n\"\\雪";let header=rowPageTestHeader("record",raw,1)
        let manifest=rowPageTestManifest([header]);let digest=modelPolicySha256Text(stringifyUnifiedJson(manifest))
        let pages=hostRowJournalPages(manifest,digest).value().getOrThrow();@Expect(pages.items.size,1)
        header.put("payload_bytes",integerValue(PLUGIN_DOCUMENT_MAX_BYTES));header.put("payload_json_bytes",integerValue(PLUGIN_DOCUMENT_MAX_BYTES+2))
        @Expect(hostRowJournalPages(manifest,digest).isError())
    }
    @TestCase
    func metadataCannotSelectDuplicateOrReorderedRowsOrAPluginGrant():Unit{
        let first=rowPageTestHeader("a","one",1);let second=rowPageTestHeader("a","two",2)
        @Expect(!opaqueRowJournalManifestValid(rowPageTestManifest([first,second])))
        second.put("key",textValue("b"));second.put("first_event_id",integerValue(1))
        @Expect(!opaqueRowJournalManifestValid(rowPageTestManifest([first,second])))
        let manifest=rowPageTestManifest([first]);manifest.put("grant",boolValue(true))
        @Expect(!opaqueRowJournalManifestValid(manifest))
    }
    @TestCase
    func windowConfigurationRequiresExplicitOriginalPayloadAndProviderLimits():Unit{
        let tool=objectValue([ValueField("name",textValue("memory")),ValueField("documents",listValue([]))])
        @Expect(hostDocumentToolConfigurationValid(tool))
        tool.put("read_windows",boolValue(true));@Expect(!hostDocumentToolConfigurationValid(tool))
        tool.put("payload_references",boolValue(true));tool.put("preparation_provider",textValue("prepare_window_document"))
        tool.put("tool_payload_limits",OrdinaryToolPayloadLimits("memory").value());@Expect(hostDocumentToolConfigurationValid(tool))
        tool.put("read_windows",textValue("true"));@Expect(!hostDocumentToolConfigurationValid(tool))
        @Expect(!hostDocumentToolConfigurationValid(listValue([])))
        let original=objectValue([ValueField("name",textValue("memory")),ValueField("documents",listValue([])),ValueField("read_windows",boolValue(false))])
        @Expect(hostDocumentToolConfigurationValid(original));original.put("grant",boolValue(true));@Expect(!hostDocumentToolConfigurationValid(original))
    }
}
