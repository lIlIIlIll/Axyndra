package tool_runtime

import agent_domain.*
import std.sync.*

private let toolCatalogConsumerDebts204 = ToolCatalogConsumerDebts204()

// The per-call audit/prepared-plan value chain draws on its own declared
// capacity instead of the shared host bank. Its invoice is sized by the
// caller's argument graph - a legal 2 MiB tool argument is invoiced at ~384x
// its bytes (6x lexical expansion times 64x retained extent) - so a single such
// call can need more than a hundred MiB, which the shared bank cannot admit
// alongside the long-lived installed-registry roots. Moving these short-lived
// leases here leaves the shared bank's own accounting untouched, so the
// bank-saturation contracts that assert its exact charged totals still hold.
// See docs/issue-45-draft-status.md E421/E422/E428.
let auditFramePaymentBudget = LogicalJsonOwnerBudget(maximumCharged: 536870912)

// Allocation accounting only: no invocation, Source, path or permission.
func acquireAuditFramePayment204(bytes: Int64): LogicalJsonOwnerReservation {
    auditFramePaymentBudget.acquire(max(4096, bytes))
}

// DATA-reference custody only. There are no Tool/Run/Source/approval operations
// in this carrier. Only Catalog's prepaid factory creates an instance.
public class ToolCatalogHostConsumer204 {
    private let lock = Mutex()
    private var catalog: ?ToolCatalog
    private var pipeline: ?ToolPipeline
    private var context: ?ToolInvocationContext
    private var payment: ?LogicalJsonOwnerReservation
    private var frames: Int64 = 0
    private var actionHeaders204: Int64 = 0
    private var firstPrepared204: ?PreparedToolInvocation = None<PreparedToolInvocation>
    private var preparedHeaders204: Int64 = 0
    private var pendingWirePayment204: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var firstAction204: ?ToolCatalogHostConsumerAction204 = None<ToolCatalogHostConsumerAction204>
    private var pendingActionPayment204: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var callerReturned = false
    private var resultObserved = false
    private var held = false
    private var collecting = false
    private var returned = false
    var nextPipeline204: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>
    var nextDebt204: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>

    init(catalog: ToolCatalog, pipeline: ToolPipeline, context: ToolInvocationContext,
        payment: LogicalJsonOwnerReservation) {
        this.catalog = Some(catalog); this.pipeline = Some(pipeline)
        this.context = Some(context); this.payment = Some(payment)
        toolCatalogConsumerDebts204.retain204(this)
    }
    func matchesContext204(actual: ToolInvocationContext): Bool {
        lock.lock()
        try {
            if (callerReturned || returned || collecting || context.isNone()) { return false }
            actual.sameInvocationOwner204(context.getOrThrow())
        } finally { lock.unlock() }
    }
    func beginFrame204(): ToolCatalogHostConsumerAction204 {
        lock.lock()
        try {
            if (callerReturned || returned || collecting || payment.isNone() || frames == Int64.Max) {
                throw IllegalStateException("actual Catalog consumer has returned")
            }
            if (actionHeaders204 > (Int64.Max - 65536) / 1024 - 1) { throw LogicalJsonPayloadError("Catalog action header invoice overflow") }
            // The Scope retains each linked node/header until all actions
            // return. The separate action child owns only its active frame.
            payment.getOrThrow().ensureRetainedPeak(65536 + (actionHeaders204 + 1) * 1024)
            actionHeaders204++
            let paid = payment.getOrThrow().deriveRetainedLease()
            try { paid.ensureRetainedPeak(4096) }
            catch (error: Exception) { paid.close(); throw error }
            pendingActionPayment204 = Some(paid)
            let action = ToolCatalogHostConsumerAction204(this, paid)
            action.nextAction204 = firstAction204; firstAction204 = Some(action)
            frames++; pendingActionPayment204 = None<LogicalJsonOwnerReservation>
            action
        } finally { lock.unlock() }
    }
    func belongsToCatalog204(actual: ToolCatalog): Bool {
        lock.lock()
        try { !returned && !collecting && frames > 0 &&
            match (catalog) { case Some(value) => refEq(value, actual); case None => false } }
        finally { lock.unlock() }
    }
    func holdUnknown204(): Unit {
        let actual = try { lock.lock(); held = true; catalog } finally { lock.unlock() }
        match (actual) { case Some(value) => value.recordUnknownConsumer204(); case None => () }
    }
    func frameReturned204(action: ToolCatalogHostConsumerAction204): Unit {
        lock.lock()
        try {
            if (frames < 1) { throw IllegalStateException("actual Catalog consumer frame underflow") }
            var previous: ?ToolCatalogHostConsumerAction204 = None<ToolCatalogHostConsumerAction204>
            var cursor = firstAction204
            var found = false
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, action)) {
                    match (previous) { case Some(value) => value.nextAction204 = actual.nextAction204
                        case None => firstAction204 = actual.nextAction204 }
                    actual.nextAction204 = None<ToolCatalogHostConsumerAction204>; found = true; break
                }
                previous = cursor; cursor = actual.nextAction204
            }
            if (!found) { throw IllegalStateException("actual Catalog action debt is missing") }
            frames--
        } finally { lock.unlock() }
        collectReturned204()
    }
    func observeActualExecution204(result: Result<ToolInvocationResult>): Unit {
        match (result) {
            case Result.Ok(ToolInvocationResult.Completed(value)) => if (value.isError) { holdUnknown204() }
            case _ => holdUnknown204()
        }
        lock.lock(); try { resultObserved = true } finally { lock.unlock() }
    }
    public func wholeHostCallerReturned204(): Unit {
        // This is a request only. The private collector additionally verifies
        // actual Pipeline completion, Context return and every active pin.
        lock.lock(); try { callerReturned = true } finally { lock.unlock() }
        collectReturned204()
    }
    func holdPreparedExport204(prepared: PreparedToolInvocation): Unit {
        lock.lock()
        let actual = try {
            if (returned || collecting) { throw IllegalStateException("prepared metadata owner has returned") }
            held = true; catalog
        } finally { lock.unlock() }
        match (actual) { case Some(value) => value.recordUnknownConsumer204(); case None => () }
    }
    func requirePreparedBorrow204(prepared: PreparedToolInvocation): Unit {
        lock.lock()
        try {
            if (returned || collecting || frames == 0) { throw IllegalStateException("prepared metadata has no actual private consumer") }
        } finally { lock.unlock() }
    }
    func retainPrepared204(prepared: PreparedToolInvocation): Unit {
        lock.lock()
        try {
            if (returned || collecting || frames == 0 || preparedHeaders204 > (Int64.Max - 65536) / 1024 - 1) {
                throw IllegalStateException("prepared metadata cannot register its original owner") }
            payment.getOrThrow().ensureRetainedPeak(65536 + (actionHeaders204 + preparedHeaders204 + 1) * 1024)
            if (prepared.ownCatalogConsumer204(this)) {
                preparedHeaders204++
                prepared.nextPrepared204 = firstPrepared204; firstPrepared204 = Some(prepared)
            }
        } finally { lock.unlock() }
    }
    func copyPreparedPlanUtf8204(prepared: PreparedToolInvocation): OwnedPreparedPlanUtf8204 {
        requirePreparedBorrow204(prepared)
        let owner = constructWireOwnerFrame204()
        owner.installPlanFrame204(prepared.borrowOperationPlanFrame204())
        owner.producerFrameReturned204()
        owner
    }
    func copyPlanValueUtf8204(plan: NormalizedOperationPlan): OwnedPreparedPlanUtf8204 {
        let owner = constructWireOwnerFrame204()
        owner.installPlanFrame204(plan)
        owner.producerFrameReturned204()
        owner
    }
    func copyPermissionGrantUtf8204(scope: ApprovalGrantScope): OwnedPreparedPlanUtf8204 {
        let owner = constructWireOwnerFrame204()
        owner.installPermissionGrantFrame204(scope)
        owner.producerFrameReturned204()
        owner
    }
    func constructAuditWire204(): OwnedPreparedPlanUtf8204 { constructWireOwnerFrame204() }
    private func constructWireOwnerFrame204(): OwnedPreparedPlanUtf8204 {
        lock.lock()
        try {
            if (returned || collecting || frames == 0 || pendingWirePayment204.isSome()) {
                throw IllegalStateException("prepared plan DATA construction is unavailable") }
            let paid = payment.getOrThrow().deriveRetainedLease()
            try { paid.ensureRetainedPeak(131072) }
            catch (error: Exception) { paid.close(); throw error }
            pendingWirePayment204 = Some(paid)
            let owner = OwnedPreparedPlanUtf8204(paid)
            // It is independently registered before any original Plan capture.
            pendingWirePayment204 = None<LogicalJsonOwnerReservation>
            owner
        } finally { lock.unlock() }
    }
    private func clearReturnedPreparedViewsFrame204(): Unit {
        while (firstPrepared204.isSome()) {
            let value = firstPrepared204.getOrThrow()
            firstPrepared204 = value.clearCatalogMetadataFrame204()
        }
    }
    private func collectReturned204(): Unit {
        lock.lock()
        let claimed = try {
            if (!callerReturned || !resultObserved || frames != 0 || firstAction204.isSome() || pendingActionPayment204.isSome() || pendingWirePayment204.isSome() || held || returned || collecting || context.isNone() || !context.getOrThrow().hasReturnedCatalogContextFrame204()) { false }
            else { collecting = true; true }
        } finally { lock.unlock() }
        if (!claimed) { return }
        // No callback/registration/executor local remains in the preceding
        // whole consumers. Clear the private carrier in another full helper.
        try {
            clearReturnedPreparedViewsFrame204()
            unlinkReturnedConsumerFrame204()
            // The complete unlink/capture helper has returned. The actual
            // reservation remains in this carrier field until its concrete
            // locked scalar-ledger close returns (no external callback/I/O).
            toolCatalogConsumerDebts204.remove204(this)
            payment.getOrThrow().close()
            clearClosedConsumerFrame204()
        } catch (error: Exception) {
            holdUnknown204()
            throw error
        }
    }
    private func unlinkReturnedConsumerFrame204(): Unit {
        let actors = borrowReturnedLinks204()
        // Avoid a scope-lock -> Pipeline-lock cycle against lookup's order.
        actors[0].removeHostConsumer204(this)
        actors[1].hostConsumerReturned204()
        lock.lock()
        try {
            if (!collecting || frames != 0 || held || payment.isNone()) {
                throw IllegalStateException("actual Catalog consumer still owns data")
            }
            pipeline = None<ToolPipeline>; catalog = None<ToolCatalog>
            context = None<ToolInvocationContext>
            nextPipeline204 = None<ToolCatalogHostConsumer204>
        } finally { lock.unlock() }
    }
    private func borrowReturnedLinks204(): (ToolPipeline, ToolCatalog) {
        lock.lock()
        try { (pipeline.getOrThrow(), catalog.getOrThrow()) } finally { lock.unlock() }
    }
    private func clearClosedConsumerFrame204(): Unit {
        lock.lock()
        try { payment = None<LogicalJsonOwnerReservation>; returned = true }
        finally { lock.unlock() }
    }
}

class ToolCatalogHostConsumerAction204 {
    private var owner: ?ToolCatalogHostConsumer204
    private var payment: ?LogicalJsonOwnerReservation
    var nextAction204: ?ToolCatalogHostConsumerAction204 = None<ToolCatalogHostConsumerAction204>
    init(owner: ToolCatalogHostConsumer204, payment: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.payment = Some(payment)
    }
    func retainPreparedResult204(result: Result<ToolPreparation>): Result<ToolPreparation> {
        match (owner) {
            case Some(value) => match (result) {
                case Result.Ok(ToolPreparation.Ready(prepared)) => value.retainPrepared204(prepared)
                case Result.Ok(ToolPreparation.NeedsApproval(prepared, _)) => value.retainPrepared204(prepared); value.holdUnknown204()
                case _ => () }
            case None => throw IllegalStateException("prepared result lost its actual consumer")
        }
        result
    }
    func observeActualExecution204(result: Result<ToolInvocationResult>): Unit {
        match (owner) { case Some(value) => value.observeActualExecution204(result); case None => () }
    }
    func copyPreparedPlanUtf8204(prepared: PreparedToolInvocation): OwnedPreparedPlanUtf8204 {
        match (owner) { case Some(value) => value.copyPreparedPlanUtf8204(prepared)
            case None => throw IllegalStateException("prepared plan lost its actual consumer") }
    }
    func retainAuthorizedResult204(result: Result<ToolAuthorization>): Result<ToolAuthorization> {
        match (owner) {
            case Some(value) => match (result) { case Result.Ok(ToolAuthorization.Ready(prepared)) => value.retainPrepared204(prepared); case _ => () }
            case None => throw IllegalStateException("authorization result lost its actual consumer") }
        result
    }
    func retainPreparedValueResult204(result: Result<PreparedToolInvocation>): Result<PreparedToolInvocation> {
        match (owner) { case Some(value) => match (result) { case Result.Ok(prepared) => value.retainPrepared204(prepared); case _ => () }
            case None => throw IllegalStateException("prepared value lost its actual consumer") }
        result
    }
    func copyPlanValueUtf8204(plan: NormalizedOperationPlan): OwnedPreparedPlanUtf8204 {
        match (owner) { case Some(value) => value.copyPlanValueUtf8204(plan)
            case None => throw IllegalStateException("prepared plan value lost its actual consumer") }
    }
    func copyPermissionGrantUtf8204(scope: ApprovalGrantScope): OwnedPreparedPlanUtf8204 {
        match (owner) { case Some(value) => value.copyPermissionGrantUtf8204(scope)
            case None => throw IllegalStateException("permission DATA lost its actual consumer") }
    }
    func constructAuditWire204(): OwnedPreparedPlanUtf8204 {
        match (owner) { case Some(value) => value.constructAuditWire204()
            case None => throw IllegalStateException("Audit DATA lost its actual consumer") }
    }
    // Private original method helper returned before this call. This removes
    // only the exact action's private-reference payment, never executor DATA.
    func returnedWholeAction204(): Unit {
        let actualOwner = clearReturnedActionReferences204()
        // Keep this exact reservation in the Scope's registered Action node
        // through the complete close helper. An unexpected close failure cannot
        // leave it only in a disappearing stack tuple.
        closeReturnedActionPayment204()
        clearClosedActionPayment204()
        match (actualOwner) { case Some(value) => value.frameReturned204(this); case None => () }
    }
    func holdReturnedResultData204<T>(result: Result<T>): Unit {
        match (result) { case Result.Err(_) => holdUnknown204(); case Result.Ok(_) => () }
    }
    func holdUnknown204(): Unit {
        match (owner) { case Some(value) => value.holdUnknown204(); case None => () }
    }
    private func clearReturnedActionReferences204(): ?ToolCatalogHostConsumer204 {
        let answer = owner; owner = None<ToolCatalogHostConsumer204>
        answer
    }
    private func closeReturnedActionPayment204(): Unit {
        match (payment) { case Some(value) => value.close(); case None => () }
    }
    private func clearClosedActionPayment204(): Unit {
        payment = None<LogicalJsonOwnerReservation>
    }
}

private class ToolCatalogConsumerDebts204 {
    private let lock = Mutex()
    private var first: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>
    func retain204(value: ToolCatalogHostConsumer204): Unit {
        lock.lock(); try { value.nextDebt204 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: ToolCatalogHostConsumer204): Unit {
        lock.lock()
        try {
            var previous: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>
            var cursor = first
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(owner) => owner.nextDebt204 = actual.nextDebt204
                        case None => first = actual.nextDebt204 }
                    actual.nextDebt204 = None<ToolCatalogHostConsumer204>; return
                }
                previous = cursor; cursor = actual.nextDebt204
            }
            throw IllegalStateException("actual Catalog consumer debt is missing")
        } finally { lock.unlock() }
    }
}
