package agent_rpc

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*

public enum AcpOwnedCloseStatus113 {
    Complete | Failed | FailedConsumed | Held
}

// Registered before a real cancel/closer/aggregate callback is allocated.
// The source Err, its independent complete consumer and unknown producer
// remain paid until the exact output and complete caller helper return.
class AcpOwnedCloseProducer113 {
    private let paid: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var source: ?AgentError = None<AgentError>
    private var failure: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var started = false
    private var returned = false
    private var borrowed = false
    private var acknowledged = false
    private var printed = false
    private var retirementGuard: ?(() -> Bool) = None<() -> Bool>
    private var peak: Int64 = 65536
    init(paid: LogicalJsonOwnerReservation) { this.paid = paid }
    func run113(action: () -> Result<Unit>, errorCode!: String = "acp.product_close_failed"): Result<Unit> {
        lock.lock()
        try {
            if (started) { throw IllegalStateException("ACP close producer cannot run twice") }
            started = true
        } finally { lock.unlock() }
        try {
            let result = action()
            match (result) {
                case Result.Err(error) => capture113(error)
                case Result.Ok(_) => () }
            result
        } catch (actual: OwnedCanonicalPaidFailure113) {
            let consumer = actual.takeConsumer()
            failure = Some(consumer)
            // Explicitly unsafe internal raw compatibility aliases remain
            // held by this same actual consumer and source invoice. Public
            // production transport never returns them to a caller.
            match (consumer.withError({ error, _ =>
                fundSource113(error)
                source = Some(error)
            })) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => () }
            Result<Unit>.Err(source.getOrThrow())
        } catch (actual: OwnedCanonicalDataFailure113) {
            capture113(actual.error)
            Result<Unit>.Err(actual.error)
        } catch (actual: Exception) {
            fund113(acpOwnedAdd113(16384, acpOwnedMultiply113(acpOwnedUtf8Bytes113(actual.message), 8)))
            let error = AgentError(AgentErrorKind.Internal, errorCode, actual.message)
            capture113(error)
            Result<Unit>.Err(error)
        }
    }
    // Its caller invokes this only AFTER run113 and the actual producer
    // helper returned, never from the producer's finally/cancel counter.
    func observeReturned113(): Unit { lock.lock(); try { returned = true } finally { lock.unlock() } }
    func setRetirementGuard113(guard: () -> Bool): Unit { retirementGuard = Some(guard) }
    func markPrinted113(): Unit { lock.lock(); try { printed = true } finally { lock.unlock() } }
    func wasPrinted113(): Bool { lock.lock(); try { printed } finally { lock.unlock() } }
    func collectAfterCallerReturn113(): Bool {
        if (!isReturned113() || (hasFailure113() && !printed)) { return false }
        match (retirementGuard) { case Some(guard) => if (!guard()) { return false }; case None => () }
        // The actual guard/helper returned before clearing its closure and
        // the producer's original cache/source aliases.
        retirementGuard = None<() -> Bool>
        retireAfterOutputAndCallerReturn113()
    }
    private func fund113(bytes: Int64): Unit {
        let wanted = acpOwnedAdd113(peak, bytes)
        paid.ensureRetainedPeak(wanted); peak = wanted
    }
    private func fundSource113(error: AgentError): Unit {
        // Original Runtime error DATA invoice: complete UTF8 fields, all
        // diagnostics and the existing bounded immutable observation. This
        // does not change any original codec/node/message/floor limit.
        fund113(acpOwnedMultiply113(acpCloseSourceInvoice113(error), 2))
    }
    func captureException113(error: Exception, code: String): Unit {
        fund113(acpOwnedAdd113(16384, acpOwnedMultiply113(acpOwnedUtf8Bytes113(error.message), 8)))
        capture113(AgentError(AgentErrorKind.Internal, code, error.message,
            retryable: false, fallbackAllowed: false))
    }
    func capturePaid113(consumer: OwnedFailureDataConsumer113): Unit {
        failure = Some(consumer)
        match (consumer.withError({ error, _ => fundSource113(error); source = Some(error) })) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(_) => () }
    }

    func capture113(error: AgentError): Unit {
        fundSource113(error)
        // Store the original before a fallible clone, under its exact source
        // invoice. Pressure keeps it and this registered original share.
        source = Some(error)
        match (captureOwnedFailureData113<Unit>(error, { _ => paid.deriveRetainedLease() })) {
            case OwnedFailureDataOutcome113.Failure(actual) => failure = Some(actual)
            case _ => throw IllegalStateException("ACP close capture returned no actual error") }
    }
    func hasFailure113(): Bool { source.isSome() || failure.isSome() }
    func isReturned113(): Bool { lock.lock(); try { returned } finally { lock.unlock() } }
    func withError113(consume: (AgentError, (Int64)->Result<Unit>) -> Unit): Result<Unit> {
        lock.lock()
        let actual = try {
            if (!returned || borrowed || acknowledged) { return acpOwnedWorkersPending113<Unit>() }
            let selected = failure.getOrThrow()
            borrowed = true; selected
        } finally { lock.unlock() }
        try { actual.withError(consume) }
        finally { lock.lock(); try { borrowed = false } finally { lock.unlock() } }
    }
    func retireAfterOutputAndCallerReturn113(): Bool {
        lock.lock()
        try {
            if (acknowledged) { return true }
            if (!returned || borrowed) { return false }
            // All producing/printing helpers and external raw compatibility
            // aliases must be gone before this explicit original source clear.
            source = None<AgentError>
            match (failure) {
                case Some(actual) =>
                    match (actual.acknowledgeAfterConsumption()) {
                        case Result.Err(_) => return false
                        case Result.Ok(_) => failure = None<OwnedFailureDataConsumer113> }
                case None => () }
            paid.close(); acknowledged = true; true
        } finally { lock.unlock() }
    }
}

class AcpOwnedCloseText113 {
    var value: ?String = None<String>
    var failed = false
    var prefix = ""
}

class AcpOwnedCloseJournal113 {
    private let control: AcpOwnedWorkerControl113
    private let lock = Mutex()
    private let producers = ArrayList<AcpOwnedCloseProducer113>()
    private var unregistered: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var unregisteredRenderPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private let renderedReceipts113 = ArrayList<AcpOwnedCloseRenderReceipt113>()
    private var primary: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>
    private var output: ?AcpOwnedResponse113 = None<AcpOwnedResponse113>
    private var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var frozen = false
    private var offered = false
    private var writeReturned = false
    private var writeSucceeded = false
    private var consumed = false
    private var frontend: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>
    private var frontendFrame: ?AcpOwnedResponse113 = None<AcpOwnedResponse113>
    private var frontendOffered = false
    private var frontendOutputReturned = false
    private var frontendOutputSucceeded = false

    init(control: AcpOwnedWorkerControl113) { this.control = control }
    func prepareProducer113(): AcpOwnedCloseProducer113 {
        lock.lock()
        try {
            if (frozen || unregistered.isSome() || unregisteredRenderPaid113.isSome()) { throw IllegalStateException("ACP keeps an unfinished close producer") }
            // Count and actual snapshot/list allocation share this same lock.
            control.ensureRegistryMetadata113(4, acpOwnedAdd113(65536,
                acpOwnedMultiply113(acpOwnedAdd113(acpOwnedAdd113(producers.size, renderedReceipts113.size), 1), 4096)))
            let paid = control.deriveMetadata113(65536)
            unregistered = Some(paid)
            let node = AcpOwnedCloseProducer113(paid)
            producers.add(node); unregistered = None<LogicalJsonOwnerReservation>
            node
        } finally { lock.unlock() }
    }
    func prepareCurrentResponseReceipt113(primary!: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>): AcpOwnedCloseRenderReceipt113 {
        lock.lock()
        try {
            if (frozen || unregistered.isSome() || unregisteredRenderPaid113.isSome()) {
                throw IllegalStateException("ACP retains an unfinished rendered response registration")
            }
            control.ensureRegistryMetadata113(4, acpOwnedAdd113(65536,
                acpOwnedMultiply113(acpOwnedAdd113(acpOwnedAdd113(producers.size, renderedReceipts113.size), 1), 4096)))
            let paid = control.deriveMetadata113(65536)
            unregisteredRenderPaid113 = Some(paid)
            let actual = AcpOwnedCloseRenderReceipt113(paid, primary)
            renderedReceipts113.add(actual); unregisteredRenderPaid113 = None<LogicalJsonOwnerReservation>
            actual
        } finally { lock.unlock() }
    }
    private func prepareFrontendProducer113(): AcpOwnedCloseProducer113 {
        if (frontend.isSome()) { throw IllegalStateException("ACP retains a previous frontend failure") }
        let actual = prepareProducer113(); frontend = Some(actual); actual
    }
    func captureFrontendFailure113(error: AgentError): Unit {
        let actual = prepareFrontendProducer113()
        actual.capture113(error); actual.observeReturned113()
    }
    func captureFrontendFailure113(error: Exception): Unit {
        let actual = prepareFrontendProducer113()
        actual.captureException113(error, "acp.server_failed"); actual.observeReturned113()
    }
    func captureFrontendFailure113(error: OwnedFailureDataConsumer113): Unit {
        let actual = prepareFrontendProducer113()
        actual.capturePaid113(error); actual.observeReturned113()
    }
    private func renderFrontendFailure113(fund: (Int64)->Result<Unit>): Result<String> {
        let cell = AcpOwnedCloseText113()
        match (frontend.getOrThrow().withError113({ error, _ =>
            match (fund(acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedUtf8Bytes113(error.message), 8)))) {
                case Result.Err(_) => cell.failed = true; return
                case Result.Ok(_) => () }
            // Exact original frontend text remains first, followed by full
            // canonical data; no fabricated protocol event/notification.
            cell.prefix = "acp.server_failed: " + error.message + "\n"
            match (encodeOwnedFailureError113(error, [], "error_data", fund)) {
                case Result.Err(_) => cell.failed = true
                case Result.Ok(value) => cell.value = Some(value) }
        })) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
        if (cell.failed || cell.value.isNone()) { return acpOwnedWorkersPending113<String>() }
        match (fund(acpOwnedMultiply113(acpOwnedAdd113(acpOwnedUtf8Bytes113(cell.prefix),
            acpOwnedUtf8Bytes113(cell.value.getOrThrow())), 8))) {
            case Result.Err(error) => Result<String>.Err(error)
            case Result.Ok(_) => Result<String>.Ok(cell.prefix + cell.value.getOrThrow()) }
    }
    func offerFrontendFailure113(frame: AcpOwnedResponse113,
        writer: (AcpOwnedResponse113)->OwnedFailureDataOutcome113<Unit>): Bool {
        if (frontend.isNone() || frontendOffered) { return false }
        frontendFrame = Some(frame)
        if (!frame.buildText113({ fund => renderFrontendFailure113(fund) }) || !frame.markOffered113()) { return false }
        frontendOffered = true
        match (writeCloseHelper113(frame, writer)) {
            case OwnedFailureDataOutcome113.Value(_) => frontendOutputSucceeded = frame.isAcknowledged113()
            case OwnedFailureDataOutcome113.Failure(actual) => secondary = Some(actual) }
        // This assignment is AFTER the real writer helper returned, never
        // in a finally that could substitute a throwing/unknown producer.
        frontendOutputReturned = true
        if (frontendOutputSucceeded && secondary.isNone()) { frontend.getOrThrow().markPrinted113(); true }
        else { false }
    }

    func preparePrimary113(error: AgentError): Unit {
        if (primary.isSome()) { return }
        let actual = prepareProducer113()
        actual.capture113(error)
        actual.observeReturned113()
        primary = Some(actual)
    }
    func installPrimary113(value: AcpOwnedCloseProducer113): Unit { primary = Some(value) }
    func renderCurrentSecondary113(fund: (Int64)->Result<Unit>, receipt: AcpOwnedCloseRenderReceipt113, excluding!: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>): Result<String> {
        lock.lock()
        let snapshot = try {
            match (fund(acpOwnedAdd113(65536, acpOwnedMultiply113(producers.size, 4096)))) {
                case Result.Err(error) => return Result<String>.Err(error)
                case Result.Ok(_) => () }
            if (!receipt.selectSnapshot113(producers, excluding)) { return acpOwnedWorkersPending113<String>() }
            receipt.exactSnapshot113()
        } finally { lock.unlock() }
        let text = AcpOwnedCloseText113()
        let result = StringBuilder()
        result.append("[")
        var previous = false
        for (node in snapshot) {
            text.value = None<String>; text.failed = false
            match (node.withError113({ error, _ =>
                match (encodeOwnedFailureError113(error, [], "error_data", fund)) {
                    case Result.Err(_) => text.failed = true
                    case Result.Ok(value) => text.value = Some(value) }
            })) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
            if (text.failed || text.value.isNone()) { return acpOwnedWorkersPending113<String>() }
            let encoded = text.value.getOrThrow()
            match (fund(acpOwnedAdd113(4096, acpOwnedMultiply113(acpOwnedUtf8Bytes113(encoded), 8)))) {
                case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
            if (previous) { result.append(",") }; result.append(encoded); previous = true
        }
        result.append("]")
        let encoded = result.toString()
        receipt.markRenderedAfterCodecHelperReturn113()
        Result<String>.Ok(encoded)
    }
    func noteCurrentResponseWritten113(receipt: AcpOwnedCloseRenderReceipt113): Unit {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < renderedReceipts113.size) {
                if (refEq(renderedReceipts113[index], receipt)) {
                    // The exact whole response writer returned with real ACK.
                    // Late producers are outside this precise rendered set.
                    receipt.markExactPrintedAndClearHelper113()
                    receipt.closeAfterExactMarkingHelperReturn113()
                    renderedReceipts113.remove(at: index)
                    return
                }
                index++
            }
            throw IllegalStateException("ACP response has no exact registered renderer receipt")
        } finally { lock.unlock() }
    }
    func collectAfterInputHelperReturn113(): Unit {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < producers.size) {
                if (primary.isSome() && refEq(primary.getOrThrow(), producers[index])) { index++; continue }
                if (producers[index].collectAfterCallerReturn113()) { producers.remove(at: index) }
                else { index++ }
            }
        } finally { lock.unlock() }
    }
    func collectSuccessfulAfterCloseHelperReturn113(): Unit {
        collectAfterInputHelperReturn113()
    }
    func freezeAfterCloseHelperReturn113(): Bool {
        lock.lock()
        try {
            if (unregistered.isSome() || unregisteredRenderPaid113.isSome() || !renderedReceipts113.isEmpty()) { return false }
            for (node in producers) { if (!node.isReturned113()) { return false } }
            frozen = true; true
        } finally { lock.unlock() }
    }
    func renderFullClose113(fund: (Int64)->Result<Unit>): Result<String> {
        // The close path is frozen only after all real close/cancel callbacks
        // returned. A count or cancellation request alone cannot admit this.
        if (!frozen || primary.isNone()) { return acpOwnedWorkersPending113<String>() }
        match (fund(acpOwnedAdd113(65536, acpOwnedMultiply113(producers.size, 4096)))) {
            case Result.Err(error) => return Result<String>.Err(error)
            case Result.Ok(_) => () }
        let text = AcpOwnedCloseText113()
        match (primary.getOrThrow().withError113({ error, _ =>
            match (fund(acpOwnedAdd113(4096, acpOwnedMultiply113(acpOwnedAdd113(acpOwnedUtf8Bytes113(error.code), acpOwnedUtf8Bytes113(error.message)), 8)))) {
                case Result.Err(_) => text.failed = true; return
                case Result.Ok(_) => () }
            text.prefix = "error[" + error.code + "]: " + error.message + "\n"
            match (encodeOwnedFailureError113(error, [ValueField("code", textValue(error.code)),
                ValueField("message", textValue(error.message))], "error_data", fund)) {
                case Result.Err(_) => text.failed = true
                case Result.Ok(value) => text.value = Some(value) }
        })) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
        if (text.failed || text.value.isNone()) { return acpOwnedWorkersPending113<String>() }
        let first = text.value.getOrThrow()
        if (!first.endsWith("}")) { throw IllegalStateException("ACP full close codec object changed") }
        match (fund(acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedUtf8Bytes113(first), 8)))) {
            case Result.Err(error) => return Result<String>.Err(error)
            case Result.Ok(_) => () }
        let result = StringBuilder()
        result.append(first[0..first.size-1]); result.append(",\"secondary_errors\":[")
        var hasPrevious = false
        for (node in producers) {
            if (refEq(node, primary.getOrThrow()) || !node.hasFailure113()) { continue }
            // Clear the paid transfer cell per consumer; no error escapes the
            // loan and no callback-return ACK occurs here.
            text.value = None<String>; text.failed = false
            match (node.withError113({ error, _ =>
                match (encodeOwnedFailureError113(error, [], "error_data", fund)) {
                    case Result.Err(_) => text.failed = true
                    case Result.Ok(value) => text.value = Some(value) }
            })) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
            if (text.failed || text.value.isNone()) { return acpOwnedWorkersPending113<String>() }
            let encoded = text.value.getOrThrow()
            match (fund(acpOwnedAdd113(4096, acpOwnedMultiply113(acpOwnedUtf8Bytes113(encoded), 8)))) {
                case Result.Err(error) => return Result<String>.Err(error)
                case Result.Ok(_) => () }
            if (hasPrevious) { result.append(",") }
            result.append(encoded); hasPrevious = true
        }
        result.append("]}"); Result<String>.Ok(text.prefix + result.toString())
    }
    func offerClose113(frame: AcpOwnedResponse113, writer: (AcpOwnedResponse113)->OwnedFailureDataOutcome113<Unit>): Bool {
        if (!frozen || offered || primary.isNone()) { return false }
        output = Some(frame)
        if (!frame.buildText113({ fund => renderFullClose113(fund) })) { return false }
        if (!frame.markOffered113()) { return false }
        offered = true
        try {
            match (writeCloseHelper113(frame, writer)) {
                case OwnedFailureDataOutcome113.Value(_) => writeSucceeded = frame.isAcknowledged113()
                case OwnedFailureDataOutcome113.Failure(actual) => secondary = Some(actual) }
        } finally { writeReturned = true }
        writeSucceeded && secondary.isNone()
    }
    private func writeCloseHelper113(frame: AcpOwnedResponse113,
        writer: (AcpOwnedResponse113)->OwnedFailureDataOutcome113<Unit>): OwnedFailureDataOutcome113<Unit> { writer(frame) }
    func hasPrimary113(): Bool { primary.isSome() }
    func isConsumed113(): Bool { consumed }
    func canRetireAfterCallerReturn113(): Bool {
        if (primary.isNone()) {
            for (node in producers) { if (node.hasFailure113() && !node.wasPrinted113()) { return false } }
        }
        frozen && unregisteredRenderPaid113.isNone() && renderedReceipts113.isEmpty() && unregistered.isNone() && secondary.isNone() &&
            (frontend.isNone() || (frontendOffered && frontendOutputReturned && frontendOutputSucceeded &&
                frontendFrame.isSome() && frontendFrame.getOrThrow().isAcknowledged113())) &&
            (primary.isNone() || (offered && writeReturned && writeSucceeded && output.isSome() && output.getOrThrow().isAcknowledged113()))
    }
    func finalizeUnsafeAfterWholeTaskReturn113(): Bool {
        if (!control.isUnsafeFixtureRetiring113() || output.isSome() || secondary.isSome() || frontend.isSome()) { return false }
        if (!freezeAfterCloseHelperReturn113()) { return false }
        // The original whole Unit oracle body actually returned and carries
        // no String/server/Error result. This consumes only its explicit
        // unsafe fixture aliases, with no stdout/production delivery credit.
        for (node in producers) { node.markPrinted113(); if (!node.collectAfterCallerReturn113()) { return false } }
        primary = None<AcpOwnedCloseProducer113>; producers.clear(); consumed = true; true
    }

    func retireAfterOutputAndCallerReturn113(): Bool {
        if (consumed) { return true }
        if (!canRetireAfterCallerReturn113()) { return false }
        // Caller clears all original Result/cache aliases AFTER its whole
        // close/print body returned and before entering this DATA retirement.
        for (node in producers) {
            // Only a frozen full-close frame covers every remaining producer.
            // Without one, each source needs its own exact earlier receipt.
            if (primary.isSome()) { node.markPrinted113() }
            if (!node.collectAfterCallerReturn113()) { return false }
        }
        primary = None<AcpOwnedCloseProducer113>
        output = None<AcpOwnedResponse113>
        frontend = None<AcpOwnedCloseProducer113>; frontendFrame = None<AcpOwnedResponse113>
        producers.clear(); consumed = true; true
    }
}

private func acpCloseSourceInvoice113(error: AgentError): Int64 {
    var bytes = acpOwnedAdd113(acpOwnedUtf8Bytes113(error.code), acpOwnedUtf8Bytes113(error.message))
    var containers: Int64 = 16384
    for (field in error.fields) {
        bytes = acpOwnedAdd113(bytes, acpOwnedAdd113(acpOwnedUtf8Bytes113(field.name), acpOwnedUtf8Bytes113(field.value)))
        containers = acpOwnedAdd113(containers, 1024) }
    var peak = acpOwnedAdd113(containers, acpOwnedMultiply113(bytes, 8))
    if (error.attemptFailure.isSome()) { peak = acpOwnedAdd113(peak, 4096) }
    if (error.observation.isSome()) { peak = acpOwnedAdd113(peak, 540672) }
    peak
}

// Each actual response keeps its own original-bank snapshot share. The exact
// rendered set is held through the complete write/flush/ACK helper return.
class AcpOwnedCloseRenderReceipt113 {
    private let paid: LogicalJsonOwnerReservation
    private var selected: ?ArrayList<AcpOwnedCloseProducer113> = Some(ArrayList<AcpOwnedCloseProducer113>())
    private var primary: ?AcpOwnedCloseProducer113
    private var snapshotted = false
    private var rendered = false
    private var marked = false
    private var retired = false
    init(paid: LogicalJsonOwnerReservation, primary: ?AcpOwnedCloseProducer113) {
        this.paid = paid; this.primary = primary
    }
    // The caller holds the journal's same collection lock throughout count,
    // payment and snapshot construction. No concurrent registry growth slips
    // between the actual invoice and this precise set.
    func selectSnapshot113(producers: ArrayList<AcpOwnedCloseProducer113>,
        excluding: ?AcpOwnedCloseProducer113): Bool {
        if (snapshotted || retired) { throw IllegalStateException("ACP response snapshot cannot be selected twice") }
        paid.ensureRetainedPeak(acpOwnedAdd113(65536, acpOwnedMultiply113(producers.size, 4096)))
        for (node in producers) {
            match (excluding) { case Some(actual) => if (refEq(actual, node)) { continue }; case None => () }
            if (node.hasFailure113()) {
                if (!node.isReturned113()) { return false }
                selected.getOrThrow().add(node)
            }
        }
        snapshotted = true; true
    }
    func exactSnapshot113(): ArrayList<AcpOwnedCloseProducer113> {
        if (!snapshotted || retired) { throw IllegalStateException("ACP response has no complete paid snapshot") }
        selected.getOrThrow()
    }
    func markRenderedAfterCodecHelperReturn113(): Unit {
        if (!snapshotted || retired) { throw IllegalStateException("ACP response renderer did not finish its actual snapshot") }
        rendered = true
    }
    func markExactPrintedAndClearHelper113(): Unit {
        if (!rendered || marked || retired) { throw IllegalStateException("ACP response has no exact renderer receipt") }
        for (node in selected.getOrThrow()) { node.markPrinted113() }
        match (primary) { case Some(actual) => actual.markPrinted113(); case None => () }
        selected.getOrThrow().clear(); selected = None<ArrayList<AcpOwnedCloseProducer113>>
        primary = None<AcpOwnedCloseProducer113>; marked = true
    }
    // Called after the whole exact marking/clear helper returned. This is
    // snapshot metadata retirement; source consumers still require their own
    // actual producer/helper return and genuine consumer ACK.
    func closeAfterExactMarkingHelperReturn113(): Unit {
        if (!marked || selected.isSome() || primary.isSome() || retired) {
            throw IllegalStateException("ACP response still has actual snapshot references")
        }
        paid.close(); retired = true
    }
}
