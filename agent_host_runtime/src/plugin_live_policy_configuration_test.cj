package agent_host_runtime

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func liveProfileTestPackage():String{"sha256:"+modelPolicySha256Text("live-profile-package")}
private func liveProfileTestCeiling():AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_CEILING_SCHEMA)),ValueField("documents",listValue([
        objectValue([ValueField("key",textValue("journal")),ValueField("operations",listValue([textValue("row_journal.append")]))])])),
        ValueField("filesystem",listValue([]))])
}
private func liveProfileTestValue():AgentValue{
    objectValue([ValueField("version",integerValue(1)),ValueField("tools",listValue([objectValue([
        ValueField("namespace",textValue("axyndra:live-fixture")),ValueField("package_digest",textValue(liveProfileTestPackage())),
        ValueField("contribution",textValue("plugin.axyndra:live-fixture.inspect")),ValueField("read_provider",textValue("fixture_read")),
        ValueField("policy_provider",textValue("fixture_policy")),ValueField("data_schema",textValue("axyndra.fixture-policy-query/v1")),
        ValueField("key",textValue("journal")),ValueField("effect_ceiling",liveProfileTestCeiling())])]))])
}
private func liveProfileTestWrite(root:Path,name:String,value:AgentValue):Unit{
    File.writeTo(root.join("plugins").join(name),stringifyUnifiedJson(value).toArray())
}
private func liveProfileTestDocuments(write:Bool):AgentValue{
    objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
        ValueField("namespace",textValue("axyndra:live-fixture")),ValueField("package_digest",textValue(liveProfileTestPackage())),
        ValueField("backends",listValue([objectValue([ValueField("key",textValue("journal")),ValueField("layout",textValue("opaque-fact-events-v3"))])])),
        ValueField("tools",listValue([objectValue([ValueField("name",textValue("inspect")),
            ValueField("preparation_provider",textValue("fixture_read")),ValueField("payload_references",boolValue(true)),
            ValueField("tool_payload_limits",OrdinaryToolPayloadLimits("inspect").value()),
            ValueField("documents",listValue([objectValue([ValueField("key",textValue("journal")),
                ValueField("read",boolValue(true)),ValueField("write",boolValue(write))])]))])]))])]))])
}
private func liveProfileTestSetup(root:Path,write!:Bool=true,live!:Bool=true):Unit{
    Directory.create(root.join("plugins"));liveProfileTestWrite(root,"documents.json",liveProfileTestDocuments(write))
    let access=objectValue([ValueField("schema",textValue(ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA)),ValueField("fields",listValue([
        objectValue([ValueField("path",listValue([textValue("classification")])),ValueField("prefix_bytes",integerValue(64)),ValueField("ascii_trimmed_length",boolValue(false))]),
        objectValue([ValueField("path",listValue([textValue("key")])),ValueField("prefix_bytes",integerValue(0)),ValueField("ascii_trimmed_length",boolValue(true))])])),
        ValueField("scope_classification_path",listValue([textValue("classification")])),ValueField("scope_key_path",listValue([textValue("key")])),
        ValueField("scopes",listValue([objectValue([ValueField("classification",textValue("public")),ValueField("key_match",textValue("text_fallback_empty"))])]))])
    let view=objectValue([ValueField("schema",textValue(ROW_JOURNAL_LATEST_VIEW_SCHEMA)),ValueField("group_key_path",listValue([textValue("id")])),
        ValueField("ordinal",textValue("event-primary-key")),ValueField("fold",textValue("last-value-first-position"))])
    liveProfileTestWrite(root,"document-journal-streams.json",objectValue([ValueField("version",integerValue(1)),
        ValueField("backends",listValue([objectValue([ValueField("namespace",textValue("axyndra:live-fixture")),ValueField("package_digest",textValue(liveProfileTestPackage())),
            ValueField("key",textValue("journal")),ValueField("purpose",textValue("event-latest-structural-read")),ValueField("access",access),ValueField("view",view)])])),
        ValueField("providers",listValue([])),ValueField("tools",listValue([objectValue([
            ValueField("namespace",textValue("axyndra:live-fixture")),ValueField("package_digest",textValue(liveProfileTestPackage())),
            ValueField("contribution",textValue("plugin.axyndra:live-fixture.inspect")),ValueField("provider",textValue("fixture_read")),
            ValueField("keys",listValue([textValue("journal")]))])]))]))
    if(live){liveProfileTestWrite(root,"live-policy.json",liveProfileTestValue())}
}

@Test
class HostPluginLivePolicyConfigurationTests{
    @TestCase
    func MissingOptInKeepsOriginalToolReadRightsAndNoLiveFamily():Unit{
        let root=Directory.createTemp("/tmp")
        try{liveProfileTestSetup(root,live:false)
            @Expect(loadHostPluginDocumentConfiguration(root.toString(),"axyndra:live-fixture",liveProfileTestPackage()).isOk(),true)
            @Expect(loadHostPluginLivePolicyConfiguration(root.toString(),"axyndra:live-fixture",liveProfileTestPackage(),
                "plugin.axyndra:live-fixture.inspect").value().getOrThrow().isNone(),true)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func ClosedMappingRejectsSqlAuthorityUnknownFieldsAndDuplicateTools():Unit{
        @Expect(hostPluginLivePolicyConfigurationValid(liveProfileTestValue()),true)
        for(field in ["sql","source","read_grant","private_fence","table"]){
            let value=liveProfileTestValue();value.field("tools").getOrThrow().items[0].put(field,textValue("untrusted"))
            @Expect(hostPluginLivePolicyConfigurationValid(value),false)}
        let duplicate=liveProfileTestValue();let row=duplicate.field("tools").getOrThrow().items[0]
        duplicate.put("tools",listValue([row,row]));@Expect(hostPluginLivePolicyConfigurationValid(duplicate),false)
    }
    @TestCase
    func LiveAppendCeilingCannotWidenOriginalReadonlyDocumentGrant():Unit{
        let root=Directory.createTemp("/tmp")
        try{liveProfileTestSetup(root,write:false)
            @Expect(loadHostPluginLivePolicyConfiguration(root.toString(),"axyndra:live-fixture",liveProfileTestPackage(),
                "plugin.axyndra:live-fixture.inspect").isError(),true)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func WholeProfileBytesAndOriginalReadRevocationInvalidateTheSameSelection():Unit{
        let root=Directory.createTemp("/tmp")
        try{liveProfileTestSetup(root)
            let selected=loadHostPluginLivePolicyConfiguration(root.toString(),"axyndra:live-fixture",liveProfileTestPackage(),
                "plugin.axyndra:live-fixture.inspect").value().getOrThrow().getOrThrow()
            @Expect(selected.validateCurrent().isOk(),true)
            File.writeTo(root.join("plugins/live-policy.json"),(stringifyUnifiedJson(liveProfileTestValue())+" ").toArray())
            @Expect(selected.validateCurrent().isError(),true)
            let changed=loadHostPluginLivePolicyConfiguration(root.toString(),"axyndra:live-fixture",liveProfileTestPackage(),
                "plugin.axyndra:live-fixture.inspect").value().getOrThrow().getOrThrow()
            @Expect(changed.digest!=selected.digest,true)
            liveProfileTestWrite(root,"documents.json",liveProfileTestDocuments(false))
            @Expect(changed.validateCurrent().isError(),true)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func AnotherPackageOrProviderCannotBorrowThisOptIn():Unit{
        let root=Directory.createTemp("/tmp")
        try{liveProfileTestSetup(root)
            @Expect(loadHostPluginLivePolicyConfiguration(root.toString(),"axyndra:live-fixture","sha256:"+modelPolicySha256Text("other"),
                "plugin.axyndra:live-fixture.inspect").value().getOrThrow().isNone(),true)
            let changed=liveProfileTestValue();changed.field("tools").getOrThrow().items[0].put("read_provider",textValue("another_provider"))
            liveProfileTestWrite(root,"live-policy.json",changed)
            @Expect(loadHostPluginLivePolicyConfiguration(root.toString(),"axyndra:live-fixture",liveProfileTestPackage(),
                "plugin.axyndra:live-fixture.inspect").isError(),true)
        }finally{remove(root,recursive:true)}
    }
}
