package logical_json_payload

import std.collection.*
import std.sync.*

// Only already-measured, bounded frontend copies and their real metadata.
// This never pays a logical JSON message, canonical DOM or worker declaration.
// Every fixed ticket comes from the original private bank. The caller must
// clear all copied data/frame/cache references before retiring its handle.
func logicalJsonAcquireCopiedDisplay(owner: LogicalJsonOwnerBudget,
    totalInvoice: Int64): PayloadDataResult<LogicalJsonCopiedDisplayAllocation> {
    if (totalInvoice < 1 || totalInvoice > Int64.Max - 8192) {
        return logicalJsonCopiedDisplayError("display.invoice_invalid") }
    var tickets: ?LogicalJsonCopiedDisplayTicket = None
    var count: Int64 = 0
    try {
        var remaining = totalInvoice + 8192
        while (remaining > 0) {
            let extent = min(65280, remaining)
            let ticket = owner.acquireFixedBuffer(max(1024, extent + 256))
            try { tickets = Some(LogicalJsonCopiedDisplayTicket(ticket, tickets)); count++ }
            catch (error: Exception) { ticket.close(); throw error }
            remaining -= extent
        }
        PayloadDataResult.Ok(LogicalJsonCopiedDisplayAllocation(
            LogicalJsonCopiedDisplayState(owner, tickets, count, totalInvoice), None))
    } catch (_: Exception) {
        // A node is detached and completely cleared in a helper frame that
        // ends BEFORE its original fixed ticket refunds. No retained array
        // capacity or old node points to that ticket after a failed acquire.
        while (tickets.isSome()) {
            let retired = logicalJsonTakeCopiedDisplayTicket(tickets)
            tickets = retired[0]; retired[1].close()
        }
        logicalJsonCopiedDisplayError("display.original_bank_pressure")
    }
}

func logicalJsonCopiedDisplayError<T>(code: String): PayloadDataResult<T> {
    PayloadDataResult.Err(code)
}

class LogicalJsonCopiedDisplayState {
    private let lock = Mutex()
    private let owner: LogicalJsonOwnerBudget
    private var invoice: Int64
    private var additional: ?LogicalJsonCopiedDisplayTicket
    private var additionalCount: Int64
    private var references: Int64 = 1
    private var borrows: Int64 = 0
    private var released = false
    init(owner: LogicalJsonOwnerBudget, tickets: ?LogicalJsonCopiedDisplayTicket,
        count: Int64, invoice: Int64) {
        this.owner = owner; this.additional = tickets; this.additionalCount = count; this.invoice = invoice
    }
    func ensureRetainedPeak(totalInvoice: Int64): PayloadDataResult<Unit> {
        lock.lock()
        try {
            if (released || totalInvoice < 1 || totalInvoice > Int64.Max - 8192) {
                return logicalJsonCopiedDisplayError("display.invoice_invalid") }
            if (totalInvoice <= invoice) { return PayloadDataResult.Ok(()) }
            // Grow only before constructing more real copied display data.
            // Existing shared handles and their old high-water stay paid.
            let originalCount = additionalCount
            try {
                var remaining = totalInvoice - invoice
                while (remaining > 0) {
                    let extent = min(65280, remaining)
                    let ticket = owner.acquireFixedBuffer(max(1024, extent + 256))
                    try { additional = Some(LogicalJsonCopiedDisplayTicket(ticket, additional)); additionalCount++ }
                    catch (error: Exception) { ticket.close(); throw error }
                    remaining -= extent
                }
                invoice = totalInvoice; PayloadDataResult.Ok(())
            } catch (_: Exception) {
                // Nothing under these newly acquired tickets was allocated
                // yet. Never remove an existing ticket or lower the invoice.
                while (additionalCount > originalCount) { retireAdditionalTicket() }
                logicalJsonCopiedDisplayError("display.original_bank_pressure")
            }
        } finally { lock.unlock() }
    }
    private func retireAdditionalTicket(): Unit {
        let retired = logicalJsonTakeCopiedDisplayTicket(additional)
        additional = retired[0]; additionalCount--
        retired[1].close()
    }
    func retain(): PayloadDataResult<LogicalJsonCopiedDisplayAllocation> {
        lock.lock()
        try {
            if (released || references == Int64.Max) { return logicalJsonCopiedDisplayError("display.allocation_closed") }
            // An additional queue/card/cache handle has its own simultaneous
            // metadata cost. This is another original fixed ticket, not a new
            // bank or a reference that silently grows an uncharged array.
            let metadata = try { owner.acquireFixedBuffer(1024) }
                catch (_: Exception) { return logicalJsonCopiedDisplayError("display.original_bank_pressure") }
            try {
                let handle = LogicalJsonCopiedDisplayAllocation(this, Some(metadata))
                references++; PayloadDataResult.Ok(handle)
            } catch (_: Exception) {
                metadata.close(); logicalJsonCopiedDisplayError("display.original_bank_pressure") }
        } finally { lock.unlock() }
    }
    func beginBorrow(): PayloadDataResult<Unit> {
        lock.lock()
        try {
            if (released || borrows == Int64.Max) { return logicalJsonCopiedDisplayError("display.allocation_closed") }
            borrows++; PayloadDataResult.Ok(())
        } finally { lock.unlock() }
    }
    func endBorrow(): Unit { lock.lock(); try { borrows-- } finally { lock.unlock() } }
    func retire(): PayloadDataResult<?LogicalJsonCopiedDisplayTicket> {
        lock.lock()
        try {
            if (released || references < 1) { return logicalJsonCopiedDisplayError("display.allocation_closed") }
            if (borrows != 0) { return logicalJsonCopiedDisplayError("display.borrow_pending") }
            references--
            if (references == 0) {
                var actual = additional
                additional = None; additionalCount = 0; released = true
                PayloadDataResult.Ok(actual)
            } else { PayloadDataResult.Ok(None<LogicalJsonCopiedDisplayTicket>) }
        } finally { lock.unlock() }
    }
}

public class LogicalJsonCopiedDisplayAllocation {
    private let lock = Mutex()
    private var state: ?LogicalJsonCopiedDisplayState
    private var metadata: ?LogicalJsonFixedBufferReservation
    private var borrowing = false
    private var closed = false
    init(state: LogicalJsonCopiedDisplayState, metadata: ?LogicalJsonFixedBufferReservation) {
        this.state = Some(state); this.metadata = metadata
    }
    public func ensureCopiedDisplayRetainedPeakData(totalInvoice: Int64): PayloadDataResult<Unit> {
        lock.lock()
        try {
            if (closed) { return logicalJsonCopiedDisplayError("display.allocation_closed") }
            state.getOrThrow().ensureRetainedPeak(totalInvoice)
        } finally { lock.unlock() }
    }
    public func retainCopiedDisplayAllocationData(): PayloadDataResult<LogicalJsonCopiedDisplayAllocation> {
        lock.lock()
        try {
            if (closed) { return logicalJsonCopiedDisplayError("display.allocation_closed") }
            state.getOrThrow().retain()
        } finally { lock.unlock() }
    }
    public func withCopiedDisplayBorrowData<T>(consume: () -> T, failure: (String) -> T): T {
        lock.lock()
        try {
            if (closed || borrowing) { return failure("display.borrow_unavailable") }
            match (state.getOrThrow().beginBorrow()) {
                case PayloadDataResult.Err(error) => return failure(error)
                case PayloadDataResult.Ok(_) => borrowing = true }
        } finally { lock.unlock() }
        // The callback frame ends before the borrow counter is retired. An
        // observer that escapes copied data must first retain another handle.
        try { consume() }
        catch (_: Exception) { failure("display.consumer_failed") }
        finally {
            state.getOrThrow().endBorrow()
            lock.lock(); try { borrowing = false } finally { lock.unlock() }
        }
    }
    public func closeAfterCopiedDisplayRetirementData(): PayloadDataResult<Unit> {
        lock.lock()
        try {
            if (closed) { return PayloadDataResult.Ok(()) }
            if (borrowing) { return logicalJsonCopiedDisplayError("display.borrow_pending") }
            var returned: ?PayloadDataResult<?LogicalJsonCopiedDisplayTicket> = Some(state.getOrThrow().retire())
            match (returned.getOrThrow()) { case PayloadDataResult.Err(error) => return PayloadDataResult.Err(error); case PayloadDataResult.Ok(_) => () }
            var tickets = returned.getOrThrow().value().getOrThrow()
            returned = None
            var handleTicket = metadata
            metadata = None; state = None; closed = true
            // The actual shared-state method has returned. This handle no
            // longer holds state, metadata tickets, arrays or copied data.
            match (handleTicket) { case Some(actual) => actual.close(); case None => () }
            handleTicket = None
            while (tickets.isSome()) {
                let retired = logicalJsonTakeCopiedDisplayTicket(tickets)
                tickets = retired[0]; retired[1].close()
            }
            PayloadDataResult.Ok(())
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
}

// Only internal growth metadata. Each node is prepaid by its own original
// fixed ticket; failed growth clears the whole new prefix before refund.
class LogicalJsonCopiedDisplayTicket {
    var ticket: ?LogicalJsonFixedBufferReservation
    var previous: ?LogicalJsonCopiedDisplayTicket
    init(ticket: LogicalJsonFixedBufferReservation, previous: ?LogicalJsonCopiedDisplayTicket) {
        this.ticket = Some(ticket); this.previous = previous
    }
}

// This entire node-reading frame ends before the caller refunds the ticket.
// The returned pair has only the still-paid next node and the actual ticket;
// the retired node's own fields and all transient node references are clear.
func logicalJsonTakeCopiedDisplayTicket(head: ?LogicalJsonCopiedDisplayTicket):
    (?LogicalJsonCopiedDisplayTicket, LogicalJsonFixedBufferReservation) {
    var actual = head
    let previous = actual.getOrThrow().previous
    let ticket = actual.getOrThrow().ticket.getOrThrow()
    actual.getOrThrow().previous = None; actual.getOrThrow().ticket = None
    actual = None
    (previous, ticket)
}
