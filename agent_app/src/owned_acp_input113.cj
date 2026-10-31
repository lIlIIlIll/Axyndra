package agent_app

import agent_domain.*
import agent_rpc.*
import process4cj.*
import std.collection.*

// Main's original control pays this reader before construction. Each
// readFdChunk buffer/slice, retained pending buffer and actual input String
// has its own derived share from that same original bank. No raw String is
// returned to an unowned frontend.
class AcpOwnedJsonlInput113 <: AcpFrontendCustody113 {
    private let control: AcpOwnedWorkerControl113
    private var metadata: ?LogicalJsonOwnerReservation
    private var pending = ArrayList<Byte>()
    private var pendingPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var retiringPending: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var chunk: ?Array<Byte> = None<Array<Byte>>
    private var chunkPayment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var offset: Int64 = 0
    private var line: ?AcpOwnedInput113 = None<AcpOwnedInput113>
    private var unregisteredLine: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var lineDelivered = false
    private var polling = false
    private var eof = false
    private var retired = false
    private let maxLineBytes: Int64 = 8388608
    init(control: AcpOwnedWorkerControl113, payment: LogicalJsonOwnerReservation) {
        this.control = control; this.metadata = Some(payment)
    }
    private func ensurePending113(bytes: Int64): Unit {
        if (pendingPayment.isNone()) {
            // Publish the exact child before ArrayList capacity can grow.
            pendingPayment = Some(control.deriveFrontendMetadata113(4096))
        }
        pendingPayment.getOrThrow().ensureRetainedPeak(
            acpFrontendAdd113(4096, acpFrontendMultiply113(bytes, 8)))
    }
    func poll113(timeoutMillis: Int32): (Bool, ?AcpOwnedInput113) {
        if (retired || polling || lineDelivered) {
            throw IllegalStateException("ACP keeps an unconsumed owned input")
        }
        polling = true
        let answer = try { pollHelper113(timeoutMillis) }
            finally { polling = false }
        // The scan/toArray/fromUtf8 helpers have physically returned. Retire
        // the old pending Array only after those producer aliases are gone.
        retirePendingAfterScanReturn113()
        if (chunk.isNone() && chunkPayment.isSome()) {
            chunkPayment.getOrThrow().close()
            chunkPayment = None<LogicalJsonOwnerReservation>
        }
        answer
    }
    private func pollHelper113(timeoutMillis: Int32): (Bool, ?AcpOwnedInput113) {
        if (line.isSome()) { lineDelivered = true; return (false, line) }
        if (eof) { return (true, None<AcpOwnedInput113>) }
        if (chunk.isNone()) {
            if (!waitReadableFd(0, timeoutMillis)) { return (false, None<AcpOwnedInput113>) }
            if (chunkPayment.isSome()) {
                throw IllegalStateException("ACP retains a previous read helper payment")
            }
            // readFdChunk allocates its 8192-byte buffer and returned slice.
            // Pay both BEFORE the real syscall and store the lease first.
            chunkPayment = Some(control.deriveFrontendMetadata113(4096 + 4 * 8192))
            chunk = readFdChunk(0)
            offset = 0
            if (chunk.isNone()) {
                eof = true
                if (!pending.isEmpty()) {
                    prepareLineHelper113()
                    lineDelivered = true
                    return (false, line)
                }
                return (true, None<AcpOwnedInput113>)
            }
        }
        let actual = chunk.getOrThrow()
        while (offset < actual.size) {
            let byte = actual[offset]
            if (byte == b'\n') {
                // A refused allocation leaves the original buffer, byte and
                // offset reachable; it never drops/retries a handled request.
                prepareLineHelper113()
                offset++
                lineDelivered = true
                return (false, line)
            }
            if (pending.size >= maxLineBytes) {
                throw ProcessError(ProcessErrorKind.Frame,
                    "line frame exceeds configured byte limit")
            }
            ensurePending113(acpFrontendAdd113(pending.size, 1))
            pending.add(byte)
            offset++
        }
        chunk = None<Array<Byte>>
        offset = 0
        (false, None<AcpOwnedInput113>)
    }
    private func prepareLineHelper113(): Unit {
        if (line.isSome() || unregisteredLine.isSome() || retiringPending.isSome()) {
            throw IllegalStateException("ACP retains a previous input producer")
        }
        let invoice = acpFrontendAdd113(4096,
            acpFrontendMultiply113(acpFrontendAdd113(pending.size, 1), 8))
        let paid = control.deriveFrontendMetadata113(invoice)
        unregisteredLine = Some(paid)
        // Array/slice/String overlap is funded before this producer closure
        // is constructed. Parsing grows this SAME line owner later.
        let input = AcpOwnedInput113(paid, invoice, { =>
            let bytes = pending.toArray()
            let end = if (!bytes.isEmpty() && bytes[bytes.size - 1] == b'\r') {
                bytes.size - 1 } else { bytes.size }
            String.fromUtf8(bytes[..end])
        })
        line = Some(input)
        unregisteredLine = None<LogicalJsonOwnerReservation>
        retiringPending = pendingPayment
        pendingPayment = None<LogicalJsonOwnerReservation>
        pending = ArrayList<Byte>()
    }
    private func retirePendingAfterScanReturn113(): Unit {
        match (retiringPending) {
            case None => ()
            case Some(paid) => paid.close(); retiringPending = None<LogicalJsonOwnerReservation>
        }
    }
    // Called by Main only AFTER the complete server.handleOwnedInput helper
    // physically returned. A failed handoff keeps that same String/owner here.
    func retireHandledInputAfterHelperReturn113(): Bool {
        match (line) {
            case None => false
            case Some(actual) =>
                if (!actual.retireAfterHandlerReturn113()) { return false }
                line = None<AcpOwnedInput113>; lineDelivered = false; true
        }
    }
    func destroyInputAfterFailedFrontendReturn113(): Bool {
        if (polling || retired) { return retired }
        // The server has already removed its input alias AFTER real complete
        // close/producer/output helpers return. No retry or display ACK.
        match (line) { case Some(actual) => if (!actual.destroyAfterFailedFrontendReturn113()) { return false }; case None => () }
        line = None<AcpOwnedInput113>; lineDelivered = false
        pending = ArrayList<Byte>(); chunk = None<Array<Byte>>; offset = 0
        // These detached array/String helpers have returned before parent
        // retirement enters Native close for their original registered shares.
        eof = true; true
    }

    public func retireAfterFrontendHelperReturn113(): Bool {
        if (retired) { return true }
        if (polling || line.isSome() || chunk.isSome() || !pending.isEmpty()) {
            return false
        }
        retirePendingAfterScanReturn113()
        match (unregisteredLine) {
            case Some(paid) => paid.close(); unregisteredLine = None<LogicalJsonOwnerReservation>
            case None => () }
        match (chunkPayment) {
            case Some(paid) => paid.close(); chunkPayment = None<LogicalJsonOwnerReservation>
            case None => () }
        match (pendingPayment) {
            case Some(paid) => paid.close(); pendingPayment = None<LogicalJsonOwnerReservation>
            case None => () }
        metadata.getOrThrow().close(); metadata = None<LogicalJsonOwnerReservation>
        retired = true; true
    }
    public func isRetired113(): Bool { retired }
}

func acpFrontendAdd113(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > Int64.Max - left) {
        throw IllegalArgumentException("ACP frontend retained invoice overflow") }
    left + right
}
func acpFrontendMultiply113(value: Int64, count: Int64): Int64 {
    if (value < 0 || count < 1 || value > Int64.Max / count) {
        throw IllegalArgumentException("ACP frontend retained invoice overflow") }
    value * count
}
