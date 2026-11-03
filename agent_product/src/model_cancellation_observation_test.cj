package agent_product

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelCancellationObservationTests {
    @TestCase
    func actualAttemptPollsObserveOneScopeTokenAndCannotUseStaleOwner(): Unit {
        let fixture = ModelProviderProductFixture()
        let retained = ArrayList<CancellationToken>()
        let owners = ArrayList<AgentThreadRuntime>()
        let epochs = ArrayList<Int64>()
        try {
            fixture.factory.beforeOpen = { dispatch =>
                let workspace = fixture.database.query("SELECT workspace_id FROM threads WHERE id='provider-thread'")[0].required(0)
                let runtime = fixture.runtimes.acquire(dispatch.threadId, workspace).value().getOrThrow()
                let original = runtime.currentRunCancellationToken(dispatch.runId, dispatch.epoch).value().getOrThrow()
                retained.add(original); owners.add(runtime); epochs.add(dispatch.epoch)
                for (_ in 0..256) {
                    let observed = runtime.currentRunCancellationToken(dispatch.runId, dispatch.epoch).value().getOrThrow()
                    @Expect(refEq(original, observed))
                    @Expect(dispatch.check().isOk())
                }
                @Expect(runtime.currentRunCancellationToken(RunId("foreign-run"), dispatch.epoch).isError())
                @Expect(runtime.currentRunCancellationToken(dispatch.runId, dispatch.epoch + 1).isError())
            }
            @Expect(fixture.run().isOk())
            @Expect(retained.size, 1); @Expect(owners.size, 1)
            @Expect(owners[0].currentRunCancellationToken(RunId("provider-run"), epochs[0]).isError())
            @Expect(fixture.factory.count(), 1); @Expect(fixture.factory.allClosed())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
        } finally { fixture.close() }
    }
}
