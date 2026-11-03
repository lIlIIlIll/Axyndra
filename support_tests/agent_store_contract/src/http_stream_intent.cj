package agent_store_contract

import std.fs.*
import std.collection.*
import std.time.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

// Real SQLite/Thread runtime contract. Network effects and plugin IPC are
// tested separately through the actual Product entry.
let STREAM_CONTRACT_DIGEST = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
func streamContractClone(value: AgentValue): AgentValue { parseUnifiedJson(stringifyUnifiedJson(value)) }
func streamContractNetwork(): NetworkPolicy {
    NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule("example.test", 443u16)])
}
func streamContractLaunchGrant(): AgentValue {
    let window = objectValue([ValueField("timeout_ms", integerValue(1000)), ValueField("max_requests", integerValue(4)),
        ValueField("max_input_bytes", integerValue(4096)), ValueField("max_output_bytes", integerValue(4096)),
        ValueField("requests", listValue([]))])
    objectValue([ValueField("schema", textValue("axyndra.http-service-launch/v1")),
        ValueField("namespace", textValue("axyndra:stream-contract")), ValueField("package_digest", textValue("sha256:" + STREAM_CONTRACT_DIGEST)),
        ValueField("configuration_digest", textValue(STREAM_CONTRACT_DIGEST)), ValueField("service_id", textValue("session")),
        ValueField("thread_id", textValue("stream-target-thread")), ValueField("instance_identity", textValue("stream-instance")),
        ValueField("permission_domain", textValue(STREAM_CONTRACT_DIGEST)), ValueField("workspace_root", textValue("/fixture/workspace")),
        ValueField("network", networkPolicyCanonicalValue(streamContractNetwork())), ValueField("lifetime_ms", integerValue(10000)),
        ValueField("max_instances", integerValue(1)), ValueField("startup", window), ValueField("refresh", window)])
}
func streamContractBinding(grant: AgentValue): AgentValue {
    objectValue([ValueField("plugin", grant.field("namespace").getOrThrow()),
        ValueField("package_digest", grant.field("package_digest").getOrThrow()),
        ValueField("configuration_digest", grant.field("configuration_digest").getOrThrow()),
        ValueField("instance_identity", grant.field("instance_identity").getOrThrow()),
        ValueField("endpoint_identity", textValue(STREAM_CONTRACT_DIGEST)), ValueField("resource_id", textValue("stream-lease")),
        ValueField("grant_digest", textValue(modelPolicySha256Text(canonicalAgentValue(grant)))),
        ValueField("startup_operation_id", textValue("stream-startup-operation")), ValueField("target_thread_id", grant.field("thread_id").getOrThrow()),
        ValueField("permission_domain", grant.field("permission_domain").getOrThrow()), ValueField("directory_revision", integerValue(1)),
        ValueField("directory_digest", textValue(STREAM_CONTRACT_DIGEST)), ValueField("implementation_version", textValue("1.0.0")),
        ValueField("implementation_fingerprint", textValue("owned-v1:" + STREAM_CONTRACT_DIGEST)), ValueField("schema_digest", textValue(STREAM_CONTRACT_DIGEST)),
        ValueField("workspace_root", grant.field("workspace_root").getOrThrow()), ValueField("network", grant.field("network").getOrThrow())])
}
func streamContractParent(binding: AgentValue, readOnly!: Bool = false, toolName!: String = "",
    replay!: ?ReplayDisposition = None, payloadBody!: ?AgentValue = None): NormalizedOperationPlan {
    var request = objectValue([ValueField("method", textValue("POST")), ValueField("url", textValue("https://example.test/mcp?a=1&a=%2f")),
        ValueField("headers", objectValue([])), ValueField("body_hex", textValue("68656c6c6f0a")), ValueField("credential_refs", listValue([])),
        ValueField("timeout_ms", integerValue(1000)), ValueField("max_response_bytes", integerValue(4096))])
    match (payloadBody) {
        case Some(value) =>
            let fields = ArrayList<ValueField>()
            for (field in request.fields where field.name != "body_hex") { fields.add(field) }
            fields.add(ValueField("body_payload", value)); request = objectValue(fields.toArray())
        case None => ()
    }
    let arguments = objectValue([ValueField("input", objectValue([ValueField("query", textValue("frozen request"))])),
        ValueField("configuration", objectValue([])), ValueField("host_plan", objectValue([
            ValueField("version", textValue(if (payloadBody.isSome()) { HOST_HTTP_STREAM_PAYLOAD_INTENT_VERSION } else { HOST_HTTP_STREAM_INTENT_VERSION })), ValueField("binding", binding),
            ValueField("intents", listValue([objectValue([ValueField("id", textValue("write-1")), ValueField("request", request),
                ValueField("network", networkPolicyCanonicalValue(streamContractNetwork()))])]))]))])
    NormalizedOperationPlan(if (toolName == "") { "plugin.axyndra:stream-contract.echo" } else { toolName }, arguments,
        httpContractRequire(httpStreamServiceRequiredCapabilities(binding), "HTTP parent capabilities"),
        if (readOnly) { OperationEffectClass.ReadOnly } else { OperationEffectClass.ExternalMutation }, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(arguments)),
        toolVersion: "1.0.0", implementationFingerprint: "owned-v1:" + STREAM_CONTRACT_DIGEST,
        schemaDigest: STREAM_CONTRACT_DIGEST, replayDisposition: Some(replay ?? ReplayDisposition.NeverReplay), networkPolicy: Some(streamContractNetwork()))
}
func streamContractChild(arguments: AgentValue): NormalizedOperationPlan {
    let policy = httpContractRequire(httpStreamIntentPolicy(arguments.field("intent").getOrThrow(), binding: arguments.field("binding")), "HTTP exact intent policy")
    NormalizedOperationPlan(HOST_HTTP_STREAM_TOOL, arguments,
        [Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(policy.egress[0]))],
        OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(arguments)),
        networkPolicy: Some(policy), toolVersion: HOST_HTTP_STREAM_FINGERPRINT, implementationFingerprint: HOST_HTTP_STREAM_FINGERPRINT)
}

class HttpStreamIntentStoreFixture {
    let root: String
    let database: SqliteDatabase
    let sink: SqliteThreadCommitSink
    let store: DurableOperationStore
    let coordinator: ThreadCoordinator
    let runtime: AgentThreadRuntime
    let thread = ThreadId("stream-target-thread")
    let turn = SemanticTurnId("stream-target-turn")
    let run = RunId("stream-target-run")
    let item = ItemId("stream-parent-item")
    let parent = OperationId("stream-parent")
    let child = OperationId("stream-child")
    let epoch: Int64
    let call: ToolCall
    let source: OperationRootSource
    let rootPlan: NormalizedOperationPlan
    let childPlan: NormalizedOperationPlan
    let key: String

    init(committed: Bool, bindingField!: String = "", bindingValue!: String = "", startupMode!: String = "",
        readOnly!: Bool = false, readOnlyGrant!: ?AgentValue = None, readOnlyBinding!: String = "",
        toolName!: String = "", replay!: ?ReplayDisposition = None, expectPair!: Bool = true,
        payloadGrant!: ?AgentValue = None, payloadBinding!: ?AgentValue = None, payloadBody!: ?AgentValue = None,
        prepareParent!: Bool = true) {
        root = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(root + "/stream-intent.db")
        sink = SqliteThreadCommitSink(database)
        store = DurableOperationStore(database)
        let grant = streamContractLaunchGrant()
        if (payloadBinding.isSome()) { grant.put("protocol_limits", capacityStoreProfile()) }
        match (payloadGrant) { case Some(value) => grant.put("payload_limits", streamContractClone(value)); case None => () }
        match (readOnlyGrant) { case Some(value) => grant.put("read_only_tools", streamContractClone(value)); case None => () }
        completeStreamContractStartup(database, sink, store, grant, startupMode)
        let binding = streamContractBinding(grant)
        if (payloadBinding.isSome()) { binding.put("protocol_limits", capacityStoreProfile()) }
        match (payloadBinding) { case Some(value) => binding.put("payload_limits", streamContractClone(value)); case None => () }
        if (readOnlyBinding != "") { binding.put("read_only_tool", textValue(readOnlyBinding)) }
        if (bindingField != "") { binding.put(bindingField, textValue(bindingValue)) }
        rootPlan = streamContractParent(binding, readOnly: readOnly, toolName: toolName, replay: replay, payloadBody: payloadBody)
        childPlan = streamContractChild(httpContractRequire(
            httpStreamServiceChildArguments(rootPlan.canonicalArguments, "write-1"), "frozen channel child"))
        expect(!expectPair || (isFrozenHttpStreamParentPlan(rootPlan) && isHttpStreamServiceChildPlan(childPlan) &&
            httpStreamServiceChildAllowed(rootPlan, childPlan)), "fixture begins with a valid exact Domain pair")
        coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("stream-contract", StoreEstimator()), { => 30 })
        let active = httpContractRequire(runtime.startTurn(turn, run, ItemId("stream-user"),
            ThreadItemContent.UserMessage(textMessageParts("use channel")), recoveryLane(), InvocationContextProjection()),
            "actual target Run")
        epoch = active.epoch
        call = ToolCall("stream-parent-call", rootPlan.toolName, rootPlan.canonicalArguments.field("input").getOrThrow())
        if (committed) {
            let reference = commitDurableToolCall(database, coordinator, thread, turn, run, epoch, 1,
                item, call.callId, call.name, call.arguments, 30)
            source = OperationRootSource.Committed(reference)
            if (prepareParent) { httpContractRequire(store.prepare(parent, run, reference, rootPlan), "channel Committed parent") }
        } else {
            expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread, turn, run, epoch, 1,
                ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                    ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))),
                "target Direct ToolCall is canonical")
            source = OperationRootSource.Direct(httpContractRequire(runtime.attestDirectToolCall(item, parent, run, epoch),
                "sealed channel Direct source"))
            if (prepareParent) { httpContractRequire(store.prepareTrustedControlOperation(parent, run, item, rootPlan), "channel Direct parent") }
        }
        key = "http-stream-service:" + call.callId + ":write-1"
        if (prepareParent) {
        let restored = httpContractRequire(store.loadCall(parent, run), "restore original channel approval input")
        expect(!expectPair || (restored.callId == call.callId && restored.name == call.name &&
            canonicalAgentValue(restored.arguments) == canonicalAgentValue(call.arguments)),
            "Store loadCall unwraps only the verified channel envelope and retains canonical call identity")
        }
    }

    func activateParent(handoff!: Bool = true): Unit {
        httpContractRequire(store.waitForApproval(parent, run), "parent waits for actual approval")
        httpContractRequire(store.recordApproval("stream-parent-approved", parent, run, rootPlan,
            CapabilitySet(values: rootPlan.requiredCapabilities), true, "user", None), "parent exact User approval")
        httpContractRequire(store.markExecuting(parent, run, rootPlan, 31, true), "approved parent executing")
        if (handoff) { httpContractRequire(store.markExecutionHandoff(parent, run, thread, 32), "approved parent handoff") }
    }
    func admit(): Result<OperationId> { store.prepareDerivedOperation(child, parent, run, source, key, childPlan) }
    func execute(): Unit { httpContractRequire(store.markExecuting(child, run, childPlan, 34, false), "ParentIntent child executing") }
    func handoff(): Unit { httpContractRequire(store.markExecutionHandoff(child, run, thread, 35), "ParentIntent child handoff") }
    func receipt(outcome: OperationOutcome): VNextOperationReceipt {
        VNextOperationReceipt("receipt-stream-child", child, outcome,
            objectValue([ValueField("observed", textValue("bounded channel result"))]), objectValue([]), 36)
    }
    func close(): Unit { database.close(); remove(root, recursive: true) }
}

func completeStreamContractStartup(database: SqliteDatabase, sink: SqliteThreadCommitSink,
    store: DurableOperationStore, grant: AgentValue, mode: String): Unit {
    let thread = ThreadId("stream-startup-thread"); let run = RunId("stream-startup-run")
    let operation = OperationId("stream-startup-operation"); let item = ItemId("stream-startup-item")
    let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
    let runtime = AgentThreadRuntime(coordinator, ContextProjector("stream-startup", StoreEstimator()), { => 10 })
    let origin = HostServiceOrigin("session", "axyndra:stream-contract", "sha256:" + STREAM_CONTRACT_DIGEST,
        STREAM_CONTRACT_DIGEST, "stream-instance", HostServiceAction.Start, "stream-startup-call")
    let admission = httpContractRequire(runtime.startHostServiceTurn(SemanticTurnId("stream-startup-turn"), run,
        ItemId("stream-startup-initiator"), origin, recoveryLane(), InvocationContextProjection()), "actual HTTP startup HostService Run")
    let args = objectValue([ValueField("grant", grant), ValueField("resource_id", textValue("stream-lease"))])
    let call = ToolCall("stream-startup-call", "host.plugin.http.lifecycle", args)
    let direct = httpContractRequire(runtime.commitHostServiceToolCall(admission, item, operation, call, run,
        admission.run.epoch), "canonical HTTP startup source")
    let requirements = ArrayList<Capability>()
    if (mode != "startup-missing-invoke") { requirements.add(Capability(CapabilityKind.ExtensionInvoke)) }
    let network = if (mode == "startup-wrong-network") {
        NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule("other.example", 443u16)])
    } else { streamContractNetwork() }
    if (mode != "startup-missing-network") {
        requirements.add(Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(network.egress[0])))
    }
    let plan = NormalizedOperationPlan(call.name, args, requirements.toArray(),
        OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never,
        modelPolicySha256Text(canonicalAgentValue(args)),
        toolVersion: if (mode == "startup-wrong-version") { "wrong-version" } else { "host-plugin-http-lifecycle-v1" },
        implementationFingerprint: "host-plugin-http-lifecycle-v1", networkPolicy: Some(network),
        replayDisposition: Some(if (mode == "startup-safe-replay") { ReplayDisposition.SafeReplay } else { ReplayDisposition.NeverReplay }))
    let source = OperationRootSource.Direct(direct)
    httpContractRequire(store.prepareDirectOperation(direct, plan), "HTTP startup prepared from real sealed source")
    expect(store.verifyHttpStreamMaintenanceExecuting(operation, run, thread, admission.run.epoch, source, plan).isError(),
        "prepared source and plan do not substitute for an executing handoff")
    httpContractRequire(store.waitForApproval(operation, run), "HTTP startup actual approval boundary")
    httpContractRequire(store.recordApproval("stream-startup-approved", operation, run, plan,
        CapabilitySet(values: plan.requiredCapabilities), true, "operator", None), "HTTP startup explicit approval")
    httpContractRequire(store.markExecuting(operation, run, plan, 11, true), "HTTP startup authorized execution")
    expect(store.verifyHttpStreamMaintenanceExecuting(operation, run, thread, admission.run.epoch, source, plan).isError(),
        "Executing without final handoff is not HTTP I/O authority")
    httpContractRequire(store.markExecutionHandoff(operation, run, thread, 12), "HTTP startup actual handoff")
    if (mode != "startup-wrong-version" && mode != "startup-safe-replay") {
        httpContractRequire(store.verifyHttpStreamMaintenanceExecuting(operation, run, thread, admission.run.epoch, source, plan),
            "current actual HTTP maintenance handoff is inspectable")
    }
    let result = objectValue([ValueField("schema", textValue("axyndra.http-service-start-result/v1")),
        ValueField("resource_id", textValue("stream-lease")),
        ValueField("grant_digest", textValue(modelPolicySha256Text(canonicalAgentValue(grant)))),
        ValueField("endpoint_identity", textValue(STREAM_CONTRACT_DIGEST)), ValueField("directory", listValue([]))])
    expect(store.verifyHttpStreamMaintenanceCommitted(operation, run, thread, admission.run.epoch, source, plan, result).isError(),
        "unsettled HTTP maintenance cannot activate a service")
    let resolved = httpContractRequire(runtime.resolveOperation(ItemId("stream-startup-result"), operation,
        CanonicalToolCallId(call.callId), plan, OperationAttemptStage.Executing,
        Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, result))),
        "receipt-stream-startup", 13, expectedRunId: Some(run), expectedEpoch: Some(admission.run.epoch)), "HTTP canonical settlement")
    expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()), "HTTP startup commits actual facts")
    expect(store.verifyHttpStreamMaintenanceCommitted(operation, run, thread, admission.run.epoch, source, plan, result).isError(),
        "Receipt before completed Run/Turn does not activate HTTP service")
    httpContractRequire(runtime.finish(RunState.Completed, 1000), "HTTP startup Run completes")
    expect(store.verifyHttpStreamMaintenanceExecuting(operation, run, thread, admission.run.epoch, source, plan).isError(),
        "completed startup does not authorize more HTTP effects")
    if (!["startup-wrong-version", "startup-safe-replay", "startup-missing-network", "startup-missing-invoke", "startup-wrong-network"].contains(mode)) {
        httpContractRequire(store.verifyHttpStreamMaintenanceCommitted(operation, run, thread, admission.run.epoch, source, plan, result),
            "exact complete startup result is available as retained-resource evidence")
        let changed = streamContractClone(result); changed.put("resource_id", textValue("foreign-resource"))
        expect(store.verifyHttpStreamMaintenanceCommitted(operation, run, thread, admission.run.epoch, source, plan, changed).isError(),
            "returned output cannot rewrite committed startup facts")
    }
    expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE id='stream-startup-run' AND state='completed'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='system_note'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 0 &&
        database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0,
        "HTTP startup retains actual HostService source without fabricated user/model facts")
}

func httpStreamServiceIntentContract(): Unit {
    var scenarios: Int64 = 0
    for (committed in [false, true]) {
        for (scenario in ["completed", "unknown-replay", "pending-parent", "no-parent-handoff", "changed-bytes",
            "changed-resource", "bound-resource", "bound-launch", "bound-package", "bound-config", "bound-instance",
            "bound-permission", "bound-workspace", "different-request-key", "wrong-parent", "nested-parent", "target-thread",
            "startup-id", "startup-run", "startup-turn", "startup-active-run", "startup-active-turn",
            "startup-missing-network", "startup-missing-invoke", "startup-wrong-version", "startup-wrong-network", "startup-safe-replay",
            "startup-epoch", "startup-receipt", "startup-result", "startup-origin",
            "startup-handoff", "parent-epoch", "parent-audit", "execution-startup-recheck", "handoff-startup-recheck",
            "settlement-startup-recheck"]) {
            httpStreamServiceIntentScenario(committed, scenario)
            scenarios += 1
        }
        for (stage in ["executing", "executing_unhanded", "prepared", "waiting_approval"]) {
            httpStreamServiceCancellationScenario(committed, stage)
            scenarios += 1
        }
    }
    expect(scenarios == 82, "all channel Store scenarios actually executed")
    println("HTTP stream ParentIntent durable contract passed: 82 scenarios, real maintenance handoff and completed startup")
}

func httpStreamServiceIntentScenario(committed: Bool, scenario: String): Unit {
    let field = if (scenario == "target-thread") { "target_thread_id" }
        else if (scenario == "startup-id") { "startup_operation_id" }
        else if (scenario == "bound-resource") { "resource_id" }
        else if (scenario == "bound-launch") { "grant_digest" }
        else if (scenario == "bound-package") { "package_digest" }
        else if (scenario == "bound-config") { "configuration_digest" }
        else if (scenario == "bound-instance") { "instance_identity" }
        else if (scenario == "bound-permission") { "permission_domain" }
        else if (scenario == "bound-workspace") { "workspace_root" } else { "" }
    let changedDigest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let value = if (["bound-launch", "bound-config", "bound-permission"].contains(scenario)) { changedDigest }
        else if (scenario == "bound-package") { "sha256:" + changedDigest }
        else if (scenario == "bound-workspace") { "/other/workspace" } else { "another-identity" }
    let fixture = HttpStreamIntentStoreFixture(committed, bindingField: field, bindingValue: value, startupMode: scenario)
    let label = (if (committed) { "Committed " } else { "Direct " }) + scenario
    let database = fixture.database
    let store = fixture.store
    try {
        if (scenario != "pending-parent") { fixture.activateParent(handoff: scenario != "no-parent-handoff") }
        if (scenario == "startup-run") { database.execute("UPDATE runs SET state='running' WHERE id='stream-startup-run'") }
        if (scenario == "startup-turn") { database.execute("UPDATE turns SET state='running' WHERE id='stream-startup-turn'") }
        if (scenario == "startup-active-run") {
            database.execute("UPDATE turns SET active_run_id='stream-startup-run' WHERE id='stream-startup-turn'")
        }
        if (scenario == "startup-active-turn") {
            database.execute("UPDATE threads SET active_turn_id='stream-startup-turn' WHERE id='stream-startup-thread'")
        }
        if (scenario == "startup-epoch") { database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='stream-startup-run'") }
        if (scenario == "startup-receipt") {
            database.execute("UPDATE operation_receipts SET outcome='unknown' WHERE operation_id='stream-startup-operation'")
        }
        if (scenario == "startup-result") {
            database.execute("UPDATE items SET payload=? WHERE id='stream-startup-result'", [SqlParameter.Text(
                encodeStoredThreadContent(ThreadItemContent.ToolResult(CanonicalToolCallId("stream-startup-call"),
                    OperationId("stream-startup-operation"), "receipt-stream-startup", objectValue([]), false)))])
        }
        if (scenario == "startup-origin") {
            database.execute("UPDATE audit_events SET payload=? WHERE operation_id='stream-startup-operation' AND kind='operation_host_origin_bound'",
                [SqlParameter.Text(encodeStoredValue(objectValue([])))])
        }
        if (scenario == "startup-handoff") {
            database.execute("DELETE FROM audit_events WHERE operation_id='stream-startup-operation' AND kind='operation_execution_handoff'")
        }
        if (scenario == "parent-epoch") { database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='stream-target-run'") }
        let arguments = streamContractClone(fixture.childPlan.canonicalArguments)
        if (scenario == "changed-bytes") { arguments.field("intent").getOrThrow().field("request").getOrThrow().put("body_hex", textValue("68656c6c6f21")) }
        if (scenario == "changed-resource") { arguments.field("binding").getOrThrow().put("resource_id", textValue("other-lease")) }
        let candidate = streamContractChild(arguments)
        let key = if (scenario == "different-request-key") { fixture.key + "-retry" } else { fixture.key }
        let parent = if (scenario == "wrong-parent") { OperationId("missing-parent") } else { fixture.parent }
        let admitted = store.prepareDerivedOperation(fixture.child, parent, fixture.run, fixture.source, key, candidate)
        let successful = ["completed", "unknown-replay", "nested-parent", "parent-audit", "execution-startup-recheck",
            "handoff-startup-recheck", "settlement-startup-recheck"].contains(scenario)
        if (!successful) {
            expect(admitted.isError(), label + " rejects missing or modified authority before admission")
            expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='stream-child'") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'") == 0,
                label + " failure rolls back all child state and authorization")
            return
        }
        httpContractRequire(admitted, label + " admission")
        let evidence = decodeStoredValue(database.query("SELECT payload FROM audit_events WHERE operation_id='stream-child' AND kind='operation_parent_intent_authorized'")[0].required(0))
        expect(httpIntentText(evidence, "authorization_source") == "parent_intent" &&
            httpIntentText(evidence, "root_source") == (if (committed) { "committed" } else { "direct" }) &&
            httpIntentText(evidence, "parent_plan_digest") == fixture.rootPlan.bindingDigest &&
            httpIntentText(evidence, "child_plan_digest") == fixture.childPlan.bindingDigest &&
            httpIntentText(evidence, "request_key") == fixture.key &&
            database.scalarInt("SELECT COUNT(*) FROM approvals WHERE operation_id='stream-child'") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM approval_decisions WHERE operation_id='stream-child'") == 0,
            label + " ParentIntent records exact source without manufacturing User approval")
        if (scenario == "nested-parent") {
            expect(store.prepareDerivedOperation(OperationId("stream-grandchild"), fixture.child,
                fixture.run, fixture.source, fixture.key, fixture.childPlan).isError(), label + " cannot nest a derived parent")
            return
        }
        if (scenario == "parent-audit") {
            database.execute("UPDATE audit_events SET payload=? WHERE operation_id='stream-child' AND kind='operation_parent_intent_authorized'",
                [SqlParameter.Text(encodeStoredValue(objectValue([])))])
            expect(store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 34, false).isError(),
                label + " approved=false cannot bypass durable ParentIntent proof")
            return
        }
        let startupDetail = database.query("SELECT detail FROM operation_receipts WHERE operation_id='stream-startup-operation'")[0].required(0)
        if (scenario == "execution-startup-recheck") {
            streamContractCorruptStartup(database)
            expect(store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 34, false).isError(),
                label + " execution rechecks exact completed startup")
            streamContractRestoreStartup(database, startupDetail)
        }
        fixture.execute()
        if (scenario == "handoff-startup-recheck") {
            streamContractCorruptStartup(database)
            expect(store.markExecutionHandoff(fixture.child, fixture.run, fixture.thread, 35).isError(),
                label + " final handoff rechecks startup before bytes can be written")
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='stream-child' AND kind='operation_execution_handoff'") == 0,
                label + " failed proof produces no handoff")
            streamContractRestoreStartup(database, startupDetail)
        }
        fixture.handoff()
        let outcome = if (scenario == "unknown-replay") { OperationOutcome.Unknown } else { OperationOutcome.Completed }
        let receipt = fixture.receipt(outcome)
        if (scenario == "settlement-startup-recheck") {
            streamContractCorruptStartup(database)
            expect(store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError(),
                label + " settlement cannot forget exact lease startup provenance")
            streamContractRestoreStartup(database, startupDetail)
        }
        httpContractRequire(store.settleDerivedOperation(fixture.run, fixture.parent, receipt), label + " settlement")
        let replay = httpContractRequire(store.prepareDerivedOperation(OperationId("stream-replay"), fixture.parent,
            fixture.run, fixture.source, fixture.key, fixture.childPlan), label + " replay identity")
        expect(replay.value == fixture.child.value && store.markExecuting(replay, fixture.run, fixture.childPlan, 40, false).isError() &&
            store.markExecutionHandoff(replay, fixture.run, fixture.thread, 40).isError() &&
            store.prepareDerivedOperation(OperationId("stream-new-transport"), fixture.parent, fixture.run, fixture.source,
                fixture.key + "-other", fixture.childPlan).isError() &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='stream-child'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 1 && database.query("PRAGMA foreign_key_check").isEmpty(),
            label + " terminal channel write retains one Receipt and cannot re-execute under a fresh transport ID")
    } finally { fixture.close() }
}

func streamContractCorruptStartup(database: SqliteDatabase): Unit {
    database.execute("UPDATE operation_receipts SET detail=? WHERE operation_id='stream-startup-operation'",
        [SqlParameter.Text(encodeStoredValue(objectValue([])))])
}
func streamContractRestoreStartup(database: SqliteDatabase, detail: String): Unit {
    database.execute("UPDATE operation_receipts SET detail=? WHERE operation_id='stream-startup-operation'", [SqlParameter.Text(detail)])
}

func httpStreamServiceCancellationScenario(committed: Bool, stage: String): Unit {
    let fixture = HttpStreamIntentStoreFixture(committed)
    let database = fixture.database
    let store = fixture.store
    try {
        fixture.activateParent()
        httpContractRequire(fixture.admit(), "cancellation child admission")
        if (stage.startsWith("executing")) {
            fixture.execute()
            if (stage == "executing") { fixture.handoff() }
        }
        else if (stage == "waiting_approval") { httpContractRequire(store.waitForApproval(fixture.child, fixture.run), "unhanded child waits") }
        // Executing remains conservatively uncertain even if the final
        // handoff audit is absent. No actual byte IO is claimed by this test.
        let outcome = if (stage.startsWith("executing")) { OperationOutcome.Unknown } else { OperationOutcome.Rejected }
        let receipt = fixture.receipt(outcome)
        let token = httpContractRequire(fixture.runtime.childCancellationToken(expectedRunId: Some(fixture.run),
            expectedEpoch: Some(fixture.epoch)), "owned channel cancellation token")
        let task = spawn {
            let deadline = agentUtcMillis() + 3000
            while (!token.isCancelled() && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
            expect(token.isCancelled() && database.query("SELECT state FROM runs WHERE id='stream-target-run'")[0].required(0) == "cancelling",
                "channel cleanup occurs in an actual cancelling Run")
            expect(fixture.admit().isError() && store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 40, false).isError() &&
                store.markExecutionHandoff(fixture.child, fixture.run, fixture.thread, 40).isError(),
                "cleanup permission cannot create new admission, execution or handoff")
            for (forbidden in [OperationOutcome.Completed, OperationOutcome.Failed]) {
                expect(store.settleDerivedOperation(fixture.run, fixture.parent, fixture.receipt(forbidden)).isError(),
                    "cancelling channel cannot claim known success or failure")
            }
            expect(store.settleDerivedOperation(fixture.run, fixture.parent,
                fixture.receipt(if (stage.startsWith("executing")) { OperationOutcome.Rejected } else { OperationOutcome.Unknown })).isError(),
                "cancellation cannot downgrade an executing child or invent execution from preparation")
            database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='stream-target-run'")
            expect(store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError(), "cancellation retains original epoch")
            database.execute("UPDATE runs SET epoch=epoch-1 WHERE id='stream-target-run'")
            let startupDetail = database.query("SELECT detail FROM operation_receipts WHERE operation_id='stream-startup-operation'")[0].required(0)
            streamContractCorruptStartup(database)
            expect(store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError(), "cancellation retains exact startup proof")
            streamContractRestoreStartup(database, startupDetail)
            httpContractRequire(store.settleDerivedOperation(fixture.run, fixture.parent, receipt), "existing channel obligation settles")
            let parentResult = httpContractRequire(fixture.runtime.resolveOperation(ItemId("stream-parent-result"), fixture.parent,
                CanonicalToolCallId(fixture.call.callId), fixture.rootPlan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Cancelled, "channel.cancelled", "owned channel cancelled")),
                "receipt-stream-parent", 42, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)),
                "parent cancellation canonical receipt")
            expect(parentResult.semanticCommit.isSome() && isStoreCommitted(parentResult.semanticCommit.getOrThrow()),
                "cancelled parent has actual ToolResult and Receipt")
        }
        httpContractRequire(fixture.runtime.ownTask("stream-settlement", task), "runtime owns channel cleanup worker")
        let cancelled = fixture.runtime.cancel(5000, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch))
        task.get()
        httpContractRequire(cancelled, "runtime cancellation joins existing channel obligation")
        let retained = httpContractRequire(store.loadDerivedOperationReceipt(fixture.child, fixture.run), "load cancelled channel Receipt").getOrThrow()
        expect(retained.outcome == outcome && database.query("SELECT state FROM runs WHERE id='stream-target-run'")[0].required(0) == "cancelled" &&
            store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 44, false).isError() &&
            store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError() &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='stream-child'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='stream-child' AND kind='operation_execution_handoff'") ==
                (if (stage == "executing") { 1 } else { 0 }) && database.query("PRAGMA foreign_key_check").isEmpty(),
            "terminal cancellation keeps one truthful child outcome and never resumes bytes")
    } finally { fixture.close() }
}
