package agent_host_runtime

import agent_domain.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Window transport is an explicit second operator profile. It conveys no
// Source or permission and cannot replace the original readonly key grant.
public class HostPluginDocumentContextWindowConfiguration {
    public let namespace:String
    public let packageDigest:String
    public let provider:String
    public let digest:String
    private let settingsRoot:String
    private let base:HostPluginDocumentContextConfiguration
    private let encoded:String
    private let witness:String
    private let keysJson:String
    init(settingsRoot:String,base:HostPluginDocumentContextConfiguration,encoded:String,witness:String,keys:AgentValue){
        this.settingsRoot=settingsRoot;this.base=base;this.encoded=encoded;this.witness=witness
        namespace=base.namespace;packageDigest=base.packageDigest;provider=base.provider
        keysJson=stringifyUnifiedJson(keys)
        digest=modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("base_digest",textValue(base.digest)),ValueField("window_bytes",textValue(encoded)),
            ValueField("window_witness",textValue(witness))])))
    }
    public func permits(key:String):Bool{
        if(!base.permits(key)){return false}
        for(item in parseUnifiedJson(keysJson,maxBytes:16384).items where item.text==key){return true}
        false
    }
    public func validateCurrent():Result<Unit>{
        match(base.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        let current=match(loadHostPluginDocumentContextWindowConfiguration(settingsRoot,namespace,packageDigest,provider)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(current.digest!=digest || current.encoded!=encoded || current.witness!=witness){
            return hostPluginResourceError("plugin.document_context_window_grant_changed","complete operator context window profile or base rights changed")}
        base.validateCurrent()
    }
}

// The distinct file deliberately uses the same narrow descriptive schema.
// The original validator and document-context.json format remain unchanged.
public func hostDocumentContextWindowConfigurationValid(value:AgentValue):Bool{
    hostDocumentContextConfigurationValid(value)
}

public func loadHostPluginDocumentContextWindowConfiguration(settingsRoot:String,namespace:String,
    packageDigest:String,provider:String):Result<HostPluginDocumentContextWindowConfiguration>{
    let base=match(loadHostPluginDocumentContextConfiguration(settingsRoot,namespace,packageDigest,provider)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    try{
        let path=Path(settingsRoot).join("plugins/document-context-windows.json").toString()
        let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!witness.startsWith("f:")){
            return hostPluginResourceError("plugin.document_context_window_grant_invalid","context window profile must be a regular operator file")}
        let bytes=Int64.parse(witness.split(":")[4])
        if(bytes<1 || bytes>65536){
            return hostPluginResourceError("plugin.document_context_window_grant_invalid","context window profile exceeds its fixed configuration bound")}
        let temporary=Directory.createTemp("/tmp");let encoded:String
        try{
            let target=temporary.join("document-context-window-grant")
            let actual=match(hostReadResourceCopy(path,witness,target.toString(),bytes)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(actual!=bytes){return hostPluginResourceError("plugin.document_context_window_grant_changed","context window profile changed during capture")}
            encoded=String.fromUtf8(File.readFrom(target))
        }finally{remove(temporary,recursive:true)}
        let config=parseUnifiedJson(encoded,maxBytes:65536,maxDepth:10)
        if(!hostDocumentContextWindowConfigurationValid(config)){
            return hostPluginResourceError("plugin.document_context_window_grant_invalid","unsupported readonly context window profile")}
        for(item in config.field("providers").getOrThrow().items where httpIntentText(item,"namespace")==namespace &&
            httpIntentText(item,"package_digest")==packageDigest && httpIntentText(item,"provider")==provider){
            // Freeze both files at one current boundary. Every use repeats
            // both captures through validateCurrent rather than trusting DTOs.
            match(base.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}
            return Result.Ok(HostPluginDocumentContextWindowConfiguration(settingsRoot,base,encoded,witness,item.field("keys").getOrThrow()))}
        hostPluginResourceError("plugin.document_context_window_grant_missing","actual installed context provider has no exact window profile")
    }catch(_:Exception){hostPluginResourceError("plugin.document_context_window_grant_invalid","readonly context window profile could not be captured")}
}
