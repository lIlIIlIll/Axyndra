package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// A separate, read-only initial/update ContextRead profile. It cannot borrow a
// Tool parent, issue a document mutation or install continuation authority.
public let PLUGIN_DOCUMENT_CONTEXT_READ_SCHEMA="axyndra.plugin-document-context-read/v1"

public func pluginDocumentContextBindingValid(value: AgentValue): Bool {
    try {
        if(!httpIntentExactFields(value,["namespace","package_digest","generation","configuration_digest",
            "thread_id","lane_id","run_id","epoch","provider"]) ||
            !httpServicePluginNamespace(httpIntentText(value,"namespace")) ||
            !httpServicePackageDigest(httpIntentText(value,"package_digest")) ||
            !httpIntentDigest(httpIntentText(value,"configuration_digest")) ||
            !documentContractIdentifier(httpIntentText(value,"provider"))){return false}
        for(name in ["thread_id","lane_id","run_id"]){
            let text=httpIntentText(value,name)
            if(text=="" || text.size>1024 || text.contains("\u{0000}")){return false}}
        for(name in ["namespace","package_digest","generation","configuration_digest","thread_id","lane_id","run_id","provider"]){
            if(value.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
        let generation=httpIntentText(value,"generation")
        let number=UInt64.parse(generation)
        let epoch=documentContractInteger(value.field("epoch").getOrThrow())
        number>0 && generation==number.toString() && epoch>0 && stringifyUnifiedJson(value).size<=8192
    }catch(_:Exception){false}
}

public func pluginDocumentContextReadRequestValid(value: AgentValue): Bool {
    try {
        if(!httpIntentExactFields(value,["schema","binding","projection_digest","keys"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_CONTEXT_READ_SCHEMA ||
            !pluginDocumentContextBindingValid(value.field("binding").getOrThrow()) ||
            !httpIntentDigest(httpIntentText(value,"projection_digest"))){return false}
        let keys=value.field("keys").getOrThrow();let seen=HashSet<String>()
        if(keys.unifiedKind!=ValueKind.List || keys.items.isEmpty() || keys.items.size>8){return false}
        for(key in keys.items){
            if(key.unifiedKind!=ValueKind.Text || !documentContractIdentifier(key.text) || seen.contains(key.text)){return false}
            seen.add(key.text)}
        stringifyUnifiedJson(value).size<=16384
    }catch(_:Exception){false}
}
