package agent_app

import agent_core.OwnedAgentRunResult113
import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import agent_runtime.*
import agent_tui.*
import std.sync.Mutex

private func appOwnedTuiInvoiceAdd113(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > Int64.Max - right) { throw Exception("display.invoice_overflow") }
    left + right
}

private class TuiFailurePaymentCell113 {
    var value: ?LogicalJsonCopiedDisplayAllocation = Option<LogicalJsonCopiedDisplayAllocation>.None
}
private class TuiFailureCopyInvoice113 {
    let allocation: LogicalJsonCopiedDisplayAllocation
    var total: Int64 = 4096
    init(allocation: LogicalJsonCopiedDisplayAllocation) { this.allocation = allocation }
    func fund(bytes: Int64): Result<Unit> {
        if (bytes < 0 || total > Int64.Max - bytes) { return ownedTuiDisplayError("display.invoice_overflow") }
        let next = total + bytes
        match (allocation.ensureCopiedDisplayRetainedPeak(next)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => total = next; Result<Unit>.Ok(()) }
    }
}

// Each accepted actual publication/caller has its own independently paid
// registration. Returning Accepted admits this real node; it is never ACK.
class OwnedTuiFailureEntry113 {
    private let lock = Mutex()
    private var working = false
    private var original: ?OwnedAgentRunResult113
    private var metadata: ?LogicalJsonCopiedDisplayAllocation
    private var display: ?OwnedTuiFailureDisplay113 = Option<OwnedTuiFailureDisplay113>.None
    private var outputAccepted113 = false
    private var unpublishedAllocation: ?LogicalJsonCopiedDisplayAllocation = Option<LogicalJsonCopiedDisplayAllocation>.None
    private var secondary: ?OwnedFailureDataConsumer113 = Option<OwnedFailureDataConsumer113>.None
    private var discardedOnClose113 = false
    private var discardedScalarBytes113: Int64 = 0
    private var discardedObservationBytes113: Int64 = 0
    var next: ?OwnedTuiFailureEntry113 = Option<OwnedTuiFailureEntry113>.None
    init(value: OwnedAgentRunResult113, metadata: LogicalJsonCopiedDisplayAllocation) {
        original = Some(value); this.metadata = Some(metadata)
    }
    static func prepare(value: OwnedAgentRunResult113): Result<OwnedTuiFailureEntry113> {
        // This small holder is funded in the actual original error loan.
        // The separate registration payment is then acquired in that loan.
        let funded = match (value) {
            case OwnedAgentRunResult113.Failed(publication) => publication.withError({ _, fund => fund(4096) })
            case OwnedAgentRunResult113.Pending(consumer) => consumer.withError({ _, fund =>
                match (fund(4096)) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () } })
            case _ => return ownedTuiDisplayError("display.failure_input_required") }
        match (funded) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let cell = TuiFailurePaymentCell113()
        let borrowed = match (value) {
            case OwnedAgentRunResult113.Failed(publication) => publication.withError({ _, _ =>
                match (publication.deriveCopiedDisplayAllocation113(4096)) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(paid) => cell.value = Some(paid); Result<Unit>.Ok(()) } })
            case OwnedAgentRunResult113.Pending(consumer) => consumer.withError({ _, _ =>
                match (consumer.deriveCopiedDisplayAllocation113(4096)) {
                    case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                    case Result.Ok(paid) => cell.value = Some(paid) } })
            case _ => return ownedTuiDisplayError("display.failure_input_required") }
        match (borrowed) {
            case Result.Err(error) =>
                // The actual original loan has returned. No registration or
                // copied data has escaped this empty holder; clear its only
                // allocation reference before retiring that separate share.
                retireEmptyPaymentCell113(cell)
                return Result.Err(error)
            case Result.Ok(_) => () }
        let paid = cell.value.getOrThrow()
        try { Result.Ok(OwnedTuiFailureEntry113(value, paid)) }
        catch (error: Exception) { let _ = paid.closeAfterCopiedDisplayRetirement(); throw error }
    }
    private static func retireEmptyPaymentCell113(cell: TuiFailurePaymentCell113): Unit {
        let actual = cell.value
        cell.value = Option<LogicalJsonCopiedDisplayAllocation>.None
        match (actual) {
            case Some(paid) => paid.closeAfterCopiedDisplayRetirement().value().getOrThrow()
            case None => () }
    }
    func hasOriginalDebt(): Bool { lock.lock(); try { original.isSome() || secondary.isSome() || working } finally { lock.unlock() } }
    private func beginWork(): Bool {
        lock.lock(); try { if (working || original.isNone()) { false } else { working = true; true } }
        finally { lock.unlock() }
    }
    private func endWork(): Unit { lock.lock(); try { working = false } finally { lock.unlock() } }
    private func pendingSecondary113(): ?OwnedFailureDataConsumer113 {
        lock.lock(); try { secondary } finally { lock.unlock() }
    }
    private func installSecondary113(value: OwnedFailureDataConsumer113): Unit {
        lock.lock(); try {
            if (secondary.isSome()) { throw IllegalStateException("actual secondary consumer is still held") }
            secondary = Some(value)
        } finally { lock.unlock() }
    }
    private func clearAdmittedSecondary113(value: OwnedFailureDataConsumer113): Unit {
        lock.lock(); try {
            if (secondary.isNone() || !refEq(secondary.getOrThrow(), value)) {
                throw IllegalStateException("admitted secondary identity changed") }
            secondary = Option<OwnedFailureDataConsumer113>.None
        } finally { lock.unlock() }
    }
    func process(output: OwnedTuiFailureDisplayOutput113, queue: OwnedTuiFailureQueue113): Unit {
        if (!beginWork()) { return }
        try {
            match (pendingSecondary113()) {
                case Some(actual) =>
                    if (!queue.admit(OwnedAgentRunResult113.Pending(actual))) { return }
                    clearAdmittedSecondary113(actual)
                case None => ()
            }
            let result = processFrame113(output)
            match (result) {
                case Result.Ok(_) =>
                    // Admission has completed once. The original API's
                    // bounded ACK refusal only keeps this exact debt pending;
                    // it cannot replay the copied output or mint a new error.
                    let _ = acknowledgeOriginalFrame113()
                case Result.Err(error) =>
                    if (!refEq(error, TUI_FAILURE_MAILBOX_PENDING113)) {
                        // Capture the actual complete secondary before this
                        // raw Result frame ends. Pressure leaves the source
                        // original/copy registered and never acknowledges it.
                        match (captureSecondary113(error)) {
                            case OwnedFailureDataOutcome113<Unit>.Value(_) => ()
                            case OwnedFailureDataOutcome113<Unit>.Failure(actual) => installSecondary113(actual)
                        }
                    }
            }
        } catch (failure: OwnedCanonicalPaidFailure113) { installSecondary113(failure.takeConsumer()) }
        catch (_: OwnedCanonicalDataFailure113) {
            // Failed funding is not an ACK or a replacement error. The real
            // original remains in this exact node for later paid consumption.
        } finally { endWork() }
    }
    private func captureSecondary113(error: AgentError): OwnedFailureDataOutcome113<Unit> {
        match (original.getOrThrow()) {
            case OwnedAgentRunResult113.Failed(publication) => publication.captureFailure113<Unit>(error)
            case OwnedAgentRunResult113.Pending(consumer) => consumer.captureFailure113<Unit>(error)
            case _ => throw IllegalStateException("failure display has no actual original consumer")
        }
    }
    private func processFrame113(output: OwnedTuiFailureDisplayOutput113): Result<Unit> {
            if (display.isNone()) {
                match (copyOriginalFrame113()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => () }
            }
            if (!outputAccepted113) {
                match (output.acceptFailureDisplay113(display.getOrThrow())) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => outputAccepted113 = true }
            }
            // Complete source error/encoder/copy/mailbox helper frames return
            // before the separate ACK step. This independently paid display
            // cannot be published twice merely because a real loan is live.
            Result<Unit>.Ok(())
    }
    private func copyOriginalFrame113(): Result<Unit> {
        let value = original.getOrThrow()
        let answer = match (value) {
            case OwnedAgentRunResult113.Failed(publication) => publication.withError({ error, _ =>
                copyErrorLoan113(error, { invoice => publication.deriveCopiedDisplayAllocation113(invoice) }) })
            case OwnedAgentRunResult113.Pending(consumer) => consumer.withError({ error, _ =>
                match (copyErrorLoan113(error, { invoice => consumer.deriveCopiedDisplayAllocation113(invoice) })) {
                    case Result.Err(failure) => throw OwnedCanonicalDataFailure113(failure)
                    case Result.Ok(_) => () } })
            case _ => ownedTuiDisplayError<Unit>("display.failure_input_required") }
        match (answer) {
            case Result.Ok(_) => Result<Unit>.Ok(())
            case Result.Err(error) =>
                // These encoding/copy frames have ended before unpublished
                // data is cleared. A failed source is not ACKed or forgotten.
                match (display) {
                    case Some(copied) => match (copied.closeUnpublishedCopiedFailure113()) {
                        case Result.Err(_) => return Result.Err(error)
                        case Result.Ok(_) => display = Option<OwnedTuiFailureDisplay113>.None }
                    case None => () }
                match (unpublishedAllocation) {
                    case Some(paid) => match (paid.closeAfterCopiedDisplayRetirement()) {
                        case Result.Err(_) => return Result.Err(error)
                        case Result.Ok(_) => unpublishedAllocation = Option<LogicalJsonCopiedDisplayAllocation>.None }
                    case None => () }
                Result.Err(error)
        }
    }
    private func copyErrorLoan113(error: AgentError,
        derive: (Int64) -> Result<LogicalJsonCopiedDisplayAllocation>): Result<Unit> {
        let paid = match (derive(4096)) { case Result.Err(failure) => return Result.Err(failure); case Result.Ok(value) => value }
        unpublishedAllocation = Some(paid)
        let invoice = TuiFailureCopyInvoice113(paid)
        let bytes = error.code.size + error.message.size
        if (bytes < 0 || bytes > (Int64.Max - 4096) / 16) { return ownedTuiDisplayError("display.invoice_overflow") }
        match (invoice.fund(4096 + bytes * 16)) { case Result.Err(failure) => return Result.Err(failure); case Result.Ok(_) => () }
        // Full eight fields, exact frozen observation bytes and original
        // 64 MiB bound. No ordinary frame/preview bound truncates this data.
        let encoded = match (encodeOwnedFailureError113(error, { count => invoice.fund(count) })) {
            case Result.Err(failure) => return Result.Err(failure); case Result.Ok(value) => value }
        let copiedCode = String.fromUtf8(error.code.toArray())
        let copiedMessage = String.fromUtf8(error.message.toArray())
        let copied = OwnedTuiFailureDisplay113(paid, invoice.total)
        // Adopt the empty actual token before its fallible install call.
        display = Some(copied); unpublishedAllocation = Option<LogicalJsonCopiedDisplayAllocation>.None
        copied.installCopiedFailure113(copiedCode, copiedMessage, encoded)
    }
    private func acknowledgeOriginalFrame113(): Result<Unit> {
        let value = original.getOrThrow()
        let acknowledged = match (value) {
            case OwnedAgentRunResult113.Failed(publication) => publication.acknowledgeAfterConsumption()
            case OwnedAgentRunResult113.Pending(consumer) => consumer.acknowledgeAfterConsumption()
            case _ => ownedTuiDisplayError<Unit>("display.failure_input_required") }
        match (acknowledged) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) =>
                lock.lock(); try { original = Option<OwnedAgentRunResult113>.None } finally { lock.unlock() }
                Result<Unit>.Ok(()) }
    }
    func wasDiscardedOnClose113(): Bool { lock.lock(); try { discardedOnClose113 } finally { lock.unlock() } }
    // Explicit cancellation consumption. This reads all original eight
    // fields in their real paid loan, creates no DOM/string/renderer copy,
    // and retains only bounded scalar accounting in this paid registration.
    private func consumeDiscardedError113(error: AgentError, fund: (Int64) -> Result<Unit>): Result<Unit> {
        match (fund(4096)) { case Result.Err(failure) => return Result.Err(failure); case Result.Ok(_) => () }
        let _ = error.kind; let _ = error.retryable; let _ = error.fallbackAllowed
        var bytes = appOwnedTuiInvoiceAdd113(error.code.size, error.message.size)
        for (field in error.fields) { bytes = appOwnedTuiInvoiceAdd113(bytes, appOwnedTuiInvoiceAdd113(field.name.size, field.value.size)) }
        discardedScalarBytes113 = bytes
        match (error.attemptFailure) {
            case Some(attempt) =>
                let _ = attempt.kind; let d = attempt.diagnostics
                let _ = d.elapsedMillis; let _ = d.softDeadlineMillis; let _ = d.hardDeadlineMillis
                let _ = d.enteredCompletionGrace; let _ = d.lastProgressKind; let _ = d.lastProgressAgeMillis
                let _ = d.providerTerminalObserved; let _ = d.openContentBlockCount
                let _ = d.toolCallsStarted; let _ = d.toolCallsCompleted
            case None => () }
        discardedObservationBytes113 = 0
        match (error.observation) {
            case Some(value) => value.withFrozenEncodedData113({ encoded => discardedObservationBytes113 = encoded.size })
            case None => () }
        Result<Unit>.Ok(())
    }
    private func consumeDiscardedSourceFrame113(value: OwnedAgentRunResult113): Result<Unit> {
        match (value) {
            case OwnedAgentRunResult113.Failed(publication) =>
                publication.withError({ error, fund => consumeDiscardedError113(error, fund) })
            case OwnedAgentRunResult113.Pending(consumer) => consumer.withError({ error, fund =>
                match (consumeDiscardedError113(error, fund)) {
                    case Result.Err(failure) => throw OwnedCanonicalDataFailure113(failure); case Result.Ok(_) => () } })
            case _ => ownedTuiDisplayError("display.failure_input_required") }
    }
    func discardOriginalAfterActualFrames113(): Result<Unit> {
        lock.lock()
        if (working) { lock.unlock(); return ownedTuiDisplayError("display.failure_input_pending") }
        working = true; lock.unlock()
        try {
            // Every real loan and its raw aliases end before each separate
            // ACK. Failure/pressure keeps the precise old paid field intact.
            match (pendingSecondary113()) {
                case Some(actual) =>
                    match (consumeDiscardedSourceFrame113(OwnedAgentRunResult113.Pending(actual))) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    match (actual.acknowledgeAfterConsumption()) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    clearAdmittedSecondary113(actual)
                case None => () }
            match (original) {
                case Some(actual) =>
                    match (consumeDiscardedSourceFrame113(actual)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    match (acknowledgeOriginalFrame113()) {
                        case Result.Err(error) => return Result.Err(error)
                        case Result.Ok(_) =>
                            lock.lock(); try { discardedOnClose113 = true } finally { lock.unlock() } }
                case None => () }
            Result<Unit>.Ok(())
        } catch (failure: OwnedCanonicalDataFailure113) { Result<Unit>.Err(failure.error) }
        finally { endWork() }
    }
    func retireCopiedData(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (hasOriginalDebt()) { return ownedTuiDisplayError("display.failure_input_pending") }
        match (display) {
            case Some(value) => match (value.closeAfterWholeScreenRetirement(retired)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => display = Option<OwnedTuiFailureDisplay113>.None; Result<Unit>.Ok(()) }
            case None => Result<Unit>.Ok(()) }
    }
    func takeMetadataAfterDataRetirement(): LogicalJsonCopiedDisplayAllocation {
        if (original.isSome() || secondary.isSome() || display.isSome() || unpublishedAllocation.isSome() || working) {
            throw IllegalStateException("failure display registration is still live") }
        let paid = metadata.getOrThrow(); metadata = Option<LogicalJsonCopiedDisplayAllocation>.None; paid
    }
}

class OwnedTuiFailureQueue113 {
    private let lock = Mutex()
    private var first: ?OwnedTuiFailureEntry113 = Option<OwnedTuiFailureEntry113>.None
    private var last: ?OwnedTuiFailureEntry113 = Option<OwnedTuiFailureEntry113>.None
    private var closing = false
    private var admissionFrames113: Int64 = 0
    private var retiringMetadata: ?LogicalJsonCopiedDisplayAllocation = Option<LogicalJsonCopiedDisplayAllocation>.None
    func admit(value: OwnedAgentRunResult113): Bool {
        lock.lock()
        let unavailable = closing
        if (!unavailable) { admissionFrames113++ }
        lock.unlock()
        if (unavailable) { return false }
        try {
            let prepared = try { OwnedTuiFailureEntry113.prepare(value) }
                catch (_: Exception) { return false }
            let entry = match (prepared) { case Result.Err(_) => return false; case Result.Ok(actual) => actual }
            lock.lock()
            try {
                // A closing transition never loses an already prepaid
                // original. The actual admission frame remains counted until
                // this node is registered and its caller helper returns.
                match (last) { case Some(previous) => previous.next = Some(entry); case None => first = Some(entry) }
                last = Some(entry); true
            } finally { lock.unlock() }
        } finally {
            lock.lock(); try { admissionFrames113-- } finally { lock.unlock() }
        }
    }
    func beginClosing(): Unit { lock.lock(); try { closing = true } finally { lock.unlock() } }
    func discardedOnCloseCount113(): Int64 {
        lock.lock()
        try { var count: Int64 = 0; var node = first
            while (node.isSome()) { if (node.getOrThrow().wasDiscardedOnClose113()) { count++ }; node = node.getOrThrow().next }
            count
        } finally { lock.unlock() }
    }
    func discardRegisteredOriginalsAfterActualFrames113(): Result<Unit> {
        lock.lock()
        if (!closing || admissionFrames113 != 0) { lock.unlock(); return ownedTuiDisplayError("display.failure_input_pending") }
        var node = first; lock.unlock()
        while (node.isSome()) {
            let actual = node.getOrThrow()
            match (actual.discardOriginalAfterActualFrames113()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            lock.lock(); node = actual.next; lock.unlock()
        }
        // Independent copied data and registration remain paid. This is
        // discarded_on_close, never displayed or StdOut retirement evidence.
        Result<Unit>.Ok(())
    }
    func hasOriginalDebt(): Bool {
        lock.lock()
        try {
            if (admissionFrames113 != 0) { return true }
            var node = first
            while (node.isSome()) { if (node.getOrThrow().hasOriginalDebt()) { return true }; node = node.getOrThrow().next }
            false
        } finally { lock.unlock() }
    }
    func drain(output: OwnedTuiFailureDisplayOutput113): Unit {
        lock.lock(); var node = first; let stop = last; lock.unlock()
        while (node.isSome()) {
            let actual = node.getOrThrow()
            if (actual.hasOriginalDebt()) { actual.process(output, this) }
            if (stop.isSome() && refEq(actual, stop.getOrThrow())) { break }
            lock.lock(); node = actual.next; lock.unlock()
        }
    }
    func retireCopiedRegistry(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (!retired.copiedReferencesRetired() || hasOriginalDebt()) { return ownedTuiDisplayError("display.failure_input_pending") }
        while (true) {
            // A previous physical close failure must be retried before the
            // next actual node can overwrite this still-paid metadata field.
            match (retiringMetadata) {
                case Some(paid) => match (paid.closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => retiringMetadata = Option<LogicalJsonCopiedDisplayAllocation>.None }
                case None => () }
            lock.lock(); let empty = first.isNone(); lock.unlock()
            if (empty) { break }
            match (detachRetiredMetadataFrame113(retired)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            // The real node/data/next helper frame has returned before this
            // separate registry payment can retire. No GC/transport shortcut.
            // The next iteration retires the exact detached share before it
            // reads another node. No close/ACK is inferred from Unit return.
        }
        Result<Unit>.Ok(())
    }
    private func detachRetiredMetadataFrame113(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        lock.lock()
        try {
            let node = first.getOrThrow()
            match (node.retireCopiedData(retired)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            retiringMetadata = Some(node.takeMetadataAfterDataRetirement())
            first = node.next; node.next = Option<OwnedTuiFailureEntry113>.None
            if (first.isNone()) { last = Option<OwnedTuiFailureEntry113>.None }
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
}

class OwnedTuiFailureAdmission113 <: OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let queue: OwnedTuiFailureQueue113
    init(queue: OwnedTuiFailureQueue113) { this.queue = queue }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        if (queue.admit(OwnedAgentRunResult113.Failed(value))) { OwnedFailureEventAdmissionOutcome113.Accepted }
        else { OwnedFailureEventAdmissionOutcome113.Held }
    }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        if (value.isAcknowledged()) { Result<Unit>.Ok(()) } else { ownedTuiDisplayError("display.failure_input_pending") }
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (admitOwnedFailure113(value)) {
            case OwnedFailureEventAdmissionOutcome113.Accepted => OwnedFailureDataOutcome113<Unit>.Value(())
            case OwnedFailureEventAdmissionOutcome113.Failed(error) => OwnedFailureDataOutcome113<Unit>.Failure(error)
            case OwnedFailureEventAdmissionOutcome113.Held => throw OwnedCanonicalDataFailure113(
                AgentError(AgentErrorKind.RecoveryRequired, "display.failure_input_pending", "the actual terminal error consumer has not admitted this publication")) }
    }
}
