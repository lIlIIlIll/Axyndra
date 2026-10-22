package agent_app

import agent_domain.*
import agent_domain.LogicalJsonOwnerReservation
import agent_domain.LogicalJsonCopiedDisplayOwnerPort
import agent_runtime.*
import agent_product.*
import agent_cli.*
import agent_tui.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*
import std.time.*
import std.env.*
import std.fs.*

// The actual frontend Root owns this concrete terminal controller before it
// starts readers or calls the physical TUI. No backend escapes its run helper.
func createOwnerProductTuiClientFrontend180(peer: ProductOwnerPeer180,
    initialPrompt: String): ProductOwnerClientFrontend180 {
    OwnerProductTuiClientFrontend180(peer, initialPrompt)
}
class OwnerProductTuiClientFrontend180 <: ProductOwnerClientFrontend180 {
    private var peer: ?ProductOwnerPeer180
    private var initialPrompt: ?String
    private var backend: ?OwnerProductTuiBackend180 = None
    private var constructing: ?LogicalJsonOwnerReservation = None
    init(peer: ProductOwnerPeer180, initialPrompt: String) {
        this.peer = Some(peer); this.initialPrompt = Some(initialPrompt)
    }
    public func runOwnerClientFrontend180(): Int64 {
        let actualPeer = peer.getOrThrow()
        let paid = actualPeer.deriveOwnerFrameData180(65536)
        constructing = Some(paid)
        backend = Some(OwnerProductTuiBackend180(actualPeer, paid, actualPeer.ownerConfiguration180().stateRoot))
        constructing = None
        backend.getOrThrow().startReader180()
        tuiStartupStage("configuration_loading_completed")
        runAgentTui(backend.getOrThrow(), title: "axyndra", initialPrompt: initialPrompt.getOrThrow())
    }
    public func closeOwnerClientFrontend180(): Result<Unit> {
        match (backend) {
            case None => return ownedTuiDisplayError("tui.owner_backend_initialization_unknown")
            case Some(actual) =>
                match (actual.closeOwnerClientBackend180()) {
                    case Result.Err(error) => return Result<Unit>.Err(error)
                    case Result.Ok(_) => () }
        }
        backend = None; peer = None; initialPrompt = None
        Result<Unit>.Ok(())
    }
}

private class TuiOwnerPayment180 {
    var next: ?TuiOwnerPayment180 = None
    var paid: ?LogicalJsonOwnerReservation
    init(paid: LogicalJsonOwnerReservation) { this.paid = Some(paid) }
}
private class TuiOwnerPending180 {
    let id: Int64
    let monitor = Monitor()
    var value: ?AgentValue = None
    var error: ?String = None
    var events: ?TuiAgentEventSink
    init(id: Int64, events: ?TuiAgentEventSink) { this.id = id; this.events = events }
    func await180(): AgentValue {
        synchronized (monitor) {
            while (value.isNone() && error.isNone()) { monitor.wait() }
            match (error) { case Some(actual) => throw Exception(actual); case None => () }
            value.getOrThrow()
        }
    }
    func resolve180(value: AgentValue): Unit { synchronized (monitor) {
        if(this.value.isSome() || error.isSome()){throw Exception("tui.owner_duplicate_terminal_response")}
        this.value = Some(value); monitor.notifyAll() } }
    func fail180(message: String): Unit { synchronized (monitor) {
        // EOF cannot replace an already published terminal response.
        // The reader retains its independent original exception separately.
        if(value.isNone() && error.isNone()){error = Some(message); monitor.notifyAll()} } }
    func clear180(): Unit { synchronized (monitor) { value = None; events = None; error = None } }
}
private class TuiOwnerAdmission180 {
    private let lock = Mutex()
    private var accepting = false
    private var accepted = false
    func begin180(): Bool {
        lock.lock(); try { if (accepting || accepted) { return false }; accepting = true; true } finally { lock.unlock() }
    }
    func finish180(result: Result<Unit>): Unit {
        lock.lock(); try { accepting = false; if (result.isOk()) { accepted = true } } finally { lock.unlock() }
    }
    func wasAccepted180(): Bool { lock.lock(); try { accepted } finally { lock.unlock() } }
}
private class TuiOwnerDelivery180 {
    var next: ?TuiOwnerDelivery180 = None
    var event: ?TuiAgentEvent = None
    var sink: ?TuiAgentEventSink = None
    var toolIndex: Int64 = -1
    var failureIndex: Int64 = -1
    var slot: ?TuiOwnerPending180 = None
    var value: ?AgentValue = None
    var error: ?String = None
}
class OwnerProductTuiBackend180 <: AgentTuiBackend & OwnedAgentTuiBackend & OwnedFailureAgentTuiBackend113 {
    private var peerValue: ?ProductOwnerPeer180
    private prop peer: ProductOwnerPeer180 { get() { peerValue.getOrThrow() } }
    private var metadata: ?LogicalJsonOwnerReservation
    private var clipboardRoot: ?String
    private var clipboardProcess180: ?LocalProcessPort = None
    private let lock = Mutex()
    private let writer = Mutex()
    private let pending = Array<?TuiOwnerPending180>(32, repeat: None<TuiOwnerPending180>)
    private var reader: ?Future<Unit> = None
    private var observer: ?TuiAgentEventSink = None
    private var toolOutput: ?OwnedTuiToolDisplayOutput = None
    private var failureOutput: ?OwnedTuiFailureDisplayOutput113 = None
    private var nextId: Int64 = 0
    private var activeTurn: Int64 = 0
    private var closing = false
    private var readerJoined = false
    private var readerFailure: ?String = None
    private var readerOriginalFailure180:?Exception=None<Exception>
    private var payments: ?TuiOwnerPayment180 = None
    private var readerPayment180: ?TuiOwnerReadFrame180 = None
    private var readerRawPending180: ?LogicalJsonOwnerReservation = None
    private var readFrames180: ?TuiOwnerReadFrame180 = None
    private var readerPaymentRetained180 = false
    private var tools = ArrayList<OwnedTuiToolDisplay>()
    private var failures = ArrayList<OwnedTuiFailureDisplay113>()
    private var registries = ArrayList<OwnedTuiRegistryResponseDisplay167>()
    private var toolAdmissions = ArrayList<TuiOwnerAdmission180>()
    private var failureAdmissions = ArrayList<TuiOwnerAdmission180>()
    private let stateMonitor = Monitor()
    private var state: ?Array<String> = None
    private let deliveryMonitor180 = Monitor()
    private var delivery180: ?Future<Unit> = None
    private var deliveryHead180: ?TuiOwnerDelivery180 = None
    private var deliveryTail180: ?TuiOwnerDelivery180 = None
    private var deliveryCurrent180: ?TuiOwnerDelivery180 = None
    private var deliveryClosing180 = false
    private var deliveryWake180: Int64 = 0
    init(peer: ProductOwnerPeer180, paid: LogicalJsonOwnerReservation, clipboardRoot: String) {
        this.peerValue = Some(peer); this.metadata = Some(paid); this.clipboardRoot = Some(clipboardRoot)
    }
    func startReader180(): Unit {
        delivery180 = Some(spawn { deliveryLoop180() })
        reader = Some(spawn { readLoop180() })
    }
    public func observe(events: TuiAgentEventSink): Unit {
    lock.lock(); try { if (closing) { throw Exception("tui.owner_closed") }; observer = Some(events) } finally { lock.unlock() }
        wakeDelivery180()
    }
    public func observeOwnedToolDisplay(output: OwnedTuiToolDisplayOutput): Unit {
        lock.lock(); try { if (closing) { throw Exception("tui.owner_closed") }; toolOutput = Some(output) } finally { lock.unlock() }
        wakeDelivery180()
    }
    public func observeOwnedFailureDisplay113(output: OwnedTuiFailureDisplayOutput113): Unit {
        lock.lock(); try { if (closing) { throw Exception("tui.owner_closed") }; failureOutput = Some(output) } finally { lock.unlock() }
        wakeDelivery180()
    }
    public func pollOwnedFailureDisplays113(): Unit {
        // UI callbacks may genuinely backpressure. Only the independent
        // delivery worker calls them; the socket reader must keep routing
        // synchronous UI replies while the real mailbox is full.
        wakeDelivery180()
    }
    private func retainPayment180(paid: LogicalJsonOwnerReservation): Unit {
        lock.lock(); try {
            let node = TuiOwnerPayment180(paid); node.next = payments; payments = Some(node)
        } finally { lock.unlock() }
    }
    private func retainReadFrame180(frame: TuiOwnerReadFrame180): Unit {
        lock.lock(); try {
            match (readerPayment180) { case Some(current) => if (refEq(current, frame)) {
                if (readerPaymentRetained180) { return }; readerPaymentRetained180 = true
            }; case None => () }
            frame.next180 = readFrames180; readFrames180 = Some(frame)
        } finally { lock.unlock() }
    }
    private func call180(method: String, invoice: Int64, build: () -> AgentValue,
        events!: ?TuiAgentEventSink = None, turn!: Bool = false, allowClosing!: Bool = false): AgentValue {
        let paid = peer.deriveOwnerFrameData180(4096); paid.ensureRetainedPeak(invoice)
        let slot = try { registerCall180(events, turn, allowClosing) } catch (error: Exception) { paid.close(); throw error }
        try {
            try { writeCallFrame180(method, slot.id, build) } finally { paid.close() }
            slot.await180()
        } finally { removeCall180(slot, turn) }
    }
    private func registerCall180(events: ?TuiAgentEventSink, turn: Bool, allowClosing: Bool): TuiOwnerPending180 {
        lock.lock()
        try {
            if ((closing && !allowClosing) || readerJoined || readerFailure.isSome()) { throw Exception("tui.owner_disconnected") }
            if (turn && activeTurn != 0) { throw Exception("tui.owner_turn_already_running") }
            for (i in 0..pending.size) {
                if (pending[i].isNone()) {
                    if (nextId == Int64.Max) { throw Exception("tui.owner_sequence_exhausted") }; nextId++
                    let slot = TuiOwnerPending180(nextId, events); pending[i] = Some(slot)
                    if (turn) { activeTurn = slot.id }; return slot
                }
            }
            throw Exception("tui.owner_call_slots_full")
        } finally { lock.unlock() }
    }
    private func removeCall180(slot: TuiOwnerPending180, turn: Bool): Unit {
        lock.lock()
        try {
            for (i in 0..pending.size) { match (pending[i]) { case Some(actual) => if (refEq(actual, slot)) { pending[i] = None }; case None => () } }
            if (turn && activeTurn == slot.id) { activeTurn = 0 }
            slot.clear180()
        } finally { lock.unlock() }
    }
    private func writeCallFrame180(method: String, id: Int64, build: () -> AgentValue): Unit {
        writer.lock()
        try {
            let frame = encodeAgentValue(listValue([textValue("call"), integerValue(id), textValue(method), build()]))
            match (peer.writeOwnerFrame180(frame)) { case Result.Err(error) => throw Exception(error.describe()); case Result.Ok(_) => () }
        } finally { writer.unlock() }
    }
    private func readLoop180(): Unit {
        try {
            while (true) {
                let rawPaid = peer.deriveOwnerFrameData180(65536)
                lock.lock(); readerRawPending180 = Some(rawPaid); lock.unlock()
                let frame = TuiOwnerReadFrame180(rawPaid)
                lock.lock(); readerPayment180 = Some(frame); readerRawPending180 = None
                readerPaymentRetained180 = false; lock.unlock()
                frame.initializeCodec180(peer)
                try { readFrame180(frame) }
                catch (error: Exception) { retainReadFrame180(frame); throw error }
                finally { retireReadPaymentAfterHelper180() }
            }
        } catch (error: Exception) {
            lock.lock();try{readerOriginalFailure180=Some(error)}finally{lock.unlock()}
            failAll180(error.message)
        }
    }
    private func retireReadPaymentAfterHelper180(): Unit {
        lock.lock()
        try {
            if (!readerPaymentRetained180) { match (readerPayment180) { case Some(frame) => frame.retireAfterWholeReadConsumer180(); case None => () } }
            readerPayment180 = None; readerPaymentRetained180 = false
        } finally { lock.unlock() }
    }
    private func readFrame180(paid: TuiOwnerReadFrame180): Bool {
        let value = paid.readAndDecode180(peer, 8388608)
        tuiOwnerShape180(value, 3)
        let kind = tuiOwnerText180(value.items[0]); let id = tuiOwnerInteger180(value.items[1])
        if (kind == "state") { let retained = acceptState180(value.items[2]); if (retained) { retainReadFrame180(paid) }; return retained }
        if (kind == "event") { retainReadFrame180(paid); dispatchEvent180(id, value.items[2], paid); return true }
        let slot = findPending180(id)
        match (kind) {
            case "result" =>
                let data = value.items[2]
                let dynamic = data.unifiedKind != ValueKind.Null && data.unifiedKind != ValueKind.Boolean && data.unifiedKind != ValueKind.Number
                if (dynamic) { retainReadFrame180(paid) }; resolveThroughDelivery180(slot, Some(data), None<String>); dynamic
            case "failure" => retainReadFrame180(paid); resolveThroughDelivery180(slot, None<AgentValue>, Some(tuiOwnerText180(value.items[2]))); true
            case _ => throw Exception("tui.owner_unknown_envelope")
        }
    }
    private func findPending180(id: Int64): TuiOwnerPending180 {
        lock.lock()
        try { for (slot in pending) { match (slot) { case Some(actual) => if (actual.id == id) { return actual }; case None => () } }; throw Exception("tui.owner_unknown_response") }
        finally { lock.unlock() }
    }
    private func failAll180(message: String): Unit {
        lock.lock()
        try {
            readerFailure = Some(message)
            for (slot in pending) { match (slot) { case Some(actual) => actual.fail180(message); case None => () } }
        } finally { lock.unlock() }
        synchronized (stateMonitor) { stateMonitor.notifyAll() }
    }
    private func newCopiedAllocation180(paid: LogicalJsonOwnerReservation, invoice: Int64): LogicalJsonCopiedDisplayAllocation {
        paid.acquireCopiedDisplayAllocation(invoice).value().getOrThrow()
    }
    private func newCopiedAllocation180(frame: TuiOwnerReadFrame180, invoice: Int64): LogicalJsonCopiedDisplayAllocation {
        frame.newCopiedAllocation180(invoice)
    }
    private func registryDisplay180(frame: TuiOwnerReadFrame180, invoice: Int64): OwnedTuiRegistryResponseDisplay167 {
        let display = OwnedTuiRegistryResponseDisplay167(this, frame.newCopiedAllocation180(invoice), invoice)
        lock.lock(); try { registries.add(display) } finally { lock.unlock() }
        display
    }
    private func registryDisplay180(paid: LogicalJsonOwnerReservation, invoice: Int64): OwnedTuiRegistryResponseDisplay167 {
        let copied = newCopiedAllocation180(paid, invoice)
        let display = OwnedTuiRegistryResponseDisplay167(this, copied, invoice)
        lock.lock(); try { registries.add(display) } finally { lock.unlock() }
        display
    }
    private func dispatchEvent180(id: Int64, data: AgentValue, paid: TuiOwnerReadFrame180): Unit {
        if (data.unifiedKind != ValueKind.List || data.items.size < 1) { throw Exception("tui.owner_event_shape") }
        let tag = tuiOwnerText180(data.items[0])
        if (tag == "owned_tool") {
            tuiOwnerShape180(data, 2)
            let invoice = tuiOwnerInvoiceAdd180(65536, tuiOwnerDataInvoice180(data.items[1]))
            let allocation = newCopiedAllocation180(paid, invoice)
            let display = OwnedTuiToolDisplay(allocation, invoice)
            lock.lock(); tools.add(display); toolAdmissions.add(TuiOwnerAdmission180()); let index = tools.size - 1; lock.unlock()
            display.installCopiedEvent(tuiOwnerDecodeTuiAgentEvent180(data.items[1])).value().getOrThrow()
            let node = TuiOwnerDelivery180(); node.toolIndex = index; enqueueDelivery180(node)
            return
        }
        if (tag == "owned_failure") {
            tuiOwnerShape180(data, 4)
            let code = tuiOwnerText180(data.items[1]); let message = tuiOwnerText180(data.items[2]); let encoded = tuiOwnerText180(data.items[3])
            let invoice = tuiOwnerInvoiceAdd180(65536, tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(code), tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(message), tuiOwnerInvoice180(encoded))))
            let allocation = newCopiedAllocation180(paid, invoice)
            let display = OwnedTuiFailureDisplay113(allocation, invoice)
            lock.lock(); failures.add(display); failureAdmissions.add(TuiOwnerAdmission180()); let index = failures.size - 1; lock.unlock()
            display.installCopiedFailure113(String.fromUtf8(code.toArray()), String.fromUtf8(message.toArray()), String.fromUtf8(encoded.toArray())).value().getOrThrow()
            let node = TuiOwnerDelivery180(); node.failureIndex = index; enqueueDelivery180(node)
            return
        }
        let event = if (tag == "owned_registry_error") {
            tuiOwnerShape180(data, 2)
            TuiAgentEvent.OwnedRegistryError167(registryDisplay180(paid, tuiOwnerInvoice180(tuiOwnerText180(data.items[1]))), tuiOwnerText180(data.items[1]))
        } else { tuiOwnerDecodeTuiAgentEvent180(data) }
        lock.lock(); let observed = observer; lock.unlock()
        let target = if (id == 0) { observed } else { findPending180(id).events }
        let node = TuiOwnerDelivery180(); node.event = Some(event); node.sink = target; enqueueDelivery180(node)
    }
    private func acceptState180(value: AgentValue): Bool {
        tuiOwnerShape180(value, 8)
        synchronized (stateMonitor) {
            var changed = state.isNone()
            match (state) {
                case Some(old) => for (i in 0..8) { if (old[i] != value.items[i].text) { changed = true } }
                case None => () }
            if (!changed) { return false }
            state = Some(tuiOwnerDecodeArray180<String>(value, { item => tuiOwnerText180(item) }))
            stateMonitor.notifyAll(); true
        }
    }
    private func stateValue180(index: Int64): String {
        synchronized (stateMonitor) {
            while (state.isNone()) {
                lock.lock(); let failed = readerFailure.isSome() || readerJoined; lock.unlock()
                if (failed) { throw Exception("tui.owner_disconnected") }; stateMonitor.wait()
            }
            state.getOrThrow()[index]
        }
    }
    private func enqueueDelivery180(node: TuiOwnerDelivery180): Unit {
        synchronized (deliveryMonitor180) {
            if (deliveryClosing180) { return }
            match (deliveryTail180) { case Some(tail) => tail.next = Some(node); case None => deliveryHead180 = Some(node) }
            deliveryTail180 = Some(node); deliveryWake180++; deliveryMonitor180.notifyAll()
        }
    }
    private func wakeDelivery180(): Unit { synchronized (deliveryMonitor180) { deliveryWake180++; deliveryMonitor180.notifyAll() } }
    private func resolveThroughDelivery180(slot: TuiOwnerPending180, value: ?AgentValue, error: ?String): Unit {
        lock.lock(); let stopped = closing; lock.unlock()
        if (slot.events.isNone() || stopped) {
            match (error) { case Some(message) => slot.fail180(message); case None => slot.resolve180(value.getOrThrow()) }; return
        }
        let node = TuiOwnerDelivery180(); node.slot = Some(slot); node.value = value; node.error = error
        enqueueDelivery180(node)
    }
    private func takeDelivery180(): ?TuiOwnerDelivery180 {
        synchronized (deliveryMonitor180) {
            while (!deliveryClosing180 && deliveryCurrent180.isNone() && deliveryHead180.isNone()) { deliveryMonitor180.wait() }
            if (deliveryClosing180) { return None<TuiOwnerDelivery180> }
            if (deliveryCurrent180.isNone()) {
                let node = deliveryHead180.getOrThrow(); deliveryHead180 = node.next; node.next = None
                if (deliveryHead180.isNone()) { deliveryTail180 = None }; deliveryCurrent180 = Some(node)
            }
            deliveryCurrent180
        }
    }
    private func deliveryLoop180(): Unit {
        try {
            while (true) {
                let node = match (takeDelivery180()) { case Some(value) => value; case None => return }
                let wake = synchronized (deliveryMonitor180) { deliveryWake180 }
                if (deliverWholeNodeHelper180(node)) {
                    clearDeliveredNode180(node)
                    synchronized (deliveryMonitor180) { deliveryCurrent180 = None }
                } else {
                    synchronized (deliveryMonitor180) {
                        while (!deliveryClosing180 && deliveryWake180 == wake) { deliveryMonitor180.wait() }
                    }
                }
            }
        } catch (error: Exception) {
            lock.lock(); let stopped = closing; lock.unlock()
            if (!stopped) { failAll180(error.message) }
        }
    }
    private func deliverWholeNodeHelper180(node: TuiOwnerDelivery180): Bool {
        match (node.slot) {
            case Some(slot) => match (node.error) { case Some(message) => slot.fail180(message); case None => slot.resolve180(node.value.getOrThrow()) }; return true
            case None => () }
        if (node.toolIndex >= 0) {
            deliverToolCopy180(node.toolIndex)
            lock.lock(); let gate = toolAdmissions[node.toolIndex]; lock.unlock(); return gate.wasAccepted180()
        }
        if (node.failureIndex >= 0) {
            deliverFailureCopy180(node.failureIndex)
            lock.lock(); let gate = failureAdmissions[node.failureIndex]; lock.unlock(); return gate.wasAccepted180()
        }
        let target = match (node.sink) { case Some(actual) => Some(actual); case None => lock.lock(); let actual = observer; lock.unlock(); actual }
        match (target) { case Some(actual) => actual(node.event.getOrThrow()); true; case None => false }
    }
    private func clearDeliveredNode180(node: TuiOwnerDelivery180): Unit {
        node.event = None; node.sink = None; node.slot = None; node.value = None; node.error = None; node.next = None
    }
    private func stopDelivery180(): Unit {
        synchronized (deliveryMonitor180) { deliveryClosing180 = true; deliveryWake180++; deliveryMonitor180.notifyAll() }
        lock.lock(); try { for (slot in pending) { match (slot) { case Some(actual) => actual.fail180("tui.owner_closing"); case None => () } } } finally { lock.unlock() }
    }
    private func joinDeliveryWholeHelper180(): Unit { match (delivery180) { case Some(actual) => actual.get(); case None => () } }
    private func clearDeliveryAfterJoin180(): Unit {
        synchronized (deliveryMonitor180) {
            match (deliveryCurrent180) { case Some(node) => clearDeliveredNode180(node); case None => () }
            deliveryCurrent180 = None
            while (deliveryHead180.isSome()) {
                let node = deliveryHead180.getOrThrow(); deliveryHead180 = node.next; clearDeliveredNode180(node)
            }
            deliveryTail180 = None; delivery180 = None
        }
    }
    private func deliverToolCopy180(index: Int64): Unit {
        lock.lock(); let value = tools[index]; let gate = toolAdmissions[index]; let output = toolOutput; lock.unlock()
        match (output) { case Some(actual) => if (gate.begin180()) {
            let result = actual.accept(value); gate.finish180(result); requireDeliveryOutcome180(result)
        }; case None => () }
    }
    private func deliverFailureCopy180(index: Int64): Unit {
        lock.lock(); let value = failures[index]; let gate = failureAdmissions[index]; let output = failureOutput; lock.unlock()
        match (output) { case Some(actual) => if (gate.begin180()) {
            let result = actual.acceptFailureDisplay113(value); gate.finish180(result); requireDeliveryOutcome180(result)
        }; case None => () }
    }
    private func requireDeliveryOutcome180(result: Result<Unit>): Unit {
        match (result) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                if (refEq(error, TUI_FAILURE_MAILBOX_PENDING113)) { return }
                lock.lock(); let stopped = closing; lock.unlock()
                if (stopped && error.code == "display.mailbox_references_closed") { return }
                throw Exception(error.describe())
        }
    }
    private func decodeTurn180(value: AgentValue): TuiTurnResult {
        tuiOwnerShape180(value, 5)
        let text = tuiOwnerText180(value.items[0]); let status = tuiOwnerText180(value.items[1])
        let display = if (tuiOwnerBoolean180(value.items[4])) {
            let paid = peer.deriveOwnerFrameData180(4096); retainPayment180(paid)
            Some(registryDisplay180(paid, tuiOwnerDataInvoice180(value)))
        } else { None<OwnedTuiRegistryResponseDisplay167> }
        TuiTurnResult(text, status, action: tuiOwnerDecodeTuiTurnAction180(value.items[2]),
            planReviewDisposition: tuiOwnerDecodeTuiPlanReviewDisposition180(value.items[3]), ownedRegistryDisplay167: display)
    }
    public func cancel(): Unit {
        lock.lock(); let current = activeTurn; let stopped = closing; lock.unlock()
        if (current != 0 && !stopped) { let _ = call180("cancel", 4096, { => listValue([integerValue(current)]) }) }
    }

    public func welcome(): Array<TuiAgentEvent> {
        tuiOwnerDecodeArray180<TuiAgentEvent>(call180("welcome", 4096, { => listValue([]) }), { item => tuiOwnerDecodeTuiAgentEvent180(item) })
    }

    public func submit(prompt: String, events: TuiAgentEventSink): TuiTurnResult {
        decodeTurn180(call180("submit", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(prompt)), { => listValue([textValue(prompt)]) }, events: Some(events), turn: true))
    }

    public func steer(correlationId: String, prompt: String): Bool {
        tuiOwnerBoolean180(call180("steer", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(correlationId)), tuiOwnerInvoice180(prompt)), { => listValue([textValue(correlationId), textValue(prompt)]) }))
    }

    public func followUp(correlationId: String, prompt: String): Bool {
        tuiOwnerBoolean180(call180("followUp", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(correlationId)), tuiOwnerInvoice180(prompt)), { => listValue([textValue(correlationId), textValue(prompt)]) }))
    }

    public func withdrawQueued(correlationId: String): TuiQueueWithdrawal {
        tuiOwnerDecodeTuiQueueWithdrawal180(call180("withdrawQueued", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(correlationId)), { => listValue([textValue(correlationId)]) }))
    }

    public func decide(operationId: String, decision: TuiApprovalDecision, events: TuiAgentEventSink): TuiTurnResult {
        decodeTurn180(call180("decide", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(operationId)), tuiOwnerInvoice180(decision)), { => listValue([textValue(operationId), tuiOwnerEncode180(decision)]) }, events: Some(events), turn: true))
    }

    public func reviewPlan(contentHash: String, decision: TuiPlanReviewDecision, feedback: String, events: TuiAgentEventSink): TuiTurnResult {
        decodeTurn180(call180("reviewPlan", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(contentHash)), tuiOwnerInvoice180(decision)), tuiOwnerInvoice180(feedback)), { => listValue([textValue(contentHash), tuiOwnerEncode180(decision), textValue(feedback)]) }, events: Some(events), turn: true))
    }

    public func answerAsk(requestId: String, resolution: TuiAskResolution): Bool {
        tuiOwnerBoolean180(call180("answerAsk", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(requestId)), tuiOwnerInvoice180(resolution)), { => listValue([textValue(requestId), tuiOwnerEncode180(resolution)]) }))
    }

    public func pluginCommands(): Array<String> {
        tuiOwnerDecodeArray180<String>(call180("pluginCommands", 4096, { => listValue([]) }), { item => tuiOwnerText180(item) })
    }

    public func runPluginCommand(routeName: String, arguments: String, events: TuiAgentEventSink): TuiTurnResult {
        decodeTurn180(call180("runPluginCommand", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(routeName)), tuiOwnerInvoice180(arguments)), { => listValue([textValue(routeName), textValue(arguments)]) }, events: Some(events), turn: true))
    }

    public func currentModel(): String {
        stateValue180(0)
    }

    public func currentSession(): String {
        stateValue180(1)
    }

    public func currentThinking(): String {
        stateValue180(2)
    }

    public func currentWorkMode(): String {
        stateValue180(3)
    }

    public func currentShellNetworkMode(): String {
        stateValue180(4)
    }

    public func currentTheme(): String {
        stateValue180(5)
    }

    public func currentBranch(): String {
        stateValue180(6)
    }

    public func workspace(): String {
        stateValue180(7)
    }

    public func models(): Array<String> {
        tuiOwnerDecodeArray180<String>(call180("models", 4096, { => listValue([]) }), { item => tuiOwnerText180(item) })
    }

    public func customThemes(): Array<TuiThemeDefinition> {
        tuiOwnerDecodeArray180<TuiThemeDefinition>(call180("customThemes", 4096, { => listValue([]) }), { item => tuiOwnerDecodeTuiThemeDefinition180(item) })
    }

    public func selectTheme(name: String): Bool {
        tuiOwnerBoolean180(call180("selectTheme", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(name)), { => listValue([textValue(name)]) }))
    }

    public func sessions(includeArchived: Bool): Array<TuiSessionNode> {
        tuiOwnerDecodeArray180<TuiSessionNode>(call180("sessions", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(includeArchived)), { => listValue([boolValue(includeArchived)]) }), { item => tuiOwnerDecodeTuiSessionNode180(item) })
    }

    public func sessionTree(): Array<TuiSessionNode> {
        tuiOwnerDecodeArray180<TuiSessionNode>(call180("sessionTree", 4096, { => listValue([]) }), { item => tuiOwnerDecodeTuiSessionNode180(item) })
    }

    public func renameSession(sessionId: String, name: String): Bool {
        tuiOwnerBoolean180(call180("renameSession", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(sessionId)), tuiOwnerInvoice180(name)), { => listValue([textValue(sessionId), textValue(name)]) }))
    }

    public func archiveSession(sessionId: String): Bool {
        tuiOwnerBoolean180(call180("archiveSession", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(sessionId)), { => listValue([textValue(sessionId)]) }))
    }

    public func restoreSession(sessionId: String): Bool {
        tuiOwnerBoolean180(call180("restoreSession", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(sessionId)), { => listValue([textValue(sessionId)]) }))
    }

    public func subagents(): Array<TuiSubagentInfo> {
        tuiOwnerDecodeArray180<TuiSubagentInfo>(call180("subagents", 4096, { => listValue([]) }), { item => tuiOwnerDecodeTuiSubagentInfo180(item) })
    }

    public func subagentTranscript(id: String): String {
        tuiOwnerText180(call180("subagentTranscript", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(id)), { => listValue([textValue(id)]) }))
    }

    public func focusSubagent(id: String): TuiConversationView {
        tuiOwnerDecodeTuiConversationView180(call180("focusSubagent", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(id)), { => listValue([textValue(id)]) }))
    }

    public func focusMain(): TuiConversationView {
        tuiOwnerDecodeTuiConversationView180(call180("focusMain", 4096, { => listValue([]) }))
    }

    public func loadMainTranscriptPage(beforeOrdinal: Int64, limit: Int64): TuiTranscriptPage {
        tuiOwnerDecodeTuiTranscriptPage180(call180("loadMainTranscriptPage", tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(beforeOrdinal)), tuiOwnerInvoice180(limit)), { => listValue([integerValue(beforeOrdinal), integerValue(limit)]) }))
    }

    public func draft(): String {
        tuiOwnerText180(call180("draft", 4096, { => listValue([]) }))
    }

    public func saveDraft(value: String): Bool {
        tuiOwnerBoolean180(call180("saveDraft", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(value)), { => listValue([textValue(value)]) }))
    }

    public func branchMessages(): Array<String> {
        tuiOwnerDecodeArray180<String>(call180("branchMessages", 4096, { => listValue([]) }), { item => tuiOwnerText180(item) })
    }

    public func selectModel(model: String): Bool {
        tuiOwnerBoolean180(call180("selectModel", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(model)), { => listValue([textValue(model)]) }))
    }

    public func selectSession(sessionId: String): Bool {
        tuiOwnerBoolean180(call180("selectSession", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(sessionId)), { => listValue([textValue(sessionId)]) }))
    }

    public func selectBranch(entryId: String): ?String {
        tuiOwnerDecodeOption180<String>(call180("selectBranch", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(entryId)), { => listValue([textValue(entryId)]) }), { item => tuiOwnerText180(item) })
    }

    public func configureSetup(request: TuiSetupRequest): String {
        tuiOwnerText180(call180("configureSetup", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(request)), { => listValue([tuiOwnerEncode180(request)]) }))
    }

    public func archiveAndReset(): String {
        tuiOwnerText180(call180("archiveAndReset", 4096, { => listValue([]) }))
    }

    public func frontendSlashDefinitions(): Array<SlashCommandDefinition> {
        tuiOwnerDecodeArray180<SlashCommandDefinition>(call180("frontendSlashDefinitions", 4096, { => listValue([]) }), { item => tuiOwnerDecodeSlashCommandDefinition180(item) })
    }

    public func todoMarkdown(): TuiTodoLoadResult {
        tuiOwnerDecodeTuiTodoLoadResult180(call180("todoMarkdown", 4096, { => listValue([]) }))
    }

    public func loadTodoEditor(): TuiTodoLoadResult {
        tuiOwnerDecodeTuiTodoLoadResult180(call180("loadTodoEditor", 4096, { => listValue([]) }))
    }

    public func saveTodoMarkdown(markdown: String): TuiTodoSaveResult {
        tuiOwnerDecodeTuiTodoSaveResult180(call180("saveTodoMarkdown", tuiOwnerInvoiceAdd180(4096, tuiOwnerInvoice180(markdown)), { => listValue([textValue(markdown)]) }))
    }

    public func copyTodoMarkdown(): String {
        let value = tuiOwnerDecodeTuiTodoLoadResult180(call180("copyTodoData180", 4096, { => listValue([]) }))
        if (!value.loaded) { return "todo copy error: " + value.message }
        if (value.markdown == "") { return "No todos to copy." }
        physicalClipboard180(value.markdown, "Copied todos as Markdown to clipboard", "todo copy error: ")
    }
    public func copyTextToClipboard(text: String): String { physicalClipboard180(text, "Copied card content to clipboard", "card copy error: ") }
    private func physicalClipboard180(text: String, success: String, errorPrefix: String): String {
        if (text == "") { return errorPrefix + "clipboard text must not be empty" }
        let paid = peer.deriveOwnerFrameData180(4096); paid.ensureRetainedPeak(tuiOwnerInvoice180(text)); retainPayment180(paid)
        let headless = match (getVariable("AGENT_TUI_HEADLESS")) { case Some(value) => value == "1" || value.toAsciiLower() == "true"; case None => false }
        let encoded = productBase64Bytes(unsafe { text.rawData() })
        let path = clipboardRoot.getOrThrow() + "/clipboard-tui-" + MonoTime.now().hashCode().toString() + ".txt"
        var native = false
        try {
            try { File.writeTo(path, text.toArray()) }
            catch (error: Exception) { return errorPrefix + error.message }
            if (headless) { return "Clipboard payload encoded for headless verification." }
            let physical = physicalClipboardProcess180()
                match (physical.execute(ProcessRequest("/bin/sh",
                    operationId: OperationId("tui-clipboard-" + MonoTime.now().hashCode().toString()),
                    arguments: ["-c",
                        "exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; " +
                        "if command -v wl-copy >/dev/null 2>&1; then setsid wl-copy < \"$1\" >/dev/null 2>&1; " +
                        "elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard < \"$1\"; " +
                        "elif command -v xsel >/dev/null 2>&1; then xsel --clipboard --input < \"$1\"; else exit 127; fi",
                        "axyndra-clipboard", path], timeoutMillis: 5000,
                    sandboxMode: ProcessSandboxMode.Host,
                    networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), displayServerAccess: true))) {
                    case Result.Ok(result) => native = result.exitCode == 0
                    case Result.Err(_) => native = false }
        } catch (_: Exception) { native = false }
        finally { if (exists(Path(path))) { remove(path) } }
        print("\u{001b}]52;c;" + encoded + "\u{0007}")
        success + if (native) { " (OSC52 + native)." } else { " (OSC52)." }
    }
    private func physicalClipboardProcess180(): LocalProcessPort {
        lock.lock()
        try {
            if (closing) { throw Exception("tui.owner_closed") }
            if (clipboardProcess180.isNone()) {
                clipboardProcess180 = Some(LocalProcessPort(LocalWorkspace(clipboardRoot.getOrThrow()),
                    lifecycleLaunchAuthority: None, modelLaunchAuthority: None))
            }
            clipboardProcess180.getOrThrow()
        } finally { lock.unlock() }
    }
    private func closePhysicalClipboardWholeHelper180(): Result<Unit> {
        match (clipboardProcess180) { case Some(actual) => actual.close(); case None => Result<Unit>.Ok(()) }
    }
    private func closePhysicalClipboard180(): Result<Unit> {
        let result = closePhysicalClipboardWholeHelper180()
        if (result.isOk()) { lock.lock(); clipboardProcess180 = None; lock.unlock() }
        result
    }
    public func beginOwnedToolDisplayProducerClosing(): Unit {
        lock.lock()
        if (closing) { lock.unlock(); return }; closing = true; lock.unlock()
        stopDelivery180()
        var closeResponseConsumed=false
        try { let _ = call180("close", 4096, { => listValue([]) }, allowClosing: true);closeResponseConsumed=true }
        finally {
            let closed = peer.closeOwnerPeer180()
            joinReaderHelper180()
            joinDeliveryWholeHelper180()
            // Only the empty EOF following our consumed close reply is a
            // cooperative control return. Partial/unknown DATA and every
            // other original reader exception stay reachable and fail close.
            lock.lock();let original=try{readerOriginalFailure180}finally{lock.unlock()}
            match(original){case Some(error)=>
                let expected=match(error as OwnedCanonicalDataFailure113){
                    case Some(known)=>closeResponseConsumed && known.error.code=="owner.peer_disconnected"
                    case None=>false}
                if(!expected){throw error}
                lock.lock();try{readerOriginalFailure180=None<Exception>}finally{lock.unlock()}
                case None=>()}
            clearDeliveryAfterJoin180()
            clearReaderCallbacks180()
            let clipboardClosed = closePhysicalClipboard180()
            closed.value().getOrThrow()
            clipboardClosed.value().getOrThrow()
        }
    }
    private func joinReaderHelper180(): Unit { match (reader) { case Some(actual) => actual.get(); case None => () } }
    private func clearReaderCallbacks180(): Unit {
        lock.lock()
        try { reader = None; observer = None; toolOutput = None; failureOutput = None; readerFailure = None; readerJoined = true }
        finally { lock.unlock() }
    }
    public func awaitOwnedToolDisplayProducerReferencesRetired(): Bool {
        lock.lock(); try { closing && readerJoined && activeTurn == 0 && clipboardProcess180.isNone() } finally { lock.unlock() }
    }
    public func discardOwnedFailureInputsAfterProducerRetirement113(retired: RetiredOwnedTuiFailureProducerFrames113): Result<Unit> {
        if (!retired.acknowledges(this) || !awaitOwnedToolDisplayProducerReferencesRetired()) { return ownedTuiDisplayError("display.failure_producer_retirement_unknown") }
        // No original Root error alias crosses this physical transport.
        Result<Unit>.Ok(())
    }
    func closeOwnerClientBackend180(): Result<Unit> {
        // Only the concrete frontend Root calls this after its original TUI
        // helper returns. Copied Screen retirement has already cleared peer
        // custody; this is actual remaining controller cleanup, not an ACK.
        lock.lock()
        try {
            if (peerValue.isSome() || !readerJoined || reader.isSome() || delivery180.isSome() ||
                readFrames180.isSome() || payments.isSome() || observer.isSome() ||
                toolOutput.isSome() || failureOutput.isSome() || state.isSome()) {
                return ownedTuiDisplayError("tui.owner_terminal_retirement_pending") }
            clipboardRoot = None
            match (metadata) { case Some(paid) => paid.close(); metadata = None; case None => () }
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    public func retireOwnedToolDisplayRegistry(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (!retired.acknowledgesRegistryProducer167(this) || !awaitOwnedToolDisplayProducerReferencesRetired()) { return ownedTuiDisplayError("display.registry_producer_pending") }
        clearCopiedDisplays180(retired)
        synchronized (stateMonitor) { state = None }
        retirePayments180()
        retireReadFrames180()
        peerValue = None
        Result<Unit>.Ok(())
    }
    private func clearCopiedDisplays180(retired: RetiredOwnedTuiScreenReferences): Unit {
        for (value in tools) { value.closeAfterWholeScreenRetirement(retired).value().getOrThrow() }; tools.clear()
        for (value in failures) { value.closeAfterWholeScreenRetirement(retired).value().getOrThrow() }; failures.clear()
        for (value in registries) { value.closeAfterWholeScreenRetirement167(retired).value().getOrThrow() }; registries.clear()
        toolAdmissions.clear(); failureAdmissions.clear()
    }
    private func detachPayment180(): ?LogicalJsonOwnerReservation {
        match (payments) {
            case None => None<LogicalJsonOwnerReservation>
            case Some(node) => let paid = node.paid; node.paid = None; payments = node.next; node.next = None; paid
        }
    }
    private func retireReadFrames180(): Unit {
        while (readFrames180.isSome()) {
            let frame = readFrames180.getOrThrow(); readFrames180 = frame.next180; frame.next180 = None
            frame.retireAfterWholeReadConsumer180()
        }
        match (readerRawPending180) { case Some(paid) => paid.close(); readerRawPending180 = None; case None => () }
    }
    private func retirePayments180(): Unit {
        while (payments.isSome()) { match (detachPayment180()) { case Some(paid) => paid.close(); case None => () } }
    }
}
