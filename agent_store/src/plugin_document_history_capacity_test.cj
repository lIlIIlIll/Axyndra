package agent_store

import agent_domain.*
import std.env.getVariable
import std.fs.*
import yjson.*
import yjson_support.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginDocumentHistoryCapacityTests {
    @TestCase
    func twoActualEightMibStoredResultsUseSequentialLeases(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(root+"/history.sqlite")
        let budget=LogicalJsonOwnerBudget(maximumCharged:100663296)
        let scope=ContinuationDocumentReadScope({bytes=>budget.acquire(bytes)})
        let content=String.fromUtf8(Array<Byte>(8388599,repeat:b'x'))
        let encoded=encodeStoredValue(textValue(content))
        @Expect(encoded.size,8388608)
        try {
            db.transaction{tx=>tx.execute("CREATE TABLE history_capacity(value TEXT)")
                tx.execute("INSERT INTO history_capacity VALUES(?)",[SqlParameter.Text(encoded)])}
            db.readTransaction<Unit>({tx=>
                let first=scope.transientDigest(tx,"SELECT value FROM history_capacity",[],{raw,check=>
                    check(raw);@Expect(decodeStoredValue(raw).text.size,content.size);modelPolicySha256Text(raw)})
                @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
                let second=scope.transientDigest(tx,"SELECT value FROM history_capacity",[],{raw,check=>
                    check(raw);@Expect(decodeStoredValue(raw).text.size,content.size);modelPolicySha256Text(raw)})
                @Expect(first,second);@Expect(budget.usage()[0],1)
            })
        }finally{scope.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func metadataCapacityRefusesInvalidUtf8BeforeConsumerRuns(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(root+"/history.sqlite")
        let budget=LogicalJsonOwnerBudget(maximumCharged:67108864)
        let scope=ContinuationDocumentReadScope({bytes=>budget.acquire(bytes)})
        let called=AtomicBool(false);var refused=false
        try {
            try {db.readTransaction<Unit>({tx=>
                let _=scope.transientDigest(tx,"SELECT CAST(X'ff' || zeroblob(8388608) AS TEXT)",[],{raw,check=>
                    called.store(true);check(raw);modelPolicySha256Text(raw)})
            })}catch(_:LogicalJsonPayloadError){refused=true}
            @Expect(refused);@Expect(!called.load());@Expect(budget.usage()[0],1)
        }finally{scope.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func originalScopeCurrentAndCloseCannotBeBypassedByTransientRead(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(root+"/history.sqlite")
        let budget=LogicalJsonOwnerBudget()
        let expired=AtomicBool(false);let called=AtomicBool(false);var refused=false
        let scope=ContinuationDocumentReadScope({bytes=>budget.acquire(bytes)},current:{=>
            if(expired.load()){throw IllegalStateException("original query expired")}})
        try {
            expired.store(true)
            try {db.readTransaction<Unit>({tx=>
                let _=scope.transientDigest(tx,"SELECT 'n'",[],{raw,check=>called.store(true);check(raw);modelPolicySha256Text(raw)})
            })}catch(_:Exception){refused=true}
            @Expect(refused);@Expect(!called.load());@Expect(budget.usage()[0],1)
            expired.store(false);scope.close();refused=false
            try {db.readTransaction<Unit>({tx=>
                let _=scope.transientDigest(tx,"SELECT 'n'",[],{raw,check=>called.store(true);check(raw);modelPolicySha256Text(raw)})
            })}catch(_:Exception){refused=true}
            @Expect(refused);@Expect(!called.load())
        }finally{scope.close();db.close();remove(root,recursive:true)}
        @Expect(budget.usage()[0],0)
    }
}
