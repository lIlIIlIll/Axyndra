package agent_host_runtime

import agent_domain.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// Scope-only regressions: actual cancellation callbacks and disposal, never a
// fabricated Root, approval, process release or canonical receipt.
@Test
class HostLifecycleStartupScopeTests {
    @TestCase
    func activeCallerCancellationRevokesBeforeScopeReturnsExactlyOnce(): Unit {
        let source = CancellationSource()
        let revocations = AtomicInt64(0)
        let scope = HostLifecycleIoScope(0, { => let _ = revocations.fetchAdd(1) })
        try {
            scope.arm(source.token)
            let _ = source.cancel()
            @Expect(revocations.load(), 1)
            @Expect(scope.isCancelled(), true)
            let _ = source.cancel()
            @Expect(revocations.load(), 1)
            @Expect(scope.finish(), true)
            @Expect(scope.finish(), true)
        } finally { let _ = scope.finish(); source.close() }
    }

    @TestCase
    func alreadyCancelledCallerIsObservedBeforeDirectoryAdmission(): Unit {
        let source = CancellationSource()
        let _ = source.cancel()
        let revocations = AtomicInt64(0)
        let scope = HostLifecycleIoScope(0, { => let _ = revocations.fetchAdd(1) })
        try {
            scope.arm(source.token)
            @Expect(revocations.load(), 1)
            @Expect(scope.finish(), true)
        } finally { let _ = scope.finish(); source.close() }
    }

    @TestCase
    func expiredOriginalDeadlineRevokesWithoutExtendingStartup(): Unit {
        let source = CancellationSource()
        let revocations = AtomicInt64(0)
        let scope = HostLifecycleIoScope(agentUtcMillis() - 1, { => let _ = revocations.fetchAdd(1) })
        try {
            scope.arm(source.token)
            @Expect(revocations.load(), 1)
            scope.checkDeadline()
            @Expect(revocations.load(), 1)
            @Expect(scope.finish(), true)
        } finally { let _ = scope.finish(); source.close() }
    }

    @TestCase
    func successfulReturnDisposesTheCallerLinkBeforeLaterCancellation(): Unit {
        let source = CancellationSource()
        let revocations = AtomicInt64(0)
        let scope = HostLifecycleIoScope(0, { => let _ = revocations.fetchAdd(1) })
        try {
            scope.arm(source.token)
            @Expect(scope.finish(), false)
            let _ = source.cancel()
            @Expect(revocations.load(), 0)
            @Expect(scope.finish(), false)
        } finally { let _ = scope.finish(); source.close() }
    }
}
