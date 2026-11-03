package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.reserveNativeDocumentPayload
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These are DATA/codec oracles over actual SQLite rows. They do not manufacture
// a prepared Root, Receipt, legal context cut or execution authorization.
@Test
class CheckpointOwnedProjectionOracle11318Tests {
    @TestCase
    func completeOriginalCodecMatchesUnicodeNulOpaqueFutureCallsAndAssistantMerges113(): Unit {
        let f = CheckpointProjectionOracleFixture113(13, false)
        try { checkpointCompareOriginalCodec113(f) } finally { f.close() }
    }
    @TestCase
    func actualNearEightMiBMultiCellCorpusUsesOriginalPoolAndExactWholeCodec113(): Unit {
        // 64 independent 131056-byte scalars: 8,387,584 payload bytes. A
        // single near8MiB cell is deliberately not substituted for this corpus.
        let f = CheckpointProjectionOracleFixture113(64, true)
        try { checkpointCompareOriginalCodec113(f) } finally { f.close() }
    }
    @TestCase
    func sixteenThousandThreeHundredEightyFourActualMessagesAreNotAnInvoiceLimit113(): Unit {
        let f = CheckpointProjectionOracleFixture113(16384, false)
        try { checkpointCompareOriginalCodec113(f) } finally { f.close() }
    }
}

class CheckpointProjectionOracleFixture113 {
    let path: String
    let db: SqliteDatabase
    let thread = ThreadId("projection-oracle113-thread")
    let count: Int64
    init(count: Int64, large: Bool) {
        path = Directory.createTemp("/tmp").toString(); db = SqliteDatabase(path + "/projection.sqlite")
        this.count = count
        let _ = SqliteThreadCommitSink(db).createThread(thread, "workspace")
        db.execute("INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
            "VALUES(?,?,1,'completed',?,NULL)", [SqlParameter.Text("projection-turn113"),
                SqlParameter.Text(thread.value), SqlParameter.Text("projection-item113-1")])
        let owner = reserveNativeDocumentPayload(1)
        try {
            db.transaction<Unit> { tx: SqliteTransaction =>
                for (ordinal in 1..=count) { checkpointSeedOracleFrame113(tx, thread, ordinal, count, large, owner) }
                tx.execute("UPDATE threads SET revision=1,next_item_ordinal=? WHERE id=?",
                    [SqlParameter.Int64Value(count + 1), SqlParameter.Text(thread.value)])
            }
        } finally { owner.close() }
    }
    func close(): Unit { db.close(); remove(path, recursive: true) }
}
private func checkpointSeedOracleFrame113(tx: SqliteTransaction, thread: ThreadId, ordinal: Int64,
    count: Int64, large: Bool, owner: LogicalJsonOwnerReservation): Unit {
    owner.ensureRetainedPeak(16777216)
    let content = if (large) {
        ThreadItemContent.UserMessage(textMessageParts(String.fromUtf8(Array<Byte>(131056, repeat: b'x'))))
    } else if (count != 13) {
        ThreadItemContent.UserMessage(textMessageParts("actual message 雪\u{0000}" + ordinal.toString()))
    } else {
        match (ordinal) {
            case 1 => ThreadItemContent.UserMessage(textMessageParts("雪\u{0000}🙂 first user"))
            case 2 => ThreadItemContent.AssistantMessage(textMessageParts("first assistant"))
            case 3 => ThreadItemContent.AssistantMessage(textMessageParts("merged assistant\u{0000}"))
            // A result before the first matching call must use the name from
            // the complete original prefix rather than a one-pass fallback.
            case 4 => ThreadItemContent.ToolResult(CanonicalToolCallId("future113"), OperationId("op113-4"),
                "receipt113-4", objectValue([ValueField("text", textValue("result before call"))]), false)
            case 5 => ThreadItemContent.ProviderOpaqueItem(OpaqueProviderState("oracle-provider", "oracle-protocol",
                "{\"opaque\":\"雪\\u0000\"}", itemId: "opaque113", replayRequired: true))
            case 6 => ThreadItemContent.ToolCall(CanonicalToolCallId("future113"), "future-name113",
                objectValue([ValueField("x", numberValue("-0"))]))
            case 7 => ThreadItemContent.ReasoningReference("reasoning113", "reasoning summary 雪")
            case 8 => ThreadItemContent.ArtifactReference("sha256:oracle113", "text/plain", 17)
            case 9 => ThreadItemContent.ToolResult(CanonicalToolCallId("adjacent113"), OperationId("op113-9"),
                "receipt113-9", boolValue(false), true)
            case 10 => ThreadItemContent.ToolResult(CanonicalToolCallId("adjacent113"), OperationId("op113-10"),
                "receipt113-10", textValue("adjacent result"), false)
            case 11 => ThreadItemContent.ToolCall(CanonicalToolCallId("adjacent113"), "adjacent-name113",
                objectValue([ValueField("nullable", nullValue())]))
            case 12 => ThreadItemContent.ProviderOpaqueItem(OpaqueProviderState("oracle-provider", "oracle-protocol",
                "{\"unpaired\":true}", itemId: "tail113"))
            case _ => ThreadItemContent.SystemNote("unprojected note still in original SourceDigest\u{0000}")
        }
    }
    let operation: ?OperationId = match (content) { case ThreadItemContent.ToolResult(_, id, _, _, _) => Some(id)
        case _ => None<OperationId> }
    let provenance = ItemProvenance(if (ordinal == 5 || ordinal == 12) { "provider_tool_call" } else { "system" },
        operationId: operation)
    tx.execute("INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
        "VALUES(?,?,?,?,?,?,?,?)", [SqlParameter.Text("projection-item113-" + ordinal.toString()),
            SqlParameter.Text(thread.value), SqlParameter.Text("projection-turn113"), SqlParameter.Int64Value(ordinal),
            SqlParameter.Text(checkpointOracleItemKind113(content)), SqlParameter.Text(encodeStoredThreadContent(content)),
            SqlParameter.Text(encodeStoredProvenance(provenance)), SqlParameter.Int64Value(ordinal)])
}
private func checkpointOracleItemKind113(content: ThreadItemContent): String {
    match (content) {
        case ThreadItemContent.UserMessage(_) => "user_message"
        case ThreadItemContent.AssistantMessage(_) => "assistant_message"
        case ThreadItemContent.ToolCall(_, _, _) => "tool_call"
        case ThreadItemContent.ToolResult(_, _, _, _, _) => "tool_result"
        case ThreadItemContent.ReasoningReference(_, _) => "reasoning_reference"
        case ThreadItemContent.ProviderOpaqueItem(_) => "provider_opaque"
        case ThreadItemContent.ArtifactReference(_, _, _) => "artifact_reference"
        case ThreadItemContent.SystemNote(_) => "system_note" }
}

private func checkpointCompareOriginalCodec113(f: CheckpointProjectionOracleFixture113): Unit {
    // Original whole snapshot/model codec is the independent oracle. This
    // phase and all of its full DOM/arrays return BEFORE the streamed phase;
    // both use the production's SAME original 128MiB bank and 16MiB floor.
    let original = checkpointOriginalWholeOracle113(f)
    let cursor = SqlitePaidCanonicalThreadCursor113(f.db, { bytes => reserveNativeDocumentPayload(bytes) })
    @Expect(cursor.withHeader(f.thread, { => Result<Unit>.Ok(()) }, { header =>
        let projection = checkpointOwnedProjectionDigest113(cursor, f.thread, 1, f.count + 1, f.count,
            nullValue(), listValue([]), { bytes => reserveNativeDocumentPayload(bytes) },
            { => Result<Unit>.Ok(()) }, { => Result<Unit>.Ok(()) })
        @Expect(projection, original[0])
        @Expect(ownedContextSourceDigestWithPaidCursor113(header, cursor, f.count,
            { => Result<Unit>.Ok(()) }, { => Result<Unit>.Ok(()) }), original[1])
        Result<Unit>.Ok(()) }).isOk(), true)
    // Every original cursor/hash/metadata/row owner must actually be retired.
    // A full original-pool invoice is possible only when none remains live.
    let retired = reserveNativeDocumentPayload(1)
    try { retired.ensureRetainedPeak(134217728) } finally { retired.close() }
}
private func checkpointOriginalWholeOracle113(f: CheckpointProjectionOracleFixture113): (String, String) {
    let owner = reserveNativeDocumentPayload(1)
    try {
        // Source SQL/decoded corpus, original provider-neutral model containers
        // and transient exact codec strings coexist in this test-only phase.
        // The fixed corpus is bounded below the existing 128MiB pool, with
        // room for the ORIGINAL digest's actual 64KiB fixed hash buffer.
        owner.ensureRetainedPeak(125829120)
        checkpointOriginalWholeOracleFrame113(f)
    } finally { owner.close() }
}
private func checkpointOriginalWholeOracleFrame113(f: CheckpointProjectionOracleFixture113): (String, String) {
    let snapshot = SqliteThreadCommitSink(f.db).loadThread(f.thread)
    let projection = modelRequestSnapshotValue(ModelRequest("compaction-history",
        modelMessagesFromCanonicalItems(snapshot.items)))
    let facts = objectValue([ValueField("projection", projection), ValueField("goal", nullValue()),
        ValueField("todos", listValue([]))])
    (ProductPolicyDataDigest().digest(facts), contextSourceDigest(snapshot, f.count))
}
