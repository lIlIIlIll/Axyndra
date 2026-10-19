package agent_domain

import std.sync.*
import std.time.*

private let hookKernelMonitorFactory159n = HookKernelMonitorFactory159n()

// A powerless DATA ticket. The caller funds its node and both actions from
// the original input phase before calling the factory. Only concrete Hook
// composition installs the short poll and the existing cancellation action.
public class HookKernelMonitor159n {
    private let id: Int64
    private let pump: HookKernelMonitorPump159n
    init(id: Int64, pump: HookKernelMonitorPump159n) { this.id = id; this.pump = pump }
    public func awaitReturned159n(): Unit { pump.awaitReturned159n(id) }
}

public func createHookKernelMonitor159n(payer: LogicalJsonOwnerReservation,
    poll: () -> Int64, cancel: () -> Unit): HookKernelMonitor159n {
    hookKernelMonitorFactory159n.acquire159n(payer).add159n(poll, cancel)
}

private class HookKernelMonitorFactory159n {
    private let lock = Mutex()
    private var value: ?HookKernelMonitorPump159n = None<HookKernelMonitorPump159n>
    private var constructing: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func acquire159n(payer: LogicalJsonOwnerReservation): HookKernelMonitorPump159n {
        lock.lock()
        try {
            match (value) { case Some(actual) => return actual; case None => () }
            if (constructing.isSome()) { throw IllegalStateException("Hook kernel construction remains held") }
            let fixed = payer.deriveRetainedLease()
            try { fixed.ensureRetainedPeak(262144) }
            catch (error: Exception) { fixed.close(); throw error }
            // Register the entire fixed resident before the first spawn. A
            // partial startup is retained and never retried with more Futures.
            constructing = Some(fixed)
            let actual = HookKernelMonitorPump159n(fixed)
            value = Some(actual); constructing = None<LogicalJsonOwnerReservation>
            actual.start159n()
            actual
        } finally { lock.unlock() }
    }
}

class HookKernelMonitorPump159n {
    private let fixed: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var first: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
    private var nextId: Int64 = 1
    private var lastPollId: Int64 = 0
    private var lastCancelId: Int64 = 0
    private var pollRoundEnd: Int64 = 0
    private var cancelRoundEnd: Int64 = 0
    private var started = false
    private var startupFailed = false
    private var pollTask: ?Future<Unit> = None<Future<Unit>>
    private var cancelTasks: ?Array<?Future<Unit>> = None<Array<?Future<Unit>>>
    init(fixed: LogicalJsonOwnerReservation) { this.fixed = fixed }
    func start159n(): Unit {
        lock.lock()
        try {
            if (started || startupFailed) { throw IllegalStateException("Hook kernel monitor already started") }
            cancelTasks = Some(Array<?Future<Unit>>(8, repeat: None<Future<Unit>>))
            try {
                pollTask = Some(spawn { runPollPump159n() })
                for (index in 0..8) { cancelTasks.getOrThrow()[index] = Some(spawn { runCancelPump159n() }) }
                started = true
            } catch (error: Exception) { startupFailed = true; throw error }
        } finally { lock.unlock() }
    }
    func add159n(poll: () -> Int64, cancel: () -> Unit): HookKernelMonitor159n {
        lock.lock()
        try {
            if (!started || startupFailed || nextId == Int64.Max) {
                throw IllegalStateException("Hook kernel monitor is unavailable")
            }
            let id = nextId; nextId++
            let actual = HookKernelMonitorNode159n(id)
            actual.next = first; first = Some(actual)
            actual.poll = Some(poll); actual.cancel = Some(cancel)
            HookKernelMonitor159n(id, this)
        } finally { lock.unlock() }
    }
    private func runPollPump159n(): Unit {
        while (true) {
            // This helper owns every dynamic node/action local. Its scalar
            // result crosses the boundary only after that entire frame ends.
            let completed = runOnePollFrame159n()
            if (completed[0] != 0) {
                lock.lock()
                try { finishPollFrame159n(completed[0], completed[1]) }
                finally { lock.unlock() }
            }
            sleep(Duration.millisecond)
        }
    }
    private func runOnePollFrame159n(): (Int64, Int64) {
        var selected: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
        lock.lock()
        try { selected = selectPollFrame159n(agentUtcMillis()) }
        finally { lock.unlock() }
        match (selected) {
            case None => (0, 0)
            case Some(actual) =>
                let status = try { actual.poll.getOrThrow()() }
                    catch (error: Exception) {
                        lock.lock(); try { actual.error = Some(error) } finally { lock.unlock() }
                        3
                    }
                (actual.id, status)
        }
    }
    // Traversal locals must leave this entire helper while the table is
    // still locked. Only the chosen, busy node crosses the unlock boundary.
    // Choose the next increasing identity, then wrap, without copied arrays.
    private func selectPollFrame159n(now: Int64): ?HookKernelMonitorNode159n {
        var after: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
        var wrapped: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
        var cursor = first
        while (cursor.isSome()) {
            let actual = cursor.getOrThrow()
            if (!actual.busy && !actual.queued && !actual.returned && !actual.failed && actual.nextPollMillis <= now) {
                if (wrapped.isNone() || actual.id < wrapped.getOrThrow().id) { wrapped = Some(actual) }
                if (actual.id > lastPollId && actual.id <= pollRoundEnd && (after.isNone() || actual.id < after.getOrThrow().id)) { after = Some(actual) }
            }
            cursor = actual.next
        }
        if (after.isNone()) { pollRoundEnd = nextId - 1 }
        let selected = if (after.isSome()) { after } else { wrapped }
        match (selected) {
            case Some(actual) => actual.busy = true; actual.nextPollMillis = now + 10; lastPollId = actual.id
            case None => ()
        }
        selected
    }
    private func finishPollFrame159n(id: Int64, status: Int64): Unit {
        let actual = find159n(id)
        if (!actual.busy || actual.returned) { throw IllegalStateException("Hook poll frame was not entered") }
        actual.busy = false
        if (status == 0) { return }
        if (status == 1) { clearActionsFrame159n(actual); actual.returned = true; return }
        if (status == 2) { actual.queued = true; return }
        actual.failed = true
        // An exceptional callback remains reachable and paid. No error flag
        // is treated as a private-input or cancellation return acknowledgement.
    }
    private func runCancelPump159n(): Unit {
        while (true) {
            let completed = runOneCancelFrame159n()
            if (completed[0] != 0) {
                lock.lock()
                try { finishCancelFrame159n(completed[0], completed[1]) }
                finally { lock.unlock() }
            }
            sleep(Duration.millisecond)
        }
    }
    private func runOneCancelFrame159n(): (Int64, Int64) {
        var selected: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
        lock.lock()
        try { selected = selectCancelFrame159n() }
        finally { lock.unlock() }
        match (selected) {
            case None => (0, 0)
            case Some(actual) =>
                let status = try { actual.cancel.getOrThrow()(); 1 }
                    catch (error: Exception) {
                        lock.lock(); try { actual.error = Some(error) } finally { lock.unlock() }
                        3
                    }
                (actual.id, status)
        }
    }
    private func selectCancelFrame159n(): ?HookKernelMonitorNode159n {
        var after: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
        var wrapped: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
        var cursor = first
        while (cursor.isSome()) {
            let actual = cursor.getOrThrow()
            if (actual.queued && !actual.busy && !actual.returned && !actual.failed) {
                if (wrapped.isNone() || actual.id < wrapped.getOrThrow().id) { wrapped = Some(actual) }
                if (actual.id > lastCancelId && actual.id <= cancelRoundEnd && (after.isNone() || actual.id < after.getOrThrow().id)) { after = Some(actual) }
            }
            cursor = actual.next
        }
        if (after.isNone()) { cancelRoundEnd = nextId - 1 }
        let selected = if (after.isSome()) { after } else { wrapped }
        match (selected) { case Some(actual) => actual.busy = true; lastCancelId = actual.id; case None => () }
        selected
    }
    private func finishCancelFrame159n(id: Int64, status: Int64): Unit {
        let actual = find159n(id)
        if (!actual.busy || !actual.queued || actual.returned) { throw IllegalStateException("Hook cancellation frame was not entered") }
        actual.busy = false
        if (status == 1) { clearActionsFrame159n(actual); actual.queued = false; actual.returned = true }
        else { actual.failed = true }
    }
    private func clearActionsFrame159n(actual: HookKernelMonitorNode159n): Unit {
        actual.poll = None<() -> Int64>; actual.cancel = None<() -> Unit>
    }
    func awaitReturned159n(id: Int64): Unit {
        while (true) {
            lock.lock()
            let returned = try { collectReturnedFrame159n(id) } finally { lock.unlock() }
            if (returned) { return }
            sleep(Duration.millisecond)
        }
    }
    private func collectReturnedFrame159n(id: Int64): Bool {
        let actual = find159n(id)
        if (actual.failed) {
            match (actual.error) { case Some(error) => throw error; case None => throw IllegalStateException("Hook monitor callback failed") }
        }
        if (!actual.returned || actual.busy || actual.queued || actual.poll.isSome() || actual.cancel.isSome()) { return false }
        var previous: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
        var cursor = first
        while (cursor.isSome()) {
            let current = cursor.getOrThrow()
            if (refEq(current, actual)) {
                match (previous) { case Some(prior) => prior.next = current.next; case None => first = current.next }
                current.next = None<HookKernelMonitorNode159n>; return true
            }
            previous = cursor; cursor = current.next
        }
        throw IllegalStateException("Hook monitor was not registered")
    }
    private func find159n(id: Int64): HookKernelMonitorNode159n {
        var cursor = first
        while (cursor.isSome()) { let actual = cursor.getOrThrow(); if (actual.id == id) { return actual }; cursor = actual.next }
        throw IllegalStateException("Hook monitor identity is unavailable")
    }
}
class HookKernelMonitorNode159n {
    let id: Int64
    var next: ?HookKernelMonitorNode159n = None<HookKernelMonitorNode159n>
    var poll: ?() -> Int64 = None<() -> Int64>
    var cancel: ?() -> Unit = None<() -> Unit>
    var error: ?Exception = None<Exception>
    var nextPollMillis: Int64 = 0
    var busy = false
    var queued = false
    var returned = false
    var failed = false
    init(id: Int64) { this.id = id }
}
