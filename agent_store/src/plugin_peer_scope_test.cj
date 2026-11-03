package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func peerRequire111<T>(result: Result<T>): T {
    match (result) { case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("child fixture: " + error.code) }
}
private class PeerEstimator111 <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
private class PeerStoreFixture111 {
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
        directory = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        database = SqliteDatabase(directory + "/child.sqlite")
        let sink = SqliteThreadCommitSink(database)
        let coordinator = ThreadCoordinator(sink.createThread(thread, "/workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("child", PeerEstimator111()), { => 10 })
        let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system")
        let turn = SemanticTurnId("primitive-turn")
        let active = peerRequire111(runtime.startTurn(turn, run, ItemId("primitive-user"),
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
        source = OperationRootSource.Direct(peerRequire111(runtime.attestDirectToolCall(item, parent, run, epoch)))
        store = DurableOperationStore(database)
        let actualLane = peerRequire111(store.pluginDocumentLane(thread, run, epoch))
        let digest = modelPolicySha256Text("exact primitive fixture")
        let binding = objectValue([ValueField("namespace", textValue("axyndra:workflow")),
            ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("1")),
            ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue(thread.value)),
            ValueField("lane_id", textValue(actualLane.value)), ValueField("run_id", textValue(run.value)),
            ValueField("epoch", integerValue(epoch)), ValueField("parent_call_id", textValue(call.callId)),
            ValueField("contribution", textValue(call.name)), ValueField("implementation_fingerprint", textValue("frozen-fixture")),
            ValueField("schema_digest", textValue(digest))])
        let intent=objectValue([ValueField("id",textValue("start-0")),ValueField("service",textValue("peer.list")),
            ValueField("input",objectValue([]))])
        let arguments = objectValue([ValueField("input", call.arguments), ValueField("configuration", objectValue([])),
            ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_PRIMITIVE_PARENT111)),
                ValueField("binding", binding), ValueField("intents",listValue([intent]))]))])
        let capabilities = [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow"), Capability(CapabilityKind.WorkspaceRead)]
        parentPlan = NormalizedOperationPlan(call.name, arguments, capabilities, OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(arguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: "fixture", implementationFingerprint: "frozen-fixture", schemaDigest: digest)
        let childArguments = peerRequire111(pluginChildStartArguments111(arguments, "start-0"))
        childPlan = NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111, childArguments, capabilities,
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(childArguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: HOST_PLUGIN_CHILD_FINGERPRINT111, implementationFingerprint: HOST_PLUGIN_CHILD_FINGERPRINT111)
    }
    func parentHandoff(): Unit {
        let direct = match (source) { case OperationRootSource.Direct(value) => value
            case _ => throw IllegalStateException("fixture requires actual Direct source") }
        peerRequire111(store.prepareDirectOperation(direct, parentPlan))
        peerRequire111(store.markExecutingWithSource(Some(source), parent, run, parentPlan, 11, false))
        peerRequire111(store.markExecutionHandoffWithSource(Some(source), parent, run, thread, 12))
    }
    func prepareChild(): Result<OperationId> {
        store.prepareDerivedOperation(child, parent, run, source, exactServiceRequestKey(source.callId(), childPlan), childPlan)
    }
    func childHandoff(): Unit {
        peerRequire111(prepareChild())
        peerRequire111(store.markExecutingWithSource(Some(source), child, run, childPlan, 13, false))
        peerRequire111(store.markExecutionHandoffWithSource(Some(source), child, run, thread, 14))
    }
    func verify(): Result<Unit> { store.verifyPluginChildExecution111(source, parent, child, run, thread, epoch, childPlan) }
    func close(): Unit { database.close(); remove(directory, recursive: true) }
}


@Test
class PluginPeerScopeTests111 {
    @TestCase
    func actualReadonlyPeerHandoffStillRequiresTheCanonicalParentAndOneReceipt(): Unit {
        let f=PeerStoreFixture111()
        try {
            @Expect(f.prepareChild().isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            f.parentHandoff();peerRequire111(f.prepareChild())
            @Expect(f.verify().isError())
            peerRequire111(f.store.markExecutingWithSource(Some(f.source),f.child,f.run,f.childPlan,13,false))
            @Expect(f.verify().isError())
            peerRequire111(f.store.markExecutionHandoffWithSource(Some(f.source),f.child,f.run,f.thread,14))
            @Expect(f.verify().isOk())
            let duplicate=peerRequire111(f.store.prepareDerivedOperation(OperationId("duplicate"),f.parent,f.run,f.source,
                exactServiceRequestKey(f.source.callId(),f.childPlan),f.childPlan))
            @Expect(duplicate.value,f.child.value)
            peerRequire111(f.store.settleDerivedOperation(f.run,f.parent,VNextOperationReceipt("receipt-"+f.child.value,f.child,
                OperationOutcome.Completed,objectValue([]),objectValue([]),15)))
            @Expect(f.verify().isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),1)
        } finally {f.close()}
    }
    @TestCase
    func readonlyPeerCannotBorrowForeignThreadRunEpochOrAnotherParent(): Unit {
        let f=PeerStoreFixture111()
        try {
            f.parentHandoff();f.childHandoff();@Expect(f.verify().isOk())
            @Expect(f.store.verifyPluginChildExecution111(f.source,f.parent,f.child,RunId("foreign"),f.thread,f.epoch,f.childPlan).isError())
            @Expect(f.store.verifyPluginChildExecution111(f.source,f.parent,f.child,f.run,ThreadId("foreign"),f.epoch,f.childPlan).isError())
            @Expect(f.store.verifyPluginChildExecution111(f.source,f.parent,f.child,f.run,f.thread,f.epoch+1,f.childPlan).isError())
            @Expect(f.store.verifyPluginChildExecution111(f.source,OperationId("foreign"),f.child,f.run,f.thread,f.epoch,f.childPlan).isError())
            @Expect(f.verify().isOk());@Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        } finally {f.close()}
    }
    @TestCase
    func delegateAndPeerMessagePlansCannotReplaceTheFrozenWorkspaceReadPlan(): Unit {
        let f=PeerStoreFixture111()
        try {
            f.parentHandoff()
            for(kind in [CapabilityKind.Delegate,CapabilityKind.PeerMessage]){
                let changed=NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111,f.childPlan.canonicalArguments,
                    [Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow"),Capability(kind)],
                    OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,f.childPlan.bindingDigest,
                    networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
                    toolVersion:HOST_PLUGIN_CHILD_FINGERPRINT111,implementationFingerprint:HOST_PLUGIN_CHILD_FINGERPRINT111)
                @Expect(!isPluginChildStartPlan111(changed))
                @Expect(f.store.prepareDerivedOperation(f.child,f.parent,f.run,f.source,
                    exactServiceRequestKey(f.source.callId(),changed),changed).isError())
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
        } finally {f.close()}
    }
}
