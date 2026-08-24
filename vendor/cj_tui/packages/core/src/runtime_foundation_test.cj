package core

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

class RuntimeTestState {
    var observed: Bool = false
    var depth: Int64 = 0
    var maximumDepth: Int64 = 0
}

@When[os == "Linux"]
func runtimeIdleWakeProof(): Bool {
    let port = ExternalPort<Event>(capacity: 4)
    let backend = TestBackend(area: Rect(0, 0, 20, 3), captureSnapshots: false)
    let driver = ObservedTerminalDriver()
    let app = App(
        backend: backend,
        inputSource: RecordingInputSource(),
        terminalDriver: driver,
        probeInputSource: RecordingInputSource(),
        rawMode: false,
        alternateScreen: false,
        bracketedPaste: false,
        hideCursor: false,
        resize: false,
        eventWaiter: LinuxEpollEventWaiter()
    )
    let producer = spawn {
        sleep(Duration.millisecond * 20)
        port.tryEnqueue(Event.Message("idle-completion"))
    }
    let state = RuntimeTestState()
    app.runWithExternalPort(port, {_ =>}, { event =>
        match (event) {
            case Event.Message("idle-completion") =>
                state.observed = true
                UpdateResult.exit()
            case _ => UpdateResult.unchanged()
        }
    })
    _ = producer.get()
    state.observed && port.acceptedCount() == 1 && driver.restores == 0
}

@When[os != "Linux"]
func runtimeIdleWakeProof(): Bool { true }

@When[os == "Linux"]
func runtimeExternalFailureRestoreProof(): Bool {
    let port = ExternalPort<Event>(capacity: 2)
    let backend = TestBackend(area: Rect(0, 0, 20, 3), captureSnapshots: false)
    let driver = ObservedTerminalDriver()
    let app = App(
        backend: backend,
        inputSource: RecordingInputSource(),
        terminalDriver: driver,
        probeInputSource: RecordingInputSource(),
        rawMode: true,
        alternateScreen: true,
        mouse: true,
        bracketedPaste: true,
        hideCursor: true,
        resize: false,
        eventWaiter: LinuxEpollEventWaiter()
    )
    let producer = spawn {
        sleep(Duration.millisecond * 20)
        port.tryEnqueue(Event.Message("fail"))
    }
    var failed = false
    try {
        app.runWithExternalPort(port, {_ =>}, { event =>
            match (event) {
                case Event.Message("fail") => throw Exception("update failed")
                case _ => UpdateResult.unchanged()
            }
        })
    } catch (error: Exception) {
        failed = error.message.contains("update failed")
    }
    _ = producer.get()
    let output = backend.output()
    failed && driver.restores == 1 &&
        countOccurrences(output, "${ESC}[?1049l") == 1 &&
        countOccurrences(output, "${ESC}[?1006l${ESC}[?1000l") == 1 &&
        countOccurrences(output, "${ESC}[?2004l") == 1 &&
        countOccurrences(output, "${ESC}[?25h") == 1
}

@When[os != "Linux"]
func runtimeExternalFailureRestoreProof(): Bool { true }

@When[os == "Linux"]
func runtimeAsyncWakeProof(): Bool {
    let backend = TestBackend(area: Rect(0, 0, 20, 3), captureSnapshots: false)
    let app = App(
        backend: backend,
        inputSource: RecordingInputSource(),
        probeInputSource: RecordingInputSource(),
        rawMode: false,
        alternateScreen: false,
        bracketedPaste: false,
        hideCursor: false,
        resize: false,
        eventWaiter: LinuxEpollEventWaiter()
    )
    let state = RuntimeTestState()
    app.runWithCommands({_ =>}, { event =>
        match (event) {
            case Event.Capabilities(_) => UpdateResult.withCommand(Command.AsyncTask("idle-async", {=>
                sleep(Duration.millisecond * 20)
                Event.Message("completed")
            }))
            case Event.AsyncStarted(_) => UpdateResult.unchanged()
            case Event.AsyncCompleted("idle-async", Event.Message("completed")) =>
                state.observed = true
                UpdateResult.exit()
            case _ => UpdateResult.unchanged()
        }
    })
    state.observed
}

@When[os != "Linux"]
func runtimeAsyncWakeProof(): Bool { true }

@When[os == "Linux"]
func runtimeEnqueueDuringUpdateProof(): Bool {
    let port = ExternalPort<Event>(capacity: 4)
    let metrics = AppMetrics()
    let app = App(
        backend: TestBackend(area: Rect(0, 0, 20, 3), captureSnapshots: false),
        inputSource: RecordingInputSource(),
        probeInputSource: RecordingInputSource(),
        rawMode: false,
        alternateScreen: false,
        bracketedPaste: false,
        hideCursor: false,
        resize: false,
        eventWaiter: LinuxEpollEventWaiter(),
        metrics: Some(metrics)
    )
    let producer = spawn {
        sleep(Duration.millisecond * 20)
        let first = port.tryEnqueue(Event.Message("one"))
        sleep(Duration.millisecond * 5)
        let second = port.tryEnqueue(Event.Message("two"))
        (first, second)
    }
    let seen = ArrayList<String>()
    app.runWithExternalPort(port, {_ =>}, { event =>
        match (event) {
            case Event.Message("one") =>
                seen.add("one")
                // The second enqueue occurs while this update is active.
                sleep(Duration.millisecond * 20)
                UpdateResult.unchanged()
            case Event.Message("two") =>
                seen.add("two")
                UpdateResult.exit()
            case _ => UpdateResult.unchanged()
        }
    })
    let outcomes = producer.get()
    match (outcomes) {
        case (ExternalEnqueueResult.Accepted, ExternalEnqueueResult.Accepted) =>
            seen.toArray() == ["one", "two"] && metrics.runtime().maxUpdateDepth == 1
        case _ => false
    }
}

@When[os != "Linux"]
func runtimeEnqueueDuringUpdateProof(): Bool { true }

@Test
class RuntimeFoundationTest {
    @TestCase
    func runtimeMetricsSnapshotIsIndependentAndSamplingDoesNotReset(): Unit {
        let metrics = AppMetrics()
        let queue = RuntimeQueue<String>(metrics: Some(metrics))
        @Expect(queue.enqueueEvent(Event.Message("A")), Some(1))

        let first = metrics.runtime()
        let repeated = metrics.runtime()
        @Expect(first.queueEnqueued, 1)
        @Expect(repeated.queueEnqueued, 1)
        @Expect(repeated.queueProcessed, 0)
        @Expect(repeated.maxQueueDepth, 1)

        @Expect(queue.enqueueEvent(Event.Message("B")), Some(2))
        let later = metrics.runtime()
        @Expect(first.queueEnqueued, 1)
        @Expect(first.maxQueueDepth, 1)
        @Expect(later.queueEnqueued, 2)
        @Expect(later.maxQueueDepth, 2)
    }

    @TestCase
    func runtimeMetricsCountersAreMonotonicAndTrackLogicalMaximumDepth(): Unit {
        let metrics = AppMetrics()
        let queue = RuntimeQueue<String>(metrics: Some(metrics))
        let initial = metrics.runtime()
        @Expect(initial.queueEnqueued, 0)
        @Expect(initial.queueProcessed, 0)
        @Expect(initial.maxQueueDepth, 0)

        @Expect(queue.enqueueEvent(Event.Message("A")), Some(1))
        let afterFirstAdmission = metrics.runtime()
        @Expect(queue.enqueueEvent(Event.Message("B")), Some(2))
        @Expect(queue.enqueueEvent(Event.Message("C")), Some(3))
        let afterAdmissions = metrics.runtime()

        match (queue.dequeue()) {
            case Some(_) =>
                queue.enterUpdate()
                queue.leaveUpdate()
            case None => @Expect(false)
        }
        let afterDispatch = metrics.runtime()
        @Expect(afterFirstAdmission.queueEnqueued, 1)
        @Expect(afterAdmissions.queueEnqueued, 3)
        @Expect(afterDispatch.queueEnqueued, 3)
        @Expect(afterDispatch.queueProcessed, 1)
        @Expect(afterAdmissions.maxQueueDepth, 3)
        @Expect(afterDispatch.maxQueueDepth, 3)
    }

    @TestCase
    func runtimeMetricsResetStartsANewEpochWithoutMutatingOldSnapshots(): Unit {
        let metrics = AppMetrics()
        let queue = RuntimeQueue<String>(metrics: Some(metrics))
        @Expect(queue.enqueueEvent(Event.Message("A")), Some(1))
        @Expect(queue.enqueueEvent(Event.Message("B")), Some(2))
        match (queue.dequeue()) {
            case Some(_) =>
                queue.enterUpdate()
                queue.leaveUpdate()
            case None => @Expect(false)
        }
        let previousEpoch = metrics.runtime()

        metrics.reset()
        let resetEpoch = metrics.runtime()
        @Expect(resetEpoch.queueEnqueued, 0)
        @Expect(resetEpoch.queueProcessed, 0)
        @Expect(resetEpoch.maxQueueDepth, 0)
        @Expect(previousEpoch.queueEnqueued, 2)
        @Expect(previousEpoch.queueProcessed, 1)
        @Expect(previousEpoch.maxQueueDepth, 2)

        @Expect(queue.enqueueEvent(Event.Message("C")), Some(3))
        let nextEpoch = metrics.runtime()
        @Expect(nextEpoch.queueEnqueued, 1)
        // One pre-reset item and the new item are pending at this admission.
        @Expect(nextEpoch.maxQueueDepth, 2)
    }

    @TestCase
    func runtimeMetricsSnapshotAllowsConcurrentImmutableReads(): Unit {
        let metrics = AppMetrics()
        let queue = RuntimeQueue<String>(metrics: Some(metrics))
        @Expect(queue.enqueueEvent(Event.Message("A")), Some(1))
        @Expect(queue.enqueueEvent(Event.Message("B")), Some(2))
        let snapshot = metrics.runtime()

        let firstReader = spawn {
            (snapshot.queueEnqueued, snapshot.queueProcessed, snapshot.maxQueueDepth)
        }
        let secondReader = spawn {
            (snapshot.queueEnqueued, snapshot.queueProcessed, snapshot.maxQueueDepth)
        }
        let firstRead = firstReader.get()
        let secondRead = secondReader.get()
        @Expect(firstRead[0], 2)
        @Expect(firstRead[1], 0)
        @Expect(firstRead[2], 2)
        @Expect(secondRead[0], 2)
        @Expect(secondRead[1], 0)
        @Expect(secondRead[2], 2)
    }

    @TestCase
    func runtimeQueueIsFifoAndRejectsReentrantUpdate(): Unit {
        let metrics = AppMetrics()
        let queue = RuntimeQueue<String>(metrics: Some(metrics))
        @Expect(queue.enqueueEvent(Event.Message("A")), Some(1))
        @Expect(queue.enqueueExternal("D"), Some(2))
        @Expect(queue.enqueueEvent(Event.Message("B")), Some(3))

        var expected: Int64 = 1
        while (true) {
            match (queue.dequeue()) {
                case Some(item) =>
                    @Expect(item.sequence, expected)
                    expected++
                case None => break
            }
        }
        @Expect(expected, 4)
        queue.enterUpdate()
        var rejected = false
        try {
            queue.enterUpdate()
        } catch (_: IllegalStateException) {
            rejected = true
        }
        queue.leaveUpdate()
        @Expect(rejected)
        @Expect(queue.maxUpdateDepth(), 1)
        let snapshot = metrics.runtime()
        @Expect(snapshot.queueEnqueued, 3)
        @Expect(snapshot.maxQueueDepth, 3)
        @Expect(snapshot.maxUpdateDepth, 1)
    }

    @TestCase
    func commandEmitAndMessageRunAfterCurrentUpdate(): Unit {
        let commands = ArrayList<Command>()
        commands.add(Command.Emit(Event.Message("A")))
        let seen = ArrayList<String>()
        let state = RuntimeTestState()
        let running = App.processCommands({ event =>
            state.depth++
            state.maximumDepth = max(state.maximumDepth, state.depth)
            let result = match (event) {
                case Event.Message("A") =>
                    seen.add("A")
                    UpdateResult.withCommand(Command.Batch([
                        Command.Emit(Event.Message("B")),
                        Command.Message("C")
                    ]))
                case Event.Message(text) =>
                    seen.add(text)
                    UpdateResult.unchanged()
                case _ => UpdateResult.unchanged()
            }
            state.depth--
            result
        }, commands)
        @Expect(running)
        @Expect(state.maximumDepth, 1)
        @Expect(seen.toArray(), ["A", "B", "C"])
    }

    @TestCase
    func externalPortIsBoundedExplicitAndLevelVisible(): Unit {
        let port = ExternalPort<Event>(capacity: 2)
        match (port.tryEnqueue(Event.Message("one"))) {
            case ExternalEnqueueResult.Accepted => ()
            case _ => @Expect(false)
        }
        match (port.tryEnqueue(Event.Message("two"))) {
            case ExternalEnqueueResult.Accepted => ()
            case _ => @Expect(false)
        }
        match (port.tryEnqueue(Event.Message("three"))) {
            case ExternalEnqueueResult.Full => ()
            case _ => @Expect(false)
        }
        @Expect(port.wakeSignals(), 1)
        @Expect(port.wakeCoalesced(), 1)
        let first = port.drain()
        @Expect(first.size, 2)
        match (first[0]) {
            case Event.Message(text) => @Expect(text, "one")
            case _ => @Expect(false)
        }
        match (port.tryEnqueue(Event.Message("after-drain"))) {
            case ExternalEnqueueResult.Accepted => ()
            case _ => @Expect(false)
        }
        @Expect(port.wakeSignals(), 2)
        port.beginClosing()
        match (port.tryEnqueue(Event.Message("late"))) {
            case ExternalEnqueueResult.Closed => ()
            case _ => @Expect(false)
        }
        port.close()
    }

    @TestCase
    func externalPortCapacityRejectsNonPositiveValues(): Unit {
        @Expect(ExternalPort<Event>().capacity(), 256)
        @Expect(ExternalPort<Event>(capacity: 3).capacity(), 3)
        @ExpectThrows[IllegalArgumentException](ExternalPort<Event>(capacity: 0))
        @ExpectThrows[IllegalArgumentException](ExternalPort<Event>(capacity: -1))
    }

    @TestCase
    func externalPortConcurrentProducersPreserveEachProducerOrder(): Unit {
        let port = ExternalPort<String>(capacity: 32)
        let start = Semaphore(2)
        start.acquire(amount: 2)
        let first = spawn {
            start.acquire()
            let outcomes = ArrayList<ExternalEnqueueResult>()
            for (index in 0..8) {
                outcomes.add(port.tryEnqueue("A${index}"))
            }
            outcomes.toArray()
        }
        let second = spawn {
            start.acquire()
            let outcomes = ArrayList<ExternalEnqueueResult>()
            for (index in 0..8) {
                outcomes.add(port.tryEnqueue("B${index}"))
            }
            outcomes.toArray()
        }
        start.release(amount: 2)
        for (outcome in first.get()) {
            match (outcome) {
                case ExternalEnqueueResult.Accepted => ()
                case _ => @Fail("first producer enqueue was not accepted")
            }
        }
        for (outcome in second.get()) {
            match (outcome) {
                case ExternalEnqueueResult.Accepted => ()
                case _ => @Fail("second producer enqueue was not accepted")
            }
        }

        let drained = port.drain()
        @Expect(drained.size, 16)
        let firstObserved = ArrayList<String>()
        let secondObserved = ArrayList<String>()
        for (value in drained) {
            if (value.startsWith("A")) {
                firstObserved.add(value)
            } else if (value.startsWith("B")) {
                secondObserved.add(value)
            } else {
                @Fail("unexpected producer value")
            }
        }
        @Expect(firstObserved.toArray(), ["A0", "A1", "A2", "A3", "A4", "A5", "A6", "A7"])
        @Expect(secondObserved.toArray(), ["B0", "B1", "B2", "B3", "B4", "B5", "B6", "B7"])
        port.close()
    }

    @TestCase
    func externalPortCloseIsIdempotentAndDiscardsResidentAcceptedWork(): Unit {
        let port = ExternalPort<Event>(capacity: 2)
        match (port.tryEnqueue(Event.Message("accepted-before-close"))) {
            case ExternalEnqueueResult.Accepted => ()
            case _ => @Fail("resident entry was not accepted")
        }
        @Expect(port.size(), 1)
        port.close()
        port.close()
        port.close()
        @Expect(port.size(), 0)
        @Expect(port.drain().size, 0)
        match (port.tryEnqueue(Event.Message("after-close"))) {
            case ExternalEnqueueResult.Closed => ()
            case _ => @Fail("enqueue after close was not rejected as Closed")
        }
    }

    @TestCase
    func externalPortCloseBarrierHasOnlyExplicitOutcomes(): Unit {
        let port = ExternalPort<Event>(capacity: 8)
        let producer = spawn {
            let outcomes = ArrayList<ExternalEnqueueResult>()
            for (index in 0..256) {
                outcomes.add(port.tryEnqueue(Event.Message(index.toString())))
            }
            outcomes.toArray()
        }
        port.beginClosing()
        let outcomes = producer.get()
        for (outcome in outcomes) {
            match (outcome) {
                case ExternalEnqueueResult.Accepted | ExternalEnqueueResult.Full |
                    ExternalEnqueueResult.Closed => ()
            }
        }
        match (port.tryEnqueue(Event.Message("after-barrier"))) {
            case ExternalEnqueueResult.Closed => ()
            case _ => @Expect(false)
        }
        port.close()
    }

    @TestCase
    func staleOwnedCompletionCannotTargetReusedSlot(): Unit {
        let runtime = AsyncOwnershipRuntime()
        let firstOwner = runtime.acquireOwner(7)
        let firstOperation = match (runtime.start(firstOwner)) {
            case Some(value) => value
            case None => throw Exception("first operation was not accepted")
        }
        @Expect(runtime.releaseOwner(firstOwner))
        let secondOwner = runtime.acquireOwner(7)
        @Expect(secondOwner.generation, firstOwner.generation + 1)
        match (runtime.complete(OwnedAsyncCompletion(
            firstOwner,
            firstOperation,
            Event.Message("stale")
        ))) {
            case CompletionDisposition.Orphan => ()
            case _ => @Expect(false)
        }
        @Expect(runtime.orphanCompletions(), 1)

        let secondOperation = match (runtime.start(secondOwner)) {
            case Some(value) => value
            case None => throw Exception("second operation was not accepted")
        }
        @Expect(runtime.requestCancel(secondOperation))
        match (runtime.complete(OwnedAsyncCompletion(
            secondOwner,
            secondOperation,
            Event.Message("late-after-cancel")
        ))) {
            case CompletionDisposition.Applied => ()
            case _ => @Expect(false)
        }
    }

    @TestCase
    func testClockDrivesTimersWithoutWallClock(): Unit {
        let clock = TestClock(startMillis: 100)
        let timers = TimerRuntime(clock: clock)
        timers.start(TimerSpec("once", Duration.millisecond * 25, mode: TimerMode.OneShot))
        @Expect(timers.drain().size, 0)
        @Expect(timers.nextTimeoutMillis(), Some(25))
        clock.advanceMillis(24)
        @Expect(timers.drain().size, 0)
        clock.advanceMillis(1)
        let events = timers.drain()
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.Timer(timer) =>
                @Expect(timer.id, "once")
                @Expect(timer.elapsedMillis, 25)
            case _ => @Expect(false)
        }
        match (timers.nextTimeoutMillis()) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func frameCoalescingKeepsFirstBackgroundImmediateAndDeadlineFixed(): Unit {
        let clock = TestClock()
        let frames = FrameCoalescingState(16, clock: clock)
        frames.request(FrameRequestKind.Background, dirtyRectsBeforeMerge: 1)
        @Expect(frames.readyToPresent())
        let first = frames.presented(1, 1)
        @Expect(first.reason, "background_immediate")
        @Expect(first.framesPresented, 1)

        clock.advanceMillis(1)
        frames.request(FrameRequestKind.Background, dirtyRectsBeforeMerge: 1)
        @Expect(!frames.readyToPresent())
        @Expect(frames.nextWakeMillis(), Some(15))
        clock.advanceMillis(7)
        frames.request(FrameRequestKind.Background, dirtyRectsBeforeMerge: 1)
        // The second invalidation merges without sliding the original due time.
        @Expect(frames.nextWakeMillis(), Some(8))
        clock.advanceMillis(7)
        @Expect(!frames.readyToPresent())
        clock.advanceMillis(1)
        @Expect(frames.readyToPresent())
        let second = frames.presented(2, 1)
        @Expect(second.reason, "background_deadline")
        @Expect(second.frameRequests, 3)
        @Expect(second.framesPresented, 2)
        @Expect(second.frameRequestsMerged, 1)
        @Expect(second.frameDeadlineWakes, 1)
        @Expect(second.updatesPerFrame, 2)
        @Expect(second.framesAvoided, 1)
    }

    @TestCase
    func interactiveAndResizeRequestsPromotePendingBackgroundFrame(): Unit {
        let clock = TestClock()
        let frames = FrameCoalescingState(16, clock: clock)
        frames.request(FrameRequestKind.Background)
        _ = frames.presented(1, 0)

        clock.advanceMillis(2)
        frames.request(FrameRequestKind.Background)
        @Expect(!frames.readyToPresent())
        clock.advanceMillis(1)
        frames.request(FrameRequestKind.Interactive, dirtyRectsBeforeMerge: 1)
        @Expect(frames.readyToPresent())
        let input = frames.presented(2, 1)
        @Expect(input.reason, "interactive_promotion")
        @Expect(input.pendingFramePromotions, 1)
        @Expect(input.interactiveFrameRequests, 1)
        @Expect(input.lastUpdateToFrameMillis, 0)

        clock.advanceMillis(1)
        frames.request(FrameRequestKind.Background)
        @Expect(!frames.readyToPresent())
        frames.request(FrameRequestKind.SurfaceCritical)
        @Expect(frames.readyToPresent())
        let resize = frames.presented(2, 0)
        @Expect(resize.reason, "resize")
        @Expect(resize.resizeFrameRequests, 1)
        @Expect(resize.pendingFramePromotions, 2)

        let interactiveOnly = FrameCoalescingState(32, clock: clock)
        interactiveOnly.request(FrameRequestKind.Interactive)
        _ = interactiveOnly.presented(1, 1)
        interactiveOnly.request(FrameRequestKind.Background)
        @Expect(interactiveOnly.readyToPresent(), true)
    }

    @TestCase
    func continuousBackgroundRequestsCannotStarveAndShutdownDiscardsPending(): Unit {
        let clock = TestClock()
        let frames = FrameCoalescingState(8, clock: clock)
        frames.request(FrameRequestKind.Background)
        _ = frames.presented(1, 0)
        for (_ in 0..7) {
            clock.advanceMillis(1)
            frames.request(FrameRequestKind.Background)
            @Expect(!frames.readyToPresent())
        }
        clock.advanceMillis(1)
        @Expect(frames.readyToPresent())
        let due = frames.presented(8, 0)
        @Expect(due.firstInvalidationToFrameMillis, 7)
        @Expect(due.frameDeadlineWakes, 1)

        clock.advanceMillis(1)
        frames.request(FrameRequestKind.Background)
        @Expect(!frames.readyToPresent())
        frames.discard()
        clock.advanceMillis(100)
        @Expect(!frames.readyToPresent())
        match (frames.nextWakeMillis()) {
            case Some(_) => @Expect(false)
            case None => ()
        }
    }

    @TestCase
    func idleExternalCompletionWakesRuntimeWithoutTimerOrInput(): Unit {
        @Expect(runtimeIdleWakeProof())
    }

    @TestCase
    func externalEnqueueDuringUpdateStaysOrderedAndNonReentrant(): Unit {
        @Expect(runtimeEnqueueDuringUpdateProof())
    }

    @TestCase
    func externalFailureRestoresEnabledTerminalModesExactlyOnce(): Unit {
        @Expect(runtimeExternalFailureRestoreProof())
    }

    @TestCase
    func asyncCompletionWakesRuntimeWithoutPollingDeadline(): Unit {
        @Expect(runtimeAsyncWakeProof())
    }
}
