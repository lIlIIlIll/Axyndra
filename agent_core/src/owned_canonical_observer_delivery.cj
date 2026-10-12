package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

class CoreOwnedCanonicalCapture {
    var committed = false
    var lease: ?ToolResultPayloadLease = None
}

class CoreOwnedCanonicalReplayProbe {
    private let operation: OperationId
    private let call: String
    private let receipt: String
    var found = false
    init(operation: OperationId, call: String, receipt: String) {
        this.operation = operation; this.call = call; this.receipt = receipt
    }
    func read(item: ThreadItem): Result<Unit> {
        match (item.content) {
            case ThreadItemContent.ToolResult(actualCall, actualOperation, actualReceipt, _, _) =>
                if (actualOperation.value == operation.value) {
                    if (actualCall.value != call || actualReceipt != receipt) {
                        return Result.Err(AgentError(AgentErrorKind.Conflict, "operation.semantic_replay_drift",
                            "Operation already committed a different canonical ToolResult")) }
                    found = true }
            case _ => () }
        Result.Ok(())
    }
}

// A paid full-row borrow is captured first. The Store's actual root callback
// ends before the concrete observer is invoked or its alias can be closed.
class CoreOwnedCanonicalObserverDelivery <: CoreOwnedCanonicalDeliveryResource {
    private let lock = Mutex()
    private let read: CoreOwnedCanonicalItemRead
    private let guard: () -> Result<Unit>
    private let observe: (OwnedCanonicalThreadItemAliasCustody) -> Result<Unit>
    private var held: ?OwnedCanonicalThreadItemAliasCustody = None
    private var started = false
    private var acknowledged = false
    init(record: OwnedCanonicalResultRetirement, guard: () -> Result<Unit>,
        observe: (OwnedCanonicalThreadItemAliasCustody) -> Result<Unit>) {
        this.read = CoreOwnedCommittedItemRead(record); this.guard = guard; this.observe = observe
    }
    init(read: CoreOwnedCanonicalItemRead, guard: () -> Result<Unit>,
        observe: (OwnedCanonicalThreadItemAliasCustody) -> Result<Unit>) {
        this.read = read; this.guard = guard; this.observe = observe
    }
    func run(): Result<Unit> {
        lock.lock()
        try { runBorrowed() }
        catch (_: Exception) { coreOwnedCanonicalDeliveryError("tool.canonical_observer_failed") }
        finally { lock.unlock() }
    }
    private func runBorrowed(): Result<Unit> {
        if (started) { return coreOwnedCanonicalDeliveryError("tool.canonical_observer_already_started") }
        started = true
        match (read.visit(guard, { _, root =>
            if (held.isSome()) { return coreOwnedCanonicalDeliveryError("tool.canonical_observer_duplicate_row") }
            held = Some(match (root.retainAliasCustody()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value })
            Result.Ok(()) })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (held.isNone()) { return coreOwnedCanonicalDeliveryError("tool.canonical_observer_row_missing") }
        match (observe(held.getOrThrow())) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        closeBorrowedAfterFailure()
    }
    public func closeAfterFailure(): Result<Unit> {
        lock.lock()
        try { closeBorrowedAfterFailure() }
        catch (_: Exception) { coreOwnedCanonicalDeliveryError("tool.canonical_observer_cleanup_pending") }
        finally { lock.unlock() }
    }
    private func closeBorrowedAfterFailure(): Result<Unit> {
        match (held) {
            case Some(value) => match (value.closeAfterAliasRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => if (!value.isAcknowledged()) {
                    return coreOwnedCanonicalDeliveryError("tool.canonical_observer_ack_pending") }
                    held = None }
            case None => () }
        acknowledged = true; Result.Ok(())
    }
    public func isAcknowledged(): Bool { lock.lock(); try { acknowledged } finally { lock.unlock() } }
}

class CoreOwnedPostToolFactory {
    private let work: CorePreparedTool
    init(work: CorePreparedTool) { this.work = work }
    func value(item: ThreadItem): CoreToolHookPostEvent {
        match (item.content) {
            case ThreadItemContent.ToolResult(call, operation, receipt, output, isError) =>
                if (call.value != work.block.callId || operation.value != work.prepared.operationId.value ||
                    receipt != "receipt-" + work.prepared.operationId.value) {
                    throw IllegalStateException("actual complete canonical post-hook result changed") }
                CoreToolHookPostEvent(work.block.name, work.prepared.operationPlan.canonicalArguments,
                    operation.value, receipt, if (isError) { "failed" } else { "completed" },
                    work.prepared.operationPlan.requiredCapabilities, result: Some(output))
            case _ => throw IllegalStateException("actual complete canonical post-hook result missing") }
    }
}
