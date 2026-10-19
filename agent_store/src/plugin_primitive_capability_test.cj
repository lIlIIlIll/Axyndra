package agent_store

import agent_domain.*
import agent_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func mappedInvocationRequire111<T>(result: Result<T>): T {
    match (result) { case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("child fixture: " + error.code) }
}
private class MappedInvocationEstimator111 <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
private class MappedInvocationStoreFixture111 {
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
        runtime = AgentThreadRuntime(coordinator, ContextProjector("child", MappedInvocationEstimator111()), { => 10 })
        let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system")
        let turn = SemanticTurnId("primitive-turn")
        let active = mappedInvocationRequire111(runtime.startTurn(turn, run, ItemId("primitive-user"),
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
        source = OperationRootSource.Direct(mappedInvocationRequire111(runtime.attestDirectToolCall(item, parent, run, epoch)))
        store = DurableOperationStore(database)
        let actualLane = mappedInvocationRequire111(store.pluginDocumentLane(thread, run, epoch))
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
                ValueField("binding", binding), ValueField("intents",listValue([intent])),ValueField("invocation_capability",textValue("workspace.read"))]))])
        let capabilities = [Capability(CapabilityKind.WorkspaceRead)]
        parentPlan = NormalizedOperationPlan(call.name, arguments, capabilities, OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(arguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: "fixture", implementationFingerprint: "frozen-fixture", schemaDigest: digest)
        let childArguments = mappedInvocationRequire111(pluginChildStartArguments111(arguments, "start-0"))
        childPlan = NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111, childArguments, capabilities,
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(childArguments)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            toolVersion: HOST_PLUGIN_CHILD_FINGERPRINT111, implementationFingerprint: HOST_PLUGIN_CHILD_FINGERPRINT111)
    }
    func parentHandoff(): Unit {
        let direct = match (source) { case OperationRootSource.Direct(value) => value
            case _ => throw IllegalStateException("fixture requires actual Direct source") }
        mappedInvocationRequire111(store.prepareDirectOperation(direct, parentPlan))
        mappedInvocationRequire111(store.markExecutingWithSource(Some(source), parent, run, parentPlan, 11, false))
        mappedInvocationRequire111(store.markExecutionHandoffWithSource(Some(source), parent, run, thread, 12))
    }
    func prepareChild(): Result<OperationId> {
        store.prepareDerivedOperation(child, parent, run, source, exactServiceRequestKey(source.callId(), childPlan), childPlan)
    }
    func childHandoff(): Unit {
        mappedInvocationRequire111(prepareChild())
        mappedInvocationRequire111(store.markExecutingWithSource(Some(source), child, run, childPlan, 13, false))
        mappedInvocationRequire111(store.markExecutionHandoffWithSource(Some(source), child, run, thread, 14))
    }
    func verify(): Result<Unit> { store.verifyPluginChildExecution111(source, parent, child, run, thread, epoch, childPlan) }
    func close(): Unit { database.close(); remove(directory, recursive: true) }
}


private func mappedInvocationChanged111(original:NormalizedOperationPlan,args:AgentValue,caps:Array<Capability>):NormalizedOperationPlan {
    NormalizedOperationPlan(HOST_PLUGIN_CHILD_TOOL111,args,caps,OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(args)),
        networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
        toolVersion:HOST_PLUGIN_CHILD_FINGERPRINT111,implementationFingerprint:HOST_PLUGIN_CHILD_FINGERPRINT111)
}

@Test
class MappedPrimitiveInvocationScopeTests111 {
    @TestCase
    func mappedReadonlyChildStillRequiresActualParentHandoffAndOneReservedReceipt():Unit {
        let f=MappedInvocationStoreFixture111()
        try {
            @Expect(isFrozenPluginChildParent111(f.parentPlan));@Expect(isPluginChildStartPlan111(f.childPlan))
            @Expect(f.prepareChild().isError())
            f.parentHandoff();f.childHandoff();@Expect(f.verify().isOk())
            @Expect(f.parentPlan.requiredCapabilities.size,1);@Expect(f.childPlan.requiredCapabilities.size,1)
            @Expect(pluginPrimitiveInvocationName111(f.childPlan.canonicalArguments),"workspace.read")
            let replay=mappedInvocationRequire111(f.store.prepareDerivedOperation(OperationId("mapped-replay"),f.parent,f.run,f.source,
                exactServiceRequestKey(f.source.callId(),f.childPlan),f.childPlan))
            @Expect(replay.value,f.child.value)
            mappedInvocationRequire111(f.store.settleDerivedOperation(f.run,f.parent,VNextOperationReceipt("receipt-"+f.child.value,f.child,
                OperationOutcome.Completed,objectValue([]),objectValue([]),15)))
            @Expect(f.verify().isError());@Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
        }finally{f.close()}
    }
    @TestCase
    func changedInvocationProfileScopeOrCapabilityCannotReplaceTheActualParentSelection():Unit {
        let f=MappedInvocationStoreFixture111()
        try {
            f.parentHandoff()
            for(mode in ["extension","delegate","resource","configuration","contribution","thread","generation"]){
                let args=parseUnifiedJson(encodeAgentValue(f.childPlan.canonicalArguments))
                var caps=f.childPlan.requiredCapabilities
                if(mode=="extension"){
                    args.put("invocation_capability",textValue("extension.invoke"))
                    caps=[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow"),Capability(CapabilityKind.WorkspaceRead)]
                }else if(mode=="delegate"){
                    args.put("invocation_capability",textValue("delegate"));caps=[Capability(CapabilityKind.Delegate)]
                }else if(mode=="resource"){caps=[Capability(CapabilityKind.WorkspaceRead,resource:"different")]}
                else{
                    let binding=args.field("binding").getOrThrow()
                    if(mode=="configuration"){binding.put("configuration_digest",textValue(modelPolicySha256Text("changed complete profile")))}
                    else if(mode=="contribution"){binding.put("contribution",textValue("plugin.axyndra:workflow.todo"))}
                    else if(mode=="thread"){binding.put("thread_id",textValue("different-thread"))}
                    else{binding.put("generation",textValue("2"))}
                }
                let plan=mappedInvocationChanged111(f.childPlan,args,caps)
                @Expect(!pluginChildParentAllows111(f.parentPlan,plan))
                @Expect(f.store.prepareDerivedOperation(f.child,f.parent,f.run,f.source,exactServiceRequestKey(f.source.callId(),plan),plan).isError())
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        }finally{f.close()}
    }
    @TestCase
    func invalidMappingDoesNotBecomeAOneCapabilityAdmissionByChangingOnlyPlanData():Unit {
        let f=MappedInvocationStoreFixture111()
        try {
            f.parentHandoff()
            for(value in [textValue("unknown.permission"),textValue("peer.message"),nullValue(),integerValue(1)]){
                let args=parseUnifiedJson(encodeAgentValue(f.childPlan.canonicalArguments))
                args.put("invocation_capability",value)
                @Expect(parsePluginChildStartIntent111(args).isError())
                let plan=mappedInvocationChanged111(f.childPlan,args,f.childPlan.requiredCapabilities)
                @Expect(!isPluginChildStartPlan111(plan))
                @Expect(f.store.prepareDerivedOperation(f.child,f.parent,f.run,f.source,exactServiceRequestKey(f.source.callId(),plan),plan).isError())
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
        }finally{f.close()}
    }
}
