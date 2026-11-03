package agent_runtime

import agent_domain.*
import std.sync.*

private let ownedModelLaneCuts159 = OwnedModelLaneCuts159()

// Additional explicit DATA consumption contract. Ordinary commit/Ok is not
// a retirement receipt; unknown sinks retain the registered complete input.
public interface ReturningModelLaneCutCommitSink159 {
    func commitModelLaneCut159(transition: ThreadTransition, input: OwnedModelLaneCut159): Result<Unit>
}

public class OwnedModelLaneCut159 {
    private let lock = Mutex()
    private var previous: ?OwnedModelLaneSnapshot159
    private var next: ?OwnedModelLaneSnapshot159
    private var change: ?RunModelLaneChange = None<RunModelLaneChange>
    private var sqlReturned = false
    private var closed = false
    var next159: ?OwnedModelLaneCut159 = None<OwnedModelLaneCut159>
    init(previous: OwnedModelLaneSnapshot159, next: OwnedModelLaneSnapshot159) {
        // Both registered snapshot loans and their measuring/codec carriers
        // were funded before this private node or its lock was constructed.
        this.previous = Some(previous); this.next = Some(next)
        ownedModelLaneCuts159.retain159(this)
    }
    func previousValue159(): AgentValue { previous.getOrThrow().value159() }
    func nextValue159(): AgentValue { next.getOrThrow().value159() }
    func reservePreviousCopy159(): Unit {
        lock.lock(); try { previous.getOrThrow().reserveCopy159() } finally { lock.unlock() }
    }
    func reserveNextCopy159(): Unit {
        lock.lock(); try { next.getOrThrow().reserveCopy159() } finally { lock.unlock() }
    }
    func install159(value: RunModelLaneChange): Unit {
        lock.lock()
        try {
            if (change.isSome() || closed) { throw IllegalStateException("safe-cut input was already installed") }
            change = Some(value)
        } finally { lock.unlock() }
    }
    func change159(): RunModelLaneChange { change.getOrThrow() }
    public func recordSqlCommitReturned159(): Unit {
        lock.lock(); try { if (!closed) { sqlReturned = true } } finally { lock.unlock() }
    }
    // Called outside the complete coordinator/transition/SQLite helper frame.
    // Clearing a live callback or a generic ThreadCommitSink is never enough.
    func returnConsumerFrame159(): Unit {
        let detached = clearConsumerFrame159()
        match (detached) {
            case Some(values) =>
                modelLaneReturnedPayments159(values[0].detachReturnedFrame159())
                modelLaneReturnedPayments159(values[1].detachReturnedFrame159())
            case None => ()
        }
    }
    private func clearConsumerFrame159(): ?(OwnedModelLaneSnapshot159, OwnedModelLaneSnapshot159) {
        lock.lock()
        try {
            if (closed || !sqlReturned) { return None<(OwnedModelLaneSnapshot159, OwnedModelLaneSnapshot159)> }
            change.getOrThrow().clearOwnedCutLink159()
            change = None<RunModelLaneChange>
            let result = (previous.getOrThrow(), next.getOrThrow())
            previous = None<OwnedModelLaneSnapshot159>; next = None<OwnedModelLaneSnapshot159>
            result[0].recordSqlCommitReturned159(); result[1].recordSqlCommitReturned159()
            closed = true; ownedModelLaneCuts159.remove159(this)
            Some(result)
        } finally { lock.unlock() }
    }
}
private class OwnedModelLaneCuts159 {
    private let lock = Mutex()
    private var first: ?OwnedModelLaneCut159 = None<OwnedModelLaneCut159>
    func retain159(value: OwnedModelLaneCut159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: OwnedModelLaneCut159): Unit {
        lock.lock()
        try {
            var prior: ?OwnedModelLaneCut159 = None<OwnedModelLaneCut159>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (prior) { case Some(parent) => parent.next159 = current.next159; case None => first = current.next159 }
                    current.next159 = None<OwnedModelLaneCut159>; return
                }
                prior = cursor; cursor = current.next159
            }
        } finally { lock.unlock() }
    }
}
