package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// These contracts exercise the actual canonical Runtime/SQLite/Host file
// owners. The fixture does not simulate a Source, instantiate a read proof,
// publish a plugin or assert that this primitive test granted user approval.
private func liveCanonicalRequire<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>
        throw IllegalStateException("canonical window fixture failed: "+error.code)}
}
private func liveCanonicalCommitted(value:SemanticCommitDecision):Bool{
    match(value){case SemanticCommitDecision.Committed(_,_)=>true;case _=>false}
}
class LiveCanonicalEstimator <: ThreadTokenEstimator{
    public init(){}
    public func estimateSystemInstructions(_:String):Int64{1}
    public func estimateToolSet(_:ToolSetSnapshot):Int64{1}
    public func estimateCheckpoint(_:ContextCheckpoint):Int64{1}
    public func estimateItem(_:ThreadItem):Int64{1}
    public func estimateDynamicState(_:AgentValue):Int64{1}
}
private func liveCanonicalLane():ModelLane{
    ModelLane(ModelLaneRole.Main,"provider","recovery-model","responses",ModelLaneCapabilitiesSnapshot(),100,10,5,
        "estimator","retry","cache",ToolSetSnapshot("tools",[]),"system-v1")
}
class LivePolicyCanonicalFixture{
    let root:String
    let database:SqliteDatabase
    let runtime:AgentThreadRuntime
    let store:DurableOperationStore
    let active:ActiveRunSnapshot
    let artifacts:HostArtifactStore
    let parent:OperationRootSource
    let binding:AgentValue
    let cancellation:CancellationSource
    let access:RowJournalStructuralAccess
    let view:RowJournalLatestView
    init(committed!:Bool=false){
        let selectedRoot=Directory.createTemp("/tmp").toString()
        let selectedDatabase=SqliteDatabase(selectedRoot+"/window.sqlite")
        let sink=SqliteThreadCommitSink(selectedDatabase)
        let thread=ThreadId("window-thread");let turn=SemanticTurnId("window-turn");let run=RunId("window-run")
        let coordinator=ThreadCoordinator(sink.createThread(thread,"workspace"),sink)
        let selectedRuntime=AgentThreadRuntime(coordinator,ContextProjector("window",LiveCanonicalEstimator()),{=>10})
        let selectedCancellation=CancellationSource()
        let selectedActive=liveCanonicalRequire(selectedRuntime.startTurn(turn,run,ItemId("window-user"),
            ThreadItemContent.UserMessage(textMessageParts("inspect the selected opaque journal")),liveCanonicalLane(),
            InvocationContextProjection(),parentCancellation:Some(selectedCancellation.token)))
        let parentOperation=OperationId("window-parent");let parentItem=ItemId("window-parent-item")
        let parentCall=ToolCall("window-parent-call","plugin.axyndra:live-fixture.inspect",objectValue([]))
        let selectedParent=if(committed){
            let decisions=SqliteModelDecisionStore(selectedDatabase)
            let request=SemanticModelRequestId("live-request-model");let attempt=ModelAttemptId("live-attempt-model")
            let decision=ModelDecisionId("live-decision-model");let blockId=DecisionBlockId("live-block-model")
            let scoped=ScopedToolCallId("live-scoped-model")
            let block=ModelBlock(ModelBlockKind.ToolCall,text:"original opaque block text",callId:parentCall.callId,
                name:parentCall.name,arguments:parentCall.arguments)
            let _=liveCanonicalRequire(decisions.createAttempt(DurableModelAttempt(attempt,request,run,1,
                ModelAttemptLifecycle.Created,objectValue([]),"trusted kernel fixture",10,10)))
            let _=liveCanonicalRequire(decisions.persistValidatedDecision(ModelDecision(decision,attempt,request,
                [DurableDecisionBlock(blockId,0,block,scopedToolCallId:Some(scoped))],
                TerminalEvidence("responses","response.completed",messageTerminalObserved:true,streamEofObserved:true,
                    adapterVersion:"trusted-kernel-fixture-v1"),DecisionValidationStatus.Validated,
                CompletionDisposition.ToolUse,DecisionOutcome.ToolCalls,"actual-content","actual-replay",1,createdAtMillis:10)))
            match(selectedRuntime.commitBatch(ResultBatchEnvelope(thread,turn,run,selectedActive.epoch,1,[
                ThreadItemDraft(parentItem,ThreadItemContent.ToolCall(CanonicalToolCallId(parentCall.callId),parentCall.name,parentCall.arguments),
                    ItemProvenance("model_decision",runId:Some(run)),sourceDecisionId:Some(decision),sourceDecisionBlockId:Some(blockId))]))){
                case SemanticBatchCommitDecision.Committed(_,_)=>()
                case _=>throw IllegalStateException("real committed model block did not atomically project")}
            let refs=liveCanonicalRequire(selectedRuntime.attestCommittedToolCalls(
                liveCanonicalRequire(decisions.committedToolCallSources(run))))
            if(refs.size!=1){throw IllegalStateException("actual committed source lost its sole canonical block")}
            OperationRootSource.Committed(refs[0])
        }else{
            if(!liveCanonicalCommitted(selectedRuntime.commitResult(ResultEnvelope(thread,turn,run,selectedActive.epoch,1,
                ThreadItemDraft(parentItem,ThreadItemContent.ToolCall(CanonicalToolCallId(parentCall.callId),parentCall.name,parentCall.arguments),
                    ItemProvenance("direct_tool",runId:Some(run),operationId:Some(parentOperation))))))){
                throw IllegalStateException("actual canonical parent did not commit")}
            OperationRootSource.Direct(liveCanonicalRequire(
                selectedRuntime.attestDirectToolCall(parentItem,parentOperation,run,selectedActive.epoch)))
        }
        let digest=modelPolicySha256Text("live-fixture")
        let selectedBinding=objectValue([ValueField("namespace",textValue("axyndra:live-fixture")),
            ValueField("package_digest",textValue("sha256:"+digest)),ValueField("generation",textValue("7")),
            ValueField("configuration_digest",textValue(digest)),ValueField("thread_id",textValue(thread.value)),
            ValueField("lane_id",textValue("main")),ValueField("run_id",textValue(run.value)),ValueField("epoch",integerValue(selectedActive.epoch)),
            ValueField("parent_call_id",textValue(parentCall.callId)),ValueField("contribution",textValue(parentCall.name)),
            ValueField("implementation_fingerprint",textValue("owned-v1:"+digest)),ValueField("schema_digest",textValue(digest))])
        // Trusted assembly selects the one existing original journal mapping.
        // This callback is an immutable fixture scope, not a user grant.
        selectedDatabase.bindDocumentStorageBackend("axyndra:live-fixture","journal",
            SqliteOpaqueRowJournalWindowBackend("axyndra:live-fixture","journal",selectedRoot,selectedRoot,
                {bytes=>reserveNativeRowJournalPayload(bytes)},digest,{=>
                    if(selectedCancellation.token.isCancelled()){
                        return Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.cancelled","original fixture caller was cancelled"))}
                    Result<Unit>.Ok(())}))
        this.root=selectedRoot;this.database=selectedDatabase;this.runtime=selectedRuntime
        this.store=DurableOperationStore(selectedDatabase,documentPayloadAllocation:Some({bytes=>reserveNativeRowJournalPayload(bytes)}));this.active=selectedActive
        this.artifacts=HostArtifactStore(selectedRoot+"/artifacts",database:Some(selectedDatabase))
        this.parent=selectedParent;this.binding=selectedBinding;this.cancellation=selectedCancellation
        let fields=ArrayList<AgentValue>()
        for(path in [["record","scopeKind"],["record","scopeKey"],["record","id"]]){
            fields.add(objectValue([ValueField("path",listValue(path.map{part=>textValue(part)})),
                ValueField("prefix_bytes",integerValue(if(path[1]=="scopeKind"){64}else{0})),
                ValueField("ascii_trimmed_length",boolValue(path[1]=="scopeKey"))]))}
        let selectedAccess=RowJournalStructuralAccess.parse(objectValue([
            ValueField("schema",textValue(ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA)),ValueField("fields",listValue(fields.toArray())),
            ValueField("scope_classification_path",listValue([textValue("record"),textValue("scopeKind")])),
            ValueField("scope_key_path",listValue([textValue("record"),textValue("scopeKey")])),
            ValueField("scopes",listValue([objectValue([ValueField("classification",textValue("global")),
                ValueField("key_match",textValue("text_fallback_empty"))])]))]))
        let selectedView=RowJournalLatestView.parse(objectValue([ValueField("schema",textValue(ROW_JOURNAL_LATEST_VIEW_SCHEMA)),
            ValueField("group_key_path",listValue([textValue("record"),textValue("id")])),
            ValueField("ordinal",textValue("event-primary-key")),ValueField("fold",textValue("last-value-first-position"))]))
        this.access=selectedAccess;this.view=selectedView
        let original=SqliteOpaqueRowJournalWindowBackend("axyndra:live-fixture","journal",selectedRoot,selectedRoot,
            {bytes=>reserveNativeRowJournalPayload(bytes)},digest,{=>current()})
        let stream=SqliteOpaqueRowJournalStreamBackend(original,"axyndra:live-fixture","journal",selectedRoot,selectedRoot,selectedAccess,
            {bytes=>reserveNativeRowJournalPayload(bytes)},{_=>Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,"fixture.v2_closed","old v2 was not selected"))})
        selectedDatabase.bindDocumentStorageBackend("axyndra:live-fixture","journal",SqliteOpaqueRowJournalLatestStreamBackend(
            stream,"axyndra:live-fixture","journal",selectedRoot,selectedAccess,selectedView,{bytes=>reserveNativeRowJournalPayload(bytes)},
            {_=>Result<()->Result<Unit>>.Ok({=>current()})}))
    }
    func current():Result<Unit>{
        if(cancellation.token.isCancelled()){
            return Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.cancelled","original fixture caller was cancelled"))}
        Result<Unit>.Ok(())
    }
    func seed(id:String,content:String):Unit{
        // Setup uses only the actual original current-row/history tables.
        // This opaque sample proves byte transport, not Native Memory policy.
        let raw=stringifyUnifiedJson(objectValue([ValueField("version",integerValue(3)),
            ValueField("record",objectValue([ValueField("id",textValue(id)),ValueField("revision",integerValue(1)),
                ValueField("scopeKind",textValue("global")),ValueField("scopeKey",textValue("")),ValueField("content",textValue(content))]))]))
        database.transaction<Unit>({tx=>
            tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,'fact',?,1)",
                [SqlParameter.Text(id),SqlParameter.Text(raw)])
            tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(?,1,'retain',?,10)",
                [SqlParameter.Text(id),SqlParameter.Text(raw)])})
    }
    func latest():ContextReadFact{
        let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA)),ValueField("binding",binding),
            ValueField("projection_digest",textValue(contextReadProjectionDigest(active.contextSnapshot))),ValueField("key",textValue("journal")),
            ValueField("access_policy_digest",textValue(access.digest)),ValueField("view_policy_digest",textValue(view.digest))])
        let call=ToolCall("live-read-call",HOST_CONTEXT_READ_TOOL,request);let operation=OperationId("live-read")
        let plan=NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL,request,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:live-fixture")],
            OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(request)),
            toolVersion:HOST_CONTEXT_READ_IMPLEMENTATION,implementationFingerprint:HOST_CONTEXT_READ_IMPLEMENTATION)
        let admission=liveCanonicalRequire(runtime.beginContextRead(call,"axyndra:live-fixture",httpIntentText(binding,"package_digest"),
            httpIntentText(binding,"configuration_digest"),"live-request",active.runId,active.epoch,
            contextReadProjectionDigest(active.contextSnapshot),parent:Some(parent)))
        let source=liveCanonicalRequire(runtime.commitContextReadToolCall(admission,ItemId("live-read-item"),operation,call,plan))
        let _=liveCanonicalRequire(store.prepareDirectOperation(source,plan))
        let _=liveCanonicalRequire(store.markExecutingWithSource(Some(OperationRootSource.Direct(source)),operation,active.runId,plan,11,false))
        let _=liveCanonicalRequire(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)),operation,active.runId,active.threadId,12))
        let reader=artifacts.latestJournalStreamPayloadReader(store,source,plan,{=>current()})
        let value=liveCanonicalRequire(reader.read());let _=liveCanonicalRequire(reader.close())
        if(!pluginDocumentLatestJournalStreamReadResultValid(value,request)){throw IllegalStateException("actual v3 read did not produce its complete original result")}
        let reserved=database.query("SELECT reserved_receipt_id,reserved_result_item_id FROM operation_effect_records WHERE operation_id=? AND run_id=?",
            [SqlParameter.Text(operation.value),SqlParameter.Text(active.runId.value)])
        if(reserved.size!=1){throw IllegalStateException("latest read lost actual reserved canonical slots")}
        let resolved=liveCanonicalRequire(runtime.resolveOperation(ItemId(reserved[0].required(1)),operation,CanonicalToolCallId(call.callId),plan,
            OperationAttemptStage.Executing,Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId,value))),
            reserved[0].required(0),13,expectedRunId:Some(active.runId),expectedEpoch:Some(active.epoch)))
        if(resolved.semanticCommit.isNone() || !liveCanonicalCommitted(resolved.semanticCommit.getOrThrow())){
            throw IllegalStateException("latest read canonical Receipt did not commit")}
        liveCanonicalRequire(store.loadContextReadFact(operation,active.runId))
    }
    func plain(content:String):AgentValue{
        let artifact=liveCanonicalRequire(artifacts.persistText(content))
        objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),ValueField("artifact_ref",textValue(artifact.reference)),
            ValueField("encoding",textValue("utf8")),ValueField("bytes",integerValue(artifact.bytes)),ValueField("sha256",textValue(artifact.sha256)),
            ValueField("content_type",textValue(artifact.contentType))])
    }
    func parentId():OperationId{
        match(parent){case OperationRootSource.Direct(value)=>value.operationId
            case OperationRootSource.Committed(value)=>OperationId("operation-"+value.decisionId.value+"-"+value.scopedToolCallId.value)}
    }
    func parentPlan(fact:ContextReadFact):NormalizedOperationPlan{
        let arguments=objectValue([ValueField("input",objectValue([])),ValueField("configuration",objectValue([])),ValueField("host_plan",objectValue([
            ValueField("version",textValue(PLUGIN_LIVE_POLICY_PARENT_SCHEMA)),ValueField("binding",binding),ValueField("input_payload",plain("{}")),
            ValueField("effect_ceiling",objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_CEILING_SCHEMA)),
                ValueField("documents",listValue([objectValue([ValueField("key",textValue("journal")),ValueField("operations",listValue([textValue("row_journal.append")]))])])),
                ValueField("filesystem",listValue([]))])),ValueField("initial_read_facts",contextReadFactLinksValue([fact.link()])),
            ValueField("policy_provider",textValue("fixture_policy")),ValueField("data_schema",textValue("axyndra.fixture-policy-query/v1"))]))])
        let plan=NormalizedOperationPlan(parent.toolName(),arguments,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:live-fixture")],
            OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(arguments)),
            implementationFingerprint:httpIntentText(binding,"implementation_fingerprint"),schemaDigest:httpIntentText(binding,"schema_digest"),
            replayDisposition:Some(ReplayDisposition.NeverReplay),contextReadFacts:[fact.link()])
        if(!isPluginLivePolicyParentPlan(plan)){throw IllegalStateException("actual parent plan failed strict opt-in shape")};plan
    }
    func prepareParent(plan:NormalizedOperationPlan):Unit{
        let _=liveCanonicalRequire(store.preparePluginLivePolicyParent(parent,parentId(),active.runId,active.threadId,active.epoch,plan,Option<ApprovalRequest>.None,{=>current()}))
    }
    func parentApproval(plan:NormalizedOperationPlan):ApprovalRequest{
        ApprovalRequest(parentId(),parent.callId(),parent.toolName(),plan.requiredCapabilities[0],preview:plan.canonicalArguments,
            sessionId:active.threadId.value,argumentHash:requiredCapabilitiesArgumentHash(
                ToolCall(parent.callId(),parent.toolName(),objectValue([])),plan.requiredCapabilities))
    }
    func prepareWaitingParent(plan:NormalizedOperationPlan):Unit{
        let _=liveCanonicalRequire(store.preparePluginLivePolicyParent(parent,parentId(),active.runId,active.threadId,
            active.epoch,plan,Some(parentApproval(plan)),{=>current()}))
    }
    func executeParent(plan:NormalizedOperationPlan,handoff!:Bool=true):Unit{
        let _=liveCanonicalRequire(store.markPluginLivePolicyParentExecuting(parent,parentId(),active.runId,active.threadId,active.epoch,plan,14,false,{=>current()}))
        if(handoff){let _=liveCanonicalRequire(store.markPluginLivePolicyParentHandoff(parent,parentId(),active.runId,active.threadId,active.epoch,plan,15,{=>current()}))}
    }
    func child(plan:NormalizedOperationPlan):(ToolCall,NormalizedOperationPlan,ApprovalRequest){
        let args=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_STREAMING_CHILD_SCHEMA)),ValueField("binding",binding),ValueField("sequence",integerValue(1)),
            ValueField("effect",objectValue([ValueField("kind",textValue("row_journal.append")),ValueField("key",textValue("journal"))])),
            ValueField("proposal_payload",plain("{\"fixture\":\"prepared-only\"}")),ValueField("read_facts",contextReadFactLinksValue(plan.contextReadFacts)),
            ValueField("prior_receipts",objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parentId().value)),ValueField("through_sequence",integerValue(0)),ValueField("tip",nullValue())]))])
        let call=ToolCall(parent.callId()+":live:1",HOST_PLUGIN_LIVE_EFFECT_TOOL,args)
        let childPlan=NormalizedOperationPlan(call.name,args,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:live-fixture")],
            OperationEffectClass.ExternalMutation,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(args)),
            toolVersion:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT,implementationFingerprint:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT,
            replayDisposition:Some(ReplayDisposition.NeverReplay))
        let approval=ApprovalRequest(OperationId("live-child"),call.callId,call.name,childPlan.requiredCapabilities[0],preview:args,
            sessionId:active.threadId.value,argumentHash:requiredCapabilitiesArgumentHash(call,childPlan.requiredCapabilities))
        (call,childPlan,approval)
    }
    func prepareChild(plan:NormalizedOperationPlan,child:(ToolCall,NormalizedOperationPlan,ApprovalRequest)):Result<OperationId>{
        store.preparePluginLivePolicyInvocation(parent,parentId(),child[2].operationId,active.runId,active.threadId,active.epoch,plan,child[1],
            pluginLivePolicyStreamingRequestKey(parent.callId(),child[1]),child[0],Some(child[2]),{=>current()})
    }
    func verifyChild(plan:NormalizedOperationPlan,child:(ToolCall,NormalizedOperationPlan,ApprovalRequest)):Result<Unit>{
        store.verifyPluginLivePolicyPending(parent,parentId(),child[2].operationId,active.runId,active.threadId,active.epoch,plan,child[1],
            pluginLivePolicyStreamingRequestKey(parent.callId(),child[1]),child[0].callId,child[2],{=>current()})
    }
    func count(sql:String):Int64{database.scalarInt(sql)}
    func count(sql:String,parameters:Array<SqlParameter>):Int64{
        let rows=database.query(sql,parameters)
        if(rows.size!=1 || rows[0].size!=1){throw IllegalStateException("fixture count lost its exact single row")}
        Int64.parse(rows[0].required(0))
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}

// Kernel Source contracts: actual Runtime attestation, completed ContextRead,
// Host file/proof, SQLite handoff/ReservedReceipt and new paid Store admission.
// No Native policy, user approval grant or child effect is simulated here.
@Test
class PluginLivePolicyCanonicalSourceTests{
    @TestCase
    func ActualReadAndExactHandoffCreateOnlyOneOriginalWaitingChild():Unit{
        let f=LivePolicyCanonicalFixture()
        try{
            f.seed("one","opaque");let fact=f.latest();let plan=f.parentPlan(fact)
            f.prepareParent(plan);let child=f.child(plan)
            @Expect(f.prepareChild(plan,child).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            f.executeParent(plan);@Expect(f.prepareChild(plan,child).isOk(),true)
            @Expect(f.verifyChild(plan,child).isOk(),true)
            @Expect(f.prepareChild(plan,child).value().getOrThrow().value,"live-child")
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='window-parent' OR operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='waiting_approval'"),1)
        }finally{f.close()}
    }
    @TestCase
    func ExecutingParentWithoutItsExactHandoffCannotPrepareAChild():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan,handoff:false)
            @Expect(f.prepareChild(plan,f.child(plan)).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions"),0)
        }finally{f.close()}
    }
    @TestCase
    func HandoffPayloadSubstitutionFailsBeforeAnyChildAdmission():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan)
            f.database.execute("UPDATE audit_events SET payload=? WHERE operation_id=? AND kind='operation_execution_handoff'",
                [SqlParameter.Text(encodeStoredValue(objectValue([]))),SqlParameter.Text(f.parentId().value)])
            @Expect(f.prepareChild(plan,f.child(plan)).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions"),0)
        }finally{f.close()}
    }
    @TestCase
    func ActualReadFenceChangeRejectsBothFirstPrepareAndPendingResume():Unit{
        let f=LivePolicyCanonicalFixture()
        try{f.seed("one","old");let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan)
            let child=f.child(plan);@Expect(f.prepareChild(plan,child).isOk(),true)
            f.seed("two","new after actual Root fact")
            @Expect(f.verifyChild(plan,child).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='operation_execution_handoff'"),0)
        }finally{f.close()}
    }
    @TestCase
    func ExactApprovalTupleAndImmutableReservedResultCannotBeSubstituted():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan);let child=f.child(plan)
            @Expect(f.prepareChild(plan,child).isOk(),true)
            let other=ApprovalRequest(child[2].operationId,child[2].callId,child[2].toolName,child[2].capability,preview:child[2].preview,
                sessionId:child[2].sessionId,argumentHash:"different-already-prepared-argument-hash")
            @Expect(f.verifyChild(plan,(child[0],child[1],other)).isError(),true)
            f.database.execute("UPDATE operation_effect_records SET reserved_result_item_id='wrong-result' WHERE operation_id='live-child'")
            @Expect(f.verifyChild(plan,child).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
        }finally{f.close()}
    }
    @TestCase
    func CancelledSameRunPreservesTheAlreadyPreparedChildAndItsPhysicalObligation():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan);let child=f.child(plan)
            @Expect(f.prepareChild(plan,child).isOk(),true);f.cancellation.cancel()
            @Expect(f.verifyChild(plan,child).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='waiting_approval'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
        }finally{f.close()}
    }
}

@Test
class PluginLivePolicyCommittedSourceTests{
    @TestCase
    func ActualCommittedDecisionAndWholeBlockPrepareTheOriginalChild():Unit{
        let f=LivePolicyCanonicalFixture(committed:true)
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan)
            let child=f.child(plan);@Expect(f.prepareChild(plan,child).isOk(),true)
            @Expect(f.verifyChild(plan,child).isOk(),true)
            @Expect(f.count("SELECT COUNT(*) FROM decision_operations WHERE operation_id=?",
                [SqlParameter.Text(f.parentId().value)]),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=? OR operation_id='live-child'",
                [SqlParameter.Text(f.parentId().value)]),0)
        }finally{f.close()}
    }
    @TestCase
    func CommittedParentProvenanceCannotBecomeAUserDirectCall():Unit{
        let f=LivePolicyCanonicalFixture(committed:true)
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan)
            f.database.execute("UPDATE items SET provenance=? WHERE id='window-parent-item'",[
                SqlParameter.Text(encodeStoredProvenance(ItemProvenance("direct_tool",runId:Some(f.active.runId),
                    operationId:Some(f.parentId()))))])
            @Expect(f.prepareChild(plan,f.child(plan)).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions"),0)
        }finally{f.close()}
    }
    @TestCase
    func CommittedBlockFieldsOutsideTheCallHeaderAreStillBound():Unit{
        let f=LivePolicyCanonicalFixture(committed:true)
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareParent(plan);f.executeParent(plan)
            let substituted=objectValue([ValueField("kind",textValue("tool_call")),ValueField("text",textValue("changed opaque block text")),
                ValueField("call_id",textValue(f.parent.callId())),ValueField("name",textValue(f.parent.toolName())),
                ValueField("arguments",objectValue([])),ValueField("is_error",boolValue(false)),ValueField("receipt_id",textValue("")),
                ValueField("opaque_state",nullValue()),ValueField("image",nullValue())])
            f.database.execute("UPDATE model_decision_blocks SET payload=? WHERE id='live-block-model'",[SqlParameter.Text(encodeStoredValue(substituted))])
            @Expect(f.prepareChild(plan,f.child(plan)).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions"),0)
        }finally{f.close()}
    }
    @TestCase
    func InitialParentApprovalPersistIsAtomicAndNeedsTheSameRunRestored():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareWaitingParent(plan)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id=? AND state='waiting_approval'",
                [SqlParameter.Text(f.parentId().value)]),1)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",
                [SqlParameter.Text(f.parentId().value)]),0)
            let _=liveCanonicalRequire(f.runtime.pauseForApproval())
            @Expect(f.store.preparePluginLivePolicyParent(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
                plan,Some(f.parentApproval(plan)),{=>f.current()}).isError(),true)
            let _=liveCanonicalRequire(f.runtime.resumeAfterApproval())
            @Expect(f.store.preparePluginLivePolicyParent(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
                plan,Some(f.parentApproval(plan)),{=>f.current()}).isOk(),true)
            @Expect(f.store.markPluginLivePolicyParentExecuting(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
                plan,14,true,{=>f.current()}).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]),0)
        }finally{f.close()}
    }
}

// A replay query selects no Source authority: the same complete waiting tuple
// must still pass the actual pending verifier before its child is excluded.
@Test
class PluginLivePolicyPendingPrepareIntegrityTests117 {
    @TestCase
    func waitingPrepareReplayCannotChangeReservedEvidenceIdentityOrApprovalPhase():Unit{
        for(variant in ["reserved_receipt","prepared_audit","request_digest","foreign_child","ready_replay"]){
            let f=LivePolicyCanonicalFixture()
            try{
                let fact=f.latest();let plan=f.parentPlan(fact)
                f.prepareParent(plan);f.executeParent(plan);let child=f.child(plan)
                @Expect(f.prepareChild(plan,child).isOk(),true)
                if(variant=="reserved_receipt"){
                    f.database.execute("UPDATE operation_effect_records SET reserved_receipt_id='other-reserved-receipt' WHERE operation_id='live-child'")
                    @Expect(f.prepareChild(plan,child).isError(),true)
                }else if(variant=="prepared_audit"){
                    f.database.execute("UPDATE audit_events SET payload='{}' WHERE operation_id='live-child' AND kind='plugin_live_child_prepared_v1'")
                    @Expect(f.prepareChild(plan,child).isError(),true)
                }else if(variant=="request_digest"){
                    f.database.execute("UPDATE derived_operation_admissions SET request_digest='other-request-digest' WHERE operation_id='live-child'")
                    @Expect(f.prepareChild(plan,child).isError(),true)
                }else if(variant=="foreign_child"){
                    let other=ApprovalRequest(OperationId("foreign-live-child"),child[2].callId,child[2].toolName,
                        child[2].capability,preview:child[2].preview,sessionId:child[2].sessionId,argumentHash:child[2].argumentHash)
                    @Expect(f.prepareChild(plan,(child[0],child[1],other)).isError(),true)
                }else{
                    @Expect(f.store.preparePluginLivePolicyInvocation(f.parent,f.parentId(),child[2].operationId,f.active.runId,
                        f.active.threadId,f.active.epoch,plan,child[1],pluginLivePolicyStreamingRequestKey(f.parent.callId(),child[1]),
                        child[0],Option<ApprovalRequest>.None,{=>f.current()}).isError(),true)
                }
                @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id=?",
                    [SqlParameter.Text(f.parentId().value)]),1)
                @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='waiting_approval'"),1)
                @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='foreign-live-child'"),0)
                @Expect(f.count("SELECT COUNT(*) FROM approvals WHERE operation_id='live-child'"),0)
                @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
                @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='operation_execution_handoff'"),0)
            }finally{f.close()}
        }
    }
}
