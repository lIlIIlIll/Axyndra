package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// Actual original-bank mapper/consumer allocation controls. These do not
// simulate the installed Host, canonical SQLite abort or Core publication.
@Test
class LiveMemoryOuterErrorConsumer333Tests {
    @TestCase
    func independentSnapshotDiagnosticAndDescriptionKeepCompleteMappedErrorPaid():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(20971520)
        let text=String.fromUtf8(Array<Byte>(65536,repeat:b'a'))+"\u{0000}雪🙂"
        let data=copyLiveMemoryMappedOuterError331(IllegalStateException(text),OperationId("consumer-parent"),ancestor)
        let run=RunId("consumer-run")
        let value=OwnedOuterErrorFailure333(data,RunSnapshot(run,SessionId("consumer-thread"),RunState.RecoveryRequired,
            sequence:3,modelRequests:2,toolCalls:1,turns:1),EventMeta(4,TraceId("consumer-trace"),run))
        @Expect(value.withSnapshot({actual,_=>
            @Expect(actual.summary,text);@Expect(actual.error.getOrThrow().message,text)
            @Expect(actual.error.getOrThrow().code,"plugin.live_parent_transaction_unverified")
            @Expect(actual.error.getOrThrow().kind,AgentErrorKind.RecoveryRequired)
            @Expect(actual.error.getOrThrow().retryable,false);@Expect(actual.error.getOrThrow().fallbackAllowed,false)
            @Expect(actual.error.getOrThrow().attemptFailure.isNone(),true)
            @Expect(actual.error.getOrThrow().observation.isNone(),true)
            @Expect(actual.error.getOrThrow().field("operation_id").getOrThrow(),"consumer-parent")
            @Expect(actual.sequence,3);@Expect(actual.modelRequests,2);@Expect(actual.toolCalls,1)
            // A consumer cannot mutate the next borrowed fields array.
            actual.error.getOrThrow().fields[0]=ErrorField("caller","mutated")
            Result<Unit>.Ok(())}).isOk(),true)
        @Expect(value.withDiagnostic({actual,_=>
            match(actual.payload){case AgentEventPayload.Diagnostic(error)=>
                @Expect(error.message,text);@Expect(error.field("operation_id").getOrThrow(),"consumer-parent")
                case _=>@Expect(false,true)}
            @Expect(actual.sequence,4);Result<Unit>.Ok(())}).isOk(),true)
        @Expect(value.withDescription({actual=>
            @Expect(actual,text+" (plugin.live_parent_transaction_unverified)\noperation_id: consumer-parent")
            Result<Unit>.Ok(())}).isOk(),true)
        let held=bank.usage();ancestor.close()
        @Expect(value.closeAfterConsumerRetirement().isError(),true)
        @Expect(data.closeAfterConsumerRetirement().isError(),true)
        @Expect(value.isConsumerRetired(),false)
        @Expect(bank.usage()[0],held[0]);@Expect(bank.usage()[1],held[1])
    }

    @TestCase
    func nestedConsumersSumOriginalBankAndCallbackThrowNeverRefundsEscapedData():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let data=copyLiveMemoryMappedOuterError331(IllegalStateException("complete error"),OperationId("nested"),ancestor)
        let initial=bank.usage()
        @Expect(data.withPaidError333({_,fund=>
            fund(20971520).value().getOrThrow()
            @Expect(data.withPaidError333({_,inner=>inner(20971520)}).isOk(),true)
            Result<Unit>.Ok(())}).isOk(),true)
        let two=bank.usage();@Expect(two[0],initial[0]);@Expect(two[1]>=41943040,true)
        @Expect(data.withPaidError333({_,fund=>
            fund(20971520).value().getOrThrow()
            throw IllegalStateException("callback exited after publication")}).isError(),true)
        let three=bank.usage();@Expect(three[0],initial[0]);@Expect(three[1]>=two[1]+20971520,true)
        ancestor.close();@Expect(data.closeAfterConsumerRetirement().isError(),true)
        @Expect(bank.usage()[1],three[1])
    }

    @TestCase
    func originalPoolPressureRejectsBeforeBorrowAndNeverSubstitutesAnotherPool():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(16777216)
        let data=copyLiveMemoryMappedOuterError331(IllegalStateException("paid error"),OperationId("pressure"),ancestor)
        let first=bank.usage();let pressure=bank.acquire(1)
        pressure.ensureRetainedPeak(134217728-first[1]-4096)
        let entered=AtomicBool(false)
        @Expect(data.withPaidError333({_,_=>entered.store(true);Result<Unit>.Ok(())}).isError(),true)
        @Expect(entered.load(),false);@Expect(bank.usage()[0],2)
        pressure.close();ancestor.close();@Expect(data.isConsumerRetired(),false)
        @Expect(bank.usage()[0],1)
    }

    @TestCase
    func mismatchedRunMetadataCannotBecomeFailureSnapshotOrSpendConsumerInvoice():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let data=copyLiveMemoryMappedOuterError331(IllegalStateException("paid error"),OperationId("metadata"),ancestor)
        let before=bank.usage()
        let rejected=try{
            let _=OwnedOuterErrorFailure333(data,RunSnapshot(RunId("one"),SessionId("thread"),RunState.RecoveryRequired),
                EventMeta(1,TraceId("trace"),RunId("other")))
            false
        }catch(_:IllegalArgumentException){true}
        @Expect(rejected,true);@Expect(bank.usage()[0],before[0]);@Expect(bank.usage()[1],before[1])
        ancestor.close();@Expect(data.closeAfterConsumerRetirement().isError(),true)
    }

    @TestCase
    func supplementalErrorKeepsBothTypedAttachmentsAndFreshFieldArrays():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        let data=copyLiveMemoryMappedOuterError331(IllegalStateException("paid error"),OperationId("supplement"),ancestor)
        let run=RunId("supplement-run")
        let value=OwnedOuterErrorFailure333(data,RunSnapshot(run,SessionId("thread"),RunState.RecoveryRequired),
            EventMeta(1,TraceId("trace"),run))
        let attempt=AttemptFailure(AttemptFailureKind.ProviderTransportError)
        let observation=OperationObservation("{\"detail\":\"full\\u0000雪\"}")
        let extra=AgentError(AgentErrorKind.Internal,"full.supplement","full\u{0000}雪",retryable:true,fallbackAllowed:true,
            fields:[ErrorField("first","original")],attemptFailure:Some(attempt),observation:Some(observation))
        @Expect(value.retainSupplement(extra).isOk(),true)
        extra.fields[0]=ErrorField("changed","caller")
        @Expect(value.withSupplement(0,{actual,_=>
            @Expect(actual.message,"full\u{0000}雪");@Expect(actual.kind,AgentErrorKind.Internal)
            @Expect(actual.code,"full.supplement");@Expect(actual.retryable,true);@Expect(actual.fallbackAllowed,true)
            @Expect(actual.fields[0].value,"original")
            @Expect(refEq(actual.attemptFailure.getOrThrow(),attempt),true)
            @Expect(refEq(actual.observation.getOrThrow(),observation),true)
            actual.fields[0]=ErrorField("second","consumer");Result<Unit>.Ok(())}).isOk(),true)
        @Expect(value.withSupplement(0,{actual,_=>@Expect(actual.fields[0].value,"original");Result<Unit>.Ok(())}).isOk(),true)
        ancestor.close();@Expect(value.closeAfterConsumerRetirement().isError(),true)
    }
    @TestCase
    func eachPendingCallerWrapperPrepaysIndependentSameBankCaptureAndCannotRefund():Unit{
        let bank=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(16777216)
        let data=copyLiveMemoryMappedOuterError331(IllegalStateException("complete error"),OperationId("pending"),ancestor)
        let before=bank.usage();let first=OwnedOuterErrorPending333(data);let one=bank.usage()
        let second=OwnedOuterErrorPending333(data);let two=bank.usage()
        @Expect(one[1]>before[1],true);@Expect(two[1]>one[1],true)
        @Expect(two[0],before[0])
        @Expect(first.closeAfterConsumerRetirement().isError(),true)
        @Expect(second.closeAfterConsumerRetirement().isError(),true)
        ancestor.close();@Expect(bank.usage()[1],two[1]);@Expect(data.isConsumerRetired(),false)
    }
}
