package agent_store

import agent_domain.*
import agent_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func peerReceiveRequire111<T>(result: Result<T>): T {
    match (result) { case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("child fixture: " + error.code) }
}
private class PeerReceiveEstimator111 <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
private class PeerReceiveStoreFixture111 {
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
    init() {
        directory = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(directory + "/child.sqlite")
        let sink = SqliteThreadCommitSink(database)
        let coordinator = ThreadCoordinator(sink.createThread(thread, "/workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("child", PeerReceiveEstimator111()), { => 10 })
        let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system")
        let turn = SemanticTurnId("primitive-turn")
        let active = peerReceiveRequire111(runtime.startTurn(turn, run, ItemId("primitive-user"),
            ThreadItemContent.UserMessage(textMessageParts("delegate one child")), lane, InvocationContextProjection()))
        epoch = active.epoch
        let call = ToolCall("primitive-call", "plugin.axyndra:workflow.hub", objectValue([]))
        let item = ItemId("primitive-item")
        match (runtime.commitResult(ResultEnvelope(thread, turn, run, epoch, 1,
            ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))) {
            case SemanticCommitDecision.Committed(_, _) => ()
            case _ => throw IllegalStateException("child fixture canonical ToolCall did not commit")
        }
        source = OperationRootSource.Direct(peerReceiveRequire111(runtime.attestDirectToolCall(item, parent, run, epoch)))
        store = DurableOperationStore(database)
        let actualLane = peerReceiveRequire111(store.pluginDocumentLane(thread, run, epoch))
        let digest = modelPolicySha256Text("exact primitive fixture")
        let binding = objectValue([ValueField("namespace", textValue("axyndra:workflow")),
            ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("1")),
            ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue(thread.value)),
            ValueField("lane_id", textValue(actualLane.value)), ValueField("run_id", textValue(run.value)),
            ValueField("epoch", integerValue(epoch)), ValueField("parent_call_id", textValue(call.callId)),
            ValueField("contribution", textValue(call.name)), ValueField("implementation_fingerprint", textValue("frozen-fixture")),
            ValueField("schema_digest", textValue(digest))])
        let intent=objectValue([ValueField("id",textValue("start-0")),ValueField("service",textValue("peer.receive")),
            ValueField("input",objectValue([ValueField("peek",boolValue(true))]))])
        let arguments = objectValue([ValueField("input", call.arguments), ValueField("configuration", objectValue([])),
            ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_PRIMITIVE_PARENT111)),
                ValueField("binding", binding), ValueField("intents",listValue([intent]))]))])
        let capabilities = [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow"), Capability(CapabilityKind.WorkspaceRead)]
        parentPlan = NormalizedOperationPlan(call.name, arguments, capabilities, OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(arguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: "fixture", implementationFingerprint: "frozen-fixture", schemaDigest: digest)
        let childArguments = peerReceiveRequire111(pluginChildStartArguments111(arguments, "start-0"))
        childPlan = NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111, childArguments, capabilities,
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(childArguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: HOST_PLUGIN_CHILD_FINGERPRINT111, implementationFingerprint: HOST_PLUGIN_CHILD_FINGERPRINT111)
    }
    func parentHandoff(): Unit {
        let direct = match (source) { case OperationRootSource.Direct(value) => value
            case _ => throw IllegalStateException("fixture requires actual Direct source") }
        peerReceiveRequire111(store.prepareDirectOperation(direct, parentPlan))
        peerReceiveRequire111(store.markExecutingWithSource(Some(source), parent, run, parentPlan, 11, false))
        peerReceiveRequire111(store.markExecutionHandoffWithSource(Some(source), parent, run, thread, 12))
    }
    func prepareChild(): Result<OperationId> {
        store.prepareDerivedOperation(child, parent, run, source, exactServiceRequestKey(source.callId(), childPlan), childPlan)
    }
    func childHandoff(): Unit {
        peerReceiveRequire111(prepareChild())
        peerReceiveRequire111(store.markExecutingWithSource(Some(source), child, run, childPlan, 13, false))
        peerReceiveRequire111(store.markExecutionHandoffWithSource(Some(source), child, run, thread, 14))
    }
    func verify(): Result<Unit> { store.verifyPluginChildExecution111(source, parent, child, run, thread, epoch, childPlan) }
    func close(): Unit { database.close(); remove(directory, recursive: true) }
}


@Test
class PluginPeerReceiveScopeTests111 {
    @TestCase
    func exactReceivePeekIsBoundToOriginalActualParentAndOneReceipt(): Unit {
        let f=PeerReceiveStoreFixture111()
        try {
            @Expect(f.prepareChild().isError())
            f.parentHandoff();f.childHandoff();@Expect(f.verify().isOk())
            let replay=peerReceiveRequire111(f.store.prepareDerivedOperation(OperationId("receive-replay"),f.parent,f.run,f.source,
                exactServiceRequestKey(f.source.callId(),f.childPlan),f.childPlan))
            @Expect(replay.value,f.child.value)
            peerReceiveRequire111(f.store.settleDerivedOperation(f.run,f.parent,VNextOperationReceipt("receipt-"+f.child.value,f.child,
                OperationOutcome.Completed,objectValue([]),objectValue([]),15)))
            @Expect(f.verify().isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
        }finally{f.close()}
    }
    @TestCase
    func ReceiveCannotChangeFrozenPeekOrSupplyForeignMailboxSelector(): Unit {
        let f=PeerReceiveStoreFixture111()
        try {
            f.parentHandoff()
            for(foreignSelector in [false,true]){
                let original=f.childPlan.canonicalArguments
                let intent=original.field("intent").getOrThrow()
                let fields=if(foreignSelector){[ValueField("peek",boolValue(true)),ValueField("thread_id",textValue("foreign"))]}
                    else{[ValueField("peek",boolValue(false))]}
                let changed=objectValue([ValueField("schema",original.field("schema").getOrThrow()),ValueField("binding",original.field("binding").getOrThrow()),
                    ValueField("intent",objectValue([ValueField("id",intent.field("id").getOrThrow()),ValueField("service",intent.field("service").getOrThrow()),ValueField("input",objectValue(fields))]))])
                let plan=NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111,changed,f.childPlan.requiredCapabilities,OperationEffectClass.ReadOnly,
                    OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(changed)),
                    networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
                    toolVersion:HOST_PLUGIN_CHILD_FINGERPRINT111,implementationFingerprint:HOST_PLUGIN_CHILD_FINGERPRINT111)
                @Expect(!pluginChildParentAllows111(f.parentPlan,plan))
                @Expect(f.store.prepareDerivedOperation(f.child,f.parent,f.run,f.source,exactServiceRequestKey(f.source.callId(),plan),plan).isError())
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        }finally{f.close()}
    }
}
