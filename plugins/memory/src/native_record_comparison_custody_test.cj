package memory_plugin

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class NativeMemoryRecordComparisonCustodyTests {
    @TestCase
    func paidValidationAndExpectedCorrectionKeepEveryOriginalEventAndFullError():Unit {
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        owner.ensureRetainedPeak(4194304)
        try {
            let record=memoryContextCustodyRecord("original 雪\u{0}🙂",["same","same","other 雪\u{0}"])
            let old=NativeMemoryJournal([],1000,captureTransactions:true,authoritativeCurrent:Some([record]))
            let paid=NativeMemoryJournal([],1000,captureTransactions:true,authoritativeCurrent:Some([record]),snapshotOwner:Some(owner))
            @Expect(paid.validateRecords([record]).isOk(),true)
            let changed=memoryV3Copy(record,revision:record.revision+1)
            let oldError=old.validateRecords([changed]).error().getOrThrow()
            let paidError=paid.validateRecords([changed]).error().getOrThrow()
            @Expect(paidError.describe(),oldError.describe())
            let draft=MemoryV3Draft(MemoryKind.Preference,MemoryScope(MemoryScopeKind.Workspace,key:"/workspace"),
                "replacement 雪\u{0}🙂",source:"user")
            let before=nativeMemoryTestRequire(old.correct(record.id,draft,expectedRevision:record.revision))
            let after=nativeMemoryTestRequire(paid.correct(record.id,draft,expectedRevision:record.revision))
            @Expect(canonicalAgentValue(memoryV3RecordValue(after)),canonicalAgentValue(memoryV3RecordValue(before)))
            @Expect(canonicalAgentValue(listValue(paid.pendingEvents())),canonicalAgentValue(listValue(old.pendingEvents())))
            @Expect(paid.pendingTransactions().size,1);@Expect(old.pendingTransactions().size,1)
            @Expect(canonicalAgentValue(paid.pendingTransactions()[0].value()),canonicalAgentValue(old.pendingTransactions()[0].value()))
            @Expect(pool.usage()[0],1)
        } finally {owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func fullOriginalPoolRejectsBothValidationAndExpectedAppendBeforeAnyEventOrGroup():Unit {
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        owner.ensureRetainedPeak(4194304)
        let record=memoryContextCustodyRecord("small",Array<String>(4096,{_=>""}))
        let paid=NativeMemoryJournal([],1000,captureTransactions:true,authoritativeCurrent:Some([record]),snapshotOwner:Some(owner))
        let draft=MemoryV3Draft(MemoryKind.Preference,MemoryScope(MemoryScopeKind.Workspace,key:"/workspace"),"after",source:"user")
        let pressure=Array<LogicalJsonOwnerReservation>(7,{_=>pool.acquire(1)})
        try {
            @Expect(pool.usage()[0],8);@Expect(pool.usage()[1],134217728)
            var validationRejected=false
            try {let _=paid.validateRecords([record])}catch(_:LogicalJsonPayloadError){validationRejected=true}
            @Expect(validationRejected,true)
            var correctionRejected=false
            try {let _=paid.correct(record.id,draft,expectedRevision:record.revision)}catch(_:LogicalJsonPayloadError){correctionRejected=true}
            @Expect(correctionRejected,true)
            @Expect(paid.pendingEvents().size,0);@Expect(paid.pendingTransactions().size,0)
            @Expect(nativeMemoryTestRequire(paid.get(record.id)).getOrThrow().revision,record.revision)
            @Expect(pool.usage()[0],8);@Expect(pool.usage()[1],134217728)
            for(held in pressure){held.close()}
            @Expect(paid.validateRecords([record]).isOk(),true)
            let _=nativeMemoryTestRequire(paid.correct(record.id,draft,expectedRevision:record.revision))
            @Expect(paid.pendingEvents().size,2);@Expect(paid.pendingTransactions().size,1)
            @Expect(pool.usage()[0],1)
        } finally {for(held in pressure){held.close()};owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
