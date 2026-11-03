package agent_product

import agent_domain.*
import agent_host_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class OwnedDapCleanupProbe <: HostManagedChannelCleanupObserver {
    private let lock=Mutex()
    private let observed=ArrayList<HostManagedChannelCleanupBorrow>()
    public func observe(borrow:HostManagedChannelCleanupBorrow):Unit{
        lock.lock();try{observed.add(borrow)}finally{lock.unlock()}
    }
    func count():Int64{lock.lock();try{observed.size}finally{lock.unlock()}}
    func at(index:Int64):HostManagedChannelCleanupBorrow{lock.lock();try{observed[index]}finally{lock.unlock()}}
}

@Test
class PluginDapOwnedScopeCleanupTests {
    @TestCase
    func pendingRealParentCannotRetargetItsFrozenOperationAfterGenerationReplacement():Unit{
        let f=OwnedDapProductFixture(approval:ApprovalMode.AlwaysAsk,multiple:true)
        let thread="dap-owned-pending-generation"
        try{
            @Expect(!f.start(thread).isError)
            let host=f.actual.product.vnext.javascriptPlugins
            let original=host.instanceGeneration(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)))
            let session=f.actual.product.applicationSession(sessionId:Some(SessionId(thread)))
            session.setThinking(ThinkingLevel.Off)
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("frozen-generation",f.name(),
                f.input("launch",fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))]))
            lifecycleTestRequire(session.submit("Review this exact selected debugger before replacing its installation."))
            let pending=session.approval().getOrThrow()
            let frozen=f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(pending.operationId.value)])[0].required(0)
            @Expect(f.actual.observed().size,0)
            @Expect(f.actual.product.setPluginEnabled(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),false).isOk())
            @Expect(f.actual.product.setPluginEnabled(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),true).isOk())
            @Expect(host.instanceGeneration(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)))>original)
            @Expect(!f.start(thread).isError)
            // The actual old Prepared and approval remain in the Application;
            // no Source or Root is recovered from the observed operation ID.
            let _=session.decide(pending.operationId.value,ApprovalDecision.Approve)
            @Expect(f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(pending.operationId.value)])[0].required(0),frozen)
            @Expect(session.approval().isNone());@Expect(f.actual.observed().size,0)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),0);@Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),0)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
            f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func actualPendingPackageAndConfigurationChangesRejectOriginalApprovalBeforeSpawn():Unit{
        for(mode in ["package","configuration"]){
            let f=OwnedDapProductFixture(approval:ApprovalMode.AlwaysAsk,multiple:true)
            let thread="dap-owned-pending-content-"+mode
            try{
                @Expect(!f.start(thread).isError)
                let session=f.actual.product.applicationSession(sessionId:Some(SessionId(thread)))
                session.setThinking(ThinkingLevel.Off)
                f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("frozen-content",f.name(),
                    f.input("launch",fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))]))
                lifecycleTestRequire(session.submit("Review the exact configuration and package bytes."))
                let pending=session.approval().getOrThrow()
                let frozen=f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(pending.operationId.value)])[0].required(0)
                @Expect(f.actual.observed().size,0)
                if(mode=="configuration"){
                    let path=f.actual.files.settings+"/plugins/lifecycle.json"
                    File.writeTo(path,(String.fromUtf8(File.readFrom(path))+"\n").toArray())
                }else{
                    let root=canonicalize(Path(f.actual.files.root)).toString()
                    let installed=canonicalize(Path(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Root)))).toString()
                    // Mutate only this disposable imported snapshot. The
                    // separately packaged fixture artifact remains untouched.
                    if(!installed.startsWith(root+"/")){throw IllegalStateException("disposable installed snapshot required")}
                    File.writeTo(installed+"/owned-fixture-changed-content.txt","changed installed package bytes".toArray())
                }
                let _=session.decide(pending.operationId.value,ApprovalDecision.Approve)
                @Expect(f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(pending.operationId.value)])[0].required(0),frozen)
                @Expect(session.approval().isNone());@Expect(f.actual.observed().size,0)
                @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),0);@Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),0)
                @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
                f.stop(thread)
            }finally{f.close()}
        }
    }

    @TestCase
    func callerCopiedRootBindingsNeverBecomeActualDerivedProcessAuthority():Unit{
        // This specifically proves raw caller values cannot manufacture a
        // Derived Source. Two simultaneous valid Derived foreign parents,
        // epoch/permission substitution after admission remain separate OPEN
        // controls; this case does not pretend to construct those authorities.
        for(mode in ["same-data","thread","epoch","permission"]){
            let f=OwnedDapProductFixture();let thread="dap-owned-caller-binding-"+mode
            try{
                @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"actual-binding-source").isError)
                var original:?AgentValue=None<AgentValue>
                for(plan in f.childPlans("actual-binding-source")){
                    let arguments=plan.field("arguments").getOrThrow()
                    if(lifecycleText(arguments.field("operation").getOrThrow(),"kind")=="spawn"){original=Some(arguments)}}
                let input=parseUnifiedJson(stringifyUnifiedJson(original.getOrThrow()))
                let binding=input.field("binding").getOrThrow()
                if(mode=="thread"){binding.put("target_thread_id",textValue("another-actual-thread"))}
                else if(mode=="epoch"){binding.put("epoch",integerValue(1000000))}
                else if(mode=="permission"){binding.put("permission_domain",textValue(modelPolicySha256Text("caller-changed-domain")))}
                let spawns=f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL)
                let writes=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
                let outcome=f.actual.product.vnext.executeCanonicalTool(SessionId(thread),productCapabilities(),
                    ToolCall("caller-never-derived",HOST_MANAGED_CHANNEL_SPAWN_TOOL,input),
                    budget:ExecutionBudget(maxToolCalls:32,maxConcurrentTools:1))
                @Expect(managedRejected(outcome));@Expect(f.actual.commandCount("adapter-start"),1)
                @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),spawns);@Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),writes)
                f.stop(thread)
            }finally{f.close()}
        }
    }

    @TestCase
    func originalApprovedChildCannotWriteAfterItsActiveInstallationIsReplaced():Unit{
        let probe=OwnedDapCleanupProbe()
        let f=OwnedDapProductFixture(approval:ApprovalMode.AlwaysAsk,multiple:true)
        let thread="dap-owned-active-generation"
        try{
            lifecycleTestRequire(f.actual.product.observeManagedCleanupForFixture(probe))
            @Expect(!f.start(thread).isError)
            let session=f.actual.product.applicationSession(sessionId:Some(SessionId(thread)))
            session.setThinking(ThinkingLevel.Off)
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("active-generation-launch",f.name(),
                f.input("launch",fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))]))
            lifecycleTestRequire(session.submit("Launch this exact selected adapter through every independent approval."))
            var approvals:Int64=0
            while(session.approval().isSome()){
                if(approvals>=6){throw IllegalStateException("one parent and five actual launch children required")}
                lifecycleTestRequire(session.decide(session.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
                approvals+=1}
            @Expect(approvals,6);@Expect(probe.count(),1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),4)
            @Expect(!probe.at(0).snapshot().released)
            let host=f.actual.product.vnext.javascriptPlugins
            let original=host.instanceGeneration(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)))
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("active-generation-held-child",f.name(),f.input("threads"))
            lifecycleTestRequire(session.submit("Approve the parent, then keep this exact threads write waiting."))
            lifecycleTestRequire(session.decide(session.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
            let child=session.approval().getOrThrow()
            let frozen=f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(child.operationId.value)])[0].required(0)
            let saved=decodeStoredValue(frozen)
            @Expect(lifecycleText(saved,"tool"),HOST_MANAGED_CHANNEL_WRITE_TOOL)
            @Expect(lifecycleText(saved.field("arguments").getOrThrow().field("operation").getOrThrow(),"kind"),"write")
            @Expect(f.actual.commandCount("threads"),0)
            @Expect(f.actual.product.setPluginEnabled(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),false).isOk())
            @Expect(!f.visible(thread))
            @Expect(f.actual.product.setPluginEnabled(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),true).isOk())
            @Expect(host.instanceGeneration(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)))>original)
            @Expect(!f.start(thread).isError)
            // ApplicationSession still owns the exact old child/control. The
            // newly installed tool with the same name cannot retarget that
            // Prepared, even after the actual endpoint is published again.
            let _=session.decide(child.operationId.value,ApprovalDecision.Approve)
            @Expect(f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(child.operationId.value)])[0].required(0),frozen)
            @Expect(session.approval().isNone())
            @Expect(f.actual.commandCount("threads"),0);@Expect(f.actual.commandCount("adapter-start"),1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),4)
            let until=MonoTime.now()+Duration.second*5
            while(!probe.at(0).snapshot().released && MonoTime.now()<until){sleep(Duration.millisecond*5)}
            let retired=probe.at(0).snapshot()
            @Expect(retired.released && retired.processCloseAcknowledged && retired.pumpsJoined && retired.ioDrained)
            @Expect(!retired.paymentRetained && !retired.namespaceDescriptorsRetained)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
            f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func actualPrivateBorrowBlocksCleanupUntilSamePaymentTreePumpsAndDescriptorsAck():Unit{
        let probe=OwnedDapCleanupProbe()
        let f=OwnedDapProductFixture(multiple:true)
        let thread="dap-owned-actual-blocked-close"
        let entered=AtomicBool(false);let release=AtomicBool(false)
        try{
            lifecycleTestRequire(f.actual.product.observeManagedCleanupForFixture(probe))
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"blocked-launch").isError)
            let reversed=f.call(thread,"blocked-reverse",f.input("custom_request",fields:[ValueField("command",textValue("fixture/runInTerminal")),ValueField("arguments",objectValue([]))]))
            @Expect(!reversed.isError);@Expect(probe.count(),2)
            let original=probe.at(0)
            @Expect(original.snapshot().paymentRetained);@Expect(original.snapshot().namespaceDescriptorsRetained)
            let borrowing=spawn{original.withCustodyBorrow({=>
                entered.store(true);let until=MonoTime.now()+Duration.second*15
                while(!release.load() && MonoTime.now()<until){sleep(Duration.millisecond*5)}
                if(!release.load()){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"fixture.borrow_timeout","actual custody borrower was not released"))}
                Result<Unit>.Ok(())})}
            try{
                let until=MonoTime.now()+Duration.second*5
                while(!entered.load() && MonoTime.now()<until){sleep(Duration.millisecond*5)}
                @Expect(entered.load());@Expect(original.snapshot().borrowed,1)
                @Expect(f.actual.product.stopPluginService(SessionId(thread),productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),"stdio").isError())
                var physical=false;let stopped=MonoTime.now()+Duration.second*5
                while(!physical && MonoTime.now()<stopped){
                    let state=original.snapshot();physical=state.processCloseAcknowledged && state.pumpsJoined && state.ioDrained
                    if(!physical){sleep(Duration.millisecond*5)}}
                @Expect(physical)
                let retained=original.snapshot()
                @Expect(retained.borrowed,1);@Expect(retained.paymentRetained);@Expect(!retained.released)
                @Expect(retained.namespaceDescriptorsRetained);@Expect(!f.released());@Expect(!f.visible(thread))
                // The actual auxiliary is separately joined; retaining the
                // adapter's real borrow cannot publish a false complete ACK.
                @Expect(probe.at(1).snapshot().released)
                release.store(true);lifecycleTestRequire(borrowing.get())
                let finished=MonoTime.now()+Duration.second*5
                while(!original.snapshot().released && MonoTime.now()<finished){sleep(Duration.millisecond*5)}
                let complete=original.snapshot()
                @Expect(complete.released);@Expect(!complete.paymentRetained);@Expect(complete.borrowed,0)
                @Expect(!complete.namespaceDescriptorsRetained)
                @Expect(complete.processCloseAcknowledged && complete.pumpsJoined && complete.ioDrained)
                f.stop(thread)
            }finally{release.store(true);let _=borrowing.get()}
        }finally{release.store(true);f.close()}
    }
}
