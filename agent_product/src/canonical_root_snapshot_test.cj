package agent_product

import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class CanonicalRootSnapshotProbe <: ToolExecutor {
    var calls: Int64 = 0
    var observed: ?ToolSetSnapshot = None
    let version: String
    init(version: String) { this.version = version }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let root = match (prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value)) => value
            case _ => return Result.Err(AgentError(AgentErrorKind.Internal,
                "fixture.root_source_missing", "requires the actual canonical Direct source"))
        }
        if (root.validateLiveSource().isError() || root.runId.value != context.runId.value ||
            root.threadId.value != context.sessionId.value || root.epoch != context.epoch) {
            return Result.Err(AgentError(AgentErrorKind.Internal,
                "fixture.root_source_stale", "requires the live same-thread actual Run source"))
        }
        calls += 1
        observed = context.toolSetSnapshot
        Result.Ok(ToolResult(prepared.call.callId, textValue(version)))
    }
}

func canonicalRootSnapshotDescriptor(name: String, version: String,
    network!: ?(ToolCall) -> Result<NetworkPolicy> = None): ToolDescriptor {
    ToolDescriptor(ModelToolDefinition(name, "Actual gateway snapshot fixture",
        objectValue([ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
        Capability(CapabilityKind.WorkspaceRead), sideEffecting: false,
        implementationVersion: version, networkPolicyResolver: network)
}

class CanonicalRootSnapshotFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    init(label: String) {
        root = pluginContractTemp("canonical-root-snapshot-" + label)
        Directory.create(root + "/workspace", recursive: true)
        product = workspacePluginOpen(root, ApprovalMode.Yolo)
        database = SqliteDatabase(root + "/state/state.db")
    }
    func capabilities(): CapabilitySet { CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]) }
    func call(id: String, name: String): ToolCall { ToolCall(id, name, objectValue([])) }
    func lane(thread: String): ModelLane {
        let rows = database.query("SELECT lane_snapshot FROM runs WHERE thread_id=?",
            [SqlParameter.Text(thread)])
        if (rows.size != 1) { throw IllegalStateException("expected one actual persisted Run lane") }
        modelLaneFromSnapshotValue(decodeStoredValue(rows[0].required(0)))
    }
    func close(): Unit { product.close(); database.close(); remove(root, recursive: true) }
}

func canonicalRootSnapshotEntry(snapshot: ToolSetSnapshot, name: String): ToolSnapshotEntry {
    for (entry in snapshot.entries where entry.name == name) { return entry }
    throw IllegalStateException("actual Run snapshot omitted the root publication")
}


// Observe the real Store reservation and the independently saved canonical
// Receipt/Item. These checks do not derive expected ids from a naming helper.
func expectCanonicalReservedRootResults(database: SqliteDatabase, thread: String, expected: Int64,
    run!: String = ""): Unit {
    let rows = database.query("SELECT e.operation_id,e.reserved_receipt_id,e.reserved_result_item_id," +
        "receipt.id,receipt.detail,receipt.outcome,result.id,result.payload,call.payload " +
        "FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id AND o.run_id=e.run_id " +
        "JOIN runs r ON r.id=e.run_id JOIN items call ON call.id=e.tool_call_item_id " +
        "AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "LEFT JOIN operation_receipts receipt ON receipt.operation_id=e.operation_id " +
        "LEFT JOIN items result ON result.id=e.reserved_result_item_id AND result.thread_id=r.thread_id " +
        "AND result.turn_id=r.turn_id AND result.kind='tool_result' " +
        "WHERE r.thread_id=? AND (?='' OR r.id=?) AND o.state IN ('committed','rejected','cancelled','timed_out','failed') " +
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=e.operation_id)",
        [SqlParameter.Text(thread), SqlParameter.Text(run), SqlParameter.Text(run)])
    @Expect(rows.size, expected)
    for (row in rows) {
        @Expect(row[3].isSome()); @Expect(row[6].isSome())
        @Expect(row.required(3), row.required(1))
        @Expect(row.required(6), row.required(2))
        let callId = match (decodeStoredThreadContent(row.required(8))) {
            case ThreadItemContent.ToolCall(id, _, _) => id.value
            case _ => throw IllegalStateException("actual root reservation lost its canonical ToolCall")
        }
        match (decodeStoredThreadContent(row.required(7))) {
            case ThreadItemContent.ToolResult(id, operation, receipt, output, isError) =>
                @Expect(id.value, callId); @Expect(operation.value, row.required(0))
                @Expect(receipt, row.required(3))
                if (row.required(5) == "completed") {
                    @Expect(isError, false)
                    @Expect(canonicalAgentValue(output), canonicalAgentValue(decodeStoredValue(row.required(4))))
                }
            case _ => throw IllegalStateException("reserved actual root result has a different content kind")
        }
    }
}

func expectCanonicalReturnedReceipt(database: SqliteDatabase, result: ToolResult): Unit {
    let rows = database.query("SELECT e.reserved_receipt_id FROM operation_effect_records e " +
        "JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE r.id=?",
        [SqlParameter.Text(result.receiptId)])
    @Expect(rows.size, 1); @Expect(result.receiptId, rows[0].required(0))
}

class CanonicalRootReservationLeaseProbe <: ToolExecutor {
    let actual: CanonicalRootSnapshotProbe
    let lease: ToolResultPayloadLease
    init(lease: ToolResultPayloadLease) { this.actual = CanonicalRootSnapshotProbe("lease-v1"); this.lease = lease }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        match (actual.execute(context, prepared)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(ToolResult(value.callId, value.output,
                receiptId: "executor-local-label", payloadLease: Some(lease)))
        }
    }
}

@Test
class ProductCanonicalRootSnapshotTests {
    @TestCase
    func ordinaryDirectRootBorrowsItsActualPersistedSameThreadSnapshot(): Unit {
        let fixture = CanonicalRootSnapshotFixture("direct")
        try {
            let probe = CanonicalRootSnapshotProbe("direct-v1")
            fixture.product.registerTool(canonicalRootSnapshotDescriptor("fixture_snapshot_direct", "direct-v1"), probe)
                .value().getOrThrow()
            let result = hostServiceEntryCompleted(fixture.product.vnext.executeCanonicalTool(SessionId("snapshot-direct"),
                fixture.capabilities(), fixture.call("snapshot-direct-call", "fixture_snapshot_direct")))
            @Expect(result.isError, false)
            @Expect(probe.calls, 1)
            let observed = probe.observed.getOrThrow()
            let lane = fixture.lane("snapshot-direct")
            @Expect(observed.threadId.getOrThrow().value, "snapshot-direct")
            @Expect(observed.id, lane.toolSet.id)
            @Expect(canonicalRootSnapshotEntry(observed, "fixture_snapshot_direct").executorVersion, "direct-v1")
            @Expect(canonicalAgentValue(modelLaneSnapshotValue(lane)).contains("direct-v1"), true)
            @Expect(lane.capabilities.tools, true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            expectCanonicalReservedRootResults(fixture.database, "snapshot-direct", 1)
            expectCanonicalReturnedReceipt(fixture.database, result)
        } finally { fixture.close() }
    }

    @TestCase
    func ordinaryHostServiceRootKeepsItsActualSourceAndRunOwnedSnapshot(): Unit {
        let fixture = CanonicalRootSnapshotFixture("service")
        try {
            let probe = CanonicalRootSnapshotProbe("service-v1")
            fixture.product.registerTool(canonicalRootSnapshotDescriptor("fixture_snapshot_service", "service-v1"), probe)
                .value().getOrThrow()
            let result = hostServiceEntryCompleted(fixture.product.vnext.executeHostServiceTool(SessionId("snapshot-service"),
                hostServiceEntryTestOrigin(), fixture.capabilities(), fixture.call("snapshot-service-call", "fixture_snapshot_service")))
            @Expect(result.isError, false)
            @Expect(probe.calls, 1)
            @Expect(probe.observed.getOrThrow().threadId.getOrThrow().value, "snapshot-service")
            @Expect(probe.observed.getOrThrow().id, fixture.lane("snapshot-service").toolSet.id)
            let sources = fixture.database.query("SELECT provenance FROM items WHERE kind='tool_call'")
            @Expect(sources.size, 1)
            @Expect(sameDirectCallOrigin(effectiveDirectCallOrigin(decodeStoredProvenance(sources[0].required(0))),
                DirectCallOrigin.HostService(hostServiceEntryTestOrigin())), true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            expectCanonicalReservedRootResults(fixture.database, "snapshot-service", 1)
            expectCanonicalReturnedReceipt(fixture.database, result)
        } finally { fixture.close() }
    }

    @TestCase
    func actualRootReturnsItsReservedReceiptAndRetainsOneExecutorPayloadLease(): Unit {
        let fixture = CanonicalRootSnapshotFixture("result-lease")
        let released = AtomicInt64(0)
        let lease = ToolResultPayloadLease({ => released.fetchAdd(1); () })
        try {
            let probe = CanonicalRootReservationLeaseProbe(lease)
            fixture.product.registerTool(canonicalRootSnapshotDescriptor("fixture_snapshot_lease", "lease-v1"), probe)
                .value().getOrThrow()
            let result = hostServiceEntryCompleted(fixture.product.vnext.executeCanonicalTool(SessionId("snapshot-result-lease"),
                fixture.capabilities(), fixture.call("snapshot-result-lease-call", "fixture_snapshot_lease")))
            try {
                @Expect(probe.actual.calls, 1); @Expect(result.isError, false)
                @Expect(result.output.text, "lease-v1")
                @Expect(result.receiptId != "executor-local-label")
                @Expect(result.payloadLease.isSome()); @Expect(refEq(result.payloadLease.getOrThrow(), lease))
                @Expect(released.load(), 0)
                expectCanonicalReservedRootResults(fixture.database, "snapshot-result-lease", 1)
                expectCanonicalReturnedReceipt(fixture.database, result)
            } finally { result.releasePayload() }
            lease.close(); @Expect(released.load(), 1)
        } finally { lease.close(); fixture.close() }
    }

    @TestCase
    func publicationChangeAfterCaptureCannotRetargetTheCurrentRoot(): Unit {
        let fixture = CanonicalRootSnapshotFixture("pin")
        try {
            let original = CanonicalRootSnapshotProbe("pinned-v1")
            let replacement = CanonicalRootSnapshotProbe("published-v2")
            let republished = AtomicBool(false)
            fixture.product.registerTool(canonicalRootSnapshotDescriptor("fixture_snapshot_pin", "pinned-v1",
                network: Some({ _: ToolCall =>
                    if (!republished.load()) {
                        // Classification must never run this business resolver before
                        // the actual owning Run has been created and persisted.
                        if (fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='snapshot-pin'") != 1) {
                            throw IllegalStateException("root classification resolved business policy before its actual Run")
                        }
                        republished.store(true)
                        if (!fixture.product.unregisterTool("fixture_snapshot_pin")) {
                            throw IllegalStateException("failed to retire the original actual publication")
                        }
                        fixture.product.registerTool(canonicalRootSnapshotDescriptor("fixture_snapshot_pin", "published-v2"), replacement)
                            .value().getOrThrow()
                    }
                    Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
                })), original).value().getOrThrow()
            let result = hostServiceEntryCompleted(fixture.product.vnext.executeCanonicalTool(SessionId("snapshot-pin"),
                fixture.capabilities(), fixture.call("snapshot-pin-call", "fixture_snapshot_pin")))
            @Expect(result.isError, false)
            @Expect(result.output.text, "pinned-v1")
            @Expect(republished.load(), true)
            @Expect(original.calls, 1)
            @Expect(replacement.calls, 0)
            @Expect(canonicalRootSnapshotEntry(fixture.lane("snapshot-pin").toolSet, "fixture_snapshot_pin").executorVersion, "pinned-v1")
            let fresh = hostServiceEntryCompleted(fixture.product.vnext.executeCanonicalTool(SessionId("snapshot-fresh"),
                fixture.capabilities(), fixture.call("snapshot-fresh-call", "fixture_snapshot_pin")))
            @Expect(fresh.output.text, "published-v2")
            @Expect(replacement.calls, 1)
            @Expect(canonicalRootSnapshotEntry(fixture.lane("snapshot-fresh").toolSet, "fixture_snapshot_pin").executorVersion, "published-v2")
        } finally { fixture.close() }
    }

    @TestCase
    func controlOnlyAndUnknownRootsRetainTheirExistingCanonicalPaths(): Unit {
        let fixture = HostServiceEntryFixture("snapshot-control")
        try {
            let result = hostServiceEntryCompleted(fixture.product.vnext.executeHostServiceTool(SessionId("snapshot-control"),
                hostServiceEntryTestOrigin(), fixture.ceiling(), fixture.call("snapshot-control-call"),
                approvalDecision: Some(ApprovalDecision.Approve)))
            @Expect(result.isError, false)
            @Expect(fixture.probe.calls, 1)
            let rows = fixture.database.query("SELECT lane_snapshot FROM runs WHERE thread_id='snapshot-control'")
            let lane = modelLaneFromSnapshotValue(decodeStoredValue(rows[0].required(0)))
            @Expect(lane.toolSet.entries.size, 0)
            @Expect(lane.capabilities.tools, false)
            let unknown = hostServiceEntryCompleted(fixture.product.vnext.executeCanonicalTool(SessionId("snapshot-unknown"),
                fixture.ceiling(), ToolCall("snapshot-unknown-call", "fixture_missing_publication", objectValue([]))))
            @Expect(unknown.isError, true)
            @Expect(unknown.output.field("error").getOrThrow().text, "tool.not_found")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='snapshot-unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='snapshot-unknown' AND state='failed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='snapshot-unknown' AND kind='user_message'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='snapshot-unknown' AND kind='tool_call'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='snapshot-unknown' AND kind='operation_execution_handoff'"), 0)
            @Expect(fixture.probe.calls, 1)
        } finally { fixture.close() }
    }
}
