package memory_plugin

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func nativeMemoryTestRequire<T>(value:Result<T>):T {
    match(value){case Result.Ok(result)=>result;case Result.Err(error)=>throw IllegalStateException(error.code+":"+error.message)}
}
func nativeMemoryTestDraft(content:String):MemoryV3Draft {
    MemoryV3Draft(MemoryKind.Preference,MemoryScope(MemoryScopeKind.Workspace,key:"/workspace"),content,source:"user")
}
func nativeMemoryTestJournal(rows:Array<MemoryV3Record>):AgentValue {
    let events=ArrayList<AgentValue>();let current=ArrayList<AgentValue>();var chain=modelPolicySha256Text("axyndra.opaque-row-journal/v1")
    var sequence:Int64=1
    for(record in rows){
        let payload=stringifyUnifiedJson(memoryV3EventValue("retain",record))
        let event=objectValue([ValueField("id",integerValue(sequence)),ValueField("key",textValue(record.id)),
            ValueField("revision",integerValue(record.revision)),ValueField("operation",textValue("retain")),
            ValueField("payload",textValue(payload)),ValueField("created_at_millis",integerValue(record.updatedAt))])
        sequence++;chain=modelPolicySha256Text(chain+canonicalAgentValue(event));events.add(event)
        current.add(objectValue([ValueField("key",textValue(record.id)),ValueField("kind",textValue(memoryV3KindName(record.kind))),
            ValueField("payload_sha256",textValue(modelPolicySha256Text(payload))),ValueField("revision",integerValue(record.revision))]))
    }
    objectValue([ValueField("schema",textValue("axyndra.opaque-row-journal/v1")),ValueField("layout",textValue("opaque-fact-events-v3")),
        ValueField("rows",listValue(current.toArray())),ValueField("events",listValue(events.toArray())),
        ValueField("journal_chain_sha256",textValue(chain)),ValueField("next_event_id",integerValue(sequence)),
        ValueField("annotations",objectValue([ValueField("workspace_root",textValue("/workspace")),ValueField("settings_root",textValue("/settings")),
            ValueField("thread_id",textValue("thread")),ValueField("lane_id",textValue("main"))]))])
}

// These are pure Native business/data tests. Their data envelopes do not
// create a Root, permission, completed ContextRead or execution Receipt.
@Test
class MemoryNativeJournalBusinessTests {
    @TestCase
    func correctionRetainsTheOriginalHistoryAndLinksReplacement():Unit {
        let journal=NativeMemoryJournal([],1000)
        let original=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("old concise")))
        let replacement=nativeMemoryTestRequire(journal.correct(original.id,nativeMemoryTestDraft("new concise"),expectedRevision:1))
        @Expect(replacement.correctionOf,original.id)
        let current=nativeMemoryTestRequire(journal.get(original.id)).getOrThrow()
        @Expect(current.status,MemoryStatus.Corrected);@Expect(current.replacementId,replacement.id);@Expect(current.revision,2)
        let history=nativeMemoryTestRequire(journal.history(original.id))
        @Expect(history.size,2);@Expect(history[0].content,"old concise");@Expect(history[0].revision,1)
        @Expect(nativeMemoryTestRequire(journal.history(replacement.id)).size,1)
        @Expect(journal.pendingEvents().size,3)
    }
    @TestCase
    func conflictAndResolutionMatchOriginalWinnerAndLoserLifecycle():Unit {
        let journal=NativeMemoryJournal([],1000)
        let first=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("first concise")))
        let second=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("second concise")))
        let conflicts=nativeMemoryTestRequire(journal.markConflict([first.id,second.id],"contradiction"))
        @Expect(conflicts.size,2);@Expect(conflicts[0].revision,2)
        let winner=nativeMemoryTestRequire(journal.resolveConflict(first.id))
        let loser=nativeMemoryTestRequire(journal.get(second.id)).getOrThrow()
        @Expect(winner.status,MemoryStatus.Active);@Expect(winner.revision,3)
        @Expect(loser.status,MemoryStatus.Corrected);@Expect(loser.replacementId,first.id);@Expect(loser.revision,3)
        @Expect(journal.pendingEvents().size,6)
    }
    @TestCase
    func failedConflictAndRevisionCASCannotAuthorPartialEvents():Unit {
        let journal=NativeMemoryJournal([],1000)
        let first=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("first")))
        @Expect(journal.markConflict([first.id,"missing"],"contradiction").isError())
        @Expect(journal.correct(first.id,nativeMemoryTestDraft("changed"),expectedRevision:2).isError())
        @Expect(journal.pendingEvents().size,1)
        @Expect(nativeMemoryTestRequire(journal.get(first.id)).getOrThrow().status,MemoryStatus.Active)
    }
    @TestCase
    func tombstoneIsIdempotentAndRemainsAbsentFromSearch():Unit {
        let journal=NativeMemoryJournal([],1000)
        let first=nativeMemoryTestRequire(journal.retain(nativeMemoryTestDraft("concise answer")))
        let deleted=nativeMemoryTestRequire(journal.delete(first.id,reason:"forget"))
        @Expect(deleted.revision,2);@Expect(deleted.deletedAt,1000);@Expect(deleted.deletionReason,"forget")
        let repeated=nativeMemoryTestRequire(journal.delete(first.id))
        @Expect(repeated.revision,2);@Expect(journal.pendingEvents().size,2)
        @Expect(nativeMemoryTestRequire(journal.search("concise",policy:Some(NativeMemoryBusinessPolicy()))).hits.size,0)
    }
    @TestCase
    func nativeProposalPreservesEveryOldEventByteAndCanonicalCodecField():Unit {
        let seed=NativeMemoryJournal([],1000);let original=nativeMemoryTestRequire(seed.retain(nativeMemoryTestDraft("old")))
        let previous=nativeMemoryTestJournal([original]);let journal=NativeMemoryJournal([original],2000)
        let replacement=nativeMemoryTestRequire(journal.correct(original.id,nativeMemoryTestDraft("new")))
        let next=memoryDocumentNext(previous,journal.pendingEvents())
        @Expect(canonicalAgentValue(next.field("events").getOrThrow().items[0]),canonicalAgentValue(previous.field("events").getOrThrow().items[0]))
        @Expect(memoryDocumentInteger(next,"next_event_id"),4)
        let history=memoryDocumentHistory(next)
        @Expect(history.size,3);@Expect(history[0].id,original.id);@Expect(history[2].id,replacement.id)
        @Expect(memoryV3RecordValue(replacement).fields.size,19)
    }
    @TestCase
    func firstAppearanceOrderDoesNotFabricateHistoricalRecords():Unit {
        let seed=NativeMemoryJournal([],1000)
        let first=nativeMemoryTestRequire(seed.retain(nativeMemoryTestDraft("first")))
        let second=nativeMemoryTestRequire(seed.retain(nativeMemoryTestDraft("second")))
        let journal=NativeMemoryJournal([second,first],2000,firstAppearance:[first.id,second.id])
        let rows=nativeMemoryTestRequire(journal.list())
        @Expect(rows[0].id,first.id);@Expect(rows[1].id,second.id)
        let history=nativeMemoryTestRequire(journal.history(second.id))
        @Expect(history.size,1);@Expect(history[0].id,second.id)
    }
}
