package tool_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

func eventOptionalTurnIdValue204(value: ?TurnId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalRequestIdValue204(value: ?RequestId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalToolBatchIdValue204(value: ?ToolBatchId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalToolCallIdValue204(value: ?ToolCallId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalOperationIdValue204(value: ?OperationId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventPayloadName204(payload: AgentEventPayload): String {
    match (payload) {
        case AgentEventPayload.RunStarted => "run_started"
        case AgentEventPayload.RunStateChanged(_, _, _) => "run_state_changed"
        case AgentEventPayload.AssistantStarted(_) => "assistant_started"
        case AgentEventPayload.TextDelta(_) => "text_delta"
        case AgentEventPayload.ReasoningDelta(_) => "reasoning_delta"
        case AgentEventPayload.ModelUsageUpdated(_) => "model_usage_updated"
        case AgentEventPayload.ModelRequestAttemptCompleted(_) =>
            "model_request_attempt_completed"
        case AgentEventPayload.ToolStarted(_, _, _) => "tool_started"
        case AgentEventPayload.ToolOutput(_, _, _) => "tool_output"
        case AgentEventPayload.ToolCompleted(_, _, _) => "tool_completed"
        case AgentEventPayload.ApprovalRequested(_, _) => "approval_requested"
        case AgentEventPayload.BudgetUpdated(_) => "budget_updated"
        case AgentEventPayload.BudgetSignal(_) => "budget_signal"
        case AgentEventPayload.ContextCompacted(_, _) => "context_compacted"
        case AgentEventPayload.Diagnostic(_) => "diagnostic"
        case AgentEventPayload.Audit(_, _) => "audit"
        case AgentEventPayload.Transcript(_) => "transcript"
        case AgentEventPayload.StructuredOutputCompleted(_) =>
            "structured_output_completed"
        case AgentEventPayload.TurnCompleted(_) => "turn_completed"
        case AgentEventPayload.RunCompleted => "run_completed"
        case AgentEventPayload.Extension(_, _) => "extension"
    }
}

func eventKindName204(kind: AgentEventKind): String {
    match (kind) {
        case AgentEventKind.RunStarted => "run_started"
        case AgentEventKind.RunStateChanged => "run_state_changed"
        case AgentEventKind.Model => "model"
        case AgentEventKind.Tool => "tool"
        case AgentEventKind.Approval => "approval"
        case AgentEventKind.Budget => "budget"
        case AgentEventKind.Diagnostic => "diagnostic"
        case AgentEventKind.Audit => "audit"
        case AgentEventKind.Transcript => "transcript"
        case AgentEventKind.Completed => "completed"
    }
}

func preparedPersistedAuditEventValue204(event: AgentEvent): AgentValue {
    objectValue(
            [
                ValueField("format_version", integerValue(1)),
                ValueField("sequence", integerValue(event.sequence)),
                ValueField("run_id", textValue(event.runId.value)),
                ValueField("kind", textValue(eventKindName204(event.kind))),
                ValueField("timestamp_ms", integerValue(event.meta.occurredAtMillis)),
                ValueField("trace_id", textValue(event.meta.traceId.value)),
                ValueField("turn_id", eventOptionalTurnIdValue204(event.meta.turnId)),
                ValueField("request_id", eventOptionalRequestIdValue204(event.meta.requestId)),
                ValueField("tool_batch_id", eventOptionalToolBatchIdValue204(event.meta.toolBatchId)),
                ValueField("tool_call_id", eventOptionalToolCallIdValue204(event.meta.toolCallId)),
                ValueField("operation_id", eventOptionalOperationIdValue204(event.meta.operationId)),
                ValueField("payload_type", textValue(eventPayloadName204(event.payload))),
                ValueField("detail", event.detail)
            ]
        )
}

func preparedPermissionGrantValue204(scope: ApprovalGrantScope): AgentValue {
    objectValue([ValueField("capability", textValue(scope.capability)),
        ValueField("path_prefix", textValue(scope.pathPrefix)),
        ValueField("tool_name", textValue(scope.toolName)),
        ValueField("host", textValue(scope.host)),
        ValueField("session_only", boolValue(scope.sessionOnly))])
}
