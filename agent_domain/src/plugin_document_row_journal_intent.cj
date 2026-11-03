package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

public let PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA="axyndra.plugin-document-row-journal-parent/v1"
public let PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA="axyndra.plugin-document-row-journal-intent/v1"
public let PLUGIN_DOCUMENT_ROW_JOURNAL_RESULT_SCHEMA="axyndra.plugin-document-row-journal-result/v1"

// Immutable descriptive DTO. Its constructor is package internal. Actual
// Source, all completed read facts and pinned bytes are mandatory in Store.
public class PluginDocumentRowJournalIntent{
    private let bindingJson:String
    public let id:String
    public let key:String
    public let append:Bool
    public let expectedRevision:Int64
    public let manifestPayload:PluginDocumentPayloadReference
    public let nextPayload:?PluginDocumentPayloadReference
    init(binding:String,id:String,key:String,append:Bool,revision:Int64,manifest:PluginDocumentPayloadReference,next:?PluginDocumentPayloadReference){
        this.bindingJson=binding;this.id=id;this.key=key;this.append=append;this.expectedRevision=revision
        this.manifestPayload=manifest;this.nextPayload=next}
    public func binding():AgentValue{parseUnifiedJson(bindingJson,maxBytes:16384)}
    public func toValue():AgentValue{
        objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA)),ValueField("binding",binding()),
            ValueField("intent",objectValue([ValueField("id",textValue(id)),ValueField("key",textValue(key)),
                ValueField("mode",textValue(if(append){"append"}else{"read"})),ValueField("expected_revision",integerValue(expectedRevision)),
                ValueField("manifest_payload",manifestPayload.value()),
                ValueField("next_payload",match(nextPayload){case Some(value)=>value.value();case None=>nullValue()})]))])}
    public func result():AgentValue{
        objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_RESULT_SCHEMA)),ValueField("key",textValue(key)),
            ValueField("revision",integerValue(expectedRevision+(if(append){1}else{0}))),ValueField("manifest_payload",manifestPayload.value())])}
}

public func parsePluginDocumentRowJournalIntent(value:AgentValue):Result<PluginDocumentRowJournalIntent>{
    try{
        if(!httpIntentExactFields(value,["schema","binding","intent"]) || httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA){
            return pluginDocumentContractError("plugin.document_window_intent_invalid")}
        let binding=value.field("binding").getOrThrow()
        match(validatePluginDocumentBinding(binding)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let raw=value.field("intent").getOrThrow()
        if(!httpIntentExactFields(raw,["id","key","mode","expected_revision","manifest_payload","next_payload"]) ||
            !documentContractIdentifier(httpIntentText(raw,"id")) || !documentContractIdentifier(httpIntentText(raw,"key"))){
            return pluginDocumentContractError("plugin.document_window_intent_invalid")}
        let revision=documentContractInteger(raw.field("expected_revision").getOrThrow())
        let manifest=match(parsePluginDocumentPayloadReference(raw.field("manifest_payload").getOrThrow())){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(revision<1 || manifest.bytes<1){return pluginDocumentContractError("plugin.document_window_expected_invalid")}
        let mode=httpIntentText(raw,"mode");let next=raw.field("next_payload").getOrThrow()
        var replacement:?PluginDocumentPayloadReference=None
        if(mode=="read"){
            if(next.unifiedKind!=ValueKind.Null){return pluginDocumentContractError("plugin.document_read_mutation")}
        }else if(mode=="append"){
            if(revision==Int64.Max){return pluginDocumentContractError("plugin.document_window_next_invalid")}
            let parsed=match(parsePluginDocumentPayloadReference(next)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(parsed.bytes<1){return pluginDocumentContractError("plugin.document_window_next_invalid")};replacement=Some(parsed)
        }else{return pluginDocumentContractError("plugin.document_window_mode_invalid")}
        let frozen=encodeAgentValue(binding)
        if(frozen.size>16384){return pluginDocumentContractError("plugin.document_binding_invalid")}
        Result.Ok(PluginDocumentRowJournalIntent(frozen,httpIntentText(raw,"id"),httpIntentText(raw,"key"),mode=="append",revision,manifest,replacement))
    }catch(_:Exception){pluginDocumentContractError("plugin.document_window_intent_invalid")}
}

public func pluginDocumentRowJournalFrozenResultValid(host:AgentValue):Bool{
    try{
        if(host.unifiedKind!=ValueKind.Object){return false}
        let _=pluginDocumentRowJournalResultValidUntilMillis(host)
        let fields=host.fields.toArray().filter{field=>field.name!="valid_until_millis"}
        pluginDocumentRowJournalFrozenResultBaseValid(objectValue(fields))
    }catch(_:Exception){false}
}

public func pluginDocumentRowJournalResultValidUntilMillis(host:AgentValue):Int64{
    match(host.field("valid_until_millis")){
        case None=>0
        case Some(raw)=>
            let value=documentContractInteger(raw)
            if(value<1){throw IllegalArgumentException("positive canonical window result validity integer required")}
            value
    }
}

// A ceiling only restricts live use; the same historical plan remains
// descriptive after expiry. The actual owner supplies its original clock.
public func pluginDocumentRowJournalFrozenResultCurrent(host:AgentValue,nowMillis:Int64):Result<Unit>{
    try{
        if(!pluginDocumentRowJournalFrozenResultValid(host) || nowMillis<1){
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,"plugin.document_result_validity_invalid","invalid frozen window result validity ceiling"))}
        let until=pluginDocumentRowJournalResultValidUntilMillis(host)
        if(until>0 && nowMillis>=until){
            return Result.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_result_expired","frozen row journal result expired before actual consumption"))}
        Result.Ok(())
    }catch(_:Exception){Result.Err(AgentError(AgentErrorKind.InvalidInput,"plugin.document_result_validity_invalid","invalid frozen window result validity ceiling"))}
}

func pluginDocumentRowJournalFrozenResultBaseValid(host:AgentValue):Bool{
    try{
        if(!(httpIntentExactFields(host,["version","binding","intents","result_payload","result_codec","is_error"]) ||
            httpIntentExactFields(host,["version","binding","intents","result_payload","result_codec","is_error","tool_payload_limits"])) ||
            httpIntentText(host,"version")!=PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA ||
            httpIntentText(host,"result_codec")!="axyndra.agent-value-json/v1" || host.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean){return false}
        parsePluginDocumentPayloadReference(host.field("result_payload").getOrThrow()).value().getOrThrow().bytes>0
    }catch(_:Exception){false}
}

public func pluginDocumentRowJournalChildArguments(parent:AgentValue,intentId:String):Result<AgentValue>{
    try{
        if(!httpIntentExactFields(parent,["input","configuration","host_plan"])){
            return pluginDocumentContractError("plugin.document_window_parent_invalid")}
        let host=parent.field("host_plan").getOrThrow()
        if(!pluginDocumentRowJournalFrozenResultValid(host) || validatePluginDocumentBinding(host.field("binding").getOrThrow()).isError()){
            return pluginDocumentContractError("plugin.document_window_parent_invalid")}
        let binding=host.field("binding").getOrThrow()
        match(host.field("tool_payload_limits")){case Some(value)=>
            let profile=ordinaryToolPayloadLimitsFromValue(value)
            if(profile.isNone() || httpIntentText(binding,"contribution")!="plugin."+httpIntentText(binding,"namespace")+"."+profile.getOrThrow().contribution){
                return pluginDocumentContractError("plugin.document_window_payload_invalid")}
            case None=>()}
        let intents=host.field("intents").getOrThrow()
        if(intents.unifiedKind!=ValueKind.List || intents.items.isEmpty() || intents.items.size>8){
            return pluginDocumentContractError("plugin.document_intent_count")}
        let ids=HashSet<String>();let keys=HashSet<String>();var found:?AgentValue=None
        for(raw in intents.items){
            let child=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA)),ValueField("binding",binding),ValueField("intent",raw)])
            let intent=match(parsePluginDocumentRowJournalIntent(child)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(ids.contains(intent.id) || keys.contains(intent.key)){return pluginDocumentContractError("plugin.document_duplicate_intent")}
            ids.add(intent.id);keys.add(intent.key);if(intent.id==intentId){found=Some(intent.toValue())}}
        match(found){case Some(value)=>Result.Ok(value);case None=>pluginDocumentContractError("plugin.document_intent_missing")}
    }catch(_:Exception){pluginDocumentContractError("plugin.document_window_parent_invalid")}
}

public func isPluginDocumentRowJournalChildPlan(plan:NormalizedOperationPlan):Bool{
    let parsed=parsePluginDocumentRowJournalIntent(plan.canonicalArguments)
    if(parsed.isError() || plan.toolName!=HOST_PLUGIN_DOCUMENT_TOOL || plan.implementation.toolVersion!=HOST_PLUGIN_DOCUMENT_FINGERPRINT ||
        plan.implementation.implementationFingerprint!=HOST_PLUGIN_DOCUMENT_FINGERPRINT || plan.retryDisposition!=OperationRetryDisposition.Never ||
        plan.idempotencyKey!="" || !networkPolicyModeIsDenied(plan.networkPolicy.mode) || !plan.networkPolicy.egress.isEmpty() ||
        !plan.networkPolicy.publish.isEmpty() || !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty() ||
        !plan.relevantEnvironment.isEmpty() || plan.requiredCapabilities.size!=1){return false}
    let intent=parsed.value().getOrThrow()
    plan.effectClass==(if(intent.append){OperationEffectClass.ExternalMutation}else{OperationEffectClass.ReadOnly}) &&
        plan.requiredCapabilities[0].kind==CapabilityKind.ExtensionInvoke &&
        plan.requiredCapabilities[0].resource==httpIntentText(intent.binding(),"namespace") &&
        match(plan.replayDisposition){case ReplayDisposition.NeverReplay=>true;case _=>false}
}

public func isFrozenPluginDocumentRowJournalParentPlan(plan:NormalizedOperationPlan):Bool{
    try{
        let host=plan.canonicalArguments.field("host_plan").getOrThrow();let intents=host.field("intents").getOrThrow()
        if(!pluginDocumentRowJournalFrozenResultValid(host) || intents.unifiedKind!=ValueKind.List || intents.items.isEmpty()){return false}
        let selected=pluginDocumentRowJournalChildArguments(plan.canonicalArguments,httpIntentText(intents.items[0],"id"))
        if(selected.isError()){return false}
        let binding=selected.value().getOrThrow().field("binding").getOrThrow()
        if(plan.toolName!=httpIntentText(binding,"contribution") || plan.implementation.implementationFingerprint!=httpIntentText(binding,"implementation_fingerprint") ||
            plan.implementation.schemaDigest!=httpIntentText(binding,"schema_digest") || plan.retryDisposition!=OperationRetryDisposition.Never ||
            !CapabilitySet(values:plan.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke,resource:httpIntentText(binding,"namespace"))){return false}
        for(intent in intents.items where httpIntentText(intent,"mode")=="append"){
            if(plan.effectClass!=OperationEffectClass.ExternalMutation){return false}}
        match(plan.replayDisposition){case ReplayDisposition.NeverReplay=>true;case _=>false}
    }catch(_:Exception){false}
}

public func pluginDocumentRowJournalParentAllows(parent:NormalizedOperationPlan,child:NormalizedOperationPlan):Bool{
    let parsed=parsePluginDocumentRowJournalIntent(child.canonicalArguments)
    if(parsed.isError() || !isPluginDocumentRowJournalChildPlan(child) || !isFrozenPluginDocumentRowJournalParentPlan(parent)){return false}
    let intent=parsed.value().getOrThrow();let binding=intent.binding()
    let expected=pluginDocumentRowJournalChildArguments(parent.canonicalArguments,intent.id)
    if(expected.isError() || canonicalAgentValue(expected.value().getOrThrow())!=canonicalAgentValue(child.canonicalArguments) ||
        parent.toolName!=httpIntentText(binding,"contribution") || parent.implementation.implementationFingerprint!=httpIntentText(binding,"implementation_fingerprint") ||
        parent.implementation.schemaDigest!=httpIntentText(binding,"schema_digest") ||
        (intent.append && parent.effectClass!=OperationEffectClass.ExternalMutation) ||
        !CapabilitySet(values:parent.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke,resource:httpIntentText(binding,"namespace"))){return false}
    match(parent.replayDisposition){case ReplayDisposition.NeverReplay=>true;case _=>false}
}
