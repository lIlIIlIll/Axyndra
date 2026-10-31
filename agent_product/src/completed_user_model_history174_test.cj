package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.reserveNativeControlMetadata
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func userModelScalar174(db: SqliteDatabase,sql: String): Int64 {
    userModelScalar174(db,sql,[])
}
private func userModelScalar174(db: SqliteDatabase,sql: String,args: Array<SqlParameter>): Int64 {
    let rows=db.query(sql,args);@Expect(rows.size,1);Int64.parse(rows[0].required(0))
}
private func userModelItemsDigest174(db: SqliteDatabase,source: SessionId): String {
    var digest=modelPolicySha256Text("axyndra.original-user-model-items/v1")
    for(row in db.query("SELECT id,payload,provenance FROM items WHERE thread_id=? ORDER BY ordinal",[SqlParameter.Text(source.value)])){
        for(at in 0..3){digest=modelPolicySha256Text(digest+":"+modelPolicySha256Text(row.required(at)))}
    };digest
}
private func actualUserModelCheckpoint174(f: CompactionPolicyFixture): Unit {
    let session=f.product.applicationSession(sessionId:Some(f.session))
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("user-checkpoint174","plugin.axyndra:compaction.checkpoint",
        objectValue([ValueField("goal",textValue("Original user/model goal 雪\u{0}"))]))
    @Expect(session.submit("Produce the genuine user/model checkpoint.").isOk())
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("user-rewind174","plugin.axyndra:compaction.rewind",
        objectValue([ValueField("report",textValue("Original report 🙂\u{0}"))]))
    @Expect(session.submit("Complete the genuine user/model rewind.").isOk())
    @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),2)
    @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
    @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM model_attempts WHERE transcript_snapshot<>''")>0)
    @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM model_decisions")>0)
    @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM runs WHERE state='completed'")>=2)
}
private func userModelActionCounts174(db: SqliteDatabase): Array<Int64> {
    [userModelScalar174(db,"SELECT COUNT(*) FROM operations"),userModelScalar174(db,"SELECT COUNT(*) FROM operation_receipts"),
        userModelScalar174(db,"SELECT COUNT(*) FROM model_attempts"),userModelScalar174(db,"SELECT COUNT(*) FROM model_decisions"),
        userModelScalar174(db,"SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")]
}
private func userModelNoReplay174(db: SqliteDatabase,before: Array<Int64>): Unit {
    let after=userModelActionCounts174(db)
    @Expect(after.size,before.size)
    for(at in 0..before.size){@Expect(after[at],before[at])}
}
// The original clone is the independent oracle: no new User provenance,
// business Run, operation, receipt or checkpoint authority is constructed.
private func userModelOriginalSeedOracle174(db: SqliteDatabase,expected: AgentThreadSnapshot,actual: AgentThreadSnapshot): Unit {
    @Expect(actual.thread.id.value,expected.thread.id.value)
    @Expect(actual.thread.workspaceId,expected.thread.workspaceId)
    @Expect(actual.thread.revision,expected.thread.revision)
    @Expect(actual.thread.nextItemOrdinal,expected.thread.nextItemOrdinal)
    @Expect(actual.thread.status,expected.thread.status)
    @Expect(actual.thread.activeTurnId.isNone() && actual.activeRunId.isNone())
    @Expect(actual.activeEpoch,expected.activeEpoch)
    @Expect(actual.turns.size,expected.turns.size);@Expect(actual.items.size,expected.items.size)
    for(at in 0..expected.turns.size){
        let old=expected.turns[at];let copied=actual.turns[at]
        @Expect(copied.id.value,old.id.value);@Expect(copied.ordinal,old.ordinal)
        @Expect(copied.userItemId.value,old.userItemId.value);@Expect(copied.state,old.state)
        @Expect(copied.activeRunId.isNone())
    }
    for(at in 0..expected.items.size){
        let old=expected.items[at];let copied=actual.items[at]
        @Expect(copied.id.value,old.id.value);@Expect(copied.turnId.value,old.turnId.value)
        @Expect(copied.ordinal,old.ordinal);@Expect(copied.kind,old.kind)
        @Expect(encodeStoredThreadContent(copied.content),encodeStoredThreadContent(old.content))
        @Expect(encodeStoredProvenance(copied.provenance),encodeStoredProvenance(old.provenance))
        @Expect(copied.createdAtMillis,old.createdAtMillis)
    }
    @Expect(userModelScalar174(db,"SELECT COUNT(*) FROM runs WHERE thread_id="+sqliteText(actual.thread.id.value)+
        " AND state='completed' AND cancellation_reason IS NULL"),actual.turns.size)
}
// Full bytes of every ACTUAL column of these independently selected original
// business tables, including transcript_snapshot, receipt detail/verification,
// errors, usage and persisted continuation/journal data. Not a digest-only
// assertion and not a synthetic seed Run substituted for the original Run.
private func userModelTableCells174(db: SqliteDatabase,history: CompletedUserModelHistory174,target: SessionId,
    copied: ThreadItem,table: String,suffix: String,args: Array<SqlParameter>): Unit {
    let count=userModelScalar174(db,"SELECT COUNT(*)"+suffix,args)
    let size=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND operation_id=? AND kind=?",
        [SqlParameter.Text(target.value),SqlParameter.Text(copied.id.value),
            SqlParameter.Text("completed_user_model_cell174_v1:"+table+".rows:integer")])
    @Expect(size.size,1);@Expect(size[0].required(0),count.toString())
    let fields=db.query("SELECT name FROM pragma_table_info(?) ORDER BY cid",[SqlParameter.Text(table)])
    let columns=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND operation_id=? AND kind=?",
        [SqlParameter.Text(target.value),SqlParameter.Text(copied.id.value),
            SqlParameter.Text("completed_user_model_cell174_v1:"+table+".columns:integer")])
    @Expect(columns.size,1);@Expect(columns[0].required(0),fields.size.toString())
    for(at in 0..count){
        let selected=Array<SqlParameter>(args.size+1,{i=>if(i<args.size){args[i]}else{SqlParameter.Int64Value(at)}})
        for(field in fields){
            let name=field.required(0)
            let actual=db.query("SELECT typeof("+name+"),CAST(COALESCE("+name+",'') AS TEXT)"+suffix+
                " ORDER BY rowid LIMIT 1 OFFSET ?",selected)
            @Expect(actual.size,1)
            let cell=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND operation_id=? AND kind=?",
                [SqlParameter.Text(target.value),SqlParameter.Text(copied.id.value),SqlParameter.Text(
                    "completed_user_model_cell174_v1:"+table+"."+at.toString()+"."+name+":"+actual[0].required(0))])
            @Expect(cell.size,1);@Expect(cell[0].required(0),actual[0].required(1))
        }
    }
    @Expect(history.evidenceCells>0)
}
private func userModelAuditOriginal174(db: SqliteDatabase,original: AgentThreadSnapshot,target: SessionId): Unit {
    let copied=SqliteThreadCommitSink(db).loadThread(ThreadId(target.value))
    var users: Int64=0
    for(old in original.items where old.kind==ItemKind.UserMessage && old.provenance.source=="user"){
        users++
        @Expect(old.provenance.runId.isNone())
        let item=copied.items[old.ordinal-1]
        @Expect(item.provenance.source,"fork")
        let head=db.query("SELECT payload,run_id,commit_sequence FROM audit_events WHERE thread_id=? AND operation_id=? AND kind='completed_user_model_history174_v1'",
            [SqlParameter.Text(target.value),SqlParameter.Text(item.id.value)])
        @Expect(head.size,1);@Expect(head[0].required(1),item.provenance.runId.getOrThrow().value)
        @Expect(head[0].required(2),"0")
        let history=completedUserModelHistoryFromValue174(decodeStoredValue(head[0].required(0)))
        @Expect(history.threadId,old.threadId.value);@Expect(history.turnId,old.turnId.value)
        @Expect(history.itemId,old.id.value)
        @Expect(history.originDigest,modelPolicySha256Text(encodeStoredProvenance(old.provenance)))
        let args=[SqlParameter.Text(old.threadId.value),SqlParameter.Text(old.turnId.value)]
        @Expect(history.runCount,userModelScalar174(db,"SELECT COUNT(*) FROM runs WHERE thread_id=? AND turn_id=?",args))
        @Expect(history.latestEpoch,userModelScalar174(db,"SELECT MAX(epoch) FROM runs WHERE thread_id=? AND turn_id=?",args))
        @Expect(userModelScalar174(db,"SELECT COUNT(*) FROM runs WHERE thread_id=? AND turn_id=? AND id=? AND epoch=?",
            [args[0],args[1],SqlParameter.Text(history.runId),SqlParameter.Int64Value(history.latestEpoch)]),1)
        let state=db.query("SELECT state FROM turns WHERE thread_id=? AND id=?",args)
        @Expect(state.size,1);@Expect(history.turnState,state[0].required(0))
        @Expect(userModelScalar174(db,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND operation_id=? AND substr(kind,1,32)='completed_user_model_cell174_v1:'",
            [SqlParameter.Text(target.value),SqlParameter.Text(item.id.value)]),history.evidenceCells)
        userModelTableCells174(db,history,target,item,"items"," FROM items WHERE thread_id=? AND turn_id=?",args)
        userModelTableCells174(db,history,target,item,"turns"," FROM turns WHERE thread_id=? AND id=?",args)
        userModelTableCells174(db,history,target,item,"runs"," FROM runs WHERE thread_id=? AND turn_id=?",args)
        let runs="SELECT id FROM runs WHERE thread_id=? AND turn_id=?"
        for(table in ["model_attempts","operations","run_model_usage","run_journal","app_run_events",
            "app_run_event_heads","run_continuations","run_continuation_facts","step_records","run_composition_bindings"]){
            userModelTableCells174(db,history,target,item,table," FROM "+table+" WHERE run_id IN ("+runs+")",args)
        }
        userModelTableCells174(db,history,target,item,"model_decisions",
            " FROM model_decisions WHERE attempt_id IN (SELECT id FROM model_attempts WHERE run_id IN ("+runs+"))",args)
        for(table in ["operation_receipts","operation_effect_records","operation_state_registers"]){
            userModelTableCells174(db,history,target,item,table,
                " FROM "+table+" WHERE operation_id IN (SELECT id FROM operations WHERE run_id IN ("+runs+"))",args)
        }
    }
    @Expect(users>0)
    @Expect(userModelScalar174(db,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND kind='completed_user_model_history174_v1'",
        [SqlParameter.Text(target.value)]),users)
    @Expect(userModelScalar174(db,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND kind='completed_user_model_ledger174_v1'",
        [SqlParameter.Text(target.value)]),users)
}
private func userModelAuditAgain174(db: SqliteDatabase,source: SessionId,target: SessionId): Unit {
    let old=SqliteThreadCommitSink(db).loadThread(ThreadId(source.value))
    let copied=SqliteThreadCommitSink(db).loadThread(ThreadId(target.value))
    for(item in old.items where item.kind==ItemKind.UserMessage){
        let actual=copied.items[item.ordinal-1]
        for(kind in ["completed_user_model_history174_v1","completed_user_model_ledger174_v1"]){
            let before=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND operation_id=? AND kind=?",
                [SqlParameter.Text(source.value),SqlParameter.Text(item.id.value),SqlParameter.Text(kind)])
            let after=db.query("SELECT payload FROM audit_events WHERE thread_id=? AND operation_id=? AND kind=?",
                [SqlParameter.Text(target.value),SqlParameter.Text(actual.id.value),SqlParameter.Text(kind)])
            @Expect(before.size,1);@Expect(after.size,1);@Expect(after[0].required(0),before[0].required(0))
        }
        let before=db.query("SELECT kind,payload,commit_sequence FROM audit_events WHERE thread_id=? AND operation_id=? "+
            "AND substr(kind,1,32)='completed_user_model_cell174_v1:' ORDER BY commit_sequence",
            [SqlParameter.Text(source.value),SqlParameter.Text(item.id.value)])
        let after=db.query("SELECT kind,payload,commit_sequence FROM audit_events WHERE thread_id=? AND operation_id=? "+
            "AND substr(kind,1,32)='completed_user_model_cell174_v1:' ORDER BY commit_sequence",
            [SqlParameter.Text(target.value),SqlParameter.Text(actual.id.value)])
        @Expect(before.size>0);@Expect(after.size,before.size)
        for(at in 0..before.size){for(field in 0..3){@Expect(after[at].required(field),before[at].required(field))}}
    }
}
class UserModelErrorCapture174 {var consumer:?OwnedFailureDataConsumer113=None<OwnedFailureDataConsumer113>}
private func userModelConsumeActualError174(session: ApplicationSession,result: Result<Unit>,
    source: SessionId,target: SessionId,code: String,kind: AgentErrorKind): Unit {
    @Expect(result.isError())
    let marker=result.error().getOrThrow();let capture=UserModelErrorCapture174()
    @Expect(session.hasOwnedCheckpointFailure113(marker))
    @Expect(!session.admitOwnedCheckpointFailure113(marker,{value=>
        let actual=match(value){case OwnedAgentRunResult113.Pending(error)=>error
            case _=>throw IllegalStateException("copy failure must not fabricate another business Run")}
        capture.consumer=Some(actual)
        @Expect(actual.withError({error,_=>
            @Expect(error.kind,kind);@Expect(error.code,code);@Expect(error.message!="")
            @Expect(!error.retryable && !error.fallbackAllowed)
            if(code=="thread.seed_failed"){@Expect(error.fields.size,1);@Expect(error.fields[0].name,"thread_id");@Expect(error.fields[0].value,target.value)}
            else if(code=="product.thread_fork_invalid"){
                @Expect(error.fields.size,2);@Expect(error.fields[0].name,"source_thread_id");@Expect(error.fields[0].value,source.value)
                @Expect(error.fields[1].name,"target_thread_id");@Expect(error.fields[1].value,target.value)
            }else{@Expect(error.fields.size,0)}
            @Expect(error.attemptFailure.isNone() && error.observation.isNone())
            @Expect(actual.acknowledgeAfterConsumption().isError())
        }).isOk());false
    }))
    @Expect(!capture.consumer.getOrThrow().isAcknowledged())
    @Expect(session.admitOwnedCheckpointFailure113(marker,{value=>
        let actual=match(value){case OwnedAgentRunResult113.Pending(error)=>error
            case _=>throw IllegalStateException("same paid failure must remain in the actual slot")}
        @Expect(refEq(actual,capture.consumer.getOrThrow()));true
    }))
    @Expect(capture.consumer.getOrThrow().acknowledgeAfterConsumption().isOk())
    capture.consumer=None<OwnedFailureDataConsumer113>;session.collectOwnedCheckpointFailure113()
    @Expect(!session.hasOwnedCheckpointFailure113(marker))
}

@Test
class InstalledUserModelHistory174Tests {
    @TestCase
    func actualCoreAllModelCellsKeepOriginalUserForkSeedAndReopenAfterSourceDiscard174(): Unit {
        let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
        let oracle=reserveNativeControlMetadata(4194304)
        try{
            actualUserModelCheckpoint174(f)
            let original=SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            let originalBytes=userModelItemsDigest174(f.database,f.session);let before=userModelActionCounts174(f.database)
            let modelCalls=f.product.fixtureProbe.getOrThrow().observedCallCount11318()
            let target=SessionId("real-user-model-fork174")
            @Expect(f.product.forkSession(f.session,target).isOk())
            @Expect(userModelItemsDigest174(f.database,f.session),originalBytes)
            userModelOriginalSeedOracle174(f.database,completedThreadCloneSnapshot(ThreadId(target.value),f.root,original),
                SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value)))
            userModelAuditOriginal174(f.database,original,target)
            userModelNoReplay174(f.database,before)
            @Expect(f.product.fixtureProbe.getOrThrow().observedCallCount11318(),modelCalls)
            @Expect(lifecycleTestRequire(f.product.removeConversation(f.session)))
            @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM threads WHERE id=?",[SqlParameter.Text(f.session.value)]),0)
            let afterDiscard=userModelActionCounts174(f.database)
            @Expect(f.product.close().isOk())
            let reopened=lifecycleTestRequire(openProduct(config:ProductConfig(workspaceRoot:f.root,
                settingsRoot:f.root+"/settings",stateRoot:f.root+"/state",fixture:true,asyncEnabled:false)))
            try{
                let loaded=SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value))
                let again=SessionId("real-user-model-second-fork174")
                @Expect(reopened.forkSession(target,again).isOk())
                userModelOriginalSeedOracle174(f.database,completedThreadCloneSnapshot(ThreadId(again.value),f.root,loaded),
                    SqliteThreadCommitSink(f.database).loadThread(ThreadId(again.value)))
                userModelAuditAgain174(f.database,target,again);userModelNoReplay174(f.database,afterDiscard)
                @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM model_attempts WHERE run_id IN (SELECT id FROM runs WHERE thread_id=? OR thread_id=?)",
                    [SqlParameter.Text(target.value),SqlParameter.Text(again.value)]),0)
            }finally{let _=reopened.close()}
        }finally{oracle.close();f.close()}
    }
    @TestCase
    func actualCoordinatorFailureAndCancellationRemainOriginalClosedUserData174(): Unit {
        let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
        let oracle=reserveNativeControlMetadata(4194304)
        try{
            for(cancelled in [false,true]){
                let source=SessionId(if(cancelled){"real-user-cancelled174"}else{"real-user-failed174"})
                let sink=SqliteThreadCommitSink(f.database)
                let coordinator=ThreadCoordinator(sink.createThread(ThreadId(source.value),f.root),sink)
                let turn=SemanticTurnId("actual-turn-"+source.value);let run=RunId("actual-run-"+source.value)
                let started=lifecycleTestRequire(coordinator.startTurn(turn,run,ItemId("actual-user-"+source.value),
                    ThreadItemContent.UserMessage([ThreadMessagePart.Text("Original terminal User 雪\u{0}")]),createdAtMillis:41))
                @Expect(started.items[0].provenance.source,"user");@Expect(started.items[0].provenance.runId.isNone())
                if(cancelled){@Expect(coordinator.cancelRun(run,finishedAtMillis:Some(42),cancellationReason:Some("actual user cancel")).isOk())}
                else{@Expect(coordinator.failTurn(turn,run,started.activeEpoch,finishedAtMillis:Some(42)).isOk())}
                let original=SqliteThreadCommitSink(f.database).loadThread(ThreadId(source.value))
                @Expect(original.turns[0].state,if(cancelled){TurnState.Cancelled}else{TurnState.Failed})
                let before=userModelActionCounts174(f.database);let target=SessionId("fork-"+source.value)
                @Expect(f.product.forkSession(source,target).isOk())
                userModelOriginalSeedOracle174(f.database,completedThreadCloneSnapshot(ThreadId(target.value),f.root,original),
                    SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value)))
                userModelAuditOriginal174(f.database,original,target);userModelNoReplay174(f.database,before)
            }
        }finally{oracle.close();f.close()}
    }
    @TestCase
    func actualPresentUserLedgerMissingDuplicateChangedOrForeignEvidenceNeverFallsBack174(): Unit {
        for(change in ["header","cell","group","duplicate","changed","thread","turn","run","user"]){
            let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
            let oracle=reserveNativeControlMetadata(4194304)
            try{
                actualUserModelCheckpoint174(f)
                let source=SessionId("corrupt-user-model-source174");let target=SessionId("corrupt-user-model-target174")
                @Expect(f.product.forkSession(f.session,source).isOk())
                let session=f.product.applicationSession(sessionId:Some(source))
                let args=[SqlParameter.Text(source.value)]
                let heads=f.database.query("SELECT id,payload,operation_id FROM audit_events WHERE thread_id=? AND kind='completed_user_model_history174_v1' ORDER BY id",args)
                @Expect(heads.size>0);let head=heads[0];let id=Int64.parse(head.required(0));let item=head.required(2)
                if(change=="header"){f.database.execute("DELETE FROM audit_events WHERE id=?",[SqlParameter.Int64Value(id)])}
                else if(change=="cell"){f.database.execute("DELETE FROM audit_events WHERE id=(SELECT MIN(id) FROM audit_events WHERE thread_id=? AND operation_id=? AND substr(kind,1,32)='completed_user_model_cell174_v1:')",[args[0],SqlParameter.Text(item)])}
                else if(change=="group"){f.database.execute("DELETE FROM audit_events WHERE thread_id=? AND operation_id=? AND kind<>'completed_user_model_ledger174_v1'",[args[0],SqlParameter.Text(item)])}
                else if(change=="duplicate"){f.database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) SELECT thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence FROM audit_events WHERE id=?",[SqlParameter.Int64Value(id)])}
                else if(change=="changed"){f.database.execute("UPDATE audit_events SET payload=payload||'changed' WHERE id=(SELECT MIN(id) FROM audit_events WHERE thread_id=? AND operation_id=? AND substr(kind,1,32)='completed_user_model_cell174_v1:')",[args[0],SqlParameter.Text(item)])}
                else{
                    let old=completedUserModelHistoryFromValue174(decodeStoredValue(head.required(1)))
                    let altered=CompletedUserModelHistory174(if(change=="thread"){"other-original-thread"}else{old.threadId},
                        if(change=="turn"){"other-original-turn"}else{old.turnId},if(change=="run"){"other-original-run"}else{old.runId},
                        if(change=="user"){"other-original-user"}else{old.itemId},old.turnState,old.latestEpoch,old.runCount,
                        old.originDigest,old.evidenceDigest,old.evidenceCells)
                    let encoded=encodeStoredValue(completedUserModelHistoryValue174(altered))
                    f.database.execute("UPDATE audit_events SET payload=? WHERE id=?",[SqlParameter.Text(encoded),SqlParameter.Int64Value(id)])
                    // Rebinding only the independent header digest still cannot
                    // change its complete original Item/Turn/Run cross-binding.
                    f.database.execute("UPDATE audit_events SET payload=? WHERE thread_id=? AND operation_id=? AND kind='completed_user_model_ledger174_v1'",
                        [SqlParameter.Text(modelPolicySha256Text(encoded)),args[0],SqlParameter.Text(item)])
                }
                let before=userModelActionCounts174(f.database)
                let result=f.product.forkSession(source,target)
                userModelConsumeActualError174(session,result,source,target,"product.thread_fork_invalid",AgentErrorKind.Conflict)
                @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM threads WHERE id=?",[SqlParameter.Text(target.value)]),0)
                @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM audit_events WHERE thread_id=?",[SqlParameter.Text(target.value)]),0)
                userModelNoReplay174(f.database,before)
            }finally{oracle.close();f.close()}
        }
    }
    @TestCase
    func actualCheckpointTriggerChangingOnlyOriginalModelTranscriptRollsBackFullCopy174(): Unit {
        let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
        let oracle=reserveNativeControlMetadata(4194304)
        try{
            actualUserModelCheckpoint174(f)
            let session=f.product.applicationSession(sessionId:Some(f.session));let target=SessionId("trigger-user-model-fork174")
            let original=userModelItemsDigest174(f.database,f.session);let before=userModelActionCounts174(f.database)
            let transcript=f.database.query("SELECT id,transcript_snapshot FROM model_attempts ORDER BY id")
            @Expect(transcript.size>0)
            f.database.execute("CREATE TRIGGER originalModelMutation174 AFTER INSERT ON context_checkpoints WHEN NEW.thread_id='trigger-user-model-fork174' BEGIN "+
                "UPDATE model_attempts SET transcript_snapshot=transcript_snapshot||'changed-original-transcript' WHERE id="+sqliteText(transcript[0].required(0))+"; END")
            let result=f.product.forkSession(f.session,target)
            userModelConsumeActualError174(session,result,f.session,target,"context.checkpoint_commit_failed",AgentErrorKind.RecoveryRequired)
            @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM threads WHERE id=?",[SqlParameter.Text(target.value)]),0)
            @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM audit_events WHERE thread_id=?",[SqlParameter.Text(target.value)]),0)
            @Expect(userModelItemsDigest174(f.database,f.session),original);userModelNoReplay174(f.database,before)
            let after=f.database.query("SELECT id,transcript_snapshot FROM model_attempts ORDER BY id")
            @Expect(after.size,transcript.size)
            for(at in 0..transcript.size){@Expect(after[at].required(0),transcript[at].required(0));@Expect(after[at].required(1),transcript[at].required(1))}
            f.database.execute("DROP TRIGGER originalModelMutation174")
        }finally{oracle.close();f.close()}
    }
    @TestCase
    func originalUserOnlyLegacySeedKeepsOldWholeForkAndCreatesNoInventedHistory174(): Unit {
        let f=CompactionPolicyFixture(hybrid:false,seedDefaultHistory:false)
        let oracle=reserveNativeControlMetadata(4194304)
        try{
            @Expect(f.product.replaceMessages(f.session,[ModelMessage(ModelRole.User,[ModelBlock(ModelBlockKind.Text,text:"Original legacy User 雪\u{0}")])]).isOk())
            let original=SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            let target=SessionId("legacy-user-fork174");let before=userModelActionCounts174(f.database)
            @Expect(f.product.forkSession(f.session,target).isOk())
            userModelOriginalSeedOracle174(f.database,completedThreadCloneSnapshot(ThreadId(target.value),f.root,original),
                SqliteThreadCommitSink(f.database).loadThread(ThreadId(target.value)))
            @Expect(userModelScalar174(f.database,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND kind IN ('completed_user_model_history174_v1','completed_user_model_ledger174_v1')",
                [SqlParameter.Text(target.value)]),0)
            userModelNoReplay174(f.database,before)
        }finally{oracle.close();f.close()}
    }
}
