package agent_product

import agent_core.*
import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

class InitialContextCutCapture {
    let fixture: SkillsProviderProductFixture
    let request: AgentRunRequest
    let mode: String
    var observed = false
    init(fixture: SkillsProviderProductFixture, request: AgentRunRequest, mode: String) {
        this.fixture = fixture; this.request = request; this.mode = mode
    }
    func event(event: AgentEvent): Unit {
        match (event.payload) {
            case AgentEventPayload.BudgetUpdated(_) =>
                // This is the existing release-slot event, after the actual
                // read Receipt/host continuation, before the Runtime safe cut.
                if (observed || skillsReadCount(fixture, "completed") != 1) { return }
                observed = true
                @Expect(fixture.product.fixtureProbe.getOrThrow().lastRequest.isNone())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
                if (mode == "config") { initialContextTestConfig(fixture, extra: true) }
                else if (mode == "revoke") { @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk()) }
                else { @Expect(fixture.product.client.cancel(request.runId).isOk()) }
            case _ => ()
        }
    }
}

@Test
class PluginInitialContextCutTests {
    @TestCase
    func completedReadCannotPassFirstModelAfterItsRequiredCutIsWithdrawn(): Unit {
        for (mode in ["config", "revoke", "cancel"]) {
            let fixture = SkillsProviderProductFixture()
            try {
                initialContextTestConfig(fixture)
                let request = fixture.product.request("$review", sessionId: Some(SessionId(fixture.thread.value)))
                let capture = InitialContextCutCapture(fixture, request, mode)
                let _ = fixture.product.client.start(request, { event => capture.event(event) })
                @Expect(capture.observed)
                @Expect(skillsReadCount(fixture, "completed"), 1)
                @Expect(initialContextHandoffs(fixture), 1)
                @Expect(fixture.product.fixtureProbe.getOrThrow().lastRequest.isNone())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
                @Expect(initialContextStored(fixture).contributions().isEmpty())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','cancelling')"), 0)
                initialContextNoOpenWork(fixture)
            } finally { fixture.close() }
        }
    }
}
