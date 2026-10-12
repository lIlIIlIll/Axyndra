package agent_store_contract

import std.fs.*
import std.collection.*
import std.time.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

// SQLite/runtime facts only: no process is opened by this contract. The
// Product lease owner separately proves that the bound channel is still live.
let CHANNEL_CONTRACT_DIGEST = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func channelContractClone(value: AgentValue): AgentValue {
    parseUnifiedJson(stringifyUnifiedJson(value))
}

func channelContractLaunchGrant(): AgentValue {
    objectValue([
        ValueField("schema", textValue("axyndra.lifecycle-launch/v1")),
        ValueField("namespace", textValue("axyndra:channel-contract")),
        ValueField("package_digest", textValue("sha256:" + CHANNEL_CONTRACT_DIGEST)),
        ValueField("configuration_digest", textValue(CHANNEL_CONTRACT_DIGEST)),
        ValueField("service_id", textValue("session")),
        ValueField("thread_id", textValue("channel-target-thread")),
        ValueField("instance_identity", textValue("channel-instance")),
        ValueField("permission_domain", textValue(CHANNEL_CONTRACT_DIGEST)),
        ValueField("package_root", textValue("/fixture/package")),
        ValueField("workspace_root", textValue("/fixture/workspace")),
        ValueField("workspace_mode", textValue("workspace_readonly")),
        ValueField("cwd", textValue("/fixture/workspace")),
        ValueField("executable", textValue("/usr/bin/cat")),
        ValueField("executable_authored", textValue("/usr/bin/cat")),
        ValueField("executable_sha256", textValue(CHANNEL_CONTRACT_DIGEST)),
        ValueField("executable_bytes", integerValue(1)),
        ValueField("arguments", listValue([])), ValueField("read_only_mounts", listValue([])),
        ValueField("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied))),
        ValueField("resources", objectValue([
            ValueField("max_output_bytes", integerValue(65536)), ValueField("address_space_bytes", integerValue(268435456)),
            ValueField("file_size_bytes", integerValue(1048576)), ValueField("open_files", integerValue(64)),
            ValueField("processes", integerValue(8)), ValueField("cpu_seconds", integerValue(10))])),
        ValueField("max_instances", integerValue(1)), ValueField("lifetime_ms", integerValue(10000)),
        ValueField("max_input_bytes", integerValue(65536)), ValueField("max_output_bytes", integerValue(65536)),
        ValueField("startup", objectValue([ValueField("timeout_ms", integerValue(1000)),
            ValueField("max_input_bytes", integerValue(1024)), ValueField("max_output_bytes", integerValue(1024)),
            ValueField("max_writes", integerValue(2))])),
        ValueField("environment", objectValue([])), ValueField("credential_refs", listValue([])),
        ValueField("content_binding", textValue("executable-only; other readable files remain authorized path content")),
        ValueField("effect", textValue("conservative lifecycle window; never read-only by protocol annotation"))
    ])
}

func channelContractBinding(grant: AgentValue): AgentValue {
    objectValue([
        ValueField("plugin", grant.field("namespace").getOrThrow()),
        ValueField("package_digest", grant.field("package_digest").getOrThrow()),
        ValueField("configuration_digest", grant.field("configuration_digest").getOrThrow()),
        ValueField("instance_identity", grant.field("instance_identity").getOrThrow()),
        ValueField("endpoint_identity", textValue(CHANNEL_CONTRACT_DIGEST)),
        ValueField("lease_id", textValue("channel-lease")),
        ValueField("launch_digest", textValue(modelPolicySha256Text(canonicalAgentValue(grant)))),
        ValueField("startup_operation_id", textValue("channel-startup-operation")),
        ValueField("target_thread_id", grant.field("thread_id").getOrThrow()),
        ValueField("permission_domain", grant.field("permission_domain").getOrThrow()),
        ValueField("directory_revision", integerValue(1)), ValueField("directory_digest", textValue(CHANNEL_CONTRACT_DIGEST)),
        ValueField("implementation_version", textValue("1.0.0")),
        ValueField("implementation_fingerprint", textValue("owned-v1:" + CHANNEL_CONTRACT_DIGEST)),
        ValueField("schema_digest", textValue(CHANNEL_CONTRACT_DIGEST)),
        ValueField("workspace_root", grant.field("workspace_root").getOrThrow()),
        ValueField("workspace_mode", grant.field("workspace_mode").getOrThrow()),
        ValueField("network", grant.field("network").getOrThrow())
    ])
}

func channelContractParent(binding: AgentValue, readOnly!: Bool = false, toolName!: String = "",
    replay!: ?ReplayDisposition = None, bytesHex!: String = "68656c6c6f0a", payloadIntent!: ?AgentValue = None,
    managedJob!: ?ManagedJobDeclaration = None): NormalizedOperationPlan {
    let arguments = objectValue([
        ValueField("input", objectValue([ValueField("query", textValue("frozen request"))])),
        ValueField("configuration", objectValue([])),
        ValueField("host_plan", objectValue([
            ValueField("version", textValue(if (payloadIntent.isSome()) { HOST_CHANNEL_PAYLOAD_INTENT_VERSION } else { HOST_CHANNEL_INTENT_VERSION })), ValueField("binding", binding),
            ValueField("intents", listValue([payloadIntent ?? objectValue([
                ValueField("id", textValue("write-1")), ValueField("bytes_hex", textValue(bytesHex))])]))]))
    ])
    let capabilities = ArrayList<Capability>(httpContractRequire(channelServiceRequiredCapabilities(binding), "channel capabilities"))
    match (managedJob) {
        case Some(value) =>
            arguments.field("host_plan").getOrThrow().put("managed_job", managedJobDeclarationValue(value))
            capabilities.add(Capability(CapabilityKind.Delegate, resource: "managed-job"))
        case None => ()
    }
    NormalizedOperationPlan(if (toolName == "") { "plugin.axyndra:channel-contract.echo" } else { toolName }, arguments,
        capabilities.toArray(),
        if (readOnly) { OperationEffectClass.ReadOnly } else { OperationEffectClass.ExternalMutation }, OperationRetryDisposition.Never,
        modelPolicySha256Text(canonicalAgentValue(arguments)), toolVersion: "1.0.0",
        implementationFingerprint: "owned-v1:" + CHANNEL_CONTRACT_DIGEST, schemaDigest: CHANNEL_CONTRACT_DIGEST, replayDisposition: Some(replay ?? ReplayDisposition.NeverReplay))
}

func channelContractChild(arguments: AgentValue): NormalizedOperationPlan {
    let binding = arguments.field("binding").getOrThrow()
    NormalizedOperationPlan(HOST_CHANNEL_WRITE_TOOL, arguments,
        httpContractRequire(channelServiceRequiredCapabilities(binding), "child channel capabilities"),
        OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never,
        modelPolicySha256Text(canonicalAgentValue(arguments)),
        networkPolicy: Some(parseNetworkPolicy(binding.field("network").getOrThrow()).value().getOrThrow()),
        implementationFingerprint: HOST_CHANNEL_WRITE_FINGERPRINT)
}

class ChannelIntentStoreFixture {
    let root: String
    let database: SqliteDatabase
    let sink: SqliteThreadCommitSink
    let store: DurableOperationStore
    let coordinator: ThreadCoordinator
    let runtime: AgentThreadRuntime
    let thread = ThreadId("channel-target-thread")
    let turn = SemanticTurnId("channel-target-turn")
    let run = RunId("channel-target-run")
    let item = ItemId("channel-parent-item")
    let parent = OperationId("channel-parent")
    let child = OperationId("channel-child")
    let epoch: Int64
    let call: ToolCall
    let source: OperationRootSource
    let rootPlan: NormalizedOperationPlan
    let childPlan: NormalizedOperationPlan
    let key: String

    init(committed: Bool, bindingField!: String = "", bindingValue!: String = "", startupMode!: String = "",
        readOnly!: Bool = false, readOnlyGrant!: ?AgentValue = None, readOnlyBinding!: String = "",
        toolName!: String = "", replay!: ?ReplayDisposition = None, expectPair!: Bool = true,
        grantProfile!: ?AgentValue = None, bindingProfile!: ?AgentValue = None, bytesHex!: String = "68656c6c6f0a",
        payloadProfile!: ?AgentValue = None, payloadBinding!: ?AgentValue = None, payloadIntent!: ?AgentValue = None,
        prepareParent!: Bool = true, managedJob!: ?ManagedJobDeclaration = None) {
        root = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(root + "/channel-intent.db")
        sink = SqliteThreadCommitSink(database)
        store = DurableOperationStore(database)
        let grant = channelContractLaunchGrant()
        match (readOnlyGrant) { case Some(value) => grant.put("read_only_tools", channelContractClone(value)); case None => () }
        match (grantProfile) { case Some(value) => grant.put("protocol_limits", channelContractClone(value)); case None => () }
        match (payloadProfile) { case Some(value) => grant.put("payload_limits", channelContractClone(value)); case None => () }
        completeChannelContractStartup(database, sink, store, grant, startupMode)
        let binding = channelContractBinding(grant)
        match (bindingProfile) { case Some(value) => binding.put("protocol_limits", channelContractClone(value)); case None => () }
        match (payloadBinding) { case Some(value) => binding.put("payload_limits", channelContractClone(value)); case None => () }
        if (readOnlyBinding != "") { binding.put("read_only_tool", textValue(readOnlyBinding)) }
        if (bindingField != "") { binding.put(bindingField, textValue(bindingValue)) }
        rootPlan = channelContractParent(binding, readOnly: readOnly, toolName: toolName, replay: replay, bytesHex: bytesHex, payloadIntent: payloadIntent, managedJob: managedJob)
        childPlan = channelContractChild(httpContractRequire(
            channelServiceChildArguments(rootPlan.canonicalArguments, "write-1"), "frozen channel child"))
        expect(!expectPair || (isFrozenChannelParentPlan(rootPlan) && isChannelServiceChildPlan(childPlan) &&
            channelServiceChildAllowed(rootPlan, childPlan)), "fixture begins with a valid exact Domain pair")
        coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("channel-contract", StoreEstimator()),
            if (managedJob.isSome()) { { => agentUtcMillis() } } else { { => 30 } })
        let active = httpContractRequire(runtime.startTurn(turn, run, ItemId("channel-user"),
            ThreadItemContent.UserMessage(textMessageParts("use channel")), recoveryLane(), InvocationContextProjection()),
            "actual target Run")
        epoch = active.epoch
        call = ToolCall("channel-parent-call", rootPlan.toolName, rootPlan.canonicalArguments.field("input").getOrThrow())
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
        key = "channel-service:" + call.callId + ":write-1"
        if (prepareParent) {
            let restored = httpContractRequire(store.loadCall(parent, run), "restore original channel approval input")
            expect(!expectPair || (restored.callId == call.callId && restored.name == call.name &&
                canonicalAgentValue(restored.arguments) == canonicalAgentValue(call.arguments)),
                "Store loadCall unwraps only the verified channel envelope and retains canonical call identity")
        }
    }

    func activateParent(handoff!: Bool = true): Unit {
        httpContractRequire(store.waitForApproval(parent, run), "parent waits for actual approval")
        httpContractRequire(store.recordApproval("channel-parent-approved", parent, run, rootPlan,
            CapabilitySet(values: rootPlan.requiredCapabilities), true, "user", None), "parent exact User approval")
        httpContractRequire(store.markExecuting(parent, run, rootPlan, 31, true), "approved parent executing")
        if (handoff) { httpContractRequire(store.markExecutionHandoff(parent, run, thread, 32), "approved parent handoff") }
    }
    func admit(): Result<OperationId> { store.prepareDerivedOperation(child, parent, run, source, key, childPlan) }
    func execute(): Unit { httpContractRequire(store.markExecuting(child, run, childPlan, 34, false), "ParentIntent child executing") }
    func handoff(): Unit { httpContractRequire(store.markExecutionHandoff(child, run, thread, 35), "ParentIntent child handoff") }
    func receipt(outcome: OperationOutcome): VNextOperationReceipt {
        VNextOperationReceipt("receipt-channel-child", child, outcome,
            objectValue([ValueField("observed", textValue("bounded channel result"))]), objectValue([]), 36)
    }
    func close(): Unit { database.close(); remove(root, recursive: true) }
}

func completeChannelContractStartup(database: SqliteDatabase, sink: SqliteThreadCommitSink,
    store: DurableOperationStore, grant: AgentValue, mode: String): Unit {
    let thread = ThreadId("channel-startup-thread")
    let run = RunId("channel-startup-run")
    let operation = OperationId("channel-startup-operation")
    let item = ItemId("channel-startup-item")
    let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
    let runtime = AgentThreadRuntime(coordinator, ContextProjector("channel-startup", StoreEstimator()), { => 10 })
    let origin = HostServiceOrigin("session", "axyndra:channel-contract", "sha256:" + CHANNEL_CONTRACT_DIGEST,
        CHANNEL_CONTRACT_DIGEST, "channel-instance", HostServiceAction.Start, "channel-startup-request")
    let admission = httpContractRequire(runtime.startHostServiceTurn(SemanticTurnId("channel-startup-turn"), run,
        ItemId("channel-startup-initiator"), origin, recoveryLane(), InvocationContextProjection()), "actual startup HostService Run")
    let call = ToolCall("channel-startup-call", "host.plugin.lifecycle.start", grant)
    let _ = httpContractRequire(runtime.commitHostServiceToolCall(admission, item, operation, call, run,
        admission.run.epoch), "canonical startup source")
    // Negative cases create real canonical history from the wrong normalized
    // startup plan. They do not rewrite the resulting approval or Receipt.
    let requirements = ArrayList<Capability>()
    if (mode != "startup-missing-process") { requirements.add(Capability(CapabilityKind.ProcessSpawn)) }
    if (mode != "startup-missing-invoke") { requirements.add(Capability(CapabilityKind.ExtensionInvoke)) }
    if (mode != "startup-missing-workspace") { requirements.add(Capability(CapabilityKind.WorkspaceRead, resource: "/fixture/workspace")) }
    let network = if (mode == "startup-wrong-network") {
        NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule("other.example", 443u16)])
    } else { NetworkPolicy(NetworkPolicyMode.Denied) }
    if (mode == "startup-wrong-network") {
        requirements.add(Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(network.egress[0])))
    }
    let plan = NormalizedOperationPlan(call.name, grant, requirements.toArray(),
        OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never,
        modelPolicySha256Text(canonicalAgentValue(grant)), implementationFingerprint: "host-plugin-lifecycle-v1",
        networkPolicy: Some(network), replayDisposition: Some(if (mode == "startup-safe-replay") {
            ReplayDisposition.SafeReplay
        } else { ReplayDisposition.NeverReplay }))
    httpContractRequire(store.prepareTrustedControlOperation(operation, run, item, plan), "startup prepared")
    httpContractRequire(store.waitForApproval(operation, run), "startup actual approval boundary")
    httpContractRequire(store.recordApproval("channel-startup-approved", operation, run, plan,
        CapabilitySet(values: plan.requiredCapabilities), true, "operator", None), "startup explicit operator approval")
    httpContractRequire(store.markExecuting(operation, run, plan, 11, true), "startup authorized execution")
    httpContractRequire(store.markExecutionHandoff(operation, run, thread, 12), "startup actual handoff")
    let result = objectValue([ValueField("lease_id", textValue("channel-lease")),
        ValueField("launch_digest", textValue(modelPolicySha256Text(canonicalAgentValue(grant)))),
        ValueField("result", objectValue([ValueField("ready", boolValue(true))]))])
    let resolved = httpContractRequire(runtime.resolveOperation(ItemId("channel-startup-result"), operation,
        CanonicalToolCallId(call.callId), plan, OperationAttemptStage.Executing,
        Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, result))),
        "receipt-channel-startup", 13, expectedRunId: Some(run), expectedEpoch: Some(admission.run.epoch)),
        "startup Receipt and ToolResult are one real canonical commit")
    expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()),
        "startup canonical commit succeeded")
    httpContractRequire(runtime.finish(RunState.Completed, 1000), "startup Run completes before later channel intent")
    expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE id='channel-startup-run' AND state='completed'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='system_note'") == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 0 &&
        database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0,
        "completed startup contains genuine SystemNote origin and no fabricated user/model Decision")
}

func channelServiceIntentContract(): Unit {
    var scenarios: Int64 = 0
    for (committed in [false, true]) {
        for (scenario in ["completed", "unknown-replay", "pending-parent", "no-parent-handoff", "changed-bytes",
            "changed-lease", "bound-lease", "bound-launch", "bound-package", "bound-config", "bound-instance",
            "bound-permission", "bound-workspace", "different-request-key", "wrong-parent", "nested-parent", "target-thread",
            "startup-id", "startup-run", "startup-turn", "startup-active-run", "startup-active-turn",
            "startup-missing-process", "startup-missing-invoke", "startup-missing-workspace", "startup-wrong-network", "startup-safe-replay",
            "startup-epoch", "startup-receipt", "startup-result", "startup-origin",
            "startup-handoff", "parent-epoch", "parent-audit", "execution-startup-recheck", "handoff-startup-recheck",
            "settlement-startup-recheck"]) {
            channelServiceIntentScenario(committed, scenario)
            scenarios += 1
        }
        for (stage in ["executing", "executing_unhanded", "prepared", "waiting_approval"]) {
            channelServiceCancellationScenario(committed, stage)
            scenarios += 1
        }
    }
    expect(scenarios == 82, "all channel Store scenarios actually executed")
    println("Channel ParentIntent durable contract passed: 82 scenarios, canonical startup and actual cancellation")
}

func channelServiceIntentScenario(committed: Bool, scenario: String): Unit {
    let field = if (scenario == "target-thread") { "target_thread_id" }
        else if (scenario == "startup-id") { "startup_operation_id" }
        else if (scenario == "bound-lease") { "lease_id" }
        else if (scenario == "bound-launch") { "launch_digest" }
        else if (scenario == "bound-package") { "package_digest" }
        else if (scenario == "bound-config") { "configuration_digest" }
        else if (scenario == "bound-instance") { "instance_identity" }
        else if (scenario == "bound-permission") { "permission_domain" }
        else if (scenario == "bound-workspace") { "workspace_root" } else { "" }
    let changedDigest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let value = if (["bound-launch", "bound-config", "bound-permission"].contains(scenario)) { changedDigest }
        else if (scenario == "bound-package") { "sha256:" + changedDigest }
        else if (scenario == "bound-workspace") { "/other/workspace" } else { "another-identity" }
    let fixture = ChannelIntentStoreFixture(committed, bindingField: field, bindingValue: value, startupMode: scenario)
    let label = (if (committed) { "Committed " } else { "Direct " }) + scenario
    let database = fixture.database
    let store = fixture.store
    try {
        if (scenario != "pending-parent") { fixture.activateParent(handoff: scenario != "no-parent-handoff") }
        if (scenario == "startup-run") { database.execute("UPDATE runs SET state='running' WHERE id='channel-startup-run'") }
        if (scenario == "startup-turn") { database.execute("UPDATE turns SET state='running' WHERE id='channel-startup-turn'") }
        if (scenario == "startup-active-run") {
            database.execute("UPDATE turns SET active_run_id='channel-startup-run' WHERE id='channel-startup-turn'")
        }
        if (scenario == "startup-active-turn") {
            database.execute("UPDATE threads SET active_turn_id='channel-startup-turn' WHERE id='channel-startup-thread'")
        }
        if (scenario == "startup-epoch") { database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='channel-startup-run'") }
        if (scenario == "startup-receipt") {
            database.execute("UPDATE operation_receipts SET outcome='unknown' WHERE operation_id='channel-startup-operation'")
        }
        if (scenario == "startup-result") {
            database.execute("UPDATE items SET payload=? WHERE id='channel-startup-result'", [SqlParameter.Text(
                encodeStoredThreadContent(ThreadItemContent.ToolResult(CanonicalToolCallId("channel-startup-call"),
                    OperationId("channel-startup-operation"), "receipt-channel-startup", objectValue([]), false)))])
        }
        if (scenario == "startup-origin") {
            database.execute("UPDATE audit_events SET payload=? WHERE operation_id='channel-startup-operation' AND kind='operation_host_origin_bound'",
                [SqlParameter.Text(encodeStoredValue(objectValue([])))])
        }
        if (scenario == "startup-handoff") {
            database.execute("DELETE FROM audit_events WHERE operation_id='channel-startup-operation' AND kind='operation_execution_handoff'")
        }
        if (scenario == "parent-epoch") { database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='channel-target-run'") }
        let arguments = channelContractClone(fixture.childPlan.canonicalArguments)
        if (scenario == "changed-bytes") { arguments.field("intent").getOrThrow().put("bytes_hex", textValue("68656c6c6f21")) }
        if (scenario == "changed-lease") { arguments.field("binding").getOrThrow().put("lease_id", textValue("other-lease")) }
        let candidate = channelContractChild(arguments)
        let key = if (scenario == "different-request-key") { fixture.key + "-retry" } else { fixture.key }
        let parent = if (scenario == "wrong-parent") { OperationId("missing-parent") } else { fixture.parent }
        let admitted = store.prepareDerivedOperation(fixture.child, parent, fixture.run, fixture.source, key, candidate)
        let successful = ["completed", "unknown-replay", "nested-parent", "parent-audit", "execution-startup-recheck",
            "handoff-startup-recheck", "settlement-startup-recheck"].contains(scenario)
        if (!successful) {
            expect(admitted.isError(), label + " rejects missing or modified authority before admission")
            expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='channel-child'") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'") == 0,
                label + " failure rolls back all child state and authorization")
            return
        }
        httpContractRequire(admitted, label + " admission")
        let evidence = decodeStoredValue(database.query("SELECT payload FROM audit_events WHERE operation_id='channel-child' AND kind='operation_parent_intent_authorized'")[0].required(0))
        expect(httpIntentText(evidence, "authorization_source") == "parent_intent" &&
            httpIntentText(evidence, "root_source") == (if (committed) { "committed" } else { "direct" }) &&
            httpIntentText(evidence, "parent_plan_digest") == fixture.rootPlan.bindingDigest &&
            httpIntentText(evidence, "child_plan_digest") == fixture.childPlan.bindingDigest &&
            httpIntentText(evidence, "request_key") == fixture.key &&
            database.scalarInt("SELECT COUNT(*) FROM approvals WHERE operation_id='channel-child'") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM approval_decisions WHERE operation_id='channel-child'") == 0,
            label + " ParentIntent records exact source without manufacturing User approval")
        if (scenario == "nested-parent") {
            expect(store.prepareDerivedOperation(OperationId("channel-grandchild"), fixture.child,
                fixture.run, fixture.source, fixture.key, fixture.childPlan).isError(), label + " cannot nest a derived parent")
            return
        }
        if (scenario == "parent-audit") {
            database.execute("UPDATE audit_events SET payload=? WHERE operation_id='channel-child' AND kind='operation_parent_intent_authorized'",
                [SqlParameter.Text(encodeStoredValue(objectValue([])))])
            expect(store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 34, false).isError(),
                label + " approved=false cannot bypass durable ParentIntent proof")
            return
        }
        let startupDetail = database.query("SELECT detail FROM operation_receipts WHERE operation_id='channel-startup-operation'")[0].required(0)
        if (scenario == "execution-startup-recheck") {
            channelContractCorruptStartup(database)
            expect(store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 34, false).isError(),
                label + " execution rechecks exact completed startup")
            channelContractRestoreStartup(database, startupDetail)
        }
        fixture.execute()
        if (scenario == "handoff-startup-recheck") {
            channelContractCorruptStartup(database)
            expect(store.markExecutionHandoff(fixture.child, fixture.run, fixture.thread, 35).isError(),
                label + " final handoff rechecks startup before bytes can be written")
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='channel-child' AND kind='operation_execution_handoff'") == 0,
                label + " failed proof produces no handoff")
            channelContractRestoreStartup(database, startupDetail)
        }
        fixture.handoff()
        let outcome = if (scenario == "unknown-replay") { OperationOutcome.Unknown } else { OperationOutcome.Completed }
        let receipt = fixture.receipt(outcome)
        if (scenario == "settlement-startup-recheck") {
            channelContractCorruptStartup(database)
            expect(store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError(),
                label + " settlement cannot forget exact lease startup provenance")
            channelContractRestoreStartup(database, startupDetail)
        }
        httpContractRequire(store.settleDerivedOperation(fixture.run, fixture.parent, receipt), label + " settlement")
        let replay = httpContractRequire(store.prepareDerivedOperation(OperationId("channel-replay"), fixture.parent,
            fixture.run, fixture.source, fixture.key, fixture.childPlan), label + " replay identity")
        expect(replay.value == fixture.child.value && store.markExecuting(replay, fixture.run, fixture.childPlan, 40, false).isError() &&
            store.markExecutionHandoff(replay, fixture.run, fixture.thread, 40).isError() &&
            store.prepareDerivedOperation(OperationId("channel-new-transport"), fixture.parent, fixture.run, fixture.source,
                fixture.key + "-other", fixture.childPlan).isError() &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='channel-child'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 1 && database.query("PRAGMA foreign_key_check").isEmpty(),
            label + " terminal channel write retains one Receipt and cannot re-execute under a fresh transport ID")
    } finally { fixture.close() }
}

func channelContractCorruptStartup(database: SqliteDatabase): Unit {
    database.execute("UPDATE operation_receipts SET detail=? WHERE operation_id='channel-startup-operation'",
        [SqlParameter.Text(encodeStoredValue(objectValue([])))])
}
func channelContractRestoreStartup(database: SqliteDatabase, detail: String): Unit {
    database.execute("UPDATE operation_receipts SET detail=? WHERE operation_id='channel-startup-operation'", [SqlParameter.Text(detail)])
}

func channelServiceCancellationScenario(committed: Bool, stage: String): Unit {
    let fixture = ChannelIntentStoreFixture(committed)
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
            expect(token.isCancelled() && database.query("SELECT state FROM runs WHERE id='channel-target-run'")[0].required(0) == "cancelling",
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
            database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='channel-target-run'")
            expect(store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError(), "cancellation retains original epoch")
            database.execute("UPDATE runs SET epoch=epoch-1 WHERE id='channel-target-run'")
            let startupDetail = database.query("SELECT detail FROM operation_receipts WHERE operation_id='channel-startup-operation'")[0].required(0)
            channelContractCorruptStartup(database)
            expect(store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError(), "cancellation retains exact startup proof")
            channelContractRestoreStartup(database, startupDetail)
            httpContractRequire(store.settleDerivedOperation(fixture.run, fixture.parent, receipt), "existing channel obligation settles")
            let parentResult = httpContractRequire(fixture.runtime.resolveOperation(ItemId("channel-parent-result"), fixture.parent,
                CanonicalToolCallId(fixture.call.callId), fixture.rootPlan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Cancelled, "channel.cancelled", "owned channel cancelled")),
                "receipt-channel-parent", 42, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)),
                "parent cancellation canonical receipt")
            expect(parentResult.semanticCommit.isSome() && isStoreCommitted(parentResult.semanticCommit.getOrThrow()),
                "cancelled parent has actual ToolResult and Receipt")
        }
        httpContractRequire(fixture.runtime.ownTask("channel-settlement", task), "runtime owns channel cleanup worker")
        let cancelled = fixture.runtime.cancel(5000, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch))
        task.get()
        httpContractRequire(cancelled, "runtime cancellation joins existing channel obligation")
        let retained = httpContractRequire(store.loadDerivedOperationReceipt(fixture.child, fixture.run), "load cancelled channel Receipt").getOrThrow()
        expect(retained.outcome == outcome && database.query("SELECT state FROM runs WHERE id='channel-target-run'")[0].required(0) == "cancelled" &&
            store.markExecuting(fixture.child, fixture.run, fixture.childPlan, 44, false).isError() &&
            store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError() &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='channel-child'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='channel-child' AND kind='operation_execution_handoff'") ==
                (if (stage == "executing") { 1 } else { 0 }) && database.query("PRAGMA foreign_key_check").isEmpty(),
            "terminal cancellation keeps one truthful child outcome and never resumes bytes")
    } finally { fixture.close() }
}
