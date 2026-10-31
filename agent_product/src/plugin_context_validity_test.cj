package agent_product

import agent_core.*
import agent_domain.*
import agent_store.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

func contextValidityProductSnapshot(deadline: Int64): InvocationContextProjection {
    InvocationContextProjection(contributions: [InvocationContextContribution("fixture", "expiring", "frozen:fixture",
        "Frozen context with a finite validity ceiling", ContextContentTrust.UntrustedData, validUntilMillis: deadline)])
}
func waitContextValidityDeadline(deadline: Int64): Unit {
    while (agentUtcMillis() <= deadline) { sleep(Duration.millisecond * 5) }
}
@Test
class PluginContextValidityTests {
    @TestCase
    func actualNativeProviderAcceptsTheOptionalCeilingAndRejectsExpiredAndInvalidValues(): Unit {
        let f = ContextProviderProductFixture()
        try {
            let future = lifecycleTestRequire(f.query(mode: "validity_future"))
            @Expect(future.contributions()[0].validUntilMillis, Int64.Max)
            @Expect(f.query(mode: "expired").error().getOrThrow().code, "context.contribution_expired")
            @Expect(f.query(mode: "validity_zero").isError())
            @Expect(f.query().isOk())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { f.close() }
    }
    @TestCase
    func actualLaunchRefusesAnExpiredSnapshotBeforeAnyModelAttemptAndKeepsHistoryReadable(): Unit {
        let f = ContextProviderProductFixture()
        try {
            let snapshot = contextValidityProductSnapshot(1)
            let request = f.product.request("Use frozen data", sessionId: Some(SessionId(f.thread.value)), contextSnapshot: Some(snapshot))
            let result = f.product.client.start(request, { _ => () })
            @Expect(match (result) { case Result.Ok(AgentRunOutcome.Completed(_)) => false; case _ => true })
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            let raw = f.database.query("SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0)
            @Expect(contextSnapshotFromValue(decodeStoredValue(raw)).contributions()[0].validUntilMillis, 1)
        } finally { f.close() }
    }
    @TestCase
    func expiryAfterPreparationStillRejectsTheActualConsumerWithoutChangingTheSnapshot(): Unit {
        let f = ContextProviderProductFixture()
        try {
            let deadline = agentUtcMillis() + 300
            let snapshot = contextValidityProductSnapshot(deadline)
            let request = f.product.request("Use frozen data", sessionId: Some(SessionId(f.thread.value)), contextSnapshot: Some(snapshot))
            waitContextValidityDeadline(deadline)
            let result = f.product.client.start(request, { _ => () })
            @Expect(match (result) { case Result.Ok(AgentRunOutcome.Completed(_)) => false; case _ => true })
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(contextSnapshotFromValue(contextSnapshotValue(snapshot)).contributions()[0].validUntilMillis, deadline)
        } finally { f.close() }
    }
    @TestCase
    func expiryAfterTheModelPacketWasPreparedPreventsProviderDispatch(): Unit {
        let f = ContextProviderProductFixture()
        try {
            let deadline = agentUtcMillis() + 1000
            let snapshot = contextValidityProductSnapshot(deadline)
            let request = f.product.request("Use frozen data", sessionId: Some(SessionId(f.thread.value)), contextSnapshot: Some(snapshot))
            let waited = AtomicBool(false)
            let result = f.product.client.start(request, { event =>
                match (event.payload) { case AgentEventPayload.AssistantStarted(_) =>
                    waited.store(true); waitContextValidityDeadline(deadline)
                    case _ => () }
            })
            @Expect(waited.load())
            @Expect(match (result) { case Result.Ok(AgentRunOutcome.Completed(_)) => false; case _ => true })
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(contextSnapshotFromValue(contextSnapshotValue(snapshot)).contributions()[0].validUntilMillis, deadline)
        } finally { f.close() }
    }
}
