package neutral_payload_consumer126

// Import only the original Domain public surface. This independent consumer
// requires actual alias/extension resolution, not own-package lookup. The
// receiver type is named explicitly because an extension is resolved through
// the class it extends, so a wildcard import alone does not make it visible.
import agent_domain.*
import agent_domain.LogicalJsonOwnerReservation
import agent_domain.LogicalJsonCopiedDisplayAllocation

main(): Int64 {
    let bank = LogicalJsonOwnerBudget()
    let original = bank.acquire(1); let child = original.deriveRetainedLease()
    original.close()
    let copied = child.acquireCopiedDisplayAllocation(16384).value().getOrThrow()
    let error = AgentError(AgentErrorKind.Provider, "fixture.consumer_error", "whole",
        retryable: true, fallbackAllowed: true, fields: [ErrorField("field", "complete")])
    try {
        let returned = copied.withCopiedDisplayBorrow({ => Result<Unit>.Err(error) })
        if (!refEq(error, returned.error().getOrThrow())) { return 1 }
        if (CONTENT_PAYLOAD_RESULT_BYTES != RUN_CONTEXT_SNAPSHOT_MAX_BYTES) { return 2 }
        if (bank.usage()[0] < 2 || bank.usage()[1] <= 16777216) { return 3 }
    } finally {
        if (!copied.closeAfterCopiedDisplayRetirement().isOk()) {
            throw IllegalStateException("actual display consumer retirement failed") }
        child.close()
    }
    if (bank.usage()[0] != 0 || bank.usage()[1] != 0) { return 4 }
    0
}
