package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// Completed historical DATA. This DTO, its origin description and digests
// provide NO Run admission, capability, Direct source or continuation claim.
// Store alone freezes the actually completed canonical origin/receipt graph.
public class CompletedInitiatorHistory173e {
    public let threadId: String
    public let turnId: String
    public let runId: String
    public let itemId: String
    public let originalSource: String
    public let origin: ?DirectCallOrigin
    public let originDigest: String
    public let evidenceDigest: String
    public let evidenceCells: Int64
    public init(threadId: String, turnId: String, runId: String, itemId: String,
        originalSource: String, origin: ?DirectCallOrigin, originDigest: String, evidenceDigest: String, evidenceCells: Int64) {
        for (text in [threadId,turnId,runId,itemId]) {
            if (text == "") { throw IllegalArgumentException("completed initiator history identity is missing") } }
        let matchesOrigin = match (origin) {
            case Some(DirectCallOrigin.HostService(_)) => originalSource == "host_service"
            case Some(DirectCallOrigin.External(_)) => originalSource == "external"
            case Some(DirectCallOrigin.ManagedJob(_)) => originalSource == "managed_job"
            case None => originalSource == "model_maintenance"
            case _ => false }
        if (!matchesOrigin || !completedHistoryDigest173e(originDigest) || !completedHistoryDigest173e(evidenceDigest) || evidenceCells < 1) {
            throw IllegalArgumentException("completed initiator history has no exact descriptive origin/evidence") }
        this.threadId=threadId;this.turnId=turnId;this.runId=runId;this.itemId=itemId
        this.originalSource=originalSource;this.origin=origin;this.originDigest=originDigest
        this.evidenceDigest=evidenceDigest;this.evidenceCells=evidenceCells
    }
}
func completedHistoryDigest173e(text: String): Bool {
    if (text.size != 64) { return false }
    for (byte in unsafe { text.rawData() }) {
        if (!((byte>=b'0' && byte<=b'9') || (byte>=b'a' && byte<=b'f'))) { return false } }; true
}
public func completedInitiatorHistoryValue173e(value: CompletedInitiatorHistory173e): AgentValue {
    objectValue([ValueField("schema",textValue("axyndra.completed-initiator-history/v1")),
        ValueField("thread_id",textValue(value.threadId)),ValueField("turn_id",textValue(value.turnId)),
        ValueField("run_id",textValue(value.runId)),ValueField("item_id",textValue(value.itemId)),
        ValueField("original_source",textValue(value.originalSource)),
        ValueField("origin",match(value.origin){case Some(origin)=>directCallOriginValue(origin);case None=>nullValue()}),
        ValueField("origin_digest",textValue(value.originDigest)),ValueField("evidence_digest",textValue(value.evidenceDigest)),
        ValueField("evidence_cells",integerValue(value.evidenceCells))])
}
public func completedInitiatorHistoryFromValue173e(value: AgentValue): CompletedInitiatorHistory173e {
    if (!httpIntentExactFields(value,["schema","thread_id","turn_id","run_id","item_id","original_source","origin",
        "origin_digest","evidence_digest","evidence_cells"]) ||
        httpIntentText(value,"schema")!="axyndra.completed-initiator-history/v1") {
        throw IllegalArgumentException("unsupported completed initiator history DATA") }
    let origin=value.field("origin").getOrThrow();let cells=value.field("evidence_cells").getOrThrow()
    if(cells.unifiedKind!=ValueKind.Number){throw IllegalArgumentException("completed history cell count is not an integer")}
    CompletedInitiatorHistory173e(httpIntentText(value,"thread_id"),httpIntentText(value,"turn_id"),httpIntentText(value,"run_id"),
        httpIntentText(value,"item_id"),httpIntentText(value,"original_source"),
        if(origin.unifiedKind==ValueKind.Null){None<DirectCallOrigin>}else{Some(directCallOriginFromValue(origin))},
        httpIntentText(value,"origin_digest"),httpIntentText(value,"evidence_digest"),Int64.parse(cells.asNumberText()))
}
public func isCompletedInitiatorHistory173e(item: ThreadItem): Bool {
    item.kind==ItemKind.SystemNote && item.provenance.source=="completed_initiator_history" &&
        item.provenance.completedInitiatorHistory173e.isSome() && item.provenance.runId.isSome() &&
        item.provenance.operationId.isNone() && item.provenance.directOrigin.isNone() &&
        item.provenance.continuationOrigin.isNone() && item.provenance.continuationHistory.isNone()
}
