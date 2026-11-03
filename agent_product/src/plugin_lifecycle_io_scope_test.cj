package agent_product

import agent_domain.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

class LifecycleIoScopeTestHolder {
    var value: ?ProductLifecycleIoScope = None
}

@Test
class ProductLifecycleIoScopeTests {
    @TestCase
    func completedCallDoesNotRetainItsCancellationIntoLaterCalls() {
        let old = CancellationSource()
        let next = CancellationSource()
        let cancelled = AtomicInt64(0)
        let previous = ProductLifecycleIoScope(0, { => let _ = cancelled.fetchAdd(1) })
        previous.arm(old.token)
        @Expect(previous.finish(), false)
        let current = ProductLifecycleIoScope(0, { => let _ = cancelled.fetchAdd(1) })
        current.arm(next.token)
        let _ = old.cancel()
        @Expect(cancelled.load(), 0)
        @Expect(current.isCancelled(), false)
        let _ = next.cancel()
        @Expect(cancelled.load(), 1)
        @Expect(current.finish(), true)
        old.close(); next.close()
    }

    @TestCase
    func cancellationActionMayReenterScopeWithoutHoldingTheScopeLock() {
        let source = CancellationSource()
        let entered = AtomicInt64(0)
        let finished = AtomicBool(false)
        let captured = LifecycleIoScopeTestHolder()
        let scope = ProductLifecycleIoScope(0, { =>
            let _ = entered.fetchAdd(1)
            finished.store(captured.value.getOrThrow().finish())
        })
        captured.value = Some(scope)
        scope.arm(source.token)
        let _ = source.cancel()
        @Expect(entered.load(), 1)
        @Expect(finished.load(), true)
        @Expect(scope.finish(), true)
        source.close()
    }

    @TestCase
    func expiredDeadlineCancelsOnceButCannotRevokeAfterScopeCompletion() {
        let source = CancellationSource()
        let cancelled = AtomicInt64(0)
        let scope = ProductLifecycleIoScope(agentUtcMillis() - 1, { => let _ = cancelled.fetchAdd(1) })
        scope.arm(source.token)
        scope.checkDeadline(); scope.checkDeadline()
        @Expect(cancelled.load(), 1)
        @Expect(scope.finish(), true)
        let closed = ProductLifecycleIoScope(agentUtcMillis() - 1, { => let _ = cancelled.fetchAdd(1) })
        @Expect(closed.finish(), false)
        closed.arm(source.token); closed.checkDeadline()
        @Expect(cancelled.load(), 1)
        source.close()
    }
}
