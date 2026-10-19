package agent_product

import agent_domain.*
import agent_host_runtime.HostPaidValueProjection151
import sandbox4cj.*
import std.sync.*

private let productHookProcessDebts159f = ProductHookProcessDebts159f()

// DATA custody only. The concrete hook caller derives/pays the full captured
// input invoice before constructing this carrier or either scheduler closure.
public class ProductHookProcessCustody159f {
    private let phaseLock159j = Mutex()
    private var claimed159j = false
    var nextGeneration159j: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
    private var resident159j: ?LogicalJsonOwnerReservation
    private var generationUnlinked159j = false
    private var schedulerPublished159j = false
    private var eventMeter159j: ?HostPaidValueProjection151 = None<HostPaidValueProjection151>
    private var eventMeterPayment159j: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var residentInvoice159j: Int64 = 32768
    private var payment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var inputInvoice159j: Int64 = 0
    private var source159j: ?CancellationSource = None<CancellationSource>
    private var parent159j: ?CancellationRegistration = None<CancellationRegistration>
    private var callerReturned159j = false
    private var sourceEscaped159j = false
    private var generationFrames159l: Int64 = 0
    private var localProcessStarted159j = false
    var callerId159j: Int64 = 0
    var nextCaller159j: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
    private var input: ?SandboxStdinReturn159f = None<SandboxStdinReturn159f>
    private var monitorAction: ?() -> Unit = None<() -> Unit>
    private var monitorFuture: ?Future<Unit> = None<Future<Unit>>
    private var kernelMonitor159n: ?HookKernelMonitor159n = None<HookKernelMonitor159n>
    private var kernelMonitorFunded159n = false
    private var monitorStarted = false
    private var monitorReturned = false
    private var localFrameReturned = false
    var nextDebt159f: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
    init(paid: LogicalJsonOwnerReservation) {
        resident159j = Some(paid)
        productHookProcessDebts159f.add159f(this)
        input = Some(SandboxStdinReturn159f(reserveScheduler159j: Some({ => prepayInputWriter159j() })))
    }
    // Derived from the actual Registry generation before construction.
    // SDK Future.fn does not clear; fixed headers and every scheduler pair
    // remain cumulatively paid. Only the independent input phase can retire.
    func claimActualHook159j(): Bool {
        phaseLock159j.lock()
        try {
            if (generationUnlinked159j || resident159j.isNone() || claimed159j || payment.isSome()) { return false }
            claimed159j = true; true
        } finally { phaseLock159j.unlock() }
    }
    // Fund the generation String, Active record, cancellation DATA and its
    // callback before any of those dynamic objects are constructed.
    func prepareCaller159j(pluginId: String, version: String, digest: String, root: String): Unit {
        if (!claimed159j || payment.isSome()) { throw IllegalStateException("hook caller is not exclusively claimed") }
        var bytes: Int64 = 0
        bytes = addHookProcessInputSize159j(bytes, pluginId.size)
        bytes = addHookProcessInputSize159j(bytes, version.size)
        bytes = addHookProcessInputSize159j(bytes, digest.size)
        bytes = addHookProcessInputSize159j(bytes, root.size)
        let paid = resident159j.getOrThrow().deriveRetainedLease()
        try { paid.ensureRetainedPeak(524288 + bytes * 64) }
        catch (error: Exception) { paid.close(); throw error }
        payment = Some(paid); inputInvoice159j = 524288 + bytes * 64
        callerReturned159j = false; sourceEscaped159j = false
        localProcessStarted159j = false; localFrameReturned = false
        monitorStarted = false; monitorReturned = false; kernelMonitorFunded159n = false
        input.getOrThrow().resetReturnedInput159j()
    }
    private func requireEventMeter159j(): HostPaidValueProjection151 {
        match (eventMeter159j) { case Some(value) => return value; case None => () }
        let paid = payment.getOrThrow().deriveRetainedLease()
        try { paid.ensureRetainedPeak(4096) }
        catch (error: Exception) { paid.close(); throw error }
        eventMeterPayment159j = Some(paid)
        let meter = HostPaidValueProjection151(paid)
        eventMeter159j = Some(meter); meter
    }
    // The existing indexed/default-writer meter is paid before its counter or
    // scalar temporaries. No items/fields snapshot or guessed number spelling.
    func fundEventEncoding159j(payload: AgentValue): Unit {
        let meter = requireEventMeter159j()
        let measured = meter.measureBorrowedValue151(payload)
        if (measured.bytes > Int64.Max / 4 || measured.nodes > Int64.Max / 4) {
            throw LogicalJsonPayloadError("hook event encoding invoice overflow")
        }
        meter.fundAdditional151(measured.bytes * 4, measured.nodes * 4)
    }
    func installParent159j(parent: CancellationToken): CancellationSource {
        if (payment.isNone() || source159j.isSome() || parent159j.isSome()) {
            throw IllegalStateException("hook cancellation DATA is not exclusively funded")
        }
        // Same effective deadline and same Parent code/message/timestamp as
        // the original CancellationSource(parent: Some(parent)).
        source159j = Some(CancellationSource(deadlineMillis: parent.deadlineMillis))
        parent159j = Some(parent.onCancelReturning159({ reason => forwardParent159j(reason) }))
        source159j.getOrThrow()
    }
    private func forwardParent159j(reason: CancellationReason): Unit {
        let actual = source159j.getOrThrow()
        let _ = actual.cancel(reason: Some(CancellationReason(CancellationReasonKind.Parent,
            "process.parent_cancelled", reason.message, cancelledAtMillis: reason.cancelledAtMillis)))
    }
    func disposeParent159j(): Unit {
        match (parent159j) { case Some(value) => value.dispose(); case None => () }
    }
    // A generation cancellation batch is a separate real source consumer.
    // Unknown consumers keep this phase; typed batches use the exact counter below.
    func holdGenerationCancellation159j(): Unit { sourceEscaped159j = true }
    // This is DATA custody for the exact private cancellation source only.
    // The existing caller invoice already reserves cancellation DATA/cause
    // metadata; no service permission, Source mint or caller bank is accepted.
    func enterGenerationCancellation159l(actual: CancellationSource): Bool {
        phaseLock159j.lock()
        try {
            if (!claimed159j || payment.isNone() || source159j.isNone() || sourceEscaped159j ||
                generationFrames159l == Int64.Max) { return false }
            if (!refEq(source159j.getOrThrow(), actual)) { return false }
            generationFrames159l++; true
        } finally { phaseLock159j.unlock() }
    }
    func returnedGenerationCancellation159l(): Unit {
        phaseLock159j.lock()
        try {
            if (generationFrames159l < 1) { throw IllegalStateException("hook source batch was not entered") }
            generationFrames159l--
        } finally { phaseLock159j.unlock() }
    }
    private func generationCancellationReturned159l(): Bool {
        phaseLock159j.lock(); try { generationFrames159l == 0 } finally { phaseLock159j.unlock() }
    }
    func wholeCallerReturned159j(): Unit { callerReturned159j = true }
    func beginInputPhase159j(operationId: String, packageRoot: String,
        command: String, standardInput: String): Unit {
        if (!claimed159j || payment.isNone() || localProcessStarted159j ||
            monitorAction.isSome() || monitorFuture.isSome() || kernelMonitor159n.isSome() || input.getOrThrow().inputDataRetained159f()) {
            throw IllegalStateException("prior hook process input has not returned")
        }
        var bytes: Int64 = 0
        bytes = addHookProcessInputSize159j(bytes, operationId.size)
        bytes = addHookProcessInputSize159j(bytes, packageRoot.size)
        bytes = addHookProcessInputSize159j(bytes, command.size)
        bytes = addHookProcessInputSize159j(bytes, standardInput.size)
        let extra = 524288 + bytes * 64
        if (inputInvoice159j > 134217728 - extra) {
            throw LogicalJsonPayloadError("hook input phases exceed original aggregate")
        }
        payment.getOrThrow().ensureRetainedPeak(inputInvoice159j + extra)
        inputInvoice159j += extra; localProcessStarted159j = true
    }
    private func fundSchedulerMetadata159j(): Unit {
        if (residentInvoice159j > 134217728 - 8192) {
            throw LogicalJsonPayloadError("hook scheduler metadata exceeds original aggregate")
        }
        resident159j.getOrThrow().ensureRetainedPeak(residentInvoice159j + 8192)
        residentInvoice159j += 8192
        schedulerPublished159j = true
    }
    func prepayInputWriter159j(): Unit {
        if (payment.isNone()) { throw IllegalStateException("hook input is not paid") }
        fundSchedulerMetadata159j()
    }
    func inputWriter159f(): SandboxStdinReturn159f { input.getOrThrow() }
    func fundKernelMonitor159n(): Unit {
        if (payment.isNone() || kernelMonitorFunded159n || monitorStarted || kernelMonitor159n.isSome()) {
            throw IllegalStateException("Hook monitor DATA phase is unavailable")
        }
        if (inputInvoice159j > 134217728 - 32768) { throw LogicalJsonPayloadError("Hook monitor DATA invoice overflow") }
        payment.getOrThrow().ensureRetainedPeak(inputInvoice159j + 32768)
        inputInvoice159j += 32768; kernelMonitorFunded159n = true
    }
    func startKernelMonitor159n(poll: () -> Int64, cancel: () -> Unit): Unit {
        if (!kernelMonitorFunded159n || monitorStarted || kernelMonitor159n.isSome()) {
            throw IllegalStateException("Hook monitor was not funded")
        }
        monitorStarted = true
        kernelMonitor159n = Some(createHookKernelMonitor159n(payment.getOrThrow(), poll, cancel))
    }
    func installMonitor159f(action: () -> Unit): Unit {
        if (monitorStarted || monitorAction.isSome()) { throw IllegalStateException("hook monitor already installed") }
        monitorAction = Some(action)
    }
    func startMonitor159f(): Unit {
        if (monitorStarted || monitorAction.isNone()) { throw IllegalStateException("hook monitor unavailable") }
        if (payment.isNone()) { throw IllegalStateException("hook monitor input is not paid") }
        fundSchedulerMetadata159j()
        monitorStarted = true
        monitorFuture = Some(spawn { runMonitorFrame159f() })
    }
    private func runMonitorFrame159f(): Unit { monitorAction.getOrThrow()() }
    func joinMonitor159f(): Unit {
        if (kernelMonitor159n.isSome()) {
            joinProductHookKernelFrame159n(kernelMonitor159n.getOrThrow())
            clearKernelMonitorFrame159n()
            monitorReturned = true
            return
        }
        joinProductHookMonitorFrame159f(monitorFuture.getOrThrow())
        monitorFuture = None<Future<Unit>>
        clearMonitorActionFrame159f()
        monitorReturned = true
    }
    private func clearKernelMonitorFrame159n(): Unit { kernelMonitor159n = None<HookKernelMonitor159n> }
    private func clearMonitorActionFrame159f(): Unit { monitorAction = None<() -> Unit> }
    func returnedLocalProcessFrame159f(): Unit { localFrameReturned = true }
    public func privateInputsReturned159f(): Bool {
        callerReturned159j && !sourceEscaped159j && generationCancellationReturned159l() &&
            (!localProcessStarted159j || localFrameReturned) && (!monitorStarted || monitorReturned) &&
            monitorFuture.isNone() && monitorAction.isNone() && kernelMonitor159n.isNone() &&
            !input.getOrThrow().inputDataRetained159f() &&
            (match (parent159j) { case Some(value) => value.callbacksReturned159(); case None => true })
    }
    func returnPrivateHookProcessFrame159f(): Bool {
        if (!privateInputsReturned159f()) { return false }
        let meterPayment = clearEventMeterFrame159j()
        match (meterPayment) { case Some(value) => value.close(); case None => () }
        let paid = clearPrivateHookProcessFrame159f()
        match (paid) { case Some(value) => value.close(); case None => () }
        tryReturnNeverScheduledResident159j()
        true
    }
    private func clearEventMeterFrame159j(): ?LogicalJsonOwnerReservation {
        // Keep the concrete meter and original lease reachable if its own
        // retirement rejects. Only its complete successful call permits unlink.
        match (eventMeter159j) { case Some(value) => value.closeUnpublished151(); case None => () }
        eventMeter159j = None<HostPaidValueProjection151>
        let paid = eventMeterPayment159j; eventMeterPayment159j = None<LogicalJsonOwnerReservation>
        paid
    }
    func returnedGenerationLink159j(): Unit {
        phaseLock159j.lock(); try { generationUnlinked159j = true } finally { phaseLock159j.unlock() }
        tryReturnNeverScheduledResident159j()
    }
    private func tryReturnNeverScheduledResident159j(): Unit {
        let paid = clearNeverScheduledResidentFrame159j()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
    private func clearNeverScheduledResidentFrame159j(): ?LogicalJsonOwnerReservation {
        phaseLock159j.lock()
        try {
            if (!generationUnlinked159j || schedulerPublished159j || claimed159j || payment.isSome() ||
                parent159j.isSome() || source159j.isSome() || nextCaller159j.isSome() || nextGeneration159j.isSome() ||
                monitorFuture.isSome() || monitorAction.isSome() || kernelMonitor159n.isSome() || eventMeter159j.isSome() || eventMeterPayment159j.isSome()) {
                return None<LogicalJsonOwnerReservation>
            }
            if (resident159j.isNone()) { return None<LogicalJsonOwnerReservation> }
            input = None<SandboxStdinReturn159f>
            let paid = resident159j; resident159j = None<LogicalJsonOwnerReservation>
            productHookProcessDebts159f.remove159f(this); paid
        } finally { phaseLock159j.unlock() }
    }
    private func clearPrivateHookProcessFrame159f(): ?LogicalJsonOwnerReservation {
        phaseLock159j.lock()
        try {
            if (generationFrames159l != 0) { throw IllegalStateException("actual source cancellation batch is still borrowed") }
            source159j = None<CancellationSource>; parent159j = None<CancellationRegistration>
            let paid = payment; payment = None<LogicalJsonOwnerReservation>
            inputInvoice159j = 0; callerId159j = 0
            claimed159j = false
            // The fixed header/empty input cell remains registered and paid.
            paid
        } finally { phaseLock159j.unlock() }
    }
}
private func joinProductHookMonitorFrame159f(value: Future<Unit>): Unit { value.get() }
private func joinProductHookKernelFrame159n(value: HookKernelMonitor159n): Unit { value.awaitReturned159n() }
private class ProductHookProcessDebts159f {
    private let lock = Mutex()
    private var first: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
    func add159f(value: ProductHookProcessCustody159f): Unit {
        lock.lock(); try { value.nextDebt159f = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159f(value: ProductHookProcessCustody159f): Unit {
        lock.lock()
        try {
            var previous: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (previous) { case Some(prior) => prior.nextDebt159f = current.nextDebt159f; case None => first = current.nextDebt159f }
                    current.nextDebt159f = None<ProductHookProcessCustody159f>; return
                }
                previous = cursor; cursor = current.nextDebt159f
            }
            throw IllegalStateException("hook process input was not registered")
        } finally { lock.unlock() }
    }
}

private func addHookProcessInputSize159j(total: Int64, bytes: Int64): Int64 {
    if (bytes < 0 || total < 0 || total > (134217728 - 524288) / 64 - bytes) {
        throw LogicalJsonPayloadError("hook process input exceeds original aggregate")
    }
    total + bytes
}
