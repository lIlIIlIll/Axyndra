package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// Operator-only opt-in. This freezes a proposal ceiling and two actual
// provider names; it never constructs a Source or grants a child capability.
public func hostPluginLivePolicyConfigurationValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["version","tools"]) ||
            value.field("version").getOrThrow().unifiedKind!=ValueKind.Number ||
            value.field("version").getOrThrow().asNumberText()!="1"){return false}
        let entries=value.field("tools").getOrThrow();let seen=HashSet<String>()
        if(entries.unifiedKind!=ValueKind.List || entries.items.size>64){return false}
        for(row in entries.items){
            if(!httpIntentExactFields(row,["namespace","package_digest","contribution","read_provider","policy_provider","data_schema","key","effect_ceiling"]) ||
                !httpServicePluginNamespace(httpIntentText(row,"namespace")) || !httpServicePackageDigest(httpIntentText(row,"package_digest")) ||
                !hostDocumentLogicalName(httpIntentText(row,"read_provider")) || !hostDocumentLogicalName(httpIntentText(row,"policy_provider")) ||
                !hostDocumentLogicalName(httpIntentText(row,"key")) || !pluginLivePolicyCeilingValid(row.field("effect_ceiling").getOrThrow())){return false}
            for(name in ["namespace","package_digest","contribution","read_provider","policy_provider","data_schema","key"]){
                if(row.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
            let schema=httpIntentText(row,"data_schema");let contribution=httpIntentText(row,"contribution")
            let prefix="plugin."+httpIntentText(row,"namespace")+"."
            if(schema=="" || schema.size>512 || schema.trimAscii()!=schema || schema.contains("\u{0000}") ||
                !contribution.startsWith(prefix) || !hostDocumentLogicalName(contribution[prefix.size..]) ||
                !seen.add(contribution)){return false}
            for(document in row.field("effect_ceiling").getOrThrow().field("documents").getOrThrow().items){
                if(httpIntentText(document,"key")!=httpIntentText(row,"key")){return false}}
        }
        stringifyUnifiedJson(value).size<=65536
    }catch(_:Exception){false}
}

public class HostPluginLivePolicyConfiguration{
    public let namespace:String
    public let packageDigest:String
    public let contribution:String
    public let readProvider:String
    public let policyProvider:String
    public let dataSchema:String
    public let key:String
    public let digest:String
    public let read:HostPluginDocumentJournalReadConfiguration
    private let settingsRoot:String
    private let base:HostPluginDocumentConfiguration
    private let encoded:String
    private let witness:String
    private let ceilingJson:String
    init(settingsRoot:String,base:HostPluginDocumentConfiguration,read:HostPluginDocumentJournalReadConfiguration,
        snapshot:HostJournalOperatorSnapshot,selected:AgentValue){
        this.settingsRoot=settingsRoot;this.base=base;this.read=read
        namespace=base.namespace;packageDigest=base.packageDigest;contribution=httpIntentText(selected,"contribution")
        readProvider=httpIntentText(selected,"read_provider");policyProvider=httpIntentText(selected,"policy_provider")
        dataSchema=httpIntentText(selected,"data_schema");key=httpIntentText(selected,"key")
        encoded=snapshot.encoded;witness=snapshot.witness
        ceilingJson=stringifyUnifiedJson(selected.field("effect_ceiling").getOrThrow())
        digest=modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("base_digest",textValue(base.digest)),
            ValueField("read_digest",textValue(read.digest)),ValueField("operator_bytes",textValue(encoded)),
            ValueField("operator_witness",textValue(witness)),ValueField("contribution",textValue(contribution))])))
    }
    public func ceiling():AgentValue{parseUnifiedJson(ceilingJson,maxBytes:65536,maxDepth:16)}
    public func validateTransferWitness():Result<Unit>{
        match(base.validateTransferWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(read.validateTransferWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDocumentJournalWitnessCurrent(settingsRoot,"plugins/live-policy.json",encoded,witness)
    }
    public func validateCurrent():Result<Unit>{
        match(read.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let current=match(loadHostPluginLivePolicyConfiguration(settingsRoot,namespace,packageDigest,contribution)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
            case Result.Ok(None)=>return hostPluginResourceError("plugin.live_policy_revoked","operator removed the original live policy mapping")}
        if(current.digest!=digest){return hostPluginResourceError("plugin.live_policy_changed","whole original live profile, base rights or read purpose changed")}
        validateTransferWitness()
    }
}

// Missing file/unmapped contribution leaves old document preparation intact.
// A present invalid file is a closed error, never a fallback to a wider grant.
public func loadHostPluginLivePolicyConfiguration(settingsRoot:String,namespace:String,packageDigest:String,
    contribution:String):Result<?HostPluginLivePolicyConfiguration>{
    try{
        if(settingsRoot=="" || !httpServicePluginNamespace(namespace) || !httpServicePackageDigest(packageDigest)){
            return hostPluginResourceError("plugin.live_policy_scope","exact trusted settings root and current package required")}
        let path=Path(settingsRoot).join("plugins/live-policy.json")
        if(!exists(path)){return Result<?HostPluginLivePolicyConfiguration>.Ok(Option<HostPluginLivePolicyConfiguration>.None)}
        let snapshot=match(hostCaptureDocumentJournalBytes(settingsRoot,"plugins/live-policy.json")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!hostPluginLivePolicyConfigurationValid(snapshot.value)){
            return hostPluginResourceError("plugin.live_policy_profile_invalid","unsupported strict live proposal mapping")}
        var selected:?AgentValue=None
        for(row in snapshot.value.field("tools").getOrThrow().items where httpIntentText(row,"namespace")==namespace &&
            httpIntentText(row,"package_digest")==packageDigest && httpIntentText(row,"contribution")==contribution){selected=Some(row)}
        if(selected.isNone()){return Result<?HostPluginLivePolicyConfiguration>.Ok(Option<HostPluginLivePolicyConfiguration>.None)}
        let row=selected.getOrThrow();let prefix="plugin."+namespace+".";let local=contribution[prefix.size..]
        let base=match(loadHostPluginDocumentConfiguration(settingsRoot,namespace,packageDigest)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let read=match(loadHostPluginDocumentJournalReadConfiguration(settingsRoot,namespace,packageDigest,
            httpIntentText(row,"read_provider"),contribution,false)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!read.permits(httpIntentText(row,"key"))){return hostPluginResourceError("plugin.live_policy_read_denied","original exact Tool read rights do not allow this journal")}
        for(document in row.field("effect_ceiling").getOrThrow().field("documents").getOrThrow().items){
            if(!base.permits(local,httpIntentText(document,"key"),true)){
                return hostPluginResourceError("plugin.live_policy_write_denied","proposal ceiling exceeds original operator document rights")}}
        let result=HostPluginLivePolicyConfiguration(settingsRoot,base,read,snapshot,row)
        match(result.validateTransferWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result<?HostPluginLivePolicyConfiguration>.Ok(Some(result))
    }catch(_:Exception){hostPluginResourceError("plugin.live_policy_profile_invalid","closed live profile could not be frozen")}
}
