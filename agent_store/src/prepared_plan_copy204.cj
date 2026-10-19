package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

private let preparedPlanCopies204 = PreparedPlanCopyLedger204()

// The fixed scanner frame and this private byte buffer must already be paid.
// The entire scan borrows the Array synchronously and returns only a number.
// It has no Source, callback, database or authorization operation.
public func preparedFramedValueCopyPeak204(bytes: Array<UInt8>): Int64 {
    PreparedFramedValueScan204(bytes).peak204()
}

private class PreparedFramedValueScan204 {
    private let bytes: Array<UInt8>
    private var offset: Int64 = 0
    private var nodes: Int64 = 0
    init(bytes: Array<UInt8>) { this.bytes = bytes }
    func peak204(): Int64 {
        if (bytes.size > 8388608) { throw IllegalStateException("stored value exceeds 8 MiB") }
        value204(0)
        if (offset != bytes.size) { throw IllegalStateException("stored value has trailing bytes") }
        if (bytes.size > (Int64.Max - 131072) / 64 ||
            nodes > (Int64.Max - 131072 - bytes.size * 64) / 2048) {
            throw LogicalJsonPayloadError("prepared value copy invoice overflow") }
        // Includes the private byte/String copies, the original parser DOM,
        // its transient lists/frames and the complete normalized plan copy.
        131072 + bytes.size * 64 + nodes * 2048
    }
    private func value204(depth: Int64): Unit {
        if (depth > 64 || offset >= bytes.size) {
            throw IllegalStateException("stored value is truncated or too deeply nested") }
        if (nodes == Int64.Max) { throw LogicalJsonPayloadError("prepared value node invoice overflow") }
        nodes++
        let tag = bytes[offset]; offset++
        match (tag) {
            case b'n' | b't' | b'f' => ()
            case b'd' | b's' => let _ = frame204()
            case b'l' =>
                let count = count204()
                for (_ in 0..count) { value204(depth + 1) }
            case b'o' =>
                let count = count204()
                for (_ in 0..count) {
                    let _ = frame204()
                    if (nodes == Int64.Max) { throw LogicalJsonPayloadError("prepared field invoice overflow") }
                    nodes++; value204(depth + 1)
                }
            case _ => throw IllegalStateException("stored value has an unknown type tag")
        }
    }
    private func frame204(): (Int64, Int64) {
        let start = offset
        var length: Int64 = 0
        while (offset < bytes.size && bytes[offset] >= b'0' && bytes[offset] <= b'9') {
            let digit = Int64(bytes[offset] - b'0')
            if (length > (Int64.Max - digit) / 10) {
                throw IllegalStateException("stored value frame length is invalid") }
            length = length * 10 + digit; offset++
        }
        if (start == offset || offset >= bytes.size || bytes[offset] != b':') {
            throw IllegalStateException("stored value has an invalid length frame") }
        offset++
        if (length > bytes.size - offset) { throw IllegalStateException("stored value frame is truncated") }
        let content = offset; offset += length
        (content, length)
    }
    private func count204(): Int64 {
        let (start, size) = frame204()
        var index = start
        let end = start + size
        var negative = false
        if (index < end && (bytes[index] == b'+' || bytes[index] == b'-')) {
            negative = bytes[index] == b'-'; index++ }
        if (index == end) { throw IllegalStateException("stored collection count is invalid") }
        var count: Int64 = 0
        while (index < end) {
            if (bytes[index] < b'0' || bytes[index] > b'9') {
                throw IllegalStateException("stored collection count is invalid") }
            let digit = Int64(bytes[index] - b'0')
            if (count > (1000000 - digit) / 10) {
                throw IllegalStateException("stored collection count is out of bounds") }
            count = count * 10 + digit; index++
        }
        if (negative && count != 0) { throw IllegalStateException("stored collection count is out of bounds") }
        count
    }
}

// Private receiving copies never acknowledge the sender's original Catalog or
// Prepared graph. An error keeps this exact registered phase and its payment.
class PreparedPlanCopyPhase204 {
    private var payment: ?LogicalJsonOwnerReservation
    private var input: ?PreparedPlanUtf8Owner204 = None<PreparedPlanUtf8Owner204>
    private var bytes: ?Array<UInt8> = None<Array<UInt8>>
    private var encoded: ?String = None<String>
    private var plan: ?NormalizedOperationPlan = None<NormalizedOperationPlan>
    private var failure: ?AgentError = None<AgentError>
    private var exception: ?Exception = None<Exception>
    private var copyPeak: Int64 = 131072
    private var cleared = false
    private var unknownPlanConsumer = false
    var next204: ?PreparedPlanCopyPhase204 = None<PreparedPlanCopyPhase204>
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }

    func installInput204(value: PreparedPlanUtf8Owner204): Unit {
        if (input.isSome() || bytes.isSome() || cleared) {
            throw IllegalStateException("prepared copy phase was already installed") }
        input = Some(value)
    }
    func copyAndDecodeFrame204(): Unit {
        let source = input.getOrThrow()
        let size = source.byteCount
        if (size < 0 || size > 8388608) { throw IllegalStateException("stored value exceeds 8 MiB") }
        // Prepay the Array and String before allocation, using the same bank.
        payment.getOrThrow().ensureRetainedPeak(131072 + size * 4)
        let buffer = Array<UInt8>(size, { _ => UInt8(0) })
        bytes = Some(buffer)
        for (index in 0..size) { buffer[index] = source.byteAt(index) }
        if (source.byteCount != size) { throw IllegalStateException("prepared byte count changed while copying") }
        copyPeak = preparedFramedValueCopyPeak204(buffer)
        payment.getOrThrow().ensureRetainedPeak(copyPeak)
        encoded = Some(String.fromUtf8(buffer))
        plan = Some(decodePreparedOperationPlan204(encoded.getOrThrow()))
        // The original full SQL/codec invoice remains additive to the live
        // receiver copy; neither invoice nor the original bank cap is reduced.
        let meter = HubProcessPlanInvoice180({ minimum => fundWork204(minimum) })
        meter.includePlan(plan.getOrThrow())
        fundWork204(meter.retainedPeak())
    }
    private func fundWork204(minimum: Int64): Unit {
        if (minimum < 0 || copyPeak > Int64.Max - minimum) {
            throw LogicalJsonPayloadError("prepared receiver SUM overflow") }
        payment.getOrThrow().ensureRetainedPeak(copyPeak + minimum)
    }
    func sourceCopyReturned204(): Unit { input = None<PreparedPlanUtf8Owner204> }
    func prepareFrame204(store: DurableOperationStore, source: DirectToolCallRef): Result<Unit> {
        // ManagedJobAdmission delegates verifyManagedJobPlan to its retained
        // arbitrary OperationRuntimePort. That consumer can save this copy;
        // a successful concrete SQL prepare is not its alias-return receipt.
        match (source.origin) {
            case DirectCallOrigin.ManagedJob(_) => unknownPlanConsumer = true
            case _ => ()
        }
        store.prepareDirectOperation(source, plan.getOrThrow())
    }
    func resolveFrame204(runtime: AgentThreadRuntime, itemId: ItemId,
        operationId: OperationId, callId: CanonicalToolCallId, stage: OperationAttemptStage,
        attempt: Result<ToolInvocationResult>, receiptId: String, observedAtMillis: Int64,
        expectedRunId: RunId, expectedEpoch: Int64): Result<Unit> {
        // RuntimeOperationResolution and every receipt/transaction temporary
        // end in this full helper. Only Unit or a retained error leaves it.
        match (runtime.resolveOperation(itemId, operationId, callId, plan.getOrThrow(),
            stage, attempt, receiptId, observedAtMillis,
            expectedRunId: Some(expectedRunId), expectedEpoch: Some(expectedEpoch))) {
            case Result.Ok(_) => Result<Unit>.Ok(())
            case Result.Err(error) => Result<Unit>.Err(error)
        }
    }
    func holdError204(error: AgentError): Unit { failure = Some(error) }
    func holdException204(error: Exception): Unit { exception = Some(error) }
    func hasUnknownPlanConsumer204(): Bool { unknownPlanConsumer }
    func clearReturnedFrame204(): Unit {
        if (failure.isSome() || exception.isSome()) {
            throw IllegalStateException("failed prepared copy still owns its data") }
        input = None<PreparedPlanUtf8Owner204>
        plan = None<NormalizedOperationPlan>; encoded = None<String>; bytes = None<Array<UInt8>>
        cleared = true
    }
    func retirementPayment204(): LogicalJsonOwnerReservation {
        if (!cleared || input.isSome() || plan.isSome() || encoded.isSome() || bytes.isSome()) {
            throw IllegalStateException("prepared copy frames have not returned") }
        payment.getOrThrow()
    }
    func detachPaymentFrame204(): Unit { payment = None<LogicalJsonOwnerReservation> }
}

private class PreparedPlanCopyLedger204 {
    private let lock = Mutex()
    private var first: ?PreparedPlanCopyPhase204 = None<PreparedPlanCopyPhase204>
    private var pending: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var retiring: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func register204(payment: LogicalJsonOwnerReservation): ?PreparedPlanCopyPhase204 {
        lock.lock()
        try {
            if (pending.isSome()) { return None<PreparedPlanCopyPhase204> }
            // A failed allocation cannot strand its prepaid reservation.
            pending = Some(payment)
            let value = PreparedPlanCopyPhase204(payment)
            value.next204 = first; first = Some(value)
            pending = None<LogicalJsonOwnerReservation>
            Some(value)
        } finally { lock.unlock() }
    }
    func retire204(value: PreparedPlanCopyPhase204): Unit {
        lock.lock()
        try {
            // A failed prior retirement is still paid and reachable. There is
            // no sweep or guessed ACK for it or for this later phase.
            if (retiring.isSome()) { return }
            retiring = Some(value.retirementPayment204())
            unlinkFrame204(value)
            value.detachPaymentFrame204()
            closeRetirementFrame204()
            retiring = None<LogicalJsonOwnerReservation>
        } finally { lock.unlock() }
    }
    private func unlinkFrame204(value: PreparedPlanCopyPhase204): Unit {
        var previous: ?PreparedPlanCopyPhase204 = None<PreparedPlanCopyPhase204>
        var cursor = first
        while (cursor.isSome()) {
            let current = cursor.getOrThrow()
            if (refEq(current, value)) {
                match (previous) {
                    case Some(parent) => parent.next204 = current.next204
                    case None => first = current.next204
                }
                current.next204 = None<PreparedPlanCopyPhase204>; return
            }
            previous = cursor; cursor = current.next204
        }
        throw IllegalStateException("prepared receiver phase is not registered")
    }
    private func closeRetirementFrame204(): Unit { retiring.getOrThrow().close() }
}

func openPreparedPlanCopy204(value: PreparedPlanUtf8Owner204): PreparedPlanCopyPhase204 {
    // The interface gives this receiver only a separate original-bank DATA
    // reservation. It gives neither Source authority nor a sender-return ACK.
    let payment = value.deriveCopiedPlanPayment204(131072)
    let registered = preparedPlanCopies204.register204(payment)
    match (registered) {
        case Some(phase) =>
            try { phase.installInput204(value); phase }
            catch (error: Exception) { phase.holdException204(error); throw error }
        case None =>
            // The entire rejecting helper returned without capturing this
            // payment; it has created no receiver data or callback.
            payment.close()
            throw IllegalStateException("prepared receiver allocation is pending")
    }
}

func returnPreparedPlanCopy204(phase: PreparedPlanCopyPhase204): Unit {
    if (phase.hasUnknownPlanConsumer204()) { return }
    phase.clearReturnedFrame204()
    preparedPlanCopies204.retire204(phase)
}

func preparedApprovalMetadata204(raw: AgentValue, value: AgentValue): ToolApprovalMetadata {
    let original = parseStoredApprovalMetadata(raw)
    match (value.field("write_summary204")) {
        case None => original
        case Some(summary) =>
            let writeSummary = WriteApprovalSummary(
                storedTextField(summary, "path"), storedTextField(summary, "action"),
                storedBoolField(summary, "exists"), storedIntField(summary, "bytes"),
                storedIntField(summary, "lines"), language: storedTextField(summary, "language"),
                preview: storeStringItems(summary.field("preview").getOrThrow()),
                truncated: storedBoolField(summary, "truncated"),
                contentHash: storedTextField(summary, "content_hash"),
                beforeBytes: storedIntField(summary, "before_bytes"),
                addedLines: storedIntField(summary, "added_lines"),
                removedLines: storedIntField(summary, "removed_lines"))
            ToolApprovalMetadata(original.capabilityLabel, original.assessment, original.grantScope,
                writeSummary: Some(writeSummary), sessionApprovalAllowed: original.sessionApprovalAllowed)
    }
}

func decodePreparedOperationPlan204(encoded: String): NormalizedOperationPlan {
    let parseTimer: ?MonoTime = if (encoded.size >= 1048576) { channelWriteMemoDiagnosticStart() } else { None }
    let value = try { decodeStoredValue(encoded) }
        finally { channelWriteMemoDiagnosticRecord(9, parseTimer, a: encoded.size) }
    let capabilities = ArrayList<Capability>()
    for (item in value.field("capabilities").getOrThrow().items) {
        capabilities.add(Capability(
            parseStoreCapability(item.field("kind").getOrThrow().text),
            resource: item.field("resource").getOrThrow().text
        ))
    }
    let environment = ArrayList<ValueField>()
    for (field in value.field("environment").getOrThrow().fields) {
        environment.add(ValueField(field.name, field.value))
    }
    let bindingDigest = value.field("digest").getOrThrow().text
    let networkPolicy = match (value.field("network")) {
        case Some(raw) => requireNetworkPolicy(raw)
        case None => NetworkPolicy(NetworkPolicyMode.Denied)
    }
    NormalizedOperationPlan(
        value.field("tool").getOrThrow().text,
        value.field("arguments").getOrThrow(),
        capabilities.toArray(),
        parseStoreEffect(value.field("effect").getOrThrow().text),
        parseStoreRetry(value.field("retry").getOrThrow().text),
        bindingDigest,
        resolvedPaths: storeStringItems(value.field("paths").getOrThrow()),
        resolvedHosts: storeStringItems(value.field("hosts").getOrThrow()),
        networkPolicy: Some(networkPolicy),
        cwd: value.field("cwd").getOrThrow().text,
        relevantEnvironment: environment.toArray(),
        approvalMetadata: match (value.field("approval")) {
            case Some(raw) => Some(preparedApprovalMetadata204(raw, value))
            case None => None
        },
        idempotencyKey: value.field("idempotency_key").getOrThrow().text,
        replayDisposition: match (value.field("replay")) {
            case Some(raw) => Some(parseReplayDisposition(raw))
            case None => None
        },
        toolVersion: optionalStoreText(value, "tool_version", "legacy-v1"),
        implementationFingerprint: optionalStoreText(
            value, "implementation_fingerprint", bindingDigest
        ),
        schemaDigest: optionalStoreText(value, "schema_digest", bindingDigest),
        effectiveArgumentsDigest: optionalStoreText(
            value, "effective_arguments_digest", bindingDigest
        ),
        replayContractVersion: storedReplayContractVersion(value),
        contextReadFacts: match (value.field("context_reads")) {
            case Some(raw) => contextReadFactLinksFromValue(raw); case None => [] }
    )
}
