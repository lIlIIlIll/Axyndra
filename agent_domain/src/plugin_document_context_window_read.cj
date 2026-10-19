package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

public let PLUGIN_DOCUMENT_CONTEXT_WINDOW_READ_SCHEMA="axyndra.plugin-document-context-window-read/v1"

// A separate parentless Context9 dialect. Neither a parsed reference nor the
// common payload-result shape grants access to an artifact, document or Run.
public func pluginDocumentContextWindowReadRequestValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["schema","binding","projection_digest","key","window","prior_facts"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_CONTEXT_WINDOW_READ_SCHEMA ||
            !pluginDocumentContextBindingValid(value.field("binding").getOrThrow()) ||
            !httpIntentDigest(httpIntentText(value,"projection_digest")) ||
            !documentContractIdentifier(httpIntentText(value,"key"))){return false}
        let binding=value.field("binding").getOrThrow()
        let prior=contextReadFactLinksFromValue(value.field("prior_facts").getOrThrow())
        if(prior.size>7){return false}
        for(link in prior){
            let origin=link.origin
            if(link.runId.value!=httpIntentText(binding,"run_id") ||
                origin.ownerNamespace!=httpIntentText(binding,"namespace") ||
                origin.packageDigest!=httpIntentText(binding,"package_digest") ||
                origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
                origin.projectionDigest!=httpIntentText(value,"projection_digest") ||
                origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
                origin.parentDecisionId!="" || origin.parentScopedCallId!=""){return false}}
        let window=value.field("window").getOrThrow()
        match(httpIntentText(window,"kind")){
            case "manifest"=>if(!httpIntentExactFields(window,["kind"]) || !prior.isEmpty()){return false}
            case "rows"=>if(!httpIntentExactFields(window,["kind","manifest_fact","offset","count"]) || prior.isEmpty() ||
                documentContractInteger(window.field("manifest_fact").getOrThrow())!=0 ||
                documentContractInteger(window.field("offset").getOrThrow())<0 ||
                documentContractInteger(window.field("count").getOrThrow())<1){return false}
            case _=>return false}
        stringifyUnifiedJson(value).size<=16384
    }catch(_:Exception){false}
}

public func pluginDocumentContextWindowReadAuthority(plan:NormalizedOperationPlan):Bool{
    if(!pluginDocumentContextWindowReadRequestValid(plan.canonicalArguments) || plan.requiredCapabilities.size!=1 ||
        !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty()){return false}
    let binding=plan.canonicalArguments.field("binding").getOrThrow()
    plan.requiredCapabilities[0].kind==CapabilityKind.ExtensionInvoke &&
        plan.requiredCapabilities[0].resource==httpIntentText(binding,"namespace")
}

public func pluginDocumentContextWindowReadResultValid(value:AgentValue,request:AgentValue):Bool{
    try{
        pluginDocumentContextWindowReadRequestValid(request) &&
            pluginDocumentRowJournalReadResultDataValid(value,modelPolicySha256Text(canonicalAgentValue(request)),httpIntentText(request,"key"))
    }catch(_:Exception){false}
}
