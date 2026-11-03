package agent_product

import agent_domain.*
import tool_runtime.ApprovalMode
import agent_store.*
import std.fs.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func selectShellFrontendFixture(f: ShellServiceProductFixture): Unit {
    let directory=f.files.settings+"/plugins"
    if(!exists(Path(directory))){Directory.create(directory)}
    File.writeTo(directory+"/shell-tools.json",encodeAgentValue(objectValue([
        ValueField("schema",textValue("axyndra.shell-tools/v1")),
        ValueField("namespace",textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest",textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
        ValueField("service_id",textValue("stdio")),ValueField("route",textValue("session"))])).toArray())
}

@Test
class SelectedNativeShellApplicationTests {
    @TestCase
    func missingSelectionRefusesBeforeAnyCanonicalCommandOrProcessEffect(): Unit {
        let f=ShellServiceProductFixture()
        try{
            let app=f.product.applicationSession(sessionId:Some(SessionId("native-shell-missing")))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            @Expect(app.executeBash("printf bypass > bypass.txt").isError())
            @Expect(!exists(Path(f.files.workspace+"/bypass.txt")))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
        }finally{f.close()}
    }

    @TestCase
    func startupApprovalCannotAuthorizeCommandAndWrongDecisionLeavesExactReview(): Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk)
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-shell-approval")).isError)
            let app=f.product.applicationSession(sessionId:Some(SessionId("native-shell-approval")))
            @Expect(app.executeBash("printf reviewed > reviewed.txt").isError())
            let approval=app.approval().getOrThrow()
            @Expect(!exists(Path(f.files.workspace+"/reviewed.txt")))
            @Expect(f.childReceipts(),0)
            @Expect(app.decide("wrong-operation",ApprovalDecision.Approve).isError())
            @Expect(app.approval().getOrThrow().operationId.value,approval.operationId.value)
            lifecycleTestRequire(app.decide(approval.operationId.value,ApprovalDecision.Approve))
            @Expect(String.fromUtf8(File.readFrom(f.files.workspace+"/reviewed.txt")),"reviewed")
            @Expect(f.childReceipts(),1)
            @Expect(app.approval().isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
        }finally{f.close()}
    }

    @TestCase
    func convenienceCallsUseSameNativePersistentSessionAndCanonicalReceipts(): Unit {
        let f=ShellServiceProductFixture()
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-shell-persistent")).isError)
            let app=f.product.applicationSession(sessionId:Some(SessionId("native-shell-persistent")))
            let first=lifecycleTestRequire(app.executeBash("export NATIVE_SAMPLE=retained; printf first"))
            @Expect(first.stdout,"first")
            let second=lifecycleTestRequire(app.executeBash("printf \"$NATIVE_SAMPLE\""))
            @Expect(second.stdout,"retained")
            @Expect(f.childReceipts(),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"),0)
        }finally{f.close()}
    }

    @TestCase
    func pendingActualOwnerCancellationHasNoWriteAndCannotBeReapproved(): Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk)
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-shell-cancel")).isError)
            let app=f.product.applicationSession(sessionId:Some(SessionId("native-shell-cancel")))
            @Expect(app.executeBash("printf forbidden > cancelled.txt").isError())
            let approval=app.approval().getOrThrow()
            lifecycleTestRequire(app.abortBash())
            @Expect(app.approval().isNone())
            @Expect(app.decide(approval.operationId.value,ApprovalDecision.Approve).isError())
            @Expect(!exists(Path(f.files.workspace+"/cancelled.txt")))
            @Expect(f.childReceipts(),0)
        }finally{f.close()}
    }

    @TestCase
    func selectionChangedWhilePendingFailsClosedWithoutNativeWrite(): Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk)
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-shell-drift")).isError)
            let app=f.product.applicationSession(sessionId:Some(SessionId("native-shell-drift")))
            @Expect(app.executeBash("printf forbidden > changed.txt").isError())
            let approval=app.approval().getOrThrow()
            File.writeTo(f.files.settings+"/plugins/shell-tools.json","{}".toArray())
            @Expect(app.decide(approval.operationId.value,ApprovalDecision.Approve).isError())
            @Expect(!exists(Path(f.files.workspace+"/changed.txt")))
            @Expect(f.childReceipts(),0)
        }finally{f.close()}
    }

    @TestCase
    func acquiredTerminalErrorKeepsItsActualOwnerThroughCleanupAcknowledgement(): Unit {
        let f=ShellServiceProductFixture()
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-shell-error")).isError)
            let actual=lifecycleTestRequire(f.product.invokeShellTool(SessionId("native-shell-error"),
                objectValue([ValueField("command",textValue("printf forbidden > invalid.txt")),
                    ValueField("env",objectValue([ValueField("bad-name",textValue("value"))]))])))
            @Expect(actual.failure().isSome())
            @Expect(actual.output().isError())
            @Expect(!exists(Path(f.files.workspace+"/invalid.txt")))
            lifecycleTestRequire(actual.close())
            lifecycleTestRequire(actual.close())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
        }finally{f.close()}
    }
}

@Test
class SelectedNativeShellRetentionTests {
    @TestCase
    func acquiredCancellationBeforeStartRetainsOriginalTypedErrorWithoutCreatingRoot(): Unit {
        let f=ShellServiceProductFixture()
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-prestart-cancel")).isError)
            let actual=lifecycleTestRequire(f.product.acquireShellToolInvocation(SessionId("native-prestart-cancel")))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            lifecycleTestRequire(actual.cancel())
            let result=actual.start(f.input("printf forbidden > cancelled-before-root.txt"),
                ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1))
            @Expect(result.isError())
            actual.recordFailure(result.error().getOrThrow())
            @Expect(actual.output().error().getOrThrow().kind,AgentErrorKind.Cancelled)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            @Expect(!exists(Path(f.files.workspace+"/cancelled-before-root.txt")))
            lifecycleTestRequire(actual.close())
        }finally{f.close()}
    }

    @TestCase
    func productCloseCancelsItsExactAcquiredPendingCommandBeforeServiceShutdown(): Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk)
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("retained-product-close")).isError)
            let actual=lifecycleTestRequire(f.product.invokeShellTool(SessionId("retained-product-close"),
                f.input("printf forbidden > never-close.txt")))
            let pending=actual.approval().getOrThrow()
            @Expect(!exists(Path(f.files.workspace+"/never-close.txt")))
            lifecycleTestRequire(f.product.close())
            @Expect(actual.approval().isNone())
            @Expect(actual.decide(pending.operationId.value,ApprovalDecision.Approve).isError())
            lifecycleTestRequire(actual.close())
            @Expect(!exists(Path(f.files.workspace+"/never-close.txt")))
        }finally{f.close()}
    }

    @TestCase
    func boundedActualInstanceRetentionReclaimsCapacityOnlyAfterSameOwnerAck(): Unit {
        let f=ShellServiceProductFixture()
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("retained-capacity")).isError)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let values=ArrayList<ProductNativeToolInvocation>()
            for(index in 0..64){values.add(lifecycleTestRequire(f.product.acquireShellToolInvocation(SessionId("retained-capacity"))))}
            @Expect(f.product.acquireShellToolInvocation(SessionId("retained-capacity")).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            lifecycleTestRequire(values[0].close())
            let next=lifecycleTestRequire(f.product.acquireShellToolInvocation(SessionId("retained-capacity")))
            lifecycleTestRequire(next.close())
            for(value in values){lifecycleTestRequire(value.close())}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
        }finally{f.close()}
    }

    @TestCase
    func networkChoiceOnlyMatchesAlreadyConfiguredActualServicePolicy(): Unit {
        let f=ShellServiceProductFixture()
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-network-choice")).isError)
            let app=f.product.applicationSession(sessionId:Some(SessionId("native-network-choice")))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            @Expect(app.executeBash("printf forbidden > network-change.txt",
                networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.HostNetwork))).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            @Expect(!exists(Path(f.files.workspace+"/network-change.txt")))
            @Expect(lifecycleTestRequire(app.executeBash("printf allowed",
                timeoutMillis:1500,networkPolicy:Some(NetworkPolicy(NetworkPolicyMode.Denied)))).stdout,"allowed")
            @Expect(f.childReceipts(),1)
        }finally{f.close()}
    }
}

@Test
class SelectedNativeShellProfileAndArtifactTests {
    @TestCase
    func explicitSixHundredSecondsRefusesTenSecondProfileBeforeRootWhileValidDefaultExecutes(): Unit {
        let f=ShellServiceProductFixture()
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("selected-profile")).isError)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let refused=f.product.invokeShellTool(SessionId("selected-profile"),objectValue([
                ValueField("command",textValue("printf forbidden > profile-bypass.txt")),ValueField("timeout",integerValue(0))]))
            @Expect(refused.isError());@Expect(refused.error().getOrThrow().code,"shell.timeout_exceeds_service")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            @Expect(!exists(Path(f.files.workspace+"/profile-bypass.txt")))
            let app=f.product.applicationSession(sessionId:Some(SessionId("selected-profile")))
            @Expect(lifecycleTestRequire(app.executeBash("printf valid-default")).stdout,"valid-default")
            @Expect(f.childReceipts(),1)
        }finally{f.close()}
    }

    @TestCase
    func observedArtifactGetsDistinctActualRootAndChoiceBeforeFullBytesRead(): Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk,streamOutput:true)
        try{
            selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("artifact-choice")).isError)
            let parent=lifecycleTestRequire(f.product.invokeShellTool(SessionId("artifact-choice"),f.input(
                "/usr/bin/python3 -c 'print(\"x\"*131072,end=\"\")'")))
            let command=parent.approval().getOrThrow()
            lifecycleTestRequire(parent.decide(command.operationId.value,ApprovalDecision.Approve))
            let output=lifecycleTestRequire(parent.output()).field("result").getOrThrow()
            let reference=output.field("artifacts").getOrThrow().items[0].field("ref").getOrThrow().text
            let child=lifecycleTestRequire(parent.beginArtifactRead(reference))
            let read=child.approval().getOrThrow()
            @Expect(read.operationId.value!=command.operationId.value)
            @Expect(child.output().isError());@Expect(child.receiptId(),"")
            @Expect(child.decide(command.operationId.value,ApprovalDecision.Approve).isError())
            @Expect(child.approval().getOrThrow().operationId.value,read.operationId.value)
            lifecycleTestRequire(child.decide(read.operationId.value,ApprovalDecision.Approve))
            let value=lifecycleTestRequire(child.output())
            @Expect(value.field("returned_bytes").getOrThrow().asNumberText(),"131072")
            @Expect(value.field("content").getOrThrow().text,String.fromUtf8(Array<Byte>(131072,repeat:b'x')))
            @Expect(child.receiptId()!="" && child.receiptId()!=parent.receiptId())
            @Expect(f.database.readTransaction<Int64>({transaction=>
                let rows=transaction.query("SELECT COUNT(*) FROM operation_receipts WHERE id=? AND outcome='completed'",
                    [SqlParameter.Text(child.receiptId())])
                if(rows.size!=1 || rows[0].size<1){throw IllegalStateException("actual bound count returned no scalar row")}
                Int64.parse(rows[0].required(0))}),1)
            @Expect(f.database.readTransaction<Int64>({transaction=>
                let rows=transaction.query("SELECT COUNT(*) FROM derived_operation_admissions WHERE operation_id=?",
                    [SqlParameter.Text(read.operationId.value)])
                if(rows.size!=1 || rows[0].size<1){throw IllegalStateException("actual bound count returned no scalar row")}
                Int64.parse(rows[0].required(0))}),0)
            lifecycleTestRequire(parent.close())
            @Expect(child.output().isError());@Expect(parent.output().isError())
            lifecycleTestRequire(child.close())
        }finally{f.close()}
    }

    @TestCase
    func unobservedAndUnrelatedReferencesCannotCreateRootOrBorrowAnotherOwner(): Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk,streamOutput:true)
        try{
            selectShellFrontendFixture(f);@Expect(!managedCompleted(f.start("artifact-unobserved")).isError)
            let parent=lifecycleTestRequire(f.product.invokeShellTool(SessionId("artifact-unobserved"),f.input("printf small")))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let unobserved="blob:sha256:"+String.fromUtf8(Array<Byte>(64,repeat:b'0'))
            @Expect(parent.beginArtifactRead(unobserved).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            let pending=parent.approval().getOrThrow();lifecycleTestRequire(parent.decide(pending.operationId.value,ApprovalDecision.Approve))
            let complete=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            @Expect(parent.beginArtifactRead(unobserved).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),complete)
            lifecycleTestRequire(parent.close());@Expect(parent.beginArtifactRead(unobserved).isError())
        }finally{f.close()}
    }

    @TestCase
    func productCloseCancelsPendingIndependentArtifactRootAndRetainsSameOwnersUntilAck(): Unit {
        let f=ShellServiceProductFixture(approval:ApprovalMode.AlwaysAsk,streamOutput:true)
        try{
            selectShellFrontendFixture(f);@Expect(!managedCompleted(f.start("artifact-close")).isError)
            let parent=lifecycleTestRequire(f.product.invokeShellTool(SessionId("artifact-close"),f.input(
                "/usr/bin/python3 -c 'print(\"x\"*131072,end=\"\")'")))
            let review=parent.approval().getOrThrow();lifecycleTestRequire(parent.decide(review.operationId.value,ApprovalDecision.Approve))
            let reference=lifecycleTestRequire(parent.output()).field("result").getOrThrow().field("artifacts").getOrThrow().items[0].field("ref").getOrThrow().text
            let child=lifecycleTestRequire(parent.beginArtifactRead(reference));let pending=child.approval().getOrThrow()
            lifecycleTestRequire(f.product.close())
            @Expect(child.approval().isNone());@Expect(child.decide(pending.operationId.value,ApprovalDecision.Approve).isError())
            @Expect(parent.output().isError());@Expect(child.output().isError())
            lifecycleTestRequire(parent.close());lifecycleTestRequire(child.close())
        }finally{f.close()}
    }
}

@Test
class SelectedNativeShellResourceAccountingTests {
    @TestCase
    func nativeCapturedOutput32AndOpenFiles16KeepSeparateBoundedHostControlTransport(): Unit {
        let f=ShellServiceProductFixture(streamOutput:true)
        try{
            // Configure a real backend capture ceiling; Host protocol/control
            // bytes retain their separate finite original16MiB charge/bound.
            let path=f.files.settings+"/plugins/lifecycle.json"
            let document=parseUnifiedJson(String.fromUtf8(File.readFrom(path)),maxBytes:262144)
            let service=document.field("plugins").getOrThrow().items[0].field("services").getOrThrow().items[0]
            let args=ArrayList<AgentValue>(service.field("arguments").getOrThrow().items.toArray())
            args.add(textValue("--output-bytes"));args.add(textValue("32"));service.put("arguments",listValue(args.toArray()))
            service.field("resources").getOrThrow().put("open_files",integerValue(16))
            f.files.write(document);selectShellFrontendFixture(f)
            @Expect(!managedCompleted(f.start("native-capture32")).isError)
            let actual=lifecycleTestRequire(f.product.invokeShellTool(SessionId("native-capture32"),f.input(
                "ulimit -n; head -c 4096 /dev/zero | tr '\\000' y; printf marker-after-truncation")))
            let envelope=lifecycleTestRequire(actual.output());let value=envelope.field("result").getOrThrow()
            @Expect(envelope.field("status").getOrThrow().text,"complete")
            @Expect(value.field("exitCode").getOrThrow().asNumberText(),"0")
            @Expect(value.field("stdout").getOrThrow().text.startsWith("16\n"))
            @Expect(value.field("truncated").getOrThrow().asBool())
            @Expect(value.field("stdout").getOrThrow().text.toArray().size<=32)
            @Expect(value.field("stdoutBytes").getOrThrow().asNumberText()!="32")
            @Expect(actual.receiptId()!="");@Expect(f.childReceipts(),1)
            // The actual operation remains retained until the acquired owner
            // ACK, and no DTO can represent a32-byte whole Run/control grant.
            lifecycleTestRequire(actual.close());@Expect(actual.output().isError())
        }finally{f.close()}
    }
}
