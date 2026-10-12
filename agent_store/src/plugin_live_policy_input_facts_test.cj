package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

// An empty real Store: these descriptive references deliberately have no
// canonical Source, admitted read, successful child or Receipt behind them.
// Positive same-parent/fence cases belong to the actual Kernel family gate.
private class LivePolicyInputCounter79 {
    var value: Int64 = 0
}

class LivePolicyInputAbsentFactsFixture {
    let root:String
    let database:SqliteDatabase
    let parent=OperationId("live-input-parent")
    let run=RunId("live-input-run")
    let parentItem=ItemId("live-input-parent-item")
    let tool="plugin.axyndra:memory.retain"
    let digest=modelPolicySha256Text("descriptive absent read metadata")
    init(){
        let directory=Directory.createTemp("/tmp").toString()
        this.root=directory;this.database=SqliteDatabase(directory+"/inputs.sqlite")
    }
    func binding(runName!:String="live-input-run",toolName!:String="plugin.axyndra:memory.retain"):AgentValue{
        objectValue([ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue("sha256:"+digest)),
            ValueField("generation",textValue("1")),ValueField("configuration_digest",textValue(digest)),
            ValueField("thread_id",textValue("live-input-thread")),ValueField("lane_id",textValue("main")),
            ValueField("run_id",textValue(runName)),ValueField("epoch",integerValue(1)),
            ValueField("parent_call_id",textValue("live-input-call")),ValueField("contribution",textValue(toolName)),
            ValueField("implementation_fingerprint",textValue("descriptive-fingerprint")),ValueField("schema_digest",textValue(digest))])
    }
    func parentlessBinding():AgentValue{
        objectValue([ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue("sha256:"+digest)),
            ValueField("generation",textValue("1")),ValueField("configuration_digest",textValue(digest)),
            ValueField("thread_id",textValue("live-input-thread")),ValueField("lane_id",textValue("main")),
            ValueField("run_id",textValue(run.value)),ValueField("epoch",integerValue(1)),ValueField("provider",textValue("memory_context"))])
    }
    func link(runName!:String="live-input-run"):ContextReadFactLink{
        let origin=ContextReadOrigin("axyndra:memory","sha256:"+digest,digest,digest,digest,"live-input-request",
            parentItem.value,parentKind:"direct",parentOperationId:parent.value)
        ContextReadFactLink(OperationId("absent-live-read"),RunId(runName),ItemId("absent-read-call"),
            ItemId("absent-read-result"),"absent-read-receipt",origin,digest,1)
    }
    func rejects(binding:AgentValue,links:Array<ContextReadFactLink>,
        allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Bool{
        try{
            database.readTransaction<Unit>({tx=>requirePluginLivePolicyReadInputs(tx,parent,run,parentItem,tool,
                binding,links,allocate,guard)});false
        }catch(_:Exception){true}
    }
    func unchanged():Unit{
        for(table in ["operations","operation_receipts","derived_operation_admissions","audit_events","items"]){
            @Expect(database.scalarInt("SELECT count(*) FROM "+table),0)
        }
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}

@Test
class PluginLivePolicyReadInputTests {
    @TestCase
    func emptyOrDuplicateReferencesCannotCreateAReadOrAllocateAnOwner():Unit{
        let f=LivePolicyInputAbsentFactsFixture();let budget=LogicalJsonOwnerBudget();let allocations=LivePolicyInputCounter79()
        let allocate={bytes=>allocations.value++;budget.acquire(bytes)}
        try{
            @Expect(validatePluginDocumentBinding(f.binding()).isOk(),true)
            @Expect(f.rejects(f.binding(),[],allocate,{=>Result<Unit>.Ok(())}),true)
            @Expect(f.rejects(f.binding(),[f.link(),f.link()],allocate,{=>Result<Unit>.Ok(())}),true)
            @Expect(allocations.value,0);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0);f.unchanged()
        }finally{f.close()}
    }
    @TestCase
    func parentlessProviderScopeAndDifferentRunOrContributionCannotBecomeToolInput():Unit{
        let f=LivePolicyInputAbsentFactsFixture();let budget=LogicalJsonOwnerBudget();let allocations=LivePolicyInputCounter79()
        let allocate={bytes=>allocations.value++;budget.acquire(bytes)}
        try{
            @Expect(pluginDocumentContextBindingValid(f.parentlessBinding()),true)
            for(binding in [f.parentlessBinding(),f.binding(runName:"other-run"),f.binding(toolName:"plugin.axyndra:memory.recall")]){
                @Expect(f.rejects(binding,[f.link()],allocate,{=>Result<Unit>.Ok(())}),true)
            }
            @Expect(f.rejects(f.binding(),[f.link(runName:"other-run")],allocate,{=>Result<Unit>.Ok(())}),true)
            @Expect(allocations.value,0);@Expect(budget.usage()[0],0);f.unchanged()
        }finally{f.close()}
    }
    @TestCase
    func repeatedMissingActualFactsReleaseOnlyTheirOwnPaidPhase():Unit{
        let f=LivePolicyInputAbsentFactsFixture();let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        let allocations=LivePolicyInputCounter79();let allocate={bytes=>allocations.value++;budget.acquire(bytes)}
        try{
            for(_ in 0..32){
                @Expect(f.rejects(f.binding(),[f.link()],allocate,{=>Result<Unit>.Ok(())}),true)
                @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
            }
            @Expect(allocations.value,32);f.unchanged()
        }finally{held.close();f.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func cancellationAtEntryAndBeforePaidSqliteLookupLeavesNoPaidDebtOrFacts():Unit{
        let f=LivePolicyInputAbsentFactsFixture();let budget=LogicalJsonOwnerBudget()
        try{
            for(threshold in [1,2]){
                let checks=LivePolicyInputCounter79();let allocations=LivePolicyInputCounter79()
                let allocate={bytes=>allocations.value++;budget.acquire(bytes)}
                let guard={=>checks.value++
                    if(checks.value>=threshold){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"input.cancelled","actual input owner cancelled"))}
                    else{Result<Unit>.Ok(())}}
                @Expect(f.rejects(f.binding(),[f.link()],allocate,guard),true)
                @Expect(allocations.value,if(threshold==1){0}else{1})
                @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0);f.unchanged()
            }
        }finally{f.close()}
    }
}
