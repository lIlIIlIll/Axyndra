package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Explicit operator-owned readonly rights for one actual typed ContextProvider.
// This profile has no mutation, wildcard, cross-Thread, path or backend choice.
public class HostPluginDocumentContextConfiguration {
    public let namespace:String
    public let packageDigest:String
    public let provider:String
    public let digest:String
    private let settingsRoot:String
    private let encoded:String
    private let witness:String
    private let keysJson:String
    init(settingsRoot:String,namespace:String,packageDigest:String,provider:String,
        encoded:String,witness:String,keys:AgentValue){
        this.settingsRoot=settingsRoot;this.namespace=namespace;this.packageDigest=packageDigest;this.provider=provider
        this.encoded=encoded;this.witness=witness;keysJson=stringifyUnifiedJson(keys)
        digest=modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("bytes",textValue(encoded)),ValueField("witness",textValue(witness))])))
    }
    public func permits(key:String):Bool{
        for(item in parseUnifiedJson(keysJson,maxBytes:16384).items where item.text==key){return true}
        false
    }
    public func validateCurrent():Result<Unit>{
        let current=match(loadHostPluginDocumentContextConfiguration(settingsRoot,namespace,packageDigest,provider)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(current.encoded!=encoded || current.witness!=witness){
            return hostPluginResourceError("plugin.document_context_grant_changed","complete operator context document rights changed")}
        Result.Ok(())
    }
}

public func hostDocumentContextConfigurationValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["version","providers"]) ||
            value.field("version").getOrThrow().unifiedKind!=ValueKind.Number ||
            value.field("version").getOrThrow().asNumberText()!="1"){return false}
        let providers=value.field("providers").getOrThrow();let seen=HashSet<String>()
        if(providers.unifiedKind!=ValueKind.List || providers.items.size>64){return false}
        for(item in providers.items){
            if(!httpIntentExactFields(item,["namespace","package_digest","provider","keys"]) ||
                !httpServicePluginNamespace(httpIntentText(item,"namespace")) ||
                !httpServicePackageDigest(httpIntentText(item,"package_digest")) ||
                !hostDocumentLogicalName(httpIntentText(item,"provider"))){return false}
            for(name in ["namespace","package_digest","provider"]){
                if(item.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
            let identity=httpIntentText(item,"namespace")+"/"+httpIntentText(item,"provider")
            if(seen.contains(identity)){return false};seen.add(identity)
            let keys=item.field("keys").getOrThrow();let unique=HashSet<String>()
            if(keys.unifiedKind!=ValueKind.List || keys.items.isEmpty() || keys.items.size>8){return false}
            for(key in keys.items){
                if(key.unifiedKind!=ValueKind.Text || !hostDocumentLogicalName(key.text) || unique.contains(key.text)){return false}
                unique.add(key.text)}
        }
        stringifyUnifiedJson(value).size<=65536
    }catch(_:Exception){false}
}

public func loadHostPluginDocumentContextConfiguration(settingsRoot:String,namespace:String,
    packageDigest:String,provider:String):Result<HostPluginDocumentContextConfiguration>{
    if(settingsRoot=="" || !httpServicePluginNamespace(namespace) || !httpServicePackageDigest(packageDigest) ||
        !hostDocumentLogicalName(provider)){
        return hostPluginResourceError("plugin.document_context_grant_missing","exact readonly context document rights are required")}
    try{
        let path=Path(settingsRoot).join("plugins/document-context.json").toString()
        let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let bytes=Int64.parse(witness.split(":")[4])
        if(!witness.startsWith("f:") || bytes<1 || bytes>65536){
            return hostPluginResourceError("plugin.document_context_grant_invalid","context document rights exceed their fixed configuration bound")}
        let temporary=Directory.createTemp("/tmp");let encoded:String
        try{
            let target=temporary.join("document-context-grant")
            let actual=match(hostReadResourceCopy(path,witness,target.toString(),bytes)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(actual!=bytes){return hostPluginResourceError("plugin.document_context_grant_changed","context document rights changed during capture")}
            encoded=String.fromUtf8(File.readFrom(target))
        }finally{remove(temporary,recursive:true)}
        let config=parseUnifiedJson(encoded,maxBytes:65536,maxDepth:10)
        if(!hostDocumentContextConfigurationValid(config)){
            return hostPluginResourceError("plugin.document_context_grant_invalid","unsupported readonly context document rights")}
        for(item in config.field("providers").getOrThrow().items where httpIntentText(item,"namespace")==namespace &&
            httpIntentText(item,"package_digest")==packageDigest && httpIntentText(item,"provider")==provider){
            return Result.Ok(HostPluginDocumentContextConfiguration(settingsRoot,namespace,packageDigest,provider,encoded,witness,item.field("keys").getOrThrow()))}
        hostPluginResourceError("plugin.document_context_grant_missing","actual installed context provider has no matching readonly document rights")
    }catch(_:Exception){hostPluginResourceError("plugin.document_context_grant_invalid","readonly context document rights could not be captured")}
}
