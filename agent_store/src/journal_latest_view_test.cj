package agent_store

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

func latestViewTestPolicies():(RowJournalStructuralAccess,RowJournalLatestView){
    let fields=ArrayList<AgentValue>()
    for(path in [["record","scopeKind"],["record","scopeKey"],["record","id"]]){
        fields.add(objectValue([ValueField("path",listValue(path.map{part=>textValue(part)})),
            ValueField("prefix_bytes",integerValue(if(path[1]=="scopeKind"){64}else{0})),
            ValueField("ascii_trimmed_length",boolValue(path[1]=="scopeKey"))]))}
    let access=RowJournalStructuralAccess.parse(objectValue([
        ValueField("schema",textValue(ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA)),ValueField("fields",listValue(fields.toArray())),
        ValueField("scope_classification_path",listValue([textValue("record"),textValue("scopeKind")])),
        ValueField("scope_key_path",listValue([textValue("record"),textValue("scopeKey")])),
        ValueField("scopes",listValue([
            objectValue([ValueField("classification",textValue("open")),ValueField("key_match",textValue("text_fallback_empty"))]),
            objectValue([ValueField("classification",textValue("thread")),ValueField("key_match",textValue("current_thread"))])]))]))
    let view=RowJournalLatestView.parse(objectValue([ValueField("schema",textValue(ROW_JOURNAL_LATEST_VIEW_SCHEMA)),
        ValueField("group_key_path",listValue([textValue("record"),textValue("id")])),
        ValueField("ordinal",textValue("event-primary-key")),ValueField("fold",textValue("last-value-first-position"))]))
    (access,view)
}
func latestViewTestSeed(db:SqliteDatabase,id:Int64,payload:String):Unit{
    db.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,?,'ignored','ignored',?,'ignored')",
        [SqlParameter.Int64Value(id),SqlParameter.Text("SQL-index-"+id.toString()),SqlParameter.Text(payload)])
}
class LatestViewTestState {
    var cancelled=false
    var calls:Int64=0
    let ids=ArrayList<Int64>()
    let bodies=ArrayList<String>()
    let chunks=ArrayList<Byte>()
}
func latestViewTestOkay():Result<Unit>{Result<Unit>.Ok(())}

@Test
class JournalLatestViewTests {
    @TestCase
    func WholeEventOrderUsesDecodedPayloadKeyAndRecoversBadCacheWithoutReadingIt():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/latest.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:67108864,maximumMessage:65536)
        let policy=latestViewTestPolicies();let storage=JournalLatestViewStorage(policy[0],policy[1],"/actual",{bytes=>budget.acquire(bytes)})
        try{
            latestViewTestSeed(db,Int64.Min,"{\"record\":{\"id\":\"a\",\"scopeKind\":\"open\",\"scopeKey\":\"\",\"value\":\"old-a\"}}")
            latestViewTestSeed(db,-1,"{\"record\":{\"id\":\"b\",\"scopeKind\":\"open\",\"scopeKey\":\"\",\"value\":\"old-b\"}}")
            latestViewTestSeed(db,0,"{\"record\":{\"id\":\"\\u0061\",\"scopeKind\":\"open\",\"scopeKey\":\"\",\"value\":\"new-a\"}}")
            latestViewTestSeed(db,Int64.Max,"{\"record\":{\"id\":\"b\",\"scopeKind\":\"open\",\"scopeKey\":\"\",\"value\":\"new-b\"}}")
            db.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES('unrelated-cache',NULL,'not-a-business-enum','not json','not a revision')")
            let state=LatestViewTestState()
            db.readTransaction<Unit>({tx=>storage.latest(tx,"thread1",latestViewTestOkay,{entry,_=>state.ids.add(entry.lastRowid)})})
            @Expect(state.ids.toArray(),[Int64(0),Int64.Max])
            db.execute("DELETE FROM memories")
            let after=LatestViewTestState()
            db.readTransaction<Unit>({tx=>storage.latest(tx,"thread1",latestViewTestOkay,{entry,_=>after.ids.add(entry.lastRowid)})})
            @Expect(after.ids.toArray(),state.ids.toArray());@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func LatestPrivateOverwriteNeverFallsBackToItsEarlierReadableEvent():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/latest.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:67108864,maximumMessage:65536);let policy=latestViewTestPolicies()
        let storage=JournalLatestViewStorage(policy[0],policy[1],"/actual",{bytes=>budget.acquire(bytes)})
        try{
            latestViewTestSeed(db,1,"{\"record\":{\"id\":\"a\",\"scopeKind\":\"open\",\"scopeKey\":\"\",\"value\":\"old readable\"}}")
            latestViewTestSeed(db,2,"{\"record\":{\"id\":\"b\",\"scopeKind\":\"open\",\"scopeKey\":\"\",\"value\":\"still readable\"}}")
            latestViewTestSeed(db,3,"{\"record\":{\"id\":\"a\",\"scopeKind\":\"thread\",\"scopeKey\":\"other-thread\",\"value\":\"private secret\"}}")
            let state=LatestViewTestState()
            db.readTransaction<Unit>({tx=>storage.latest(tx,"thread1",latestViewTestOkay,{entry,_=>state.ids.add(entry.lastRowid)})})
            @Expect(state.ids.toArray(),[Int64(2)])
            let stream=JournalLatestStreamStorage(policy[0],policy[1],"/actual",{bytes=>budget.acquire(bytes)})
            let publicBytes=LatestViewTestState()
            db.readTransaction<Unit>({tx=>
                let fence=stream.fence(tx,latestViewTestOkay)
                let _=stream.emit(tx,"thread1",objectValue([]),objectValue([]),fence,latestViewTestOkay,
                    Some({_,bytes=>publicBytes.chunks.add(all:bytes)}))
            })
            let text=String.fromUtf8(publicBytes.chunks.toArray())
            @Expect(text.contains("private secret"),false);@Expect(text.contains("other-thread"),false)
            @Expect(text.contains("key_sha256"),false);@Expect(text.contains("firstOrdinal"),false)
            @Expect(text.contains("event-cells-private-fence"),false);@Expect(text.contains("\"state\""),false)
            @Expect(text.contains("\"rows\":1"),true);@Expect(text.contains("\"visibility\":\"projection\""),true)
            @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func PrivateEqualityComparesDecodedUnicodeAndEveryByteWithoutTrimmingOrTrustingHash():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/latest.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:67108864,maximumMessage:65536);let policy=latestViewTestPolicies()
        let storage=JournalLatestViewStorage(policy[0],policy[1],"/actual",{bytes=>budget.acquire(bytes)})
        try{
            latestViewTestSeed(db,1,"{\"record\":{\"id\":\"a音😀\",\"scopeKind\":\"open\",\"scopeKey\":\"\"}}")
            latestViewTestSeed(db,2,"{\"record\":{\"id\":\"\\u0061音\\ud83d\\ude00\",\"scopeKind\":\"open\",\"scopeKey\":\"\"}}")
            latestViewTestSeed(db,3,"{\"record\":{\"id\":\" a音😀\",\"scopeKind\":\"open\",\"scopeKey\":\"\"}}")
            db.readTransaction<Unit>({tx=>
                let a=storage.opaque(tx,JournalOpaqueCell.EventPayload,1,true,latestViewTestOkay)
                let b=storage.opaque(tx,JournalOpaqueCell.EventPayload,2,true,latestViewTestOkay)
                let c=storage.opaque(tx,JournalOpaqueCell.EventPayload,3,true,latestViewTestOkay)
                @Expect(storage.equal(tx,1,a,2,b,"thread1",latestViewTestOkay),true)
                // Calling the actual byte comparator directly covers the path
                // a hash collision would take without fabricating a SHA or fact.
                @Expect(storage.equal(tx,1,a,3,c,"thread1",latestViewTestOkay),false)
            })
            let state=LatestViewTestState()
            db.readTransaction<Unit>({tx=>storage.latest(tx,"thread1",latestViewTestOkay,{entry,_=>state.ids.add(entry.lastRowid)})})
            @Expect(state.ids.toArray(),[Int64(2),Int64(3)]);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
    @TestCase
    func IgnoredMetadataChangesOnlyThePrivateFenceAndCancellationNeverReturnsAView():Unit{
        let root=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(root+"/latest.db")
        let budget=LogicalJsonOwnerBudget(maximumCharged:67108864,maximumMessage:65536);let policy=latestViewTestPolicies()
        let stream=JournalLatestStreamStorage(policy[0],policy[1],"/actual",{bytes=>budget.acquire(bytes)})
        let storage=JournalLatestViewStorage(policy[0],policy[1],"/actual",{bytes=>budget.acquire(bytes)})
        try{
            latestViewTestSeed(db,0,"{\"record\":{\"id\":\"a\",\"scopeKind\":\"open\",\"scopeKey\":\"\"}}")
            let a=db.readTransaction<JournalLatestStreamFence>({tx=>stream.fence(tx,latestViewTestOkay)})
            let publicA=db.readTransaction<FixedJournalCellObservation>({tx=>
                stream.emit(tx,"thread1",objectValue([]),objectValue([]),a,latestViewTestOkay,None)})
            db.execute("UPDATE memory_events SET revision=X'00',created_at_millis=1.25,memory_id='different-index' WHERE id=0")
            let b=db.readTransaction<JournalLatestStreamFence>({tx=>stream.fence(tx,latestViewTestOkay)})
            let publicB=db.readTransaction<FixedJournalCellObservation>({tx=>
                stream.emit(tx,"thread1",objectValue([]),objectValue([]),b,latestViewTestOkay,None)})
            @Expect(a.same(b),false)
            @Expect(publicA.bytes,publicB.bytes);@Expect(publicA.digest,publicB.digest)
            let state=LatestViewTestState();state.cancelled=true;var refused=false
            try{db.readTransaction<Unit>({tx=>storage.latest(tx,"thread1",{=>
                Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.cancelled","actual data consumer cancelled"))},
                {_,_=>state.calls+=1})})}catch(_:Exception){refused=true}
            @Expect(refused,true);@Expect(state.calls,0);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
}
