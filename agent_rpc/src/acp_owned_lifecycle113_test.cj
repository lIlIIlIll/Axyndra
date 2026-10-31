package agent_rpc

import tool_runtime.ApprovalMode
import agent_domain.*
import agent_product.*
import agent_runtime.*
import agent_store.*
import logical_json_payload.LogicalJsonOwnerReservation as AcpOraclePayment113
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import tool_runtime.*
import yjson.JsonNode
import yjson.*
import yjson_support.*

// One exact original Native reservation pays the fixture BEFORE its classes,
// callback captures, byte/DOM copies, SQLite queries and actual Future cells.
// No Tool Source/Operation/Receipt is created by this fixture. Product's real
// Core/Pipeline/SQLite alone creates and commits the canonical result.
private class AcpActualOutput113 <: AcpOwnedResponseOutput113 & OwnedRpcFailureOutput113 {
    private let metadata: AcpOraclePayment113
    private var peak: Int64 = 33554432
    let frames = ArrayList<AgentValue>()
    var writes: Int64 = 0
    var failureWrites: Int64 = 0
    var closeWrites: Int64 = 0
    var lastClosePrefix113 = ""
    init(metadata: AcpOraclePayment113) { this.metadata = metadata }
    private func retainDecoded113(raw: String): Unit {
        peak = acpOwnedAdd113(peak, acpOwnedInputInvoice113(raw))
        metadata.ensureRetainedPeak(peak)
        let prefix = "error[acp.server_shutdown_failed]: "
        if (raw.startsWith(prefix)) {
            var boundary = prefix.size
            while (boundary < raw.size && raw[boundary] != 10u8) { boundary++ }
            if (boundary == raw.size) { throw IllegalStateException("actual ACP close prefix has no original newline boundary") }
            lastClosePrefix113 = raw[0..boundary+1]
            closeWrites++; frames.add(decodeAgentValue(raw[boundary+1..]).value().getOrThrow())
        } else { frames.add(decodeAgentValue(raw).value().getOrThrow()) }
    }
    public func writeAcpResponse113(value: AcpOwnedResponse113): OwnedFailureDataOutcome113<Unit> {
        writes++
        let answer = value.withResponse113({ raw =>
            @Expect(value.acknowledgeAfterWriteHelperReturn113().isError())
            retainDecoded113(raw); Result<Unit>.Ok(()) })
        match (answer) {
            case OwnedFailureDataOutcome113.Failure(_) => answer
            case OwnedFailureDataOutcome113.Value(_) =>
                value.acknowledgeAfterWriteHelperReturn113().value().getOrThrow()
                OwnedFailureDataOutcome113<Unit>.Value(()) }
    }
    public func writeFailureFrame113(value: OwnedFailureRunPublication113,
        render: (AgentError, (Int64)->Result<Unit>)->Result<String>): OwnedFailureDataOutcome113<Unit> {
        writeFailure113(RpcFailureAlias113.Publication(value), render)
    }
    public func writeFailureFrame113(value: OwnedFailureDataConsumer113,
        render: (AgentError, (Int64)->Result<Unit>)->Result<String>): OwnedFailureDataOutcome113<Unit> {
        writeFailure113(RpcFailureAlias113.Data(value), render)
    }
    private func renderWholeHelper113(value: RpcFailureAlias113,
        render: (AgentError, (Int64)->Result<Unit>)->Result<String>): Result<Unit> {
        value.withError({ error, fund =>
            @Expect(value.acknowledge().isError())
            let raw = render(error, fund).value().getOrThrow()
            retainDecoded113(raw)
            Result<Unit>.Ok(()) })
    }
    private func writeFailure113(value: RpcFailureAlias113,
        render: (AgentError, (Int64)->Result<Unit>)->Result<String>): OwnedFailureDataOutcome113<Unit> {
        failureWrites++
        let answer = renderWholeHelper113(value, render)
        match (answer) {
            case Result.Err(error) => OwnedFailureDataOutcome113<Unit>.Failure(value.capture(error))
            case Result.Ok(_) =>
                // Only this exact output child's full renderer/loan helper
                // returned. The real queue/Event/caller inputs remain distinct.
                value.acknowledge().value().getOrThrow()
                OwnedFailureDataOutcome113<Unit>.Value(()) }
    }
    func response113(id: Int64): AgentValue {
        for (value in frames) {
            match (value.field("id")) {
                case Some(actual) => if (actual.unifiedKind == ValueKind.Number &&
                    Int64.parse(actual.asNumberText()) == id) { return value }
                case None => () } }
        throw IllegalStateException("actual ACP output omitted its original request identity")
    }
    func responseCount113(id: Int64): Int64 {
        var count: Int64 = 0
        for (value in frames) {
            match (value.field("id")) {
                case Some(actual) => if (actual.unifiedKind == ValueKind.Number &&
                    Int64.parse(actual.asNumberText()) == id) { count++ }
                case None => () } }
        count
    }
}

private class AcpActualCanonicalObserver113 <: ToolExecutor & PreparedPostCanonicalToolObserver & PaidPreparedPostCanonicalToolObserver113 {
    private let metadata: AcpOraclePayment113
    private let database: SqliteDatabase
    var executed: Int64 = 0
    var observed: Int64 = 0
    var oldCalls: Int64 = 0
    var receipt = ""
    private var digest = ""
    let canonicalEntered113 = AtomicBool(false)
    let canonicalRelease113 = AtomicBool(false)
    private let pausedObserver113: Bool
    private let failObserver113: Bool
    init(metadata: AcpOraclePayment113, database: SqliteDatabase,
        pausedObserver113!: Bool = false, failObserver113!: Bool = true) {
        this.metadata = metadata; this.database = database
        this.pausedObserver113 = pausedObserver113; this.failObserver113 = failObserver113
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executed++; digest = prepared.operationPlan.bindingDigest
        let child = metadata.deriveRetainedLease()
        child.ensureRetainedPeak(65536)
        Result.Ok(ToolResult(prepared.call.callId, textValue("actual-canonical-success113"),
            payloadLease: Some(ToolResultPayloadLease({ => child.close() }))))
    }
    public func afterPreparedResultPersisted(context: ToolInvocationContext,
        plan: NormalizedOperationPlan, result: ToolResult): Result<Unit> {
        oldCalls++; throw IllegalStateException("actual paid ACP observer fell back to an old callback")
    }
    public func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        plan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        observed++
        @Expect(plan.bindingDigest, digest); @Expect(plan.toolName, "acp_actual_checkpoint113")
        @Expect(result.isError, false); @Expect(result.payloadLease.isSome()); @Expect(result.receiptId != "")
        let rows = database.query("SELECT o.normalized_plan,r.outcome,i.payload FROM operations o " +
            "JOIN operation_effect_records e ON e.operation_id=o.id " +
            "JOIN operation_receipts r ON r.id=e.reserved_receipt_id AND r.operation_id=o.id " +
            "JOIN items i ON i.id=e.reserved_result_item_id WHERE r.id=?", [SqlParameter.Text(result.receiptId)])
        @Expect(rows.size, 1); @Expect(rows[0].required(1), "completed")
        @Expect(storedOperationPlanMatches(rows[0].required(0), plan))
        @Expect(rows[0].required(2).contains("actual-canonical-success113"))
        receipt = result.receiptId
        canonicalEntered113.store(true)
        while (pausedObserver113 && !canonicalRelease113.load()) { sleep(Duration.millisecond * 5) }
        if (!failObserver113) { return Some(OwnedFailureDataOutcome113<Unit>.Value(())) }
        // This source DTO is constructed under the already paid original
        // fixture share; capture derives THAT same bank, never a new owner.
        let error = AgentError(AgentErrorKind.Internal, "acp.actual_checkpoint雪", "actual observer failed\u{0}雪🙂",
            retryable: true, fallbackAllowed: true,
            fields: [ErrorField("same", "first"), ErrorField("same", "second雪\u{0}")],
            attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError,
                diagnostics: AttemptFailureDiagnostics(elapsedMillis: 11, softDeadlineMillis: 12,
                    hardDeadlineMillis: 13, enteredCompletionGrace: true,
                    lastProgressKind: AttemptProgressKind.ToolArgumentProgress, lastProgressAgeMillis: 14,
                    providerTerminalObserved: true, openContentBlockCount: 15,
                    toolCallsStarted: 16, toolCallsCompleted: 17))),
            observation: Some(OperationObservation(stringifyUnifiedJson(objectValue([
                ValueField("actual_receipt", textValue(result.receiptId)), ValueField("actual_call", textValue(result.callId))])))))
        Some(captureOwnedFailureData113<Unit>(error, { _ => metadata.deriveRetainedLease() }))
    }
}

private class AcpActualFactory113 {
    private let root: String
    private let observer: AcpActualCanonicalObserver113
    let closedProducts = AtomicInt64(0)
    var opened: ?ProductRuntime = None<ProductRuntime>
    init(root: String, observer: AcpActualCanonicalObserver113) { this.root = root; this.observer = observer }
    func open113(cwd: String): Result<ProductRuntime> {
        let product = openProduct(config: ProductConfig(workspaceRoot: cwd, settingsRoot: root + "/session-settings",
            stateRoot: root + "/session-state", fixture: true, asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        opened = Some(product)
        product.registerTool(ToolDescriptor(ModelToolDefinition("acp_actual_checkpoint113", "Real ACP canonical failure observer",
            objectValue([ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
            Capability(CapabilityKind.WorkspaceRead), implementationVersion: "actual-acp113",
            implementationFingerprint: "actual-acp113"), observer).value().getOrThrow()
        Result.Ok(product)
    }
    func close113(product: ProductRuntime, lateClose: Bool): Result<Unit> {
        let result = product.close(); closedProducts.fetchAdd(1)
        match (result) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!lateClose) { return Result<Unit>.Ok(()) }
        // Actual Product cleanup physically returned before this late typed
        // producer failure. The source fields are funded by the fixture's
        // already paid original Native metadata, never a fabricated Receipt.
        Result<Unit>.Err(AgentError(AgentErrorKind.Internal, "acp.actual_late_close雪", "late close failed\u{0}🙂",
            retryable: true, fallbackAllowed: true,
            fields: [ErrorField("same", "first"), ErrorField("same", "second雪\u{0}")],
            attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError,
                diagnostics: AttemptFailureDiagnostics(elapsedMillis: 11, softDeadlineMillis: 12,
                    hardDeadlineMillis: 13, enteredCompletionGrace: true,
                    lastProgressKind: AttemptProgressKind.ToolArgumentProgress, lastProgressAgeMillis: 14,
                    providerTerminalObserved: true, openContentBlockCount: 15,
                    toolCallsStarted: 16, toolCallsCompleted: 17))),
            observation: Some(OperationObservation("{\"actual_cleanup_returned\":true}"))))
    }
}
private class AcpActualInstalledFixture113 {
    let root: String
    let control: AcpOwnedWorkerControl113
    let output: AcpActualOutput113
    let database: SqliteDatabase
    let observer: AcpActualCanonicalObserver113
    let host: ProductRuntime
    let server: ProductAcpServer
    let factory: AcpActualFactory113
    prop opened: ?ProductRuntime { get() { factory.opened } }
    private let metadata: AcpOraclePayment113
    init(metadata: AcpOraclePayment113, lateClose!: Bool = false,
        pausedObserver113!: Bool = false, failObserver113!: Bool = true) {
        this.metadata = metadata
        if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
        this.root = Directory.createTemp("target").toString()
        this.control = newAcpOwnedWorkerControl113()
        this.output = AcpActualOutput113(metadata)
        this.host = openProduct(config: ProductConfig(workspaceRoot: root, settingsRoot: root + "/host-settings",
            stateRoot: root + "/host-state", fixture: true, asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        Directory.create(root + "/session-state", recursive: true)
        this.database = SqliteDatabase(root + "/session-state/state.db")
        this.observer = AcpActualCanonicalObserver113(metadata, database,
            pausedObserver113: pausedObserver113, failObserver113: failObserver113)
        this.factory = AcpActualFactory113(root, observer)
        let actualFactory = this.factory
        this.server = ProductAcpServer(host, { cwd => actualFactory.open113(cwd) },
            { _ => throw IllegalStateException("actual owned ACP fixture has no bare String fallback") },
            closer: { product => actualFactory.close113(product, lateClose) },
            control113: control, ownedFailureOutput113: Some(output), ownedResponseOutput113: Some(output))
    }
    func input113(id: Int64, name: String, params: AgentValue): Unit {
        let payment = control.deriveFrontendMetadata113(1048576)
        let input = AcpOwnedInput113(payment, 1048576, { => encodeAgentValue(objectValue([
            ValueField("jsonrpc", textValue("2.0")), ValueField("id", integerValue(id)),
            ValueField("method", textValue(name)), ValueField("params", params)])) })
        server.handleOwnedInput113(input).value().getOrThrow()
        @Expect(server.afterOwnedInputHelperReturn113(input)); @Expect(input.retireAfterHandlerReturn113())
    }
    func session113(): String {
        input113(1, "initialize", objectValue([]))
        input113(2, "session/new", objectValue([ValueField("cwd", textValue(root)), ValueField("mcpServers", listValue([]))]))
        output.response113(2).field("result").getOrThrow().field("sessionId").getOrThrow().text
    }
    func canonical113(): Unit {
        @Expect(observer.executed, 1); @Expect(observer.observed, 1); @Expect(observer.oldCalls, 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 1)
    }
    func closeNormal113(): Unit {
        @Expect(match (server.closeOwned113()) { case AcpOwnedCloseStatus113.Complete => true; case _ => false })
        @Expect(server.retireOwnedCloseAfterFrontendHelperReturn113())
        database.close(); remove(root, recursive: true)
    }
}

private func acpActualFullError113(value: AgentValue, receipt: String): Unit {
    @Expect(value.fields.size, 8)
    @Expect(value.field("kind").getOrThrow().text, "internal")
    @Expect(value.field("code").getOrThrow().text, "acp.actual_checkpoint雪")
    @Expect(value.field("message").getOrThrow().text, "actual observer failed\u{0}雪🙂")
    @Expect(value.field("retryable").getOrThrow().asBool()); @Expect(value.field("fallback_allowed").getOrThrow().asBool())
    let fields = value.field("fields").getOrThrow().items
    @Expect(fields.size, 2); @Expect(fields[0].field("name").getOrThrow().text, "same")
    @Expect(fields[0].field("value").getOrThrow().text, "first")
    @Expect(fields[1].field("name").getOrThrow().text, "same")
    @Expect(fields[1].field("value").getOrThrow().text, "second雪\u{0}")
    let attempt = value.field("attempt_failure").getOrThrow()
    @Expect(attempt.field("kind").getOrThrow().text, "provider_protocol_error")
    let diagnostics = attempt.field("diagnostics").getOrThrow()
    @Expect(diagnostics.fields.size, 10)
    @Expect(diagnostics.field("elapsed_millis").getOrThrow().asNumberText(), "11")
    @Expect(diagnostics.field("soft_deadline_millis").getOrThrow().asNumberText(), "12")
    @Expect(diagnostics.field("hard_deadline_millis").getOrThrow().asNumberText(), "13")
    @Expect(diagnostics.field("entered_completion_grace").getOrThrow().asBool())
    @Expect(diagnostics.field("last_progress_kind").getOrThrow().text, "tool_argument_progress")
    @Expect(diagnostics.field("last_progress_age_millis").getOrThrow().asNumberText(), "14")
    @Expect(diagnostics.field("provider_terminal_observed").getOrThrow().asBool())
    @Expect(diagnostics.field("open_content_block_count").getOrThrow().asNumberText(), "15")
    @Expect(diagnostics.field("tool_calls_started").getOrThrow().asNumberText(), "16")
    @Expect(diagnostics.field("tool_calls_completed").getOrThrow().asNumberText(), "17")
    let observation = value.field("observation").getOrThrow()
    @Expect(!observation.field("authorizes_effects").getOrThrow().asBool())
    @Expect(observation.field("trust").getOrThrow().text, "untrusted_data")
    @Expect(observation.field("content").getOrThrow().field("actual_receipt").getOrThrow().text, receipt)
    @Expect(observation.field("content").getOrThrow().field("actual_call").getOrThrow().text, "acp-actual-call113")
}
private func acpActualWait113(condition: ()->Bool): Bool {
    let until = MonoTime.now() + Duration.second * 5
    while (!condition() && MonoTime.now() < until) { sleep(Duration.millisecond * 5) }
    condition()
}
private func acpActualSequentialBody113(metadata: AcpOraclePayment113): AcpOwnedWorkerControl113 {
    let f = AcpActualInstalledFixture113(metadata)
    f.input113(1, "initialize", objectValue([]))
    let first = f.control.observedOriginalCustody113()
    for (id in 3..33) { f.input113(id, "initialize", objectValue([])); @Expect(f.output.responseCount113(id), 1) }
    let last = f.control.observedOriginalCustody113()
    expectActualUsageFields163_3(last, first) // 30 extra inputs/frames cannot accumulate Root invoices.
    @Expect(f.output.failureWrites, 0); f.closeNormal113(); f.control
}
private func acpActualCanonicalBody113(metadata: AcpOraclePayment113): AcpOwnedWorkerControl113 {
    let f = AcpActualInstalledFixture113(metadata)
    let id = f.session113()
    f.opened.getOrThrow().fixtureProbe.getOrThrow().enqueueToolCallReply("acp-actual-call113", "acp_actual_checkpoint113", objectValue([]))
    f.input113(47, "session/prompt", objectValue([ValueField("sessionId", textValue(id)),
        ValueField("prompt", listValue([objectValue([ValueField("type", textValue("text")), ValueField("text", textValue("Execute the actual canonical observer once."))])]))]))
    @Expect(acpActualWait113({ => f.server.collectOwnedCheckpointFailures113() && f.output.responseCount113(47) == 1 }))
    let response = f.output.response113(47)
    @Expect(response.field("jsonrpc").getOrThrow().text, "2.0")
    let data = response.field("error").getOrThrow().field("data").getOrThrow()
    acpActualFullError113(data.field("error_data").getOrThrow(), f.observer.receipt)
    @Expect(data.field("secondary_errors").getOrThrow().items.size, 0)
    let diagnostics = data.field("diagnostics").getOrThrow().items
    @Expect(diagnostics.size, 1); @Expect(diagnostics[0].field("type").getOrThrow().text, "diagnostic")
    acpActualFullError113(diagnostics[0].field("error_data").getOrThrow(), f.observer.receipt)
    @Expect(diagnostics[0].field("run_id").getOrThrow().text != "")
    @Expect(diagnostics[0].field("sequence").getOrThrow().asNumberText() != "0")
    @Expect(f.output.failureWrites, 1); f.canonical113()
    @Expect(f.server.collectOwnedCheckpointFailures113()); @Expect(f.output.responseCount113(47), 1)
    f.closeNormal113(); f.control
}
private func acpActualLateCloseBody113(metadata: AcpOraclePayment113): AcpOwnedWorkerControl113 {
    let f = AcpActualInstalledFixture113(metadata, lateClose: true)
    let _ = f.session113()
    @Expect(match (f.server.closeOwned113()) { case AcpOwnedCloseStatus113.Failed => true; case _ => false })
    @Expect(f.factory.closedProducts.load(), 2)
    @Expect(!f.control.retireStandaloneAfterScopeReturn113())
    @Expect(f.server.writeOwnedClose113({ frame => f.output.writeAcpResponse113(frame) }))
    @Expect(f.output.closeWrites, 1)
    @Expect(f.output.lastClosePrefix113, "error[acp.server_shutdown_failed]: ACP server shutdown failed: 2 failure(s)\n")
    let data = f.output.frames[f.output.frames.size-1]
    @Expect(data.field("error_data").getOrThrow().field("code").getOrThrow().text, "acp.server_shutdown_failed")
    let secondary = data.field("secondary_errors").getOrThrow().items
    @Expect(secondary.size, 3)
    var actualLateCount113: Int64 = 0
    var actualSessionAggregateCount113: Int64 = 0
    for (item in secondary) {
        let error = item.field("error_data").getOrThrow()
        @Expect(error.fields.size, 8)
        if (error.field("code").getOrThrow().text == "acp.session_close_failed") {
            actualSessionAggregateCount113++
            @Expect(error.field("kind").getOrThrow().text, "internal")
            @Expect(error.field("message").getOrThrow().text, "ACP session close failed: 1 failure(s)")
            @Expect(!error.field("retryable").getOrThrow().asBool()); @Expect(!error.field("fallback_allowed").getOrThrow().asBool())
            let fields = error.field("fields").getOrThrow().items
            @Expect(fields.size, 3)
            @Expect(fields[0].field("name").getOrThrow().text, "failure_count"); @Expect(fields[0].field("value").getOrThrow().text, "1")
            @Expect(fields[1].field("name").getOrThrow().text, "error_0_code"); @Expect(fields[1].field("value").getOrThrow().text, "acp.actual_late_close雪")
            @Expect(fields[2].field("name").getOrThrow().text, "error_0_message"); @Expect(fields[2].field("value").getOrThrow().text, "late close failed\u{0}🙂")
            @Expect(error.field("attempt_failure").getOrThrow().unifiedKind, ValueKind.Null)
            @Expect(error.field("observation").getOrThrow().unifiedKind, ValueKind.Null)
            continue
        }
        actualLateCount113++
        @Expect(error.field("code").getOrThrow().text, "acp.actual_late_close雪")
        @Expect(error.field("message").getOrThrow().text, "late close failed\u{0}🙂")
        @Expect(error.field("retryable").getOrThrow().asBool()); @Expect(error.field("fallback_allowed").getOrThrow().asBool())
        @Expect(error.field("fields").getOrThrow().items.size, 2)
        @Expect(error.field("attempt_failure").getOrThrow().field("diagnostics").getOrThrow().fields.size, 10)
        @Expect(error.field("observation").getOrThrow().field("content").getOrThrow().field("actual_cleanup_returned").getOrThrow().asBool())
    }
    @Expect(actualLateCount113, 2); @Expect(actualSessionAggregateCount113, 1)
    @Expect(f.server.retireOwnedCloseAfterFrontendHelperReturn113())
    @Expect(match (f.server.closeOwned113()) { case AcpOwnedCloseStatus113.FailedConsumed => true; case _ => false })
    @Expect(f.factory.closedProducts.load(), 2); @Expect(f.output.closeWrites, 1)
    f.database.close(); remove(f.root, recursive: true); f.control
}

@Test
class ActualAcpOwnedLifecycle113Tests {
    @TestCase
    func actualSequentialOwnedRequestsRetireInputsAndFramesWithoutCumulativeRootGrowth(): Unit {
        let before = productControlMetadataUsage113()
        let paid = reserveProductControlMetadata113(4194304)
        try {
            let returned = acpActualSequentialBody113(paid)
            // WHOLE fixture body and all real server/SQL/renderer locals returned.
            @Expect(returned.retireStandaloneAfterScopeReturn113())
        } finally { paid.close() }
        expectActualUsageFields163_2(productControlMetadataUsage113(), before)
    }
    @TestCase
    func actualCanonicalObserverCallerAndEventReachOneAcpFullDataReplyBeforeIndependentAcknowledgements(): Unit {
        let before = productControlMetadataUsage113()
        let paid = reserveProductControlMetadata113(4194304)
        try {
            let returned = acpActualCanonicalBody113(paid)
            // WHOLE fixture body and all real server/SQL/renderer locals returned.
            @Expect(returned.retireStandaloneAfterScopeReturn113())
        } finally { paid.close() }
        expectActualUsageFields163_2(productControlMetadataUsage113(), before)
    }
    @TestCase
    func actualLateProductCloseErrorsKeepCompleteOriginalDataUntilOneConsumedCloseFrame(): Unit {
        let before = productControlMetadataUsage113()
        let paid = reserveProductControlMetadata113(4194304)
        try {
            let returned = acpActualLateCloseBody113(paid)
            // WHOLE fixture body and all real server/SQL/renderer locals returned.
            @Expect(returned.retireStandaloneAfterScopeReturn113())
        } finally { paid.close() }
        expectActualUsageFields163_2(productControlMetadataUsage113(), before)
    }
}

private func expectActualUsageFields163_2(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
}

private func expectActualUsageFields163_3(actual: (Int64, Int64, Int64), expected: (Int64, Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
    @Expect(actual[2], expected[2])
}

private func acpActualCancelledCanonicalBody113(metadata: AcpOraclePayment113, failed: Bool): AcpOwnedWorkerControl113 {
    let f = AcpActualInstalledFixture113(metadata, pausedObserver113: true, failObserver113: failed)
    let id = f.session113()
    f.opened.getOrThrow().fixtureProbe.getOrThrow().enqueueToolCallReply("acp-actual-call113", "acp_actual_checkpoint113", objectValue([]))
    f.input113(47,"session/prompt",objectValue([ValueField("sessionId",textValue(id)),
        ValueField("prompt",listValue([objectValue([ValueField("type",textValue("text")),
            ValueField("text",textValue("Execute the actual canonical observer before cancelling."))])]))]))
    @Expect(acpActualWait113({ => f.observer.canonicalEntered113.load() }))
    f.canonical113()
    f.input113(48,"session/cancel",objectValue([ValueField("sessionId",textValue(id))]))
    @Expect(f.output.responseCount113(48),1)
    @Expect(f.output.response113(48).field("result").getOrThrow().fields.size,0)
    // The original request id is still held while the real canonical observer
    // and its enclosing registered Future have NOT returned. Cancel is not ACK.
    @Expect(f.output.responseCount113(47),0)
    @Expect(!f.server.collectOwnedCheckpointFailures113())
    @Expect(f.output.responseCount113(47),0)
    @Expect(f.factory.closedProducts.load(),0)
    // A second real cancellation cannot take the original paid prompt id.
    // A new actual prompt is rejected even though cancel set running=false.
    f.input113(49,"session/cancel",objectValue([ValueField("sessionId",textValue(id))]))
    @Expect(f.output.responseCount113(49),1)
    @Expect(f.output.response113(49).field("result").getOrThrow().fields.size,0)
    @Expect(f.output.responseCount113(47),0)
    f.input113(50,"session/prompt",objectValue([ValueField("sessionId",textValue(id)),
        ValueField("prompt",listValue([objectValue([ValueField("type",textValue("text")),
            ValueField("text",textValue("This must not replace the actual retained request."))])]))]))
    @Expect(f.output.responseCount113(50),1)
    @Expect(f.output.response113(50).field("error").isSome())
    @Expect(f.output.responseCount113(47),0); f.canonical113()
    f.observer.canonicalRelease113.store(true)
    @Expect(acpActualWait113({ => f.server.collectOwnedCheckpointFailures113() && f.output.responseCount113(47)==1 }))
    let response = f.output.response113(47)
    @Expect(response.field("jsonrpc").getOrThrow().text,"2.0")
    if (failed) {
        let data = response.field("error").getOrThrow().field("data").getOrThrow()
        acpActualFullError113(data.field("error_data").getOrThrow(),f.observer.receipt)
        @Expect(data.field("secondary_errors").getOrThrow().items.size,0)
        let diagnostics = data.field("diagnostics").getOrThrow().items
        @Expect(diagnostics.size,1)
        acpActualFullError113(diagnostics[0].field("error_data").getOrThrow(),f.observer.receipt)
        @Expect(f.output.failureWrites,1)
    } else {
        @Expect(response.field("error").isNone())
        let result = response.field("result").getOrThrow()
        @Expect(result.fields.size,1)
        @Expect(result.field("stopReason").getOrThrow().text,"cancelled")
        @Expect(f.output.failureWrites,0)
    }
    // Repeated collection observes true input consumption, never another
    // terminal offer. Actual canonical bytes/Receipt remain the original ones.
    @Expect(f.server.collectOwnedCheckpointFailures113())
    @Expect(f.output.responseCount113(47),1); f.canonical113()
    f.closeNormal113(); f.control
}

@Test
class ActualAcpCancelledCanonical113Tests {
    @TestCase
    func cancelDuringActualCanonicalObserverKeepsOriginalIdForCompleteFailureAndEvent(): Unit {
        let before=productControlMetadataUsage113()
        let paid=reserveProductControlMetadata113(4194304)
        try {
            let returned=acpActualCancelledCanonicalBody113(paid,true)
            @Expect(returned.retireStandaloneAfterScopeReturn113())
        } finally { paid.close() }
        expectActualCancelledUsageFields28(productControlMetadataUsage113(),before)
    }
    @TestCase
    func cancelWithoutCheckpointFailureKeepsOriginalCancelledSchemaAfterActualWorkerReturn(): Unit {
        let before=productControlMetadataUsage113()
        let paid=reserveProductControlMetadata113(4194304)
        try {
            let returned=acpActualCancelledCanonicalBody113(paid,false)
            @Expect(returned.retireStandaloneAfterScopeReturn113())
        } finally { paid.close() }
        expectActualCancelledUsageFields28(productControlMetadataUsage113(),before)
    }
}

private func expectActualCancelledUsageFields28(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0],expected[0])
    @Expect(actual[1],expected[1])
}
