package agent_product

import agent_core.*
import agent_domain
import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_store.*
import tool_runtime.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func completedHistoryCheckpointGrant173e(name: String): AgentValue {
    objectValue([ValueField("name", textValue(name)), ValueField("provider", textValue("summarize")),
        ValueField("action", textValue("canonical.context.project")), ValueField("capability", textValue("workspace.read")),
        ValueField("effect", textValue("read_only"))])
}

private func actualHistoricalServiceFrame173e(f: CompactionPolicyFixture): Unit {
    let probe=HostServiceEntryProbe()
    @Expect(f.product.registerTool(ToolDescriptor(ModelToolDefinition("fixture_host_control",
        "Actual canonical service history",objectValue([ValueField("type",textValue("object"))])),
        Capability(CapabilityKind.WorkspaceRead),sideEffecting:true,controlOnly:true,
        implementationVersion:"host-service-entry-fixture-v1",neverReplay:true),probe).isOk())
    let call=ToolCall("service-history173e","fixture_host_control",objectValue([
        ValueField("source",textValue("external")),ValueField("principal",textValue("root"))]))
    let result=f.product.vnext.executeCanonicalHostServiceTool(f.session,hostServiceEntryTestOrigin(),
        CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),call,Some(ApprovalDecision.Approve),
        ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1),None<agent_domain.CancellationToken>)
    match(result){case Result.Ok(ToolInvocationResult.Completed(value))=>
        try {@Expect(!value.isError);@Expect(probe.calls,1)}finally{value.releasePayload()}
        case Result.Err(error)=>throw IllegalStateException(error.describe())
        case _=>throw IllegalStateException("actual service must have its canonical completed result")}
}
private func historyActionCounts173e(db: SqliteDatabase): Array<Int64> {
    [db.scalarInt("SELECT COUNT(*) FROM operations"),db.scalarInt("SELECT COUNT(*) FROM operation_receipts"),
        db.scalarInt("SELECT COUNT(*) FROM model_attempts"),db.scalarInt("SELECT COUNT(*) FROM model_decisions"),
        db.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")]
}
private func historyNoReplay173e(db: SqliteDatabase,before: Array<Int64>): Unit {
    let after=historyActionCounts173e(db)
    for(at in 0..before.size){@Expect(after[at],before[at])}
}
private func actualHistoricalSeedOracle173e(db: SqliteDatabase,original: AgentThreadSnapshot,target: SessionId): Unit {
    let actual=SqliteThreadCommitSink(db).loadThread(ThreadId(target.value))
    @Expect(actual.turns.size,original.turns.size);@Expect(actual.items.size,original.items.size)
    @Expect(actual.thread.revision,1);@Expect(actual.thread.nextItemOrdinal,original.thread.nextItemOrdinal)
    @Expect(actual.thread.activeTurnId.isNone() && actual.activeRunId.isNone())
    for(at in 0..original.items.size){
        let old=original.items[at];let copied=actual.items[at]
        @Expect(copied.id.value,"seed-item-"+target.value+"-"+old.ordinal.toString())
        @Expect(copied.ordinal,old.ordinal);@Expect(copied.kind,old.kind);@Expect(copied.createdAtMillis,old.createdAtMillis)
        let content=match(old.content){case ThreadItemContent.ToolResult(call,_,receipt,value,error)=>
            ThreadItemContent.ToolResult(call,OperationId("seed-operation-"+target.value+"-"+old.ordinal.toString()),receipt,value,error)
            case value=>value}
        @Expect(encodeStoredThreadContent(copied.content),encodeStoredThreadContent(content))
        if(isOwnedDirectInitiator(old) || isInternalModelMaintenanceInitiator(old) || isCompletedInitiatorHistory173e(old)){
            @Expect(isCompletedInitiatorHistory173e(copied));@Expect(!isOwnedDirectInitiator(copied))
            @Expect(!isInternalModelMaintenanceInitiator(copied))
            @Expect(copied.provenance.directOrigin.isNone() && copied.provenance.operationId.isNone())
            let description=copied.provenance.completedInitiatorHistory173e.getOrThrow()
            @Expect(description.threadId,old.threadId.value);@Expect(description.turnId,old.turnId.value)
            @Expect(description.runId,old.provenance.runId.getOrThrow().value);@Expect(description.itemId,old.id.value)
            if(isCompletedInitiatorHistory173e(old)){
                let prior=old.provenance.completedInitiatorHistory173e.getOrThrow()
                @Expect(description.originalSource,prior.originalSource);@Expect(description.originDigest,prior.originDigest)
                @Expect(description.evidenceDigest,prior.evidenceDigest);@Expect(description.evidenceCells,prior.evidenceCells)
            }else{
                @Expect(description.originalSource,old.provenance.source)
                @Expect(description.originDigest,modelPolicySha256Text(encodeStoredProvenance(old.provenance)))
                @Expect(description.evidenceCells>0)
                @Expect(description.origin.isSome()==old.provenance.directOrigin.isSome())
                match(old.provenance.directOrigin){case Some(origin)=>
                    @Expect(sameDirectCallOrigin(description.origin.getOrThrow(),origin));case None=>()}
                // Full original source bytes, including UTF8/NUL/origin fields,
                // are copied unchanged. These SELECTs use the test's original
                // prepaid small fixture oracle; no synthetic Source/Receipt.
                let evidence=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND operation_id=? "+
                    "AND kind='completed_initiator_cell173e_v1:initial.provenance:text'",
                    [SqlParameter.Text(target.value),SqlParameter.Text(copied.id.value)])
                @Expect(evidence.size,1);@Expect(evidence[0].required(0),encodeStoredProvenance(old.provenance))
            }
            let header=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND operation_id=? "+
                "AND kind='completed_initiator_history173e_v1'",[SqlParameter.Text(target.value),SqlParameter.Text(copied.id.value)])
            @Expect(header.size,1);@Expect(header[0].required(0),encodeStoredValue(completedInitiatorHistoryValue173e(description)))
        }else{
            let operation=match(content){case ThreadItemContent.ToolResult(_,id,_,_,_)=>Some(id);case _=>None<OperationId>}
            @Expect(encodeStoredProvenance(copied.provenance),encodeStoredProvenance(ItemProvenance("fork",
                runId:copied.provenance.runId,operationId:operation)))
        }
    }
    @Expect(db.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id="+sqliteText(target.value)+
        " AND state='completed' AND cancellation_reason IS NULL"),actual.turns.size)
    @Expect(db.scalarInt("SELECT COUNT(*) FROM operations WHERE run_id IN(SELECT id FROM runs WHERE thread_id="+
        sqliteText(target.value)+")"),0)
}
class HistoricalErrorCapture173e {var consumer:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>}

@Test
class InstalledCompletedInitiatorHistory173eTests {
    @TestCase
    func actualHostServiceKeepsOldRawRefusalAndUniformPaidForkReopenAfterOriginalDiscard173e(): Unit {
        let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
        let oracle=reserveNativeControlMetadata(8388608)
        try {
            actualHistoricalServiceFrame173e(f)
            let original=SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            @Expect(original.items[0].kind,ItemKind.SystemNote);@Expect(isOwnedDirectInitiator(original.items[0]))
            var rejected=false
            try{let _=completedThreadCloneSnapshot(ThreadId("raw-service-refusal173e"),f.root,original)}
            catch(error:IllegalArgumentException){@Expect(error.message,"seed source Turn is missing its user Item");rejected=true}
            @Expect(rejected)
            let before=historyActionCounts173e(f.database);let target=SessionId("actual-service-fork173e")
            @Expect(f.product.forkSession(f.session,target).isOk())
            actualHistoricalSeedOracle173e(f.database,original,target);historyNoReplay173e(f.database,before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_host_origin_bound'"),1)
            // Actual production discard, never a synthetic DELETE. The target
            // owns its full historical evidence and requires no original live
            // Source, old Run grant, primitive replay or parent receipt mint.
            @Expect(lifecycleTestRequire(f.product.removeConversation(f.session)))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE id="+sqliteText(f.session.value)),0)
            let afterDiscard=historyActionCounts173e(f.database)
            @Expect(f.product.close().isOk())
            let reopened=lifecycleTestRequire(openProduct(config:ProductConfig(workspaceRoot:f.root,
                settingsRoot:f.root+"/settings",stateRoot:f.root+"/state",fixture:true,asyncEnabled:false)))
            try {
                let loaded=SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
                @Expect(isCompletedInitiatorHistory173e(loaded.items[0]))
                let again=SessionId("actual-service-second-fork173e")
                @Expect(reopened.forkSession(target,again).isOk())
                actualHistoricalSeedOracle173e(f.database,loaded,again);historyNoReplay173e(f.database,afterDiscard)
            }finally{let _=reopened.close()}
        }finally{oracle.close();f.close()}
    }
    @TestCase
    func actualInternalMaintenanceAttemptRemainsDataAcrossForkAndSecondFork173e(): Unit {
        let f=CompactionPolicyFixture(hybrid:true)
        let oracle=reserveNativeControlMetadata(8388608)
        try {
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session,force:true))>0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_context_compaction' AND lifecycle='completed'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='system_note'"),1)
            let original=SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            let before=historyActionCounts173e(f.database);let target=SessionId("actual-maintenance-fork173e")
            @Expect(f.product.forkSession(f.session,target).isOk())
            actualHistoricalSeedOracle173e(f.database,original,target);historyNoReplay173e(f.database,before)
            let loaded=SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
            let again=SessionId("actual-maintenance-second-fork173e")
            @Expect(f.product.forkSession(target,again).isOk())
            actualHistoricalSeedOracle173e(f.database,loaded,again);historyNoReplay173e(f.database,before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE run_id IN(SELECT id FROM runs WHERE thread_id='actual-maintenance-fork173e' OR thread_id='actual-maintenance-second-fork173e')"),0)
        }finally{oracle.close();f.close()}
    }
    @TestCase
    func actualAmplifiedHistoryInsertRollsBackWithoutUnpaidReadAndConsumerAckWaitsForLoan173e(): Unit {
        let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
        let session=f.product.applicationSession(sessionId:Some(f.session))
        let capture=HistoricalErrorCapture173e();let oracle=reserveNativeControlMetadata(8388608)
        try {
            actualHistoricalServiceFrame173e(f);let before=historyActionCounts173e(f.database)
            f.database.execute("CREATE TRIGGER historyAmplifier173e AFTER INSERT ON audit_events "+
                "WHEN NEW.thread_id='amplified-history-fork173e' AND NEW.kind='completed_initiator_cell173e_v1:initial.provenance:text' "+
                "BEGIN UPDATE audit_events SET payload=hex(zeroblob(8388608)) WHERE id=NEW.id; END")
            let target=SessionId("amplified-history-fork173e")
            let result=f.product.forkSession(f.session,target);@Expect(result.isError())
            let marker=result.error().getOrThrow();@Expect(session.hasOwnedCheckpointFailure113(marker))
            @Expect(!session.admitOwnedCheckpointFailure113(marker,{value=>
                let consumer=match(value){case OwnedAgentRunResult113.Pending(actual)=>actual
                    case _=>throw IllegalStateException("historical copy error must not invent a new canonical Run")}
                capture.consumer=Some(consumer)
                @Expect(consumer.withError({error,_=>
                    @Expect(error.kind,AgentErrorKind.Conflict);@Expect(error.code,"thread.seed_failed")
                    @Expect(error.message,"completed initiator evidence changed during its actual INSERT")
                    @Expect(error.fields.size,1);@Expect(error.fields[0].name,"thread_id")
                    @Expect(error.fields[0].value,target.value);@Expect(!error.retryable && !error.fallbackAllowed)
                    @Expect(error.attemptFailure.isNone() && error.observation.isNone())
                    @Expect(consumer.acknowledgeAfterConsumption().isError())
                }).isOk());false}))
            @Expect(!capture.consumer.getOrThrow().isAcknowledged())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='amplified-history-fork173e'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='amplified-history-fork173e'"),0)
            historyNoReplay173e(f.database,before)
            @Expect(session.admitOwnedCheckpointFailure113(marker,{value=>
                let actual=match(value){case OwnedAgentRunResult113.Pending(consumer)=>consumer
                    case _=>throw IllegalStateException("no second failure Run")}
                @Expect(refEq(actual,capture.consumer.getOrThrow()));true}))
            @Expect(capture.consumer.getOrThrow().acknowledgeAfterConsumption().isOk())
            capture.consumer=None<OwnedFailureDataConsumer113>;session.collectOwnedCheckpointFailure113()
            @Expect(!session.hasOwnedCheckpointFailure113(marker))
        }finally{
            match(capture.consumer){case Some(value)=>let _=value.acknowledgeAfterConsumption();case None=>()}
            capture.consumer=None<OwnedFailureDataConsumer113>;session.collectOwnedCheckpointFailure113();oracle.close();f.close()
        }
    }
}

// Actual installed selected Native compaction, genuine operator DATA grants.
// This fixture only configures the existing mount; it never fabricates Source,
// Operation, Receipt, parent admission or child completion.
private func installHistoricalCompaction173f(product: ProductRuntime,settings: String): Unit {
    let record=match(product.importLocalPlugin(getVariable("AXYNDRA_COMPACTION_PLUGIN_PACKAGE").getOrThrow())){
        case PluginRegistryResult.Ok(value)=>value
        case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
    let digest=productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
    let ns=productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))
    @Expect(product.setPluginEnabled(ns,true).isOk())
    if(!exists(Path(settings+"/plugins"))){Directory.create(settings+"/plugins",recursive:true)}
    File.writeTo(settings+"/plugins/policies.json",encodeAgentValue(objectValue([
        ValueField("version",integerValue(1)),ValueField("bindings",objectValue([ValueField("compaction",objectValue([
            ValueField("namespace",textValue(ns)),ValueField("provider",textValue("summarize")),
            ValueField("package_digest",textValue(digest))]))]))])).toArray())
    File.writeTo(settings+"/plugins/canonical-data.json",encodeAgentValue(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(ns)),ValueField("package_digest",textValue(digest)),
            ValueField("tools",listValue([completedHistoryCheckpointGrant173e("checkpoint"),
                completedHistoryCheckpointGrant173e("rewind")]))])]))])).toArray())
    @Expect(product.setPluginEnabled(ns,false).isOk());@Expect(product.setPluginEnabled(ns,true).isOk())
}

private func actualHistoricalExternalFrame173f(f: CompactionPolicyFixture): ExternalIngressConnection {
    let probe=ExternalProductProbe(false)
    let call=ToolCall("external-history173f","fixture_external173f",objectValue([
        ValueField("principal",textValue("untrusted-body-principal")),ValueField("text",textValue("外部\u{0}history"))]))
    let descriptor=ToolDescriptor(ModelToolDefinition(call.name,"Actual external historical DATA",
        objectValue([ValueField("type",textValue("object"))])),Capability(CapabilityKind.WorkspaceWrite),
        sideEffecting:true,neverReplay:true,implementationVersion:"external-history173f-v1")
    @Expect(f.product.registerTool(descriptor,probe).isOk())
    let context=ToolInvocationContext(RunId("export-snapshot173f"),f.session,
        CapabilitySet(values:[Capability(CapabilityKind.WorkspaceWrite)]),toolContext:productToolContext(f.root))
    let plan=normalizedToolOperationPlan(context,call,descriptor.resolved(call))
    let binding=ExternalIngressBinding("historical-external-grant173f","historical-external-connection173f",
        "authenticated-principal173f",1,ThreadId(f.session.value),externalInvocationAuthorityScope(context),
        [ExternalExportBinding(call.name,plan.implementation.toolVersion,plan.implementation.implementationFingerprint,
            plan.implementation.schemaDigest)],context.capabilities.values,agentUtcMillis()+600000,[])
    let connection=openExternalIngressConnection(ExternalProductAuthorizer(binding),{=>agentUtcMillis()}).value().getOrThrow()
    probe.connection=Some(connection)
    try{
        let result=f.product.vnext.executeExternalTool(connection,ExternalRequestId(ExternalRequestIdKind.Text,
            value:"external-historical-request173f"),call,approvalDecision:Some(ApprovalDecision.Approve),
            budget:ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1))
        match(result){case Result.Ok(ToolInvocationResult.Completed(actual))=>
            try{@Expect(!actual.isError);@Expect(probe.calls,1)}finally{actual.releasePayload()}
            case Result.Err(error)=>throw IllegalStateException(error.describe())
            case _=>throw IllegalStateException("external historical control requires actual canonical completion")}
        connection
    }catch(error:Exception){connection.revoke();throw error}
}

private func actualHistoricalManagedFrame173f(f: ShellServiceProductFixture,label: String): SessionId {
    installHistoricalCompaction173f(f.product,f.files.settings)
    let start=managedCompleted(f.start(label))
    try{@Expect(!start.isError)}finally{start.releasePayload()}
    let result=shellManagedLaunch(f,label,"managed-history-call173f","printf 'managed-history-结果'")
    try{
        @Expect(!result.isError);@Expect(lifecycleText(result.output,"schema"),"axyndra.managed-job-started/v1")
        let id=lifecycleText(result.output,"job_id");let run=lifecycleText(result.output,"run_id")
        let child=SessionId(lifecycleText(result.output,"thread_id"))
        let completed=shellManagedWait(f,label,id)
        @Expect(completed.status,"completed");@Expect(!completed.executing)
        @Expect(shellManagedRunState(f,run),"completed");@Expect(shellManagedRootReceipt(f,run),"completed")
        @Expect(lifecycleText(completed.result.getOrThrow().field("result").getOrThrow(),"stdout"),"managed-history-结果")
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "WHERE o.run_id="+sqliteText(run))>0)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items i JOIN operation_effect_records e ON e.reserved_result_item_id=i.id "+
            "JOIN derived_operation_admissions a ON a.operation_id=e.operation_id JOIN operations o ON o.id=a.operation_id "+
            "WHERE o.run_id="+sqliteText(run)),0)
        child
    }finally{result.releasePayload()}
}

private func actualHistoricalManagedClose173f(product: ProductRuntime): Unit {
    // Exact original Shell fixture cleanup bound, actual close/ACK each time.
    let deadline=MonoTime.now()+Duration.second*10
    while(MonoTime.now()<deadline){
        if(product.close().isOk()){return}
        sleep(Duration.millisecond*10)
    }
    throw IllegalStateException("historical managed service has no actual cleanup acknowledgement")
}

private func actualDerivedEvidenceOracle173f(db: SqliteDatabase,source: SessionId,target: SessionId): Unit {
    let run=db.query("SELECT id FROM runs WHERE thread_id=?",[SqlParameter.Text(source.value)])
    @Expect(run.size,1)
    let ops=db.query("SELECT rowid FROM operations WHERE run_id=? ORDER BY rowid",[SqlParameter.Text(run[0].required(0))])
    var derived: Int64=0
    for(at in 0..ops.size){
        let edge=db.query("SELECT a.operation_id,a.parent_operation_id,a.call_sequence,a.request_key,a.request_digest,"+
            "a.child_call_id,a.root_operation_id,a.depth FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "WHERE o.rowid=?",[SqlParameter.Int64Value(Int64.parse(ops[at].required(0)))])
        if(edge.size==1){
            derived++
            let columns=["operation_id","parent_operation_id","call_sequence","request_key","request_digest",
                "child_call_id","root_operation_id","depth"]
            for(column in 0..columns.size){
                let kind=if(columns[column]=="call_sequence" || columns[column]=="depth"){"integer"}else{"text"}
                let copied=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND kind=?",
                    [SqlParameter.Text(target.value),SqlParameter.Text("completed_initiator_cell173e_v1:operation."+
                        at.toString()+".admission."+columns[column]+":"+kind)])
                @Expect(copied.size,1);@Expect(copied[0].required(0),edge[0].required(column))
            }
        }else{@Expect(edge.size,0)}
    }
    @Expect(derived>0)
    @Expect(db.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
        "WHERE o.run_id IN(SELECT id FROM runs WHERE thread_id="+sqliteText(target.value)+")"),0)
}

@Test
class InstalledCompletedRichHistory173fTests {
    @TestCase
    func actualExternalRevokedConnectionForkDiscardReopenKeepsFullOriginWithoutExecution173f(): Unit {
        let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
        let oracle=reserveNativeControlMetadata(8388608)
        try{
            let connection=actualHistoricalExternalFrame173f(f)
            connection.revoke()
            let original=SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            @Expect(original.items[0].kind,ItemKind.SystemNote);@Expect(original.items[0].provenance.source,"external")
            @Expect(match(original.items[0].provenance.directOrigin.getOrThrow()){
                case DirectCallOrigin.External(value)=>value.principalId=="authenticated-principal173f";case _=>false})
            let before=historyActionCounts173e(f.database);let target=SessionId("external-fork173f")
            @Expect(f.product.forkSession(f.session,target).isOk())
            actualHistoricalSeedOracle173e(f.database,original,target);historyNoReplay173e(f.database,before)
            @Expect(lifecycleTestRequire(f.product.removeConversation(f.session)))
            let afterDiscard=historyActionCounts173e(f.database)
            @Expect(f.product.close().isOk())
            let reopened=lifecycleTestRequire(openProduct(config:ProductConfig(workspaceRoot:f.root,settingsRoot:f.root+"/settings",
                stateRoot:f.root+"/state",fixture:true,asyncEnabled:false)))
            try{
                let loaded=SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
                let next=SessionId("external-reopened-fork173f")
                @Expect(reopened.forkSession(target,next).isOk())
                actualHistoricalSeedOracle173e(f.database,loaded,next);historyNoReplay173e(f.database,afterDiscard)
            }finally{let _=reopened.close()}
        }finally{oracle.close();f.close()}
    }
    @TestCase
    func actualManagedSettledDerivedReceiptsFreezeAllAdmissionCellsAndReopenNoReplay173f(): Unit {
        let f=ShellServiceProductFixture(asyncEnabled:true)
        let oracle=reserveNativeControlMetadata(8388608)
        try{
            let source=actualHistoricalManagedFrame173f(f,"managed-parent173f")
            let original=SqliteThreadCommitSink(f.database).loadThread(ThreadId(source.value))
            @Expect(original.items[0].kind,ItemKind.SystemNote);@Expect(original.items[0].provenance.source,"managed_job")
            let before=historyActionCounts173e(f.database);let target=SessionId("managed-fork173f")
            @Expect(f.product.forkSession(source,target).isOk())
            actualHistoricalSeedOracle173e(f.database,original,target)
            actualDerivedEvidenceOracle173f(f.database,source,target);historyNoReplay173e(f.database,before)
            let loaded=SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
            @Expect(lifecycleTestRequire(f.product.removeConversation(source)))
            let afterDiscard=historyActionCounts173e(f.database)
            // Child producer and real service cleanup have returned before the
            // native fixture closes. Historical target keeps only paid DATA.
            actualHistoricalManagedClose173f(f.product)
            let reopened=lifecycleTestRequire(openProduct(config:ProductConfig(workspaceRoot:f.files.workspace,
                settingsRoot:f.files.settings,stateRoot:f.files.root+"/state",fixture:true,asyncEnabled:true)))
            try{
                let next=SessionId("managed-reopened-fork173f")
                @Expect(reopened.forkSession(target,next).isOk())
                actualHistoricalSeedOracle173e(f.database,loaded,next);historyNoReplay173e(f.database,afterDiscard)
            }finally{let _=reopened.close()}
        }finally{oracle.close();f.close()}
    }
    @TestCase
    func actualKnownParentCannotWashUnknownChildOrAmplifiedAdmissionCopyAndPreciseAck173f(): Unit {
        for(mode in ["unknown","amplified"]){
            let f=ShellServiceProductFixture(asyncEnabled:true);let oracle=reserveNativeControlMetadata(8388608)
            let capture=HistoricalErrorCapture173e()
            try{
                let source=actualHistoricalManagedFrame173f(f,"managed-negative173f")
                let session=f.product.applicationSession(sessionId:Some(source))
                let child=f.database.query("SELECT a.operation_id FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                    "WHERE o.run_id IN(SELECT id FROM runs WHERE thread_id=?) ORDER BY o.rowid LIMIT 1",[SqlParameter.Text(source.value)])
                @Expect(child.size,1)
                let target=SessionId("managed-negative-fork173f")
                let action=if(mode=="unknown"){
                    "UPDATE operation_receipts SET outcome='unknown' WHERE operation_id="+sqliteText(child[0].required(0))+";"}
                else{"UPDATE audit_events SET payload=hex(zeroblob(8388608)) WHERE id=NEW.id;"}
                let predicate=if(mode=="unknown"){
                    "NEW.kind='completed_initiator_cell173e_v1:audit.0.kind:text'"}
                else{"NEW.kind LIKE 'completed_initiator_cell173e_v1:operation.%.admission.operation_id:text'"}
                f.database.execute("CREATE TRIGGER derivedHistoryTamper173f AFTER INSERT ON audit_events "+
                    "WHEN NEW.thread_id='managed-negative-fork173f' AND "+predicate+" "+
                    "BEGIN "+action+" END")
                let before=historyActionCounts173e(f.database)
                let result=f.product.forkSession(source,target);@Expect(result.isError())
                let marker=result.error().getOrThrow();@Expect(session.hasOwnedCheckpointFailure113(marker))
                @Expect(!session.admitOwnedCheckpointFailure113(marker,{value=>
                    let actual=match(value){case OwnedAgentRunResult113.Pending(consumer)=>consumer
                        case _=>throw IllegalStateException("historical failure cannot create another Run")}
                    capture.consumer=Some(actual)
                    @Expect(actual.withError({error,_=>
                        @Expect(error.kind,AgentErrorKind.Conflict);@Expect(error.code,"thread.seed_failed")
                        @Expect(error.message,if(mode=="unknown"){
                            "completed initiator has unsettled, Unknown or unbound canonical Operation/Receipt"}
                            else{"completed initiator evidence changed during its actual INSERT"})
                        @Expect(error.fields.size,1);@Expect(error.fields[0].name,"thread_id");@Expect(error.fields[0].value,target.value)
                        @Expect(!error.retryable && !error.fallbackAllowed)
                        @Expect(error.attemptFailure.isNone() && error.observation.isNone())
                        @Expect(actual.acknowledgeAfterConsumption().isError())}).isOk());false}))
                @Expect(!capture.consumer.getOrThrow().isAcknowledged())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='managed-negative-fork173f'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='managed-negative-fork173f'"),0)
                historyNoReplay173e(f.database,before)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id="+
                    sqliteText(child[0].required(0))+" AND outcome='completed'"),1)
                @Expect(session.admitOwnedCheckpointFailure113(marker,{value=>
                    let actual=match(value){case OwnedAgentRunResult113.Pending(consumer)=>consumer
                        case _=>throw IllegalStateException("no replacement failure Run")}
                    @Expect(refEq(actual,capture.consumer.getOrThrow()));true}))
                @Expect(capture.consumer.getOrThrow().acknowledgeAfterConsumption().isOk())
                capture.consumer=None<OwnedFailureDataConsumer113>;session.collectOwnedCheckpointFailure113()
                @Expect(!session.hasOwnedCheckpointFailure113(marker))
            }finally{
                match(capture.consumer){case Some(value)=>let _=value.acknowledgeAfterConsumption();case None=>()}
                capture.consumer=None<OwnedFailureDataConsumer113>;oracle.close();f.close()
            }
        }
    }
}
