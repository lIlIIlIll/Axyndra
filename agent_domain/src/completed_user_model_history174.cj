package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// This is a description of the closed original Turn and ALL its Runs. The
// latest-epoch Run identifies the description, not a replay or admission.
// ItemProvenance and the original User/fork/seed codecs are deliberately absent.
public class CompletedUserModelHistory174 {
    public let threadId: String
    public let turnId: String
    public let runId: String
    public let itemId: String
    public let turnState: String
    public let latestEpoch: Int64
    public let runCount: Int64
    public let originDigest: String
    public let evidenceDigest: String
    public let evidenceCells: Int64
    public init(threadId: String, turnId: String, runId: String, itemId: String,
        turnState: String, latestEpoch: Int64, runCount: Int64,
        originDigest: String, evidenceDigest: String, evidenceCells: Int64) {
        for (value in [threadId, turnId, runId, itemId]) {
            if (value == "") { throw IllegalArgumentException("User/model history identity is missing") }
        }
        if (!(turnState == "completed" || turnState == "failed" || turnState == "cancelled" || turnState == "superseded") ||
            latestEpoch < 1 || runCount < 1 || evidenceCells < 1 ||
            !completedHistoryDigest173e(originDigest) || !completedHistoryDigest173e(evidenceDigest)) {
            throw IllegalArgumentException("User/model history lacks its closed Turn/all-Run evidence")
        }
        this.threadId=threadId; this.turnId=turnId; this.runId=runId; this.itemId=itemId
        this.turnState=turnState; this.latestEpoch=latestEpoch; this.runCount=runCount
        this.originDigest=originDigest; this.evidenceDigest=evidenceDigest; this.evidenceCells=evidenceCells
    }
}
public func completedUserModelHistoryValue174(value: CompletedUserModelHistory174): AgentValue {
    objectValue([ValueField("schema",textValue("axyndra.completed-user-model-history/v1")),
        ValueField("thread_id",textValue(value.threadId)),ValueField("turn_id",textValue(value.turnId)),
        ValueField("run_id",textValue(value.runId)),ValueField("item_id",textValue(value.itemId)),
        ValueField("turn_state",textValue(value.turnState)),ValueField("latest_epoch",integerValue(value.latestEpoch)),
        ValueField("run_count",integerValue(value.runCount)),ValueField("origin_digest",textValue(value.originDigest)),
        ValueField("evidence_digest",textValue(value.evidenceDigest)),ValueField("evidence_cells",integerValue(value.evidenceCells))])
}
public func completedUserModelHistoryFromValue174(value: AgentValue): CompletedUserModelHistory174 {
    if (!httpIntentExactFields(value,["schema","thread_id","turn_id","run_id","item_id","turn_state",
        "latest_epoch","run_count","origin_digest","evidence_digest","evidence_cells"]) ||
        httpIntentText(value,"schema") != "axyndra.completed-user-model-history/v1") {
        throw IllegalArgumentException("unsupported User/model history DATA")
    }
    for (key in ["latest_epoch","run_count","evidence_cells"]) {
        if (value.field(key).getOrThrow().unifiedKind != ValueKind.Number) {
            throw IllegalArgumentException("User/model history count is not an integer")
        }
    }
    CompletedUserModelHistory174(httpIntentText(value,"thread_id"),httpIntentText(value,"turn_id"),
        httpIntentText(value,"run_id"),httpIntentText(value,"item_id"),httpIntentText(value,"turn_state"),
        Int64.parse(value.field("latest_epoch").getOrThrow().asNumberText()),
        Int64.parse(value.field("run_count").getOrThrow().asNumberText()),httpIntentText(value,"origin_digest"),
        httpIntentText(value,"evidence_digest"),Int64.parse(value.field("evidence_cells").getOrThrow().asNumberText()))
}
