package agent_store

import agent_domain.*
import agent_runtime.*
import std.fs.*
import std.collection.*
import std.convert.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func paidPlanReadContract204(): PlanContract {
    let args = objectValue([ValueField("path", textValue("/workspace/source"))])
    let action = PlanAction("inspect", ["read"], ["denied"], OperationEffectClass.ReadOnly,
        args, 1, exactArguments: true, toolIdentities: objectValue([ValueField("read", objectValue([
            ValueField("version", textValue("1")), ValueField("fingerprint", textValue("fixture")),
            ValueField("schema_digest", textValue("schema"))]))]))
    PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("source"), [], true, [action])],
        participatingRepositories: ["/read-repository"])
}

private func paidPlanScopeConsumerFrame204(loan: PlanExecutionReadConsumer204): Bool {
    let value = loan.value204()
    value.fields.size == 3 && value.field("execution_id").getOrThrow().text == "approved" &&
        value.field("target_roots").getOrThrow().items[0].text == "/workspace" &&
        value.field("participating_repositories").getOrThrow().items[0].text == "/read-repository" &&
        value.field("steps").isNone() && value.field("contract_view").isNone()
}

private func paidPlanDispatchConsumerFrame204(loan: PlanExecutionReadConsumer204, request: Bool): Bool {
    let value = loan.value204()
    if (request) {
        value.field("runnable_actions").isSome() && value.field("allowed_tools").isSome() &&
            value.field("contract_digest").isSome() && value.field("contract_view").isNone()
    } else {
        value.fields.size == 3 && value.field("contract_view").getOrThrow().field("steps").isSome() &&
            value.field("runnable_action_ids").isSome() && value.field("allowed_tools").isSome()
    }
}
private func consumePaidPlanDispatch204(owner: PlanExecutionReadOwner204, request: Bool): Bool {
    let loan = owner.beginConsumer204()
    let valid = paidPlanDispatchConsumerFrame204(loan, request)
    loan.returnConsumerFrame204(); owner.closeAfterCaller204(); valid
}

@Test
class PaidPlanExecutionRead204Tests {
    @TestCase
    func ClosedAndExhaustedOriginalBankRejectBeforeOpaqueDecode(): Unit {
        let path = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let database = SqliteDatabase(path + "/plan.sqlite")
        try {
            let store = DurablePlanExecutionStore(database)
            @Expect(store.activate("approved", "session", paidPlanReadContract204()).isOk())
            let closedBank = LogicalJsonOwnerBudget()
            let closed = closedBank.acquire(1); closed.close()
            @Expect(store.openSessionScope204("session", closed).isError())
            @Expect(closedBank.usage()[1], 0)
            let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
            let original = bank.acquire(1)
            original.ensureRetainedPeak(16775168)
            let before = bank.usage()
            @Expect(store.openSessionScope204("session", original).isError())
            @Expect(bank.usage()[0], before[0]); @Expect(bank.usage()[1], before[1])
            original.close()
            @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_executions"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 0)
        } finally { database.close(); remove(path, recursive: true) }
    }
    @TestCase
    func RetainedBorrowKeepsOriginalBankChargedAfterCallerReturn(): Unit {
        let path = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let database = SqliteDatabase(path + "/plan.sqlite")
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let original = bank.acquire(1)
        try {
            let store = DurablePlanExecutionStore(database)
            @Expect(store.activate("approved", "session", paidPlanReadContract204()).isOk())
            let owner = store.openSessionScope204("session", original).value().getOrThrow().getOrThrow()
            let loan = owner.beginConsumer204()
            @Expect(paidPlanScopeConsumerFrame204(loan))
            let outstanding = original.retainedCustodyUsage113()[0]
            @Expect(outstanding > 131072)
            let pressure = original.deriveRetainedLease()
            pressure.ensureRetainedPeak(16777216 - outstanding - 2048)
            owner.closeAfterCaller204()
            let held = bank.usage()
            @Expect(store.openSessionScope204("session", original).isError())
            @Expect(bank.usage()[1], held[1])
            // This is the actual complete local borrowing helper's return,
            // not a provider result, callback return, GC or Run completion.
            loan.returnConsumerFrame204()
            let recovered = store.openSessionScope204("session", original).value().getOrThrow().getOrThrow()
            recovered.closeAfterCaller204()
            pressure.close(); original.close()
            @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        } finally { database.close(); remove(path, recursive: true) }
    }
}


@Test
class UnstartedPlanChildRevocation204Tests {
    @TestCase
    func ExactUnstartedBindingRevokesWithoutDeletingGrantOrStartedRun(): Unit {
        let path = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let database = SqliteDatabase(path + "/plan.sqlite")
        let bank = LogicalJsonOwnerBudget()
        let original = bank.acquire(131072)
        let allocate = { bytes: Int64 => planReadAllocation204(original, bytes) }
        try {
            let sink = SqliteThreadCommitSink(database, knownParentAllocation: Some(allocate))
            let thread = ThreadId("cleanup-parent-thread")
            let run = RunId("cleanup-parent-run")
            let turn = SemanticTurnId("cleanup-parent-turn")
            let operation = OperationId("cleanup-parent-operation")
            let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
            let active = coordinator.startTurn(turn, run, ItemId("cleanup-parent-user"),
                ThreadItemContent.UserMessage(textMessageParts("delegate a child")), createdAtMillis: 1).value().getOrThrow()
            let item = ItemId("cleanup-parent-tool")
            let decision = coordinator.commit(ResultEnvelope(thread, turn, run, active.activeEpoch, 1,
                ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId("cleanup-call"), "task", objectValue([])),
                    ItemProvenance("control", runId: Some(run)), createdAtMillis: 2)))
            @Expect(match (decision) { case SemanticCommitDecision.Committed(_, _) => true; case _ => false })
            let plan = NormalizedOperationPlan("task", objectValue([]),
                [Capability(CapabilityKind.Delegate), Capability(CapabilityKind.WorkspaceRead)],
                OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "cleanup-digest", cwd: "/workspace",
                toolVersion: "1", implementationFingerprint: "fixture", schemaDigest: "schema")
            let operations = DurableOperationStore(database, documentPayloadAllocation: Some(allocate))
            @Expect(operations.prepareTrustedControlOperation(operation, run, item, plan).isOk())
            let task = PlanAction("delegate", ["task"], ["denied"], OperationEffectClass.ReadOnly, objectValue([]), 1,
                exactArguments: true, toolIdentities: objectValue([ValueField("task", objectValue([
                    ValueField("version", textValue("1")), ValueField("fingerprint", textValue("fixture")),
                    ValueField("schema_digest", textValue("schema"))]))]), delegatedActionIds: ["inspect"])
            let leaf = paidPlanReadContract204().steps[0].actions[0]
            let contract = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("delegate"), [], true, [task]),
                PlanExecutionStep(PlanStepId("source"), [], true, [leaf])])
            let plans = DurablePlanExecutionStore(database, knownParentAllocation: Some(allocate))
            @Expect(plans.bind("cleanup", thread.value, run, contract).isOk())
            @Expect(plans.admit(run, operation, "delegate", "delegate", plan).isOk())
            @Expect(operations.markExecuting(operation, run, plan, 3, false).isOk())
            @Expect(operations.markExecutionHandoff(operation, run, thread, 4).isOk())
            let child = ThreadId("cleanup-fresh-child")
            let childThread = sink.createThread(child, "workspace")
            @Expect(plans.inherit(run, child.value, operation).isOk())
            let before = database.query("SELECT allowed_actions,parent_run_id,parent_operation_id FROM plan_execution_members WHERE session_id='cleanup-fresh-child'")[0]
            @Expect(plans.abandonUnstartedChild204(run, child.value, OperationId("other-operation")).isError())
            @Expect(plans.executionForSession(child.value).value().getOrThrow().isSome())
            @Expect(plans.abandonUnstartedChild204(run, child.value, operation).isOk())
            @Expect(plans.abandonUnstartedChild204(run, child.value, operation).isOk())
            @Expect(plans.executionForSession(child.value).value().getOrThrow().isNone())
            let after = database.query("SELECT allowed_actions,parent_run_id,parent_operation_id FROM plan_execution_members WHERE session_id='cleanup-fresh-child'")[0]
            @Expect(before.required(0), after.required(0)); @Expect(before.required(1), after.required(1)); @Expect(before.required(2), after.required(2))
            @Expect(database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='cleanup-fresh-child'"), 1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 1)
            // This test has no queued or launched worker producer. Canonical
            // Run admission below is explicit, and makes cleanup fail closed.
            let childCoordinator = ThreadCoordinator(childThread, sink)
            let childRun = RunId("cleanup-started-run")
            @Expect(childCoordinator.startTurn(SemanticTurnId("cleanup-child-turn"), childRun, ItemId("cleanup-child-user"),
                ThreadItemContent.UserMessage(textMessageParts("accepted child")), createdAtMillis: 5).isOk())
            @Expect(plans.inherit(run, child.value, operation).isOk())
            @Expect(plans.bindRun("cleanup", child.value, childRun).isOk())
            @Expect(plans.abandonUnstartedChild204(run, child.value, operation).isError())
            @Expect(plans.executionForSession(child.value).value().getOrThrow().isSome())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE id='cleanup-started-run'"), 1)
        } finally { database.close(); original.close(); remove(path, recursive: true) }
    }
}

private class PlanGuardEstimator204 <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}

// Genuine frozen Lane, private Runtime Direct source, canonical Operation and
// immutable plan membership. No tool executor, alternate bank or SQL shortcut
// grants admission. The 100 KiB description is valid unused catalog metadata.
private class LargeLanePlanGuardFixture204 {
    let path: String
    let database: SqliteDatabase
    let operations: DurableOperationStore
    let plans: DurablePlanExecutionStore
    let runtime: AgentThreadRuntime
    let source: OperationRootSource
    let thread = ThreadId("large-lane-thread")
    let run = RunId("large-lane-run")
    let operation = OperationId("large-lane-operation")
    let plan: NormalizedOperationPlan
    init(original: LogicalJsonOwnerReservation, review: Bool, matching: Bool,
        nativeAllocation!: ?(Int64)->LogicalJsonOwnerReservation = None,
        planAllocation!: ?(Int64)->LogicalJsonOwnerReservation = None) {
        original.ensureRetainedPeak(131072 + 100000 * 128)
        // The original ledger's fixed header is real retained metadata. Pay
        // and initialize it before taking a no-leak live-lease baseline.
        let initialized = original.deriveRetainedLease(); initialized.close()
        let funding = original
        let allocate = { bytes: Int64 => planReadAllocation204(funding, bytes) }
        path = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        database = SqliteDatabase(path + "/plan.sqlite")
        let sink = SqliteThreadCommitSink(database, knownParentAllocation: Some(allocate))
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("large-lane", PlanGuardEstimator204()), { => 10 })
        let schema = objectValue([])
        let schemaDigest = modelPolicySha256Text(canonicalAgentValue(schema))
        let tools = ToolSetSnapshot("large-catalog", [ToolSnapshotEntry("read",
            String.fromUtf8(Array<Byte>(100000, repeat: b'x')), schema, "1", [Capability(CapabilityKind.WorkspaceRead)],
            implementationFingerprint: "fixture", schemaDigest: schemaDigest, planReviewSafe: review)])
        let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", tools, "system")
        let arguments = objectValue([ValueField("path", textValue("/workspace/source"))])
        let action = PlanAction("inspect", ["read"], ["denied"], OperationEffectClass.ReadOnly, arguments, 1,
            exactArguments: true, toolIdentities: objectValue([ValueField("read", objectValue([
                ValueField("version", textValue("1")), ValueField("fingerprint", textValue("fixture")),
                ValueField("schema_digest", textValue(schemaDigest))]))]))
        plans = DurablePlanExecutionStore(database, knownParentAllocation: Some(allocate))
        plans.activate("guard-execution", thread.value, PlanContract(["/workspace"],
            [PlanExecutionStep(PlanStepId("source"), [], true, [action])])).value().getOrThrow()
        let turn = SemanticTurnId("large-lane-turn")
        let active = runtime.startTurn(turn, run, ItemId("large-lane-user"),
            ThreadItemContent.UserMessage(textMessageParts("inspect source")), lane, InvocationContextProjection()).value().getOrThrow()
        let item = ItemId("large-lane-call")
        let committed = runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
            ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId("large-lane-call"), "read", arguments),
                ItemProvenance("direct_tool", runId: Some(run), operationId: Some(operation)))))
        match (committed) { case SemanticCommitDecision.Committed(_, _) => ()
            case _ => throw IllegalStateException("large catalog fixture failed its actual canonical ToolCall") }
        let direct = runtime.attestDirectToolCall(item, operation, run, active.epoch).value().getOrThrow()
        source = OperationRootSource.Direct(direct)
        plan = NormalizedOperationPlan("read", arguments, [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "large-lane-binding", cwd: "/workspace",
            resolvedPaths: ["/workspace/source"], toolVersion: if (matching) { "1" } else { "different-version" },
            implementationFingerprint: "fixture", schemaDigest: schemaDigest,
            policyVersion: if (review) { "tool-policy-plan-review-v1" } else { "tool-policy-v1" })
        operations = DurableOperationStore(database,
            documentPayloadAllocation: match (nativeAllocation) { case Some(value) => Some(value); case None => Some(allocate) },
            planExecutionAllocation: planAllocation)
        operations.prepareDirectOperation(direct, plan).value().getOrThrow()
        if (!review) {
            plans.bindRun("guard-execution", thread.value, run).value().getOrThrow()
            plans.admit(run, operation, "source", "inspect", plan).value().getOrThrow()
        }
    }
    func enter(): Result<Unit> {
        operations.markExecutingWithSource(Some(source), operation, run, plan, 11, false)
    }
    func close(): Unit { database.close(); remove(path, recursive: true) }
}

private func largeLaneGuardFrame204(original: LogicalJsonOwnerReservation, review: Bool, matching: Bool): Bool {
    let fixture = LargeLanePlanGuardFixture204(original, review, matching)
    try {
        let bytes = fixture.database.scalarInt("SELECT length(CAST(lane_snapshot AS BLOB)) FROM runs WHERE id='large-lane-run'")
        // The previous unconditional byte*2048 invoice alone exceeded the
        // unchanged 144 MiB bank even before the additive contract/fact peak.
        @Expect(bytes > 73216)
        let before = original.retainedCustodyUsage113()[0]
        let result = fixture.enter()
        if (matching) {
            @Expect(result.isOk())
            @Expect(fixture.operations.markExecutionHandoffWithSource(Some(fixture.source), fixture.operation,
                fixture.run, fixture.thread, 12).isOk())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
        } else {
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().message.contains("trusted frozen catalog identity"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='prepared'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
        }
        original.retainedCustodyUsage113()[0] == before
    } finally { fixture.close() }
}

private func largeLanePressureFrame204(original: LogicalJsonOwnerReservation, bank: LogicalJsonOwnerBudget): Bool {
    let fixture = LargeLanePlanGuardFixture204(original, true, true)
    try {
        let pressure = original.deriveRetainedLease()
        pressure.ensureRetainedPeak(bank.capacity() - original.retainedCustodyUsage113()[0] - 2048)
        let before = original.retainedCustodyUsage113()
        let beforeBank = bank.usage()
        let result = fixture.enter()
        let after = original.retainedCustodyUsage113()
        // Deriving a failed phase may legitimately raise the original bank's
        // fixed high-water charge. Its active DATA sum and lease count must
        // still return exactly; the full original frame later refunds cost.
        let unchanged = result.isError() && after[0] == before[0] && after[2] == before[2] &&
            bank.usage()[0] == beforeBank[0] && bank.usage()[1] >= beforeBank[1] && bank.usage()[1] <= bank.capacity() &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='prepared'") == 1 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0
        pressure.close()
        unchanged && fixture.enter().isOk()
    } finally { fixture.close() }
}

@Test
class PlanPreEffectCatalogInvoice204Tests {
    @TestCase
    func GenericAdmittedOperationDoesNotReadOrPriceUnusedLargeCatalog(): Unit {
        let bank = LogicalJsonOwnerBudget(); let original = bank.acquire(131072)
        let result = largeLaneGuardFrame204(original, false, true)
        original.close()
        @Expect(result); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func ActualReviewLargeCatalogKeepsCompleteFrozenIdentityValidation(): Unit {
        let bank = LogicalJsonOwnerBudget(); let original = bank.acquire(131072)
        let valid = largeLaneGuardFrame204(original, true, true)
        let mismatch = largeLaneGuardFrame204(original, true, false)
        original.close()
        @Expect(valid && mismatch); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func ActualReviewOriginalBankPressureRefusesBeforeHandoffWithoutLeak(): Unit {
        let bank = LogicalJsonOwnerBudget(); let original = bank.acquire(131072)
        let result = largeLanePressureFrame204(original, bank)
        original.close()
        @Expect(result); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}

private func paidRequestParityInner204(request: PlanExecutionReadConsumer204,
    inspection: PlanExecutionReadConsumer204, payment: LogicalJsonOwnerReservation): Bool {
    let actual = request.value204(); let source = inspection.value204()
    let meter = ToolSnapshotMeasure159(payment)
    meter.addValue159(source); meter.addValue159(actual); meter.fund159()
    let expected = approvedPlanRequestView(source)
    canonicalAgentValue(actual) == canonicalAgentValue(expected)
}
private func paidRequestParity204(requestOwner: PlanExecutionReadOwner204,
    publicOwner: PlanExecutionReadOwner204, payer: LogicalJsonOwnerReservation): Bool {
    let request = requestOwner.beginConsumer204(); let inspection = publicOwner.beginConsumer204()
    let copies = planReadAllocation204(payer, 131072)
    let result = paidRequestParityInner204(request, inspection, copies)
    copies.close()
    request.returnConsumerFrame204(); inspection.returnConsumerFrame204()
    requestOwner.closeAfterCaller204(); publicOwner.closeAfterCaller204(); result
}

private func accumulatedGuardRequire204<T>(result: Result<T>): T {
    match (result) { case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("accumulated guard fixture: " + error.code) }
}

// Uses the same two existing funding roles as production: the plan/catalog
// payer owns approved-contract reads; the unchanged 16 MiB Native document
// payer alone owns Operation pre-effect checks. Neither source funds the other.
private func accumulatedNativeGuardFrame204(catalog: LogicalJsonOwnerReservation,
    native: LogicalJsonOwnerReservation): Bool {
    catalog.ensureRetainedPeak(4194304)
    // Initialize the original custody ledger before the no-leak baseline;
    // its fixed header remains paid until this real original closes.
    let initializedNative = native.deriveRetainedLease(); initializedNative.close()
    let catalogAllocate = { bytes: Int64 => planReadAllocation204(catalog, bytes) }
    let nativeAllocate = { bytes: Int64 => planReadAllocation204(native, bytes) }
    let path = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
    let database = SqliteDatabase(path + "/plan.sqlite")
    try {
        let thread = ThreadId("accumulated-native-thread"); let run = RunId("accumulated-native-run")
        let turn = SemanticTurnId("accumulated-native-turn")
        let sink = SqliteThreadCommitSink(database, knownParentAllocation: Some(catalogAllocate))
        let coordinator = ThreadCoordinator(sink.createThread(thread, "/workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("accumulated", PlanGuardEstimator204()), { => 10 })
        let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system")
        let active = runtime.startTurn(turn, run, ItemId("accumulated-user"),
            ThreadItemContent.UserMessage(textMessageParts("perform approved independent work")), lane,
            InvocationContextProjection()).value().getOrThrow()
        let operations = DurableOperationStore(database, documentPayloadAllocation: Some(nativeAllocate))
        let actualLane = operations.pluginDocumentLane(thread, run, active.epoch).value().getOrThrow()
        let digest = modelPolicySha256Text("accumulated Native fixture")
        let plans = DurablePlanExecutionStore(database, knownParentAllocation: Some(catalogAllocate))
        let tool = "plugin.axyndra:workflow.task"
        let nativePlans = ArrayList<NormalizedOperationPlan>()
        let nativeIds = ArrayList<OperationId>()
        let steps = ArrayList<PlanExecutionStep>()
        let pins = { name: String => objectValue([ValueField(name, objectValue([
            ValueField("version", textValue("fixture")), ValueField("fingerprint", textValue("frozen-fixture")),
            ValueField("schema_digest", textValue(digest))]))]) }
        for (index in 0..3) {
            let suffix = index.toString(); let call = "accumulated-call-" + suffix
            let operation = OperationId("accumulated-operation-" + suffix)
            let item = ItemId("accumulated-item-" + suffix)
            let input = objectValue([ValueField("context", textValue(String.fromUtf8(Array<Byte>(6000, repeat: b'x'))))])
            match (runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, index + 1,
                ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call), tool, input),
                    ItemProvenance("direct_tool", runId: Some(run), operationId: Some(operation)))))) {
                case SemanticCommitDecision.Committed(_, _) => ()
                case _ => throw IllegalStateException("accumulated canonical call failed") }
            let direct = runtime.attestDirectToolCall(item, operation, run, active.epoch).value().getOrThrow()
            let binding = objectValue([ValueField("namespace", textValue("axyndra:workflow")),
                ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("1")),
                ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue(thread.value)),
                ValueField("lane_id", textValue(actualLane.value)), ValueField("run_id", textValue(run.value)),
                ValueField("epoch", integerValue(active.epoch)), ValueField("parent_call_id", textValue(call)),
                ValueField("contribution", textValue(tool)), ValueField("implementation_fingerprint", textValue("frozen-fixture")),
                ValueField("schema_digest", textValue(digest))])
            let completion = objectValue([])
            let intent = objectValue([ValueField("id", textValue("start-0")), ValueField("service", textValue("child.start")),
                ValueField("input", objectValue([ValueField("request", objectValue([
                    ValueField("label", textValue("one")), ValueField("description", textValue("approved child")),
                    ValueField("prompt", input.field("context").getOrThrow()), ValueField("system_prompt", textValue("")),
                    ValueField("model_alias", textValue("")), ValueField("thinking", textValue("")), ValueField("cache_key", textValue("")),
                    ValueField("capability_ceiling", listValue([])), ValueField("requested_limits", objectValue([])),
                    ValueField("background", boolValue(false))])), ValueField("completion", objectValue([
                        ValueField("provider", textValue("propose")), ValueField("input", completion),
                        ValueField("input_sha256", textValue(modelPolicySha256Text(canonicalAgentValue(completion))))]))]))])
            let arguments = objectValue([ValueField("input", input), ValueField("configuration", objectValue([])),
                ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_PRIMITIVE_PARENT111)),
                    ValueField("binding", binding), ValueField("intents", listValue([intent]))]))])
            let normalized = NormalizedOperationPlan(tool, arguments,
                [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow"), Capability(CapabilityKind.Delegate)],
                OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never,
                modelPolicySha256Text(canonicalAgentValue(arguments)),
                replayDisposition: Some(ReplayDisposition.NeverReplay), toolVersion: "fixture",
                implementationFingerprint: "frozen-fixture", schemaDigest: digest)
            @Expect(isFrozenPluginChildParent111(normalized))
            operations.prepareDirectOperation(direct, normalized).value().getOrThrow()
            nativePlans.add(normalized); nativeIds.add(operation)
            steps.add(PlanExecutionStep(PlanStepId("native-" + suffix), [], false,
                [PlanAction("native-" + suffix, [tool], ["denied"], OperationEffectClass.ExternalMutation,
                    input, 1, exactArguments: true, toolIdentities: pins(tool), delegatedActionIds: ["probe"])]))
        }
        let probeInput = objectValue([ValueField("executable", textValue("/usr/bin/true")), ValueField("argv", listValue([]))])
        let probe = NormalizedOperationPlan("command_probe", probeInput, [Capability(CapabilityKind.ProcessSpawn)],
            OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never, "accumulated-probe-binding",
            cwd: "/workspace", approvedWriteRoots: ["/workspace"], toolVersion: "fixture",
            implementationFingerprint: "frozen-fixture", schemaDigest: digest)
        steps.add(PlanExecutionStep(PlanStepId("probe"), [], true, [PlanAction("probe", ["command_probe"], ["denied"],
            OperationEffectClass.ExternalMutation, probeInput, 1, exactArguments: true, toolIdentities: pins("command_probe"))]))
        accumulatedGuardRequire204(plans.bind("accumulated-execution", thread.value, run, PlanContract(["/workspace"], steps.toArray())))
        for (index in 0..3) {
            let id = "native-" + index.toString()
            accumulatedGuardRequire204(plans.admit(run, nativeIds[index], id, id, nativePlans[index]))
        }
        // Direct production shares the public canonical fold and action
        // serializer, while omitting all non-runnable task argument bodies.
        @Expect(paidRequestParity204(plans.openRequest204(run, native).value().getOrThrow(),
            plans.openInspection204(run, catalog).value().getOrThrow(), catalog))
        let probeId = OperationId("accumulated-probe"); let probeItem = ItemId("accumulated-probe-item")
        match (runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 4,
            ThreadItemDraft(probeItem, ThreadItemContent.ToolCall(CanonicalToolCallId("accumulated-probe"), "command_probe", probeInput),
                ItemProvenance("direct_tool", runId: Some(run), operationId: Some(probeId)))))) {
            case SemanticCommitDecision.Committed(_, _) => ()
            case _ => throw IllegalStateException("accumulated probe call failed") }
        let direct = runtime.attestDirectToolCall(probeItem, probeId, run, active.epoch).value().getOrThrow()
        operations.prepareDirectOperation(direct, probe).value().getOrThrow()
        accumulatedGuardRequire204(plans.admit(run, probeId, "probe", "probe", probe))
        let before = native.retainedCustodyUsage113()[0]
        let admitted = operations.markExecutingWithSource(Some(OperationRootSource.Direct(direct)), probeId, run, probe, 11, false)
        @Expect(admitted.isOk())
        @Expect(operations.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(direct)), probeId, run, thread, 12).isOk())
        @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 4)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
        // These production closed reads need their actual contract/facts, not
        // the much larger public member view. All use this same 16 MiB payer.
        @Expect(plans.canContinue204(run, native).isOk())
        @Expect(plans.requireComplete204(run, native).error().getOrThrow().code, "plan.evidence_incomplete")
        @Expect(plans.validateContextResource204(run, "/workspace/source", native).isOk())
        let observed = plans.observe204(run, probeId, native).value().getOrThrow()
        observed.closeAfterCaller204()
        @Expect(consumePaidPlanDispatch204(plans.openBinding204(run, native).value().getOrThrow(), false))
        @Expect(consumePaidPlanDispatch204(plans.openRequest204(run, native).value().getOrThrow(), true))
        // Public inspection now measures its real complete graph instead of
        // assuming one DOM node per input byte. Refusal must follow actual
        // original-bank pressure, not the former inflated byte multiplier.
        let publicPressure = native.deriveRetainedLease()
        publicPressure.ensureRetainedPeak(14000000)
        let publicBefore = native.retainedCustodyUsage113()
        @Expect(plans.openInspection204(run, native).isError())
        let publicAfter = native.retainedCustodyUsage113()
        @Expect(publicBefore[0], publicAfter[0]); @Expect(publicBefore[2], publicAfter[2])
        @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 4)
        publicPressure.close()
        native.retainedCustodyUsage113()[0] == before
    } finally { database.close(); remove(path, recursive: true) }
}

@Test
class PlanPreEffectAccumulatedInvoice204Tests {
    @TestCase
    func SmallOriginalNativeBankAdmitsProbeAfterAccumulatedFrozenPlans(): Unit {
        let catalogBank = LogicalJsonOwnerBudget(); let catalog = catalogBank.acquire(131072)
        let nativeBank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let native = nativeBank.acquire(131072)
        let result = accumulatedNativeGuardFrame204(catalog, native)
        catalog.close(); native.close()
        @Expect(result)
        @Expect(catalogBank.usage()[0], 0); @Expect(catalogBank.usage()[1], 0)
        @Expect(nativeBank.usage()[0], 0); @Expect(nativeBank.usage()[1], 0)
    }
}


private func sameBankDerivedGuardFrame204(bank: LogicalJsonOwnerBudget,
    original: LogicalJsonOwnerReservation): Bool {
    let documentCalls = Array<Int64>(1, repeat: 0)
    let fixture = LargeLanePlanGuardFixture204(original, false, true,
        nativeAllocation: Some({ bytes: Int64 => documentCalls[0]++; bank.acquire(bytes) }),
        planAllocation: Some({ bytes: Int64 => planReadAllocation204(original, bytes) }))
    try {
        // Both reservations belong to the SAME unchanged production-sized
        // bank. The other existing owner plus original custody leave less than
        // one 16 MiB root floor, while a measured derived guard still fits.
        original.ensureRetainedPeak(125829120)
        let otherOwner = bank.acquire(1)
        try {
            var freshRefused = false
            try { let unused = bank.acquire(131072); unused.close() }
            catch (_: LogicalJsonPayloadError) { freshRefused = true }
            @Expect(freshRefused)
            let pressure = original.deriveRetainedLease()
            pressure.ensureRetainedPeak(8384512)
            let before = original.retainedCustodyUsage113()
            @Expect(fixture.plans.openInspection204(fixture.run, original).isError())
            @Expect(fixture.plans.openRequest204(fixture.run, original).isError())
            @Expect(fixture.plans.openBinding204(fixture.run, original).isError())
            @Expect(fixture.plans.canContinue204(fixture.run, original).isError())
            let admissionDenied = fixture.plans.admit(fixture.run, fixture.operation, "source", "inspect", fixture.plan)
            @Expect(admissionDenied.isError())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 1)
            let denied = fixture.enter()
            let after = original.retainedCustodyUsage113()
            @Expect(denied.isError())
            @Expect(before[0], after[0]); @Expect(before[2], after[2])
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='prepared'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            // A present derived source is authoritative for DATA funding:
            // pressure never falls back to the document/root allocator.
            @Expect(documentCalls[0], 0)
            pressure.close()
            @Expect(consumePaidPlanDispatch204(fixture.plans.openRequest204(fixture.run, original).value().getOrThrow(), true))
            @Expect(consumePaidPlanDispatch204(fixture.plans.openBinding204(fixture.run, original).value().getOrThrow(), false))
            @Expect(fixture.plans.canContinue204(fixture.run, original).isOk())
            @Expect(fixture.plans.admit(fixture.run, fixture.operation, "source", "inspect", fixture.plan).isOk())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 1)
            @Expect(fixture.enter().isOk())
            @Expect(fixture.operations.markExecutionHandoffWithSource(Some(fixture.source), fixture.operation,
                fixture.run, fixture.thread, 12).isOk())
            @Expect(documentCalls[0], 0)
            true
        } finally { otherOwner.close() }
    } finally { fixture.close() }
}

@Test
class PlanPreEffectSharedOriginalInvoice204Tests {
    @TestCase
    func ExistingOriginalCustodyAvoidsNewRootFloorAndStillEnforcesAggregatePressure(): Unit {
        let bank = LogicalJsonOwnerBudget(); let original = bank.acquire(131072)
        let result = sameBankDerivedGuardFrame204(bank, original)
        original.close()
        @Expect(result); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}


@Test
class PlanSessionPresence204Tests {
    @TestCase
    func ExactMappingsIncludeSealedOrUnreadableContractsWithoutAnOwner(): Unit {
        let path = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let database = SqliteDatabase(path + "/presence.sqlite")
        try {
            let store = DurablePlanExecutionStore(database)
            let presence: PlanExecutionSessionPresence204 = store
            @Expect(presence.sessionHasExecution204("session").value().getOrThrow(), false)
            @Expect(store.activate("approved", "session", paidPlanReadContract204()).isOk())
            @Expect(presence.sessionHasExecution204("session").value().getOrThrow(), true)
            @Expect(presence.sessionHasExecution204("other").value().getOrThrow(), false)
            @Expect(presence.sessionHasExecution204("session' OR 1=1 --").value().getOrThrow(), false)
            // Deliberately inconsistent persisted data must remain present.
            // This is a refusal regression, not an alternate seal/approval API.
            database.execute("UPDATE plan_executions SET sealed=1,contract='unreadable' WHERE id='approved'")
            let reopened = DurablePlanExecutionStore(database)
            @Expect(reopened.sessionHasExecution204("session").value().getOrThrow(), true)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_execution_sessions"), 1)
            @Expect(database.query("SELECT sealed,contract FROM plan_executions WHERE id='approved'")[0].required(0), "1")
            @Expect(database.query("SELECT sealed,contract FROM plan_executions WHERE id='approved'")[0].required(1), "unreadable")
        } finally { database.close(); remove(path, recursive: true) }
    }

    @TestCase
    func MissingPresenceTableFailsClosedWithOnlyFixedErrorData(): Unit {
        let path = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let database = SqliteDatabase(path + "/presence.sqlite")
        try {
            let store = DurablePlanExecutionStore(database)
            database.execute("DROP TABLE plan_execution_sessions")
            let result = store.sessionHasExecution204("private-session-input")
            @Expect(result.isError())
            let error = result.error().getOrThrow()
            @Expect(error.code, "plan.session_presence_unavailable")
            @Expect(error.message, "Approved scope presence could not be checked")
            @Expect(error.fields.isEmpty())
            @Expect(error.attemptFailure.isNone() && error.observation.isNone())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_executions"), 0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions"), 0)
        } finally { database.close(); remove(path, recursive: true) }
    }
}
