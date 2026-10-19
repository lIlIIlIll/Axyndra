package persistence_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

private class OwnedEventRunEstimator <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
private class OwnedEventRunFixture {
    let directory: String
    let database: SqliteDatabase
    let repository: SqliteRunRepository
    let run = RunId("owned-event-run")
    init() {
        let path = Directory.createTemp("/tmp").toString(); let db = SqliteDatabase(path + "/event.sqlite")
        let sink = SqliteThreadCommitSink(db); let thread = ThreadId("owned-event-thread")
        let coordinator = ThreadCoordinator(sink.createThread(thread, path), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("event", OwnedEventRunEstimator()), { => 10 })
        let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system")
        runtime.startTurn(SemanticTurnId("owned-event-turn"), RunId("owned-event-run"), ItemId("owned-event-user"),
            ThreadItemContent.UserMessage(textMessageParts("observe full lifecycle event")), lane, InvocationContextProjection()).value().getOrThrow()
        this.directory = path; this.database = db
        this.repository = SqliteRunRepository(db, ownedEventSpoolRoot: Some(path))
    }
    func close(): Unit { database.close(); remove(directory, recursive: true) }
}

// These are actual allocation/data-IO controls, not installed Kernel Parent
// Root admission or a replacement Source/Receipt/Known acceptance fixture.
private func ownedSpoolTestEvent(pool: LogicalJsonOwnerBudget, bytes: Int64): OwnedAgentEvent {
    let payment = pool.acquire(1); payment.ensureRetainedPeak(bytes * 8 + 1048576)
    let root = OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("owned-event-data"), ThreadId("owned-event-thread"),
        SemanticTurnId("owned-event-turn"), 2,
        ThreadItemContent.SystemNote(String.fromUtf8(Array<Byte>(bytes, repeat: 0)) + "雪🙂\n"),
        ItemProvenance("system")), payment)
    let alias = root.retainAliasCustody().value().getOrThrow()
    let event = OwnedAgentEvent(EventMeta(1, TraceId("owned-event-trace"), RunId("owned-event-run"), occurredAtMillis: 7),
        { item => match (item.content) {
            case ThreadItemContent.SystemNote(value) => AgentEventPayload.Extension(AgentEventKind.Tool,
                objectValue([ValueField("code", textValue("tool.execution_completed")), ValueField("output", textValue(value))]))
            case _ => throw IllegalStateException("full event data source absent") } }, alias)
    root.closeAfterConsumption().value().getOrThrow(); event
}
private func ownedSpoolOracleDigest(bytes: Int64): String {
    let expected = SHA256()
    expected.write(("{\"format_version\":1,\"sequence\":1,\"run_id\":\"owned-event-run\",\"kind\":\"tool\"," +
        "\"timestamp_ms\":7,\"trace_id\":\"owned-event-trace\",\"turn_id\":null,\"request_id\":null," +
        "\"tool_batch_id\":null,\"tool_call_id\":null,\"operation_id\":null,\"payload_type\":\"extension\"," +
        "\"detail\":{\"code\":\"tool.execution_completed\",\"output\":\"").toArray())
    let block = Array<Byte>(65536 * 6, { index => "\\u0000"[index % 6] })
    for (_ in 0..bytes / 65536) { expected.write(block) }
    expected.write("雪🙂\\n\"}}".toArray()); logicalJsonEncodeHex(expected.finish())
}
private func ownedSpoolHexDigit(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'A' && value <= b'F') { value - b'A' + 10 }
    else { throw IllegalStateException("actual SQLite hex readback invalid") }
}
// Read the SAME committed SQLite TEXT cell through a checked read-only
// native incremental cursor. SQL CAST/substr on the full 48MiB cell once per
//16KiB projection repeatedly copies the whole value; this independent oracle
// reads every original byte once, including Unicode boundaries and suffix.
// The real existing readback allocation remains held throughout this frame.
@When[os == "Linux"]
foreign func sqlite3_open_v2(filename: CString, output: CPointer<CPointer<Unit>>, flags: Int32, vfs: CString): Int32
@When[os == "Linux"]
foreign func sqlite3_close_v2(database: CPointer<Unit>): Int32
@When[os == "Linux"]
foreign func sqlite3_blob_open(database: CPointer<Unit>, databaseName: CString, tableName: CString,
    columnName: CString, row: Int64, write: Int32, output: CPointer<CPointer<Unit>>): Int32
@When[os == "Linux"]
foreign func sqlite3_blob_bytes(blob: CPointer<Unit>): Int32
@When[os == "Linux"]
foreign func sqlite3_blob_read(blob: CPointer<Unit>, buffer: CPointer<Byte>, bytes: Int32, offset: Int32): Int32
@When[os == "Linux"]
foreign func sqlite3_blob_close(blob: CPointer<Unit>): Int32

@When[os == "Linux"]
private func ownedSpoolDatabaseDigest(db: SqliteDatabase, directory: String): String {
    let rows = db.query("SELECT rowid FROM app_run_events WHERE run_id='owned-event-run'")
    @Expect(rows.size, 1)
    let row = Int64.parse(rows[0].required(0))
    let bytes = db.scalarInt("SELECT length(CAST(payload AS BLOB)) FROM app_run_events WHERE run_id='owned-event-run'")
    let hash = SHA256()
    let buffer = Array<Byte>(16384, repeat: 0)
    let path = unsafe { LibC.mallocCString(directory + "/event.sqlite") }
    let databaseName = unsafe { LibC.mallocCString("main") }
    let tableName = unsafe { LibC.mallocCString("app_run_events") }
    let columnName = unsafe { LibC.mallocCString("payload") }
    let output = unsafe { LibC.malloc<CPointer<Unit>>() }
    var database = CPointer<Unit>()
    var blob = CPointer<Unit>()
    var offset: Int64 = 0
    try {
        unsafe {
            if (path.isNull() || databaseName.isNull() || tableName.isNull() || columnName.isNull() || output.isNull()) {
                throw IllegalStateException("actual SQLite readback allocation failed") }
            output.write(CPointer<Unit>())
            let opened = sqlite3_open_v2(path, output, 1, CString(CPointer<UInt8>())) // SQLITE_OPEN_READONLY
            database = output.read()
            if (opened != 0 || database.isNull()) { throw IllegalStateException("same committed SQLite readback open failed") }
            output.write(CPointer<Unit>())
            let selected = sqlite3_blob_open(database, databaseName, tableName, columnName, row, 0, output)
            blob = output.read()
            if (selected != 0 || blob.isNull()) { throw IllegalStateException("same committed Run event cell cursor failed") }
            let actual = Int64(sqlite3_blob_bytes(blob))
            @Expect(actual, bytes)
            if (actual < 1 || actual != bytes) { throw IllegalStateException("complete original event readback extent changed") }
        }
        while (offset < bytes) {
            let count = min(buffer.size, bytes - offset)
            let code = unsafe {
                let raw = acquireArrayRawData(buffer)
                try { sqlite3_blob_read(blob, raw.pointer, Int32(count), Int32(offset)) }
                finally { releaseArrayRawData(raw) }
            }
            if (code != 0) { throw IllegalStateException("complete committed Run event byte read failed") }
            hash.write(buffer[..count]); offset += count
        }
        @Expect(offset, bytes)
        logicalJsonEncodeHex(hash.finish())
    } finally {
        let blobClose = unsafe { if (blob.isNull()) { Int32(0) } else { sqlite3_blob_close(blob) } }
        let databaseClose = unsafe { if (database.isNull()) { Int32(0) } else { sqlite3_close_v2(database) } }
        unsafe { LibC.free(output); LibC.free(columnName); LibC.free(tableName); LibC.free(databaseName); LibC.free(path) }
        if (blobClose != 0 || databaseClose != 0) { throw IllegalStateException("actual readback cursor/database cleanup failed") }
    }
}

@When[os == "Linux"]
@Test
class OwnedRunEventSpoolTests {
    @TestCase
    func CompleteEightMiBNulScalarPersistsOriginalEventAfterActualDomAliasesRetire(): Unit {
        let fixture = OwnedEventRunFixture(); let pool = LogicalJsonOwnerBudget()
        let event = ownedSpoolTestEvent(pool, 8388608)
        let readback = event.deriveRetainedAllocation(1048576).value().getOrThrow()
        let write = fixture.repository.stageOwned(event.fanout().value().getOrThrow()).value().getOrThrow()
        try {
            @Expect(write.appendAfterSourceAliasRetirement().isOk(), false)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 0)
            event.closeAfterEventRetirement().value().getOrThrow()
            @Expect(write.appendAfterSourceAliasRetirement().isOk(), true)
            @Expect(fixture.database.scalarInt("SELECT length(CAST(payload AS BLOB)) FROM app_run_events") > 8388608 * 6, true)
            @Expect(ownedSpoolDatabaseDigest(fixture.database, fixture.directory), ownedSpoolOracleDigest(8388608))
            @Expect(fixture.database.query("SELECT typeof(payload),event_class FROM app_run_events")[0].required(0), "text")
            @Expect(write.closeAfterStorageRetirement().isOk(), true)
            @Expect(pool.usage()[0], 1)
            readback.close(); @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
        } finally { let _ = event.closeAfterEventRetirement(); let _ = write.closeAfterStorageRetirement(); readback.close(); fixture.close() }
    }
    @TestCase
    func UnretiredFanoutAndCallbackReturnCannotAdmitDatabaseMutation(): Unit {
        let fixture = OwnedEventRunFixture(); let pool = LogicalJsonOwnerBudget()
        let event = ownedSpoolTestEvent(pool, 65536); let observer = event.fanout().value().getOrThrow()
        let write = fixture.repository.stageOwned(event.fanout().value().getOrThrow()).value().getOrThrow()
        try {
            @Expect(observer.withEvent(262144, { _ => Result.Ok(()) }).isOk(), true)
            event.closeAfterEventRetirement().value().getOrThrow()
            @Expect(write.appendAfterSourceAliasRetirement().isOk(), false)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 0)
            observer.closeAfterEventRetirement().value().getOrThrow()
            @Expect(write.appendAfterSourceAliasRetirement().isOk(), true)
            @Expect(write.appendAfterSourceAliasRetirement().isOk(), true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 1)
            @Expect(write.closeAfterStorageRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
        } finally { let _ = event.closeAfterEventRetirement(); let _ = observer.closeAfterEventRetirement(); let _ = write.closeAfterStorageRetirement(); fixture.close() }
    }
    @TestCase
    func RealOriginalPoolPressureBlocksBeforeFirstMutationThenSameCompleteSpoolRetries(): Unit {
        let fixture = OwnedEventRunFixture(); let pool = LogicalJsonOwnerBudget()
        let event = ownedSpoolTestEvent(pool, 8388608)
        let write = fixture.repository.stageOwned(event.fanout().value().getOrThrow()).value().getOrThrow()
        event.closeAfterEventRetirement().value().getOrThrow()
        let pressure = [pool.acquire(1), pool.acquire(1)]
        try {
            @Expect(write.appendAfterSourceAliasRetirement().isOk(), false)
            @Expect(write.isAcknowledged(), false)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 0)
            for (owner in pressure) { owner.close() }
            @Expect(write.appendAfterSourceAliasRetirement().isOk(), true)
            @Expect(fixture.database.scalarInt("SELECT length(CAST(payload AS BLOB)) FROM app_run_events") > 8388608 * 6, true)
            @Expect(write.closeAfterStorageRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
        } finally { for (owner in pressure) { owner.close() }; let _ = write.closeAfterStorageRetirement(); fixture.close() }
    }
}

// These additional controls use the original SQLite schema and a local
// default 128 MiB / 32-slot DATA bank. They create no execution permission.
private class PersistenceNumericData204 <: PreparedPlanUtf8Owner204 {
    private let payment: LogicalJsonOwnerReservation
    private var bytes: ?Array<UInt8>
    init(payment: LogicalJsonOwnerReservation, wire: String) {
        this.payment = payment; this.bytes = Some(wire.toArray())
    }
    public prop byteCount: Int64 { get() { bytes.getOrThrow().size } }
    public func byteAt(index: Int64): UInt8 { bytes.getOrThrow()[index] }
    public func deriveCopiedPlanPayment204(invoice: Int64): LogicalJsonOwnerReservation {
        let child = payment.deriveRetainedLease()
        try { child.ensureRetainedPeak(invoice); child }
        catch (error: Exception) { child.close(); throw error }
    }
    func clearBytes204(): Unit { bytes = None<Array<UInt8>> }
}

private func persistenceAuditEvent204(run: RunId, full: Bool, sequence: Int64): AgentEvent {
    AgentEvent(EventMeta(sequence, TraceId("audit-204-雪"), run, occurredAtMillis: 7,
        turnId: if (full) { Some(TurnId("turn-204")) } else { None<TurnId> },
        requestId: if (full) { Some(RequestId("request-204")) } else { None<RequestId> },
        toolBatchId: if (full) { Some(ToolBatchId("batch-204")) } else { None<ToolBatchId> },
        toolCallId: if (full) { Some(ToolCallId("call-204")) } else { None<ToolCallId> },
        operationId: if (full) { Some(OperationId("operation-204")) } else { None<OperationId> }),
        AgentEventPayload.Audit("copy-204", objectValue([
            ValueField("text", textValue("quoted\" newline\n雪\u{0}🙂")),
            ValueField("count", integerValue(17)), ValueField("flag", boolValue(true)),
            ValueField("absent", nullValue())])))
}

private func persistenceAuditPair204(fixture: OwnedEventRunFixture,
    payment: LogicalJsonOwnerReservation, full: Bool, sequence: Int64): Bool {
    let repository = SqliteAuditRepository(fixture.database)
    let run = if (full) { fixture.run } else { RunId("absent-audit-run-204") }
    let event = persistenceAuditEvent204(run, full, sequence)
    let golden = encodeEvent(event)
    let complete = decodeAgentValue(golden).value().getOrThrow()
    let wire = encodeStoredValue(objectValue([ValueField("run_id", textValue(run.value)),
        ValueField("detail", event.detail), ValueField("event204", complete)]))
    let source = PersistenceNumericData204(payment, wire)
    let before = payment.retainedCustodyUsage113()
    let low = agentUtcMillis()
    if (!repository.appendCatalogAuditOwnedUtf8204(source).isOk()) { return false }
    let high = agentUtcMillis()
    let after = payment.retainedCustodyUsage113()
    // Exact copied child returned; the caller's original event and wire remain paid.
    if (before[0] != after[0] || before[2] != after[2]) { return false }
    source.clearBytes204()
    if (!repository.append(event).isOk()) { return false }
    let rows = fixture.database.query("SELECT thread_id,run_id,operation_id,kind,payload,created_at_millis " +
        "FROM audit_events WHERE kind='tool_audit' ORDER BY id DESC LIMIT 2")
    if (rows.size != 2 || rows[0].required(4) != golden || rows[1].required(4) != golden ||
        rows[1].required(1) != run.value || rows[1][2].isSome() || rows[1].required(3) != "tool_audit") { return false }
    if (full) {
        if (rows[1].required(0) != "owned-event-thread") { return false }
    } else if (rows[1][0].isSome()) { return false }
    let actualTime = Int64.parse(rows[1].required(5))
    if (actualTime < low || actualTime > high || actualTime == 7) { return false }
    let decoded = decodeAgentValue(rows[1].required(4)).value().getOrThrow()
    if (decoded.fields.size != 13 || decoded.field("format_version").getOrThrow().asNumberText() != "1" ||
        decoded.field("sequence").getOrThrow().asNumberText() != sequence.toString() ||
        decoded.field("trace_id").getOrThrow().text != "audit-204-雪" ||
        decoded.field("timestamp_ms").getOrThrow().asNumberText() != "7" ||
        decoded.field("kind").getOrThrow().text != "audit" ||
        decoded.field("payload_type").getOrThrow().text != "audit" ||
        encodeAgentValue(decoded.field("detail").getOrThrow()) != encodeAgentValue(event.detail)) { return false }
    for (name in ["turn_id", "request_id", "tool_batch_id", "tool_call_id", "operation_id"]) {
        if (full) {
            if (decoded.field(name).getOrThrow().unifiedKind != ValueKind.Text) { return false }
        } else if (decoded.field(name).getOrThrow().unifiedKind != ValueKind.Null) { return false }
    }
    true
}

private func persistenceAuditSqlFrame204(payment: LogicalJsonOwnerReservation): Bool {
    let fixture = OwnedEventRunFixture()
    try {
        let warm = payment.deriveRetainedLease(); warm.close()
        for (index in 0..32) {
            if (!persistenceAuditPair204(fixture, payment, true, index + 1) ||
                !persistenceAuditPair204(fixture, payment, false, index + 1)) { return false }
        }
        fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_audit'") == 128
    } finally { fixture.close() }
}

private func persistenceGrantWire204(scope: ApprovalGrantScope): String {
    encodeStoredValue(objectValue([
        ValueField("capability", textValue(scope.capability)), ValueField("path_prefix", textValue(scope.pathPrefix)),
        ValueField("tool_name", textValue(scope.toolName)), ValueField("host", textValue(scope.host)),
        ValueField("session_only", boolValue(scope.sessionOnly))]))
}

private func persistenceGrantAllowsPair204(repository: SqlitePermissionRepository, payment: LogicalJsonOwnerReservation,
    session: SessionId, scope: ApprovalGrantScope, expected: Bool): Bool {
    let source = PersistenceNumericData204(payment, persistenceGrantWire204(scope))
    let before = payment.retainedCustodyUsage113()
    let actual = repository.allowsCatalogGrantOwnedUtf8204(session, source).value().getOrThrow()
    let after = payment.retainedCustodyUsage113()
    source.clearBytes204()
    actual == expected && repository.allows(session, scope).value().getOrThrow() == expected &&
        before[0] == after[0] && before[2] == after[2]
}

private func persistenceGrantSqlFrame204(payment: LogicalJsonOwnerReservation): Bool {
    let directory = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(directory + "/grants.sqlite")
    try {
        let repository = SqlitePermissionRepository(database)
        let session = SessionId("permission-session-204")
        let scope = ApprovalGrantScope("workspace.read", pathPrefix: "/tmp/root", toolName: "fixture.read",
            host: "example.invalid", sessionOnly: false)
        let warm = payment.deriveRetainedLease(); warm.close()
        if (!persistenceGrantAllowsPair204(repository, payment, session, scope, false)) { return false }
        let source = PersistenceNumericData204(payment, persistenceGrantWire204(scope))
        let before = payment.retainedCustodyUsage113()
        let low = agentUtcMillis()
        if (!repository.grantCatalogGrantOwnedUtf8204(session, source).isOk()) { return false }
        let high = agentUtcMillis()
        let after = payment.retainedCustodyUsage113()
        source.clearBytes204()
        if (before[0] != after[0] || before[2] != after[2] || !repository.grant(session, scope).isOk()) { return false }
        let rows = database.query("SELECT payload,created_at_millis FROM session_permission_grants")
        if (rows.size != 1) { return false }
        let expected = encodeAgentValue(objectValue([
            ValueField("capability", textValue(scope.capability)), ValueField("path_prefix", textValue(scope.pathPrefix)),
            ValueField("tool_name", textValue(scope.toolName)), ValueField("host", textValue(scope.host)),
            ValueField("session_only", boolValue(true))]))
        let timestamp = Int64.parse(rows[0].required(1))
        if (rows[0].required(0) != expected || timestamp < low || timestamp > high) { return false }
        // A stored payload much larger than the requested scope must be paid
        // from its actual same-TX extent, not guessed from that small request.
        let large = objectValue([ValueField("capability", textValue("other.capability")),
            ValueField("padding", textValue(String.fromUtf8(Array<UInt8>(65536, repeat: b'x')) + "雪"))])
        let largeText = encodeAgentValue(large)
        database.execute("INSERT INTO session_permission_grants(thread_id,digest,payload,created_at_millis) VALUES(" +
            sqliteText(session.value) + ",'large-204'," + sqliteText(largeText) + ",0)")
        for (_ in 0..32) {
            if (!persistenceGrantAllowsPair204(repository, payment, session, scope, true) ||
                !persistenceGrantAllowsPair204(repository, payment, SessionId("other-session-204"), scope, false)) { return false }
        }
        let requests = [
            ApprovalGrantScope("workspace.read", pathPrefix: "/tmp/root/child", toolName: "fixture.read", host: "example.invalid"),
            ApprovalGrantScope("workspace.read", pathPrefix: "/tmp/root-other", toolName: "fixture.read", host: "example.invalid"),
            ApprovalGrantScope("workspace.write", pathPrefix: "/tmp/root", toolName: "fixture.read", host: "example.invalid"),
            ApprovalGrantScope("workspace.read", pathPrefix: "/tmp/root", toolName: "different", host: "example.invalid"),
            ApprovalGrantScope("workspace.read", pathPrefix: "/tmp/root", toolName: "fixture.read", host: "different.invalid")]
        for (index in 0..requests.size) {
            if (!persistenceGrantAllowsPair204(repository, payment, session, requests[index], index == 0)) { return false }
        }
        true
    } finally { database.close(); remove(directory, recursive: true) }
}

@When[os == "Linux"]
@Test
class CatalogPersistenceCopiedData204Tests {
    @TestCase
    func CompleteAuditSqlMatchesOriginalThirteenFieldsThreadNullAndUtcAfterCopiedFrameReturn(): Unit {
        let bank = LogicalJsonOwnerBudget()
        let payment = bank.acquire(1); payment.ensureRetainedPeak(2097152)
        let valid = persistenceAuditSqlFrame204(payment)
        payment.close()
        @Expect(valid, true)
        @Expect(bank.usage()[0], 0)
        @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func CompleteGrantSqlPreservesSessionScopeStoredPayloadAndReturnsEveryCopiedFrame(): Unit {
        let bank = LogicalJsonOwnerBudget()
        let payment = bank.acquire(1); payment.ensureRetainedPeak(2097152)
        let valid = persistenceGrantSqlFrame204(payment)
        payment.close()
        @Expect(valid, true)
        @Expect(bank.usage()[0], 0)
        @Expect(bank.usage()[1], 0)
    }
}
