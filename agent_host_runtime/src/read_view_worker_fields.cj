package agent_host_runtime

import agent_domain.*
import std.fs.*

// Only a refusal by the worker's own pre-launch DATA payer has this type.
// Native output and process failures keep their existing outcome classification.
class HostReadViewMetadataCapacity <: Exception {
    init() { super("cannot fund read-view execution fields") }
}

func readViewMetadataBudgetError(): AgentError {
    AgentError(AgentErrorKind.BudgetExceeded, "read_view.metadata_capacity", "cannot fund read-view execution fields",
        retryable: false, fallbackAllowed: false)
}

func deriveReadViewDataLease(work: LogicalJsonOwnerReservation): LogicalJsonOwnerReservation {
    try { work.deriveRetainedLease() } catch (_: LogicalJsonPayloadError) { throw HostReadViewMetadataCapacity() }
}

private func prepayReadViewData(work: LogicalJsonOwnerReservation, invoice: Int64): Unit {
    try { work.ensureRetainedPeak(invoice) } catch (_: LogicalJsonPayloadError) { throw HostReadViewMetadataCapacity() }
}

// Used by one synchronous read-view execution only. Process/inspector/ToolResult
// consumers can save raw text independently; the private writer and witness
// cannot. A process status, output callback or view cleanup retires neither.
class HostReadViewWorkerFields {
    let input: ToolResolverInput
    private let work: LogicalJsonOwnerReservation
    private let local: HostReadViewTextCopies
    private let escaped: HostReadViewTextCopies
    private let holder: HostReadViewPublishedText
    var published = false
    init(input: ToolResolverInput, work: LogicalJsonOwnerReservation, exports: LogicalJsonOwnerReservation) {
        this.input = input; this.work = work
        local = HostReadViewTextCopies(work); escaped = HostReadViewTextCopies(exports)
        holder = HostReadViewPublishedText(exports)
    }
    func text(field: ToolResolverText, external!: Bool = false): String {
        if (!external) { return local.copy(input, field) }
        let result = escaped.copy(input, field)
        if (!published) { holder.publish(); published = true }
        result
    }
    func root(name: String, external!: Bool = false): String {
        text(ToolResolverText.Scalar([ToolResolverStep.Field(name)]), external: external)
    }
    func request(name: String): String {
        text(ToolResolverText.Scalar([ToolResolverStep.Field("intent"), ToolResolverStep.Field("request"), ToolResolverStep.Field(name)]))
    }
    func resource(index: Int64, name: String): ToolResolverText {
        ToolResolverText.Scalar([ToolResolverStep.Field("intent"), ToolResolverStep.Field("resources"),
            ToolResolverStep.Index(index), ToolResolverStep.Field(name)])
    }
    func argument(index: Int64): String {
        text(ToolResolverText.Scalar([ToolResolverStep.Field("intent"), ToolResolverStep.Field("request"),
            ToolResolverStep.Field("arguments"), ToolResolverStep.Index(index)]), external: true)
    }
    func writeInputFile(path: String): Bool {
        let payment = deriveReadViewDataLease(work)
        try { writeReadViewInput(path, input, payment) } finally { payment.close() }
    }
}

// Each instance is private to one synchronous worker and one exclusive lease.
// SUM copied fields even if their text compares equal. Read one byte past the
// measured size so a changed or revoked source can never produce a truncated ID.
private class HostReadViewTextCopies {
    private let payment: LogicalJsonOwnerReservation
    private var invoice: Int64 = 16384
    init(payment: LogicalJsonOwnerReservation) {
        prepayReadViewData(payment, invoice); this.payment = payment
    }
    func copy(input: ToolResolverInput, field: ToolResolverText): String {
        let size = input.byteCount(field)
        if (invoice > Int64.Max - 1024 || size > (Int64.Max - invoice - 1024) / 8) {
            throw HostReadViewMetadataCapacity()
        }
        let next = invoice + 1024 + size * 8
        prepayReadViewData(payment, next); invoice = next
        let bytes = Array<Byte>(size + 1, repeat: 0)
        if (input.readBytes(field, 0, bytes) != size) { throw IllegalStateException("read-view field changed during copy") }
        String.fromUtf8(bytes[0..size])
    }
}

private func writeReadViewInput(path: String, input: ToolResolverInput, payment: LogicalJsonOwnerReservation): Bool {
    // The common input is encoded once. Longer inputs are bounded and measured
    // by the same encoder before allocating their exact independent destination.
    prepayReadViewData(payment, 65536 + 8 * 4096)
    let small = Array<Byte>(4096, repeat: 0)
    let count = match (resolverEncodeReadViewInput(input, small)) { case Some(n) => n; case None => return false }
    if (count <= small.size) { File.writeTo(path, small[0..count]); return true }
    prepayReadViewData(payment, 65536 + 8 * (small.size + count))
    let exact = Array<Byte>(count, repeat: 0)
    match (resolverEncodeReadViewInput(input, exact)) {
        case Some(n) => if (n != count) { return false }
        case None => return false
    }
    File.writeTo(path, exact); true
}
