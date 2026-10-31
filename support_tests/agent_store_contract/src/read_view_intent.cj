package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import yjson.*
import yjson_support.*

func readViewContractArguments(): AgentValue {
    let resource = objectValue([ValueField("kind", textValue("file")), ValueField("source", textValue("/workspace/public.txt")),
        ValueField("path", textValue("target")), ValueField("witness", textValue("f:1:2:384:5:1:0:1:0")),
        ValueField("bytes", integerValue(5)), ValueField("permission", textValue("workspace.read"))])
    let intent = objectValue([ValueField("id", textValue("view")), ValueField("request", objectValue([
        ValueField("executable", textValue("bin/worker")), ValueField("arguments", listValue([])), ValueField("timeout_ms", integerValue(1000))])),
        ValueField("resources", listValue([resource])), ValueField("requires_approval", boolValue(false))])
    objectValue([ValueField("input", objectValue([ValueField("path", textValue("public.txt"))])), ValueField("host_plan", objectValue([
        ValueField("version", textValue(HOST_READ_VIEW_VERSION)), ValueField("plugin", textValue("axyndra:read-view-contract")),
        ValueField("package_digest", textValue("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
        ValueField("generation", textValue("1")), ValueField("configuration_digest", textValue("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")),
        ValueField("contribution", textValue("read")), ValueField("read_granted", boolValue(true)),
        ValueField("tool_payload_limits", nullValue()), ValueField("intents", listValue([intent]))]))])
}
func readViewContractRootPlan(): NormalizedOperationPlan {
    NormalizedOperationPlan("plugin.axyndra:read-view-contract.read", readViewContractArguments(),
        [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead, resource: "/workspace/public.txt")],
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "view-parent-binding",
        implementationFingerprint: "axyndra:read-view-contract:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}
func readViewContractChildPlan(change: String): NormalizedOperationPlan {
    let args = readViewChildArguments(readViewContractArguments(), "view").value().getOrThrow()
    if (change == "path") { args.field("intent").getOrThrow().field("resources").getOrThrow().items[0].put("source", textValue("/outside/secret")) }
    if (change == "witness") { args.field("intent").getOrThrow().field("resources").getOrThrow().items[0].put("witness", textValue("f:9:9:384:5:1:0:1:0")) }
    if (change == "contribution") { args.put("contribution", textValue("other")) }
    if (change == "configuration") { args.put("configuration_digest", textValue("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")) }
    if (change == "profile") { args.put("tool_payload_limits", OrdinaryToolPayloadLimits("read").value()) }
    if (change == "foreign-profile") { args.put("tool_payload_limits", OrdinaryToolPayloadLimits("other").value()) }
    if (change == "generation") { args.put("generation", textValue("2")) }
    NormalizedOperationPlan(HOST_READ_VIEW_TOOL, args, readViewRequiredCapabilities(args),
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "view-child-binding",
        toolVersion: HOST_READ_VIEW_FINGERPRINT, implementationFingerprint: HOST_READ_VIEW_FINGERPRINT)
}

func readViewParentIntentContract(): Unit {
    for (committed in [false, true]) {
        for (scenario in ["completed", "unknown", "path", "witness", "contribution", "configuration", "profile", "foreign-profile", "generation", "wrong-key", "no-handoff",
            "cancel-before-execute", "epoch-before-handoff", "missing-proof", "root-bypass"]) {
            readViewParentIntentScenario(committed, scenario)
        }
    }
    println("Read-view exact ParentIntent durable contract passed: 30 scenarios")
}

func readViewParentIntentScenario(committed: Bool, scenario: String): Unit {
    let directory = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(directory + "/state.db")
    let label = (if (committed) { "Committed" } else { "Direct" }) + " read view " + scenario
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("view-thread"); let turn = SemanticTurnId("view-turn"); let run = RunId("view-run")
        let item = ItemId("view-root-item"); let parent = OperationId("view-parent"); let child = OperationId("view-child")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "/workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("view", StoreEstimator()), { => 10 })
        let active = runtime.startTurn(turn, run, ItemId("view-user"), ThreadItemContent.UserMessage(textMessageParts("Read exact resources")),
            recoveryLane(), InvocationContextProjection()).value().getOrThrow()
        let parentPlan = readViewContractRootPlan()
        let call = ToolCall("view-call", parentPlan.toolName, parentPlan.canonicalArguments.field("input").getOrThrow())
        let store = DurableOperationStore(database)
        let source: OperationRootSource
        if (committed) {
            let reference = commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
                item, call.callId, call.name, call.arguments, 10)
            source = OperationRootSource.Committed(reference)
            httpContractRequire(store.prepare(parent, run, reference, parentPlan), label + " actual committed parent")
        } else {
            expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
                ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                    ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))), label + " actual Direct ToolCall")
            source = OperationRootSource.Direct(runtime.attestDirectToolCall(item, parent, run, active.epoch).value().getOrThrow())
            httpContractRequire(store.prepareTrustedControlOperation(parent, run, item, parentPlan), label + " actual Direct parent")
        }
        httpContractRequire(store.markExecuting(parent, run, parentPlan, 11, false), label + " parent executing")
        if (scenario != "no-handoff") { httpContractRequire(store.markExecutionHandoff(parent, run, thread, 12), label + " parent handoff") }
        let childPlan = readViewContractChildPlan(scenario)
        let key = "javascript-service:view-call:" + (if (scenario == "wrong-key") { "another-transport-id" } else { "view" })
        if (scenario == "root-bypass") {
            httpContractRequire(store.prepareTrustedControlOperation(child, run, item, childPlan), label + " descriptive root plan")
            expect(store.markExecuting(child, run, childPlan, 13, false).isError(), label + " cannot execute hidden service without actual parent proof")
            expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0, label + " cannot fabricate child source")
            return
        }
        let admission = store.prepareDerivedOperation(child, parent, run, source, key, childPlan)
        if (["path", "witness", "contribution", "configuration", "profile", "foreign-profile", "generation", "wrong-key", "no-handoff"].contains(scenario)) {
            expect(admission.isError(), label + " must reject changed or absent frozen authority")
            expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='view-child'") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'") == 0,
                label + " failed admission rolls back all child facts")
            return
        }
        httpContractRequire(admission, label + " admission")
        let audit = database.query("SELECT payload FROM audit_events WHERE operation_id='view-child' AND kind='operation_parent_intent_authorized'")
        expect(audit.size == 1, label + " has exactly one durable ParentIntent proof")
        let proof = decodeStoredValue(audit[0].required(0))
        expect(httpIntentText(proof, "parent_plan_digest") == parentPlan.bindingDigest &&
            httpIntentText(proof, "child_plan_digest") == childPlan.bindingDigest &&
            httpIntentText(proof, "root_source") == (if (committed) { "committed" } else { "direct" }), label + " binds source and exact plans")
        if (scenario == "cancel-before-execute") { database.execute("UPDATE runs SET state='cancelling' WHERE id='view-run'") }
        if (scenario == "missing-proof") { database.execute("DELETE FROM audit_events WHERE kind='operation_parent_intent_authorized'") }
        if (scenario == "cancel-before-execute" || scenario == "missing-proof") {
            expect(store.markExecuting(child, run, childPlan, 13, false).isError(), label + " revalidates authority before execution")
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='view-child' AND kind='operation_execution_handoff'") == 0,
                label + " never crosses child handoff")
            return
        }
        httpContractRequire(store.markExecuting(child, run, childPlan, 13, false), label + " child executing")
        if (scenario == "epoch-before-handoff") {
            database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='view-run'")
            expect(store.markExecutionHandoff(child, run, thread, 14).isError(), label + " old epoch cannot hand off")
            return
        }
        httpContractRequire(store.markExecutionHandoff(child, run, thread, 14), label + " child handoff")
        let outcome = if (scenario == "unknown") { OperationOutcome.Unknown } else { OperationOutcome.Completed }
        let receiptReservation = database.query("SELECT reserved_receipt_id FROM operation_effect_records WHERE operation_id='view-child'")
        expect(receiptReservation.size == 1, label + " has one immutable child Receipt reservation")
        httpContractRequire(store.settleDerivedOperation(run, parent, VNextOperationReceipt(receiptReservation[0].required(0), child, outcome,
            objectValue([ValueField("status", textValue("fixture"))]), objectValue([]), 15)), label + " settles actual outcome")
        expect(store.prepareDerivedOperation(OperationId("view-repeat"), parent, run, source, key, childPlan).value().getOrThrow().value == child.value,
            label + " request identity cannot create another child")
        expect(store.markExecuting(child, run, childPlan, 16, false).isError(), label + " never replays a settled worker")
        expect(store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow().outcome == outcome,
            label + " retains the actual receipt outcome")
        expect(database.query("PRAGMA foreign_key_check").isEmpty(), label + " retains referential integrity")
    } finally { database.close(); remove(directory, recursive: true) }
}
