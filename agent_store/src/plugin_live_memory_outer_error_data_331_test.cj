package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

// Actual default-bank allocation/copy controls only. No installed Kernel,
// SQLite rollback, Source/Known, Core persistence/event or caller retirement
// is simulated. These fixtures deliberately retain the complete error debt.
@Test
class LiveMemoryOuterErrorData331Tests {
    @TestCase
    func fullEightMiBNulUnicodeMappingPreservesAllEightFieldsAndCannotRefundCallerAliases():Unit{
        let bank=LogicalJsonOwnerBudget();let original=bank.acquire(1)
        original.ensureRetainedPeak(20971520)
        let text=String.fromUtf8(Array<Byte>(8388604,repeat:b'a'))+"\u{0000}雪"
        @Expect(text.size,8388608)
        let source=IllegalStateException(text);let parent=OperationId("outer-error-331-parent")
        let data=copyLiveMemoryMappedOuterError331(source,parent,original)
        let charged=bank.usage()
        @Expect(data.withError({actual=>
            @Expect(actual.kind,AgentErrorKind.RecoveryRequired)
            @Expect(actual.code,"plugin.live_parent_transaction_unverified")
            @Expect(actual.message,text);@Expect(actual.retryable,false);@Expect(actual.fallbackAllowed,false)
            @Expect(actual.fields.size,1);@Expect(actual.fields[0].name,"operation_id")
            @Expect(actual.fields[0].value,parent.value)
            @Expect(actual.attemptFailure.isNone(),true);@Expect(actual.observation.isNone(),true)
            @Expect(data.matchesError(actual),true);Result<Unit>.Ok(())}).isOk(),true)
        original.close()
        @Expect(data.closeAfterConsumerRetirement().isError(),true)
        @Expect(data.isConsumerRetired(),false)
        @Expect(bank.usage()[0],charged[0]);@Expect(bank.usage()[1],charged[1])
        @Expect(data.withError({actual=>@Expect(actual.message,text);Result<Unit>.Ok(())}).isOk(),true)
        @Expect(data.closeAfterConsumerRetirement().isError(),true)
    }
    @TestCase
    func originalBankPressureRejectsBeforeMappedCopyAndNeverRaisesCapsOrRefundsPublishedData():Unit{
        let bank=LogicalJsonOwnerBudget();let original=bank.acquire(1)
        original.ensureRetainedPeak(20971520)
        let source=IllegalStateException(String.fromUtf8(Array<Byte>(8388600,repeat:b'a')))
        let pressure=bank.acquire(1);pressure.ensureRetainedPeak(100663296)
        let before=bank.usage();var rejected=false
        try{let _=copyLiveMemoryMappedOuterError331(source,OperationId("outer-error-pressure"),original)}
        catch(_:Exception){rejected=true}
        @Expect(rejected,true)
        let after=bank.usage()
        @Expect(after[0],before[0])
        // A failed child still leaves actual shared-group wrapper high-water
        // paid. It must not refund that real concurrently allocated metadata.
        @Expect(after[1]>=before[1],true);@Expect(after[1]<=before[1]+8192,true)
        pressure.close();original.close()
    }
}
