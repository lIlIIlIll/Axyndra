package process4cj

import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private func cancellationEntered159(value: AtomicBool): Bool {
    let started = MonoTime.now()
    while (!value.load() && MonoTime.now() - started < Duration.second * 5) {
        sleep(Duration.millisecond)
    }
    value.load()
}

@Test
class ActualCancellationReturn159Tests {
    @TestCase
    func disposalBeforeSnapshotRemovesTheActualCallbackWithoutInventingLegacyReceipt159(): Unit {
        let source = CancellationSource()
        let invoked = AtomicBool(false)
        let returned = source.token.onCancelReturning159({ _ => invoked.store(true) })
        let ordinary = source.token.onCancel({ _ => () })
        @Expect(returned.callbacksReturned159(), false)
        returned.dispose(); ordinary.dispose()
        @Expect(returned.callbacksReturned159(), true)
        @Expect(ordinary.callbacksReturned159(), false)
        @Expect(source.cancel(), true)
        @Expect(invoked.load(), false)
        @Expect(source.cancel(), false)
        source.close()
    }

    @TestCase
    func copiedButNotInvokedCallbackRemainsPendingAfterDisposeUntilActualFutureReturns159(): Unit {
        let source = CancellationSource()
        let entered = AtomicBool(false); let release = AtomicBool(false)
        let invoked = AtomicBool(false)
        // The original ordered snapshot copies both callbacks before this
        // first actual callback blocks. The second has not begun executing.
        let first = source.token.onCancel({ _ =>
            entered.store(true)
            while (!release.load()) { sleep(Duration.millisecond) }
        })
        let second = source.token.onCancelReturning159({ _ => invoked.store(true) })
        let worker = spawn { source.cancel() }
        try {
            @Expect(cancellationEntered159(entered), true)
            @Expect(invoked.load(), false)
            second.dispose()
            @Expect(second.callbacksReturned159(), false)
            // Preserve the original semantics: disposal cannot retract a
            // callback that the real cancellation snapshot already copied.
            release.store(true)
            @Expect(worker.get(), true)
            @Expect(invoked.load(), true)
            @Expect(second.callbacksReturned159(), true)
            @Expect(source.cancel(), false)
        } finally {
            release.store(true)
            let _ = worker.get()
            first.dispose(); second.dispose(); source.close()
        }
    }

    @TestCase
    func actualExecutingThrowingAndImmediateCallbacksKeepOriginalSingleDelivery159(): Unit {
        let source = CancellationSource()
        let entered = AtomicBool(false); let release = AtomicBool(false)
        let returned = source.token.onCancelReturning159({ _ =>
            entered.store(true)
            while (!release.load()) { sleep(Duration.millisecond) }
            throw IllegalStateException("actual cancellation callback error")
        })
        let worker = spawn { source.cancel() }
        try {
            @Expect(cancellationEntered159(entered), true)
            returned.dispose()
            @Expect(returned.callbacksReturned159(), false)
            release.store(true)
            @Expect(worker.get(), true)
            @Expect(returned.callbacksReturned159(), true)
            let immediate = AtomicBool(false)
            let later = source.token.onCancelReturning159({ _ => immediate.store(true) })
            @Expect(immediate.load(), true)
            @Expect(later.callbacksReturned159(), true)
            @Expect(source.cancel(), false)
            later.dispose()
        } finally {
            release.store(true)
            let _ = worker.get()
            returned.dispose(); source.close()
        }
    }
}
