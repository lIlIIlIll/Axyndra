package memory_plugin
import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class NativeMemoryTransactionAndCurrentTests {
    @TestCase
    func retainDraftsStaySeparateWhileCorrectionAndConflictStayAtomic():Unit{
        let journal=NativeMemoryJournal([],1000,captureTransactions:true)
        let first=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("first")))
        let second=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("second")))
        let replacement=nativeMemoryTestRequire(journal.correct(first.id,nativeMemoryTestDraft("replacement"),expectedRevision:1))
        let conflict=nativeMemoryTestRequire(journal.markConflict([replacement.id,second.id],"reason"))
        let groups=journal.pendingTransactions()
        @Expect(groups.size,4);@Expect(groups[0].operation,"retain");@Expect(groups[1].operation,"retain")
        @Expect(groups[0].events.size,1);@Expect(groups[1].events.size,1)
        @Expect(groups[2].operation,"correct");@Expect(groups[2].events.size,2)
        @Expect(groups[3].operation,"conflict");@Expect(groups[3].events.size,2);@Expect(conflict.size,2)
        @Expect(journal.pendingEvents().size,6)
        for(index in 0..groups.size){@Expect(groups[index].ordinal,index)}
        let expected=groups[2].value().field("expected_record").getOrThrow()
        @Expect(httpIntentText(expected,"id"),first.id)
        @Expect(expected.field("revision").getOrThrow().asNumberText(),"1")}
    @TestCase
    func failedPureMutationsAuthorNoGroupAndDoNotEraseEarlierDrafts():Unit{
        let journal=NativeMemoryJournal([],1000,captureTransactions:true)
        let first=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("first")))
        @Expect(journal.correct(first.id,nativeMemoryTestDraft("wrong"),expectedRevision:2).isError(),true)
        @Expect(journal.markConflict([first.id,"missing"],"reason").isError(),true)
        @Expect(journal.pendingTransactions().size,1);@Expect(journal.pendingEvents().size,1)
        @Expect(nativeMemoryTestRequire(journal.get(first.id)).getOrThrow().content,"first")
        // This is a proposal oracle, NOT a simulated SQLite-failure success.
        // Actual first-commit/second-fault persistence still needs two real
        // DerivedRoot Receipts and the original SQLite append fault fixture.
        let ordinary=NativeMemoryJournal([],1000)
        let _=nativeMemoryTestRequire(ordinary.retain(nativeMemoryTestDraft("legacy")))
        @Expect(ordinary.pendingTransactions().size,0);@Expect(ordinary.pendingEvents().size,1)}
    @TestCase
    func explicitEmptyCurrentCannotLeakAnEarlierGloballyReadableHistory():Unit{
        let seed=NativeMemoryJournal([],1000)
        let old=nativeMemoryTestRequire(seed.retain(MemoryV3Draft(MemoryKind.Preference,MemoryScope(MemoryScopeKind.Global),"old global")))
        let noCurrent:Array<MemoryV3Record>=[]
        let journal=NativeMemoryJournal([old],2000,captureTransactions:true,authoritativeCurrent:Some(noCurrent))
        @Expect(nativeMemoryTestRequire(journal.get(old.id)).isNone(),true)
        @Expect(nativeMemoryTestRequire(journal.list()).size,0)
        @Expect(nativeMemoryTestRequire(journal.history(old.id)).size,0)
        @Expect(nativeMemoryTestRequire(journal.eventCount()),1)
        let fresh=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("fresh")))
        @Expect(nativeMemoryTestRequire(journal.list()).size,1)
        @Expect(nativeMemoryTestRequire(journal.get(fresh.id)).getOrThrow().content,"fresh")
        @Expect(nativeMemoryTestRequire(journal.get(old.id)).isNone(),true)}
}
