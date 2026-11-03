package agent_domain

import logical_json_payload as payload
import std.unittest.*
import std.unittest.testmacro.*

@Test
class NeutralPayloadDomainAliasTests126 {
    @TestCase
    func ActualNeutralBankAndDomainAliasShareOnePhysicalLeaseAndFloor(): Unit {
        let actual = payload.LogicalJsonOwnerBudget()
        let alias: LogicalJsonOwnerBudget = actual
        @Expect(refEq(actual, alias), true)
        let parent = alias.acquire(1); let child = parent.deriveRetainedLease()
        parent.close(); child.ensureRetainedPeak(67108864)
        @Expect(actual.usage()[0], 1); @Expect(alias.usage()[1], 67108864 + 1024)
        child.close(); @Expect(actual.usage()[0], 0); @Expect(alias.usage()[1], 0)
    }
    @TestCase
    func DomainBorrowKeepsActualRichErrorObjectAndOriginalProfileCeilings(): Unit {
        let actual = LogicalJsonOwnerBudget(); let parent = actual.acquire(1)
        let copied = parent.acquireCopiedDisplayAllocation(16384).value().getOrThrow()
        let error = AgentError(AgentErrorKind.Provider, "fixture.full_error", "雪\u{0000}whole",
            retryable: true, fallbackAllowed: true, fields: [ErrorField("field", "complete")])
        let returned = copied.withCopiedDisplayBorrow({ => Result<Unit>.Err(error) })
        @Expect(refEq(error, returned.error().getOrThrow()), true)
        @Expect(returned.error().getOrThrow().retryable, true)
        @Expect(returned.error().getOrThrow().fallbackAllowed, true)
        @Expect(returned.error().getOrThrow().field("field"), Some("complete"))
        @Expect(CONTENT_PAYLOAD_RESULT_BYTES, RUN_CONTEXT_SNAPSHOT_MAX_BYTES)
        @Expect(CONTENT_PAYLOAD_INPUT_BYTES, RUN_CONTEXT_SNAPSHOT_MAX_BYTES + 262144)
        @Expect(CONTENT_PAYLOAD_MESSAGE_BYTES, RUN_CONTEXT_SNAPSHOT_MAX_BYTES + 262144 + 65536)
        @Expect(copied.closeAfterCopiedDisplayRetirement().isOk(), true)
        parent.close(); @Expect(actual.usage()[0], 0); @Expect(actual.usage()[1], 0)
    }
}
