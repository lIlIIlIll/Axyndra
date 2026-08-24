package attempt_projection_contract

import agent_tui.*

main(): Int64 {
    let projection = AttemptProjection()
    let a1Start = TuiAttemptScope("run-1", "semantic-1", "attempt-1", 1)
    projection.start(a1Start)
    expect(projection.activeAttemptId("semantic-1") == "attempt-1", "A1 becomes active")
    expect(projection.accept(TuiAttemptScope("run-1", "semantic-1", "attempt-1", 2)),
        "ordered A1 delta is accepted")
    expect(!projection.accept(TuiAttemptScope("run-1", "semantic-1", "attempt-1", 2)),
        "duplicate sequence is ignored")

    projection.fail(TuiAttemptScope("run-1", "semantic-1", "attempt-1", 3))
    expect(!projection.accept(TuiAttemptScope("run-1", "semantic-1", "attempt-1", 4)),
        "failed Attempt rejects late delta")

    let a2Start = TuiAttemptScope("run-1", "semantic-1", "attempt-2", 5)
    projection.start(a2Start)
    expect(projection.activeAttemptId("semantic-1") == "attempt-2",
        "retry chain has exactly one active Attempt")
    expect(projection.accept(TuiAttemptScope("run-1", "semantic-1", "attempt-2", 6)),
        "A2 delta is isolated from A1")
    projection.commit(TuiAttemptScope("run-1", "semantic-1", "attempt-2", 7))
    expect(projection.activeAttemptId("semantic-1") == "",
        "committed source Attempt is no longer provisional")
    expect(!projection.accept(TuiAttemptScope("run-1", "semantic-1", "attempt-2", 8)),
        "committed Attempt rejects late delta")

    let cancelled = TuiAttemptScope("run-2", "semantic-2", "attempt-cancel", 1)
    projection.start(cancelled)
    projection.cancel(TuiAttemptScope("run-2", "semantic-2", "attempt-cancel", 2))
    expect(!projection.accept(TuiAttemptScope("run-2", "semantic-2", "attempt-cancel", 3)),
        "cancelled Attempt rejects provider-race delta")

    let current = TuiAttemptScope("run-3", "semantic-3", "attempt-current", 10)
    projection.start(current)
    let stale = TuiAttemptScope("run-3", "semantic-3", "attempt-stale", 3)
    projection.start(stale)
    projection.abort(stale)
    expect(projection.activeAttemptId("semantic-3") == "attempt-current",
        "resync does not reactivate terminal retry ancestor")
    println("Attempt projection contract passed")
    0
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
