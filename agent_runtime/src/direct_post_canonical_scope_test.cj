package agent_runtime

import agent_domain.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

private class DirectProjectionScopeGate113 {
    let lock = Mutex()
    let changed: Condition
    var released = false
    init() { changed = synchronized(lock) { lock.condition() } }
    func wait(): Unit {
        lock.lock(); try { while (!released) { changed.wait() } } finally { lock.unlock() }
    }
    func release(): Unit {
        lock.lock(); try { released = true; changed.notifyAll() } finally { lock.unlock() }
    }
}

// Real original RunScope/Future completion; no DTO claims cleanup or Source.
@Test
class DirectPostCanonicalScope113Tests {
    @TestCase
    func actualPendingFutureCannotEnterProjectionBeforePhysicalJoin(): Unit {
        let scope = RunScope(); let gate = DirectProjectionScopeGate113(); let calls = AtomicInt64(0)
        let future = spawn { gate.wait() }
        let joined = scope.ownWithJoin("direct-projection-physical1138", future).value().getOrThrow()
        try {
            @Expect(scope.withSettledDataProjection({ => calls.fetchAdd(1); Result<Unit>.Ok(()) }).isError())
            @Expect(calls.load(), 0)
            gate.release(); @Expect(joined().isOk())
            @Expect(scope.withSettledDataProjection({ => calls.fetchAdd(1); Result<Unit>.Ok(()) }).isOk())
            @Expect(calls.load(), 1)
        } finally { gate.release(); let _ = joined(); let _ = scope.join(1000) }
    }

    @TestCase
    func actualFailedFutureKeepsProjectionClosedAfterJoin(): Unit {
        let scope = RunScope(); let calls = AtomicInt64(0)
        let future: Future<Unit> = spawn {
            if (true) { throw IllegalStateException("physical cleanup failed1138") }
            ()
        }
        let joined = scope.ownWithJoin("direct-projection-failed1138", future).value().getOrThrow()
        try {
            @Expect(joined().isError())
            @Expect(scope.withSettledDataProjection({ => calls.fetchAdd(1); Result<Unit>.Ok(()) }).isError())
            @Expect(calls.load(), 0)
        } finally { let report = scope.join(1000); @Expect(report.failedCount(), 1) }
    }

    @TestCase
    func cancelledActualScopeCannotEnterAnyProjectionCallback(): Unit {
        let scope = RunScope(); let calls = AtomicInt64(0)
        @Expect(scope.cancel())
        try {
            @Expect(scope.withSettledDataProjection({ => calls.fetchAdd(1); Result<Unit>.Ok(()) }).isError())
            @Expect(calls.load(), 0)
        } finally { let _ = scope.join(1000) }
    }
}
