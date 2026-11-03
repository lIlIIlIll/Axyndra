package agent_domain

import yjson.*
import yjson_support.*

public let PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA="axyndra.plugin-document-journal-stream-read/v3"
public let PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA="axyndra.plugin-document-context-journal-stream-read/v3"
public let PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_RESULT_SCHEMA="axyndra.plugin-document-journal-stream-read-result/v3"
public let PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_REFERENCE_SCHEMA="axyndra.plugin-document-journal-stream/v3"
public let PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_ENCODING="axyndra-journal-frames/v3"
public let PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_CONTENT_TYPE="application/x-axyndra-journal; version=3"

public func pluginDocumentLatestJournalStreamReadRequestValid(value:AgentValue):Bool{
    try{latestJournalStreamRequestShape(value,PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA) &&
        validatePluginDocumentBinding(value.field("binding").getOrThrow()).isOk()}
    catch(_:Exception){false}
}
public func pluginDocumentContextLatestJournalStreamReadRequestValid(value:AgentValue):Bool{
    try{latestJournalStreamRequestShape(value,PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA) &&
        pluginDocumentContextBindingValid(value.field("binding").getOrThrow())}
    catch(_:Exception){false}
}
func latestJournalStreamRequestShape(value:AgentValue,schema:String):Bool{
    httpIntentExactFields(value,["schema","binding","projection_digest","key","access_policy_digest","view_policy_digest"]) &&
        httpIntentText(value,"schema")==schema && httpIntentDigest(httpIntentText(value,"projection_digest")) &&
        httpIntentDigest(httpIntentText(value,"access_policy_digest")) && httpIntentDigest(httpIntentText(value,"view_policy_digest")) &&
        documentContractIdentifier(httpIntentText(value,"key")) && stringifyUnifiedJson(value).size<=16384
}
public func pluginDocumentLatestJournalStreamReadAuthority(plan:NormalizedOperationPlan):Bool{
    pluginDocumentLatestJournalStreamReadRequestValid(plan.canonicalArguments) && latestJournalStreamCapability(plan)
}
public func pluginDocumentContextLatestJournalStreamReadAuthority(plan:NormalizedOperationPlan):Bool{
    pluginDocumentContextLatestJournalStreamReadRequestValid(plan.canonicalArguments) && latestJournalStreamCapability(plan)
}
func latestJournalStreamCapability(plan:NormalizedOperationPlan):Bool{
    plan.requiredCapabilities.size==1 && plan.resolvedPaths.isEmpty() && plan.resolvedHosts.isEmpty() &&
        plan.requiredCapabilities[0].kind==CapabilityKind.ExtensionInvoke &&
        plan.requiredCapabilities[0].resource==httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(),"namespace")
}
public class PluginDocumentLatestJournalStreamReference {
    public let artifactRef:String
    public let bytes:Int64
    public let digest:String
    private init(artifactRef:String,bytes:Int64,digest:String){this.artifactRef=artifactRef;this.bytes=bytes;this.digest=digest}
    public func toValue():AgentValue{objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_REFERENCE_SCHEMA)),
        ValueField("artifact_ref",textValue(artifactRef)),ValueField("encoding",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_ENCODING)),
        ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_CONTENT_TYPE))])}
    public static func parse(value:AgentValue):PluginDocumentLatestJournalStreamReference{
        if(!httpIntentExactFields(value,["schema","artifact_ref","encoding","bytes","sha256","content_type"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_REFERENCE_SCHEMA ||
            httpIntentText(value,"encoding")!=PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_ENCODING ||
            httpIntentText(value,"content_type")!=PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_CONTENT_TYPE){
            throw LogicalJsonPayloadError("latest stream reference has another exact descriptive dialect")}
        let bytes=documentContractInteger(value.field("bytes").getOrThrow());let digest=httpIntentText(value,"sha256")
        let ref=httpIntentText(value,"artifact_ref")
        if(bytes<1 || !httpIntentDigest(digest) || ref!="blob:sha256:"+digest){
            throw LogicalJsonPayloadError("latest stream reference has invalid complete public bytes or digest")}
        PluginDocumentLatestJournalStreamReference(ref,bytes,digest)
    }
}
public func parsePluginDocumentLatestJournalStreamReference(value:AgentValue):Result<PluginDocumentLatestJournalStreamReference>{
    try{Result.Ok(PluginDocumentLatestJournalStreamReference.parse(value))}
    catch(_:Exception){Result.Err(AgentError(AgentErrorKind.InvalidInput,"plugin.document_latest_stream_reference_invalid",
        "exact public authorized-byte artifact reference required; it grants no data or file access"))}
}
public func pluginDocumentLatestJournalStreamReadResultValid(value:AgentValue,request:AgentValue):Bool{
    pluginDocumentLatestJournalStreamReadRequestValid(request) &&
        pluginDocumentLatestJournalStreamResultDataValid(value,modelPolicySha256Text(canonicalAgentValue(request)),httpIntentText(request,"key"))
}
public func pluginDocumentContextLatestJournalStreamReadResultValid(value:AgentValue,request:AgentValue):Bool{
    pluginDocumentContextLatestJournalStreamReadRequestValid(request) &&
        pluginDocumentLatestJournalStreamResultDataValid(value,modelPolicySha256Text(canonicalAgentValue(request)),httpIntentText(request,"key"))
}
// The artifact is only the authorized public stream. No global cache/history
// blind SHA, private grouping key/hash/token/ordinal or sequence appears here.
public func pluginDocumentLatestJournalStreamResultDataValid(value:AgentValue,requestDigest:String,key:String):Bool{
    try{
        if(!httpIntentDigest(requestDigest) || !documentContractIdentifier(key) ||
            !httpIntentExactFields(value,["schema","request_digest","documents"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_RESULT_SCHEMA ||
            httpIntentText(value,"request_digest")!=requestDigest){return false}
        let rows=value.field("documents").getOrThrow()
        if(rows.unifiedKind!=ValueKind.List || rows.items.size!=1){return false}
        let row=rows.items[0]
        httpIntentExactFields(row,["key","revision","stream"]) && httpIntentText(row,"key")==key &&
            documentContractInteger(row.field("revision").getOrThrow())>=1 &&
            parsePluginDocumentLatestJournalStreamReference(row.field("stream").getOrThrow()).isOk()
    }catch(_:Exception){false}
}
