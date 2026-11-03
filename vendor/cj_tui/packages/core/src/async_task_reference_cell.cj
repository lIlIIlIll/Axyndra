package core

import std.sync.*

// Tracks the actual callable, not Future.cancel()/get() as a lifetime ACK.
// A pending cancelled Future can keep this empty cell but no Screen closure.
class AsyncTaskReferenceCell {
    private let lock = Mutex()
    private var body: ?(() -> Event)
    private var borrowed = false
    private var closed = false
    private var notifierFrameEnded = false
    private var retirementWaitingOnNotifier = false
    init(body: () -> Event) { this.body = Some(body) }
    func run(): Event {
        lock.lock()
        if (closed) { lock.unlock(); return Event.Message("async:references-closed") }
        borrowed = true; lock.unlock()
        try { runBorrowedBodyFrame() }
        finally { lock.lock(); try { body = None; borrowed = false } finally { lock.unlock() } }
    }
    private func runBorrowedBodyFrame(): Event { let actual = body.getOrThrow(); actual() }
    func beginClosing(): Unit {
        lock.lock(); try { closed = true; if (!borrowed) { body = None } } finally { lock.unlock() }
    }
    func noteNotifierFrameEnded(): Unit {
        lock.lock(); try { notifierFrameEnded = true } finally { lock.unlock() } }
    func noteActualRetirementWaitingOnNotifier(waiting: Bool): Unit {
        lock.lock(); try { retirementWaitingOnNotifier = waiting } finally { lock.unlock() } }
    func actualRetirementWaitingOnNotifier(): Bool {
        lock.lock(); try { retirementWaitingOnNotifier } finally { lock.unlock() } }
    func actualNotifierFrameEnded(): Bool {
        lock.lock(); try { notifierFrameEnded } finally { lock.unlock() } }
    func referencesRetired(): Bool {
        lock.lock(); try { closed && !borrowed && body.isNone() } finally { lock.unlock() } }
}

// Only this runtime's callable and actual notifier borrow frames, plus its
// stored Future/Event references, after those fields really clear. Returned
// Events, SDK task metadata/capacity and inherited Screen data have separate
// lifetimes and payment. This witness grants no bank, Source or output ACK.
public class RetiredAsyncTaskReferences {
    private init() {}
    public static func retire(runtime: AsyncRuntime): RetiredAsyncTaskReferences {
        runtime.retireTaskReferences(); RetiredAsyncTaskReferences() }
    public func callableReferencesRetired(): Bool { true }
    public func notifierAndRuntimeResultReferencesRetired(): Bool { true }
}
