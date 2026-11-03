package agent_host_runtime

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func contextWindowProfile(keys:Array<String>,provider!:String="prepare_window_context",digest!:String="sha256:"+modelPolicySha256Text("actual-package")):AgentValue{
    objectValue([ValueField("version",integerValue(1)),ValueField("providers",listValue([
        objectValue([ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue(digest)),
            ValueField("provider",textValue(provider)),ValueField("keys",listValue(keys.map{key=>textValue(key)}))])]))])
}
func contextWindowBase(keys:Array<String>,encoded!:String="original-whole-base",witness!:String="original-base-witness"):HostPluginDocumentContextConfiguration{
    HostPluginDocumentContextConfiguration("/actual-settings","axyndra:memory","sha256:"+modelPolicySha256Text("actual-package"),
        "prepare_window_context",encoded,witness,listValue(keys.map{key=>textValue(key)}))
}
func contextWindowWrite(root:Path,name:String,value:AgentValue):Unit{
    File.writeTo(root.join("plugins").join(name),stringifyUnifiedJson(value).toArray())
}

@Test
class HostDocumentContextWindowConfigurationTests {
    @TestCase
    func windowKeysIntersectTheOriginalReadonlyGrant():Unit{
        let encoded=stringifyUnifiedJson(contextWindowProfile(["journal","window-only"]))
        let config=HostPluginDocumentContextWindowConfiguration("/actual-settings",contextWindowBase(["journal","base-only"]),
            encoded,"whole-window-witness",listValue([textValue("journal"),textValue("window-only")]))
        @Expect(config.permits("journal"));@Expect(!config.permits("base-only"));@Expect(!config.permits("window-only"))
        @Expect(!config.permits("../journal"));@Expect(!config.permits("other-thread"))
    }
    @TestCase
    func frozenDigestCoversWholeBaseAndWindowBytesAndBothWitnesses():Unit{
        let keys=listValue([textValue("journal")]);let original=stringifyUnifiedJson(contextWindowProfile(["journal"]))
        let frozen=HostPluginDocumentContextWindowConfiguration("/actual-settings",contextWindowBase(["journal"]),original,"window-witness",keys)
        for(base in [contextWindowBase(["journal"],encoded:"changed unrelated base row"),contextWindowBase(["journal"],witness:"changed base witness")]){
            @Expect(HostPluginDocumentContextWindowConfiguration("/actual-settings",base,original,"window-witness",keys).digest!=frozen.digest)}
        @Expect(HostPluginDocumentContextWindowConfiguration("/actual-settings",contextWindowBase(["journal"]),original+" ","window-witness",keys).digest!=frozen.digest)
        @Expect(HostPluginDocumentContextWindowConfiguration("/actual-settings",contextWindowBase(["journal"]),original,"changed window witness",keys).digest!=frozen.digest)
    }
    @TestCase
    func distinctProfileRejectsWildcardsDuplicatesAuthorityAndNoncanonicalVersion():Unit{
        @Expect(hostDocumentContextWindowConfigurationValid(contextWindowProfile(["journal"])))
        let deniedKeys:Array<Array<String>>=[["*"],["../journal"],["journal","journal"],[]]
        for(keys in deniedKeys){
            @Expect(!hostDocumentContextWindowConfigurationValid(contextWindowProfile(keys)))}
        let wrong=contextWindowProfile(["journal"]);wrong.put("version",textValue("1"))
        @Expect(!hostDocumentContextWindowConfigurationValid(wrong))
        let grant=contextWindowProfile(["journal"]);grant.field("providers").getOrThrow().items[0].put("grant",boolValue(true))
        @Expect(!hostDocumentContextWindowConfigurationValid(grant))
        let duplicate=contextWindowProfile(["journal"]);let row=duplicate.field("providers").getOrThrow().items[0]
        duplicate.put("providers",listValue([row,row]));@Expect(!hostDocumentContextWindowConfigurationValid(duplicate))
    }
    @TestCase
    func originalContextLoaderStillWorksWhenWindowProfileIsAbsent():Unit{
        let root=Directory.createTemp("/tmp")
        try{
            Directory.create(root.join("plugins"));contextWindowWrite(root,"document-context.json",contextWindowProfile(["journal"]))
            let digest="sha256:"+modelPolicySha256Text("actual-package")
            @Expect(loadHostPluginDocumentContextConfiguration(root.toString(),"axyndra:memory",digest,"prepare_window_context").isOk())
            @Expect(loadHostPluginDocumentContextWindowConfiguration(root.toString(),"axyndra:memory",digest,"prepare_window_context").isError())
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func actualCaptureRequiresBothExactProviderAndPackageProfiles():Unit{
        let root=Directory.createTemp("/tmp")
        try{
            Directory.create(root.join("plugins"));contextWindowWrite(root,"document-context.json",contextWindowProfile(["journal","base-only"]))
            contextWindowWrite(root,"document-context-windows.json",contextWindowProfile(["journal","window-only"]))
            let digest="sha256:"+modelPolicySha256Text("actual-package")
            let config=loadHostPluginDocumentContextWindowConfiguration(root.toString(),"axyndra:memory",digest,"prepare_window_context").value().getOrThrow()
            @Expect(config.permits("journal"));@Expect(!config.permits("base-only"));@Expect(!config.permits("window-only"))
            @Expect(config.validateCurrent().isOk())
            @Expect(loadHostPluginDocumentContextWindowConfiguration(root.toString(),"axyndra:memory",digest,"memory_context").isError())
            @Expect(loadHostPluginDocumentContextWindowConfiguration(root.toString(),"axyndra:memory","sha256:"+modelPolicySha256Text("changed-package"),"prepare_window_context").isError())
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func revocationOrAnyWholeProfileChangeInvalidatesFrozenUse():Unit{
        let root=Directory.createTemp("/tmp")
        try{
            Directory.create(root.join("plugins"));let digest="sha256:"+modelPolicySha256Text("actual-package")
            contextWindowWrite(root,"document-context.json",contextWindowProfile(["journal"]))
            contextWindowWrite(root,"document-context-windows.json",contextWindowProfile(["journal"]))
            let frozen=loadHostPluginDocumentContextWindowConfiguration(root.toString(),"axyndra:memory",digest,"prepare_window_context").value().getOrThrow()
            contextWindowWrite(root,"document-context-windows.json",contextWindowProfile(["journal","new-unrelated-key"]))
            @Expect(frozen.validateCurrent().isError())
            let second=loadHostPluginDocumentContextWindowConfiguration(root.toString(),"axyndra:memory",digest,"prepare_window_context").value().getOrThrow()
            contextWindowWrite(root,"document-context.json",objectValue([ValueField("version",integerValue(1)),ValueField("providers",listValue([]))]))
            @Expect(second.validateCurrent().isError())
        }finally{remove(root,recursive:true)}
    }
}
