package agent_store

import agent_domain.*
import agent_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Storage primitive fixtures only. These whole original canonical codecs do
// not create a Source/approval/Receipt from the fixture's IDs or row data.
private func ownedReadbackSeedCell(db: SqliteDatabase, ordinal: Int64, owner: LogicalJsonOwnerReservation): Unit {
    owner.ensureRetainedPeak(67108864)
    let text = String.fromUtf8(Array<Byte>(3145728, repeat: b'r')) + "\u{0}雪🙂"
    let content = if (ordinal == 1) { ThreadItemContent.UserMessage(textMessageParts("whole ordered seed")) }
        else { ThreadItemContent.SystemNote(text + ordinal.toString()) }
    let payload = encodeStoredThreadContent(content)
    let provenance = encodeStoredProvenance(ItemProvenance("system"))
    db.execute("INSERT INTO items (id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (?,?,?,?,?,?,?,?)",
        [SqlParameter.Text("owned-row-" + ordinal.toString()), SqlParameter.Text("owned-readback-thread"),
            SqlParameter.Text("owned-readback-turn"), SqlParameter.Int64Value(ordinal),
            SqlParameter.Text(if (ordinal == 1) { "user_message" } else { "system_note" }),
            SqlParameter.Text(payload), SqlParameter.Text(provenance), SqlParameter.Int64Value(ordinal)])
}
class OwnedCanonicalReadbackFixture {
    let path: String
    let db: SqliteDatabase
    let pool = LogicalJsonOwnerBudget()
    let thread = ThreadId("owned-readback-thread")
    private var readback: ?SqliteOwnedCanonicalThreadReadback = None
    prop reader: SqliteOwnedCanonicalThreadReadback { get() { readback.getOrThrow() } }
    let count: Int64
    init(count: Int64) {
        path = Directory.createTemp("/tmp").toString()
        db = SqliteDatabase(path + "/whole-readback.sqlite")
        let sink = SqliteThreadCommitSink(db); let _ = sink.createThread(thread, "workspace")
        db.execute("INSERT INTO turns (id,thread_id,ordinal,state,user_item_id,active_run_id) VALUES (?,?,1,'completed',?,NULL)",
            [SqlParameter.Text("owned-readback-turn"), SqlParameter.Text(thread.value), SqlParameter.Text("owned-row-1")])
        this.count = count
        for (ordinal in 1..=count) {
            let paid = pool.acquire(1)
            try { ownedReadbackSeedCell(db, ordinal, paid) }
            finally { paid.close() } // the complete seed String/SQL frame ended
        }
        db.execute("UPDATE threads SET revision=1,next_item_ordinal=? WHERE id=?",
            [SqlParameter.Int64Value(count + 1), SqlParameter.Text(thread.value)])
        readback = Some(SqliteOwnedCanonicalThreadReadback(db, { bytes => pool.acquire(bytes) }))
    }
    func close(): Unit {
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
        db.close(); remove(path, recursive: true)
    }
}
class OwnedReadbackVisitCapture {
    var count: Int64 = 0
    var alias: ?OwnedCanonicalThreadItemAliasCustody = None
    func verify(item: ThreadItem): Result<Unit> {
        count++
        @Expect(item.ordinal, count)
        @Expect(item.id.value, "owned-row-" + count.toString())
        match (item.content) {
            case ThreadItemContent.SystemNote(text) =>
                @Expect(text.size > 3145728, true)
                @Expect(text.endsWith("\u{0}雪🙂" + count.toString()), true)
            case ThreadItemContent.UserMessage(parts) => @Expect(parts.size, 1)
            case _ => return Result.Err(AgentError(AgentErrorKind.Internal, "fixture.changed", "full original row changed"))
        }
        Result.Ok(())
    }
}

private func ownedReadbackOriginalDigest(fixture: OwnedCanonicalReadbackFixture): String {
    let paid = fixture.pool.acquire(1)
    try { paid.ensureRetainedPeak(67108864); ownedReadbackOriginalDigestFrame(fixture) }
    finally { paid.close() }
}
private func ownedReadbackOriginalDigestFrame(fixture: OwnedCanonicalReadbackFixture): String {
    let snapshot = SqliteThreadCommitSink(fixture.db).loadThread(fixture.thread)
    contextSourceDigest(snapshot, fixture.count)
}

@Test
class OwnedCanonicalThreadReadbackTests {
    @TestCase
    func streamedFullOriginalContextDigestMatchesWholeLegacyNULUnicodeOracle(): Unit {
        let fixture = OwnedCanonicalReadbackFixture(2)
        try {
            let original = ownedReadbackOriginalDigest(fixture)
            let thread = ThreadRecord(fixture.thread, 1, "workspace", ThreadStatus.Open, 3)
            let streamed = ownedContextSourceDigest(thread, fixture.reader, 2, { => Result<Unit>.Ok(()) })
            @Expect(streamed.isOk(), true)
            @Expect(streamed.value().getOrThrow(), original)
        } finally { fixture.close() }
    }
    @TestCase
    func completeOrderedCorpusExceedsPoolWhileEachOriginalCellIsReadWhole(): Unit {
        let fixture = OwnedCanonicalReadbackFixture(45)
        try {
            // 44 independent >3MiB body cells exceed 128MiB as a corpus.
            // No corpus DOM or newest-N cut is constructed by actual visit.
            let seen = OwnedReadbackVisitCapture()
            @Expect(fixture.reader.visit(fixture.thread, 1, 0, { => Result<Unit>.Ok(()) },
                { item, _ => seen.verify(item) }).isOk(), true)
            @Expect(seen.count, 45)
            @Expect(fixture.pool.usage()[0], 0); @Expect(fixture.pool.usage()[1], 0)
        } finally { fixture.close() }
    }
    @TestCase
    func originalPoolPressureRejectsBeforeConsumerAndWholeCellWorksAfterOwnersRetire(): Unit {
        let fixture = OwnedCanonicalReadbackFixture(2)
        try {
            let pressure = [fixture.pool.acquire(1), fixture.pool.acquire(1), fixture.pool.acquire(1),
                fixture.pool.acquire(1), fixture.pool.acquire(1), fixture.pool.acquire(1), fixture.pool.acquire(1)]
            let seen = OwnedReadbackVisitCapture()
            @Expect(fixture.reader.visitItem(fixture.thread, 1, ItemId("owned-row-2"),
                { => Result<Unit>.Ok(()) }, { _, _ => seen.count++; Result.Ok(()) }).isOk(), false)
            @Expect(seen.count, 0)
            for (paid in pressure) { paid.close() }
            @Expect(fixture.reader.visitItem(fixture.thread, 1, ItemId("owned-row-2"),
                { => Result<Unit>.Ok(()) }, { item, _ =>
                    @Expect(item.ordinal, 2)
                    match (item.content) { case ThreadItemContent.SystemNote(text) =>
                        @Expect(text.endsWith("\u{0}雪🙂2"), true); case _ => @Expect(false, true) }
                    Result.Ok(()) }).isOk(), true)
        } finally { fixture.close() }
    }
    @TestCase
    func retainedActualAliasPaysAfterQueryRootEndsAndStaleOrMissingRowNeverPublishes(): Unit {
        let fixture = OwnedCanonicalReadbackFixture(2)
        try {
            let seen = OwnedReadbackVisitCapture()
            @Expect(fixture.reader.visitItem(fixture.thread, 1, ItemId("owned-row-2"),
                { => Result<Unit>.Ok(()) }, { _, root =>
                    match (root.retainAliasCustody()) { case Result.Err(error) => Result.Err(error)
                        case Result.Ok(alias) => seen.alias = Some(alias); Result.Ok(()) } }).isOk(), true)
            @Expect(fixture.pool.usage()[0], 1); @Expect(fixture.pool.usage()[1] > 16777216, true)
            let alias = seen.alias.getOrThrow(); seen.alias = None
            let witness = alias.retirementWitness().value().getOrThrow()
            @Expect(witness.isItemRetired(), false)
            @Expect(alias.withItem({ item => @Expect(item.ordinal, 2); Result.Ok(()) }).isOk(), true)
            @Expect(alias.closeAfterAliasRetirement().isOk(), true)
            @Expect(witness.isItemRetired(), true)
            @Expect(fixture.reader.visit(fixture.thread, 2, 0, { => Result<Unit>.Ok(()) },
                { _, _ => seen.count++; Result.Ok(()) }).isOk(), false)
            @Expect(fixture.reader.visitItem(fixture.thread, 1, ItemId("missing-row"),
                { => Result<Unit>.Ok(()) }, { _, _ => seen.count++; Result.Ok(()) }).isOk(), false)
            @Expect(seen.count, 0)
        } finally { fixture.close() }
    }
}
