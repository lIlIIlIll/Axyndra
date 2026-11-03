package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_plugin_registry.PluginRegistry
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func registryPeerDisable(settings:String,workspace:String,name:String):Unit {
        let _registryOwners = ProductRegistryTestOwners()
        try {

    // The old Product/Host remains alive. This independent management object
    // is the same implementation used by the separately tested CLI process.
    let peer=_registryOwners.openRegistry(settings,workspace)
    match(peer.setEnabled(name,false)){
        case PluginRegistryResult.Ok(value)=>if(value.enabled){throw IllegalStateException("actual registry disable did not persist")}
        case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}

        } finally { _registryOwners.close() }
    }
private func registryInvocationRejected(value:Result<ToolInvocationResult>):Bool {
    match(value){case Result.Err(_)=>true
        case Result.Ok(ToolInvocationResult.Completed(result))=>result.isError
        case _=>false}
}

@Test
class PluginRegistryExecutionTests {
    @TestCase
    func separatelyPublishedDisablePreventsNewActualNativeReadViewHandoff():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let first=f.invoke("registry-native-positive",f.input("printf native-current"))
            try{@Expect(lifecycleTestRequire(first.output()).field("stdout").getOrThrow().text,"native-current")
                f.requireRootAndWorker("registry-native-positive",first.receiptId())}
            finally{lifecycleTestRequire(first.close())}
            registryPeerDisable(f.files.settings,f.files.workspace,productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))
            let next=f.product.invokeShellTool(SessionId("registry-native-revoked"),f.input("printf must-not-run"),readOnly:true,
                budget:ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1))
            var refused=false
            match(next){case Result.Err(_)=>refused=true
                case Result.Ok(value)=>try{refused=value.output().isError()}finally{lifecycleTestRequire(value.close())}}
            @Expect(refused);@Expect(f.workerHandoffs("registry-native-revoked"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"),0)
        }finally{f.close()}
    }
    @TestCase
    func separatelyPublishedDisableStopsExistingServiceWritesButKeepsActualCloseAck():Unit {
        let f=ShellServiceProductFixture()
        try{@Expect(!managedCompleted(f.start("registry-channel")).isError)
            @Expect(lifecycleText(shellServiceOutput(f.call("registry-channel","positive",f.input("printf live"))),"stdout"),"live")
            let before=f.childReceipts()
            registryPeerDisable(f.files.settings,f.files.workspace,productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))
            @Expect(registryInvocationRejected(f.call("registry-channel","revoked",f.input("printf forbidden > registry-forbidden.txt"))))
            @Expect(!exists(Path(f.files.workspace+"/registry-forbidden.txt")))
            @Expect(f.childReceipts(),before)
            // finally uses the real service/process close loop. Revocation
            // never becomes permission to release an unacknowledged owner.
        }finally{f.close()}
    }
    @TestCase
    func retainedApprovalAfterOtherRegistryDisableCannotReachCanonicalHandoff():Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk)
        try{selectShellFrontendFixture(f);@Expect(!managedCompleted(f.start("registry-review")).isError)
            let app=f.product.applicationSession(sessionId:Some(SessionId("registry-review")))
            @Expect(app.executeBash("printf forbidden > registry-approved.txt").isError())
            let approval=app.approval().getOrThrow()
            let before=f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'")
            registryPeerDisable(f.files.settings,f.files.workspace,productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))
            let result=app.decide(approval.operationId.value,ApprovalDecision.Approve)
            @Expect(result.isError())
            @Expect(!exists(Path(f.files.workspace+"/registry-approved.txt")))
            @Expect(f.childReceipts(),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),before)
        }finally{f.close()}
    }
    @TestCase
    func separatelyPublishedDisableCannotMakeAnotherHttpRequestFromOldHost():Unit {
        let f=PluginHttpProductFixture("registry-pin","normal")
        try{let first=lifecycleTestRequire(f.invoke("registry-http-positive"));@Expect(!first.isError);f.awaitObserved(1)
            registryPeerDisable(f.root+"/settings",f.root,productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))
            let result=f.invoke("registry-http-revoked")
            @Expect(match(result){case Result.Err(_)=>true;case Result.Ok(value)=>value.isError})
            @Expect(f.observed().size,1)
            @Expect(f.database.query("SELECT a.operation_id FROM audit_events a JOIN operations o ON o.id=a.operation_id "+
                "JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND a.kind='operation_execution_handoff'",
                [SqlParameter.Text("registry-http-revoked")]).size,0)
        }finally{f.close()}
    }
}
