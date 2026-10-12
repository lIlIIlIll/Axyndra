package tool_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.AuditPort
import std.sync.*
import yjson.*
import yjson_support.*

private let preparedPlanWireDebts204 = PreparedPlanWireDebts204()

// A separately prepaid copy. This owner never exports its Array, String,
// original Plan, Context or Catalog. Saving a returned handle retains only a
// closed shell; receiver-created copies retain their own original-bank leases.
public class OwnedPreparedPlanUtf8204 <: PreparedPlanUtf8Owner204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var producerPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var auditEvent: ?AgentEvent = None<AgentEvent>
    private var originalPlan: ?NormalizedOperationPlan = None<NormalizedOperationPlan>
    private var producerValue: ?AgentValue = None<AgentValue>
    private var producerText: ?String = None<String>
    private var bytes: ?Array<UInt8> = None<Array<UInt8>>
    private var producerReturned = false
    private var closeRequested = false
    private var closing = false
    private var closed = false
    private var readFrames: Int64 = 0
    var nextWire204: ?OwnedPreparedPlanUtf8204 = None<OwnedPreparedPlanUtf8204>
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment)
        preparedPlanWireDebts204.register204(this)
    }
    func installPlanFrame204(plan: NormalizedOperationPlan): Unit {
        lock.lock()
        try {
            if (originalPlan.isSome() || producerReturned || closed || payment.isNone()) {
                throw IllegalStateException("prepared plan DATA producer is unavailable") }
            beginProducerPaymentFrame204()
            originalPlan = Some(plan)
            // Fixed scanner, recursive stack, numeric formatter and closure
            // have already been paid before this meter is constructed.
            let meter = HubProcessPlanInvoice180({ minimum => producerPayment.getOrThrow().ensureRetainedPeak(minimum) })
            meter.includePlan(plan)
            producerPayment.getOrThrow().ensureRetainedPeak(meter.retainedPeak())
            producerValue = Some(preparedPlanWireValue204(plan))
            producerText = Some(encodeStoredValue204(producerValue.getOrThrow()))
            let actualBytes = unsafe { producerText.getOrThrow().rawData().size }
            if (actualBytes > (Int64.Max - 131072) / 4) { throw LogicalJsonPayloadError("prepared byte invoice overflow") }
            payment.getOrThrow().ensureRetainedPeak(131072 + actualBytes * 4)
            bytes = Some(producerText.getOrThrow().toArray())
        } finally { lock.unlock() }
    }
    func fundAuditInputFrame204(context: ToolInvocationContext, action: String,
        call: ToolCall, capability: Capability, metadata: ?ToolApprovalMetadata): Unit {
        lock.lock()
        try {
            if (producerReturned || closed || payment.isNone()) {
                throw IllegalStateException("Audit DATA producer is unavailable") }
            beginProducerPaymentFrame204()
            let meter = HubProcessPlanInvoice180({ minimum => producerPayment.getOrThrow().ensureRetainedPeak(minimum) })
            // Hashing the original arguments and the complete original Audit
            // event builder are paid before either constructs a DOM/String.
            meter.includeRequest180(call.arguments)
            var text: Int64 = 0
            for (value in [action, call.name, call.callId, capability.resource, context.runId.value]) {
                if (text > Int64.Max - value.size) { throw LogicalJsonPayloadError("Audit input text invoice overflow") }
                text += value.size
            }
            var nodes: Int64 = 64
            match (metadata) { case Some(value) =>
                if (text > Int64.Max - value.capabilityLabel.size) { throw LogicalJsonPayloadError("Audit permission invoice overflow") }
                text += value.capabilityLabel.size
                for (flag in value.assessment.flags) {
                    if (text > Int64.Max - flag.size || nodes == Int64.Max) { throw LogicalJsonPayloadError("Audit input invoice overflow") }
                    text += flag.size; nodes++ }
                for (reason in value.assessment.reasons) {
                    if (text > Int64.Max - reason.size || nodes == Int64.Max) { throw LogicalJsonPayloadError("Audit input invoice overflow") }
                    text += reason.size; nodes++ }
                case None => () }
            let base = meter.retainedPeak()
            if (text < 0 || text > (Int64.Max-base)/384 || nodes > (Int64.Max-base-text*384)/2048) {
                throw LogicalJsonPayloadError("Audit input complete SUM overflow") }
            producerPayment.getOrThrow().ensureRetainedPeak(base + text*384 + nodes*2048)
        } finally { lock.unlock() }
    }
    func installAuditEventFrame204(event: AgentEvent): Unit {
        lock.lock()
        try {
            if (producerReturned || closed || payment.isNone() || producerValue.isSome()) {
                throw IllegalStateException("Audit DATA event producer is unavailable") }
            // Only the independently paid envelope is sent to the consumer.
            // It has the same actual Run and complete original event detail.
            auditEvent = Some(event)
            producerValue = Some(objectValue([ValueField("run_id", textValue(event.runId.value)),
                ValueField("detail", eventProtocolDetail(event)),
                ValueField("event204", preparedPersistedAuditEventValue204(event))]))
            let meter = HubProcessPlanInvoice180({ minimum => producerPayment.getOrThrow().ensureRetainedPeak(minimum) })
            meter.includeRequest180(producerValue.getOrThrow())
            producerPayment.getOrThrow().ensureRetainedPeak(meter.retainedPeak())
            producerText = Some(encodeStoredValue204(producerValue.getOrThrow()))
            let actualBytes = unsafe { producerText.getOrThrow().rawData().size }
            if (actualBytes > (Int64.Max - 131072) / 4) { throw LogicalJsonPayloadError("prepared byte invoice overflow") }
            payment.getOrThrow().ensureRetainedPeak(131072 + actualBytes * 4)
            bytes = Some(producerText.getOrThrow().toArray())
        } finally { lock.unlock() }
    }
    func installPermissionGrantFrame204(scope: ApprovalGrantScope): Unit {
        lock.lock()
        try {
            if (producerReturned || closed || payment.isNone()) {
                throw IllegalStateException("permission DATA producer is unavailable") }
            beginProducerPaymentFrame204()
            var size: Int64 = 0
            for (text in [scope.capability, scope.pathPrefix, scope.toolName, scope.host]) {
                if (size > Int64.Max - text.size) { throw LogicalJsonPayloadError("permission input invoice overflow") }
                size += text.size
            }
            if (size > (Int64.Max - 262144) / 384) { throw LogicalJsonPayloadError("permission input complete SUM overflow") }
            producerPayment.getOrThrow().ensureRetainedPeak(262144 + size * 384)
            producerValue = Some(preparedPermissionGrantValue204(scope))
            let meter = HubProcessPlanInvoice180({ minimum => producerPayment.getOrThrow().ensureRetainedPeak(minimum) })
            meter.includeRequest180(producerValue.getOrThrow())
            producerPayment.getOrThrow().ensureRetainedPeak(meter.retainedPeak())
            producerText = Some(encodeStoredValue204(producerValue.getOrThrow()))
            let actualBytes = unsafe { producerText.getOrThrow().rawData().size }
            if (actualBytes > (Int64.Max - 131072) / 4) { throw LogicalJsonPayloadError("permission byte invoice overflow") }
            payment.getOrThrow().ensureRetainedPeak(131072 + actualBytes * 4)
            bytes = Some(producerText.getOrThrow().toArray())
        } finally { lock.unlock() }
    }
    private func beginProducerPaymentFrame204(): Unit {
        if (producerPayment.isSome()) { throw IllegalStateException("prepared DATA producer is already paid") }
        // Register the real reservation in the reachable carrier before any
        // retained producer allocation or original graph capture.
        let child = payment.getOrThrow().deriveRetainedLease()
        producerPayment = Some(child)
        child.ensureRetainedPeak(131072)
    }
    private func closeReturnedProducerPaymentFrame204(): Unit {
        match (producerPayment) { case Some(value) => value.close(); case None => () }
    }
    func requiresRawAuditCompatibility204(): Bool {
        lock.lock(); try { bytes.getOrThrow().size > 8388608 } finally { lock.unlock() }
    }
    func appendRawAuditCompatibility204(receiver: AuditPort): Result<Unit> {
        // This is deliberately never cleared or refunded: a legacy receiver
        // may save the actual event/DOM. Both independent child payments stay
        // in the global registered carrier; it is not a Catalog-return ACK.
        receiver.append(auditEvent.getOrThrow())
    }
    // The entire invoice/DOM/framed writer/UTF8 producer helper returned Unit
    // before the original graph references are dropped in this full helper.
    func producerFrameReturned204(): Unit {
        lock.lock()
        try {
            if (producerReturned || bytes.isNone()) { throw IllegalStateException("prepared plan DATA producer did not return") }
            originalPlan = None<NormalizedOperationPlan>
            producerValue = None<AgentValue>; producerText = None<String>
            auditEvent = None<AgentEvent>
        } finally { lock.unlock() }
        // The entire producer and clear helper returned before this child
        // returns. The independent byte child stays live for the consumer.
        closeReturnedProducerPaymentFrame204()
        lock.lock()
        try { producerPayment = None<LogicalJsonOwnerReservation>; producerReturned = true }
        finally { lock.unlock() }
        collectClosed204()
    }
    public prop byteCount: Int64 {
        get() {
            enterRead204()
            try { readByteCountFrame204() } finally { returnRead204() }
        }
    }
    public func byteAt(index: Int64): UInt8 {
        enterRead204()
        try { readByteFrame204(index) } finally { returnRead204() }
    }
    public func deriveCopiedPlanPayment204(invoice: Int64): LogicalJsonOwnerReservation {
        enterRead204()
        try { derivePaymentFrame204(invoice) } finally { returnRead204() }
    }
    private func readByteCountFrame204(): Int64 {
        lock.lock(); try { bytes.getOrThrow().size } finally { lock.unlock() }
    }
    private func readByteFrame204(index: Int64): UInt8 {
        lock.lock(); try { bytes.getOrThrow()[index] } finally { lock.unlock() }
    }
    private func derivePaymentFrame204(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (invoice < 0 || invoice > 1073741824) { throw LogicalJsonPayloadError("prepared plan copy invoice exceeds the original retained bound") }
            let child = payment.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(invoice); child }
            catch (error: Exception) { child.close(); throw error }
        } finally { lock.unlock() }
    }
    private func enterRead204(): Unit {
        lock.lock()
        try {
            if (!producerReturned || closeRequested || closed || closing || bytes.isNone() || readFrames == Int64.Max) {
                throw IllegalStateException("prepared plan DATA owner is not readable") }
            readFrames++
        } finally { lock.unlock() }
    }
    private func returnRead204(): Unit {
        lock.lock()
        try {
            if (readFrames < 1) { throw IllegalStateException("prepared plan read frame underflow") }
            readFrames--
        } finally { lock.unlock() }
        // Every original Array/payment borrow is confined to the preceding
        // whole private helper, which has returned before this scalar gate.
        collectClosed204()
    }
    public func closeAfterWholeCaller204(): Unit {
        lock.lock(); try { closeRequested = true } finally { lock.unlock() }
        collectClosed204()
    }
    private func collectClosed204(): Unit {
        lock.lock()
        let claim = try {
            if (!closeRequested || !producerReturned || readFrames != 0 || closing || closed) { false }
            else { closing = true; true }
        } finally { lock.unlock() }
        if (!claim) { return }
        clearReturnedBytesFrame204()
        // The full unlink helper clears this exact intrusive graph link before
        // its fixed node/header payment may return. No global debt sweep runs.
        preparedPlanWireDebts204.remove204(this)
        // This actual reservation stays in the reachable carrier field until
        // its concrete locked scalar-ledger close fully returns; that method
        // has no external callback/I/O. Receiver reservations are not closed.
        closePaymentFrame204()
        clearClosedPaymentFrame204()
    }
    private func clearReturnedBytesFrame204(): Unit {
        lock.lock()
        try {
            if (readFrames != 0 || originalPlan.isSome() || producerValue.isSome() || producerText.isSome() || auditEvent.isSome() || producerPayment.isSome()) {
                throw IllegalStateException("prepared plan producer/reader is still active") }
            bytes = None<Array<UInt8>>
        } finally { lock.unlock() }
    }
    private func closePaymentFrame204(): Unit {
        match (payment) { case Some(value) => value.close(); case None => () }
    }
    private func clearClosedPaymentFrame204(): Unit {
        lock.lock()
        try { payment = None<LogicalJsonOwnerReservation>; closed = true }
        finally { lock.unlock() }
    }
}

private class PreparedPlanWireDebts204 {
    private let lock = Mutex()
    private var first: ?OwnedPreparedPlanUtf8204 = None<OwnedPreparedPlanUtf8204>
    func register204(value: OwnedPreparedPlanUtf8204): Unit {
        lock.lock(); try { value.nextWire204 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: OwnedPreparedPlanUtf8204): Unit {
        lock.lock()
        try {
            var previous: ?OwnedPreparedPlanUtf8204 = None<OwnedPreparedPlanUtf8204>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (previous) { case Some(parent) => parent.nextWire204 = current.nextWire204
                        case None => first = current.nextWire204 }
                    current.nextWire204 = None<OwnedPreparedPlanUtf8204>; return
                }
                previous = cursor; cursor = current.nextWire204
            }
            throw IllegalStateException("prepared plan DATA debt is missing")
        } finally { lock.unlock() }
    }
}
