package agent_store_contract

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.convert.*
import std.fs.*
import std.sync.*

// Actual SQLite/Runtime producers, not hand-written authority rows. These
// contracts exercise historical metadata validation; the existing Store-only
// materializer deliberately makes no physical artifact/8 MiB throughput claim.
func continuationPayloadHistoryContracts(): Unit {
    for(committed in [false,true]) {
        for(mode in ["completed","running","middle-handoff","middle-unknown","duplicate-authorization",
            "generation","current-bytes","original-read","original-parent","reopen"]) {
            continuationPayloadHistoryScenario(committed,mode)
        }
    }
    println("Continuation payload history Store contract passed: 20 scenarios")
}

func continuationPayloadHistoryScenario(committed:Bool,mode:String):Unit {
    let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/history.sqlite")
    let label=(if(committed){"Committed "}else{"Direct "})+"continuation history "+mode
    try {
        let thread=ThreadId("document-thread");let turn=SemanticTurnId("document-turn");let run=RunId("document-run")
        let sink=SqliteThreadCommitSink(database);let coordinator=ThreadCoordinator(sink.createThread(thread,"workspace"),sink)
        let runtime=AgentThreadRuntime(coordinator,ContextProjector("document",StoreEstimator()),{=>10})
        let active=httpContractRequire(runtime.startTurn(turn,run,ItemId("history-user"),
            ThreadItemContent.UserMessage(textMessageParts("three real canonical document mutations")),
            recoveryLane(),InvocationContextProjection()),label+" actual Run")
        let store=DurableOperationStore(database);let repository=SqlitePluginDocumentRepository(database)
        let absent=httpContractRequire(repository.read(thread,LaneId("main"),"axyndra:workflow","todo"),label+" absent")
        let _=httpContractRequire(repository.compareExchange(absent,objectValue([]),{_=>Result<Unit>.Ok(())}),label+" original data")
        for(index in 0..3) {
            let id="history-parent-"+index.toString();let parentItem=ItemId(id);let parent=OperationId("operation-"+id)
            let parentCall=ToolCall(id,"plugin.axyndra:workflow.todo",objectValue([]))
            let owner:OperationRootSource
            if(committed) {
                owner=OperationRootSource.Committed(commitDurableToolCall(database,coordinator,thread,turn,run,active.epoch,
                    coordinator.snapshot().nextResultSequence,parentItem,id,parentCall.name,parentCall.arguments,10))
            } else {
                expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread,turn,run,active.epoch,coordinator.snapshot().nextResultSequence,
                    ThreadItemDraft(parentItem,ThreadItemContent.ToolCall(CanonicalToolCallId(id),parentCall.name,parentCall.arguments),
                        ItemProvenance("direct_tool",runId:Some(run),operationId:Some(parent)))))),label+" canonical parent")
                owner=OperationRootSource.Direct(httpContractRequire(runtime.attestDirectToolCall(parentItem,parent,run,active.epoch),label+" actual owner"))
            }
            let binding=documentServiceValue(false,active.epoch,"completed").field("binding").getOrThrow()
            binding.put("parent_call_id",textValue(id))
            let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA)),ValueField("binding",binding),
                ValueField("projection_digest",textValue(contextReadProjectionDigest(active.contextSnapshot))),ValueField("keys",listValue([textValue("todo")]))])
            let call=ToolCall(id+"-read",HOST_CONTEXT_READ_TOOL,request)
            let plan=NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL,request,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:workflow")],
                OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(request)),
                toolVersion:HOST_CONTEXT_READ_IMPLEMENTATION,implementationFingerprint:HOST_CONTEXT_READ_IMPLEMENTATION)
            let admission=httpContractRequire(runtime.beginContextRead(call,"axyndra:workflow",httpIntentText(binding,"package_digest"),
                httpIntentText(binding,"configuration_digest"),id+"-read-request",run,active.epoch,
                contextReadProjectionDigest(active.contextSnapshot),parent:Some(owner)),label+" actual read admission")
            let source=httpContractRequire(runtime.commitContextReadToolCall(admission,ItemId(id+"-read-call"),
                OperationId(id+"-read-op"),call,plan),label+" canonical read")
            httpContractRequire(store.prepareDirectOperation(source,plan),label+" read plan")
            httpContractRequire(store.markExecutingWithSource(Some(OperationRootSource.Direct(source)),source.operationId,run,plan,11,false),label+" read executing")
            httpContractRequire(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)),source.operationId,run,thread,12),label+" read handoff")
            let observed=httpContractRequire(store.readPluginDocuments(source,plan,{=>Result<Unit>.Ok(())},None,
                Some(DocumentPayloadFixture("completed"))),label+" actual document ref")
            let read=httpContractRequire(runtime.resolveOperation(ItemId("result-"+source.operationId.value),source.operationId,CanonicalToolCallId(call.callId),plan,
                OperationAttemptStage.Executing,Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId,observed))),
                "receipt-"+source.operationId.value,13,expectedRunId:Some(run),expectedEpoch:Some(active.epoch)),label+" completed read")
            expect(read.semanticCommit.isSome() && isStoreCommitted(read.semanticCommit.getOrThrow()),label+" read committed")
            let fact=httpContractRequire(store.loadContextReadFact(source.operationId,run),label+" frozen read fact")
            documentPayloadFinalWrite(database,runtime,owner,fact,binding,parentCall,active.epoch,"intent-cas-completed",label,
                frozenContextInput:true)
        }
        expect(database.scalarInt("SELECT COUNT(*) FROM operations")==9 && database.scalarInt("SELECT COUNT(*) FROM operation_receipts")==9,
            label+" all three read/parent/child chains have real receipts")
        if(mode!="running"){httpContractRequire(runtime.finish(RunState.Completed,1000),label+" actual completed Run")}
        let first=database.query("SELECT a.operation_id FROM derived_operation_admissions a JOIN operations p ON p.id=a.parent_operation_id "+
            "WHERE p.tool_call_item_id='history-parent-0'")
        let middle=database.query("SELECT a.operation_id,p.id FROM derived_operation_admissions a JOIN operations p ON p.id=a.parent_operation_id "+
            "WHERE p.tool_call_item_id='history-parent-1'")
        expect(first.size==1 && middle.size==1,label+" exact test identities")
        let binding=documentServiceValue(false,active.epoch,"completed").field("binding").getOrThrow()
        let raw=encodeAgentValue(objectValue([ValueField("message",textValue("replacement 雪"))]))
        let originalDigest=modelPolicySha256Text(raw)
        // Damage only existing durable evidence. No SQL here grants a Run,
        // Operation, approval, handoff or owner to a negative fixture.
        match(mode) {
            case "middle-handoff"=>database.execute("DELETE FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",[SqlParameter.Text(middle[0].required(0))])
            case "middle-unknown"=>database.execute("UPDATE operation_receipts SET outcome='unknown' WHERE operation_id=?",[SqlParameter.Text(middle[0].required(0))])
            case "duplicate-authorization"=>database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                "SELECT thread_id,run_id,operation_id,kind,payload,created_at_millis FROM audit_events WHERE operation_id=? AND kind='operation_parent_intent_authorized'",
                [SqlParameter.Text(middle[0].required(0))])
            case "current-bytes"=>database.execute("UPDATE plugin_documents SET payload='null' WHERE document_key='todo'")
            case "original-read"=>database.execute("DELETE FROM audit_events WHERE operation_id='history-parent-0-read-op' AND kind='context_read_admitted'")
            case "original-parent"=>database.execute("DELETE FROM audit_events WHERE operation_id IN (SELECT parent_operation_id FROM derived_operation_admissions WHERE operation_id=?) "+
                "AND kind='operation_execution_handoff'",[SqlParameter.Text(first[0].required(0))])
            case _=>()
        }
        continuationPayloadHistoryAssert(database,first[0].required(0),originalDigest,binding,mode,label)
        if(mode=="reopen") {
            // A separate connection must validate completed history without
            // recreating its old active Runtime or a continuation user owner.
            let reopened=SqliteDatabase(root+"/history.sqlite")
            try{continuationPayloadHistoryAssert(reopened,first[0].required(0),originalDigest,binding,mode,label+" reopened")}
            finally{reopened.close()}
        }
    } finally {database.close();remove(root,recursive:true)}
}

func continuationPayloadHistoryAssert(database:SqliteDatabase,originalOperation:String,originalDigest:String,
    binding:AgentValue,mode:String,label:String):Unit {
    let budget=LogicalJsonOwnerBudget(maximumCharged:134217728)
    let scope=ContinuationDocumentReadScope({bytes=>budget.acquire(bytes)})
    try {
        let result=database.readTransaction<Result<Array<CompletedPluginDocumentObservation>>>({tx=>
            let version=match(readContinuationDocumentVersion(tx,ThreadId("document-thread"),LaneId("main"),"axyndra:workflow","todo",scope)) {
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            observeContinuationDocumentPayloadChain(tx,version,originalOperation,2,originalDigest,"plugin.axyndra:workflow.todo",
                httpIntentText(binding,"package_digest"),if(mode=="generation"){"8"}else{"7"},httpIntentText(binding,"configuration_digest"),scope)
        })
        if(mode=="completed" || mode=="reopen") {
            let chain=httpContractRequire(result,label+" completed metadata chain")
            expect(chain.size==3 && chain[0].revision==2 && chain[2].revision==4,label+" every CAS predecessor is retained")
            for(value in chain){expect(value.payload.isSome() && value.expectedPayload.isSome() && value.encoded=="" && value.expectedJson=="",
                label+" historical proof does not retain document bodies")}
        }else{expect(result.isError(),label+" damaged or incomplete authority cannot be a historical input")}
        expect(database.scalarInt("SELECT COUNT(*) FROM operations")==9 && database.scalarInt("SELECT COUNT(*) FROM operation_receipts")==9,
            label+" observation creates no effect or replay")
    }finally{scope.close()}
    expect(budget.usage()[0]==0 && budget.usage()[1]==0,label+" metadata and transient history allocations released")
}
