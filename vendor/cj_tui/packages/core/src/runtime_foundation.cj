package core

import std.collection.*
import std.sync.*
import std.time.*

@FastNative
@When[os == "Windows"]
foreign func CreateEventW(attributes: CPointer<Unit>, manualReset: Int32, initialState: Int32, name: CPointer<UInt16>): CPointer<Unit>

@FastNative
@When[os == "Windows"]
foreign func SetEvent(handle: CPointer<Unit>): Int32

@FastNative
@When[os == "Windows"]
foreign func ResetEvent(handle: CPointer<Unit>): Int32

@FastNative
@When[os == "Windows"]
foreign func CloseHandle(handle: CPointer<Unit>): Int32

public enum RuntimeState {
    | Running
    | Closing
    | Closed
}

// Producer-visible outcome. Accepted is admission into a running port with any
// required wake published; it is not App.update completion or durable delivery.
public enum ExternalEnqueueResult {
    | Accepted
    | Full
    | Closed
}

// Immutable identity for an owner lifetime. A slot may be reused, but never
// with the same generation.
public struct OwnerToken <: Equatable<OwnerToken> {
    public let slot: Int64
    public let generation: Int64

    public init(slot: Int64, generation: Int64) {
        this.slot = max(0, slot)
        this.generation = max(1, generation)
    }

    public operator func ==(other: OwnerToken): Bool {
        slot == other.slot && generation == other.generation
    }

    public operator func !=(other: OwnerToken): Bool { !(this == other) }
}

// Operation identity is intentionally independent from owner identity.
public struct OperationId <: Equatable<OperationId> {
    public let value: Int64

    public init(value: Int64) { this.value = max(1, value) }
    public operator func ==(other: OperationId): Bool { value == other.value }
    public operator func !=(other: OperationId): Bool { value != other.value }
}

public enum OperationState {
    | Running
    | CancelRequested
    | Settled
}

public class OwnerRegistry {
    private let generations = ArrayList<Int64>()
    private let live = ArrayList<Bool>()

    public init() {}

    public func acquire(slot: Int64): OwnerToken {
        let index = max(0, slot)
        while (generations.size <= index) {
            generations.add(0)
            live.add(false)
        }
        generations[index]++
        live[index] = true
        OwnerToken(index, generations[index])
    }

    public func release(token: OwnerToken): Bool {
        if (!isCurrent(token)) { return false }
        live[token.slot] = false
        true
    }

    public func isCurrent(token: OwnerToken): Bool {
        token.slot >= 0 && token.slot < generations.size &&
            live[token.slot] && generations[token.slot] == token.generation
    }
}

public class OperationRecord {
    public let id: OperationId
    public let owner: OwnerToken
    private var current: OperationState = OperationState.Running

    public init(id: OperationId, owner: OwnerToken) {
        this.id = id
        this.owner = owner
    }

    public func state(): OperationState { current }

    public func requestCancel(): Bool {
        match (current) {
            case OperationState.Running =>
                current = OperationState.CancelRequested
                true
            case _ => false
        }
    }

    public func settle(): Bool {
        match (current) {
            case OperationState.Settled => false
            case _ =>
                current = OperationState.Settled
                true
        }
    }
}

public struct OwnedAsyncCompletion {
    public let owner: OwnerToken
    public let operation: OperationId
    public let event: Event

    public init(owner: OwnerToken, operation: OperationId, event: Event) {
        this.owner = owner
        this.operation = operation
        this.event = event
    }
}

public enum CompletionDisposition {
    | Applied
    | Orphan
    | Duplicate
}

// UI-thread lifecycle validator for structured async completions. Cancellation
// only changes an operation state; it never makes owner validation optional.
public class AsyncOwnershipRuntime {
    private let owners = OwnerRegistry()
    private let operations = ArrayList<OperationRecord>()
    private var nextOperation: Int64 = 1
    private var orphanValue: Int64 = 0

    public init() {}

    public func acquireOwner(slot: Int64): OwnerToken { owners.acquire(slot) }
    public func releaseOwner(owner: OwnerToken): Bool { owners.release(owner) }

    public func start(owner: OwnerToken): ?OperationId {
        if (!owners.isCurrent(owner)) { return None }
        let id = OperationId(nextOperation)
        nextOperation++
        operations.add(OperationRecord(id, owner))
        Some(id)
    }

    public func requestCancel(operation: OperationId): Bool {
        match (find(operation)) {
            case Some(record) => record.requestCancel()
            case None => false
        }
    }

    public func complete(completion: OwnedAsyncCompletion): CompletionDisposition {
        match (find(completion.operation)) {
            case Some(record) =>
                if (record.owner != completion.owner || !owners.isCurrent(completion.owner)) {
                    _ = record.settle()
                    orphanValue++
                    return CompletionDisposition.Orphan
                }
                if (!record.settle()) { return CompletionDisposition.Duplicate }
                CompletionDisposition.Applied
            case None =>
                orphanValue++
                CompletionDisposition.Orphan
        }
    }

    public func orphanCompletions(): Int64 { orphanValue }

    private func find(id: OperationId): ?OperationRecord {
        for (record in operations) {
            if (record.id == id) { return Some(record) }
        }
        None
    }
}

public enum RuntimeEnvelope<A> {
    | EventItem(Event)
    | ExternalItem(A)
    | QuitItem
}

public struct SequencedRuntimeItem<A> {
    public let sequence: Int64
    public let envelope: RuntimeEnvelope<A>
    public let enqueuedAtMillis: Int64

    public init(sequence: Int64, envelope: RuntimeEnvelope<A>, enqueuedAtMillis!: Int64 = 0) {
        this.sequence = max(1, sequence)
        this.envelope = envelope
        this.enqueuedAtMillis = max(0, enqueuedAtMillis)
    }
}

// Single-consumer FIFO. Producers never access this queue directly; external
// producers use ExternalPort and the runtime imports immutable actions.
public class RuntimeQueue<A> {
    private let items = ArrayList<SequencedRuntimeItem<A>>()
    private var readIndex: Int64 = 0
    private var nextSequence: Int64 = 1
    private var stateValue: RuntimeState = RuntimeState.Running
    private var updateDepth: Int64 = 0
    private var processedValue: Int64 = 0
    private var maximumUpdateDepth: Int64 = 0
    private var maximumDepth: Int64 = 0
    private let metrics: ?AppMetrics

    public init(metrics!: ?AppMetrics = None) { this.metrics = metrics }

    public func state(): RuntimeState { stateValue }
    public func size(): Int64 { max(0, items.size - readIndex) }
    public func maxQueueDepth(): Int64 { maximumDepth }
    public func maxUpdateDepth(): Int64 { maximumUpdateDepth }
    public func processedCount(): Int64 { processedValue }

    public func enqueueEvent(event: Event, nowMillis!: Int64 = 0): ?Int64 {
        enqueue(RuntimeEnvelope<A>.EventItem(event), nowMillis)
    }

    public func enqueueExternal(action: A, nowMillis!: Int64 = 0): ?Int64 {
        enqueue(RuntimeEnvelope<A>.ExternalItem(action), nowMillis)
    }

    public func enqueueQuit(nowMillis!: Int64 = 0): ?Int64 {
        enqueue(RuntimeEnvelope<A>.QuitItem, nowMillis)
    }

    private func enqueue(envelope: RuntimeEnvelope<A>, nowMillis: Int64): ?Int64 {
        match (stateValue) {
            case RuntimeState.Running => ()
            case _ => return None
        }
        let sequence = nextSequence
        nextSequence++
        items.add(SequencedRuntimeItem<A>(sequence, envelope, enqueuedAtMillis: nowMillis))
        maximumDepth = max(maximumDepth, size())
        match (metrics) {
            case Some(value) => value.runtimeEnqueued(size())
            case None => ()
        }
        Some(sequence)
    }

    public func dequeue(): ?SequencedRuntimeItem<A> {
        if (readIndex >= items.size) {
            compact()
            return None
        }
        let item = items[readIndex]
        readIndex++
        if (readIndex >= 256 && readIndex * 2 >= items.size) { compact() }
        Some(item)
    }

    public func enterUpdate(): Unit {
        if (updateDepth != 0) {
            throw IllegalStateException("runtime update reentrancy")
        }
        updateDepth = 1
        processedValue++
        maximumUpdateDepth = max(maximumUpdateDepth, updateDepth)
        match (metrics) {
            case Some(value) => value.runtimeProcessed(updateDepth)
            case None => ()
        }
    }

    public func leaveUpdate(): Unit {
        if (updateDepth <= 0) { throw IllegalStateException("runtime update depth underflow") }
        updateDepth--
    }

    public func beginClosing(): Unit {
        match (stateValue) {
            case RuntimeState.Running => stateValue = RuntimeState.Closing
            case _ => ()
        }
    }

    public func close(discardPending!: Bool = true): Unit {
        beginClosing()
        if (discardPending) {
            items.clear()
            readIndex = 0
        }
        stateValue = RuntimeState.Closed
    }

    private func compact(): Unit {
        if (readIndex == 0) { return }
        if (readIndex >= items.size) {
            items.clear()
            readIndex = 0
            return
        }
        let remaining = ArrayList<SequencedRuntimeItem<A>>()
        for (i in readIndex..items.size) { remaining.add(items[i]) }
        items.clear()
        for (item in remaining) { items.add(item) }
        readIndex = 0
    }
}

public interface RuntimeClock {
    func nowMillis(): Int64
}

public class MonotonicRuntimeClock <: RuntimeClock {
    private let started = MonoTime.now()
    public init() {}
    public func nowMillis(): Int64 { max(0, (MonoTime.now() - started).toMilliseconds()) }
}

public class TestClock <: RuntimeClock {
    private var currentMillis: Int64
    public init(startMillis!: Int64 = 0) { currentMillis = max(0, startMillis) }
    public func nowMillis(): Int64 { currentMillis }
    public func advance(duration: Duration): Unit {
        currentMillis += max(0, duration.toMilliseconds())
    }
    public func advanceMillis(millis: Int64): Unit { currentMillis += max(0, millis) }
}

// Internal presentation policy. It deliberately knows nothing about Widget,
// application state, or event payloads: updates have already completed before
// a request reaches this state machine.
enum FrameRequestKind {
    | Background
    | Interactive
    | SurfaceCritical
}

public struct FrameSchedulingSnapshot {
    public let reason: String
    public let frameRequests: Int64
    public let framesPresented: Int64
    public let frameRequestsMerged: Int64
    public let frameDeadlineWakes: Int64
    public let pendingFramePromotions: Int64
    public let backgroundFrameRequests: Int64
    public let interactiveFrameRequests: Int64
    public let resizeFrameRequests: Int64
    public let updatesPerFrame: Int64
    public let dirtyRectsBeforeMerge: Int64
    public let dirtyRectsAfterMerge: Int64
    public let firstInvalidationToFrameMillis: Int64
    public let lastUpdateToFrameMillis: Int64
    public let frameDelayDueToCoalescingMillis: Int64
    public let framesAvoided: Int64

    public init(
        reason!: String = "none",
        frameRequests!: Int64 = 0,
        framesPresented!: Int64 = 0,
        frameRequestsMerged!: Int64 = 0,
        frameDeadlineWakes!: Int64 = 0,
        pendingFramePromotions!: Int64 = 0,
        backgroundFrameRequests!: Int64 = 0,
        interactiveFrameRequests!: Int64 = 0,
        resizeFrameRequests!: Int64 = 0,
        updatesPerFrame!: Int64 = 0,
        dirtyRectsBeforeMerge!: Int64 = 0,
        dirtyRectsAfterMerge!: Int64 = 0,
        firstInvalidationToFrameMillis!: Int64 = 0,
        lastUpdateToFrameMillis!: Int64 = 0,
        frameDelayDueToCoalescingMillis!: Int64 = 0,
        framesAvoided!: Int64 = 0
    ) {
        this.reason = reason
        this.frameRequests = max(0, frameRequests)
        this.framesPresented = max(0, framesPresented)
        this.frameRequestsMerged = max(0, frameRequestsMerged)
        this.frameDeadlineWakes = max(0, frameDeadlineWakes)
        this.pendingFramePromotions = max(0, pendingFramePromotions)
        this.backgroundFrameRequests = max(0, backgroundFrameRequests)
        this.interactiveFrameRequests = max(0, interactiveFrameRequests)
        this.resizeFrameRequests = max(0, resizeFrameRequests)
        this.updatesPerFrame = max(0, updatesPerFrame)
        this.dirtyRectsBeforeMerge = max(0, dirtyRectsBeforeMerge)
        this.dirtyRectsAfterMerge = max(0, dirtyRectsAfterMerge)
        this.firstInvalidationToFrameMillis = max(0, firstInvalidationToFrameMillis)
        this.lastUpdateToFrameMillis = max(0, lastUpdateToFrameMillis)
        this.frameDelayDueToCoalescingMillis = max(0, frameDelayDueToCoalescingMillis)
        this.framesAvoided = max(0, framesAvoided)
    }
}

// Immediate-first, rate-limited continuation policy. After an idle period the
// first background request is eligible immediately. Later background requests
// inside the budget share one fixed deadline; new requests never extend it.
// Interactive and surface-critical requests promote the pending frame.
class FrameCoalescingState {
    private let clock: RuntimeClock
    private let budgetMillis: Int64
    private var pendingValue: Bool = false
    private var readyValue: Bool = false
    private var deadlineMillis: Int64 = 0
    private var nextBackgroundEligibleMillis: Int64 = 0
    private var firstInvalidationMillis: Int64 = 0
    private var lastUpdateMillis: Int64 = 0
    private var reasonValue: String = "none"
    private var requestsSinceFrame: Int64 = 0
    private var backgroundSinceFrame: Bool = false
    private var dirtyBeforeSinceFrame: Int64 = 0
    private var totalRequests: Int64 = 0
    private var totalPresented: Int64 = 0
    private var totalMerged: Int64 = 0
    private var totalDeadlineWakes: Int64 = 0
    private var totalPromotions: Int64 = 0
    private var totalBackground: Int64 = 0
    private var totalInteractive: Int64 = 0
    private var totalResize: Int64 = 0

    init(budgetMillis: Int64, clock!: RuntimeClock = MonotonicRuntimeClock()) {
        this.budgetMillis = max(0, budgetMillis)
        this.clock = clock
    }

    func request(kind: FrameRequestKind, dirtyRectsBeforeMerge!: Int64 = 0): Unit {
        let now = clock.nowMillis()
        totalRequests++
        requestsSinceFrame++
        dirtyBeforeSinceFrame += max(0, dirtyRectsBeforeMerge)
        match (kind) {
            case FrameRequestKind.Background =>
                totalBackground++
                backgroundSinceFrame = true
            case FrameRequestKind.Interactive => totalInteractive++
            case FrameRequestKind.SurfaceCritical => totalResize++
        }
        if (!pendingValue) {
            pendingValue = true
            firstInvalidationMillis = now
            lastUpdateMillis = now
            match (kind) {
                case FrameRequestKind.Background =>
                    if (budgetMillis == 0 || now >= nextBackgroundEligibleMillis) {
                        readyValue = true
                        reasonValue = "background_immediate"
                    } else {
                        readyValue = false
                        deadlineMillis = nextBackgroundEligibleMillis
                        reasonValue = "background_deadline"
                    }
                case FrameRequestKind.Interactive =>
                    readyValue = true
                    reasonValue = "interactive"
                case FrameRequestKind.SurfaceCritical =>
                    readyValue = true
                    reasonValue = "resize"
            }
            return
        }

        totalMerged++
        lastUpdateMillis = now
        match (kind) {
            case FrameRequestKind.Background => ()
            case FrameRequestKind.Interactive =>
                if (!readyValue) { totalPromotions++ }
                readyValue = true
                reasonValue = "interactive_promotion"
            case FrameRequestKind.SurfaceCritical =>
                if (!readyValue) { totalPromotions++ }
                readyValue = true
                reasonValue = "resize"
        }
    }

    func readyToPresent(): Bool {
        if (!pendingValue) { return false }
        if (!readyValue && clock.nowMillis() >= deadlineMillis) {
            readyValue = true
            totalDeadlineWakes++
            reasonValue = "background_deadline"
        }
        readyValue
    }

    func nextWakeMillis(): ?Int64 {
        if (!pendingValue || readyValue) { return None }
        Some(max(0, deadlineMillis - clock.nowMillis()))
    }

    func presented(updatesPerFrame: Int64, dirtyRectsAfterMerge: Int64): FrameSchedulingSnapshot {
        if (!pendingValue || !readyToPresent()) {
            throw IllegalStateException("frame presented without an eligible request")
        }
        let now = clock.nowMillis()
        totalPresented++
        let firstDelay = max(0, now - firstInvalidationMillis)
        let lastDelay = max(0, now - lastUpdateMillis)
        let coalescingDelay = if (reasonValue == "background_deadline") { firstDelay } else { 0 }
        let snapshot = FrameSchedulingSnapshot(
            reason: reasonValue,
            frameRequests: totalRequests,
            framesPresented: totalPresented,
            frameRequestsMerged: totalMerged,
            frameDeadlineWakes: totalDeadlineWakes,
            pendingFramePromotions: totalPromotions,
            backgroundFrameRequests: totalBackground,
            interactiveFrameRequests: totalInteractive,
            resizeFrameRequests: totalResize,
            updatesPerFrame: updatesPerFrame,
            dirtyRectsBeforeMerge: dirtyBeforeSinceFrame,
            dirtyRectsAfterMerge: dirtyRectsAfterMerge,
            firstInvalidationToFrameMillis: firstDelay,
            lastUpdateToFrameMillis: lastDelay,
            frameDelayDueToCoalescingMillis: coalescingDelay,
            framesAvoided: max(0, totalRequests - totalPresented)
        )
        nextBackgroundEligibleMillis = if (backgroundSinceFrame) { now + budgetMillis } else { now }
        pendingValue = false
        readyValue = false
        deadlineMillis = 0
        firstInvalidationMillis = 0
        lastUpdateMillis = 0
        reasonValue = "none"
        requestsSinceFrame = 0
        backgroundSinceFrame = false
        dirtyBeforeSinceFrame = 0
        snapshot
    }

    func discard(): Unit {
        pendingValue = false
        readyValue = false
        deadlineMillis = 0
        firstInvalidationMillis = 0
        lastUpdateMillis = 0
        reasonValue = "none"
        requestsSinceFrame = 0
        backgroundSinceFrame = false
        dirtyBeforeSinceFrame = 0
    }
}

// The pipe is only a level-visible wake signal. Queue contents remain owned by
// the locked in-memory queue and are never serialized through the pipe.
@When[os != "Windows"]
class ExternalWakeSource <: EventSource {
    private let lock: Mutex
    private var readFd: Int32 = -1
    private var writeFd: Int32 = -1
    private var closed: Bool = false

    init(lock: Mutex) {
        this.lock = lock
        let fds = Array<Int32>(2, repeat: -1)
        var ok = false
        unsafe {
            let handle = acquireArrayRawData(fds)
            ok = pipe(CPointer<Int32>(handle.pointer)) == 0
            releaseArrayRawData(handle)
        }
        if (ok) {
            readFd = fds[0]
            writeFd = fds[1]
            _ = unsafe { fcntl(readFd, F_SETFL, fcntl(readFd, F_GETFL, 0) | O_NONBLOCK) }
            _ = unsafe { fcntl(writeFd, F_SETFL, fcntl(writeFd, F_GETFL, 0) | O_NONBLOCK) }
        }
    }

    public func id(): String { "runtime-external-wake" }
    public func fd(): ?Int32 { if (closed || readFd < 0) { None } else { Some(readFd) } }
    public func interests(): EventSourceInterest { EventSourceInterest.Read }
    public func onReady(readable: Bool, writable: Bool, error: Bool, hangup: Bool): Unit {
        if (writable && !readable && !error && !hangup) { return }
    }
    public func drain(): Array<Event> { [] }

    func signalLocked(): Bool {
        if (closed || writeFd < 0) { return false }
        let byte = Array<Byte>(1, repeat: 1)
        var written: IntNative = 0
        unsafe {
            let handle = acquireArrayRawData(byte)
            written = write(writeFd, CPointer<Unit>(handle.pointer), UIntNative(1))
            releaseArrayRawData(handle)
        }
        written == 1
    }

    func clearLocked(): Unit {
        if (closed || readFd < 0) { return }
        let bytes = Array<Byte>(64, repeat: 0)
        while (true) {
            var count: IntNative = 0
            unsafe {
                let handle = acquireArrayRawData(bytes)
                count = read(readFd, CPointer<Unit>(handle.pointer), UIntNative(bytes.size))
                releaseArrayRawData(handle)
            }
            if (count <= 0 || count < IntNative(bytes.size)) { return }
        }
    }

    func closeLocked(): Unit {
        if (closed) { return }
        if (readFd >= 0) { unsafe { _ = close(readFd) } }
        if (writeFd >= 0) { unsafe { _ = close(writeFd) } }
        readFd = -1
        writeFd = -1
        closed = true
    }

    public func close(): Unit {
        lock.lock()
        try { closeLocked() } finally { lock.unlock() }
    }
}

@When[os == "Windows"]
class ExternalWakeSource <: EventSource {
    private let handle: CPointer<Unit>
    private var closed: Bool = false

    public init(_: Mutex) {
        handle = unsafe { CreateEventW(CPointer<Unit>(), 1, 0, CPointer<UInt16>()) }
    }
    public func id(): String { "runtime-external-wake" }
    public func fd(): ?Int32 { None }
    public func waitHandle(): ?CPointer<Unit> { if (closed) { None } else { Some(handle) } }
    public func interests(): EventSourceInterest { EventSourceInterest.Read }
    public func onReady(readable: Bool, writable: Bool, error: Bool, hangup: Bool): Unit {}
    public func drain(): Array<Event> { [] }
    func signalLocked(): Bool { !closed && unsafe { SetEvent(handle) != 0 } }
    func clearLocked(): Unit { if (!closed) { unsafe { _ = ResetEvent(handle) } } }
    func closeLocked(): Unit {
        if (!closed) {
            unsafe { _ = CloseHandle(handle) }
            closed = true
        }
    }
    public func close(): Unit { closeLocked() }
}

struct ExternalPortEntry<A> {
    let action: A
    let acceptedAt: ?MonoTime
    init(action: A, acceptedAt: ?MonoTime) {
        this.action = action
        this.acceptedAt = acceptedAt
    }
}

// Bounded non-blocking ingress for the App runtime. The port stores A with
// ordinary Cangjie value/reference semantics and does not deep-copy payloads.
// Concurrent producer calls are mutex-linearized; close is idempotent and may
// discard accepted entries that the runtime has not imported yet.
public class ExternalPort<A> {
    private let lock = Mutex()
    private let values = ArrayList<ExternalPortEntry<A>>()
    private let capacityValue: Int64
    private var measureLatency: Bool = false
    private let wakeSource: ExternalWakeSource
    private var stateValue: RuntimeState = RuntimeState.Running
    private var acceptedValue: Int64 = 0
    private var fullValue: Int64 = 0
    private var closedValue: Int64 = 0
    private var wakeSignalsValue: Int64 = 0
    private var wakeCoalescedValue: Int64 = 0

    public init(capacity!: Int64 = 256) {
        if (capacity <= 0) { throw IllegalArgumentException("ExternalPort capacity must be positive") }
        capacityValue = capacity
        wakeSource = ExternalWakeSource(lock)
    }

    public func capacity(): Int64 { capacityValue }

    // Experimental diagnostics switch. Latency timestamps are not part of the
    // stable producer contract and must be enabled before producers enqueue.
    public func enableLatencyMeasurement(): Unit {
        lock.lock()
        try { measureLatency = true } finally { lock.unlock() }
    }

    public func tryEnqueue(action: A): ExternalEnqueueResult {
        lock.lock()
        try {
            match (stateValue) {
                case RuntimeState.Running => ()
                case _ =>
                    closedValue++
                    return ExternalEnqueueResult.Closed
            }
            if (values.size >= capacityValue) {
                fullValue++
                return ExternalEnqueueResult.Full
            }
            let needsWake = values.isEmpty()
            values.add(ExternalPortEntry<A>(
                action,
                if (measureLatency) { Some(MonoTime.now()) } else { None }
            ))
            if (needsWake) {
                if (wakeSource.signalLocked()) {
                    wakeSignalsValue++
                } else {
                    // Never report Accepted when the empty-to-non-empty edge
                    // cannot be made visible to the sleeping runtime.
                    values.remove(at: values.size - 1)
                    stateValue = RuntimeState.Closing
                    closedValue++
                    return ExternalEnqueueResult.Closed
                }
            } else {
                wakeCoalescedValue++
            }
            acceptedValue++
            ExternalEnqueueResult.Accepted
        } finally {
            lock.unlock()
        }
    }

    // Runtime-only drain. Clearing the wake byte while holding the producer
    // lock prevents the classic clear-after-new-enqueue lost-wake race.
    func drain(): Array<A> {
        let actions = ArrayList<A>()
        for (entry in drainEntries()) { actions.add(entry.action) }
        actions.toArray()
    }

    func drainEntries(): Array<ExternalPortEntry<A>> {
        lock.lock()
        try {
            let drained = values.toArray()
            values.clear()
            wakeSource.clearLocked()
            drained
        } finally {
            lock.unlock()
        }
    }

    public func size(): Int64 {
        lock.lock()
        try { values.size } finally { lock.unlock() }
    }

    func eventSource(): EventSource { wakeSource }

    func beginClosing(): Unit {
        lock.lock()
        try {
            match (stateValue) {
                case RuntimeState.Running => stateValue = RuntimeState.Closing
                case _ => ()
            }
        } finally { lock.unlock() }
    }

    public func close(): Unit {
        lock.lock()
        try {
            match (stateValue) {
                case RuntimeState.Closed => return
                case _ => ()
            }
            stateValue = RuntimeState.Closing
            values.clear()
            wakeSource.clearLocked()
            wakeSource.closeLocked()
            stateValue = RuntimeState.Closed
        } finally { lock.unlock() }
    }

    func state(): RuntimeState {
        lock.lock()
        try { stateValue } finally { lock.unlock() }
    }

    public func acceptedCount(): Int64 { lock.lock(); try { acceptedValue } finally { lock.unlock() } }
    public func fullCount(): Int64 { lock.lock(); try { fullValue } finally { lock.unlock() } }
    public func closedCount(): Int64 { lock.lock(); try { closedValue } finally { lock.unlock() } }
    public func wakeSignals(): Int64 { lock.lock(); try { wakeSignalsValue } finally { lock.unlock() } }
    public func wakeCoalesced(): Int64 { lock.lock(); try { wakeCoalescedValue } finally { lock.unlock() } }
}
