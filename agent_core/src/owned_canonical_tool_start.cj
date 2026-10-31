package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Full canonical data only. Actual Kernel preparation/Source/approval still
// uses the original CommittedToolCallRef and unchanged normal policy route.
interface CoreOwnedCanonicalPayloadFactory {
    func retainedPeak(): Int64
    func validate(item: ThreadItem): Result<Unit>
    func value(item: ThreadItem): AgentEventPayload
}

class CoreOwnedToolCallItemRead <: CoreOwnedCanonicalItemRead {
    private let read: OwnedCanonicalThreadReadback
    private let thread: ThreadId
    private let revision: Int64
    private let item: ItemId
    init(read: OwnedCanonicalThreadReadback, thread: ThreadId, revision: Int64, item: ItemId) {
        this.read = read; this.thread = thread; this.revision = revision; this.item = item
    }
    public func visit(guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        // This is the actual installed full-cell reader and its original
        // bank. IDs select existing complete data; they cannot create Source.
        read.visitItem(thread, revision, item, guard, consume)
    }
}

class CoreOwnedToolCallPayloadFactory <: CoreOwnedCanonicalPayloadFactory {
    private let name: String
    private let call: ToolCallId
    private let item: ItemId
    init(name: String, call: ToolCallId, item: ItemId) { this.name = name; this.call = call; this.item = item }
    public func retainedPeak(): Int64 {
        let bytes = coreOwnedCanonicalAdd(name.size, coreOwnedCanonicalAdd(call.value.size, item.value.size))
        if (bytes > (Int64.Max - 32768) / 8) { throw IllegalStateException("canonical input event invoice overflow") }
        32768 + bytes * 8
    }
    public func validate(actual: ThreadItem): Result<Unit> {
        if (actual.id.value != item.value) { return coreOwnedCanonicalDeliveryError("tool.canonical_start_item_changed") }
        match (actual.content) {
            case ThreadItemContent.ToolCall(actualCall, actualName, _) =>
                if (actualCall.value != call.value || actualName != name) {
                    return coreOwnedCanonicalDeliveryError("tool.canonical_start_call_changed") }
                Result.Ok(())
            case _ => coreOwnedCanonicalDeliveryError("tool.canonical_start_call_missing") }
    }
    public func value(actual: ThreadItem): AgentEventPayload {
        match (actual.content) {
            case ThreadItemContent.ToolCall(_, actualName, arguments) =>
                // Exact original four fields and whole arguments. Frontend
                // display copies occur only under this real paid row borrow.
                AgentEventPayload.Extension(AgentEventKind.Tool, objectValue([
                    ValueField("code", textValue("tool.execution_started")),
                    ValueField("call_id", textValue(call.value)),
                    ValueField("name", textValue(actualName)), ValueField("arguments", arguments)]))
            case _ => throw IllegalStateException("canonical input event requires its actual complete ToolCall") }
    }
}
