package agent_product

import agent_domain.*
import std.collection.*
import std.sync.*

private let hookGenerationDebts159g = HookGenerationDebts159g()

// Private Registry DATA. Only equality results leave this carrier; active
// hooks retain their original independent handler identity, never these bytes.
class ProductHookGeneration159g {
    private var payment: ?LogicalJsonOwnerReservation
    private var namespace: ?String = None<String>
    private var generation: ?String = None<String>
    private var retained: Int64 = 65536
    private var processHeaders159j: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
    var nextEnabled159g: ?ProductHookGeneration159g = None<ProductHookGeneration159g>
    var nextDebt159g: ?ProductHookGeneration159g = None<ProductHookGeneration159g>
    init(paid: LogicalJsonOwnerReservation) {
        payment = Some(paid)
        hookGenerationDebts159g.add159g(this)
    }
    func installRecord159g(record: ProductPluginRecord): Unit {
        if (namespace.isSome() || generation.isSome() || payment.isNone()) {
            throw IllegalStateException("hook generation is already installed")
        }
        namespace = Some(copyText159g(record.descriptor.copyText(PluginDescriptorText.Namespace)))
        let version = copyText159g(record.descriptor.copyText(PluginDescriptorText.Version))
        let digest = copyText159g(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
        let root = copyText159g(record.descriptor.copyText(PluginDescriptorText.Root))
        let size = version.size + digest.size + root.size + 2
        fundText159g(size)
        // Preserve the complete original generation grammar, including '#'.
        generation = Some(version + "#" + digest + "#" + root)
    }
    private func fundText159g(bytes: Int64): Unit {
        let invoice = productRegistryCopyInvoice83(bytes, 0)
        if (retained > 134217728 - invoice) {
            throw LogicalJsonPayloadError("hook generation exceeds original aggregate capacity")
        }
        payment.getOrThrow().ensureRetainedPeak(retained + invoice)
        retained += invoice
    }
    private func copyText159g(result: PluginRegistryResult<OwnedRegistryUtf8>): String {
        let value = match (result) {
            case PluginRegistryResult.Ok(actual) => actual
            case PluginRegistryResult.Err(error) =>
                try { throw LogicalJsonPayloadError("hook generation descriptor is unavailable") }
                finally { error.close() }
        }
        try {
            fundText159g(value.byteCount)
            let bytes = Array<UInt8>(value.byteCount, { index => value.byteAt(index) })
            String.fromUtf8(bytes)
        } finally { value.close() }
    }
    // The concrete runtime holds its one state mutex for every comparison and
    // for unlinking. No arbitrary callback or borrowed String is returned.
    func sameNamespace159g(other: ProductHookGeneration159g): Bool {
        namespace.getOrThrow() == other.namespace.getOrThrow()
    }
    func sameGeneration159g(other: ProductHookGeneration159g): Bool {
        sameNamespace159g(other) && generation.getOrThrow() == other.generation.getOrThrow()
    }
    func matchesNamespace159g(value: String): Bool { namespace.getOrThrow() == value }
    func matchesGeneration159g(value: String): Bool { generation.getOrThrow() == value }
    func reserveCancellationFrame159g(count: Int64): LogicalJsonOwnerReservation {
        if (count < 0 || count > (134217728 - 8192) / 512) {
            throw LogicalJsonPayloadError("hook cancellation frame exceeds original aggregate capacity")
        }
        let paid = payment.getOrThrow().deriveRetainedLease()
        try { paid.ensureRetainedPeak(8192 + count * 512); paid }
        catch (error: Exception) { paid.close(); throw error }
    }
    // The real runtime state lock spans selection and this claim. Reuse a
    // fixed resident header without reusing any still-live dynamic input phase.
    func acquireHookProcessResident159j(): ProductHookProcessCustody159f {
        var cursor = processHeaders159j
        while (cursor.isSome()) {
            let current = cursor.getOrThrow()
            if (current.claimActualHook159j()) { return current }
            cursor = current.nextGeneration159j
        }
        let paid = payment.getOrThrow().deriveRetainedLease()
        try { paid.ensureRetainedPeak(32768) }
        catch (error: Exception) { paid.close(); throw error }
        let current = ProductHookProcessCustody159f(paid)
        current.nextGeneration159j = processHeaders159j
        processHeaders159j = Some(current)
        if (!current.claimActualHook159j()) { throw IllegalStateException("new hook header was already claimed") }
        current
    }
    // Only after runtime unlink and the complete comparison helper returns.
    func returnUnlinkedData159g(): Unit {
        var headers = detachProcessHeadersFrame159j()
        while (headers.isSome()) {
            let current = headers.getOrThrow(); headers = current.nextGeneration159j
            current.nextGeneration159j = None<ProductHookProcessCustody159f>
            current.returnedGenerationLink159j()
        }
        let paid = clearUnlinkedDataFrame159g()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
    private func detachProcessHeadersFrame159j(): ?ProductHookProcessCustody159f {
        let result = processHeaders159j; processHeaders159j = None<ProductHookProcessCustody159f>; result
    }
    private func clearUnlinkedDataFrame159g(): ?LogicalJsonOwnerReservation {
        namespace = None<String>; generation = None<String>
        // Independent resident children remain registered and paid while
        // SDK Future.fn retirement is unknown; unlinking is not their ACK.
        processHeaders159j = None<ProductHookProcessCustody159f>
        nextEnabled159g = None<ProductHookGeneration159g>
        let paid = payment; payment = None<LogicalJsonOwnerReservation>
        hookGenerationDebts159g.remove159g(this)
        paid
    }
}

func createHookGeneration159g(record: ProductPluginRecord): ProductHookGeneration159g {
    // The carrier itself is funded before construction, not inside init.
    let paid = record.descriptor.deriveCopiedDataPayment(65536)
    let result = ProductHookGeneration159g(paid)
    result.installRecord159g(record)
    result
}

private class HookGenerationDebts159g {
    private let lock = Mutex()
    private var first: ?ProductHookGeneration159g = None<ProductHookGeneration159g>
    func add159g(value: ProductHookGeneration159g): Unit {
        lock.lock(); try { value.nextDebt159g = first; first = Some(value) }
        finally { lock.unlock() }
    }
    func remove159g(value: ProductHookGeneration159g): Unit {
        lock.lock()
        try {
            var previous: ?ProductHookGeneration159g = None<ProductHookGeneration159g>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (previous) {
                        case Some(prior) => prior.nextDebt159g = current.nextDebt159g
                        case None => first = current.nextDebt159g
                    }
                    current.nextDebt159g = None<ProductHookGeneration159g>; return
                }
                previous = cursor; cursor = current.nextDebt159g
            }
            throw IllegalStateException("hook generation was not registered")
        } finally { lock.unlock() }
    }
}

private let hookCancellationDebts159g = HookCancellationDebts159g()

// This separately funded batch owns its two private arrays. A typed input
// phase independently pays its actual Source/cause until the whole Hook and
// LocalProcess frames return; a raw or mixed batch retains the old payment.
class ProductHookCancellationBatch159g {
    private var payment: ?LogicalJsonOwnerReservation
    private var sources: ?ArrayList<CancellationSource> = None<ArrayList<CancellationSource>>
    private var returned = false
    private var cancellationEscaped = false
    private var unknownSource159l = false
    private var sourceOwners159l: ?ArrayList<ProductHookProcessCustody159f> = None<ArrayList<ProductHookProcessCustody159f>>
    var retired159g: ?ProductHookGeneration159g = None<ProductHookGeneration159g>
    var nextDebt159g: ?ProductHookCancellationBatch159g = None<ProductHookCancellationBatch159g>
    init(paid: LogicalJsonOwnerReservation) {
        payment = Some(paid)
        hookCancellationDebts159g.add159g(this)
        sources = Some(ArrayList<CancellationSource>())
        sourceOwners159l = Some(ArrayList<ProductHookProcessCustody159f>())
    }
    func addSource159g(source: CancellationSource): Unit {
        unknownSource159l = true
        sources.getOrThrow().add(source)
    }
    func addOwnedSource159l(source: CancellationSource, custody: ?ProductHookProcessCustody159f): Unit {
        match (custody) {
            case Some(value) =>
                if (value.enterGenerationCancellation159l(source)) {
                    sourceOwners159l.getOrThrow().add(value)
                } else {
                    value.holdGenerationCancellation159j(); unknownSource159l = true
                }
            case None => unknownSource159l = true
        }
        sources.getOrThrow().add(source)
    }
    func cancelSources159g(): Unit {
        // An unknown historical Source keeps the old paid batch. For wholly
        // typed batches every exact Source has its own original paid caller
        // DATA phase, including the one cause retained by cancellation.
        if (!sources.getOrThrow().isEmpty() && unknownSource159l) { cancellationEscaped = true }
        cancelHookSourcesFrame159g(sources.getOrThrow())
        returned = true
    }
    func returnComparisonFrame159g(): Unit {
        if (!returned) { throw IllegalStateException("hook cancellation frame has not returned") }
        let old = detachRetiredGenerationFrame159g()
        match (old) { case Some(value) => value.returnUnlinkedData159g(); case None => () }
        if (cancellationEscaped) { return }
        returnOwnedSourcesFrame159l()
        let paid = clearEmptyFrame159g()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
    private func detachRetiredGenerationFrame159g(): ?ProductHookGeneration159g {
        let old = retired159g; retired159g = None<ProductHookGeneration159g>; old
    }
    private func returnOwnedSourcesFrame159l(): Unit {
        let owners = detachReturnedSourcesFrame159l()
        // The entire actual Source array/backing has been cleared by the
        // completed helper. This remaining array contains paid headers only.
        for (owner in owners) { owner.returnedGenerationCancellation159l() }
    }
    private func detachReturnedSourcesFrame159l(): ArrayList<ProductHookProcessCustody159f> {
        if (!returned || cancellationEscaped) { throw IllegalStateException("source cancellation consumers have not returned") }
        sources = None<ArrayList<CancellationSource>>
        let owners = sourceOwners159l.getOrThrow()
        sourceOwners159l = None<ArrayList<ProductHookProcessCustody159f>>
        owners
    }
    private func clearEmptyFrame159g(): ?LogicalJsonOwnerReservation {
        sources = None<ArrayList<CancellationSource>>
        let paid = payment; payment = None<LogicalJsonOwnerReservation>
        hookCancellationDebts159g.remove159g(this); paid
    }
}
private func cancelHookSourcesFrame159g(sources: ArrayList<CancellationSource>): Unit {
    let reason = CancellationReason(
        CancellationReasonKind.Failure,
        "plugin.hook_snapshot_revoked",
        "plugin hook generation was disabled or replaced",
        cancelledAtMillis: agentUtcMillis()
    )
    for (source in sources) { let _ = source.cancel(reason: Some(reason)) }
}
private class HookCancellationDebts159g {
    private let lock = Mutex()
    private var first: ?ProductHookCancellationBatch159g = None<ProductHookCancellationBatch159g>
    func add159g(value: ProductHookCancellationBatch159g): Unit {
        lock.lock(); try { value.nextDebt159g = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159g(value: ProductHookCancellationBatch159g): Unit {
        lock.lock()
        try {
            var previous: ?ProductHookCancellationBatch159g = None<ProductHookCancellationBatch159g>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (previous) { case Some(prior) => prior.nextDebt159g = current.nextDebt159g; case None => first = current.nextDebt159g }
                    current.nextDebt159g = None<ProductHookCancellationBatch159g>; return
                }
                previous = cursor; cursor = current.nextDebt159g
            }
            throw IllegalStateException("hook cancellation batch was not registered")
        } finally { lock.unlock() }
    }
}
