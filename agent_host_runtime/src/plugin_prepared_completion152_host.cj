package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// The actual installed configuration chooses the original invocation ceiling.
// The Provider may propose a result but cannot select a service, capability,
// Source, operation or child. No old primitive plan accepts an empty sequence.
func hostFreezePreparedCompletion152(host: HostJavaScriptPluginHost,
    configuration: HostPrimitiveConfiguration111, generation: UInt64, localTool: String,
    context: ToolInvocationContext, call: ToolCall, binding: AgentValue,
    options: AgentValue, completion: AgentValue): Result<AgentValue> {
    configuration.retainWorkerMetadata111(65536)
    if (!httpIntentExactFields(completion, ["output", "is_error"]) ||
        completion.field("is_error").getOrThrow().unifiedKind != ValueKind.Boolean) {
        return hostPluginResourceError("primitive.completion_invalid", "expected exact data-only completion") }
    let permission = configuration.preparedCompletionPermission152(localTool)
    match (hostChildPreparationCurrent111(host, configuration, generation, localTool, context, binding, service: permission)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let plan = objectValue([ValueField("version", textValue(PLUGIN_PREPARED_COMPLETION152)),
        ValueField("binding", binding), ValueField("permission", textValue(permission)),
        ValueField("completion", completion)])
    let invocation = configuration.invocationName(localTool, service: permission)
    if (invocation != "extension.invoke") { plan.put("invocation_capability", textValue(invocation)) }
    let arguments = objectValue([ValueField("input", call.arguments), ValueField("configuration", options),
        ValueField("host_plan", plan)])
    if (!pluginPreparedCompletionArgumentsValid152(arguments)) {
        return hostPluginResourceError("primitive.completion_invalid", "invalid frozen no-effect data") }
    let frozen = configuration.copyPreparedPlan(arguments)
    match (hostChildPreparationCurrent111(host, configuration, generation, localTool, context, binding, service: permission)) {
        case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(frozen) }
}

func hostVerifyPreparedCompletion152(host: HostJavaScriptPluginHost, namespace: String,
    localTool: String, generation: UInt64, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, output: AgentValue, isError: Bool): Result<Unit> {
    if (!isFrozenPluginPreparedCompletion152(prepared.operationPlan)) {
        return hostPluginResourceError("primitive.completion_plan_changed", "data-only completion lost its frozen parent") }
    match (hostChildInvocationInput111(host, context, prepared, namespace, localTool, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let configuration = match (host.primitiveConfiguration111(namespace, localTool, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(Some(value)) => value
        case Result.Ok(None) => return hostPluginResourceError("primitive.completion_selection_missing", "original selection is absent") }
    let expected = prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("completion").getOrThrow()
    let planned = expected.field("output").getOrThrow()
    // Payment precedes the fixed meter and every indexed/scalar traversal.
    // Derive only from the original installed reservation; the original two
    // source DOMs stay paid separately throughout the complete comparison.
    let loan = configuration.inputTemporaryPayment111(1048576)
    try {
        if (expected.field("is_error").getOrThrow().asBool() != isError ||
            !hostPreparedCompletionEqual153(loan, planned, output)) {
            return hostPluginResourceError("primitive.completion_output_changed", "Native terminal differs from the complete frozen result") }
        match (hostChildInvocationInput111(host, context, prepared, namespace, localTool, generation)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(()) }
    } finally { loan.close() }
}

// Bool-only lexical frame: no counter, value or encoded String escapes. Both
// full original canonical codecs are funded as simultaneously retained data.
// This helper supplies no Source, permission, operation or completion ACK.
func hostPreparedCompletionEqual153(owner: LogicalJsonOwnerReservation,
    expected: AgentValue, actual: AgentValue): Bool {
    let meter = HostPaidValueProjection151(owner)
    try { hostPreparedCompletionCompareFrame153(meter, expected, actual) }
    finally { meter.closeUnpublished151() }
}
func hostPreparedCompletionCompareFrame153(meter: HostPaidValueProjection151,
    expected: AgentValue, actual: AgentValue): Bool {
        let left = meter.measureBorrowedValue151(expected)
        let right = meter.measureBorrowedValue151(actual)
        if (left.bytes > 8388608 || right.bytes > 8388608) {
            throw LogicalJsonPayloadError("completion comparison exceeds the original 8MiB codec bound") }
        if (left.nodes > Int64.Max - right.nodes) {
            throw LogicalJsonPayloadError("completion comparison node SUM overflow") }
        meter.fundAdditional151(left.bytes + right.bytes, left.nodes + right.nodes)
        canonicalAgentValue(expected) == canonicalAgentValue(actual)
}
