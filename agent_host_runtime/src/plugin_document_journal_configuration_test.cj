package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func journalProfileTestPolicy():AgentValue{
    objectValue([ValueField("schema",textValue(ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA)),
        ValueField("fields",listValue([
            objectValue([ValueField("path",listValue([textValue("classification")])),ValueField("prefix_bytes",integerValue(64)),ValueField("ascii_trimmed_length",boolValue(false))]),
            objectValue([ValueField("path",listValue([textValue("key")])),ValueField("prefix_bytes",integerValue(0)),ValueField("ascii_trimmed_length",boolValue(true))])])),
        ValueField("scope_classification_path",listValue([textValue("classification")])),ValueField("scope_key_path",listValue([textValue("key")])),
        ValueField("scopes",listValue([objectValue([ValueField("classification",textValue("public")),ValueField("key_match",textValue("text_fallback_empty"))])]))])
}
func journalProfileTestValue(extra!:Bool=false):AgentValue{
    let packageDigest="sha256:"+modelPolicySha256Text("actual-package")
    let backends=ArrayList<AgentValue>()
    for(key in if(extra){["journal","stream-only"]}else{["journal"]}){
        backends.add(objectValue([ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue(packageDigest)),
            ValueField("key",textValue(key)),ValueField("purpose",textValue("event-latest-structural-read")),
            ValueField("access",journalProfileTestPolicy()),ValueField("view",objectValue([
                ValueField("schema",textValue(ROW_JOURNAL_LATEST_VIEW_SCHEMA)),ValueField("group_key_path",listValue([textValue("id")])),
                ValueField("ordinal",textValue("event-primary-key")),ValueField("fold",textValue("last-value-first-position"))]))]))}
    let keys=listValue((if(extra){["journal","stream-only"]}else{["journal"]}).map{key=>textValue(key)})
    objectValue([ValueField("version",integerValue(1)),ValueField("backends",listValue(backends.toArray())),
        ValueField("providers",listValue([objectValue([ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue(packageDigest)),
            ValueField("provider",textValue("prepare_latest_context")),ValueField("keys",keys)])])),
        ValueField("tools",listValue([objectValue([ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue(packageDigest)),
            ValueField("contribution",textValue("plugin.axyndra:memory.recall")),ValueField("provider",textValue("prepare_latest_document")),ValueField("keys",keys)])]))])
}
func journalProfileTestDocuments(payloads!:Bool=true,provider!:String="prepare_latest_document"):AgentValue{
    let tool=objectValue([ValueField("name",textValue("recall")),ValueField("documents",listValue([
        objectValue([ValueField("key",textValue("journal")),ValueField("read",boolValue(true)),ValueField("write",boolValue(false))])])),
        ValueField("preparation_provider",textValue(provider)),ValueField("payload_references",boolValue(payloads)),
        ValueField("tool_payload_limits",OrdinaryToolPayloadLimits("recall").value())])
    objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
        ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue("sha256:"+modelPolicySha256Text("actual-package"))),
        ValueField("tools",listValue([tool])),ValueField("backends",listValue([objectValue([
            ValueField("key",textValue("journal")),ValueField("layout",textValue("opaque-fact-events-v3"))])]))])]))])
}
func journalProfileTestSetup(root:Path,stream!:Bool=true):Unit{
    Directory.create(root.join("plugins"))
    contextWindowWrite(root,"documents.json",journalProfileTestDocuments())
    contextWindowWrite(root,"document-context.json",contextWindowProfile(["journal","base-only"],provider:"prepare_latest_context"))
    if(stream){contextWindowWrite(root,"document-journal-streams.json",journalProfileTestValue(extra:true))}
}

@Test
class HostDocumentJournalConfigurationTests {
    @TestCase
    func ClosedOperatorPurposeRejectsAuthoritySqlDuplicatesAndUnmappedKeys():Unit{
        @Expect(hostDocumentJournalConfigurationValid(journalProfileTestValue()))
        for(field in ["sql","source","grant","tables","private_fence"]){
            let value=journalProfileTestValue();value.put(field,textValue("caller selected"));@Expect(!hostDocumentJournalConfigurationValid(value))}
        let duplicate=journalProfileTestValue();let row=duplicate.field("backends").getOrThrow().items[0]
        duplicate.put("backends",listValue([row,row]));@Expect(!hostDocumentJournalConfigurationValid(duplicate))
        let unknown=journalProfileTestValue();unknown.field("providers").getOrThrow().items[0].put("keys",listValue([textValue("unmapped")]))
        @Expect(!hostDocumentJournalConfigurationValid(unknown))
        let purpose=journalProfileTestValue();purpose.field("backends").getOrThrow().items[0].put("purpose",textValue("write-anything"))
        @Expect(!hostDocumentJournalConfigurationValid(purpose))
        let alias=journalProfileTestValue();alias.field("tools").getOrThrow().items[0].put("contribution",textValue("recall"))
        @Expect(!hostDocumentJournalConfigurationValid(alias))
    }
    @TestCase
    func ActualContextKeysIntersectBothOldRightsAndTheDeclaredSoleBackend():Unit{
        let root=Directory.createTemp("/tmp")
        try{journalProfileTestSetup(root)
            let config=loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory","sha256:"+modelPolicySha256Text("actual-package"),"prepare_latest_context","",true).value().getOrThrow()
            @Expect(config.permits("journal"));@Expect(!config.permits("base-only"));@Expect(!config.permits("stream-only"))
            @Expect(config.access("journal").isSome());@Expect(config.view("journal").isSome());@Expect(config.access("stream-only").isNone())
            @Expect(config.validateCurrent().isOk())
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func AnyPolicyWholeFileOrBaseRevocationInvalidatesTheFrozenRead():Unit{
        let root=Directory.createTemp("/tmp")
        try{journalProfileTestSetup(root);let digest="sha256:"+modelPolicySha256Text("actual-package")
            let first=loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_context","",true).value().getOrThrow()
            let changed=journalProfileTestValue(extra:true)
            changed.field("backends").getOrThrow().items[0].field("view").getOrThrow().put("group_key_path",listValue([textValue("another-id")]))
            contextWindowWrite(root,"document-journal-streams.json",changed)
            @Expect(first.validateCurrent().isError())
            let second=loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_context","",true).value().getOrThrow()
            @Expect(first.digest!=second.digest)
            let encoded=stringifyUnifiedJson(changed)+" "
            File.writeTo(root.join("plugins/document-journal-streams.json"),encoded.toArray())
            @Expect(second.validateCurrent().isError())
            let third=loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_context","",true).value().getOrThrow()
            contextWindowWrite(root,"document-context.json",objectValue([ValueField("version",integerValue(1)),ValueField("providers",listValue([]))]))
            @Expect(third.validateCurrent().isError())
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func ToolReadsRequireTheOriginalProviderPayloadProfileAndFullPublishedName():Unit{
        let root=Directory.createTemp("/tmp")
        try{journalProfileTestSetup(root);let digest="sha256:"+modelPolicySha256Text("actual-package")
            let config=loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_document","plugin.axyndra:memory.recall",false).value().getOrThrow()
            @Expect(config.permits("journal"));@Expect(!config.contextRead);@Expect(config.validateCurrent().isOk())
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_document","recall",false).isError())
            contextWindowWrite(root,"documents.json",journalProfileTestDocuments(payloads:false))
            @Expect(config.validateCurrent().isError())
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_document","plugin.axyndra:memory.recall",false).isError())
            contextWindowWrite(root,"documents.json",journalProfileTestDocuments(provider:"another_provider"))
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_document","plugin.axyndra:memory.recall",false).isError())
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func AnotherPackageProviderOrToolParentCannotBorrowContextRights():Unit{
        let root=Directory.createTemp("/tmp")
        try{journalProfileTestSetup(root);let digest="sha256:"+modelPolicySha256Text("actual-package")
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"another_provider","",true).isError())
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory","sha256:"+modelPolicySha256Text("another-package"),"prepare_latest_context","",true).isError())
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_context","plugin.axyndra:memory.recall",true).isError())
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_document","plugin.other.recall",false).isError())
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func MissingNewFileLeavesOriginalDocumentAndContextLoadersIntact():Unit{
        let root=Directory.createTemp("/tmp")
        try{journalProfileTestSetup(root,stream:false);let digest="sha256:"+modelPolicySha256Text("actual-package")
            @Expect(loadHostPluginDocumentConfiguration(root.toString(),"axyndra:memory",digest).isOk())
            @Expect(loadHostPluginDocumentContextConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_context").isOk())
            @Expect(loadHostPluginDocumentJournalReadConfiguration(root.toString(),"axyndra:memory",digest,"prepare_latest_context","",true).isError())
        }finally{remove(root,recursive:true)}
    }
}
