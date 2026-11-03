package agent_product

import agent_domain.*
import agent_store.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginContinuationHandoffTests {
    @TestCase
    func deadlineFailureBeforeOrAfterAdoptionReleasesActualScopeExactlyOnce(): Unit {
        for (adopted in [false, true]) {
            let pool = LogicalJsonOwnerBudget()
            let before = pool.usage()
            let scope = ContinuationDocumentReadScope({ bytes => pool.acquire(bytes) })
            let closes = AtomicInt64(0)
            let cleanup = ProductContinuationPreparationCleanup({ => let _ = closes.fetchAdd(1); scope.close() })
            let expired = MonoTime.now() - Duration.second
            var refused = false
            try {
                @Expect(pool.usage()[0], before[0] + 1)
                if (adopted) { cleanup.transfer() }
                if (policyQueryRemaining(Some(expired)) <= 0) { throw IllegalStateException("injected expired selection") }
            } catch (_: Exception) { refused = true }
            finally { cleanup.close(); cleanup.close() }
            @Expect(refused)
            if (adopted) {
                // Transfer never releases while the real owner can still use
                // raw data. Model its separate post-consumption retirement.
                @Expect(closes.load(), 0); @Expect(pool.usage()[0], before[0] + 1)
                scope.preflightStored("n"); scope.close(); scope.close()
            } else { @Expect(closes.load(), 1) }
            @Expect(pool.usage()[0], before[0]); @Expect(pool.usage()[1], before[1])
        }
    }
}
