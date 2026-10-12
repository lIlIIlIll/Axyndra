package agent_minimal

import agent_domain.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func minimalServiceDecision(value: String): ApprovalDecision {
    match (value) {
        case "approve" => ApprovalDecision.Approve
        case "deny" => ApprovalDecision.Reject
        case _ => throw IllegalArgumentException("maintenance decision must be approve or deny")
    }
}

func minimalServiceText(value: AgentValue, name: String): String {
    let field = value.field(name)
    if (field.isNone() || field.getOrThrow().unifiedKind != ValueKind.Text ||
        field.getOrThrow().text == "" || field.getOrThrow().text.contains("\u{0000}")) {
        throw IllegalArgumentException("service frontend requires a nonempty text field") }
    field.getOrThrow().text
}

func minimalServiceExact(value: AgentValue, fields: Array<String>): Unit {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != fields.size) {
        throw IllegalArgumentException("service frontend object has an invalid shape") }
    for (field in value.fields) { if (!fields.contains(field.name)) {
        throw IllegalArgumentException("service frontend object has an unknown field") } }
    for (name in fields) { if (value.field(name).isNone()) {
        throw IllegalArgumentException("service frontend object has a missing field") } }
}

func minimalServiceActions(source: String): Array<AgentValue> {
    let value = parseUnifiedJson(source, maxBytes: 65536)
    if (value.unifiedKind != ValueKind.List || value.items.size > 32) {
        throw IllegalArgumentException("service frontend accepts at most 32 explicit actions") }
    for (item in value.items) {
        match (minimalServiceText(item, "action")) {
            case "tools" => minimalServiceExact(item, ["action", "thread"]); let _ = minimalServiceText(item, "thread")
            case "invoke" => minimalServiceExact(item, ["action", "thread", "tool", "arguments"])
                let _ = minimalServiceText(item, "thread"); let _ = minimalServiceText(item, "tool")
            case "refresh" => minimalServiceExact(item, ["action", "decision"])
                let _ = minimalServiceDecision(minimalServiceText(item, "decision"))
            case "status" | "stop" => minimalServiceExact(item, ["action"])
            case _ => throw IllegalArgumentException("unsupported service frontend action")
        }
    }
    value.items.toArray()
}

func minimalServiceStarts(source: String): Array<AgentValue> {
    let value = parseUnifiedJson(source, maxBytes: 65536)
    if (value.unifiedKind != ValueKind.List || value.items.size > 8) {
        throw IllegalArgumentException("serve accepts at most eight explicit operator service starts") }
    for (item in value.items) {
        minimalServiceExact(item, ["thread", "namespace", "service", "route", "decision"])
        for (name in ["thread", "namespace", "service", "route"]) { let _ = minimalServiceText(item, name) }
        let _ = minimalServiceDecision(minimalServiceText(item, "decision"))
    }
    value.items.toArray()
}

func minimalServiceInvocationReply(result: Result<ToolInvocationResult>, thread: String): MinimalRuntimeReply {
    match (result) {
        case Result.Err(error) => minimalRuntimeFailure(error, thread: thread)
        case Result.Ok(ToolInvocationResult.Denied(value)) => minimalRuntimeFailure(value.reason, thread: thread)
        case Result.Ok(ToolInvocationResult.NeedsApproval(value)) => MinimalRuntimeReply(2, objectValue([
            ValueField("ok", boolValue(false)), ValueField("code", textValue("minimal.approval_required")),
            ValueField("message", textValue("maintenance requires an explicit approved canonical operation")),
            ValueField("operation_id", textValue(value.operationId.value)), ValueField("preview", value.preview)]))
        case Result.Ok(ToolInvocationResult.Completed(value)) => MinimalRuntimeReply(if (value.isError) { 2 } else { 0 },
            objectValue([ValueField("ok", boolValue(!value.isError)), ValueField("is_error", boolValue(value.isError)),
                ValueField("code", textValue(if (value.isError) { "minimal.maintenance_failed" } else { "" })),
                ValueField("message", textValue(if (value.isError) { "canonical maintenance returned a failed tool result" } else { "" })),
                ValueField("thread_id", textValue(thread)), ValueField("call_id", textValue(value.callId)),
                ValueField("receipt_id", textValue(value.receiptId)), ValueField("output", value.output)]))
    }
}
