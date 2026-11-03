package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import yjson.*
import yjson_support.*

func readonlyTreeWorkspacePlan(): NormalizedOperationPlan {
    let original = readViewContractRootPlan()
    NormalizedOperationPlan(original.toolName, original.canonicalArguments, original.requiredCapabilities,
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "workspace-exact-plan",
        toolVersion: "workspace-v1", implementationFingerprint: original.implementation.implementationFingerprint,
        schemaDigest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        replayDisposition: Some(ReplayDisposition.NeverReplay))
}

func readonlyTreeProgramPlan(): NormalizedOperationPlan {
    let child = readonlyTreeWorkspacePlan()
    let host = child.canonicalArguments.field("host_plan").getOrThrow()
    let entry = objectValue([ValueField("alias", textValue("read")), ValueField("name", textValue(child.toolName)),
        ValueField("version", textValue(child.implementation.toolVersion)),
        ValueField("fingerprint", textValue(child.implementation.implementationFingerprint)),
        ValueField("schema_digest", textValue(child.implementation.schemaDigest)),
        ValueField("package_digest", host.field("package_digest").getOrThrow()), ValueField("generation", textValue("1")),
        ValueField("services", listValue([textValue("process.readview")]))])
    let arguments = objectValue([ValueField("input", objectValue([ValueField("source", textValue("workspace.read()"))])),
        ValueField("host_plan", objectValue([
            ValueField("version", textValue(HOST_READONLY_DELEGATION_VERSION)), ValueField("plugin", textValue("axyndra:program")),
            ValueField("package_digest", textValue("sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd")),
            ValueField("generation", textValue("1")), ValueField("configuration_digest", textValue("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")),
            ValueField("contribution", textValue("run")), ValueField("tool_set_id", textValue("actual-fixture-snapshot")),
            ValueField("tools", listValue([entry])), ValueField("max_calls", integerValue(1)), ValueField("max_depth", integerValue(2))]))])
    NormalizedOperationPlan("plugin.axyndra:program.run", arguments,
        [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead)],
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "program-exact-plan",
        implementationFingerprint: "axyndra:program:sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        replayDisposition: Some(ReplayDisposition.NeverReplay))
}

class ReadonlyTreeFixture {
    let directory: String
    let database: SqliteDatabase
    let runtime: AgentThreadRuntime
    let store: DurableOperationStore
    let source: OperationRootSource
    let epoch: Int64
    let thread = ThreadId("tree-thread")
    let run = RunId("tree-run")
    let root = OperationId("tree-root")
    let child = OperationId("tree-workspace")
    let leaf = OperationId("tree-readview")
    let rootPlan: NormalizedOperationPlan
    let childPlan: NormalizedOperationPlan
    let leafPlan: NormalizedOperationPlan
    init(committed: Bool, rootHandoff: Bool) {
        let directoryValue = Directory.createTemp("/tmp").toString()
        let db = SqliteDatabase(directoryValue + "/state.db")
        let sink = SqliteThreadCommitSink(db)
        let coordinator = ThreadCoordinator(sink.createThread(ThreadId("tree-thread"), "/workspace"), sink)
        let rt = AgentThreadRuntime(coordinator, ContextProjector("readonly-tree", StoreEstimator()), { => 10 })
        let active = rt.startTurn(SemanticTurnId("tree-turn"), RunId("tree-run"), ItemId("tree-user"),
            ThreadItemContent.UserMessage(textMessageParts("readonly tree")), recoveryLane(), InvocationContextProjection()).value().getOrThrow()
        let port = DurableOperationStore(db)
        let plan = readonlyTreeProgramPlan()
        let call = ToolCall("program-call", plan.toolName, plan.canonicalArguments.field("input").getOrThrow())
        let actualSource: OperationRootSource
        if (committed) {
            let actual = commitDurableToolCall(db, coordinator, ThreadId("tree-thread"), SemanticTurnId("tree-turn"),
                RunId("tree-run"), active.epoch, 1, ItemId("tree-call-item"), call.callId, call.name, call.arguments, 10)
            actualSource = OperationRootSource.Committed(actual)
            port.prepare(OperationId("tree-root"), RunId("tree-run"), actual, plan).value().getOrThrow()
        } else {
            expect(isStoreCommitted(rt.commitResult(ResultEnvelope(ThreadId("tree-thread"), SemanticTurnId("tree-turn"),
                RunId("tree-run"), active.epoch, 1, ThreadItemDraft(ItemId("tree-call-item"),
                    ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                    ItemProvenance("direct_tool", runId: Some(RunId("tree-run")), operationId: Some(OperationId("tree-root"))))))),
                "readonly tree starts with a real canonical Direct call")
            actualSource = OperationRootSource.Direct(rt.attestDirectToolCall(ItemId("tree-call-item"), OperationId("tree-root"),
                RunId("tree-run"), active.epoch).value().getOrThrow())
            port.prepareTrustedControlOperation(OperationId("tree-root"), RunId("tree-run"), ItemId("tree-call-item"), plan).value().getOrThrow()
        }
        port.markExecutingWithSource(Some(actualSource), OperationId("tree-root"), RunId("tree-run"), plan, 11, false).value().getOrThrow()
        if (rootHandoff) { port.markExecutionHandoffWithSource(Some(actualSource), OperationId("tree-root"), RunId("tree-run"),
            ThreadId("tree-thread"), 12).value().getOrThrow() }
        directory = directoryValue; database = db; runtime = rt; store = port; source = actualSource; epoch = active.epoch
        rootPlan = plan; childPlan = readonlyTreeWorkspacePlan(); leafPlan = readViewContractChildPlan("completed")
    }
    func admitWorkspace(operation: OperationId, callId: String): Result<OperationId> {
        store.prepareDerivedInvocation(operation, root, run, source, readonlyDelegationRequestKey("program-call", callId),
            ToolCall(callId, childPlan.toolName, childPlan.canonicalArguments), childPlan)
    }
    func admitLeaf(parent: OperationId, key: String): Result<OperationId> {
        store.prepareDerivedInvocation(leaf, parent, run, source, key,
            ToolCall("worker-call", leafPlan.toolName, leafPlan.canonicalArguments), leafPlan)
    }
    func executeChild(handoff: Bool): Unit {
        store.markExecutingWithSource(Some(source), child, run, childPlan, 13, false).value().getOrThrow()
        if (handoff) { store.markExecutionHandoffWithSource(Some(source), child, run, thread, 14).value().getOrThrow() }
    }
    func settle(operation: OperationId, parent: OperationId, outcome: OperationOutcome): Result<Unit> {
        let row = database.query("SELECT reserved_receipt_id FROM operation_effect_records WHERE operation_id=?",
            [SqlParameter.Text(operation.value)])[0]
        store.settleDerivedOperation(run, parent, VNextOperationReceipt(row.required(0), operation, outcome,
            objectValue([ValueField("fixture", boolValue(true))]), objectValue([]), 20))
    }
    func settleRootUnknown(): Unit {
        let resolved = runtime.resolveOperation(ItemId("result-tree-root"), root, CanonicalToolCallId("program-call"),
            rootPlan, OperationAttemptStage.Executing, Result<ToolInvocationResult>.Err(AgentError(
                AgentErrorKind.RecoveryRequired, "tree.cleanup_pending", "descendant cleanup remains owned")),
            "receipt-tree-root", 20, expectedRunId: Some(run), expectedEpoch: Some(epoch)).value().getOrThrow()
        expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()) &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='tree-root' AND outcome='unknown'") == 1,
            "actual Runtime atomically commits the root Unknown Receipt and canonical ToolResult")
    }
    func close(): Unit { database.close(); remove(directory, recursive: true) }
}

func readonlyDerivedTreeContracts(): Unit {
    for (committed in [false, true]) {
        for (scenario in ["normal", "no-root-handoff", "no-child-handoff", "legacy-api", "wrong-key", "duplicate-call",
            "width", "depth", "root-plan", "child-plan", "epoch", "missing-root-proof", "missing-leaf-proof", "legacy-row",
            "parent-unknown", "parent-pending", "cancel-before-leaf", "cancel-after-leaf",
            "late-unknown", "late-rejected", "root-late-unknown", "root-late-rejected",
            "late-known-receipt", "late-missing-receipt", "late-receipt-identity", "late-missing-handoff"]) {
            let f = ReadonlyTreeFixture(committed, scenario != "no-root-handoff")
            let label = (if (committed) { "Committed " } else { "Direct " }) + scenario
            try {
                if (scenario == "legacy-api") {
                    expect(f.store.prepareDerivedOperation(f.child, f.root, f.run, f.source,
                        readonlyDelegationRequestKey("program-call", "workspace-call"), f.childPlan).isError() &&
                        f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0,
                        label + " primitive compatibility API cannot fabricate a tree call identity")
                    continue
                }
                let admission = f.admitWorkspace(f.child, "workspace-call")
                if (scenario == "no-root-handoff") {
                    expect(admission.isError() && f.database.scalarInt("SELECT COUNT(*) FROM operations") == 1,
                        label + " no child record before the actual root handoff")
                    continue
                }
                expect(admission.isOk(), label + " actual frozen root admits the installed readonly contribution")
                if (scenario == "duplicate-call" || scenario == "width") {
                    let callId = if (scenario == "duplicate-call") { "workspace-call" } else { "workspace-call-2" }
                    let result = f.admitWorkspace(OperationId("tree-other"), callId)
                    expect(if (scenario == "duplicate-call") { result.isOk() && result.value().getOrThrow().value == f.child.value }
                        else { result.isError() }, label + " existing identity observes once; new work consumes immutable width")
                    expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 1,
                        label + " bounded admission never creates another record")
                    continue
                }
                f.executeChild(scenario != "no-child-handoff")
                if (scenario == "root-plan") { f.database.execute("UPDATE operations SET normalized_plan='corrupt' WHERE id='tree-root'") }
                if (scenario == "child-plan") { f.database.execute("UPDATE operations SET normalized_plan='corrupt' WHERE id='tree-workspace'") }
                if (scenario == "epoch") { f.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='tree-run'") }
                if (scenario == "missing-root-proof") { f.database.execute("DELETE FROM audit_events WHERE operation_id='tree-workspace' AND kind='operation_parent_intent_authorized'") }
                if (scenario == "legacy-row") { f.database.execute("UPDATE derived_operation_admissions SET child_call_id='',root_operation_id='',depth=0 WHERE operation_id='tree-workspace'") }
                if (scenario == "cancel-before-leaf") { f.database.execute("UPDATE runs SET state='cancelling' WHERE id='tree-run'") }
                let key = if (scenario == "wrong-key") { "javascript-service:program-call:view" }
                    else { "javascript-service:workspace-call:view" }
                let leaf = f.admitLeaf(f.child, key)
                if (["no-child-handoff", "root-plan", "child-plan", "epoch", "missing-root-proof", "legacy-row", "cancel-before-leaf", "wrong-key"].contains(scenario)) {
                    expect(leaf.isError() && f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='tree-readview'") == 0,
                        label + " every ancestor, immediate identity, epoch and effect record is required")
                    continue
                }
                expect(leaf.isOk() && f.store.loadCall(f.leaf, f.run).value().getOrThrow().callId == "worker-call",
                    label + " grandchild stores and loads its actual host call identity")
                let row = f.database.query("SELECT root_operation_id,depth FROM derived_operation_admissions WHERE operation_id='tree-readview'")[0]
                expect(row.required(0) == f.root.value && row.required(1) == "2", label + " uses one existing canonical root and depth two")
                if (scenario == "missing-leaf-proof") {
                    f.database.execute("DELETE FROM audit_events WHERE operation_id='tree-readview' AND kind='operation_parent_intent_authorized'")
                    expect(f.store.markExecutingWithSource(Some(f.source), f.leaf, f.run, f.leafPlan, 15, false).isError(),
                        label + " execution revalidates the complete recorded parent authorization")
                    continue
                }
                if (scenario == "parent-pending") {
                    expect(f.settle(f.child, f.root, OperationOutcome.Completed).isError() &&
                        f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
                        label + " known parent cannot wash its unexecuted outstanding child")
                    continue
                }
                if (scenario != "late-rejected" && scenario != "root-late-rejected") {
                    f.store.markExecutingWithSource(Some(f.source), f.leaf, f.run, f.leafPlan, 15, false).value().getOrThrow()
                    f.store.markExecutionHandoffWithSource(Some(f.source), f.leaf, f.run, f.thread, 16).value().getOrThrow()
                }
                if (scenario.startsWith("late-") || scenario.startsWith("root-late-")) {
                    if (scenario.startsWith("root-late-")) { f.settleRootUnknown() }
                    f.settle(f.child, f.root, OperationOutcome.Unknown).value().getOrThrow()
                    expect(f.admitLeaf(f.child, "javascript-service:workspace-call:view").isError() &&
                        f.store.markExecutingWithSource(Some(f.source), f.leaf, f.run, f.leafPlan, 21, false).isError() &&
                        f.store.markExecutionHandoffWithSource(Some(f.source), f.leaf, f.run, f.thread, 21).isError(),
                        label + " Unknown ancestors never permit new admission, execution or handoff")
                    expect(f.settle(f.leaf, f.child, OperationOutcome.Completed).isError(),
                        label + " late cleanup cannot turn the uncertain ancestor chain into a known success")
                    if (scenario == "late-known-receipt") {
                        f.database.execute("UPDATE operation_receipts SET outcome='completed' WHERE operation_id='tree-workspace'")
                    }
                    if (scenario == "late-missing-receipt") {
                        f.database.execute("DELETE FROM operation_receipts WHERE operation_id='tree-workspace'")
                    }
                    if (scenario == "late-receipt-identity") {
                        f.database.execute("UPDATE operation_receipts SET id='foreign-receipt' WHERE operation_id='tree-workspace'")
                    }
                    if (scenario == "late-missing-handoff") {
                        f.database.execute("DELETE FROM audit_events WHERE operation_id='tree-workspace' AND kind='operation_execution_handoff'")
                    }
                    let rejected = scenario == "late-rejected" || scenario == "root-late-rejected"
                    let settled = f.settle(f.leaf, f.child, if (rejected) { OperationOutcome.Rejected } else { OperationOutcome.Unknown })
                    let corrupted = ["late-known-receipt", "late-missing-receipt", "late-receipt-identity", "late-missing-handoff"].contains(scenario)
                    expect(settled.isError() == corrupted && f.database.scalarInt(
                        "SELECT COUNT(*) FROM operation_receipts WHERE operation_id='tree-readview'") == (if (corrupted) { 0 } else { 1 }),
                        label + " late cleanup still requires the exact original handoff and one reserved Unknown Receipt")
                    if (!corrupted) {
                        expect(f.settle(f.leaf, f.child, if (rejected) { OperationOutcome.Rejected } else { OperationOutcome.Unknown }).isError(),
                            label + " cleanup settlement cannot be replayed")
                    }
                    continue
                }
                if (scenario == "depth") {
                    expect(f.store.prepareDerivedInvocation(OperationId("tree-too-deep"), f.leaf, f.run, f.source,
                        "javascript-service:worker-call:view", ToolCall("too-deep-call", f.leafPlan.toolName, f.leafPlan.canonicalArguments), f.leafPlan).isError() &&
                        f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 2,
                        label + " terminal readview cannot become another delegation or recursive service")
                    continue
                }
                let uncertain = scenario == "parent-unknown" || scenario == "cancel-after-leaf"
                if (scenario == "cancel-after-leaf") { f.database.execute("UPDATE runs SET state='cancelling' WHERE id='tree-run'") }
                f.settle(f.leaf, f.child, if (uncertain) { OperationOutcome.Unknown } else { OperationOutcome.Completed }).value().getOrThrow()
                if (uncertain) { expect(f.settle(f.child, f.root, OperationOutcome.Completed).isError(),
                    label + " parent success cannot wash an Unknown child receipt") }
                f.settle(f.child, f.root, if (uncertain) { OperationOutcome.Unknown } else { OperationOutcome.Completed }).value().getOrThrow()
                expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 2 &&
                    f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") == 1,
                    label + " descendant receipts remain in the sole operation ledger without fake canonical calls")
                expect(f.store.markExecutingWithSource(Some(f.source), f.leaf, f.run, f.leafPlan, 21, false).isError(),
                    label + " completed or uncertain bytes cannot be executed twice")
                let reopened = SqliteDatabase(f.directory + "/state.db")
                try { expect(DurableOperationStore(reopened).loadCall(f.leaf, f.run).value().getOrThrow().callId == "worker-call",
                    label + " history reopens descriptive actual identity without restoring execution authority") }
                finally { reopened.close() }
            } finally { f.close() }
        }
    }
    println("Bounded readonly derived tree contract passed: 52 scenarios")
}
