package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func managedActualPrepareCommitted68(value:SemanticCommitDecision):Bool{
    match(value){case SemanticCommitDecision.Committed(_,_)=>true;case _=>false}
}
private func managedActualPrepareRequire<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>
        throw IllegalStateException("actual managed parent fixture: "+error.code)}
}
class ManagedActualPrepareEstimator <: ThreadTokenEstimator{
    public init(){}
    public func estimateSystemInstructions(_:String):Int64{1}
    public func estimateToolSet(_:ToolSetSnapshot):Int64{1}
    public func estimateCheckpoint(_:ContextCheckpoint):Int64{1}
    public func estimateItem(_:ThreadItem):Int64{1}
    public func estimateDynamicState(_:AgentValue):Int64{1}
}
private func managedActualPrepareBinding(thread:ThreadId,run:RunId,epoch:Int64,lane:LaneId):AgentValue{
    let digest=modelPolicySha256Text("actual prepared managed endpoint control")
    objectValue([ValueField("plugin",textValue("axyndra:dap")),ValueField("package_digest",textValue("sha256:"+digest)),
        ValueField("configuration_digest",textValue(digest)),ValueField("instance_identity",textValue("managed-actual-instance")),
        ValueField("endpoint_identity",textValue(digest)),ValueField("directory_revision",integerValue(1)),
        ValueField("directory_digest",textValue(digest)),ValueField("implementation_version",textValue("1")),
        ValueField("implementation_fingerprint",textValue("owned-v1:"+digest)),ValueField("schema_digest",textValue(digest)),
        ValueField("target_thread_id",textValue(thread.value)),ValueField("permission_domain",textValue(digest)),
        ValueField("workspace_root",textValue("/workspace")),ValueField("workspace_mode",textValue("workspace_readonly")),
        ValueField("network",networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied))),
        ValueField("lifecycle_policy",processShutdownPolicyValue(0)),
        ValueField("launch_digest",textValue(digest)),ValueField("lane_id",textValue(lane.value)),ValueField("run_id",textValue(run.value)),
        ValueField("epoch",integerValue(epoch)),ValueField("resource_state",textValue("planned"))])
}
private func managedActualPreparePlan(call:ToolCall,binding:AgentValue):NormalizedOperationPlan{
    let arguments=objectValue([ValueField("input",call.arguments),ValueField("configuration",objectValue([])),
        ValueField("host_plan",objectValue([ValueField("version",textValue(HOST_MANAGED_CHANNEL_OWNED_VERSION)),ValueField("binding",binding)]))])
    NormalizedOperationPlan(call.name,arguments,managedActualPrepareRequire(managedChannelRuntimeRequiredCapabilities(binding)),
        OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(arguments)),
        networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)),replayDisposition:Some(ReplayDisposition.NeverReplay),
        toolVersion:"1",implementationFingerprint:httpIntentText(binding,"implementation_fingerprint"),
        schemaDigest:httpIntentText(binding,"schema_digest"))
}
class ManagedActualParentPrepareFixture{
    let directory:String
    let database:SqliteDatabase
    let store:DurableOperationStore
    let pool:LogicalJsonOwnerBudget
    let held:LogicalJsonOwnerReservation
    let root:OperationRootSource
    let thread:ThreadId
    let run:RunId
    let parent:OperationId
    let epoch:Int64
    let binding:AgentValue
    let plan:NormalizedOperationPlan
    let approval:ApprovalRequest
    init(){
        let path=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(path+"/managed-parent.sqlite")
        let sink=SqliteThreadCommitSink(db);let thread=ThreadId("managed-actual-thread")
        let run=RunId("managed-actual-run");let parent=OperationId("managed-actual-parent")
        let turn=SemanticTurnId("managed-actual-turn")
        let coordinator=ThreadCoordinator(sink.createThread(thread,"/workspace"),sink)
        let runtime=AgentThreadRuntime(coordinator,ContextProjector("managed-actual",ManagedActualPrepareEstimator()),{=>10})
        let lane=ModelLane(ModelLaneRole.Main,"provider","model","responses",ModelLaneCapabilitiesSnapshot(),
            100,10,5,"estimator","retry","cache",ToolSetSnapshot("tools",[]),"system")
        let active=managedActualPrepareRequire(runtime.startTurn(turn,run,ItemId("managed-actual-user"),
            ThreadItemContent.UserMessage(textMessageParts("inspect stack trace 雪\u{0}🙂")),lane,InvocationContextProjection()))
        let call=ToolCall("managed-actual-call","plugin.axyndra:dap.service.session.stackTrace",
            objectValue([ValueField("threadId",integerValue(1)),ValueField("label",textValue("雪\u{0}🙂"))]))
        let item=ItemId("managed-actual-call-item")
        if(!managedActualPrepareCommitted68(runtime.commitResult(ResultEnvelope(thread,turn,run,active.epoch,1,
            ThreadItemDraft(item,ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId),call.name,call.arguments),
                ItemProvenance("direct_tool",runId:Some(run),operationId:Some(parent))))))){
            throw IllegalStateException("actual managed canonical ToolCall did not commit")}
        // The original runtime attests the physically persisted canonical
        // item. No Source or DirectToolCallRef is reconstructed from IDs.
        let actualRoot=OperationRootSource.Direct(managedActualPrepareRequire(runtime.attestDirectToolCall(item,parent,run,active.epoch)))
        let budget=LogicalJsonOwnerBudget();let retained=budget.acquire(1)
        let operationStore=DurableOperationStore(db,documentPayloadAllocation:Some({bytes=>budget.acquire(bytes)}))
        let actualLane=managedActualPrepareRequire(operationStore.pluginDocumentLane(thread,run,active.epoch))
        let binding=managedActualPrepareBinding(thread,run,active.epoch,actualLane)
        let plan=managedActualPreparePlan(call,binding)
        let expected=ApprovalRequest(parent,call.callId,call.name,plan.requiredCapabilities[0],preview:plan.canonicalArguments,
            sessionId:thread.value,argumentHash:plan.bindingDigest,metadata:plan.approvalMetadata,sessionApprovalAllowed:false)
        this.directory=path;this.database=db;this.store=operationStore;this.pool=budget;this.held=retained
        this.root=actualRoot;this.thread=thread;this.run=run;this.parent=parent;this.epoch=active.epoch
        this.binding=binding;this.plan=plan;this.approval=expected
    }
    func prepare():Result<Unit>{store.prepareManagedChannelOwnedParent(root,parent,run,thread,epoch,plan,Some(approval),{=>Result<Unit>.Ok(())})}
    func empty():Unit{
        for(table in ["operations","operation_effect_records","operation_state_registers","derived_operation_admissions","operation_receipts","audit_events"]){
            @Expect(database.scalarInt("SELECT COUNT(*) FROM "+table),0)}
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"),1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"),0)
    }
    func waiting():Unit{
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='managed-actual-parent' AND state='waiting_approval'"),1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_state_registers WHERE operation_id='managed-actual-parent' AND state='waiting_approval'"),1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE operation_id='managed-actual-parent'"),1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_channel_parent_prepared_v1'"),1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_channel_parent_approval_expected_v1'"),1)
        for(table in ["approvals","derived_operation_admissions","operation_receipts"]){@Expect(database.scalarInt("SELECT COUNT(*) FROM "+table),0)}
        @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"),0)
        @Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
    }
    func close():Unit{held.close();@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0);database.close();remove(directory,recursive:true)}
}

@Test
class ManagedActualParentPrepareTests{
    @TestCase
    func actualCanonicalUserRootPreparesOneFullWaitingParentAndRejectsForeignTargetThread():Unit{
        let f=ManagedActualParentPrepareFixture()
        try{
            @Expect(f.binding.field("thread_id").isNone(),true)
            @Expect(httpIntentText(f.binding,"target_thread_id"),f.thread.value)
            @Expect(isManagedChannelOwnedParentPlan(f.plan),true);f.empty()
            @Expect(f.prepare().isOk(),true);f.waiting()
            @Expect(f.prepare().isOk(),true);f.waiting()
            let other=managedActualPrepareBinding(ThreadId("foreign-thread"),f.run,f.epoch,LaneId(httpIntentText(f.binding,"lane_id")))
            let call=match(f.root){case OperationRootSource.Direct(source)=>source.call;case _=>throw IllegalStateException("fixture must use actual UserDirect")}
            let changed=managedActualPreparePlan(call,other)
            @Expect(f.store.prepareManagedChannelOwnedParent(f.root,f.parent,f.run,f.thread,f.epoch,changed,None,{=>Result<Unit>.Ok(())}).isError(),true)
            f.waiting()
        }finally{f.close()}
    }
    @TestCase
    func actualOriginalPoolPressureRejectsParentPrepareBeforeAnyEffectAndReleasedOwnersRestoreIt():Unit{
        let f=ManagedActualParentPrepareFixture();let pressure=Array<LogicalJsonOwnerReservation>(7,{_=>f.pool.acquire(1)})
        try{
            @Expect(f.pool.usage()[0],8);@Expect(f.pool.usage()[1],134217728);f.empty()
            @Expect(f.prepare().isError(),true);f.empty()
            @Expect(f.pool.usage()[0],8);@Expect(f.pool.usage()[1],134217728)
            for(owner in pressure){owner.close()}
            @Expect(f.prepare().isOk(),true);f.waiting()
        }finally{for(owner in pressure){owner.close()};f.close()}
    }
}
