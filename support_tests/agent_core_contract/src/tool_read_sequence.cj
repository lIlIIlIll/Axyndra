package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// Trusted fixture assembly only. The actual SQLite Root/approval/ledger,
// canonical facts and normal semantic result commits remain production code.
class ToolReadSequenceCoreProbe <: ToolExecutor{
    let root:String
    let mode:String
    let database:SqliteDatabase
    var reads:Int64=0
    var parents:Int64=0
    var advances:Int64=0
    var ledger:?ExecutionBudget=None
    var finalPlan:?NormalizedOperationPlan=None
    init(root:String,mode:String,database:SqliteDatabase){this.root=root;this.mode=mode;this.database=database}
    func readRequest(context:ToolInvocationContext,call:ToolCall):Result<?ToolPreparationRead>{
        ledger=Some(context.budget)
        let original=parseUnifiedJson(stringifyUnifiedJson(call.arguments))
        let sequence=ToolPreparationReadSequence(2,{actual,facts=>
            advances++
            if(facts.size==1){return Result.Ok(ToolPreparationReadNext.Read(stage(actual,2,
                changedOwner:mode=="owner_changed")))}
            if(mode=="fact_changed"){
                database.execute("DELETE FROM audit_events WHERE operation_id=? AND kind='context_read_admitted'",
                    [SqlParameter.Text(facts[0].operationId.value)])}
            if(mode=="stage_limit"){return Result.Ok(ToolPreparationReadNext.Read(stage(actual,3)))}
            Result.Ok(ToolPreparationReadNext.Ready(contextReadSequenceInput(original,facts)))
        })
        Result.Ok(Some(stage(context,1,sequence:Some(sequence))))
    }
    private func stage(context:ToolInvocationContext,ordinal:Int64,
        changedOwner!:Bool=false,sequence!:?ToolPreparationReadSequence=None):ToolPreparationRead{
        let path=root+"/input-"+ordinal.toString()+".txt"
        let request=objectValue([ValueField("path",textValue(path))]);let frozen=canonicalAgentValue(request)
        let run=context.runId.value;let thread=context.sessionId.value;let epoch=context.epoch;let budget=context.budget
        ToolPreparationRead("axyndra:context-fixture","sha256:"+modelPolicySha256Text("sequence-package"),
            modelPolicySha256Text(if(changedOwner){"another-configuration"}else{"sequence-configuration"}),request,
            {_,_=>Result.Ok(objectValue([]))},boundary:Some({actual,arguments=>
                if(actual.cancellation.isCancelled() || actual.runId.value!=run || actual.sessionId.value!=thread ||
                    actual.epoch!=epoch || actual.workspaceRoot!=root || !refEq(actual.budget,budget) || canonicalAgentValue(arguments)!=frozen){
                    return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"fixture.sequence_owner_changed","actual fixture boundary changed"))}
                Result<Unit>.Ok(())}),sequence:sequence)
    }
    public func execute(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult>{
        expect(refEq(context.budget,ledger.getOrThrow()) && context.budget.snapshot().activeTools==1,
            "all sequence stages consume the original ledger and exactly one real exclusive slot")
        if(prepared.call.name==HOST_CONTEXT_READ_TOOL){
            reads++
            let path=httpIntentText(prepared.operationPlan.canonicalArguments,"path")
            return Result.Ok(ToolResult(prepared.call.callId,objectValue([ValueField("text",textValue(String.fromUtf8(File.readFrom(path))))])))}
        parents++;finalPlan=Some(prepared.operationPlan)
        expect(prepared.operationPlan.contextReadFacts.size==2 &&
            validateContextReadSequenceInputProjection(prepared.operationPlan.canonicalArguments,prepared.operationPlan.contextReadFacts).isOk(),
            "final actual parent consumes both complete canonical read outputs")
        let data=prepared.operationPlan.canonicalArguments.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow()
        expect(httpIntentText(data.items[0],"text")=="actual first file" && httpIntentText(data.items[1],"text")=="actual second file",
            "sequence ordering retains both physically read original files")
        Result.Ok(ToolResult(prepared.call.callId,objectValue([ValueField("observed",integerValue(2))])))
    }
}
func coreToolReadSequenceContract():Unit{
    for(mode in ["approve","cancel_second","budget","owner_changed","fact_changed","stage_limit"]){
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/sequence.db")
        try{
            File.writeTo(root+"/input-1.txt","actual first file".toArray());File.writeTo(root+"/input-2.txt","actual second file".toArray())
            let probe=ToolReadSequenceCoreProbe(root,mode,database);let catalog=ToolCatalog()
            catalog.register(ToolDescriptor(ModelToolDefinition(HOST_CONTEXT_READ_TOOL,"hidden real file read fixture",objectValue([])),
                Capability(CapabilityKind.WorkspaceRead),neverReplay:true,hostServiceOnly:true,
                implementationVersion:HOST_CONTEXT_READ_IMPLEMENTATION,implementationFingerprint:HOST_CONTEXT_READ_IMPLEMENTATION),probe).value().getOrThrow()
            catalog.register(ToolDescriptor(ModelToolDefinition("plugin.context.pending","read sequence parent",objectValue([])),
                Capability(CapabilityKind.WorkspaceWrite),sideEffecting:true,neverReplay:true,
                preparationReadResolver:Some({context,call=>probe.readRequest(context,call)})),probe).value().getOrThrow()
            let operations=DurableOperationStore(database);let repository=SqliteRunRepository(database)
            let threads=SqliteThreadRuntimeRegistry(database,ContextProjector("sequence",ConservativeThreadTokenEstimator()),{=>agentUtcMillis()})
            let model=ContextReadCoreModel();let core=AgentCore(model,repository,
                ToolPipeline(catalog,operations,MemoryAudit(),FixtureIds(),policy:ContextReadApprovalPolicy()),catalog,
                threadRuntimes:Some(threads),operationRuntime:Some(operations),modelDecisionRuntime:Some(SqliteModelDecisionStore(database)),
                contextManifestRuntime:Some(DurableCutManifest(database)),toolHooks:ContextReadHook())
            let request=AgentRunRequest(RunId("sequence-"+mode),SessionId("sequence-"+mode),"fixture","two real reads",
                capabilities:CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.WorkspaceWrite)]),
                toolContext:ToolContextDescriptor(workspaceRoot:root,cwd:root),approvalModeOverride:Some(ApprovalMode.AlwaysAsk),
                budget:ResourceBudget(maxConcurrentTools:1,maxToolCalls:if(mode=="budget"){1}else{3}))
            let first=contextReadAwaiting(core.start(request),HOST_CONTEXT_READ_TOOL)
            expect(probe.reads==0 && probe.parents==0 && probe.ledger.getOrThrow().snapshot().toolCalls==1,
                "first actual read awaits its own review before physical I/O")
            let one=core.decide(request,first,ApprovalDecision.Approve)
            if(mode=="budget"){
                expect(one.isError() && probe.reads==1 && probe.parents==0,"second stage cannot exceed the actual one-call ledger")
            }else if(mode=="owner_changed"){
                let _=completedSnapshotOrThrow(one,"changed next owner is rejected with its canonical unexecuted parent settled")
                expect(probe.reads==1 && probe.parents==0 && database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'")==1,
                    "different configuration cannot mint a second ContextRead Root")
            }else{
                let second=contextReadAwaiting(one,HOST_CONTEXT_READ_TOOL)
                expect(second.operationId.value!=first.operationId.value && probe.reads==1 && probe.parents==0 &&
                    probe.ledger.getOrThrow().snapshot().toolCalls==2 && probe.ledger.getOrThrow().snapshot().activeTools==1,
                    "second real Root owns its separate approval and same retained parent/budget")
                if(mode=="cancel_second"){
                    core.cancel(request.runId).value().getOrThrow()
                    expect(probe.reads==1 && probe.parents==0 && model.requests.size==1,
                        "cancel between stages never reads the second file or dispatches the parent")
                }else{
                    let two=core.decide(request,second,ApprovalDecision.Approve)
                    if(mode=="approve"){
                        let parent=contextReadAwaiting(two,"plugin.context.pending")
                        expect(probe.reads==2 && probe.parents==0 && probe.advances==2,"read approvals grant no later parent write")
                        let _=completedSnapshotOrThrow(core.decide(request,parent,ApprovalDecision.Approve),"two facts consumed by actual parent")
                        expect(probe.parents==1 && probe.ledger.getOrThrow().snapshot().toolCalls==3 &&
                            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'")==3,
                            "two reads plus one actual parent retain exactly three real receipts and charges")
                        for(link in probe.finalPlan.getOrThrow().contextReadFacts){
                            let actual=operations.loadContextReadFact(link.operationId,request.runId).value().getOrThrow()
                            expect(canonicalAgentValue(actual.reference())==canonicalAgentValue(link.toValue()),"all persisted links remain canonical after completion")}
                    }else if(mode=="fact_changed"){
                        expect(two.isError() && probe.reads==2 && probe.parents==0,
                            "rereading a changed earlier real fact prevents final parent preparation")
                    }else{
                        let _=completedSnapshotOrThrow(two,"stage overflow rejects unexecuted canonical parent")
                        expect(probe.reads==2 && probe.parents==0 && database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'")==2,
                            "third read cannot exceed the original fixed stage ceiling")
                    }
                }
            }
            expect(probe.ledger.getOrThrow().snapshot().activeTools==0,
                "all successful, rejected, cancelled and exhausted sequence paths release the real slot")
            expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'")==database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") &&
                database.scalarInt("SELECT COUNT(*) FROM operations WHERE state!='committed'")==0,
                "every real stage and original parent settles its own canonical debt")
            expect(database.scalarInt("SELECT COUNT(*) FROM runs")==1 && database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'")==1,
                "sequence adds no fake Run, user input or model Decision")
        }finally{database.close();remove(root,recursive:true)}
    }
    println("Core actual bounded tool read sequence contract passed: 6 scenarios")
}
