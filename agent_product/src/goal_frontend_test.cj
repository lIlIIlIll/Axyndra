package agent_product

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func goalFrontendConfigure(f: WorkflowDocumentFixture): Unit {
    File.writeTo(f.root+"/settings/plugins/goal-tools.json",stringifyUnifiedJson(objectValue([
        ValueField("schema",textValue("axyndra.goal-tools/v1")),
        ValueField("namespace",textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest",textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
        ValueField("tool",textValue("goal")),ValueField("command",textValue("goal"))])).toArray())
}
func goalFrontendLegacy(objective!: String="preserve history"): AgentValue {
    objectValue([ValueField("id",textValue("historical-goal")),ValueField("objective",textValue(objective)),
        ValueField("status",textValue("active")),ValueField("tokenBudget",integerValue(1000)),
        ValueField("tokensUsed",integerValue(123)),ValueField("timeUsedSeconds",integerValue(8)),
        ValueField("createdAt",integerValue(1000)),ValueField("updatedAt",integerValue(2000)),
        ValueField("enabled",boolValue(true)),ValueField("baselineTokens",integerValue(400)),
        ValueField("accountedAt",integerValue(2000))])
}
func goalFrontendSeedCold(f: WorkflowDocumentFixture,thread: String,raw: String): Unit {
    lifecycleTestRequire(SqliteSessionMetadataRepository(f.database).setDraft(SessionId(thread),"cold history fixture"))
    // This explicit test seam edits the actual existing legacy SQL field. It
    // creates no Source, current invocation, approval or continuation owner.
    f.database.execute("UPDATE thread_metadata SET goal_payload=? WHERE thread_id=?",[SqlParameter.Text(raw),SqlParameter.Text(thread)])
}
func goalFrontendCold(f: WorkflowDocumentFixture,thread: String): String {
    f.database.query("SELECT goal_payload FROM thread_metadata WHERE thread_id=?",[SqlParameter.Text(thread)])[0].required(0)
}

@Test
class GoalFrontendTests {
    @TestCase
    func unprovidedOrDisabledSelectionCannotCreateAnyNewRunOrDocument() {
        let f=WorkflowDocumentFixture(provider:"prepare_document",payload:true)
        try{
            let session=f.product.applicationSession(sessionId:Some(SessionId("goal-unprovided")))
            @Expect(session.handle("/goal set unselected").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0)
            @Expect(f.snapshot("goal-unprovided",key:"goal").revision,0)
            goalFrontendConfigure(f)
            let _=f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),false,PluginInstallScope.Workspace)
            @Expect(session.handle("/goal set disabled").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0)
            @Expect(f.snapshot("goal-unprovided",key:"goal").revision,0)
        }finally{f.close()}
    }

    @TestCase
    func selectedSlashUsesActualRootAndDisplayCopiesCannotChangeCanonicalFacts() {
        let f=WorkflowDocumentFixture(provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-selected-slash"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            @Expect(session.handle("/goal set selected objective").isOk())
            let snapshot=f.snapshot(thread,key:"goal")
            @Expect(snapshot.revision,1)
            let projection=lifecycleTestRequire(f.product.goalState(SessionId(thread))).getOrThrow()
            @Expect(projection.objective,"selected objective");@Expect(projection.enabled)
            let copy=lifecycleTestRequire(snapshot.decode());copy.put("enabled",boolValue(false))
            @Expect(lifecycleTestRequire(f.product.goalState(SessionId(thread))).getOrThrow().enabled)
            @Expect(f.snapshot(thread,key:"goal").encoded,snapshot.encoded)
            @Expect(workflowDocumentTestAllowance(f,thread).getOrThrow().enabled)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM thread_metadata WHERE goal_payload<>''"),0)
        }finally{f.close()}
    }

    @TestCase
    func deferredReadThenActualGoalMutationNeedsItsOwnApprovalAndRejectHasNoControl() {
        let f=WorkflowDocumentFixture(mode:ApprovalMode.AlwaysAsk,provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-frontend-approval"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            @Expect(session.handle("/goal set wait for actual approval").isOk())
            let read=session.approval().getOrThrow();@Expect(read.toolName,HOST_CONTEXT_READ_TOOL)
            @Expect(f.snapshot(thread,key:"goal").revision,0)
            @Expect(session.decide(read.operationId.value,ApprovalDecision.Approve).isOk())
            let mutation=session.approval().getOrThrow()
            @Expect(mutation.operationId.value!=read.operationId.value)
            @Expect(mutation.toolName,"plugin."+productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))+".goal")
            @Expect(httpIntentText(mutation.preview.field("host_user_control").getOrThrow(),"action"),"create")
            @Expect(session.decide(mutation.operationId.value,ApprovalDecision.Reject).isError())
            @Expect(f.snapshot(thread,key:"goal").revision,0)
            @Expect(workflowDocumentTestAllowance(f,thread).isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{f.close()}
    }

    @TestCase
    func exactColdBytesImportPreservesHistoryAndEnabledDataDoesNotGrantContinuation() {
        let f=WorkflowDocumentFixture(provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-cold-history"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            let history=goalFrontendLegacy()
            let raw=" \n"+stringifyUnifiedJson(history)+"\n "
            goalFrontendSeedCold(f,thread,raw)
            @Expect(session.handle("/goal set cannot overwrite cold history").isError())
            @Expect(f.snapshot(thread,key:"goal").revision,0)
            @Expect(session.handle("/goal migrate").isOk())
            @Expect(goalFrontendCold(f,thread),raw)
            let imported=lifecycleTestRequire(f.snapshot(thread,key:"goal").decode())
            @Expect(canonicalAgentValue(imported),canonicalAgentValue(history))
            @Expect(lifecycleTestRequire(f.product.goalState(SessionId(thread))).getOrThrow().enabled)
            @Expect(workflowDocumentTestAllowance(f,thread).isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"),0)
            @Expect(session.handle("/goal resume").isOk())
            @Expect(workflowDocumentTestAllowance(f,thread).getOrThrow().enabled)
            @Expect(goalFrontendCold(f,thread),raw)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{f.close()}
    }

    @TestCase
    func sameJsonDifferentColdBytesDuringApprovalCannotCommitTheFrozenMigration() {
        let f=WorkflowDocumentFixture(mode:ApprovalMode.AlwaysAsk,provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-cold-changed"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            let raw=stringifyUnifiedJson(goalFrontendLegacy())
            goalFrontendSeedCold(f,thread,raw)
            @Expect(session.handle("/goal migrate").isOk())
            let approval=session.approval().getOrThrow()
            let changed=" "+raw+" "
            goalFrontendSeedCold(f,thread,changed)
            @Expect(session.decide(approval.operationId.value,ApprovalDecision.Approve).isError())
            @Expect(f.snapshot(thread,key:"goal").revision,0)
            @Expect(goalFrontendCold(f,thread),changed)
            @Expect(workflowDocumentTestAllowance(f,thread).isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{f.close()}
    }

    @TestCase
    func selectedConfigurationChangeDuringApprovalCannotWriteTheGoal() {
        let f=WorkflowDocumentFixture(mode:ApprovalMode.AlwaysAsk,provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-selection-changed"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            @Expect(session.handle("/goal set stale selection").isOk())
            let approval=session.approval().getOrThrow()
            let path=f.root+"/settings/plugins/goal-tools.json"
            File.writeTo(path,(String.fromUtf8(File.readFrom(path))+" ").toArray())
            @Expect(session.decide(approval.operationId.value,ApprovalDecision.Approve).isError())
            @Expect(f.snapshot(thread,key:"goal").revision,0)
            @Expect(workflowDocumentTestAllowance(f,thread).isNone())
        }finally{f.close()}
    }

    @TestCase
    func actualCancelOfPendingMigrationLeavesBothDocumentsAndHistoryUntouched() {
        let f=WorkflowDocumentFixture(mode:ApprovalMode.AlwaysAsk,provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-cold-cancel"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            let raw=stringifyUnifiedJson(goalFrontendLegacy())
            goalFrontendSeedCold(f,thread,raw)
            @Expect(session.handle("/goal migrate").isOk())
            @Expect(session.approval().isSome())
            @Expect(session.cancel().isOk())
            @Expect(session.approval().isNone())
            @Expect(f.snapshot(thread,key:"goal").revision,0)
            @Expect(goalFrontendCold(f,thread),raw)
            @Expect(workflowDocumentTestAllowance(f,thread).isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{f.close()}
    }

    @TestCase
    func unsupportedColdConvenienceSizeIsReadOnlyBeforeAnyNewRoot() {
        let f=WorkflowDocumentFixture(provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-cold-unsupported"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            let raw=stringifyUnifiedJson(goalFrontendLegacy(objective:String.fromUtf8(Array<UInt8>(18000,repeat:b'x'))))
            goalFrontendSeedCold(f,thread,raw)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            @Expect(session.handle("/goal migrate").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),before)
            @Expect(goalFrontendCold(f,thread),raw)
            @Expect(f.snapshot(thread,key:"goal").revision,0)
            @Expect(workflowDocumentTestAllowance(f,thread).isNone())
        }finally{f.close()}
    }
    @TestCase
    func currentGoalShowAndPauseIgnoreMalformedColdHistoryWithoutChangingItsBytes() {
        let f=WorkflowDocumentFixture(provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-current-cold-malformed"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            @Expect(session.handle("/goal set current goal survives archived corruption").isOk())
            let first=f.snapshot(thread,key:"goal")
            @Expect(first.revision>0)
            @Expect(lifecycleTestRequire(f.product.goalState(SessionId(thread))).getOrThrow().enabled)
            let cold=" \n{unsupported: archived-goal}\n "
            goalFrontendSeedCold(f,thread,cold)
            let receipts=f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'")
            @Expect(session.handle("/goal show").isOk())
            @Expect(goalFrontendCold(f,thread),cold)
            @Expect(lifecycleTestRequire(f.product.goalState(SessionId(thread))).getOrThrow().objective,"current goal survives archived corruption")
            @Expect(session.handle("/goal pause").isOk())
            @Expect(!lifecycleTestRequire(f.product.goalState(SessionId(thread))).getOrThrow().enabled)
            @Expect(!workflowDocumentTestAllowance(f,thread).getOrThrow().enabled)
            @Expect(goalFrontendCold(f,thread),cold)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'")>receipts)
            let paused=f.snapshot(thread,key:"goal")
            let runs=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            @Expect(session.handle("/goal migrate").isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),runs)
            @Expect(f.snapshot(thread,key:"goal").encoded,paused.encoded)
            @Expect(f.snapshot(thread,key:"goal").revision,paused.revision)
            @Expect(goalFrontendCold(f,thread),cold)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{f.close()}
    }

    @TestCase
    func malformedColdHistoryWithNoCurrentGoalStillRejectsBeforeAnyNewRoot() {
        let f=WorkflowDocumentFixture(provider:"prepare_document",payload:true)
        try{
            goalFrontendConfigure(f)
            let thread="goal-empty-cold-malformed"
            let session=f.product.applicationSession(sessionId:Some(SessionId(thread)))
            let cold=" \n{unsupported: archived-goal}\n "
            goalFrontendSeedCold(f,thread,cold)
            let runs=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            for(command in ["/goal show","/goal pause","/goal set must not overwrite history","/goal migrate"]){
                @Expect(session.handle(command).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),runs)
                @Expect(f.snapshot(thread,key:"goal").revision,0)
                @Expect(goalFrontendCold(f,thread),cold)
                @Expect(workflowDocumentTestAllowance(f,thread).isNone())
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{f.close()}
    }
}
