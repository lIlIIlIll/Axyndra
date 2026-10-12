package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Genuine SQLite cells and same-pool accounting. No fake Root/read fact or
// Receipt is seeded, and these controls do not establish terminal acceptance.
@Test
class PluginLivePolicyParentSourceStreamedTests{
    @TestCase
    func OnePaidCellPhaseKeepsOutputAndSessionOwnersUntilActualFullComparison():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/phase.sqlite")
        let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608);let session=pool.acquire(65536)
        let expected=encodeStoredValue(objectValue([ValueField("unicode",textValue("中文😀\u{0000}")),ValueField("number",JsonNode.number("1e0"))]))
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE phase_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO phase_cell(payload) VALUES(?)",[SqlParameter.Text(expected)])
                let cell=contextReadMetadataMeasure(tx,"payload"," FROM phase_cell",[],{bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())})
                @Expect(pool.usage()[0],2)
                let owner=pool.acquire(65536)
                try{
                    requireLivePolicyTerminalStoredCell(tx,"payload"," FROM phase_cell",[],cell,expected,owner,1048576,{=>Result<Unit>.Ok(())})
                    @Expect(pool.usage()[0],3);@Expect(pool.usage()[1],100663296)
                }finally{owner.close()}
                @Expect(pool.usage()[0],2)}
        }finally{session.close();output.close();db.close();remove(directory,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func ChangedCompleteCellFailsAndCallerReservationRemainsLive():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/changed.sqlite")
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let expected=encodeStoredValue(textValue("whole expected"));let changed=encodeStoredValue(textValue("whole changed!"))
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE phase_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO phase_cell(payload) VALUES(?)",[SqlParameter.Text(changed)])
                let cell=contextReadMetadataMeasure(tx,"payload"," FROM phase_cell",[],{bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())})
                var rejected=false
                try{requireLivePolicyTerminalStoredCell(tx,"payload"," FROM phase_cell",[],cell,expected,owner,1048576,{=>Result<Unit>.Ok(())})}
                catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(pool.usage()[0],1)}
        }finally{owner.close();db.close();remove(directory,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func TrailingStoredBytesCannotPassTheOriginalEofMeasurement():Unit{
        let directory=Directory.createTemp("/tmp").toString();let db=SqliteDatabase(directory+"/eof.sqlite")
        let pool=LogicalJsonOwnerBudget();let held=pool.acquire(65536)
        try{
            db.transaction<Unit>{tx=>
                tx.execute("CREATE TABLE phase_cell(payload TEXT NOT NULL)")
                tx.execute("INSERT INTO phase_cell(payload) VALUES(?)",[SqlParameter.Text(encodeStoredValue(textValue("complete"))+"n")])
                var rejected=false
                try{let _=contextReadMetadataMeasure(tx,"payload"," FROM phase_cell",[],{bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())})}
                catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(pool.usage()[0],1)}
        }finally{held.close();db.close();remove(directory,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
