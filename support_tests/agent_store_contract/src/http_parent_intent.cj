package agent_store_contract

import std.fs.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func httpContractRequire<T>(result: Result<T>, label: String): T {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(label + ": " + error.describe())
    }
}

func httpParentIntentAdmissionContract(): Unit {
    for (committed in [false, true]) {
        for (scenario in ["completed", "unknown-replay", "changed-body", "different-request-key",
            "wrong-network", "wrong-parent", "no-handoff", "cancel-before-execute",
            "epoch-before-execute", "cancel-before-handoff", "epoch-before-handoff",
            "missing-proof", "changed-proof", "missing-parent-handoff", "nested-parent",
            "cancel-before-settle", "epoch-before-settle", "forged-parent", "root-service-bypass",
            "read-only-root", "retryable-root", "epoch-before-admission", "cancel-before-admission",
            "handoff-epoch-rebind", "cancelling-unknown", "cancelling-completed", "cancelling-failed",
            "cancelling-before-execute", "cancelling-before-handoff", "cancelling-prepared-rejected",
            "cancelling-waiting-rejected", "cancelling-prepared-completed", "cancelling-prepared-failed",
            "cancelling-prepared-unknown", "cancelling-prepared-handoff-rejected"]) {
            httpParentIntentScenario(committed, "POST", scenario)
        }
        httpParentIntentScenario(committed, "GET", "completed")
    }
    println("HTTP ParentIntent durable contract passed: 72 scenarios")
    httpCommittedApprovalBindingContract()
    httpCommittedApprovalEffectiveInputContract()
}

func httpCommittedApprovalEffectiveInputContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/http-approval-effective-input.db")
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("http-effective-thread")
        let turn = SemanticTurnId("http-effective-turn")
        let run = RunId("http-effective-run")
        let item = ItemId("http-effective-item")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("http-effective", StoreEstimator()), { => 10 })
        let active = runtime.startTurn(turn, run, ItemId("http-effective-user"),
            ThreadItemContent.UserMessage(textMessageParts("approve effective HTTP input")),
            recoveryLane(), InvocationContextProjection()).value().getOrThrow()
        // Reserved-looking field names remain ordinary plugin input. Loading
        // for approval must restore the hook result, without unwrapping it again.
        let effective = objectValue([
            ValueField("input", textValue("trusted hook effective input")),
            ValueField("host_plan", objectValue([ValueField("untrusted_input", boolValue(true))]))
        ])
        let plan = httpContractRootPlan("POST", effectiveInput: Some(effective))
        let source = commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
            item, "http-effective-call", plan.toolName, httpContractOriginalInput(), 10)
        let operation = OperationId("operation-" + source.decisionId.value + "-" + source.scopedToolCallId.value)
        let store = DurableOperationStore(database)
        httpContractRequire(store.prepare(operation, run, source, plan), "effective HTTP input preparation")
        httpContractRequire(store.waitForApproval(operation, run), "effective HTTP input waits for approval")
        let before = database.query("SELECT o.state,o.revision,o.normalized_plan,i.payload " +
            "FROM operations o JOIN items i ON i.id=o.tool_call_item_id WHERE o.id=?",
            [SqlParameter.Text(operation.value)])[0]
        let restored = httpContractRequire(store.loadCall(operation, run), "restore effective HTTP input")
        expect(restored.callId == source.block.callId && restored.name == source.block.name &&
            canonicalAgentValue(restored.arguments) == canonicalAgentValue(effective) &&
            canonicalAgentValue(restored.arguments) != canonicalAgentValue(source.block.arguments),
            "HTTP approval restores the frozen hook input while retaining the canonical call identity")
        expect(restored.arguments.field("input").getOrThrow().text == "trusted hook effective input" &&
            canonicalAgentValue(restored.arguments.field("host_plan").getOrThrow()
                .field("untrusted_input").getOrThrow()) == canonicalAgentValue(boolValue(true)),
            "HTTP approval unwraps only the verified host envelope and preserves reserved-looking effective input")
        httpContractRequire(store.prepare(operation, run, source, plan), "effective source remains exactly bound")
        let after = database.query("SELECT o.state,o.revision,o.normalized_plan,i.payload " +
            "FROM operations o JOIN items i ON i.id=o.tool_call_item_id WHERE o.id=?",
            [SqlParameter.Text(operation.value)])[0]
        for (index in 0..4) {
            expect(after.required(index) == before.required(index),
                "HTTP input restoration changes neither the canonical Item nor pending immutable plan")
        }
        expect(after.required(0) == "waiting_approval" && database.scalarInt("SELECT COUNT(*) FROM approvals") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
            "restoring effective HTTP input grants no approval and performs no handoff")
        println("HTTP Committed approval effective input contract passed")
    } finally {
        database.close()
        remove(root, recursive: true)
    }
}

func httpCommittedApprovalBindingContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/http-approval-source.db")
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("http-approval-source-thread")
        let turn = SemanticTurnId("http-approval-source-turn")
        let run = RunId("http-approval-source-run")
        let item = ItemId("http-approval-source-item")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("http-approval", StoreEstimator()), { => 10 })
        let active = runtime.startTurn(turn, run, ItemId("http-approval-source-user"),
            ThreadItemContent.UserMessage(textMessageParts("approve HTTP")), recoveryLane(), InvocationContextProjection())
            .value().getOrThrow()
        let plan = httpContractRootPlan("POST")
        let source = commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
            item, "same-provider-call", plan.toolName, httpContractOriginalInput(), 10)
        let operation = OperationId("operation-" + source.decisionId.value + "-" + source.scopedToolCallId.value)
        let store = DurableOperationStore(database)
        httpContractRequire(store.prepare(operation, run, source, plan), "approval source initial preparation")
        httpContractRequire(store.waitForApproval(operation, run), "approval source pending")
        let before = database.query("SELECT o.state,o.revision,s.state,s.revision,e.normalized_plan " +
            "FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id " +
            "JOIN operation_effect_records e ON e.operation_id=o.id WHERE o.id=?", [SqlParameter.Text(operation.value)])[0]
        httpContractRequire(store.prepare(operation, run, source, plan), "approval source idempotent verification")

        // A real different Thread may reuse a provider-local call ID/name.
        // Its attestation is not evidence for the original canonical Item.
        let otherThread = ThreadId("http-approval-other-thread")
        let otherTurn = SemanticTurnId("http-approval-other-turn")
        let otherRun = RunId("http-approval-other-run")
        let otherItem = ItemId("http-approval-other-item")
        let otherCoordinator = ThreadCoordinator(sink.createThread(otherThread, "workspace"), sink)
        let otherRuntime = AgentThreadRuntime(otherCoordinator,
            ContextProjector("http-approval-other", StoreEstimator()), { => 10 })
        let otherActive = otherRuntime.startTurn(otherTurn, otherRun, ItemId("http-approval-other-user"),
            ThreadItemContent.UserMessage(textMessageParts("another HTTP")), recoveryLane(), InvocationContextProjection())
            .value().getOrThrow()
        let other = commitDurableToolCall(database, otherCoordinator, otherThread, otherTurn, otherRun,
            otherActive.epoch, 1, otherItem, source.block.callId, source.block.name, source.block.arguments, 20)
        let rebound = otherRuntime.attestCommittedToolCalls([CommittedToolCallSource(source.decisionId,
            source.scopedToolCallId, other.canonicalItemId, other.block)]).value().getOrThrow()[0]
        expect(rebound.block.callId == source.block.callId && rebound.block.name == source.block.name &&
            rebound.decisionId.value == source.decisionId.value &&
            rebound.scopedToolCallId.value == source.scopedToolCallId.value &&
            rebound.canonicalItemId.value != source.canonicalItemId.value,
            "SQLite approval regression keeps operation/call identity equal while substituting only the canonical Item")
        expect(store.prepare(operation, run, rebound, plan).isError() &&
            store.prepare(operation, otherRun, rebound, plan).isError() &&
            store.prepare(operation, run, other, plan).isError(),
            "idempotent approval verification rejects another Item, Run or durable Decision source")
        let after = database.query("SELECT o.state,o.revision,s.state,s.revision,e.normalized_plan " +
            "FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id " +
            "JOIN operation_effect_records e ON e.operation_id=o.id WHERE o.id=?", [SqlParameter.Text(operation.value)])[0]
        for (index in 0..5) {
            expect(after.required(index) == before.required(index),
                "source verification cannot reset pending state, revision or immutable plan")
        }
        expect(after.required(0) == "waiting_approval" && after.required(2) == "waiting_approval" &&
            database.scalarInt("SELECT COUNT(*) FROM operations") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM decision_operations") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM approvals") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
            "pending source checks preserve the existing Operation without executing or inventing approval")
        httpContractRequire(store.recordApproval("http-approval-source-decision", operation, run, plan,
            CapabilitySet(values: plan.requiredCapabilities), true, "user", None), "approval source User decision")
        let approvedRevision = database.query("SELECT revision FROM operations WHERE id=?", [SqlParameter.Text(operation.value)])[0].required(0)
        httpContractRequire(store.prepare(operation, run, source, plan), "approved source idempotent verification")
        expect(database.query("SELECT revision FROM operations WHERE id=?", [SqlParameter.Text(operation.value)])[0].required(0) == approvedRevision &&
            database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='prepared'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM approvals") == 1,
            "exact source recheck retains the recorded User approval and prepared revision")
        httpContractRequire(store.markExecuting(operation, run, plan, 30, true), "exact source approved execution")
        httpContractRequire(store.markExecutionHandoff(operation, run, thread, 31), "exact source execution handoff")
        expect(database.query("PRAGMA foreign_key_check").isEmpty(), "approval source checks retain referential integrity")
        println("HTTP Committed approval canonical binding contract passed")
    } finally {
        database.close()
        remove(root, recursive: true)
    }
}

func httpContractNetwork(host!: String = "fixture.example"): NetworkPolicy {
    NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule(host, 443u16)])
}

func httpContractArguments(method: String, body!: String = "original",
    effectiveInput!: Option<AgentValue> = None): AgentValue {
    let request = objectValue([
        ValueField("method", textValue(method)),
        ValueField("url", textValue("https://fixture.example/search")),
        ValueField("query", objectValue([ValueField("q", textValue("contract"))])),
        ValueField("headers", objectValue([ValueField("accept", textValue("application/json"))])),
        ValueField("json_body", if (method == "POST") {
            objectValue([ValueField("query", textValue(body))])
        } else { nullValue() }),
        ValueField("credential_refs", listValue([textValue("provider-key")])),
        ValueField("timeout_ms", integerValue(1000))
    ])
    objectValue([
        ValueField("input", match (effectiveInput) {
            case Some(value) => value
            case None => httpContractOriginalInput()
        }),
        ValueField("configuration", objectValue([])),
        ValueField("host_plan", objectValue([
            ValueField("version", textValue(HOST_HTTP_INTENT_VERSION)),
            ValueField("plugin", textValue("axyndra:http-contract")),
            ValueField("package_digest", textValue("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
            ValueField("generation", textValue("1")),
            ValueField("configuration_digest", textValue("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")),
            ValueField("intents", listValue([objectValue([
                ValueField("id", textValue("request-1")),
                ValueField("request", request),
                ValueField("network", networkPolicyCanonicalValue(httpContractNetwork()))
            ])]))
        ]))
    ])
}

func httpContractOriginalInput(): AgentValue {
    // These names are ordinary original input fields. Approval restoration
    // must not unwrap or trust them as a host-created plan envelope.
    objectValue([
        ValueField("input", textValue("user input named input")),
        ValueField("host_plan", objectValue([ValueField("forged", boolValue(true))]))
    ])
}

func httpContractRootPlan(method: String, scenario!: String = "completed",
    effectiveInput!: Option<AgentValue> = None): NormalizedOperationPlan {
    let network = httpContractNetwork()
    NormalizedOperationPlan("plugin.axyndra:http-contract.search", httpContractArguments(method, effectiveInput: effectiveInput),
        [Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(network.egress[0]))],
        if (scenario == "read-only-root") { OperationEffectClass.ReadOnly } else { OperationEffectClass.ExternalMutation },
        if (scenario == "retryable-root") { OperationRetryDisposition.Safe } else { OperationRetryDisposition.Never },
        "http-parent-binding",
        networkPolicy: Some(network),
        implementationFingerprint: "axyndra:http-contract:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}

func httpContractChildPlan(method: String, body!: String = "original",
    wrongNetwork!: Bool = false): NormalizedOperationPlan {
    let arguments = httpServiceChildArguments(httpContractArguments(method, body: body), "request-1")
        .value().getOrThrow()
    let network = httpContractNetwork(host: if (wrongNetwork) { "other.example" } else { "fixture.example" })
    NormalizedOperationPlan(HOST_HTTP_SERVICE_TOOL, arguments,
        [Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(network.egress[0]))],
        if (method == "GET") { OperationEffectClass.ReadOnly } else { OperationEffectClass.ExternalMutation },
        OperationRetryDisposition.Never, "http-child-binding",
        networkPolicy: Some(network), implementationFingerprint: "host-http-intent-v1")
}

func httpParentIntentScenario(committed: Bool, method: String, scenario: String): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/http-parent-intent.db")
    let label = (if (committed) { "Committed" } else { "Direct" }) + " " + method + " " + scenario
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("http-thread")
        let turn = SemanticTurnId("http-turn")
        let run = RunId("http-run")
        let item = ItemId("http-root-item")
        let parent = OperationId("http-parent")
        let child = OperationId("http-child")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("http", StoreEstimator()), { => 10 })
        let active = runtime.startTurn(turn, run, ItemId("http-user"),
            ThreadItemContent.UserMessage(textMessageParts("HTTP intent")), recoveryLane(), InvocationContextProjection())
            .value().getOrThrow()
        let rootPlan = httpContractRootPlan(method, scenario: scenario)
        let call = ToolCall("http-call", rootPlan.toolName, httpContractOriginalInput())
        let source: OperationRootSource
        let store = DurableOperationStore(database)
        if (committed) {
            let reference = commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
                item, call.callId, call.name, call.arguments, 10)
            source = OperationRootSource.Committed(reference)
            store.prepare(parent, run, reference, rootPlan).value().getOrThrow()
        } else {
            expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
                ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name,
                    call.arguments), ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))),
                label + " starts from a canonical Direct ToolCall")
            source = OperationRootSource.Direct(runtime.attestDirectToolCall(item, parent, run, active.epoch)
                .value().getOrThrow())
            store.prepareTrustedControlOperation(parent, run, item, rootPlan).value().getOrThrow()
        }
        let restored = store.loadCall(parent, run).value().getOrThrow()
        expect(restored.callId == call.callId && restored.name == call.name &&
            canonicalAgentValue(restored.arguments) == canonicalAgentValue(call.arguments),
            label + " approval restore preserves original input instead of the frozen host envelope")
        store.markExecuting(parent, run, rootPlan, 11, false).value().getOrThrow()
        if (scenario != "no-handoff") {
            store.markExecutionHandoff(parent, run, thread, 12).value().getOrThrow()
        }
        if (scenario == "epoch-before-admission" || scenario == "handoff-epoch-rebind") {
            database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='http-run'")
            if (scenario == "handoff-epoch-rebind") {
                expect(store.markExecutionHandoff(parent, run, thread, 13).isError(),
                    label + " cannot overwrite the first HTTP handoff with a later epoch")
            }
        } else if (scenario == "cancel-before-admission") {
            database.execute("UPDATE runs SET state='cancelled' WHERE id='http-run'")
        }
        let requestKey = "javascript-service:" + call.callId + ":request-1"
        let childPlan = httpContractChildPlan(method)
        if (scenario == "forged-parent") {
            database.execute("UPDATE items SET provenance=? WHERE id='http-root-item'",
                [SqlParameter.Text(encodeStoredProvenance(ItemProvenance("direct_tool",
                    runId: Some(run), operationId: Some(OperationId("forged-parent")))))])
        }
        if (scenario == "changed-body" || scenario == "different-request-key" ||
            scenario == "wrong-network" || scenario == "wrong-parent" || scenario == "no-handoff" ||
            scenario == "forged-parent" || scenario == "read-only-root" || scenario == "retryable-root" ||
            scenario == "epoch-before-admission" || scenario == "cancel-before-admission" ||
            scenario == "handoff-epoch-rebind") {
            let candidate = if (scenario == "changed-body") { httpContractChildPlan(method, body: "changed") }
                else if (scenario == "wrong-network") { httpContractChildPlan(method, wrongNetwork: true) }
                else { childPlan }
            let key = if (scenario == "different-request-key") { requestKey + "-transport-retry" } else { requestKey }
            let candidateParent = if (scenario == "wrong-parent") { OperationId("another-parent") } else { parent }
            expect(store.prepareDerivedOperation(child, candidateParent, run, source, key, candidate).isError(),
                label + " rejects changed authority before durable admission")
            expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM operations") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'") == 0,
                label + " admission failure leaves no child or authorization evidence")
            return
        }
        if (scenario == "root-service-bypass") {
            store.prepareTrustedControlOperation(child, run, item, childPlan).value().getOrThrow()
            expect(store.markExecuting(child, run, childPlan, 13, false).isError(),
                label + " false approval flag cannot authorize HTTP as a standalone trusted root")
            expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0,
                label + " does not invent a parent relationship")
            return
        }
        httpContractRequire(store.prepareDerivedOperation(child, parent, run, source, requestKey, childPlan),
            label + " admission")
        let evidenceRows = database.query("SELECT payload FROM audit_events WHERE operation_id='http-child' " +
            "AND kind='operation_parent_intent_authorized'")
        expect(evidenceRows.size == 1, label + " commits exactly one ParentIntent audit in its admission transaction")
        let evidence = decodeStoredValue(evidenceRows[0].required(0))
        expect(httpIntentText(evidence, "authorization_source") == "parent_intent" &&
            httpIntentText(evidence, "root_source") == (if (committed) { "committed" } else { "direct" }) &&
            httpIntentText(evidence, "parent_operation_id") == parent.value &&
            httpIntentText(evidence, "parent_plan_digest") == rootPlan.bindingDigest &&
            httpIntentText(evidence, "child_plan_digest") == childPlan.bindingDigest &&
            httpIntentText(evidence, "request_key") == requestKey &&
            database.scalarInt("SELECT COUNT(*) FROM approvals WHERE operation_id='http-child'") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM approval_decisions WHERE operation_id='http-child'") == 0,
            label + " records exact parent provenance without inventing a User approval")
        expect(store.prepareDerivedOperation(OperationId("http-replay"), parent, run, source, requestKey, childPlan)
            .value().getOrThrow().value == child.value &&
            database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'") == 1,
            label + " exact replay retains a single child identity and authorization")
        expect(store.prepareDerivedOperation(OperationId("http-other-transport"), parent, run, source,
            requestKey + "-other", childPlan).isError(), label + " transport request IDs cannot duplicate the frozen intent")
        if (scenario == "nested-parent") {
            expect(store.prepareDerivedOperation(OperationId("http-nested"), child, run, source, requestKey, childPlan)
                .isError(), label + " a derived child cannot become another HTTP parent")
            return
        }
        if (scenario.startsWith("cancelling-prepared-") || scenario == "cancelling-waiting-rejected") {
            if (scenario == "cancelling-prepared-handoff-rejected") {
                httpContractRequire(store.markExecuting(child, run, childPlan, 13, false), label + " initial execution")
                httpContractRequire(store.markExecutionHandoff(child, run, thread, 14), label + " actual handoff")
                // Simulate a stale recovered state register; durable handoff
                // evidence still forbids claiming that no execution happened.
                database.execute("UPDATE operations SET state='prepared' WHERE id='http-child'")
                database.execute("UPDATE operation_state_registers SET state='prepared' WHERE operation_id='http-child'")
            }
            if (scenario == "cancelling-waiting-rejected") {
                httpContractRequire(store.waitForApproval(child, run), label + " waiting approval")
            }
            database.execute("UPDATE runs SET state='cancelling' WHERE id='http-run'")
            let outcome = if (scenario.endsWith("rejected")) { OperationOutcome.Rejected }
                else if (scenario.endsWith("completed")) { OperationOutcome.Completed }
                else if (scenario.endsWith("failed")) { OperationOutcome.Failed } else { OperationOutcome.Unknown }
            let settled = store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-http-child", child,
                outcome, objectValue([]), objectValue([]), 13))
            if (outcome == OperationOutcome.Rejected && scenario != "cancelling-prepared-handoff-rejected") {
                httpContractRequire(settled, label + " unexecuted cancellation settlement")
                expect(store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow().outcome ==
                    OperationOutcome.Rejected && store.markExecuting(child, run, childPlan, 14, false).isError(),
                    label + " records rejected unexecuted work without reviving execution authority")
            } else {
                expect(settled.isError() &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='http-child'") == 0,
                    label + " prepared cancellation cannot invent execution or effect certainty")
            }
            let expectedHandoffs: Int64 = if (scenario == "cancelling-prepared-handoff-rejected") { 1 } else { 0 }
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='http-child' " +
                "AND kind='operation_execution_handoff'") == expectedHandoffs,
                label + " preserves the actual executor handoff evidence")
            return
        }
        if (scenario == "cancel-before-execute") {
            database.execute("UPDATE runs SET state='cancelled' WHERE id='http-run'")
        } else if (scenario == "cancelling-before-execute") {
            database.execute("UPDATE runs SET state='cancelling' WHERE id='http-run'")
        } else if (scenario == "epoch-before-execute") {
            database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='http-run'")
        } else if (scenario == "missing-proof") {
            database.execute("DELETE FROM audit_events WHERE kind='operation_parent_intent_authorized'")
        } else if (scenario == "changed-proof") {
            database.execute("UPDATE audit_events SET payload=? WHERE kind='operation_parent_intent_authorized'",
                [SqlParameter.Text(encodeStoredValue(objectValue([])))])
        } else if (scenario == "missing-parent-handoff") {
            database.execute("DELETE FROM audit_events WHERE operation_id='http-parent' AND kind='operation_execution_handoff'")
        }
        if (["cancel-before-execute", "epoch-before-execute", "missing-proof", "changed-proof",
            "missing-parent-handoff", "cancelling-before-execute"].contains(scenario)) {
            expect(store.markExecuting(child, run, childPlan, 13, false).isError() &&
                database.query("SELECT state FROM operations WHERE id='http-child'")[0].required(0) == "prepared",
                label + " revalidates live ParentIntent even with approvalRequired=false")
            return
        }
        httpContractRequire(store.markExecuting(child, run, childPlan, 13, false), label + " executing")
        if (scenario == "cancel-before-handoff" || scenario == "epoch-before-handoff" ||
            scenario == "cancelling-before-handoff") {
            database.execute(if (scenario == "cancel-before-handoff") {
                "UPDATE runs SET state='cancelled' WHERE id='http-run'"
            } else if (scenario == "cancelling-before-handoff") {
                "UPDATE runs SET state='cancelling' WHERE id='http-run'"
            } else { "UPDATE runs SET epoch=epoch+1 WHERE id='http-run'" })
            expect(store.markExecutionHandoff(child, run, thread, 14).isError() &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='http-child' " +
                    "AND kind='operation_execution_handoff'") == 0,
                label + " cancellation or epoch drift between admission and handoff prevents I/O authority")
            return
        }
        httpContractRequire(store.markExecutionHandoff(child, run, thread, 14), label + " handoff")
        if (scenario.startsWith("cancelling-")) {
            database.execute("UPDATE runs SET state='cancelling' WHERE id='http-run'")
            let outcome = if (scenario == "cancelling-unknown") { OperationOutcome.Unknown }
                else if (scenario == "cancelling-failed") { OperationOutcome.Failed } else { OperationOutcome.Completed }
            let settled = store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-http-child", child,
                outcome, objectValue([]), objectValue([]), 15))
            if (outcome == OperationOutcome.Unknown) {
                httpContractRequire(settled, label + " uncertain cancellation settlement")
                expect(store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow().outcome ==
                    OperationOutcome.Unknown && store.markExecuting(child, run, childPlan, 16, false).isError(),
                    label + " joins an in-flight child with Unknown without restoring execution authority")
            } else {
                expect(settled.isError() &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='http-child'") == 0,
                    label + " cancelling cannot assert a known success or failure for in-flight HTTP")
            }
            return
        }
        if (scenario == "cancel-before-settle" || scenario == "epoch-before-settle") {
            database.execute(if (scenario == "cancel-before-settle") {
                "UPDATE runs SET state='cancelled' WHERE id='http-run'"
            } else { "UPDATE runs SET epoch=epoch+1 WHERE id='http-run'" })
            expect(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-http-child", child,
                OperationOutcome.Completed, objectValue([]), objectValue([]), 15)).isError() &&
                database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='http-child'") == 0,
                label + " stale HTTP completion cannot settle against cancelled or changed parent authority")
            return
        }
        let outcome = if (scenario == "unknown-replay") { OperationOutcome.Unknown } else { OperationOutcome.Completed }
        httpContractRequire(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-http-child", child,
            outcome, objectValue([ValueField("status", textValue("retained"))]), objectValue([]), 15)), label + " settlement")
        let receipt = store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow()
        expect(receipt.outcome == outcome, label + " records the actual child outcome")
        if (scenario == "unknown-replay") {
            database.execute("UPDATE runs SET state='cancelled' WHERE id='http-run'")
            expect(store.prepareDerivedOperation(OperationId("http-unknown-replay"), parent, run, source,
                requestKey, childPlan).value().getOrThrow().value == child.value &&
                store.markExecuting(child, run, childPlan, 16, false).isError() &&
                store.loadDerivedOperationReceipt(child, run).value().getOrThrow().getOrThrow().outcome == OperationOutcome.Unknown,
                label + " retrieves uncertain receipt without resending a Never-replay HTTP request")
        }
        expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='http-child'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='http-child' " +
                "AND kind='operation_execution_handoff'") == 1 &&
            database.query("PRAGMA foreign_key_check").isEmpty(),
            label + " preserves one child execution and durable referential integrity")
    } finally { database.close() }
}
