package agent_runtime

import agent_domain.*

// Original v1 full Item/provenance framing, using actual row custody after
// SQLite unlock. This is a data digest only; Store still proves the legal cut.
public func ownedContextSourceDigestWithPaidCursor113(thread: ThreadRecord,
    cursor: PaidCanonicalThreadCursor113, cover: Int64, localGuard: () -> Result<Unit>,
    current: () -> Result<Unit>): String {
    if (cover < 1 || cover >= thread.nextItemOrdinal) {
        throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
            "context.checkpoint_cover_invalid", "context source digest cover is outside canonical history")) }
    let writer = OwnedContextByteWriter(true)
    writer.frame(thread.id.value); writer.frame(cover.toString())
    // Visit COMPLETE history as the original readback does, not only the cover.
    for (ordinal in 1..thread.nextItemOrdinal) {
        ownedCursorDigestRequire113(cursor.withOrdinal(thread.id, thread.revision, thread.nextItemOrdinal, ordinal,
            localGuard, current, { item, owner =>
                if (item.ordinal <= cover) {
                    ownedCursorDigestRequire113(owner.ensureAdditionalRetainedPeak(65536))
                    writer.item(item); writer.seen++ }
                Result<Unit>.Ok(()) }))
    }
    if (writer.seen != cover) { throw IllegalStateException("canonical Thread prefix is not ordinal-complete") }
    ownedCursorDigestRequire113(cursor.requireBoundary(thread.id, thread.revision, thread.nextItemOrdinal, localGuard))
    "fnv1a64-v1:" + writer.hash.toString()
}
func ownedCursorDigestRequire113(value: Result<Unit>): Unit {
    match (value) { case Result.Ok(_) => (); case Result.Err(error) => throw OwnedCanonicalDataFailure113(error) }
}
