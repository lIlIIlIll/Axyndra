package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private class ActualPhysicalErrorState334 {
    var debt:?SqliteLiveMemoryNativeAbortCleanupDebt326=None<SqliteLiveMemoryNativeAbortCleanupDebt326>
    var data:?SqliteLiveMemoryOuterErrorData331=None<SqliteLiveMemoryOuterErrorData331>
    var effects:Int64=0
    var recovery:Int64=0
}
// Real SQLite resource controls. No fake Root/Source, Receipt, installed Host
// or Kernel authority. The borrowed original error never escapes this helper.
private func actualPhysicalErrorInvocation334(db:SqliteDatabase,ancestor:LogicalJsonOwnerReservation,
    frame:PluginLivePolicyOuterErrorFrame334,state:ActualPhysicalErrorState334):Unit{
    try{db.withPaidLiveMemoryNativeAbortRecoveryFrame334(ancestor,65536,Some(frame),{tx=>
        state.effects++
        try{tx.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(1,'duplicate',1,'retain','{}',1)", [])}
        catch(error:Exception){throw LiveMemoryActualSqliteWriteFailure311(error)}
    },{_,_=>state.recovery++})}
    catch(error:LiveMemoryNativeAbortRetainedFailure326){
        let debt=match(error.debt as SqliteLiveMemoryNativeAbortCleanupDebt326){
            case Some(value)=>value;case None=>throw IllegalStateException("actual SQLite debt missing")}
        debt.beginOuterErrorCopy331()
        let data=copyLiveMemoryMappedOuterError331(error.primary,OperationId("actual-physical-334"),ancestor)
        debt.adoptOuterErrorData331(data);state.debt=Some(debt);state.data=Some(data)
    }
}
@Test
class LiveMemoryPhysicalError334Tests {
    @TestCase
    func actualSqliteFrameMustReturnBeforeRollbackAckAndCopiedErrorStaysPaid():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/actual.sqlite")
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        let frame=PluginLivePolicyOuterErrorFrame334.retain(ancestor);let state=ActualPhysicalErrorState334()
        try{
            db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(1,'before',1,'retain','{}',1)")
            frame.invoke<Unit>({actual=>
                actualPhysicalErrorInvocation334(db,ancestor,actual,state)
                @Expect(state.debt.isSome(),true);@Expect(state.data.isSome(),true)
                @Expect(state.debt.getOrThrow().closeAfterFailure().error().getOrThrow().code,"plugin.live_cleanup_frame_pending")
                @Expect(state.debt.getOrThrow().isAcknowledged(),false)
                let refused=try{let _=db.query("SELECT COUNT(*) FROM memory_events");false}catch(_:Exception){true}
                @Expect(refused,true)
            })
            @Expect(state.effects,1);@Expect(state.recovery,0)
            let otherFrame=PluginLivePolicyOuterErrorFrame334.retain(ancestor);otherFrame.invoke<Unit>({_=>()})
            let debt=state.debt.getOrThrow();let data=state.data.getOrThrow()
            @Expect(debt.matchesReturnedErrorFrame334(otherFrame,data),false)
            @Expect(debt.matchesReturnedErrorFrame334(frame,data),true)
            let wrong=copyLiveMemoryMappedOuterError331(IllegalStateException("different"),OperationId("wrong"),ancestor)
            @Expect(debt.matchesReturnedErrorFrame334(frame,wrong),false)
            @Expect(debt.closeAfterFailure().isOk(),true);@Expect(debt.isAcknowledged(),true)
            @Expect(db.query("SELECT COUNT(*) FROM memory_events")[0].required(0),"1")
            let paid=bank.usage();ancestor.close()
            @Expect(bank.usage()[0],paid[0]);@Expect(bank.usage()[1],paid[1])
            @Expect(data.isConsumerRetired(),false);@Expect(data.closeAfterConsumerRetirement().isError(),true)
            @Expect(data.withError({error=>@Expect(error.message.startsWith("SQLite step failed with code 19:"),true)
                @Expect(error.field("operation_id").getOrThrow(),"actual-physical-334");Result<Unit>.Ok(())}).isOk(),true)
        }finally{ancestor.close();db.close();remove(root,recursive:true)}
        @Expect(bank.usage()[0],1)
    }
    @TestCase
    func cleanupCopyPreservesCompleteEightFieldsAndOriginalMutableFieldArrayCannotChangeIt():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        let observation=OperationObservation("{\"source\":\"full\"}")
        let attempt=AttemptFailure(AttemptFailureKind.ProviderTransportError)
        let original=AgentError(AgentErrorKind.RecoveryRequired,"cleanup.complete","complete\u{0000}雪",
            retryable:true,fallbackAllowed:true,fields:[ErrorField("name","original")],
            attemptFailure:Some(attempt),observation:Some(observation))
        let copy=copyLiveMemoryCleanupError334(PluginDocumentGuardFailure(original),ancestor)
        let parent=copyLiveMemoryMappedOuterError331(IllegalStateException("primary"),OperationId("primary"),ancestor)
        parent.retainCleanupData334(copy)
        original.fields[0]=ErrorField("changed","changed")
        @Expect(copy.withError({value=>
            @Expect(value.kind,AgentErrorKind.RecoveryRequired);@Expect(value.code,"cleanup.complete")
            @Expect(value.message,"complete\u{0000}雪");@Expect(value.retryable,true);@Expect(value.fallbackAllowed,true)
            @Expect(value.fields[0].name,"name");@Expect(value.fields[0].value,"original")
            @Expect(refEq(value.attemptFailure.getOrThrow(),attempt),true)
            @Expect(refEq(value.observation.getOrThrow(),observation),true);Result<Unit>.Ok(())}).isOk(),true)
        let paid=bank.usage();ancestor.close();@Expect(bank.usage()[1],paid[1])
        @Expect(copy.isConsumerRetired(),false);@Expect(parent.isConsumerRetired(),false)
    }
    @TestCase
    func cleanupCopyPressureNeverFallsBackToUnpaidMappedMessage():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(16777216)
        let primary=copyLiveMemoryMappedOuterError331(IllegalStateException("primary"),OperationId("primary"),ancestor)
        let pressure=bank.acquire(1);pressure.ensureRetainedPeak(134217728-bank.usage()[1]+16777216)
        let before=bank.usage()
        let refused=try{let _=copyLiveMemoryCleanupError334(IllegalStateException("full cleanup error"),ancestor);false}
            catch(_:Exception){true}
        @Expect(refused,true);@Expect(bank.usage()[0],before[0]);@Expect(bank.usage()[1],before[1])
        @Expect(primary.withError({value=>@Expect(value.message,"primary");Result<Unit>.Ok(())}).isOk(),true)
        pressure.close();ancestor.close();@Expect(primary.isConsumerRetired(),false)
    }
}
