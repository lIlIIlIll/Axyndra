package agent_domain

import yjson.*
import yjson_support.*

public let PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA="axyndra.plugin-document-journal-stream-read/v2"
public let PLUGIN_DOCUMENT_CONTEXT_JOURNAL_STREAM_READ_SCHEMA="axyndra.plugin-document-context-journal-stream-read/v2"
public let PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_RESULT_SCHEMA="axyndra.plugin-document-journal-stream-read-result/v2"

// One new actual read, with no Native-selected table, SQL, path, field rule,
// byte selector, shortened prior proof or change to the old eight-stage cap.
// access_policy_digest is frozen from the actual operator document by Host;
// the parser never treats a supplied digest as a grant or current witness.
public func pluginDocumentJournalStreamReadRequestValid(value:AgentValue):Bool{
    try{journalStreamRequestShape(value,PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA) &&
        !validatePluginDocumentBinding(value.field("binding").getOrThrow()).isError()}
    catch(_:Exception){false}
}
public func pluginDocumentContextJournalStreamReadRequestValid(value:AgentValue):Bool{
    try{journalStreamRequestShape(value,PLUGIN_DOCUMENT_CONTEXT_JOURNAL_STREAM_READ_SCHEMA) &&
        pluginDocumentContextBindingValid(value.field("binding").getOrThrow())}
    catch(_:Exception){false}
}
func journalStreamRequestShape(value:AgentValue,schema:String):Bool{
    httpIntentExactFields(value,["schema","binding","projection_digest","key","access_policy_digest"]) &&
        httpIntentText(value,"schema")==schema && httpIntentDigest(httpIntentText(value,"projection_digest")) &&
        httpIntentDigest(httpIntentText(value,"access_policy_digest")) &&
        documentContractIdentifier(httpIntentText(value,"key")) && stringifyUnifiedJson(value).size<=16384
}
public func pluginDocumentJournalStreamReadAuthority(plan:NormalizedOperationPlan):Bool{
    pluginDocumentJournalStreamReadRequestValid(plan.canonicalArguments) && journalStreamReadCapability(plan)
}
public func pluginDocumentContextJournalStreamReadAuthority(plan:NormalizedOperationPlan):Bool{
    pluginDocumentContextJournalStreamReadRequestValid(plan.canonicalArguments) && journalStreamReadCapability(plan)
}
func journalStreamReadCapability(plan:NormalizedOperationPlan):Bool{
    plan.requiredCapabilities.size==1 && plan.resolvedPaths.isEmpty() && plan.resolvedHosts.isEmpty() &&
        plan.requiredCapabilities[0].kind==CapabilityKind.ExtensionInvoke &&
        plan.requiredCapabilities[0].resource==httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(),"namespace")
}
public func pluginDocumentJournalStreamReadResultValid(value:AgentValue,request:AgentValue):Bool{
    pluginDocumentJournalStreamReadRequestValid(request) &&
        pluginDocumentJournalStreamReadResultDataValid(value,modelPolicySha256Text(canonicalAgentValue(request)),httpIntentText(request,"key"))
}
public func pluginDocumentContextJournalStreamReadResultValid(value:AgentValue,request:AgentValue):Bool{
    pluginDocumentContextJournalStreamReadRequestValid(request) &&
        pluginDocumentJournalStreamReadResultDataValid(value,modelPolicySha256Text(canonicalAgentValue(request)),httpIntentText(request,"key"))
}
// Shared descriptive output; Store still checks the actual Root/fact/ref,
// artifact metadata, complete current fence and file owner independently.
public func pluginDocumentJournalStreamReadResultDataValid(value:AgentValue,requestDigest:String,key:String):Bool{
    try{
        if(!httpIntentDigest(requestDigest) || !documentContractIdentifier(key) ||
            !httpIntentExactFields(value,["schema","request_digest","documents"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_RESULT_SCHEMA ||
            httpIntentText(value,"request_digest")!=requestDigest){return false}
        let documents=value.field("documents").getOrThrow()
        if(documents.unifiedKind!=ValueKind.List || documents.items.size!=1){return false}
        let item=documents.items[0]
        httpIntentExactFields(item,["key","revision","stream"]) && httpIntentText(item,"key")==key &&
            documentContractInteger(item.field("revision").getOrThrow())>=1 &&
            parsePluginDocumentJournalStreamReference(item.field("stream").getOrThrow()).isOk()
    }catch(_:Exception){false}
}
