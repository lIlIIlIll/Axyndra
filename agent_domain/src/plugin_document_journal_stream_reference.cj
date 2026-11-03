package agent_domain

import yjson.*
import yjson_support.*
public let PLUGIN_DOCUMENT_JOURNAL_STREAM_REFERENCE_SCHEMA="axyndra.plugin-document-journal-stream/v2"
public let PLUGIN_DOCUMENT_JOURNAL_STREAM_ENCODING="axyndra-journal-frames/v2"
public let PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE="application/x-axyndra-journal; version=2"

// Binary framing is deliberately separate from the old UTF8 payload reference
// and its unchanged 8MiB ceiling. Parsing this descriptive reference does not
// open a file or permit a read. Every byte still belongs to a real paid Root,
// registered artifact, complete Source/Receipt/fence and bounded file cursor.
public class PluginDocumentJournalStreamReference {
    public let artifactRef:String
    public let bytes:Int64
    public let digest:String
    private init(artifactRef:String,bytes:Int64,digest:String){this.artifactRef=artifactRef;this.bytes=bytes;this.digest=digest}
    public func toValue():AgentValue{objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_REFERENCE_SCHEMA)),
        ValueField("artifact_ref",textValue(artifactRef)),ValueField("encoding",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_ENCODING)),
        ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE))])}
    public static func parse(value:AgentValue):PluginDocumentJournalStreamReference{
        if(!httpIntentExactFields(value,["schema","artifact_ref","encoding","bytes","sha256","content_type"]) ||
            httpIntentText(value,"schema")!=PLUGIN_DOCUMENT_JOURNAL_STREAM_REFERENCE_SCHEMA ||
            httpIntentText(value,"encoding")!=PLUGIN_DOCUMENT_JOURNAL_STREAM_ENCODING ||
            httpIntentText(value,"content_type")!=PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE){
            throw LogicalJsonPayloadError("journal stream reference has another exact dialect")}
        let bytes=documentContractInteger(value.field("bytes").getOrThrow());let digest=httpIntentText(value,"sha256")
        let ref=httpIntentText(value,"artifact_ref")
        if(bytes<1 || !httpIntentDigest(digest) || ref!="blob:sha256:"+digest){
            throw LogicalJsonPayloadError("journal stream reference has invalid whole bytes or digest")}
        // There is no aggregate history format ceiling. Actual frozen operator
        // budgets, deadline, file-storage ownership and cancellation constrain
        // each real transfer; no allocation is made from this length.
        PluginDocumentJournalStreamReference(ref,bytes,digest)
    }
}
public func parsePluginDocumentJournalStreamReference(value:AgentValue):Result<PluginDocumentJournalStreamReference>{
    try{Result.Ok(PluginDocumentJournalStreamReference.parse(value))}
    catch(_:Exception){Result.Err(AgentError(AgentErrorKind.InvalidInput,"plugin.document_journal_stream_reference_invalid",
        "exact descriptive stream reference required; it grants no file or data access"))}
}
