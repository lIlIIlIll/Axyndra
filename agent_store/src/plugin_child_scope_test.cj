package agent_store

import agent_domain.*
import agent_runtime.*
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
    init(waiting!: Bool = false) {
        directory = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(directory + "/child.sqlite")
        let sink = SqliteThreadCommitSink(database)
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
        store = DurableOperationStore(database)
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
                ValueField("prompt", textValue("perform the frozen task")), ValueField("system_prompt", textValue("")),
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
    func close(): Unit { database.close(); remove(directory, recursive: true) }
}

// These are actual canonical SQLite admission controls. They do NOT assert
// that an installed worker or a model child was launched; those belong to the
// required Host/Product pilot tests before this service can be enabled.
@Test
class PluginChildScopeTests111 {
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
