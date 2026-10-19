package agent_store

import agent_domain.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ManagedChannelRuntimeStoreBoundaryTests{
    @TestCase
    func activeLeaseDataWithoutActualStartupCannotAllocateOrChangeTheStore():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/managed-absent.sqlite")
        let pool=LogicalJsonOwnerBudget();let held=pool.acquire(1)
        try{
            let binding=objectValue([ValueField("resource_state",textValue("active")),ValueField("startup_operation_id",textValue("absent-startup")),
                ValueField("target_thread_id",textValue("thread-1")),ValueField("lease_id",textValue("invented-lease"))])
            var rejected=false
            try{database.readTransaction<Unit>{tx=>requireManagedChannelActiveResource(tx,binding,{bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())})}}
            catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
            for(table in ["operations","operation_receipts","derived_operation_admissions","audit_events"]){@Expect(database.scalarInt("SELECT count(*) FROM "+table),0)}
        }finally{held.close();database.close();remove(root,recursive:true)}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func fullStoredMetadataEofAndTrailingCorruptionKeepOriginalPoolAccounting():Unit{
        let root=Directory.createTemp("/tmp").toString();let database=SqliteDatabase(root+"/managed-eof.sqlite")
        let pool=LogicalJsonOwnerBudget()
        try{
            let raw=encodeStoredValue(objectValue([ValueField("body",textValue(String.fromUtf8(Array<Byte>(1048576,repeat:b'x'))+"雪\u{0}🙂"))]))
            database.execute("INSERT INTO audit_events(kind,payload,created_at_millis) VALUES('managed_payment_control',?,1)",[SqlParameter.Text(raw)])
            database.readTransaction<Unit>{tx=>withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE kind='managed_payment_control'",[],
                {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},{actual=>@Expect(actual,raw)})}
            @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
            database.execute("UPDATE audit_events SET payload=? WHERE kind='managed_payment_control'",[SqlParameter.Text(raw+" trailing")])
            var rejected=false
            try{database.readTransaction<Unit>{tx=>withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE kind='managed_payment_control'",[],
                {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},{_=>()})}}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
            @Expect(database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
        }finally{database.close();remove(root,recursive:true)}
    }
}
