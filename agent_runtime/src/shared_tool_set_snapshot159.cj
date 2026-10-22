package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.sync.*

private let sharedToolSnapshotDebts159 = SharedToolSnapshotDebts159()

// Opaque snapshot shares contain no public String, Array, schema or callback
// getter. A fork has its own prepaid handle; closing a handle cannot invalidate
// a sibling or a real in-flight consumer. It grants no invocation authority.
public class SharedToolSetSnapshot159 {
    private let lock = Mutex()
    private var owner: ?SharedToolSnapshotState159
    private var handlePayment: ?LogicalJsonOwnerReservation
    init(owner: SharedToolSnapshotState159, payment: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.handlePayment = Some(payment)
    }
    private var contextDataInvoice180: Int64 = 131072
    public func reserveInvocationSettingsCopy180(value: AgentValue): Unit {
        lock.lock()
        try {
            let _ = owner.getOrThrow()
            let meter = ToolSnapshotMeasure159(handlePayment.getOrThrow(), priorInvoice: contextDataInvoice180)
            meter.addValue159(value); meter.addSlots159(32); meter.fund159()
            contextDataInvoice180 = meter.retainedInvoice159()
        } finally { lock.unlock() }
    }

    public func contentEqualsShared159(other: SharedToolSetSnapshot159): Bool {
        var first: ?SharedToolSnapshotLoan159 = Some(begin159())
        var second: ?SharedToolSnapshotLoan159 = None<SharedToolSnapshotLoan159>
        try {
            second = Some(other.begin159())
            let answer = sharedSnapshotSameContentFrame159(first.getOrThrow(), second.getOrThrow())
            let secondPayments = sharedSnapshotReturnLoanFrame159(second.getOrThrow())
            second = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(secondPayments)
            let firstPayments = sharedSnapshotReturnLoanFrame159(first.getOrThrow())
            first = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(firstPayments)
            answer
        } catch (error: Exception) {
            match (second) { case Some(value) => value.holdFailure159(); case None => () }
            match (first) { case Some(value) => value.holdFailure159(); case None => () }
            throw error
        }
    }
    func laneDigestEquals159(lane: ModelLane, expected: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotLaneDigestFrame159(loan.getOrThrow(), lane, expected) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func sameBacking159(other: SharedToolSetSnapshot159): Bool {
        var first: ?SharedToolSnapshotLoan159 = Some(begin159())
        var second: ?SharedToolSnapshotLoan159 = None<SharedToolSnapshotLoan159>
        try {
            second = Some(other.begin159())
            let answer = sharedSnapshotSameBackingFrame159(first.getOrThrow(), second.getOrThrow())
            let secondPayments = sharedSnapshotReturnLoanFrame159(second.getOrThrow())
            second = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(secondPayments)
            let firstPayments = sharedSnapshotReturnLoanFrame159(first.getOrThrow())
            first = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(firstPayments)
            answer
        } catch (error: Exception) {
            match (second) { case Some(value) => value.holdFailure159(); case None => () }
            match (first) { case Some(value) => value.holdFailure159(); case None => () }
            throw error
        }
    }
    // Fixed private Context/locks/control-reference carrier, no copied DOM.
    // This cannot grant authority or expose an allocator to its caller.
    public func forkInvocationView159(): SharedToolSetSnapshot159 {
        lock.lock()
        try { owner.getOrThrow().newShare159(bytes: 16384) } finally { lock.unlock() }
    }
    public func fork159(): SharedToolSetSnapshot159 {
        lock.lock()
        try { owner.getOrThrow().newShare159() } finally { lock.unlock() }
    }
    // Historical exports remain explicitly charged. A raw getter is never
    // turned into an implicit synchronous borrow or acknowledged by Unit.
    public func exportHistoricalSnapshot159(): ToolSetSnapshot {
        lock.lock()
        try { owner.getOrThrow().exportHistorical159() } finally { lock.unlock() }
    }
    func deriveLaneMetadata159(bytes: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try { owner.getOrThrow().newLaneMetadata159(bytes) } finally { lock.unlock() }
    }
    public func retainedReferenceCounts159(bytes: Int64, nodes: Int64): (Int64, Int64) {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotRetainedCountsFrame159(loan.getOrThrow(), bytes, nodes) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func entryDescriptionEquals159(index: Int64, expected: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { loan.getOrThrow().entryDescriptionEquals159(index, expected) }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>; sharedSnapshotClosePayments159(payments)
        }
    }
    public func identityEqualsValue159(expected: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { loan.getOrThrow().identityEqualsValue159(expected) }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>; sharedSnapshotClosePayments159(payments)
        }
    }
    public func identityEqualsShared159(other: SharedToolSetSnapshot159): Bool {
        var first: ?SharedToolSnapshotLoan159 = Some(begin159())
        try {
            var second: ?SharedToolSnapshotLoan159 = Some(other.begin159())
            try { first.getOrThrow().identityEqualsShared159(second.getOrThrow()) }
            finally {
                let payments = sharedSnapshotReturnLoanFrame159(second.getOrThrow())
                second = None<SharedToolSnapshotLoan159>; sharedSnapshotClosePayments159(payments)
            }
        } finally {
            let payments = sharedSnapshotReturnLoanFrame159(first.getOrThrow())
            first = None<SharedToolSnapshotLoan159>; sharedSnapshotClosePayments159(payments)
        }
    }
    public func hasNoEntriesOrHooks159(): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotEmptyFrame159(loan.getOrThrow()) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            sharedSnapshotClosePayments159(payments)
        }
    }
    func estimateConservativeTokens159(): Int64 {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotConservativeFrame159(loan.getOrThrow()) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func hasMatchingHook159f(event: String, name: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try {
            let result = loan.getOrThrow().matchingHook159f(event, name)
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
            result
        } catch (error: Exception) {
            match (loan) { case Some(value) => value.holdFailure159(); case None => () }
            throw error
        }
    }
    public func copyMatchingHookHandlers159f(event: String, toolName: String): ?OwnedToolHookSelection159f {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try {
            let result = loan.getOrThrow().copyMatchingHooks159f(event, toolName)
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
            result
        } catch (error: Exception) {
            match (loan) { case Some(value) => value.holdFailure159(); case None => () }
            throw error
        }
    }
    public func copyOwnedModelTools159(): OwnedModelTools159 {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try {
            // The whole copy helper returns before any source loan is cleared.
            // Its result contains independently paid copies, not snapshot refs.
            let result = loan.getOrThrow().copyModelTools159()
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
            result
        } catch (error: Exception) {
            match (loan) { case Some(value) => value.holdFailure159(); case None => () }
            throw error
        }
    }
    func manifestCatalog159(): OwnedToolCatalogValue159 {
        // The original-bank phase exists before the carrier, registration and
        // compiler's complete catalog DOM/identity-digest construction.
        OwnedToolCatalogValue159(begin159())
    }
    func modelLaneSnapshot159(lane: ModelLane): OwnedModelLaneSnapshot159 {
        // begin159 pays the carrier/node/codec phase before either object.
        let result = OwnedModelLaneSnapshot159(begin159())
        result.install159(lane)
        result
    }
    public func borrow159(): SharedToolSnapshotRead159 {
        // begin159 prepays the complete read carrier before either object.
        SharedToolSnapshotRead159(begin159())
    }
    public func hasAvailableTools159(): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotAvailableFrame159(loan.getOrThrow()) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func hasBoundThread159(): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotHasThreadFrame159(loan.getOrThrow()) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func requiredThreadMatches159(thread: ThreadId): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotRequiredThreadFrame159(loan.getOrThrow(), thread) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func strictAvailableExport159(name: String, version: String, fingerprint: String, schemaDigest: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotStrictExportFrame159(loan.getOrThrow(), name, version, fingerprint, schemaDigest) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func hasExportName159(name: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotHasNameFrame159(loan.getOrThrow(), name) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func availableCompleteExport159(name: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotAvailableCompleteFrame159(loan.getOrThrow(), name) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func matchesRegistration159(name: String, version: String, fingerprint: String, digest: String, scope: ?ThreadId): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotRegistrationFrame159(loan.getOrThrow(), name, version, fingerprint, digest, scope) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func permitsThread159(thread: ThreadId): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotThreadFrame159(loan.getOrThrow(), thread) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func hasCompleteIdentities159(): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotIdentitiesFrame159(loan.getOrThrow()) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func matchesExport159(name: String, version: String, fingerprint: String, schemaDigest: String): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotExportFrame159(loan.getOrThrow(), name, version, fingerprint, schemaDigest) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            sharedSnapshotClosePayments159(payments)
        }
    }
    public func contentEquals159(expected: ToolSetSnapshot): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotContentFrame159(loan.getOrThrow(), expected) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            sharedSnapshotClosePayments159(payments)
        }
    }
    // Closed DATA-only comparison against the actual stored model-lane codec.
    // No snapshot, entry, schema, String or callback is exported to Store.
    public func matchesStoredModelLane185(lane: AgentValue): Bool {
        var loan: ?SharedToolSnapshotLoan159 = Some(begin159())
        try { sharedSnapshotStoredLaneFrame185(loan.getOrThrow(), lane) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally {
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = None<SharedToolSnapshotLoan159>
            sharedSnapshotClosePayments159(payments)
        }
    }
    private func begin159(): SharedToolSnapshotLoan159 {
        lock.lock()
        try { owner.getOrThrow().begin159() } finally { lock.unlock() }
    }
    public func close159(): Unit {
        let payments = clearShareFrame159()
        sharedSnapshotClosePayments159(payments)
    }
    private func clearShareFrame159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (owner.isNone()) { return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
            let detached = owner.getOrThrow().removeShare159()
            let handle = handlePayment
            owner = Option<SharedToolSnapshotState159>.None
            handlePayment = Option<LogicalJsonOwnerReservation>.None
            (handle, detached[0], detached[1])
        } finally { lock.unlock() }
    }
}

// A read token can cross a real Future boundary without exporting any payload.
// Its own lock makes close wait for the entire concrete scalar helper; the
// shared state's loan survives closing every owning share in the meantime.
public class SharedToolSnapshotRead159 {
    private let lock = Mutex()
    private var loan: ?SharedToolSnapshotLoan159
    init(loan: SharedToolSnapshotLoan159) { this.loan = Some(loan) }
    public func hasAvailableTools159(): Bool {
        lock.lock()
        try { sharedSnapshotAvailableFrame159(loan.getOrThrow()) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally { lock.unlock() }
    }
    public func contentEquals159(expected: ToolSetSnapshot): Bool {
        lock.lock()
        try { sharedSnapshotContentFrame159(loan.getOrThrow(), expected) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally { lock.unlock() }
    }
    public func matchesExport159(name: String, version: String, fingerprint: String, digest: String): Bool {
        lock.lock()
        try { sharedSnapshotExportFrame159(loan.getOrThrow(), name, version, fingerprint, digest) }
        catch (error: Exception) { loan.getOrThrow().holdFailure159(); throw error }
        finally { lock.unlock() }
    }
    public func close159(): Unit {
        let payments = clearReadFrame159()
        sharedSnapshotClosePayments159(payments)
    }
    private func clearReadFrame159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (loan.isNone()) { return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
            let payments = sharedSnapshotReturnLoanFrame159(loan.getOrThrow())
            loan = Option<SharedToolSnapshotLoan159>.None
            payments
        } finally { lock.unlock() }
    }
}

class SharedToolSnapshotState159 {
    private let lock = Mutex()
    private var snapshot: ?ToolSetSnapshot
    private var dataPayment: ?LogicalJsonOwnerReservation
    private var metadataPayment: ?LogicalJsonOwnerReservation
    private var shares: Int64 = 0
    private var loans: Int64 = 0
    private var held = false
    private var failedLoans159: ?SharedToolSnapshotLoan159 = None<SharedToolSnapshotLoan159>
    var next159: ?SharedToolSnapshotState159 = None<SharedToolSnapshotState159>
    init(snapshot: ToolSetSnapshot, data: LogicalJsonOwnerReservation, metadata: LogicalJsonOwnerReservation) {
        this.snapshot = Some(snapshot); dataPayment = Some(data); metadataPayment = Some(metadata)
        sharedToolSnapshotDebts159.retain159(this)
    }
    func newShare159(bytes!: Int64 = 4096): SharedToolSetSnapshot159 {
        lock.lock()
        try {
            if (snapshot.isNone() || dataPayment.isNone()) { throw IllegalStateException("snapshot data is retired") }
            if (shares == Int64.Max) { throw IllegalStateException("snapshot share count overflow") }
            let payment = sharedSnapshotPhase159(dataPayment.getOrThrow(), max(4096, bytes))
            // Payment precedes the handle and all of its reference fields.
            let result = SharedToolSetSnapshot159(this, payment)
            shares++
            result
        } finally { lock.unlock() }
    }
    func newLaneMetadata159(bytes: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (snapshot.isNone() || dataPayment.isNone()) { throw IllegalStateException("snapshot data is retired") }
            // This independent original-bank lease owns copied lane Strings,
            // not a reference to this graph and not an extra graph share.
            sharedSnapshotPhase159(dataPayment.getOrThrow(), bytes)
        } finally { lock.unlock() }
    }
    func exportHistorical159(): ToolSetSnapshot {
        lock.lock()
        try {
            let value = snapshot.getOrThrow()
            held = true
            value
        } finally { lock.unlock() }
    }
    func begin159(): SharedToolSnapshotLoan159 {
        lock.lock()
        try {
            if (shares == 0 || snapshot.isNone() || dataPayment.isNone()) {
                throw IllegalStateException("snapshot has no live owning share")
            }
            if (loans == Int64.Max) { throw IllegalStateException("snapshot loan count overflow") }
            let payment = sharedSnapshotPhase159(dataPayment.getOrThrow(), 131072)
            let result = SharedToolSnapshotLoan159(this, snapshot.getOrThrow(), payment)
            loans++
            result
        } finally { lock.unlock() }
    }
    func holdFailure159(value: SharedToolSnapshotLoan159): Unit {
        lock.lock()
        try {
            held = true
            if (!value.failed159) {
                value.failed159 = true
                value.nextFailed159 = failedLoans159
                failedLoans159 = Some(value)
            }
        } finally { lock.unlock() }
    }
    func removeShare159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (shares <= 0) { throw IllegalStateException("snapshot share was already removed") }
            shares--
            detachIfReturned159()
        } finally { lock.unlock() }
    }
    func returnLoan159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (loans <= 0) { throw IllegalStateException("snapshot loan was already returned") }
            loans--
            detachIfReturned159()
        } finally { lock.unlock() }
    }
    private func detachIfReturned159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        if (shares != 0 || loans != 0 || held) { return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
        snapshot = Option<ToolSetSnapshot>.None
        let data = dataPayment; let metadata = metadataPayment
        dataPayment = Option<LogicalJsonOwnerReservation>.None
        metadataPayment = Option<LogicalJsonOwnerReservation>.None
        sharedToolSnapshotDebts159.remove159(this)
        (data, metadata)
    }
}

class SharedToolSnapshotLoan159 {
    private var copiedInvoice159: Int64 = 131072
    var failed159 = false
    var nextFailed159: ?SharedToolSnapshotLoan159 = None<SharedToolSnapshotLoan159>
    private var owner: ?SharedToolSnapshotState159
    private var snapshot: ?ToolSetSnapshot
    private var payment: ?LogicalJsonOwnerReservation
    private var firstContentDigest159: ?String = None<String>
    private var secondContentDigest159: ?String = None<String>
    init(owner: SharedToolSnapshotState159, snapshot: ToolSetSnapshot, payment: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.snapshot = Some(snapshot); this.payment = Some(payment)
    }
    // Package-private access is limited to the concrete closed consumers in
    // this Runtime leaf. No arbitrary public callback receives the snapshot.
    func matchingHook159f(event: String, name: String): Bool {
        for (handler in snapshot.getOrThrow().hookHandlers) {
            if (handler.event == event && (handler.matcher == "*" || handler.matcher == name)) { return true }
        }
        false
    }
    func copyMatchingHooks159f(event: String, toolName: String): ?OwnedToolHookSelection159f {
        let actual = snapshot.getOrThrow()
        var count: Int64 = 0
        for (handler in actual.hookHandlers where handler.event == event &&
            (handler.matcher == "*" || handler.matcher == toolName)) { count++ }
        // The zero-handler path never exports a historical graph or allocates
        // a persistent selection. Original hook ordering and limits remain.
        if (count == 0) { return None<OwnedToolHookSelection159f> }
        let paid = sharedSnapshotPhase159(payment.getOrThrow(), 131072)
        let selection = OwnedToolHookSelection159f(paid)
        let meter = ToolSnapshotMeasure159(paid)
        meter.addSlots159(count)
        for (handler in actual.hookHandlers where handler.event == event &&
            (handler.matcher == "*" || handler.matcher == toolName)) { meter.addHook159(handler) }
        meter.fund159()
        selection.installMatchingCopies159f(actual, event, toolName)
        Some(selection)
    }
    func copyModelTools159(): OwnedModelTools159 {
        // A new independent child is funded before its carrier or any output
        // array/schema/String is created. This is the original bank, no Source.
        let copiedPayment = sharedSnapshotPhase159(payment.getOrThrow(), 131072)
        let result = OwnedModelTools159(copiedPayment)
        let meter = ToolSnapshotMeasure159(copiedPayment)
        meter.addSnapshot159(snapshot.getOrThrow()); meter.fund159()
        result.installCopies159(snapshot.getOrThrow())
        result
    }
    func manifestCatalogValue159(): AgentValue {
        let meter = ToolSnapshotMeasure159(payment.getOrThrow())
        meter.addSnapshot159(snapshot.getOrThrow()); meter.fund159()
        toolCatalogSnapshotValue(snapshot.getOrThrow())
    }
    func modelLaneValue159(lane: ModelLane): AgentValue {
        let meter = ToolSnapshotMeasure159(payment.getOrThrow())
        meter.addSnapshot159(snapshot.getOrThrow())
        meter.addText159(lane.providerId); meter.addText159(lane.modelId); meter.addText159(lane.protocol)
        meter.addText159(lane.estimatorId); meter.addText159(lane.retryPolicyId)
        meter.addText159(lane.cachePolicyId); meter.addText159(lane.systemInstructionVersion)
        meter.fund159()
        copiedInvoice159 = meter.retainedInvoice159()
        modelLaneSnapshotFrame159(lane, snapshot.getOrThrow())
    }
    // Each escaped decoded/canonical copy is charged cumulatively. This
    // phase is released only by the complete concrete safe-cut consumer.
    func reserveLaneCopy159(value: AgentValue): Unit {
        let meter = ToolSnapshotMeasure159(payment.getOrThrow(), priorInvoice: copiedInvoice159)
        meter.addValue159(value); meter.fund159()
        copiedInvoice159 = meter.retainedInvoice159()
    }
    func retainedReferenceCounts159(bytes: Int64, nodes: Int64): (Int64, Int64) {
        let measure = ToolSnapshotRetainedShape159(payment.getOrThrow(), bytes, nodes)
        measure.snapshot159(snapshot.getOrThrow())
    }
    func entryDescriptionEquals159(index: Int64, expected: String): Bool {
        snapshot.getOrThrow().entries[index].description == expected
    }
    func identityEqualsValue159(expected: String): Bool { snapshot.getOrThrow().id == expected }
    func identityEqualsShared159(other: SharedToolSnapshotLoan159): Bool {
        snapshot.getOrThrow().id == other.snapshot.getOrThrow().id
    }
    func empty159(): Bool {
        snapshot.getOrThrow().entries.isEmpty() && snapshot.getOrThrow().hookHandlers.isEmpty()
    }
    func conservativeTokens159(): Int64 {
        // Literal arithmetic/order of the actual Conservative estimator.
        var total: Int64 = 8
        for (entry in snapshot.getOrThrow().entries) {
            total += estimateTextTokens(entry.name) +
                estimateTextTokens(entry.description) + 32
        }
        total
    }
    func available159(): Bool {
        for (entry in snapshot.getOrThrow().entries where entry.availableAtSnapshot) { return true }
        false
    }
    func sameBacking159(other: SharedToolSnapshotLoan159): Bool {
        refEq(owner.getOrThrow(), other.owner.getOrThrow())
    }
    func hasThread159(): Bool { snapshot.getOrThrow().threadId.isSome() }
    func requiredThread159(thread: ThreadId): Bool {
        match (snapshot.getOrThrow().threadId) { case Some(value) => value.value == thread.value; case None => false }
    }
    func strictExport159(name: String, version: String, fingerprint: String, schemaDigest: String): Bool {
        // The original readonly selector chooses the last same-name entry.
        var found = false
        for (entry in snapshot.getOrThrow().entries where entry.name == name) {
            found = entry.availableAtSnapshot && entry.hasCompleteIdentity() && entry.executorVersion == version &&
                entry.implementationFingerprint == fingerprint && entry.schemaDigest == schemaDigest
        }
        found
    }
    func thread159(thread: ThreadId): Bool {
        match (snapshot.getOrThrow().threadId) { case Some(value) => value.value == thread.value; case None => true }
    }
    func hasName159(name: String): Bool {
        for (entry in snapshot.getOrThrow().entries where entry.name == name) { return true }
        false
    }
    func availableComplete159(name: String): Bool {
        var found = false
        for (entry in snapshot.getOrThrow().entries where entry.name == name) {
            found = entry.availableAtSnapshot && entry.hasCompleteIdentity()
        }
        found
    }
    // Exact original ToolCatalog.findForSnapshot predicate: availability is
    // deliberately not added here. Scope is matched to the frozen snapshot,
    // including its original None semantics, never a supplied live context.
    func registration159(name: String, version: String, fingerprint: String, digest: String, scope: ?ThreadId): Bool {
        if (scope.isSome()) {
            let frozenThread = snapshot.getOrThrow().threadId
            if (frozenThread.isNone() || frozenThread.getOrThrow().value != scope.getOrThrow().value) { return false }
        }
        for (entry in snapshot.getOrThrow().entries where entry.name == name) {
            return entry.executorVersion == version && entry.implementationFingerprint == fingerprint && entry.schemaDigest == digest
        }
        false
    }
    func identities159(): Bool {
        for (entry in snapshot.getOrThrow().entries where !entry.hasCompleteIdentity()) { return false }
        true
    }
    func export159(name: String, version: String, fingerprint: String, schemaDigest: String): Bool {
        for (entry in snapshot.getOrThrow().entries where entry.name == name && entry.availableAtSnapshot) {
            return entry.executorVersion == version && entry.implementationFingerprint == fingerprint && entry.schemaDigest == schemaDigest
        }
        false
    }
    func contentShared159(other: SharedToolSnapshotLoan159): Bool {
        content159(other.snapshot.getOrThrow())
    }
    func laneDigest159(lane: ModelLane, expected: String): Bool {
        // modelLaneValue159 pays the complete DOM and original encoder peak
        // before construction; only the comparison Bool leaves this frame.
        modelPolicySha256Text(canonicalAgentValue(modelLaneValue159(lane))) == expected
    }
    func storedLane185(lane: AgentValue): Bool {
        // Same original bank, before any optional-field/numeric/schema work.
        // The private indexed walker pays both actual input graphs, including
        // all numeric formatting/canonical subtree work, before comparison.
        let meter = ToolSnapshotMeasure159(payment.getOrThrow())
        meter.addSnapshot159(snapshot.getOrThrow()); meter.addValue159(lane); meter.fund159()
        storedCheckpointToolSetMatches185(lane, snapshot.getOrThrow())
    }
    func content159(expected: ToolSetSnapshot): Bool {
        // Both immutable source snapshots remain paid by their actual loans.
        // Only the first 64-byte digest overlaps the second complete codec
        // helper; no canonical DOM/String/formatter from the first survives.
        produceContentDigestFrame159(snapshot.getOrThrow(), true)
        produceContentDigestFrame159(expected, false)
        firstContentDigest159.getOrThrow() == secondContentDigest159.getOrThrow()
    }
    private func produceContentDigestFrame159(value: ToolSetSnapshot, first: Bool): Unit {
        let meter = ToolSnapshotMeasure159(payment.getOrThrow())
        meter.addSnapshot159(value)
        // Separate bounded result/header storage remains in this loan until
        // the whole comparison caller returns, including its failure paths.
        meter.addSlots159(32); meter.fund159()
        let digest = toolSetSnapshotContentDigest(value)
        if (first) { firstContentDigest159 = Some(digest) }
        else { secondContentDigest159 = Some(digest) }
    }
    func holdFailure159(): Unit { owner.getOrThrow().holdFailure159(this) }
    func clear159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        if (failed159) {
            // The real thrown frame can retain newly encoded strings, not only
            // the original graph. Keep this independently paid loan intact.
            return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>)
        }
        firstContentDigest159 = None<String>; secondContentDigest159 = None<String>
        snapshot = Option<ToolSetSnapshot>.None
        let detached = owner.getOrThrow().returnLoan159()
        owner = Option<SharedToolSnapshotState159>.None
        let own = payment; payment = Option<LogicalJsonOwnerReservation>.None
        (own, detached[0], detached[1])
    }
}

private func sharedSnapshotSameBackingFrame159(left: SharedToolSnapshotLoan159, right: SharedToolSnapshotLoan159): Bool { left.sameBacking159(right) }
private func sharedSnapshotHasThreadFrame159(loan: SharedToolSnapshotLoan159): Bool { loan.hasThread159() }
private func sharedSnapshotRequiredThreadFrame159(loan: SharedToolSnapshotLoan159, thread: ThreadId): Bool { loan.requiredThread159(thread) }
private func sharedSnapshotStrictExportFrame159(loan: SharedToolSnapshotLoan159, name: String, version: String, fingerprint: String, digest: String): Bool {
    loan.strictExport159(name, version, fingerprint, digest)
}
private func sharedSnapshotHasNameFrame159(loan: SharedToolSnapshotLoan159, name: String): Bool { loan.hasName159(name) }
private func sharedSnapshotAvailableCompleteFrame159(loan: SharedToolSnapshotLoan159, name: String): Bool { loan.availableComplete159(name) }
private func sharedSnapshotRegistrationFrame159(loan: SharedToolSnapshotLoan159, name: String, version: String, fingerprint: String, digest: String, scope: ?ThreadId): Bool {
    loan.registration159(name, version, fingerprint, digest, scope)
}
private func sharedSnapshotSameContentFrame159(left: SharedToolSnapshotLoan159, right: SharedToolSnapshotLoan159): Bool { left.contentShared159(right) }
private func sharedSnapshotLaneDigestFrame159(loan: SharedToolSnapshotLoan159, lane: ModelLane, expected: String): Bool { loan.laneDigest159(lane, expected) }
private func sharedSnapshotEmptyFrame159(loan: SharedToolSnapshotLoan159): Bool { loan.empty159() }
private func sharedSnapshotConservativeFrame159(loan: SharedToolSnapshotLoan159): Int64 { loan.conservativeTokens159() }
private func sharedSnapshotAvailableFrame159(loan: SharedToolSnapshotLoan159): Bool { loan.available159() }
private func sharedSnapshotThreadFrame159(loan: SharedToolSnapshotLoan159, thread: ThreadId): Bool { loan.thread159(thread) }
private func sharedSnapshotIdentitiesFrame159(loan: SharedToolSnapshotLoan159): Bool { loan.identities159() }
private func sharedSnapshotExportFrame159(loan: SharedToolSnapshotLoan159, name: String, version: String, fingerprint: String, digest: String): Bool {
    loan.export159(name, version, fingerprint, digest)
}
private func sharedSnapshotContentFrame159(loan: SharedToolSnapshotLoan159, expected: ToolSetSnapshot): Bool { loan.content159(expected) }
private func sharedSnapshotReturnLoanFrame159(loan: SharedToolSnapshotLoan159): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) { loan.clear159() }
private func sharedSnapshotClosePayments159(value: (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation)): Unit {
    match (value[0]) { case Some(payment) => payment.close(); case None => () }
    match (value[1]) { case Some(payment) => payment.close(); case None => () }
    match (value[2]) { case Some(payment) => payment.close(); case None => () }
}
func sharedSnapshotPhase159(parent: LogicalJsonOwnerReservation, bytes: Int64): LogicalJsonOwnerReservation {
    let payment = parent.deriveRetainedLease()
    try { payment.ensureRetainedPeak(bytes); payment }
    catch (error: Exception) { payment.close(); throw error }
}
private class SharedToolSnapshotDebts159 {
    private let lock = Mutex()
    private var first: ?SharedToolSnapshotState159 = None<SharedToolSnapshotState159>
    func retain159(value: SharedToolSnapshotState159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: SharedToolSnapshotState159): Unit {
        lock.lock()
        try {
            var previous: ?SharedToolSnapshotState159 = None<SharedToolSnapshotState159>
            var current = first
            while (current.isSome()) {
                let entry = current.getOrThrow()
                if (refEq(entry, value)) {
                    match (previous) { case Some(parent) => parent.next159 = entry.next159; case None => first = entry.next159 }
                    entry.next159 = None<SharedToolSnapshotState159>; return
                }
                previous = current; current = entry.next159
            }
        } finally { lock.unlock() }
    }
}

private func sharedSnapshotRetainedCountsFrame159(loan: SharedToolSnapshotLoan159,
    bytes: Int64, nodes: Int64): (Int64, Int64) {
    loan.retainedReferenceCounts159(bytes, nodes)
}
private func sharedSnapshotStoredLaneFrame185(loan: SharedToolSnapshotLoan159, lane: AgentValue): Bool { loan.storedLane185(lane) }
