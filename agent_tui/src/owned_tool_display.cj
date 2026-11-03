package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import std.sync.*

// Data only. A successful observer call is never an allocation ACK. The
// concrete Screen keeps this token beside all mailbox/card/history copies.
public interface OwnedAgentTuiBackend {
    func observeOwnedToolDisplay(output: OwnedTuiToolDisplayOutput): Unit
    // Unknown/custom backends preserve debt through these defaults.
    func beginOwnedToolDisplayProducerClosing(): Unit {}
    func awaitOwnedToolDisplayProducerReferencesRetired(): Bool { false }
    func retireOwnedToolDisplayRegistry(_: RetiredOwnedTuiScreenReferences): Result<Unit> {
        ownedTuiDisplayError("display.registry_retirement_unknown") }
}

public interface OwnedTuiToolDisplayOutput {
    func accept(display: OwnedTuiToolDisplay): Result<Unit>
}

public class CallbackOwnedTuiToolDisplayOutput <: OwnedTuiToolDisplayOutput {
    private let output: (OwnedTuiToolDisplay) -> Result<Unit>
    public init(output: (OwnedTuiToolDisplay) -> Result<Unit>) { this.output = output }
    public func accept(display: OwnedTuiToolDisplay): Result<Unit> { output(display) }
}

public class OwnedTuiToolDisplay <: OwnedTuiCardDisplay113 {
    private let lock = Mutex()
    private var allocation: ?LogicalJsonCopiedDisplayAllocation
    // A real independent same-bank renderer handle, retained before the
    // first fallible renderer allocation. No history/frame/GC retirement is
    // inferred; closing the ordinary observer handle cannot refund cached
    // Documents/rows/raster/front/back/transport scalar backing.
    private var rendererAllocation: ?LogicalJsonCopiedDisplayAllocation = None
    private var event: ?TuiAgentEvent = None
    private var borrows: Int64 = 0
    private var closed = false
    private var adopted = false
    private var projected = false
    private var uiCardId = ""
    private var cardFormattingPeak: Int64
    // Constant-size, initially prepaid cells for the concrete materialization
    // contexts: virtual item, synchronous history, aggregate/probe, modal.
    // Each context has distinct document/layout/history/raster/frame peaks.
    // Replacement uses two full peaks, in addition to exact old-copy invoices.
    // There is no growing registry, per-render handle, or GC-based retirement.
    private let retainedOccurrencePeaks = Array<Int64>(20, repeat: 0)
    public let projectionInvoice: Int64

    public init(allocation: LogicalJsonCopiedDisplayAllocation, projectionInvoice: Int64) {
        this.allocation = Some(allocation); this.projectionInvoice = projectionInvoice
        this.cardFormattingPeak = projectionInvoice
    }
    // The actual App registers this empty paid cell before constructing the
    // copied preview. Only these two display event families can be installed.
    public func installCopiedEvent(value: TuiAgentEvent): Result<Unit> {
        lock.lock()
        try {
            if (closed || event.isSome()) { return ownedTuiDisplayError("display.already_installed") }
            match (value) {
                case TuiAgentEvent.ToolStarted(_, _) | TuiAgentEvent.ToolStartedWithId(_, _, _)
                    | TuiAgentEvent.ToolCompleted(_, _, _) | TuiAgentEvent.ToolCompletedWithId(_, _, _, _) =>
                    event = Some(value); Result.Ok(())
                case _ => ownedTuiDisplayError("display.unexpected_event") }
        } finally { lock.unlock() }
    }
    public func withCopiedEvent(consume: (TuiAgentEvent) -> Result<Unit>): Result<Unit> {
        lock.lock()
        if (closed || event.isNone()) { lock.unlock(); return ownedTuiDisplayError("display.unavailable") }
        borrows++; lock.unlock()
        try { withCopiedEventFrame(consume) }
        finally { lock.lock(); try { borrows-- } finally { lock.unlock() } }
    }
    private func withCopiedEventFrame(consume: (TuiAgentEvent) -> Result<Unit>): Result<Unit> {
        // All actual copied event/allocation locals and the consumer callback
        // frame end before the outer borrow counter may permit real close.
        let actual = event.getOrThrow(); let paid = allocation.getOrThrow()
        paid.withCopiedDisplayBorrow({ => consume(actual) })
    }
    public func ensureCopiedDisplayRetainedPeak(invoice: Int64): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return ownedTuiDisplayError("display.unavailable") }
            allocation.getOrThrow().ensureCopiedDisplayRetainedPeak(invoice)
        } finally { lock.unlock() }
    }
    public func noteUiCardIdentity(value: String): Unit { lock.lock(); try { uiCardId = value } finally { lock.unlock() } }
    public func matchesUiCard(value: String): Bool { lock.lock(); try { uiCardId != "" && uiCardId == value } finally { lock.unlock() } }
    public func noteCardFormattingPeak(value: Int64): Unit { lock.lock(); try { cardFormattingPeak = max(cardFormattingPeak, value) } finally { lock.unlock() } }
    // Only four concrete contexts are installed by this private product
    // renderer. Virtual owns one item cache per unique UiCard; history is a
    // synchronous helper with one pending batch; aggregate/probe and modal
    // are separate contexts. Two full peaks cover old/new replacement in
    // each context; exact previous cache/backing is also paid before replace.
    // All twenty simultaneous peaks are SUM. Existing tickets remain paid.
    public func prepareRenderCopies(component: Int64, invoice: Int64, occurrence!: Int64 = 0): Result<Unit> {
        lock.lock()
        try {
            if (closed || invoice < 0 || component < 0 || component > 4 || occurrence < 0 || occurrence > 3) {
                return ownedTuiDisplayError("display.unavailable") }
            if (rendererAllocation.isNone()) {
                match (allocation.getOrThrow().retainCopiedDisplayAllocation()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(value) => rendererAllocation = Some(value) }
            }
            let index = component * 4 + occurrence
            let candidate = max(retainedOccurrencePeaks[index], ownedTuiInvoiceMultiply(invoice, 2))
            var total = cardFormattingPeak
            for (i in 0..retainedOccurrencePeaks.size) {
                total = ownedTuiInvoiceAdd(total, if (i == index) { candidate } else { retainedOccurrencePeaks[i] }) }
            match (allocation.getOrThrow().ensureCopiedDisplayRetainedPeak(total)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => retainedOccurrencePeaks[index] = candidate; Result.Ok(()) }
        } finally { lock.unlock() }
    }
    public func prepareCardRenderCopies113(component: Int64, invoice: Int64, occurrence: Int64): Result<Unit> {
        prepareRenderCopies(component, invoice, occurrence: occurrence)
    }
    public func isAdopted(): Bool { lock.lock(); try { adopted } finally { lock.unlock() } }
    public func noteUiAdoption(): Unit { lock.lock(); try { adopted = true } finally { lock.unlock() } }
    public func isProjected(): Bool { lock.lock(); try { projected } finally { lock.unlock() } }
    public func noteUiProjection(): Unit { lock.lock(); try { projected = true } finally { lock.unlock() } }
    // Caller must first clear every real mailbox/card/cache/raster String
    // reference. The current Screen deliberately never claims that condition
    // from a history ACK or conversation switch; its registry retains payment.
    public func closeAfterCopiedDisplayRetirement(): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return Result.Ok(()) }
            if (borrows != 0) { return ownedTuiDisplayError("display.borrow_pending") }
            event = None; uiCardId = ""
            match (allocation.getOrThrow().closeAfterCopiedDisplayRetirement()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => allocation = None; closed = true; Result.Ok(()) }
        } finally { lock.unlock() }
    }
    public func closeAfterWholeScreenRetirement(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (!retired.copiedReferencesRetired()) { return ownedTuiDisplayError("display.screen_retirement_required") }
        match (closeAfterCopiedDisplayRetirement()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            match (rendererAllocation) {
                case Some(paid) => match (paid.closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(_) => rendererAllocation = None; Result.Ok(()) }
                case None => Result.Ok(()) }
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
}

public func ownedTuiDisplayError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "terminal display requires its real copied-data payment and retirement", retryable: false, fallbackAllowed: false))
}

// Complete simultaneous card-formatting invoice, independent of the original
// 12KiB raw preview policy. Covers the existing Strings, new body/title/footer,
// parser/redactor/split arrays and old+new concatenation backing. Rendered
// Document/rows/raster retirement is a separate, still-paid Screen lifetime.
public func ownedTuiCardFormattingInvoice(projectionInvoice: Int64, bytes: Int64): Result<Int64> {
    if (bytes < 0 || projectionInvoice < 1 || projectionInvoice > Int64.Max - 262144 ||
        bytes > (Int64.Max - projectionInvoice - 262144) / 256) {
        return ownedTuiDisplayError("display.invoice_overflow") }
    Result.Ok(projectionInvoice + 262144 + bytes * 256)
}
