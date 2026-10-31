package agent_host_runtime

import agent_domain.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HostLatestJournalStreamInputOwnerTests {
    @TestCase
    func aSuccessfulDescriptiveCallbackWithoutActualStoreProofCannotOpenOrConsume():Unit{
        let invokes=AtomicInt64(0);let paths=AtomicInt64(0);let chunks=AtomicInt64(0);let ends=AtomicInt64(0)
        let reader=HostLatestJournalStreamInputReader({_=>let _=invokes.fetchAdd(1);Result<Unit>.Ok(())},
            {_=>let _=paths.fetchAdd(1);"/never-opened-latest-input"},{=>Result<Unit>.Ok(())},
            {_,_=>let _=chunks.fetchAdd(1);Result<Unit>.Ok(())},{_=>let _=ends.fetchAdd(1);Result<Bool>.Ok(true)})
        try{
            @Expect(reader.read().error().getOrThrow().code,"plugin.latest_input_unconsumed")
            @Expect(reader.read().error().getOrThrow().code,"plugin.latest_input_closed")
            @Expect(invokes.load(),1);@Expect(paths.load(),0);@Expect(chunks.load(),0);@Expect(ends.load(),0)
        }finally{@Expect(reader.close().isOk(),true)}
    }
    @TestCase
    func preclosedInputNeverCallsTheStoreOrChoosesAPath():Unit{
        let invokes=AtomicInt64(0);let paths=AtomicInt64(0)
        let reader=HostLatestJournalStreamInputReader({_=>let _=invokes.fetchAdd(1);Result<Unit>.Ok(())},
            {_=>let _=paths.fetchAdd(1);"/never-opened-latest-input"},{=>Result<Unit>.Ok(())},
            {_,_=>Result<Unit>.Ok(())},{_=>Result<Bool>.Ok(true)})
        @Expect(reader.close().isOk(),true);@Expect(reader.close().isOk(),true)
        @Expect(reader.read().error().getOrThrow().code,"plugin.latest_input_closed")
        @Expect(invokes.load(),0);@Expect(paths.load(),0)
    }
    @TestCase
    func theActualSessionAdoptsOnlyOneInputAndOwnsItsCleanupBeforeAnyOpen():Unit{
        let invokes=AtomicInt64(0);let session=HostDocumentDataSession(HostArtifactStore("/never-opened-latest-session"))
        let reader=HostLatestJournalStreamInputReader({_=>let _=invokes.fetchAdd(1);Result<Unit>.Ok(())},
            {_=>"/never-opened-latest-input"},{=>Result<Unit>.Ok(())},{_,_=>Result<Unit>.Ok(())},{_=>Result<Bool>.Ok(true)})
        try{
            let result=session.run({owner=>
                @Expect(owner.retainLatestJournalInput(reader).isOk(),true)
                @Expect(owner.retainLatestJournalInput(reader).error().getOrThrow().code,"plugin.document_query_closed")
                Result<AgentValue>.Ok(nullValue())})
            @Expect(result.isOk(),true);@Expect(session.collect(),true);@Expect(invokes.load(),0)
            @Expect(reader.read().error().getOrThrow().code,"plugin.latest_input_closed")
        }finally{@Expect(reader.close().isOk(),true);@Expect(session.close().isOk(),true)}
    }
}
