package agent_store_contract

import std.time.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

// These tests create real HostService startup Runs, approval decisions,
// canonical results and Receipts through the existing fixture. They exercise
// the ONE durable store. They do not assert physical bytes or Product's
// post-write error classification; those belong to actual transport tests.
class ServiceEffectStoreFixture {
    let stream: Bool
    let prefix: String
    let database: SqliteDatabase
    let store: DurableOperationStore
    let runtime: AgentThreadRuntime
    let thread: ThreadId
    let run: RunId
    let parent: OperationId
    let child: OperationId
    let epoch: Int64
    let call: ToolCall
    let source: OperationRootSource
    let rootPlan: NormalizedOperationPlan
    let childPlan: NormalizedOperationPlan
    let key: String
    private let closeFixture: () -> Unit

    init(stream: Bool, committed: Bool, scenario!: String = "completed") {
        this.stream = stream
        prefix = if (stream) { "stream" } else { "channel" }
        let grant: ?AgentValue = if (scenario == "missing-grant") { None }
            else { Some(listValue([textValue(if (scenario == "different-grant") { "other" } else { "echo" })])) }
        let marker = if (scenario == "unbound-readonly") { "" }
            else if (scenario == "binding-tool-mismatch") { "other" } else { "echo" }
        let namespace = if (scenario == "wrong-owner") { "axyndra:foreign" } else { "axyndra:" + prefix + "-contract" }
        let service = if (scenario == "wrong-service") { "foreign" } else { "session" }
        let name = "plugin." + namespace + ".service." + service + ".echo"
        let validPair = !["wrong-owner", "binding-tool-mismatch", "unbound-readonly", "safe-replay"].contains(scenario)
        let replay = if (scenario == "safe-replay") { ReplayDisposition.SafeReplay } else { ReplayDisposition.NeverReplay }
        if (stream) {
            let value = HttpStreamIntentStoreFixture(committed, readOnly: true, readOnlyGrant: grant,
                readOnlyBinding: marker, toolName: name, replay: Some(replay), expectPair: validPair)
            database = value.database; store = value.store; runtime = value.runtime
            thread = value.thread; run = value.run; parent = value.parent; child = value.child; epoch = value.epoch
            call = value.call; source = value.source; rootPlan = value.rootPlan; childPlan = value.childPlan; key = value.key
            closeFixture = { => value.close() }
        } else {
            let value = ChannelIntentStoreFixture(committed, readOnly: true, readOnlyGrant: grant,
                readOnlyBinding: marker, toolName: name, replay: Some(replay), expectPair: validPair)
            database = value.database; store = value.store; runtime = value.runtime
            thread = value.thread; run = value.run; parent = value.parent; child = value.child; epoch = value.epoch
            call = value.call; source = value.source; rootPlan = value.rootPlan; childPlan = value.childPlan; key = value.key
            closeFixture = { => value.close() }
        }
    }
    func binding(): AgentValue { rootPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow() }
    func activate(): Unit {
        httpContractRequire(store.waitForApproval(parent, run), "readonly parent actual approval wait")
        httpContractRequire(store.recordApproval(prefix + "-parent-approved", parent, run, rootPlan,
            CapabilitySet(values: rootPlan.requiredCapabilities), true, "user", None), "readonly parent explicit approval")
        httpContractRequire(store.markExecuting(parent, run, rootPlan, 31, true), "readonly parent execution")
        httpContractRequire(store.markExecutionHandoff(parent, run, thread, 32), "readonly parent actual handoff")
    }
    func verifyRoot(): Result<Unit> {
        if (stream) { store.verifyHttpStreamInvocationRoot(parent, run, thread, epoch, source, rootPlan, binding()) }
        else { store.verifyChannelInvocationRoot(parent, run, thread, epoch, source, rootPlan, binding()) }
    }
    func admit(): Result<OperationId> { store.prepareDerivedOperation(child, parent, run, source, key, childPlan) }
    func execute(): Result<Unit> { store.markExecuting(child, run, childPlan, 34, false) }
    func handoff(): Result<Unit> { store.markExecutionHandoff(child, run, thread, 35) }
    func receipt(outcome: OperationOutcome): VNextOperationReceipt {
        VNextOperationReceipt("receipt-" + prefix + "-child", child, outcome,
            objectValue([ValueField("observed", textValue("readonly root, mutating transport"))]), objectValue([]), 36)
    }
    func settle(outcome: OperationOutcome): Result<Unit> { store.settleDerivedOperation(run, parent, receipt(outcome)) }
    func startupId(): String { prefix + "-startup-operation" }
    func countChild(table: String): Int64 {
        database.scalarInt("SELECT COUNT(*) FROM " + table + " WHERE " +
            (if (table == "operations") { "id" } else { "operation_id" }) + "=" + sqliteText(child.value))
    }
    func childState(): String { database.query("SELECT state FROM operations WHERE id=?", [SqlParameter.Text(child.value)])[0].required(0) }
    func assertUnchangedNoReceipt(state: String): Unit {
        expect(childState() == state && countChild("operation_receipts") == 0,
            "failed readonly proof leaves operation state and Receipt unchanged")
    }
    func close(): Unit { closeFixture() }
}

// Save and restore both persisted copies. A mutation of just one row would
// test only generic plan equality; this tests the canonical startup proof too.
class ServiceEffectStartupMutation {
    private let fixture: ServiceEffectStoreFixture
    private let mode: String
    private let original: String
    init(fixture: ServiceEffectStoreFixture, mode: String) {
        this.fixture = fixture; this.mode = mode
        let column = if (mode == "plan") { "normalized_plan" } else { "detail" }
        let table = if (mode == "plan") { "operations" } else { "operation_receipts" }
        let id = if (mode == "plan") { "id" } else { "operation_id" }
        original = fixture.database.query("SELECT " + column + " FROM " + table + " WHERE " + id + "=?",
            [SqlParameter.Text(fixture.startupId())])[0].required(0)
        let changed = decodeStoredValue(original)
        if (mode == "plan") {
            let args = changed.field("arguments").getOrThrow()
            let grant = if (fixture.stream) { args.field("grant").getOrThrow() } else { args }
            grant.put("read_only_tools", listValue([textValue("other")]))
            fixture.database.execute("UPDATE operations SET normalized_plan=? WHERE id=?",
                [SqlParameter.Text(encodeStoredValue(changed)), SqlParameter.Text(fixture.startupId())])
            fixture.database.execute("UPDATE operation_effect_records SET normalized_plan=? WHERE operation_id=?",
                [SqlParameter.Text(encodeStoredValue(changed)), SqlParameter.Text(fixture.startupId())])
        } else {
            changed.put(if (fixture.stream) { "grant_digest" } else { "launch_digest" }, textValue(
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
            fixture.database.execute("UPDATE operation_receipts SET detail=? WHERE operation_id=?",
                [SqlParameter.Text(encodeStoredValue(changed)), SqlParameter.Text(fixture.startupId())])
        }
    }
    func restore(): Unit {
        if (mode == "plan") {
            fixture.database.execute("UPDATE operations SET normalized_plan=? WHERE id=?",
                [SqlParameter.Text(original), SqlParameter.Text(fixture.startupId())])
            fixture.database.execute("UPDATE operation_effect_records SET normalized_plan=? WHERE operation_id=?",
                [SqlParameter.Text(original), SqlParameter.Text(fixture.startupId())])
        } else {
            fixture.database.execute("UPDATE operation_receipts SET detail=? WHERE operation_id=?",
                [SqlParameter.Text(original), SqlParameter.Text(fixture.startupId())])
        }
    }
}

func serviceEffectPolicyDurableContract(): Unit {
    var scenarios: Int64 = 0
    for (stream in [false, true]) {
        for (committed in [false, true]) {
            for (scenario in ["completed", "unknown", "missing-grant", "different-grant", "wrong-service",
                "wrong-owner", "binding-tool-mismatch", "unbound-readonly", "safe-replay", "derived-root"]) {
                serviceEffectAdmissionScenario(stream, committed, scenario); scenarios += 1
            }
            for (corruption in ["plan", "receipt"]) {
                for (stage in ["admit", "execute", "handoff", "settle", "cancel"]) {
                    if (stage == "cancel") { serviceEffectCancellationScenario(stream, committed, corruption) }
                    else { serviceEffectRecheckScenario(stream, committed, stage, corruption) }
                    scenarios += 1
                }
            }
            serviceEffectCancellationScenario(stream, committed, ""); scenarios += 1
        }
    }
    expect(scenarios == 84, "all readonly service effect policy cases actually execute")
    println("Service readonly policy durable contract passed: 84 scenarios, Direct and Committed, channel and HTTP POST")
}

func serviceEffectAdmissionScenario(stream: Bool, committed: Bool, scenario: String): Unit {
    let fixture = ServiceEffectStoreFixture(stream, committed, scenario: scenario)
    let database = fixture.database; let store = fixture.store
    try {
        fixture.activate()
        if (scenario == "derived-root") {
            // Fault injection: this is a real canonical root and startup,
            // but its persisted classification now says Derived. Program's
            // real admission API cannot create this managed root at all.
            database.execute("INSERT INTO derived_operation_admissions " +
                "(operation_id,parent_operation_id,call_sequence,request_key,request_digest) VALUES (?,?,?,?,?)",
                [SqlParameter.Text(fixture.parent.value), SqlParameter.Text(fixture.startupId()),
                SqlParameter.Int64Value(1), SqlParameter.Text("fault-injected-derived-root"),
                SqlParameter.Text(fixture.rootPlan.bindingDigest)])
        }
        let negative = scenario != "completed" && scenario != "unknown"
        if (negative) {
            expect(fixture.verifyRoot().isError() && fixture.admit().isError(),
                scenario + " cannot turn a readonly marker into operator authority")
            expect(fixture.countChild("operations") == 0 && fixture.countChild("derived_operation_admissions") == 0 &&
                fixture.countChild("operation_receipts") == 0 && fixture.countChild("audit_events") == 0,
                scenario + " admission rejection rolls back every child fact")
            return
        }
        expect(fixture.rootPlan.effectClass == OperationEffectClass.ReadOnly &&
            fixture.childPlan.effectClass == OperationEffectClass.ExternalMutation &&
            fixture.rootPlan.retryDisposition == OperationRetryDisposition.Never &&
            fixture.childPlan.retryDisposition == OperationRetryDisposition.Never &&
            (match (fixture.rootPlan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }) &&
            (match (fixture.childPlan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }),
            "operator read-only root never relabels transport mutation or permits replay")
        if (stream) {
            expect(httpIntentText(fixture.childPlan.canonicalArguments.field("intent").getOrThrow().field("request").getOrThrow(),
                "method") == "POST", "HTTP case performs the conservative POST child path")
        }
        httpContractRequire(fixture.verifyRoot(), "exact completed startup grants the exact local readonly contribution")
        // The operator assertion is bound to this root, not a reusable right
        // to issue a different request or to narrow the child's effect.
        let weakened = NormalizedOperationPlan(fixture.childPlan.toolName, fixture.childPlan.canonicalArguments,
            fixture.childPlan.requiredCapabilities, OperationEffectClass.ReadOnly, OperationRetryDisposition.Never,
            fixture.childPlan.bindingDigest, toolVersion: fixture.childPlan.implementation.toolVersion,
            implementationFingerprint: fixture.childPlan.implementation.implementationFingerprint,
            networkPolicy: Some(fixture.childPlan.networkPolicy), replayDisposition: Some(ReplayDisposition.NeverReplay))
        expect(store.prepareDerivedOperation(OperationId("readonly-weakened-child"), fixture.parent, fixture.run,
            fixture.source, fixture.key, weakened).isError() &&
            database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='readonly-weakened-child'") == 0,
            "transport effects cannot be laundered into a read-only child")
        httpContractRequire(fixture.admit(), "readonly source exact child admission")
        let evidence = decodeStoredValue(database.query("SELECT payload FROM audit_events WHERE operation_id=? " +
            "AND kind='operation_parent_intent_authorized'", [SqlParameter.Text(fixture.child.value)])[0].required(0))
        expect(httpIntentText(evidence, "root_source") == (if (committed) { "committed" } else { "direct" }) &&
            httpIntentText(evidence, "parent_plan_digest") == fixture.rootPlan.bindingDigest &&
            httpIntentText(evidence, "child_plan_digest") == fixture.childPlan.bindingDigest &&
            fixture.countChild("approvals") == 0 && fixture.countChild("approval_decisions") == 0,
            "read-only grant does not create a fake model source or extra user approval")
        httpContractRequire(fixture.execute(), "readonly parent child authorized execution")
        httpContractRequire(fixture.handoff(), "readonly parent child real handoff")
        let outcome = if (scenario == "unknown") { OperationOutcome.Unknown } else { OperationOutcome.Completed }
        httpContractRequire(fixture.settle(outcome), "readonly parent child truthful outcome")
        let retained = httpContractRequire(store.loadDerivedOperationReceipt(fixture.child, fixture.run), "readonly child receipt").getOrThrow()
        let replay = httpContractRequire(fixture.admit(), "readonly duplicate request finds same operation")
        expect(retained.outcome == outcome && replay.value == fixture.child.value && fixture.execute().isError() &&
            fixture.handoff().isError() && fixture.countChild("operation_receipts") == 1 &&
            fixture.countChild("derived_operation_admissions") == 1 && database.query("PRAGMA foreign_key_check").isEmpty(),
            "one exact child has one Receipt and cannot be dispatched again")

    } finally { fixture.close() }
}

func serviceEffectRecheckScenario(stream: Bool, committed: Bool, stage: String, corruption: String): Unit {
    let fixture = ServiceEffectStoreFixture(stream, committed)
    try {
        fixture.activate()
        if (stage != "admit") { httpContractRequire(fixture.admit(), "recheck child admitted") }
        if (stage == "handoff" || stage == "settle") { httpContractRequire(fixture.execute(), "recheck child executing") }
        if (stage == "settle") { httpContractRequire(fixture.handoff(), "recheck child handed off") }
        let changed = ServiceEffectStartupMutation(fixture, corruption)
        expect(fixture.verifyRoot().isError(), "existing readonly root cannot retain altered startup authority")
        if (stage == "admit") {
            expect(fixture.admit().isError() && fixture.countChild("operations") == 0 &&
                fixture.countChild("derived_operation_admissions") == 0 && fixture.countChild("audit_events") == 0,
                "admission atomically rechecks actual completed startup grant")
        } else if (stage == "execute") {
            expect(fixture.execute().isError(), "execution rechecks startup read-only authority")
            fixture.assertUnchangedNoReceipt("prepared")
        } else if (stage == "handoff") {
            expect(fixture.handoff().isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id=" + sqliteText(fixture.child.value) +
                " AND kind='operation_execution_handoff'") == 0,
                "handoff rechecks operator proof before transport")
            fixture.assertUnchangedNoReceipt("executing")
        } else {
            expect(fixture.settle(OperationOutcome.Completed).isError(), "settlement preserves exact startup authority")
            fixture.assertUnchangedNoReceipt("executing")
        }
        changed.restore()
        httpContractRequire(fixture.verifyRoot(), "restoring original facts restores exact root proof")
        if (stage == "admit") { httpContractRequire(fixture.admit(), "unchanged admission still works") }
        if (stage == "admit" || stage == "execute") { httpContractRequire(fixture.execute(), "unchanged execution still works") }
        if (stage != "settle") { httpContractRequire(fixture.handoff(), "unchanged handoff still works") }
        httpContractRequire(fixture.settle(OperationOutcome.Completed), "restored exact obligation settles once")
        expect(fixture.countChild("operation_receipts") == 1 && fixture.database.query("PRAGMA foreign_key_check").isEmpty(),
            "rejected proof checks cannot consume the one eventual Receipt")
    } finally { fixture.close() }
}

func serviceEffectCancellationScenario(stream: Bool, committed: Bool, corruption: String): Unit {
    let fixture = ServiceEffectStoreFixture(stream, committed)
    let database = fixture.database; let store = fixture.store
    try {
        fixture.activate()
        httpContractRequire(fixture.admit(), "cancel readonly child admitted")
        httpContractRequire(fixture.execute(), "cancel readonly child executing")
        httpContractRequire(fixture.handoff(), "cancel readonly child handed off")
        // Existing generic ReadOnly semantics remain intact. Product maps a
        // real attempted write to RecoveryRequired before this root resolver.
        let ordinary = resolveOperationAttempt(fixture.parent, CanonicalToolCallId(fixture.call.callId), fixture.rootPlan,
            OperationAttemptStage.Executing, Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Cancelled,
                "readonly.cancelled", "ordinary readonly cancellation")), "not-persisted", 40)
        expect(match (ordinary) { case OperationResolution.Terminal(value) => value.receipt.outcome == OperationOutcome.Cancelled
            case _ => false }, "ordinary readonly cancellation is not globally reclassified as an unknown write")
        let token = httpContractRequire(fixture.runtime.childCancellationToken(expectedRunId: Some(fixture.run),
            expectedEpoch: Some(fixture.epoch)), "readonly Run owned cancellation")
        let task = spawn {
            let deadline = agentUtcMillis() + 3000
            while (!token.isCancelled() && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
            expect(token.isCancelled() && database.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(fixture.run.value)])[0].required(0) == "cancelling",
                "late readonly obligation settles during actual cancelling Run")
            expect(fixture.admit().isError() && fixture.execute().isError() && fixture.handoff().isError() && fixture.verifyRoot().isError(),
                "cancellation never grants new effects through readonly status")
            for (outcome in [OperationOutcome.Completed, OperationOutcome.Failed, OperationOutcome.Cancelled, OperationOutcome.Rejected]) {
                expect(fixture.settle(outcome).isError(), "handed mutation cannot become known success, failure, rejection or cancellation")
            }
            if (corruption != "") {
                let changed = ServiceEffectStartupMutation(fixture, corruption)
                expect(fixture.settle(OperationOutcome.Unknown).isError(), "cancelled obligation still rechecks operator grant provenance")
                fixture.assertUnchangedNoReceipt("executing")
                changed.restore()
            }
            httpContractRequire(fixture.settle(OperationOutcome.Unknown), "handed child retains truthful Unknown during cancellation")
            // This is the host finish result after a physical write attempt;
            // the actual physical-write -> classification mapping is tested
            // in Product, not invented by this Store fixture.
            let resolved = httpContractRequire(fixture.runtime.resolveOperation(ItemId(fixture.prefix + "-parent-result"), fixture.parent,
                CanonicalToolCallId(fixture.call.callId), fixture.rootPlan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "service.write_outcome_unknown", "host observed an attempted transport write")),
                "receipt-" + fixture.prefix + "-parent", 42, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)),
                "readonly root retains actual host Unknown classification")
            expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()),
                "readonly cancellation retains canonical root ToolResult and Receipt")
        }
        httpContractRequire(fixture.runtime.ownTask("readonly-settlement", task), "runtime owns late readonly settlement")
        let cancelled = fixture.runtime.cancel(5000, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch))
        task.get(); httpContractRequire(cancelled, "cancel waits for child and root evidence")
        expect(database.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(fixture.run.value)])[0].required(0) == "cancelled" &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id IN (" + sqliteText(fixture.parent.value) + "," +
                sqliteText(fixture.child.value) + ") AND outcome='unknown'") == 2 &&
            fixture.countChild("operation_receipts") == 1 && fixture.execute().isError() && fixture.handoff().isError() &&
            fixture.settle(OperationOutcome.Unknown).isError() && database.query("PRAGMA foreign_key_check").isEmpty(),
            "readonly cancelled root and handed child each keep one Unknown Receipt and never replay")
    } finally { fixture.close() }
}
