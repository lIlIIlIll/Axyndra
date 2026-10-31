package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

public let PLUGIN_LIVE_POLICY_PARENT_SCHEMA="axyndra.plugin-live-policy-parent/v1"
public let PLUGIN_LIVE_POLICY_CEILING_SCHEMA="axyndra.plugin-live-policy-ceiling/v1"
public let PLUGIN_LIVE_POLICY_CHILD_SCHEMA="axyndra.plugin-live-policy-child/v1"
public let HOST_PLUGIN_LIVE_EFFECT_TOOL="host.plugin.live_effect"
public let HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT="axyndra.host-plugin-live-effect/v1"

// These validators describe a new, closed family. They are intentionally NOT
// members of exactServiceChildAllowed, isExactServiceChildPlan or the old
// frozen ParentIntent family. A ceiling narrows proposals; it approves none.
// Actual Source/current operator/paid refs/previous receipts are Store checks.
public func pluginLivePolicyParentValueValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["input","configuration","host_plan"])){return false}
        let host=value.field("host_plan").getOrThrow()
        if(!httpIntentExactFields(host,["version","binding","input_payload","effect_ceiling","initial_read_facts","policy_provider","data_schema"]) ||
            httpIntentText(host,"version")!=PLUGIN_LIVE_POLICY_PARENT_SCHEMA ||
            validatePluginDocumentBinding(host.field("binding").getOrThrow()).isError() ||
            !documentContractIdentifier(httpIntentText(host,"policy_provider")) ||
            !pluginLivePolicySchemaName(httpIntentText(host,"data_schema")) ||
            !pluginLivePolicyCeilingValid(host.field("effect_ceiling").getOrThrow()) ||
            !pluginLivePolicyReadLinksValid(host.field("initial_read_facts").getOrThrow(),host.field("binding").getOrThrow())){return false}
        let reference=parsePluginDocumentPayloadReference(host.field("input_payload").getOrThrow()).value().getOrThrow()
        reference.bytes>0
    }catch(_:Exception){false}
}

public func pluginLivePolicyCeilingValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["schema","documents","filesystem"]) ||
            httpIntentText(value,"schema")!=PLUGIN_LIVE_POLICY_CEILING_SCHEMA){return false}
        let documents=value.field("documents").getOrThrow();let filesystem=value.field("filesystem").getOrThrow()
        if(documents.unifiedKind!=ValueKind.List || filesystem.unifiedKind!=ValueKind.List ||
            (documents.items.isEmpty() && filesystem.items.isEmpty())){return false}
        let keys=HashSet<String>();let roots=HashSet<String>()
        for(row in documents.items){
            let key=httpIntentText(row,"key")
            if(!httpIntentExactFields(row,["key","operations"]) || !documentContractIdentifier(key) || keys.contains(key) ||
                !pluginLivePolicyOperationList(row.field("operations").getOrThrow(),["row_journal.append"])){return false}
            keys.add(key)}
        for(row in filesystem.items){
            let root=httpIntentText(row,"root")
            if(!httpIntentExactFields(row,["root","canonical_root","operations"]) || !documentContractIdentifier(root) ||
                roots.contains(root) || !pluginLivePolicyPhysicalPath(httpIntentText(row,"canonical_root")) ||
                !pluginLivePolicyOperationList(row.field("operations").getOrThrow(),
                    ["directory.create","file.atomic_write","directory.delete_tree"])){return false}
            roots.add(root)}
        true
    }catch(_:Exception){false}
}

public func pluginLivePolicyChildValueValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["schema","binding","sequence","effect","proposal_payload","read_facts","prior_receipts"]) ||
            httpIntentText(value,"schema")!=PLUGIN_LIVE_POLICY_CHILD_SCHEMA ||
            validatePluginDocumentBinding(value.field("binding").getOrThrow()).isError() ||
            !pluginLivePolicyReadLinksValid(value.field("read_facts").getOrThrow(),value.field("binding").getOrThrow())){return false}
        let sequence=documentContractInteger(value.field("sequence").getOrThrow())
        if(sequence<1 || !pluginLivePolicyReceiptLinksValid(value.field("prior_receipts").getOrThrow(),sequence)){return false}
        let effect=value.field("effect").getOrThrow();let kind=httpIntentText(effect,"kind")
        if(kind=="row_journal.append"){
            if(!httpIntentExactFields(effect,["kind","key"]) || !documentContractIdentifier(httpIntentText(effect,"key"))){return false}
        }else if(["directory.create","file.atomic_write","directory.delete_tree"].contains(kind)){
            if(!httpIntentExactFields(effect,["kind","root","relative_path","canonical_path"]) ||
                !documentContractIdentifier(httpIntentText(effect,"root")) ||
                !pluginLivePolicyRelativePath(httpIntentText(effect,"relative_path")) ||
                !pluginLivePolicyPhysicalPath(httpIntentText(effect,"canonical_path"))){return false}
        }else{return false}
        // Even directory effects own their strict precondition proposal ref.
        // No raw content, SQL, table, authorizer or Native completion bit.
        parsePluginDocumentPayloadReference(value.field("proposal_payload").getOrThrow()).value().getOrThrow().bytes>0
    }catch(_:Exception){false}
}

public func isPluginLivePolicyParentPlan(plan:NormalizedOperationPlan):Bool{
    try{
        if(!pluginLivePolicyParentValueValid(plan.canonicalArguments) || plan.effectClass!=OperationEffectClass.ExternalMutation ||
            plan.retryDisposition!=OperationRetryDisposition.Never || !pluginLivePolicyNoNetwork(plan)){return false}
        let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        plan.toolName==httpIntentText(binding,"contribution") &&
            plan.implementation.implementationFingerprint==httpIntentText(binding,"implementation_fingerprint") &&
            plan.implementation.schemaDigest==httpIntentText(binding,"schema_digest") &&
            canonicalAgentValue(contextReadFactLinksValue(plan.contextReadFacts))==canonicalAgentValue(
                plan.canonicalArguments.field("host_plan").getOrThrow().field("initial_read_facts").getOrThrow()) &&
            CapabilitySet(values:plan.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke,resource:httpIntentText(binding,"namespace")) &&
            match(plan.replayDisposition){case ReplayDisposition.NeverReplay=>true;case _=>false}
    }catch(_:Exception){false}
}

public func isPluginLivePolicyChildPlan(plan:NormalizedOperationPlan):Bool{
    try{
        if(!pluginLivePolicyChildValueValid(plan.canonicalArguments) || plan.toolName!=HOST_PLUGIN_LIVE_EFFECT_TOOL ||
            plan.implementation.toolVersion!=HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT ||
            plan.implementation.implementationFingerprint!=HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT ||
            plan.effectClass!=OperationEffectClass.ExternalMutation || plan.retryDisposition!=OperationRetryDisposition.Never ||
            plan.idempotencyKey!="" || !plan.resolvedHosts.isEmpty() || !plan.relevantEnvironment.isEmpty() ||
            !plan.contextReadFacts.isEmpty() || !pluginLivePolicyNoNetwork(plan) || plan.requiredCapabilities.size!=1){return false}
        let binding=plan.canonicalArguments.field("binding").getOrThrow()
        let effect=plan.canonicalArguments.field("effect").getOrThrow()
        let required=plan.requiredCapabilities[0]
        let matches=if(httpIntentText(effect,"kind")=="row_journal.append"){
            required.kind==CapabilityKind.ExtensionInvoke && required.resource==httpIntentText(binding,"namespace") && plan.resolvedPaths.isEmpty()
        }else{
            let path=httpIntentText(effect,"canonical_path")
            required.kind==CapabilityKind.WorkspaceWrite && required.resource==path &&
                plan.resolvedPaths.size==1 && plan.resolvedPaths[0]==path}
        matches && match(plan.replayDisposition){case ReplayDisposition.NeverReplay=>true;case _=>false}
    }catch(_:Exception){false}
}

// Relationship only: caller must independently prepare/approve/admit this
// precise child and reload every real previous Receipt. NEVER interpret this
// predicate as ParentIntent authorization or proof of a completed effect.
public func pluginLivePolicyChildWithinCeiling(parent:NormalizedOperationPlan,child:NormalizedOperationPlan):Bool{
    try{
        if(!isPluginLivePolicyParentPlan(parent) || !isPluginLivePolicyChildPlan(child)){return false}
        let host=parent.canonicalArguments.field("host_plan").getOrThrow()
        if(canonicalAgentValue(host.field("binding").getOrThrow())!=canonicalAgentValue(child.canonicalArguments.field("binding").getOrThrow())){return false}
        let effect=child.canonicalArguments.field("effect").getOrThrow();let kind=httpIntentText(effect,"kind")
        let ceiling=host.field("effect_ceiling").getOrThrow()
        if(kind=="row_journal.append"){
            for(row in ceiling.field("documents").getOrThrow().items where httpIntentText(row,"key")==httpIntentText(effect,"key")){
                return pluginLivePolicyOperationContains(row.field("operations").getOrThrow(),kind)}
        }else{
            let path=httpIntentText(effect,"canonical_path")
            for(row in ceiling.field("filesystem").getOrThrow().items where httpIntentText(row,"root")==httpIntentText(effect,"root")){
                let anchor=httpIntentText(row,"canonical_root")
                let contained=if(anchor.endsWith("/") || anchor.endsWith("\\")){path.startsWith(anchor)}
                    else{path.startsWith(anchor+"/") || path.startsWith(anchor+"\\")}
                return pluginLivePolicyOperationContains(row.field("operations").getOrThrow(),kind) &&
                    path!=anchor && contained}
        }
        false
    }catch(_:Exception){false}
}

public func pluginLivePolicyRequestKey(parentCallId:String,child:NormalizedOperationPlan):String{
    if(!documentContractIdentifier(parentCallId) || !isPluginLivePolicyChildPlan(child)){return ""}
    "live-policy:"+parentCallId+":"+child.canonicalArguments.field("sequence").getOrThrow().asNumberText()
}

func pluginLivePolicyReadLinksValid(value:AgentValue,binding:AgentValue):Bool{
    if(value.unifiedKind!=ValueKind.List || value.items.isEmpty() || value.items.size>16){return false}
    let links=contextReadFactLinksFromValue(value)
    if(links.size!=value.items.size || links.isEmpty() || canonicalAgentValue(value)!=canonicalAgentValue(contextReadFactLinksValue(links))){return false}
    for(link in links){
        if(link.runId.value!=httpIntentText(binding,"run_id") || link.origin.parentKind=="" ||
            link.origin.ownerNamespace!=httpIntentText(binding,"namespace") ||
            link.origin.packageDigest!=httpIntentText(binding,"package_digest")){return false}}
    true
}

func pluginLivePolicyReceiptLinksValid(value:AgentValue,sequence:Int64):Bool{
    if(value.unifiedKind!=ValueKind.List || value.items.size!=sequence-1){return false}
    let operations=HashSet<String>();let receipts=HashSet<String>();var ordinal:Int64=1
    for(raw in value.items){
        if(!httpIntentExactFields(raw,["sequence","operation_id","receipt_id","plan_sha256","outcome"]) ||
            documentContractInteger(raw.field("sequence").getOrThrow())!=ordinal ||
            !documentContractIdentifier(httpIntentText(raw,"operation_id")) || !documentContractIdentifier(httpIntentText(raw,"receipt_id")) ||
            !httpIntentDigest(httpIntentText(raw,"plan_sha256")) || !["completed","rejected"].contains(httpIntentText(raw,"outcome")) ||
            operations.contains(httpIntentText(raw,"operation_id")) || receipts.contains(httpIntentText(raw,"receipt_id"))){return false}
        operations.add(httpIntentText(raw,"operation_id"));receipts.add(httpIntentText(raw,"receipt_id"));ordinal+=1}
    true
}

func pluginLivePolicyOperationList(value:AgentValue,allowed:Array<String>):Bool{
    if(value.unifiedKind!=ValueKind.List || value.items.isEmpty()){return false}
    let seen=HashSet<String>()
    for(raw in value.items){
        if(raw.unifiedKind!=ValueKind.Text || !allowed.contains(raw.text) || seen.contains(raw.text)){return false}
        seen.add(raw.text)}
    true
}
func pluginLivePolicyOperationContains(value:AgentValue,kind:String):Bool{
    for(raw in value.items where raw.text==kind){return true};false}
func pluginLivePolicySchemaName(value:String):Bool{value.size>0 && value.size<=512 && value.trimAscii()==value && !value.contains("\u{0000}")}
func pluginLivePolicyRelativePath(value:String):Bool{
    if(value=="" || value.contains("\\") || value.contains(":") || value.contains("\u{0000}") || value.startsWith("/")){return false}
    for(part in value.split("/")){if(part=="" || part=="." || part==".."){return false}}
    true
}
func pluginLivePolicyPhysicalPath(value:String):Bool{
    if(value=="" || value.contains("\u{0000}") ||
        !(value.startsWith("/") || (value.size>=3 && value[1]==b':' && (value[2]==b'/' || value[2]==b'\\')))){return false}
    for(part in value.replace("\\","/").split("/")){if(part=="." || part==".."){return false}}
    true
}
func pluginLivePolicyNoNetwork(plan:NormalizedOperationPlan):Bool{
    networkPolicyModeIsDenied(plan.networkPolicy.mode) && plan.networkPolicy.egress.isEmpty() && plan.networkPolicy.publish.isEmpty()
}
