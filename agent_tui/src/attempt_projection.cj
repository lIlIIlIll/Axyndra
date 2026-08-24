package agent_tui

import std.collection.*
import std.deriving.*

@Derive[Equatable]
public enum AttemptProjectionLifecycle {
    Streaming | Failed | Cancelled | Aborted | Committed
}

public class AttemptProjectionEntry {
    public let runId: String
    public let semanticRequestId: String
    public let attemptId: String
    public var lifecycle: AttemptProjectionLifecycle
    public var lastSequence: Int64
    public init(scope: TuiAttemptScope) {
        runId = scope.runId
        semanticRequestId = scope.semanticRequestId
        attemptId = scope.attemptId
        lifecycle = AttemptProjectionLifecycle.Streaming
        lastSequence = scope.sequence
    }
}

// UI-only projection. It never becomes a correctness source: canonical
// ThreadItems replace it on resync and a terminal Attempt rejects late deltas.
public class AttemptProjection {
    private let entries = ArrayList<AttemptProjectionEntry>()

    public func start(scope: TuiAttemptScope): Unit {
        for (entry in entries where entry.semanticRequestId == scope.semanticRequestId &&
            entry.lifecycle == AttemptProjectionLifecycle.Streaming &&
            entry.lastSequence >= scope.sequence) {
            return
        }
        for (entry in entries where entry.semanticRequestId == scope.semanticRequestId &&
            entry.lifecycle == AttemptProjectionLifecycle.Streaming &&
            entry.attemptId != scope.attemptId) {
            entry.lifecycle = AttemptProjectionLifecycle.Aborted
        }
        match (find(scope.attemptId)) {
            case Some(entry) => if (scope.sequence > entry.lastSequence) {
                entry.lastSequence = scope.sequence
            }
            case None => entries.add(AttemptProjectionEntry(scope))
        }
    }

    public func accept(scope: TuiAttemptScope): Bool {
        match (find(scope.attemptId)) {
            case Some(entry) =>
                if (entry.lifecycle != AttemptProjectionLifecycle.Streaming ||
                    scope.sequence <= entry.lastSequence) { return false }
                entry.lastSequence = scope.sequence
                true
            case None => false
        }
    }

    public func fail(scope: TuiAttemptScope): Unit { terminal(scope, AttemptProjectionLifecycle.Failed) }
    public func cancel(scope: TuiAttemptScope): Unit { terminal(scope, AttemptProjectionLifecycle.Cancelled) }
    public func abort(scope: TuiAttemptScope): Unit { terminal(scope, AttemptProjectionLifecycle.Aborted) }
    public func commit(scope: TuiAttemptScope): Unit { terminal(scope, AttemptProjectionLifecycle.Committed) }

    public func activeAttemptId(semanticRequestId: String): String {
        for (entry in entries where entry.semanticRequestId == semanticRequestId &&
            entry.lifecycle == AttemptProjectionLifecycle.Streaming) { return entry.attemptId }
        ""
    }

    public func lifecycle(attemptId: String): ?AttemptProjectionLifecycle {
        match (find(attemptId)) {
            case Some(entry) => Some(entry.lifecycle)
            case None => None
        }
    }

    private func terminal(scope: TuiAttemptScope, lifecycle: AttemptProjectionLifecycle): Unit {
        match (find(scope.attemptId)) {
            case Some(entry) =>
                if (scope.sequence >= entry.lastSequence) {
                    entry.lastSequence = scope.sequence
                    entry.lifecycle = lifecycle
                }
            case None => ()
        }
    }

    private func find(attemptId: String): ?AttemptProjectionEntry {
        for (entry in entries where entry.attemptId == attemptId) { return Some(entry) }
        None
    }
}
