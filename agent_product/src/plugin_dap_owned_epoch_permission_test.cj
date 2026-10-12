package agent_product

import agent_domain.*
import agent_host_runtime.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Snapshot only actual canonical facts. This helper admits no operation,
// manufactures no Prepared/Root/context and never changes a saved receipt.
func ownedDapEpochLedger(database:SqliteDatabase,run:String):Array<String>{
    let values=ArrayList<String>()
    for(row in database.query("SELECT o.id,o.state,o.normalized_plan,COALESCE(e.normalized_plan,''),"+
        "COALESCE(r.id,''),COALESCE(r.outcome,''),COALESCE(r.detail,''),COALESCE(r.verification,'') "+
        "FROM operations o LEFT JOIN operation_effect_records e ON e.operation_id=o.id "+
        "LEFT JOIN operation_receipts r ON r.operation_id=o.id WHERE o.run_id=? ORDER BY o.id",
        [SqlParameter.Text(run)])){
        for(index in 0..8){values.add(row.required(index))}}
    values.toArray()
}

@Test
class PluginDapOwnedEpochPermissionTests {
    @TestCase
    func normalCanonicalCapabilityDomainChangeCannotReuseTheOriginalInstalledEndpoint():Unit{
        let f=OwnedDapProductFixture();let thread="dap-owned-capability-domain"
        try{
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"domain-original-launch").isError)
            let spawns=f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL)
            let writes=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
            let originalPlans=f.childPlans("domain-original-launch")
            @Expect(originalPlans.size,5)
            let scope=lifecycleText(originalPlans[0].field("arguments").getOrThrow().field("binding").getOrThrow(),"permission_domain")
            @Expect(scope!="")
            let allowed=ArrayList<Capability>()
            for(capability in productCapabilities().values where capability.kind!=CapabilityKind.PeerMessage){allowed.add(capability)}
            let changed=CapabilitySet(values:allowed.toArray())
            @Expect(!changed.allows(CapabilityKind.PeerMessage))
            @Expect(changed.allows(CapabilityKind.ExtensionInvoke) && changed.allows(CapabilityKind.ProcessSpawn) &&
                changed.allows(CapabilityKind.WorkspaceRead) && changed.allows(CapabilityKind.WorkspaceWrite))
            for(action in ["threads","launch"]){
                let id="foreign-domain-"+action
                let input=if(action=="launch"){f.input(action,fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))])}
                    else{f.input(action)}
                // This is the public normal canonical entry with a REAL
                // narrowed CapabilitySet; the old endpoint's actual frozen
                // permission scope must reject before any derived dispatch.
                // No copied binding or fabricated child context is supplied.
                let denied=managedCompleted(f.actual.product.vnext.executeCanonicalTool(SessionId(thread),changed,ToolCall(id,f.name(),input),
                    budget:ExecutionBudget(maxToolCalls:32,maxConcurrentTools:1)))
                // Preserve the ORIGINAL normal Direct preparation contract:
                // the Host commits a real UserDirect call, then Store settles
                // an unexecuted canonical rejected Completed, with its full
                // actual receipt and audit. It is not an outer business Err.
                @Expect(denied.isError);@Expect(denied.callId,id)
                @Expect(canonicalAgentValue(denied.output),canonicalAgentValue(rejectedDirectPreparationOutput()))
                @Expect(canonicalAgentValue(f.canonical(thread,id,true)),canonicalAgentValue(denied.output))
                let rejected=f.actual.database.query("SELECT o.id,r.outcome,r.detail,r.verification,c.thread_id,c.kind,c.payload "+
                    "FROM operation_receipts r JOIN operations o ON o.id=r.operation_id JOIN items c ON c.id=o.tool_call_item_id WHERE r.id=?",
                    [SqlParameter.Text(denied.receiptId)])
                @Expect(rejected.size,1);let operation=rejected[0].required(0)
                @Expect(rejected[0].required(1),"rejected")
                @Expect(rejected[0].required(2),encodeStoredValue(rejectedDirectPreparationOutput()))
                @Expect(rejected[0].required(3),encodeStoredValue(objectValue([ValueField("known_completion",boolValue(true)),ValueField("stage",textValue("prepared"))])))
                @Expect(rejected[0].required(4),thread);@Expect(rejected[0].required(5),"tool_call")
                match(decodeStoredThreadContent(rejected[0].required(6))){case ThreadItemContent.ToolCall(call,name,arguments)=>
                    @Expect(call.value,id);@Expect(name,f.name());@Expect(canonicalAgentValue(arguments),canonicalAgentValue(input))
                    case _=>throw IllegalStateException("original actual canonical Direct source required")}
                @Expect(f.actual.database.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='operation_direct_preparation_rejection_only'",
                    [SqlParameter.Text(operation)]).size,1)
                @Expect(f.actual.database.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",
                    [SqlParameter.Text(operation)]).size,0)
                @Expect(f.actual.database.query("SELECT operation_id FROM derived_operation_admissions WHERE operation_id=? OR parent_operation_id=?",
                    [SqlParameter.Text(operation),SqlParameter.Text(operation)]).size,0)
                @Expect(f.childPlans(id).size,0)
                @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),spawns)
                @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),writes)
                @Expect(f.actual.commandCount("threads"),0);@Expect(f.actual.commandCount("adapter-start"),1)
            }
            // Restoring the actual original capabilities leaves the original
            // endpoint usable; no replacement adapter or old-write replay.
            @Expect(!f.call(thread,"domain-original-remains-current",f.input("threads")).isError)
            @Expect(f.actual.commandCount("threads"),1)
            @Expect(f.actual.commandCount("adapter-start"),1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),spawns)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),writes+1)
            let remaining=f.childPlans("domain-original-launch")
            @Expect(remaining.size,originalPlans.size)
            for(index in 0..remaining.size){@Expect(canonicalAgentValue(remaining[index]),canonicalAgentValue(originalPlans[index]))}
            f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func cancelledActualWaitingChildCannotBeApprovedInTheNextRealEpoch():Unit{
        let probe=OwnedDapCleanupProbe();let f=OwnedDapProductFixture(approval:ApprovalMode.AlwaysAsk)
        let thread="dap-owned-cancelled-epoch"
        try{
            lifecycleTestRequire(f.actual.product.observeManagedCleanupForFixture(probe))
            @Expect(!f.start(thread).isError)
            let session=f.actual.product.applicationSession(sessionId:Some(SessionId(thread)))
            session.setThinking(ThinkingLevel.Off)
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("epoch-old-launch",f.name(),
                f.input("launch",fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))]))
            lifecycleTestRequire(session.submit("Approve the actual parent and adapter, then leave initialize waiting."))
            lifecycleTestRequire(session.decide(session.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
            lifecycleTestRequire(session.decide(session.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
            let oldChild=session.approval().getOrThrow()
            let oldRows=f.actual.database.query("SELECT o.run_id,r.epoch,o.normalized_plan FROM operations o JOIN runs r ON r.id=o.run_id WHERE o.id=?",
                [SqlParameter.Text(oldChild.operationId.value)])
            @Expect(oldRows.size,1)
            let oldRun=oldRows[0].required(0);let oldEpoch=Int64.parse(oldRows[0].required(1));let frozen=oldRows[0].required(2)
            let oldPlan=decodeStoredValue(frozen)
            @Expect(lifecycleText(oldPlan,"tool"),HOST_MANAGED_CHANNEL_WRITE_TOOL)
            @Expect(f.approvedCommand(oldPlan),"initialize")
            @Expect(probe.count(),1);@Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),0);@Expect(f.actual.commandCount("initialize"),0)
            lifecycleTestRequire(session.cancel());@Expect(session.approval().isNone())
            @Expect(f.actual.database.query("SELECT state FROM runs WHERE id=?",[SqlParameter.Text(oldRun)])[0].required(0),"cancelled")
            let cancelled=ownedDapEpochLedger(f.actual.database,oldRun)
            @Expect(cancelled.size>0)
            let until=MonoTime.now()+Duration.second*5
            while(!probe.at(0).snapshot().released && MonoTime.now()<until){sleep(Duration.millisecond*5)}
            let closed=probe.at(0).snapshot()
            @Expect(closed.released && closed.processCloseAcknowledged && closed.pumpsJoined && closed.ioDrained)
            @Expect(!closed.paymentRetained && !closed.namespaceDescriptorsRetained)
            @Expect(f.actual.commandCount("initialize"),0)

            // Cancellation revoked the actual old endpoint. Publish a new
            // normal service explicitly, then start a new Application Run.
            // Re-publication does not authorize the old frozen child.
            @Expect(!f.start(thread).isError)
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("epoch-new-launch",f.name(),
                f.input("launch",fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))]))
            lifecycleTestRequire(session.submit("Start the next actual epoch with a new independently approved launch."))
            let current=session.approval().getOrThrow()
            let newRows=f.actual.database.query("SELECT o.run_id,r.epoch,o.normalized_plan FROM operations o JOIN runs r ON r.id=o.run_id WHERE o.id=?",
                [SqlParameter.Text(current.operationId.value)])
            @Expect(newRows.size,1);@Expect(newRows[0].required(0)!=oldRun)
            @Expect(Int64.parse(newRows[0].required(1))>oldEpoch)
            let newFrozen=newRows[0].required(2)
            let rejected=session.decide(oldChild.operationId.value,ApprovalDecision.Approve)
            @Expect(rejected.isError());@Expect(rejected.error().getOrThrow().code,"application.operation_mismatch")
            @Expect(session.approval().getOrThrow().operationId.value,current.operationId.value)
            @Expect(f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(current.operationId.value)])[0].required(0),newFrozen)
            @Expect(f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(oldChild.operationId.value)])[0].required(0),frozen)
            let after=ownedDapEpochLedger(f.actual.database,oldRun)
            @Expect(after.size,cancelled.size)
            for(index in 0..after.size){@Expect(after[index],cancelled[index])}
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),1);@Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),0)
            @Expect(f.actual.commandCount("initialize"),0);@Expect(f.actual.commandCount("adapter-start"),1)
            var approvals:Int64=0
            while(session.approval().isSome()){
                if(approvals>=6){throw IllegalStateException("new epoch requires one parent and five independent children")}
                lifecycleTestRequire(session.decide(session.approval().getOrThrow().operationId.value,ApprovalDecision.Approve));approvals+=1}
            @Expect(approvals,6);@Expect(probe.count(),2)
            @Expect(f.actual.commandCount("adapter-start"),2);@Expect(f.actual.commandCount("initialize"),1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),2);@Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),4)
            let finalOld=ownedDapEpochLedger(f.actual.database,oldRun)
            @Expect(finalOld.size,cancelled.size)
            for(index in 0..finalOld.size){@Expect(finalOld[index],cancelled[index])}
            f.stop(thread)
        }finally{f.close()}
    }
}
