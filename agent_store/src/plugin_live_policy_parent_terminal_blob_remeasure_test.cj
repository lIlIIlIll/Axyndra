package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

// Real SQLite rollback/payment control only. No physical FD/Root/Source ACK.
@Test
class PluginLivePolicyParentTerminalBlobRemeasureTests {
    @TestCase
    func CallbackMetadataGrowthIsMeasuredBeforeSecondFullCopyAndRollsBack():Unit {
        let fixture=LiveTerminalOwnedBlobFixture();let pool=LogicalJsonOwnerBudget();let prefix=pool.acquire(65536)
        let callbacks=LiveTerminalOwnedBlobCounter()
        try {
            var rejected=false;var measuredBoundary=false
            try{fixture.database.transaction<Unit>{tx=>requireLivePolicyParentTerminalBlobOwned(tx,fixture.payload,
                prefix,1048576,{=>callbacks.value++
                    tx.execute("UPDATE artifacts SET metadata=? WHERE hash=?",
                        [SqlParameter.Text(String.fromUtf8(Array<Byte>(4097,repeat:65))),SqlParameter.Text(fixture.digest)])
                    Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())})}}
            catch(error:Exception){rejected=true;measuredBoundary=error.message.contains("original decoder bound")}
            @Expect(rejected,true);@Expect(measuredBoundary,true);@Expect(callbacks.value,1)
            @Expect(pool.usage()[0],1)
            fixture.database.readTransaction<Unit>{tx=>requireDocumentPayloadMetadata(tx,fixture.payload)}
            @Expect(fixture.database.scalarInt("SELECT count(*) FROM audit_events"),0)
            @Expect(fixture.database.scalarInt("SELECT count(*) FROM operation_receipts"),0)
        }finally{prefix.close();fixture.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
