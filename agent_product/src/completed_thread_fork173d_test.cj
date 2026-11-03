package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func coreCompletedCheckpoint173d(f: CompactionPolicyFixture): Unit {
    let session = f.product.applicationSession(sessionId: Some(f.session))
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("fork-checkpoint173d", "plugin.axyndra:compaction.checkpoint",
        objectValue([ValueField("goal", textValue("Exact historical 闆猏u{0} goal"))]))
    @Expect(session.submit("Create the genuine completed checkpoint.").isOk())
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("fork-rewind173d", "plugin.axyndra:compaction.rewind",
        objectValue([ValueField("report", textValue("Exact historical report 馃檪\u{0} tail"))]))
    @Expect(session.submit("Commit the genuine original report.").isOk())
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
}
private func fullOriginalSeedOracle173d(database: SqliteDatabase, source: AgentThreadSnapshot,
    target: AgentThreadSnapshot): Unit {
    @Expect(target.thread.id.value, source.thread.id.value)
    @Expect(target.thread.workspaceId, source.thread.workspaceId)
    @Expect(target.thread.revision, source.thread.revision)
    @Expect(target.thread.nextItemOrdinal, source.thread.nextItemOrdinal)
    @Expect(target.thread.status, source.thread.status)
    @Expect(target.thread.activeTurnId.isNone() && target.activeRunId.isNone())
    @Expect(target.activeEpoch, source.activeEpoch)
    @Expect(target.turns.size, source.turns.size); @Expect(target.items.size, source.items.size)
    for (at in 0..source.turns.size) {
        let expected = source.turns[at]; let actual = target.turns[at]
        @Expect(actual.id.value, expected.id.value); @Expect(actual.ordinal, expected.ordinal)
        @Expect(actual.userItemId.value, expected.userItemId.value); @Expect(actual.state, expected.state)
        @Expect(actual.activeRunId.isNone())
    }
    for (at in 0..source.items.size) {
        let expected = source.items[at]; let actual = target.items[at]
        @Expect(actual.id.value, expected.id.value); @Expect(actual.turnId.value, expected.turnId.value)
        @Expect(actual.ordinal, expected.ordinal); @Expect(actual.kind, expected.kind)
        @Expect(encodeStoredThreadContent(actual.content), encodeStoredThreadContent(expected.content))
        @Expect(encodeStoredProvenance(actual.provenance), encodeStoredProvenance(expected.provenance))
        @Expect(actual.createdAtMillis, expected.createdAtMillis)
    }
    @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id=" + sqliteText(target.thread.id.value) +
        " AND state='completed' AND cancellation_reason IS NULL"), target.turns.size)
}
private func completedForkExecutionCount173d(database: SqliteDatabase): Array<Int64> {
    [database.scalarInt("SELECT COUNT(*) FROM operations"), database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),
        database.scalarInt("SELECT COUNT(*) FROM model_attempts"),
        database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")]
}
private func expectCompletedForkCounts173d(database: SqliteDatabase, before: Array<Int64>): Unit {
    let actual = completedForkExecutionCount173d(database)
    for (at in 0..before.size) { @Expect(actual[at], before[at]) }
}
class CompletedForkErrorCapture173d { var value: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113> }

private func seedFullOriginalCorpusFrame173d(f: CompactionPolicyFixture, wide: Bool): Unit {
    // This is the actual existing Product seed writer, never synthetic SQL.
    // Its complete producer/encoder/SQL frame returns before caller payment
    // closes; no input/model String crosses this helper boundary.
    if (wide) {
        let messages = ArrayList<ModelMessage>()
        for (at in 0..16384) { messages.add(ModelMessage(if (at % 2 == 0) { ModelRole.User } else { ModelRole.Assistant },
            [ModelBlock(ModelBlockKind.Text, text: "original short 雪\u{0} " + at.toString())])) }
        @Expect(f.product.replaceMessages(f.session, messages.toArray()).isOk())
    } else {
        let text = String.fromUtf8(Array<Byte>(8388608 - 65536, repeat: b'x')) + "雪🙂\u{0} ORIGINAL TAIL"
        @Expect(f.product.replaceMessages(f.session, [ModelMessage(ModelRole.User,
            [ModelBlock(ModelBlockKind.Text, text: text)])]).isOk())
    }
}
private func requireFullOriginalCorpusFrame173d(f: CompactionPolicyFixture, target: SessionId, wide: Bool): Unit {
    let expectedCount: Int64 = if (wide) { 16384 } else { 1 }
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id=" + sqliteText(f.session.value)), expectedCount)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id=" + sqliteText(target.value)), expectedCount)
    var ordinal: Int64 = 1
    while (ordinal <= expectedCount) {
        // One complete source/target row pair; never a 16K history snapshot.
        let rows = f.database.query("SELECT source.kind,source.payload,target.kind,target.payload " +
            "FROM items source JOIN items target ON target.ordinal=source.ordinal " +
            "WHERE source.thread_id=? AND target.thread_id=? AND source.ordinal=?",
            [SqlParameter.Text(f.session.value), SqlParameter.Text(target.value), SqlParameter.Int64Value(ordinal)])
        @Expect(rows.size, 1); @Expect(rows[0].required(0), rows[0].required(2))
        @Expect(rows[0].required(1) == rows[0].required(3))
        if (!wide) { @Expect(rows[0].required(1).size > 8388608 - 65536 && rows[0].required(1).size <= 8388608) }
        ordinal++
    }
}

@Test
class InstalledCompletedThreadFork173dTests {
    @TestCase
    func originalNearEightMiBCellAnd16384ShortMessagesStayOnSameUnreducedBank173d(): Unit {
        for (wide in [false, true]) {
            let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
            try {
                let seed = reserveNativeControlMetadata(67108864)
                try { seedFullOriginalCorpusFrame173d(f, wide) } finally { seed.close() }
                let before = completedForkExecutionCount173d(f.database)
                let target = SessionId("full-corpus-fork173d")
                @Expect(f.product.forkSession(f.session, target).isOk())
                let oracle = reserveNativeControlMetadata(67108864)
                try { requireFullOriginalCorpusFrame173d(f, target, wide) } finally { oracle.close() }
                expectCompletedForkCounts173d(f.database, before)
            } finally { f.close() }
        }
    }
    @TestCase
    func indexedFullContentAndProvenanceDigestMatchesOriginalWholeCodec173d(): Unit {
        let payer = reserveNativeControlMetadata(8388608)
        try {
            let thread = ThreadId("full-digest173d"); let turn = SemanticTurnId("digest-turn173d")
            let run = RunId("digest-run173d"); let call = CanonicalToolCallId("digest-call173d")
            let value = objectValue([ValueField("z雪", listValue([integerValue(Int64.Min), nullValue(),
                JsonNode.float64(-0.0), JsonNode.uint64(UInt64.Max), textValue("🙂\u{0}")])),
                ValueField("a", objectValue([ValueField("last", boolValue(true)), ValueField("first", boolValue(false))]))])
            let contents: Array<ThreadItemContent> = [
                ThreadItemContent.UserMessage([ThreadMessagePart.Text("雪\u{0}"),
                    ThreadMessagePart.Image(ThreadImage(ThreadImageSourceKind.Url, "https://example.invalid/image")),
                    ThreadMessagePart.Image(ThreadImage(ThreadImageSourceKind.Base64, "YQ==", mediaType: "image/png")),
                    ThreadMessagePart.Image(ThreadImage(ThreadImageSourceKind.Artifact, "sha256:original"))]),
                ThreadItemContent.ToolResult(call, OperationId("digest-operation173d"), "digest-receipt173d", value, true),
                ThreadItemContent.ToolCall(call, "future original tool", value),
                ThreadItemContent.AssistantMessage([ThreadMessagePart.Text("assistant merged 雪"), ThreadMessagePart.Refusal("refusal\u{0}")]),
                ThreadItemContent.ReasoningReference("safe-original-id", "safe-original-summary"),
                ThreadItemContent.ProviderOpaqueItem(OpaqueProviderState("provider", "original protocol", "opaque\u{0}雪",
                    itemId: "opaque-item", replayRequired: true)),
                ThreadItemContent.ArtifactReference("sha256:original", "image/png", 7),
                ThreadItemContent.SystemNote("original system note 雪\u{0}")]
            let items = ArrayList<ThreadItem>()
            for (at in 0..contents.size) {
                let operation: ?OperationId = if (at == 1) { Some(OperationId("digest-operation173d")) } else { None<OperationId> }
                items.add(ThreadItem(ItemId("digest-item-" + at.toString()), thread, turn, at + 1, contents[at],
                    ItemProvenance("original", runId: Some(run), operationId: operation), createdAtMillis: at)) }
            let snapshot = AgentThreadSnapshot(ThreadRecord(thread, 1, "workspace", ThreadStatus.Open, items.size + 1), [], items.toArray())
            for (cover in 1..items.size + 1) {
                let writer = OwnedContextPrefixDigest173d(thread, cover, { bytes => payer.ensureRetainedPeak(8388608 + bytes) })
                for (item in snapshot.items) { writer.consumeItem173d(item) }
                @Expect(writer.finish173d(), contextSourceDigest(snapshot, cover)) }
            let history = ContinuationHistorySource("old-thread", "old-turn", "old-run", "old-item", modelPolicySha256Text("original request"))
            let item = ThreadItem(ItemId("historical-digest-item"), thread, turn, 1, ThreadItemContent.SystemNote("Host continuation"),
                ItemProvenance("continuation_history", runId: Some(run), continuationHistory: Some(history)))
            let continuation = AgentThreadSnapshot(ThreadRecord(thread, 1, "workspace", ThreadStatus.Open, 2), [], [item])
            let writer = OwnedContextPrefixDigest173d(thread, 1, { bytes => payer.ensureRetainedPeak(8388608 + bytes) })
            writer.consumeItem173d(item); @Expect(writer.finish173d(), contextSourceDigest(continuation, 1))
        } finally { payer.close() }
    }
    @TestCase
    func actualCoreCanonicalCheckpointForkAndReopenMatchEveryOriginalSeedCodecByte173d(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        // Prepay the FULL legacy snapshot/container/codec oracle before its
        // copies, but only after the unrelated genuine Core history completes.
        let oracle = try {
            coreCompletedCheckpoint173d(f)
            reserveNativeControlMetadata(8388608)
        } catch (error: Exception) { f.close(); throw error }
        try {
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM pragma_table_info('runs') WHERE name='continuation'"), 0)
            let before = completedForkExecutionCount173d(f.database)
            let original = SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            let target = SessionId("genuine-fork173d")
            let expected = completedThreadCloneSnapshot(ThreadId(target.value), f.root, original)
            let savedBefore = f.database.query("SELECT payload FROM context_checkpoints WHERE thread_id=?",
                [SqlParameter.Text(f.session.value)])
            @Expect(savedBefore.size, 1)
            @Expect(f.product.forkSession(f.session, target).isOk())
            let actual = SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
            fullOriginalSeedOracle173d(f.database, expected, actual)
            let saved = f.database.query("SELECT covers_through_item_ordinal,payload,source_digest FROM context_checkpoints WHERE thread_id=?",
                [SqlParameter.Text(target.value)])
            @Expect(saved.size, 1)
            let old = decodeStoredValue(savedBefore[0].required(0)); let copied = decodeStoredValue(saved[0].required(1))
            for (field in ["structured_summary", "active_goal", "durable_notes", "artifact_references"]) {
                @Expect(encodeStoredValue(copied.field(field).getOrThrow()), encodeStoredValue(old.field(field).getOrThrow())) }
            @Expect(encodeStoredValue(copied.field("active_state").getOrThrow()), encodeStoredValue(objectValue([])))
            @Expect(saved[0].required(2), contextSourceDigest(expected, Int64.parse(saved[0].required(0))))
            expectCompletedForkCounts173d(f.database, before)
            @Expect(f.product.close().isOk())
            let reopened = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: f.root,
                settingsRoot: f.root + "/settings", stateRoot: f.root + "/state", fixture: true, asyncEnabled: false)))
            try {
                let loaded = SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
                fullOriginalSeedOracle173d(f.database, expected, loaded)
                let again = SessionId("genuine-fork-again173d")
                @Expect(reopened.forkSession(target, again).isOk())
                fullOriginalSeedOracle173d(f.database, completedThreadCloneSnapshot(ThreadId(again.value), f.root, loaded),
                    SqliteThreadCommitSink(f.database).loadThread(ThreadId(again.value)))
                expectCompletedForkCounts173d(f.database, before)
            } finally { let _ = reopened.close() }
        } finally { oracle.close(); f.close() }
    }
    @TestCase
    func actualCheckpointInsertTriggerCannotRewriteCompletedRunOrItemAndErrorStaysOwned173d(): Unit {
        for (change in ["run", "item"]) {
            let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
            let target = SessionId("trigger-fork173d")
            let session = f.product.applicationSession(sessionId: Some(f.session))
            let capture = CompletedForkErrorCapture173d()
            let oracle = try {
                coreCompletedCheckpoint173d(f)
                reserveNativeControlMetadata(4194304)
            } catch (error: Exception) { f.close(); throw error }
            var marker: ?AgentError = None<AgentError>
            try {
                let before = completedForkExecutionCount173d(f.database)
                let replacement = if (change == "run") { encodeStoredValue(objectValue([ValueField("forged", boolValue(true))])) }
                    else { encodeStoredThreadContent(ThreadItemContent.UserMessage([ThreadMessagePart.Text("changed historical user")])) }
                let update = if (change == "run") { "UPDATE runs SET budget=" + sqliteText(replacement) +
                    " WHERE thread_id='trigger-fork173d';" }
                    else { "UPDATE items SET payload=" + sqliteText(replacement) +
                        " WHERE thread_id='trigger-fork173d' AND ordinal=1;" }
                f.database.execute("CREATE TRIGGER exactForkTrigger173d AFTER INSERT ON context_checkpoints " +
                    "WHEN NEW.thread_id='trigger-fork173d' BEGIN " + update + " END")
                let result = f.product.forkSession(f.session, target)
                @Expect(result.isError()); marker = Some(result.error().getOrThrow())
                @Expect(session.hasOwnedCheckpointFailure113(marker.getOrThrow()))
                @Expect(!session.admitOwnedCheckpointFailure113(marker.getOrThrow(), { value =>
                    let actual = match (value) { case OwnedAgentRunResult113.Pending(actual) => actual
                        case _ => throw IllegalStateException("fork must not fabricate a canonical Run failure") }
                    match (capture.value) { case Some(old) => @Expect(refEq(old, actual)); case None => capture.value = Some(actual) }
                    @Expect(actual.withError({ error, _ =>
                        @Expect(error.kind, AgentErrorKind.RecoveryRequired)
                        @Expect(error.code, "context.checkpoint_commit_failed")
                        @Expect(error.message.contains("changed"))
                        @Expect(!error.retryable && !error.fallbackAllowed)
                        @Expect(error.fields.size, 0)
                        @Expect(error.attemptFailure.isNone() && error.observation.isNone())
                        @Expect(actual.acknowledgeAfterConsumption().isError())
                    }).isOk())
                    false }))
                @Expect(!capture.value.getOrThrow().isAcknowledged())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='trigger-fork173d'"), 0)
                expectCompletedForkCounts173d(f.database, before)
                @Expect(session.admitOwnedCheckpointFailure113(marker.getOrThrow(), { value =>
                    let actual = match (value) { case OwnedAgentRunResult113.Pending(actual) => actual
                        case _ => throw IllegalStateException("fork has no new canonical Run") }
                    @Expect(refEq(actual, capture.value.getOrThrow())); true }))
                @Expect(capture.value.getOrThrow().acknowledgeAfterConsumption().isOk())
                capture.value = None<OwnedFailureDataConsumer113>
                session.collectOwnedCheckpointFailure113()
                @Expect(!session.hasOwnedCheckpointFailure113(marker.getOrThrow()))
            } finally {
                match (capture.value) { case Some(actual) => let _ = actual.acknowledgeAfterConsumption(); case None => () }
                capture.value = None<OwnedFailureDataConsumer113>
                session.collectOwnedCheckpointFailure113(); oracle.close(); f.close()
            }
        }
    }
    @TestCase
    func missingAndDisabledSelectedPackageCannotUseOldRawForkFallback173d(): Unit {
        for (installed in [false, true]) {
            let f = CompactionPolicyFixture(install: installed)
            try {
                if (installed) {
                    @Expect(f.product.setPluginEnabled("axyndra:compaction", false).isOk()) }
                let before = completedForkExecutionCount173d(f.database)
                @Expect(f.product.forkSession(f.session, SessionId("blocked-fork173d")).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='blocked-fork173d'"), 0)
                expectCompletedForkCounts173d(f.database, before)
            } finally { f.close() }
        }
    }
    @TestCase
    func actualDirectCompletedInitiatorKeepsOriginalExplicitForkRejectionWithoutAuthority173d(): Unit {
        // Preserve the historical named ID, but correct its false premise:
        // invokeLocalTool's real ordinary Direct entry writes UserMessage.
        // Its original complete seed codec must succeed without any new
        // completed-initiator DATA tag or altered execution authority.
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        let oracle = reserveNativeControlMetadata(8388608)
        try {
            let call = lifecycleTestRequire(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint",
                objectValue([ValueField("goal", textValue("Original Direct seed oracle"))])))
            try { @Expect(!call.isError) } finally { call.releasePayload() }
            let original = SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            @Expect(original.items[0].kind, ItemKind.UserMessage)
            let before = completedForkExecutionCount173d(f.database)
            let target = SessionId("new-direct-fork173d")
            let expected = completedThreadCloneSnapshot(ThreadId(target.value), f.root, original)
            @Expect(f.product.forkSession(f.session, target).isOk())
            fullOriginalSeedOracle173d(f.database, expected,
                SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value)))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='new-direct-fork173d' "+
                "AND kind='completed_initiator_history173e_v1'"), 0)
            expectCompletedForkCounts173d(f.database, before)
            @Expect(f.product.close().isOk())
            let reopened = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: f.root,
                settingsRoot: f.root + "/settings", stateRoot: f.root + "/state", fixture: true, asyncEnabled: false)))
            try {
                let loaded = SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
                fullOriginalSeedOracle173d(f.database, expected, loaded)
                let again = SessionId("ordinary-direct-fork-again173e")
                @Expect(reopened.forkSession(target, again).isOk())
                fullOriginalSeedOracle173d(f.database, completedThreadCloneSnapshot(ThreadId(again.value), f.root, loaded),
                    SqliteThreadCommitSink(f.database).loadThread(ThreadId(again.value)))
                expectCompletedForkCounts173d(f.database, before)
            } finally { let _ = reopened.close() }
        } finally { oracle.close(); f.close() }
    }
}
