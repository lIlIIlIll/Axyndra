package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import std.sync.Mutex

// Allocation and UI data only. Card identity is a lookup key, never Source.
public interface OwnedTuiCardDisplay113 {
    func matchesUiCard(value: String): Bool
    func prepareCardRenderCopies113(component: Int64, invoice: Int64, occurrence: Int64): Result<Unit>
}

public interface OwnedFailureAgentTuiBackend113 {
    func observeOwnedFailureDisplay113(output: OwnedTuiFailureDisplayOutput113): Unit
    func pollOwnedFailureDisplays113(): Unit
    func discardOwnedFailureInputsAfterProducerRetirement113(retired: RetiredOwnedTuiFailureProducerFrames113): Result<Unit> {
        ownedTuiDisplayError("display.failure_producer_retirement_unknown") }
}

// Only the concrete Screen's actual native/async/Window/Terminal guards can
// mint this receipt, and it binds its exact published backend object. It is
// producer-frame evidence only, never Screen/output/Source or budget ACK.
public class RetiredOwnedTuiFailureProducerFrames113 {
    private let backend: Object
    private init(backend: Object) { this.backend = backend }
    static func retire(screen: AgentScreen): ?RetiredOwnedTuiFailureProducerFrames113 {
        match (screen.actualRetiredFailureProducer113()) {
            case None => Option<RetiredOwnedTuiFailureProducerFrames113>.None
            case Some(actual) => match (actual as Object) {
                case None => Option<RetiredOwnedTuiFailureProducerFrames113>.None
                case Some(identity) => Some(RetiredOwnedTuiFailureProducerFrames113(identity)) }
        }
    }
    public func acknowledges(actual: OwnedFailureAgentTuiBackend113): Bool {
        match (actual as Object) { case Some(identity) => refEq(identity, backend); case None => false }
    }
}

// Fixed backpressure metadata is never an error-data or Source handoff key.
// A full mailbox holds the original already registered error for another UI
// drain; it does not create or acknowledge another error consumer.
public let TUI_FAILURE_MAILBOX_PENDING113 = AgentError(AgentErrorKind.RecoveryRequired,
    "display.failure_mailbox_pending", "the copied failure is waiting for a real mailbox slot",
    retryable: false, fallbackAllowed: false)

public interface OwnedTuiFailureDisplayOutput113 {
    func acceptFailureDisplay113(display: OwnedTuiFailureDisplay113): Result<Unit>
}

public class CallbackOwnedTuiFailureDisplayOutput113 <: OwnedTuiFailureDisplayOutput113 {
    private let output: (OwnedTuiFailureDisplay113) -> Result<Unit>
    public init(output: (OwnedTuiFailureDisplay113) -> Result<Unit>) { this.output = output }
    public func acceptFailureDisplay113(display: OwnedTuiFailureDisplay113): Result<Unit> { output(display) }
}

// The complete original eight-field JSON, code and message are independently
// copied in the producer's real error loan. No AgentError/observation alias is
// retained here. This separate same-bank allocation outlives that loan/ACK.
public class OwnedTuiFailureDisplay113 <: OwnedTuiCardDisplay113 {
    private let lock = Mutex()
    private var allocation: ?LogicalJsonCopiedDisplayAllocation
    private var rendererAllocation: ?LogicalJsonCopiedDisplayAllocation = Option<LogicalJsonCopiedDisplayAllocation>.None
    private var code: ?String = Option<String>.None
    private var message: ?String = Option<String>.None
    private var completeError: ?String = Option<String>.None
    private var borrows: Int64 = 0
    private var closed = false
    private var adopted = false
    private var projected = false
    private var uiCardId = ""
    private var cardFormattingPeak: Int64
    private var queueAndScreenPeak113: Int64 = 0
    private let retainedOccurrencePeaks = Array<Int64>(20, repeat: 0)
    public let projectionInvoice: Int64

    public init(allocation: LogicalJsonCopiedDisplayAllocation, projectionInvoice: Int64) {
        if (projectionInvoice < 4096) { throw IllegalArgumentException("display.failure_invoice_invalid") }
        this.allocation = Some(allocation)
        this.projectionInvoice = projectionInvoice
        this.cardFormattingPeak = projectionInvoice
    }
    public func installCopiedFailure113(code: String, message: String, completeError: String): Result<Unit> {
        lock.lock()
        try {
            if (closed || this.completeError.isSome()) { return ownedTuiDisplayError("display.already_installed") }
            this.code = Some(code); this.message = Some(message); this.completeError = Some(completeError)
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    public func withCopiedFailure113(consume: (String, String, String) -> Result<Unit>): Result<Unit> {
        lock.lock()
        if (closed || completeError.isNone()) { lock.unlock(); return ownedTuiDisplayError("display.unavailable") }
        borrows++; lock.unlock()
        try { withCopiedFailureFrame113(consume) }
        finally { lock.lock(); try { borrows-- } finally { lock.unlock() } }
    }
    private func withCopiedFailureFrame113(consume: (String, String, String) -> Result<Unit>): Result<Unit> {
        let paid = allocation.getOrThrow()
        let actualCode = code.getOrThrow(); let actualMessage = message.getOrThrow()
        let actualError = completeError.getOrThrow()
        paid.withCopiedDisplayBorrow({ => consume(actualCode, actualMessage, actualError) })
    }
    public func ensureCopiedDisplayRetainedPeak(invoice: Int64): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return ownedTuiDisplayError("display.unavailable") }
            allocation.getOrThrow().ensureCopiedDisplayRetainedPeak(invoice)
        } finally { lock.unlock() }
    }
    // The actual mailbox funds its backing and the cumulative Screen token
    // array together before enqueue. This permanent cost coexists with the
    // copied error, card formatting and every renderer occurrence.
    public func prepareQueueAndScreenCopies113(invoice: Int64): Result<Unit> {
        lock.lock()
        try {
            if (closed || invoice < 0) { return ownedTuiDisplayError("display.unavailable") }
            let peak = max(queueAndScreenPeak113, invoice)
            let total = ownedTuiInvoiceAdd(projectionInvoice, peak)
            match (allocation.getOrThrow().ensureCopiedDisplayRetainedPeak(total)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) =>
                    queueAndScreenPeak113 = peak; cardFormattingPeak = max(cardFormattingPeak, total)
                    Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    public func fundedProjectionInvoice113(): Int64 {
        lock.lock(); try { ownedTuiInvoiceAdd(projectionInvoice, queueAndScreenPeak113) } finally { lock.unlock() }
    }
    public func noteUiCardIdentity(value: String): Unit { lock.lock(); try { uiCardId = value } finally { lock.unlock() } }
    public func matchesUiCard(value: String): Bool { lock.lock(); try { uiCardId != "" && uiCardId == value } finally { lock.unlock() } }
    public func noteCardFormattingPeak(value: Int64): Unit { lock.lock(); try { cardFormattingPeak = max(cardFormattingPeak, value) } finally { lock.unlock() } }
    public func prepareCardRenderCopies113(component: Int64, invoice: Int64, occurrence: Int64): Result<Unit> {
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
                case Result.Ok(_) => retainedOccurrencePeaks[index] = candidate; Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    public func isAdopted(): Bool { lock.lock(); try { adopted } finally { lock.unlock() } }
    public func noteUiAdoption(): Unit { lock.lock(); try { adopted = true } finally { lock.unlock() } }
    public func isProjected(): Bool { lock.lock(); try { projected } finally { lock.unlock() } }
    public func noteUiProjection(): Unit { lock.lock(); try { projected = true } finally { lock.unlock() } }
    // Producer-only rollback: no mailbox/card/render reference was admitted.
    // The caller invokes this after its encoding/copy helper frames return.
    public func closeUnpublishedCopiedFailure113(): Result<Unit> {
        lock.lock()
        try {
            if (adopted || rendererAllocation.isSome()) { return ownedTuiDisplayError("display.screen_retirement_required") }
            closeCopiedFailureFrame113()
        } finally { lock.unlock() }
    }
    private func closeCopiedFailureFrame113(): Result<Unit> {
        if (closed) { return Result<Unit>.Ok(()) }
        if (borrows != 0) { return ownedTuiDisplayError("display.borrow_pending") }
        code = Option<String>.None; message = Option<String>.None
        completeError = Option<String>.None; uiCardId = ""
        match (allocation.getOrThrow().closeAfterCopiedDisplayRetirement()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => allocation = Option<LogicalJsonCopiedDisplayAllocation>.None; closed = true; Result<Unit>.Ok(()) }
    }
    public func closeAfterWholeScreenRetirement(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (!retired.copiedReferencesRetired()) { return ownedTuiDisplayError("display.screen_retirement_required") }
        lock.lock()
        try {
            match (closeCopiedFailureFrame113()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (rendererAllocation) {
                case Some(paid) => match (paid.closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(_) => rendererAllocation = Option<LogicalJsonCopiedDisplayAllocation>.None; Result<Unit>.Ok(()) }
                case None => Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { closed && rendererAllocation.isNone() } finally { lock.unlock() } }
}
