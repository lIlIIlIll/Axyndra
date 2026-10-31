package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

// Data delivery only. The caller has already committed the original exact
// canonical result through Kernel/Store and physically acknowledged its output.
// This object never mints Source, a receipt, approval, or a replay permission.
interface CoreOwnedCanonicalDeliveryResource {
    func closeAfterFailure(): Result<Unit>
    func isAcknowledged(): Bool
}

// Complete data only. The production adapter carries the actual retirement
// record obtained after the original Kernel canonical commit. A data reader
// cannot admit an operation, Source, receipt, approval or effect.
interface CoreOwnedCanonicalItemRead {
    func visit(guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit>
}
class CoreOwnedCommittedItemRead <: CoreOwnedCanonicalItemRead {
    private let record: OwnedCanonicalResultRetirement
    init(record: OwnedCanonicalResultRetirement) { this.record = record }
    public func visit(guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        record.visitCommittedItem(guard, consume)
    }
}

class CoreOwnedCanonicalEventDelivery <: CoreOwnedCanonicalDeliveryResource {
    private let lock = Mutex()
    private let read: CoreOwnedCanonicalItemRead
    private let guard: () -> Result<Unit>
    private let repository: OwnedRunEventRepository
    private let sink: OwnedAgentEventSink
    private let meta: EventMeta
    private let payload: CoreOwnedCanonicalPayloadFactory
    private var held: ?OwnedAgentEvent = None
    private var storageAlias: ?OwnedAgentEvent = None
    private var failedAlias: ?OwnedCanonicalThreadItemAliasCustody = None
    private var write: ?OwnedRunEventWrite = None
    private var started = false
    private var staged = false
    private var appended = false
    private var delivered = false
    private var acknowledged = false

    init(record: OwnedCanonicalResultRetirement, guard: () -> Result<Unit>,
        repository: OwnedRunEventRepository, sink: OwnedAgentEventSink,
        meta: EventMeta, payload: CoreOwnedCanonicalPayloadFactory) {
        this.read = CoreOwnedCommittedItemRead(record); this.guard = guard; this.repository = repository
        this.sink = sink; this.meta = meta; this.payload = payload
    }
    init(read: CoreOwnedCanonicalItemRead, guard: () -> Result<Unit>,
        repository: OwnedRunEventRepository, sink: OwnedAgentEventSink,
        meta: EventMeta, payload: CoreOwnedCanonicalPayloadFactory) {
        this.read = read; this.guard = guard; this.repository = repository
        this.sink = sink; this.meta = meta; this.payload = payload
    }

    func run(): Result<Unit> {
        lock.lock()
        try { runBorrowed() }
        catch (_: Exception) { coreOwnedCanonicalDeliveryError("tool.canonical_event_delivery_failed") }
        finally { lock.unlock() }
    }
    private func runBorrowed(): Result<Unit> {
        if (started) { return coreOwnedCanonicalDeliveryError("tool.canonical_delivery_already_started") }
        started = true
        match (read.visit(guard, { item, root => stage(item, root) })) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => () }
        // The Store root borrow has ended. Only now may the repository borrow
        // or acknowledge a fanout alias; no nested same-row borrow is allowed.
        storageAlias = Some(match (held.getOrThrow().fanout()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value })
        match (repository.stageOwned(storageAlias.getOrThrow())) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => write = Some(value); staged = true }
        if (!storageAlias.getOrThrow().isAcknowledged()) {
            return coreOwnedCanonicalDeliveryError("tool.canonical_event_stage_alias_ack_pending") }
        storageAlias = None
        // The first Store row callback, complete raw cells, decoder, and root
        // custody have ended. Retire this actual event alias before SQLite's
        // complete record/input allocations can be admitted by the writer.
        match (retireHeld()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!staged || write.isNone()) { return coreOwnedCanonicalDeliveryError("tool.canonical_event_not_staged") }
        match (write.getOrThrow().appendAfterSourceAliasRetirement()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => appended = true }
        match (write.getOrThrow().closeAfterStorageRetirement()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => () }
        if (!write.getOrThrow().isAcknowledged()) {
            return coreOwnedCanonicalDeliveryError("tool.canonical_event_storage_ack_pending") }
        write = None
        // Original append-before-observer order remains. A fresh paid full
        // canonical readback supplies exactly the same item and event metadata;
        // it neither repeats durable append nor reuses a stale result DOM.
        match (read.visit(guard, { item, root => deliver(item, root) })) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => () }
        // Delivery also happens after the fresh Store root callback ended.
        // A sink may now borrow and physically acknowledge its actual alias.
        delivered = true
        match (sink.emit(held.getOrThrow())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!delivered || held.isNone() || !held.getOrThrow().isAcknowledged()) {
            return coreOwnedCanonicalDeliveryError("tool.canonical_event_delivery_ack_pending") }
        held = None; acknowledged = true; Result.Ok(())
    }

    private func makeEvent(item: ThreadItem, root: OwnedCanonicalThreadItemCustody): Result<OwnedAgentEvent> {
        match (payload.validate(item)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let alias = match (root.retainAliasCustody()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value }
        // Actual immutable IDs/name captured by the factory are included,
        // before constructing the event/factory envelope. Full result bytes
        // stay in this row's original backing and are only borrowed.
        match (alias.ensureAdditionalRetainedPeak(payload.retainedPeak())) {
            case Result.Err(error) => failedAlias = Some(alias); return Result.Err(error)
            case Result.Ok(_) => () }
        try { Result.Ok(OwnedAgentEvent(meta, { actual => payload.value(actual) }, alias)) }
        catch (_: Exception) {
            failedAlias = Some(alias)
            coreOwnedCanonicalDeliveryError("tool.canonical_event_envelope_pressure") }
    }
    private func stage(item: ThreadItem, root: OwnedCanonicalThreadItemCustody): Result<Unit> {
        if (held.isSome() || write.isSome() || staged) {
            return coreOwnedCanonicalDeliveryError("tool.canonical_event_duplicate_row") }
        held = Some(match (makeEvent(item, root)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value })
        Result.Ok(())
    }
    private func deliver(item: ThreadItem, root: OwnedCanonicalThreadItemCustody): Result<Unit> {
        if (!appended || write.isSome() || held.isSome() || delivered) {
            return coreOwnedCanonicalDeliveryError("tool.canonical_event_delivery_order_invalid") }
        held = Some(match (makeEvent(item, root)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value })
        Result.Ok(())
    }
    private func retireHeld(): Result<Unit> {
        match (held) {
            case Some(value) => match (value.closeAfterEventRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => if (!value.isAcknowledged()) {
                    return coreOwnedCanonicalDeliveryError("tool.canonical_event_alias_ack_pending") }
                    held = None }
            case None => () }
        Result.Ok(())
    }
    // Resource cleanup only. It cannot retry append, delivery or any effect.
    // The Run's retained delivery registry owns this object until real ACK.
    public func closeAfterFailure(): Result<Unit> {
        lock.lock()
        try { closeBorrowedAfterFailure() }
        catch (_: Exception) { coreOwnedCanonicalDeliveryError("tool.canonical_event_cleanup_pending") }
        finally { lock.unlock() }
    }
    private func closeBorrowedAfterFailure(): Result<Unit> {
        match (failedAlias) {
            case Some(value) => match (value.closeAfterAliasRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => failedAlias = None }
            case None => () }
        match (storageAlias) {
            case Some(value) => match (value.closeAfterEventRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => if (!value.isAcknowledged()) {
                    return coreOwnedCanonicalDeliveryError("tool.canonical_event_stage_alias_ack_pending") }
                    storageAlias = None }
            case None => () }
        match (retireHeld()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (write) {
            case Some(value) => match (value.closeAfterStorageRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => if (!value.isAcknowledged()) {
                    return coreOwnedCanonicalDeliveryError("tool.canonical_event_storage_ack_pending") }
                    write = None }
            case None => () }
        acknowledged = true; Result.Ok(())
    }
    public func isAcknowledged(): Bool { lock.lock(); try { acknowledged } finally { lock.unlock() } }
}

// Complete old Tool-completion business event, constructed only while the
// actual canonical row is borrowed. No full output is captured by the factory.
class CoreOwnedToolResultPayloadFactory <: CoreOwnedCanonicalPayloadFactory {
    private let name: String
    private let call: ToolCallId
    private let operation: OperationId
    private let receipt: String
    init(name: String, call: ToolCallId, operation: OperationId, receipt: String) {
        this.name = name; this.call = call; this.operation = operation; this.receipt = receipt
    }
    public func retainedPeak(): Int64 {
        let bytes = coreOwnedCanonicalAdd(name.size, coreOwnedCanonicalAdd(call.value.size,
            coreOwnedCanonicalAdd(operation.value.size, receipt.size)))
        if (bytes > (Int64.Max - 32768) / 8) { throw IllegalStateException("canonical event factory payment overflow") }
        32768 + bytes * 8
    }
    public func validate(item: ThreadItem): Result<Unit> {
        match (item.content) {
            case ThreadItemContent.ToolResult(actualCall, actualOperation, actualReceipt, _, _) =>
                if (actualCall.value != call.value || actualOperation.value != operation.value || actualReceipt != receipt) {
                    return coreOwnedCanonicalDeliveryError("tool.canonical_event_identity_changed") }
                Result.Ok(())
            case _ => coreOwnedCanonicalDeliveryError("tool.canonical_event_result_missing") }
    }
    public func value(item: ThreadItem): AgentEventPayload {
        match (item.content) {
            case ThreadItemContent.ToolResult(_, _, actualReceipt, output, isError) =>
                AgentEventPayload.Extension(AgentEventKind.Tool, objectValue([
                    ValueField("code", textValue("tool.execution_completed")),
                    ValueField("name", textValue(name)), ValueField("call_id", textValue(call.value)),
                    ValueField("output", output), ValueField("is_error", boolValue(isError)),
                    ValueField("receipt_id", textValue(actualReceipt))]))
            case _ => throw IllegalStateException("canonical event requires its actual complete result") }
    }
}

func coreOwnedCanonicalAdd(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > Int64.Max - left) { throw IllegalStateException("canonical metadata payment overflow") }
    left + right
}
func coreOwnedCanonicalDeliveryError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "complete canonical delivery still owns its actual unpaid or unacknowledged resource debt",
        retryable: false, fallbackAllowed: false))
}
