package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func childRequire111<T>(result: Result<T>): T {
    match (result) { case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("child fixture: " + error.code) }
}
private class ChildEstimator111 <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
private class ChildStoreFixture111 {
    let directory: String
    let database: SqliteDatabase
    let store: DurableOperationStore
    let runtime: AgentThreadRuntime
    let source: OperationRootSource
    let thread = ThreadId("primitive-thread")
    let run = RunId("primitive-run")
    let parent = OperationId("primitive-parent")
    let child = OperationId("primitive-child")
    let epoch: Int64
    let parentPlan: NormalizedOperationPlan
    let childPlan: NormalizedOperationPlan
    init(waiting!: Bool = false, allocation!: ?(Int64)->LogicalJsonOwnerReservation = None,
        prompt!: String = "perform the frozen task") {
        directory = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        database = SqliteDatabase(directory + "/child.sqlite")
        let sink = SqliteThreadCommitSink(database, knownParentAllocation: allocation)
        let coordinator = ThreadCoordinator(sink.createThread(thread, "/workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("child", ChildEstimator111()), { => 10 })
        let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system")
        let turn = SemanticTurnId("primitive-turn")
        let active = childRequire111(runtime.startTurn(turn, run, ItemId("primitive-user"),
            ThreadItemContent.UserMessage(textMessageParts("delegate one child")), lane, InvocationContextProjection()))
        epoch = active.epoch
        let call = ToolCall("primitive-call", "plugin.axyndra:workflow.task", objectValue([]))
        let item = ItemId("primitive-item")
        match (runtime.commitResult(ResultEnvelope(thread, turn, run, epoch, 1,
            ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))) {
            case SemanticCommitDecision.Committed(_, _) => ()
            case _ => throw IllegalStateException("child fixture canonical ToolCall did not commit")
        }
        source = OperationRootSource.Direct(childRequire111(runtime.attestDirectToolCall(item, parent, run, epoch)))
        store = DurableOperationStore(database, documentPayloadAllocation: allocation)
        let actualLane = childRequire111(store.pluginDocumentLane(thread, run, epoch))
        let digest = modelPolicySha256Text("exact primitive fixture")
        let binding = objectValue([ValueField("namespace", textValue("axyndra:workflow")),
            ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("1")),
            ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue(thread.value)),
            ValueField("lane_id", textValue(actualLane.value)), ValueField("run_id", textValue(run.value)),
            ValueField("epoch", integerValue(epoch)), ValueField("parent_call_id", textValue(call.callId)),
            ValueField("contribution", textValue(call.name)), ValueField("implementation_fingerprint", textValue("frozen-fixture")),
            ValueField("schema_digest", textValue(digest))])
        let completionInput = objectValue([])
        let intent = objectValue([ValueField("id", textValue("start-0")), ValueField("service", textValue("child.start")),
            ValueField("input", objectValue([ValueField("request", objectValue([
                ValueField("label", textValue("one")), ValueField("description", textValue("one actual child")),
                ValueField("prompt", textValue(prompt)), ValueField("system_prompt", textValue("")),
                ValueField("model_alias", textValue("")), ValueField("thinking", textValue("")), ValueField("cache_key", textValue("")),
                ValueField("capability_ceiling", listValue([])), ValueField("requested_limits", objectValue([])),
                ValueField("background", boolValue(false))])), ValueField("completion", objectValue([
                    ValueField("provider", textValue("propose")), ValueField("input", completionInput),
                    ValueField("input_sha256", textValue(modelPolicySha256Text(canonicalAgentValue(completionInput))))]))]))])
        let arguments = objectValue([ValueField("input", call.arguments), ValueField("configuration", objectValue([])),
            ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_PRIMITIVE_PARENT111)),
                ValueField("binding", binding), ValueField("intents", listValue(if(waiting){[intent,
                    objectValue([ValueField("id",textValue("wait-0")),ValueField("service",textValue("child.wait")),
                        ValueField("input",objectValue([ValueField("start_intent_id",textValue("start-0"))]))])]}else{[intent]}))]))])
        let capabilities = [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow"), Capability(CapabilityKind.Delegate)]
        parentPlan = NormalizedOperationPlan(call.name, arguments, capabilities, OperationEffectClass.ExternalMutation,
            OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(arguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: "fixture", implementationFingerprint: "frozen-fixture", schemaDigest: digest)
        let childArguments = childRequire111(pluginChildStartArguments111(arguments, "start-0"))
        childPlan = NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111, childArguments, capabilities,
            OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(childArguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: HOST_PLUGIN_CHILD_FINGERPRINT111, implementationFingerprint: HOST_PLUGIN_CHILD_FINGERPRINT111)
    }
    func parentHandoff(): Unit {
        let direct = match (source) { case OperationRootSource.Direct(value) => value
            case _ => throw IllegalStateException("fixture requires actual Direct source") }
        childRequire111(store.prepareDirectOperation(direct, parentPlan))
        childRequire111(store.markExecutingWithSource(Some(source), parent, run, parentPlan, 11, false))
        childRequire111(store.markExecutionHandoffWithSource(Some(source), parent, run, thread, 12))
    }
    func prepareChild(): Result<OperationId> {
        store.prepareDerivedOperation(child, parent, run, source, exactServiceRequestKey(source.callId(), childPlan), childPlan)
    }
    func childHandoff(): Unit {
        childRequire111(prepareChild())
        childRequire111(store.markExecutingWithSource(Some(source), child, run, childPlan, 13, false))
        childRequire111(store.markExecutionHandoffWithSource(Some(source), child, run, thread, 14))
    }
    func verify(): Result<Unit> { store.verifyPluginChildExecution111(source, parent, child, run, thread, epoch, childPlan) }
    func waitPlan(): NormalizedOperationPlan {
        let arguments=childRequire111(pluginChildStartArguments111(parentPlan.canonicalArguments,"wait-0"))
        NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111,arguments,childPlan.requiredCapabilities,
            OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(arguments)),
            networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
            toolVersion:HOST_PLUGIN_CHILD_FINGERPRINT111,implementationFingerprint:HOST_PLUGIN_CHILD_FINGERPRINT111)
    }
    func waitHandoff(): Unit {
        let plan=waitPlan();let id=OperationId("primitive-wait")
        childRequire111(store.prepareDerivedOperation(id,parent,run,source,exactServiceRequestKey(source.callId(),plan),plan))
        childRequire111(store.markExecutingWithSource(Some(source),id,run,plan,16,false))
        childRequire111(store.markExecutionHandoffWithSource(Some(source),id,run,thread,17))
    }
    func launchReceipt(): Unit {
        childRequire111(store.settleDerivedOperation(run,parent,VNextOperationReceipt("receipt-"+child.value,child,
            OperationOutcome.Completed,objectValue([ValueField("schema",textValue("axyndra.child-launch-result/v1")),
                ValueField("child_id",textValue("observed-child")),ValueField("run_id",textValue("observed-run")),
                ValueField("thread_id",textValue("observed-thread"))]),objectValue([
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("request_key",textValue(exactServiceRequestKey(source.callId(),childPlan))),
                ValueField("request_id",textValue("start-0")),ValueField("service",textValue("child.start"))]),15)))
    }
    func waitReceipt(): Result<VNextOperationReceipt> {
        store.pluginChildStartReceipt111(source,parent,OperationId("primitive-wait"),run,thread,epoch,waitPlan())
    }
    func commitParentFailure(): Bool {
        let slots = database.query("SELECT reserved_receipt_id,reserved_result_item_id FROM operation_effect_records WHERE operation_id=?",
            [SqlParameter.Text(parent.value)])
        if (slots.size != 1) { throw IllegalStateException("parent lost its real reserved settlement slots") }
        let output = objectValue([ValueField("error", textValue("fixture child failed"))])
        let receipt = VNextOperationReceipt(slots[0].required(0), parent, OperationOutcome.Failed,
            output, objectValue([]), 16)
        match (runtime.commitOperationResult(ResultEnvelope(thread, SemanticTurnId("primitive-turn"), run, epoch,
            runtime.threadSnapshot().nextResultSequence,
            ThreadItemDraft(ItemId(slots[0].required(1)), ThreadItemContent.ToolResult(
                CanonicalToolCallId("primitive-call"), parent, receipt.receiptId, output, true),
                ItemProvenance("operation", runId: Some(run), operationId: Some(parent)), createdAtMillis: 16)), receipt)) {
            case SemanticCommitDecision.Committed(_, _) => true
            case _ => false
        }
    }
    func close(): Unit { database.close(); remove(directory, recursive: true) }
}

// These are actual canonical SQLite admission controls. They do NOT assert
// that an installed worker or a model child was launched; those belong to the
// required Host/Product pilot tests before this service can be enabled.
@Test
class PluginChildScopeTests111 {
    @TestCase
    func KnownTerminalDerivedReceiptAllowsCompletedRunAfterCanonicalParentResult(): Unit {
        for (paid in [false, true]) {
            for (outcome in [OperationOutcome.Rejected, OperationOutcome.Cancelled, OperationOutcome.TimedOut, OperationOutcome.Failed]) {
                let bank = LogicalJsonOwnerBudget()
                let original = bank.acquire(131072)
                let allocate = { bytes: Int64 =>
                    let loan = original.deriveRetainedLease()
                    try { loan.ensureRetainedPeak(bytes); loan }
                    catch (error: Exception) { loan.close(); throw error }
                }
                let allocation: ?(Int64)->LogicalJsonOwnerReservation = if (paid) { Some(allocate) } else { None }
                let f = ChildStoreFixture111(allocation: allocation)
                try {
                    f.parentHandoff()
                    if (outcome == OperationOutcome.Rejected) { childRequire111(f.prepareChild()) } else { f.childHandoff() }
                    childRequire111(f.store.settleDerivedOperation(f.run, f.parent, VNextOperationReceipt(
                        "receipt-" + f.child.value, f.child, outcome, objectValue([]), objectValue([]), 15)))
                    @Assert(f.commitParentFailure())
                    let completed = f.runtime.finish(RunState.Completed, 1000)
                    @Expect(completed.isOk())
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
                    let rows = f.database.query("SELECT o.state,receipt.outcome FROM operations o JOIN operation_receipts receipt " +
                        "ON receipt.operation_id=o.id WHERE o.id='primitive-child'")
                    @Expect(rows.size, 1)
                    @Expect(rows[0].required(0), operationOutcomeName(outcome))
                    @Expect(rows[0].required(1), operationOutcomeName(outcome))
                } finally { f.close(); original.close() }
            }
        }
    }
    @TestCase
    func PaidDerivedCompletionCommitsWithinTheExistingSharedBank(): Unit {
        // Fixed-capacity accounting behavior, not the product quota or a
        // physical-memory benchmark. Both other invoices remain live through
        // the actual SQLite-backed Run completion.
        let bank = LogicalJsonOwnerBudget(maximumCharged: 33554432)
        let original = bank.acquire(131072)
        let competing = bank.acquire(131072)
        let allocate = { bytes: Int64 =>
            let loan = original.deriveRetainedLease()
            try { loan.ensureRetainedPeak(bytes); loan }
            catch (error: Exception) { loan.close(); throw error }
        }
        let f = ChildStoreFixture111(allocation: Some(allocate),
            prompt: String.fromUtf8(Array<Byte>(32768, repeat: b'x')))
        var pressure: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
        try {
            f.parentHandoff(); f.childHandoff()
            childRequire111(f.store.settleDerivedOperation(f.run, f.parent, VNextOperationReceipt(
                "receipt-" + f.child.value, f.child, OperationOutcome.Failed, objectValue([]), objectValue([]), 15)))
            @Assert(f.commitParentFailure())
            let held = original.deriveRetainedLease(); pressure = Some(held)
            held.ensureRetainedPeak(11534336)
            let completed = f.runtime.finish(RunState.Completed, 1000)
            match (completed) {
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
                case Result.Ok(_) => ()
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations o JOIN operation_receipts receipt " +
                "ON receipt.operation_id=o.id WHERE o.id='primitive-child' AND o.state='failed' AND receipt.outcome='failed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 1)
        } finally {
            f.close()
            match (pressure) { case Some(value) => value.close(); case None => () }
            competing.close(); original.close()
        }
    }
    @TestCase
    func PaidDerivedCompletionStillValidatesArgumentsAndEveryPlanHeader(): Unit {
        for (mode in ["argument_tag", "argument_duplicates", "argument_depth", "argument_shape",
            "capability", "network", "policy", "replay", "eof"]) {
            let bank = LogicalJsonOwnerBudget()
            let original = bank.acquire(131072)
            let allocate = { bytes: Int64 =>
                let loan = original.deriveRetainedLease()
                try { loan.ensureRetainedPeak(bytes); loan }
                catch (error: Exception) { loan.close(); throw error }
            }
            let f = ChildStoreFixture111(allocation: Some(allocate))
            try {
                f.parentHandoff(); f.childHandoff()
                childRequire111(f.store.settleDerivedOperation(f.run, f.parent, VNextOperationReceipt(
                    "receipt-" + f.child.value, f.child, OperationOutcome.Failed, objectValue([]), objectValue([]), 15)))
                @Assert(f.commitParentFailure())
                let marker = "projection-argument-canary"
                let value = storedOperationPlanValue(f.childPlan)
                value.put("arguments", if (mode == "argument_shape") { listValue([]) }
                    else { objectValue([ValueField("ignored", textValue(marker))]) })
                if (mode == "capability") {
                    value.put("capabilities", listValue([objectValue([
                        ValueField("kind", textValue("invalid")), ValueField("resource", textValue("fixture"))])]))
                } else if (mode == "network") { value.put("network", objectValue([ValueField("mode", textValue("invalid"))])) }
                else if (mode == "policy") { value.put("policy_version", textValue(" ")) }
                else if (mode == "replay") { value.put("replay", objectValue([ValueField("kind", textValue("invalid"))])) }
                var raw = encodeStoredValue(value)
                let encodedMarker = "s" + marker.size.toString() + ":" + marker
                if (mode == "argument_tag") { raw = raw.replace(encodedMarker, "z") }
                else if (mode == "argument_duplicates") { raw = raw.replace(encodedMarker, "o1:21:xn1:xn") }
                else if (mode == "argument_depth") {
                    let nested = Array<Byte>(261, { index =>
                        if (index == 260) { b'n' } else {
                            match (index % 4) { case 0 => b'l'; case 1 | 3 => b'1'; case _ => b':' }
                        }
                    })
                    raw = raw.replace(encodedMarker, String.fromUtf8(nested))
                } else if (mode == "eof") { raw += "n" }
                // Fault-inject both equal canonical cells, so the original
                // byte-equality join cannot stand in for full codec validation.
                f.database.execute("UPDATE operations SET normalized_plan=? WHERE id=?",
                    [SqlParameter.Text(raw), SqlParameter.Text(f.child.value)])
                f.database.execute("UPDATE operation_effect_records SET normalized_plan=? WHERE operation_id=?",
                    [SqlParameter.Text(raw), SqlParameter.Text(f.child.value)])
                @Expect(f.runtime.finish(RunState.Completed, 1000).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 0)
            } finally { f.close(); original.close() }
        }
    }
    @TestCase
    func FailedDerivedCompletionStillRequiresExactCanonicalReceiptAndSource(): Unit {
        for (mode in ["unknown", "state", "receipt", "depth", "digest", "effect", "missing"]) {
            let f = ChildStoreFixture111()
            try {
                f.parentHandoff(); f.childHandoff()
                childRequire111(f.store.settleDerivedOperation(f.run, f.parent, VNextOperationReceipt(
                    "receipt-" + f.child.value, f.child, OperationOutcome.Failed, objectValue([]), objectValue([]), 15)))
                @Assert(f.commitParentFailure())
                if (mode == "unknown") { f.database.execute("UPDATE operation_receipts SET outcome='unknown' WHERE operation_id='primitive-child'") }
                else if (mode == "state") { f.database.execute("UPDATE operation_state_registers SET state='executing' WHERE operation_id='primitive-child'") }
                else if (mode == "receipt") { f.database.execute("UPDATE operation_effect_records SET reserved_receipt_id='changed' WHERE operation_id='primitive-child'") }
                else if (mode == "depth") { f.database.execute("UPDATE derived_operation_admissions SET depth=1 WHERE operation_id='primitive-child'") }
                else if (mode == "digest") { f.database.execute("UPDATE derived_operation_admissions SET request_digest='changed' WHERE operation_id='primitive-child'") }
                else if (mode == "effect") { f.database.execute("UPDATE operation_effect_records SET normalized_plan='{}' WHERE operation_id='primitive-child'") }
                else { f.database.execute("DELETE FROM operation_receipts WHERE operation_id='primitive-child'") }
                @Expect(f.runtime.finish(RunState.Completed, 1000).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 0)
            } finally { f.close() }
        }
    }

    @TestCase
    func SupervisedNativeTaskChildrenReuseOnlyTheirCanonicalAdmittedRoot(): Unit {
        let bank = LogicalJsonOwnerBudget()
        let original = bank.acquire(131072)
        let allocate = { bytes: Int64 =>
            let child = original.deriveRetainedLease()
            try { child.ensureRetainedPeak(bytes); child }
            catch (error: Exception) { child.close(); throw error }
        }
        let f = ChildStoreFixture111(allocation: Some(allocate))
        try {
            let direct = match (f.source) { case OperationRootSource.Direct(value) => value
                case _ => throw IllegalStateException("actual fixture Direct source is missing") }
            childRequire111(f.store.prepareDirectOperation(direct, f.parentPlan))
            let pin = objectValue([ValueField(f.parentPlan.toolName, objectValue([
                ValueField("version", textValue(f.parentPlan.implementation.toolVersion)),
                ValueField("fingerprint", textValue(f.parentPlan.implementation.implementationFingerprint)),
                ValueField("schema_digest", textValue(f.parentPlan.implementation.schemaDigest))]))])
            let action = PlanAction("delegate", [f.parentPlan.toolName], ["denied"], OperationEffectClass.ExternalMutation,
                objectValue([]), 1, exactArguments: true, toolIdentities: pin, delegatedActionIds: ["leaf"])
            let leaf = PlanAction("leaf", ["read"], ["denied"], OperationEffectClass.ReadOnly, objectValue([]), 1,
                toolIdentities: objectValue([ValueField("read", objectValue([ValueField("version", textValue("1")),
                    ValueField("fingerprint", textValue("leaf")), ValueField("schema_digest", textValue("leaf"))]))]))
            let plans = DurablePlanExecutionStore(f.database, knownParentAllocation: Some(allocate))
            childRequire111(plans.bind("native-task-plan", f.thread.value, f.run, PlanContract(["/workspace"], [
                PlanExecutionStep(PlanStepId("delegate"), [], true, [action]),
                PlanExecutionStep(PlanStepId("leaf"), [], true, [leaf])])) )
            childRequire111(plans.admit(f.run, f.parent, "delegate", "delegate", f.parentPlan))
            f.parentHandoff()
            childRequire111(f.prepareChild())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions WHERE root_operation_id='' AND child_call_id='' AND depth=0"), 1)
            @Expect(exactServiceChildAllowed(f.parentPlan, f.childPlan), true)
            // Fault-inject only the canonical row's tree shape. An empty-root
            // legacy Host child must never borrow a malformed readonly tree.
            f.database.execute("UPDATE derived_operation_admissions SET depth=1 WHERE operation_id='primitive-child'")
            @Expect(plans.admit(f.run, f.child, "", "", f.childPlan).isError(), true)
            @Expect(f.store.markExecutingWithSource(Some(f.source), f.child, f.run, f.childPlan, 13, false).isError(), true)
            f.database.execute("UPDATE derived_operation_admissions SET depth=0,child_call_id='forged-tree-call' WHERE operation_id='primitive-child'")
            @Expect(plans.admit(f.run, f.child, "", "", f.childPlan).isError(), true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='primitive-child' AND kind='operation_execution_handoff'"), 0)
            f.database.execute("UPDATE derived_operation_admissions SET child_call_id='' WHERE operation_id='primitive-child'")
            @Expect(plans.admit(f.run, f.child, "", "", f.childPlan).isOk(), true)
            childRequire111(f.store.markExecutingWithSource(Some(f.source), f.child, f.run, f.childPlan, 13, false))
            childRequire111(f.store.markExecutionHandoffWithSource(Some(f.source), f.child, f.run, f.thread, 14))
            @Expect(f.verify().isOk(), true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 1)
            @Expect(f.database.scalarInt("SELECT attempt_no FROM plan_action_admissions"), 1)
            childRequire111(f.store.settleDerivedOperation(f.run, f.parent, VNextOperationReceipt("receipt-" + f.child.value,
                f.child, OperationOutcome.Unknown, objectValue([]), objectValue([]), 15)))
            let owner = plans.openInspection204(f.run, original).value().getOrThrow()
            let loan = owner.beginConsumer204()
            let recovery = pluginChildRecoveryFrame204(loan)
            loan.returnConsumerFrame204(); owner.closeAfterCaller204()
            @Expect(recovery, true)
            @Expect(plans.admit(f.run, f.parent, "delegate", "delegate", f.parentPlan).isError(), true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 1)
        } finally { f.close(); original.close() }
    }
    @TestCase
    func onlyTheActualChildHandoffCanReachTheLaunchVerifier(): Unit {
        let f = ChildStoreFixture111()
        try {
            @Expect(f.prepareChild().isError(), true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            f.parentHandoff()
            childRequire111(f.prepareChild())
            @Expect(f.verify().isError(), true)
            childRequire111(f.store.markExecutingWithSource(Some(f.source), f.child, f.run, f.childPlan, 13, false))
            @Expect(f.verify().isError(), true)
            childRequire111(f.store.markExecutionHandoffWithSource(Some(f.source), f.child, f.run, f.thread, 14))
            @Expect(f.verify().isOk(), true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
        } finally { f.close() }
    }
    @TestCase
    func wrongCallerRunThreadEpochAndPlanCannotBorrowTheActualHandoff(): Unit {
        let f = ChildStoreFixture111()
        try {
            f.parentHandoff(); f.childHandoff()
            @Expect(f.verify().isOk(), true)
            @Expect(f.store.verifyPluginChildExecution111(f.source, f.parent, f.child, RunId("other"), f.thread, f.epoch, f.childPlan).isError(), true)
            @Expect(f.store.verifyPluginChildExecution111(f.source, f.parent, f.child, f.run, ThreadId("other"), f.epoch, f.childPlan).isError(), true)
            @Expect(f.store.verifyPluginChildExecution111(f.source, f.parent, f.child, f.run, f.thread, f.epoch + 1, f.childPlan).isError(), true)
            @Expect(f.store.verifyPluginChildExecution111(f.source, OperationId("other"), f.child, f.run, f.thread, f.epoch, f.childPlan).isError(), true)
            @Expect(f.store.verifyPluginChildExecution111(f.source, f.parent, f.child, f.run, f.thread, f.epoch, f.parentPlan).isError(), true)
            @Expect(f.verify().isOk(), true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
        } finally { f.close() }
    }
    @TestCase
    func sameIntentReusesTheExistingOperationAndACompletedReceiptClosesLaunch(): Unit {
        let f = ChildStoreFixture111()
        try {
            f.parentHandoff(); f.childHandoff()
            let duplicate = childRequire111(f.store.prepareDerivedOperation(OperationId("duplicate"), f.parent, f.run,
                f.source, exactServiceRequestKey(f.source.callId(), f.childPlan), f.childPlan))
            @Expect(duplicate.value, f.child.value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 2)
            childRequire111(f.store.settleDerivedOperation(f.run, f.parent,
                VNextOperationReceipt("receipt-" + f.child.value, f.child, OperationOutcome.Completed,
                    objectValue([]), objectValue([]), 15)))
            @Expect(f.verify().isError(), true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
        } finally { f.close() }
    }
}

@Test
class PluginChildWaitScopeTests111 {
    @TestCase
    func actualWaitCannotReadPreparedOrUnreceiptedLaunchAndKeepsOneRun():Unit {
        let f=ChildStoreFixture111(waiting:true)
        try{
            f.parentHandoff();f.childHandoff();f.waitHandoff()
            @Expect(f.waitReceipt().isError())
            f.launchReceipt();let receipt=childRequire111(f.waitReceipt())
            @Expect(receipt.operationId.value,f.child.value);@Expect(receipt.receiptId,"receipt-"+f.child.value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),3)
        }finally{f.close()}
    }
    @TestCase
    func wrongParentEpochRunAndSettledWaitCannotBorrowExistingLaunch():Unit {
        let f=ChildStoreFixture111(waiting:true)
        try{
            f.parentHandoff();f.childHandoff();f.launchReceipt();f.waitHandoff()
            let plan=f.waitPlan();let wait=OperationId("primitive-wait")
            @Expect(f.waitReceipt().isOk())
            @Expect(f.store.pluginChildStartReceipt111(f.source,OperationId("foreign-parent"),wait,f.run,f.thread,f.epoch,plan).isError())
            @Expect(f.store.pluginChildStartReceipt111(f.source,f.parent,wait,RunId("foreign-run"),f.thread,f.epoch,plan).isError())
            @Expect(f.store.pluginChildStartReceipt111(f.source,f.parent,wait,f.run,f.thread,f.epoch+1,plan).isError())
            childRequire111(f.store.settleDerivedOperation(f.run,f.parent,VNextOperationReceipt("receipt-"+wait.value,wait,
                OperationOutcome.Completed,objectValue([]),objectValue([]),18)))
            @Expect(f.waitReceipt().isError());@Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),2)
        }finally{f.close()}
    }
    @TestCase
    func actualStartReceiptAndParentIntentCorruptionCannotBecomeWaitAuthority():Unit {
        for(mode in ["receipt","intent","digest"]){
            let f=ChildStoreFixture111(waiting:true)
            try{
                f.parentHandoff();f.childHandoff();f.launchReceipt();f.waitHandoff();@Expect(f.waitReceipt().isOk())
                if(mode=="receipt"){f.database.execute("UPDATE operation_receipts SET outcome='unknown' WHERE operation_id='primitive-child'")}
                else if(mode=="intent"){f.database.execute("DELETE FROM audit_events WHERE operation_id='primitive-child' AND kind='operation_parent_intent_authorized'")}
                else{f.database.execute("UPDATE derived_operation_admissions SET request_digest='changed' WHERE operation_id='primitive-child'")}
                @Expect(f.waitReceipt().isError());@Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),3)
            }finally{f.close()}
        }
    }
}

private func pluginChildRecoveryFrame204(loan: PlanExecutionReadConsumer204): Bool {
    loan.value204().field("recovery_required").getOrThrow().asBool()
}
