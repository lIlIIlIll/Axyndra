package agent_core

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

class CoreBoundaryTurnReservation { var turn: ?TurnId = None }

func coreContextBoundaryCounterValue(value: BudgetCounter, turns!: ?Int64 = None): AgentValue {
    objectValue([ValueField("model_requests", integerValue(value.modelRequests)),
        ValueField("work_model_requests", integerValue(value.workModelRequests)), ValueField("drain_model_requests", integerValue(value.drainModelRequests)),
        ValueField("input_tokens", integerValue(value.inputTokens)), ValueField("output_tokens", integerValue(value.outputTokens)),
        ValueField("reasoning_tokens", integerValue(value.reasoningTokens)), ValueField("cache_read_tokens", integerValue(value.cacheReadTokens)),
        ValueField("cache_write_tokens", integerValue(value.cacheWriteTokens)), ValueField("cost_micros", match (value.costMicros) {
            case Some(cost) => integerValue(cost); case None => nullValue() }),
        ValueField("last_input_tokens", integerValue(value.lastInputTokens)), ValueField("last_output_tokens", integerValue(value.lastOutputTokens)),
        ValueField("last_duration_millis", integerValue(value.lastRequestDurationMillis)), ValueField("tool_calls", integerValue(value.toolCalls)),
        ValueField("turns", integerValue(match (turns) { case Some(count) => count; case None => value.turns }))])
}
func coreContextBoundaryCounter(value: AgentValue, restoredWallStart!: ?Int64 = None): BudgetCounter {
    contextBoundaryShape(value, ["model_requests", "work_model_requests", "drain_model_requests", "input_tokens", "output_tokens",
        "reasoning_tokens", "cache_read_tokens", "cache_write_tokens", "cost_micros", "last_input_tokens", "last_output_tokens",
        "last_duration_millis", "tool_calls", "turns"])
    let cost = contextBoundaryField(value, "cost_micros")
    let counter = BudgetCounter(modelRequests: contextBoundaryInteger(value, "model_requests"),
        workModelRequests: contextBoundaryInteger(value, "work_model_requests"), drainModelRequests: contextBoundaryInteger(value, "drain_model_requests"),
        inputTokens: contextBoundaryInteger(value, "input_tokens"), outputTokens: contextBoundaryInteger(value, "output_tokens"),
        reasoningTokens: contextBoundaryInteger(value, "reasoning_tokens"), cacheReadTokens: contextBoundaryInteger(value, "cache_read_tokens"),
        cacheWriteTokens: contextBoundaryInteger(value, "cache_write_tokens"),
        costMicros: if (cost.unifiedKind == ValueKind.Null) { None } else { Some(contextBoundaryInteger(value, "cost_micros")) },
        lastInputTokens: contextBoundaryInteger(value, "last_input_tokens"), lastOutputTokens: contextBoundaryInteger(value, "last_output_tokens"),
        lastRequestDurationMillis: contextBoundaryInteger(value, "last_duration_millis"), toolCalls: contextBoundaryInteger(value, "tool_calls"),
        turns: contextBoundaryInteger(value, "turns"), restoredWallStart: restoredWallStart)
    if (counter.workModelRequests > Int64.Max - counter.drainModelRequests ||
        counter.modelRequests != counter.workModelRequests + counter.drainModelRequests) {
        throw IllegalArgumentException("context boundary model counters disagree") }
    counter
}
func coreContextBoundaryToolState(value: AgentValue): CoreToolLoopState {
    contextBoundaryShape(value, ["consecutive_capability_denials", "last_capability_denied_tool"])
    let result = CoreToolLoopState()
    result.consecutiveCapabilityDenials = contextBoundaryInteger(value, "consecutive_capability_denials")
    result.lastCapabilityDeniedTool = contextBoundaryText(value, "last_capability_denied_tool")
    result
}
func coreContextBoundaryCapture(request: AgentRunRequest, counter: BudgetCounter,
    control: CoreRunControl, state: CoreToolLoopState): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.core-context-boundary/v1")),
        ValueField("point", textValue("after_safe_cut")), ValueField("request", coreContextBoundaryRequestValue(request)),
        ValueField("counter", coreContextBoundaryCounterValue(counter)), ValueField("control", control.contextBoundaryControlValue()),
        ValueField("usage", contextBoundaryUsageValue(control.ledger.snapshot())),
        ValueField("wall_start_millis", integerValue(counter.wallStartedAtMillis)),
        ValueField("tool_loop_state", objectValue([ValueField("consecutive_capability_denials", integerValue(state.consecutiveCapabilityDenials)),
            ValueField("last_capability_denied_tool", textValue(state.lastCapabilityDeniedTool))]))])
}
func coreContextBoundaryReservedData(before: AgentValue, counter: BudgetCounter,
    control: CoreRunControl, usage: ExecutionUsage): AgentValue {
    let fields = ArrayList<ValueField>()
    for (field in before.fields) { fields.add(match (field.name) {
        case "point" => ValueField(field.name, textValue("turn_reserved"))
        case "counter" => ValueField(field.name, coreContextBoundaryCounterValue(counter, turns: Some(counter.turns + 1)))
        case "control" => ValueField(field.name, control.contextBoundaryControlValue())
        case "usage" => ValueField(field.name, contextBoundaryUsageValue(usage))
        case _ => field }) }
    objectValue(fields.toArray())
}
func coreContextBoundaryError(message: String): AgentError {
    AgentError(AgentErrorKind.RecoveryRequired, "context.boundary_recovery_required", message, retryable: false)
}
