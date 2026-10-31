package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

let READ_VIEW_PARAMETER_SCHEMA = "axyndra.read-view-parameter-input/v1"
let READ_VIEW_PARAMETER_METADATA_BYTES: Int64 = 16384

// A typed tree preserves every field and index, including unknown fields and
// duplicate names. It is descriptive data, never a Source or read permission.
// String values are retained only while their escaped representation is small.
func hostReadViewParameterNode(value: AgentValue, depth: Int64): AgentValue {
    if (depth > 64) { throw LogicalJsonPayloadError("parameter shape exceeds its original depth") }
    let fields = ArrayList<ValueField>()
    if (value.unifiedKind == ValueKind.Object) {
        let children = ArrayList<AgentValue>()
        for (field in value.fields) {
            children.add(objectValue([ValueField("name", textValue(field.name)),
                ValueField("node", hostReadViewParameterNode(field.value, depth + 1))]))
            if (stringifyUnifiedJson(listValue(children.toArray())).size > READ_VIEW_PARAMETER_METADATA_BYTES) {
                throw LogicalJsonPayloadError("parameter metadata exceeds the original prepare bound") }
        }
        fields.add(ValueField("type", textValue("object"))); fields.add(ValueField("fields", listValue(children.toArray())))
    } else if (value.unifiedKind == ValueKind.List) {
        let children = ArrayList<AgentValue>()
        for (item in value.items) {
            children.add(hostReadViewParameterNode(item, depth + 1))
            if (stringifyUnifiedJson(listValue(children.toArray())).size > READ_VIEW_PARAMETER_METADATA_BYTES) {
                throw LogicalJsonPayloadError("parameter metadata exceeds the original prepare bound") }
        }
        fields.add(ValueField("type", textValue("list"))); fields.add(ValueField("items", listValue(children.toArray())))
    } else {
        let kind = match (value.unifiedKind) {
            case ValueKind.Text => "text"; case ValueKind.Number => "number"
            case ValueKind.Boolean => "boolean"; case ValueKind.Null => "null"
            case _ => throw LogicalJsonPayloadError("parameter scalar type is unsupported") }
        let encoded = stringifyUnifiedJson(value)
        let raw = if (kind == "text") { value.text } else { encoded }
        fields.add(ValueField("type", textValue(kind)))
        fields.add(ValueField("utf8_bytes", integerValue(raw.size)))
        fields.add(ValueField("sha256", textValue(modelPolicySha256Text(raw))))
        fields.add(ValueField("has_nul", boolValue(kind == "text" && raw.contains("\u{0000}"))))
        if (kind != "text" || encoded.size <= 8192) { fields.add(ValueField("value", value)) }
    }
    let result = objectValue(fields.toArray())
    if (stringifyUnifiedJson(result).size > READ_VIEW_PARAMETER_METADATA_BYTES) {
        throw LogicalJsonPayloadError("parameter metadata exceeds the original prepare bound") }
    result
}

// Caller holds the original shared native allocation throughout preparation,
// return-reference comparison, resource collection and canonical freezing.
func hostReadViewParameterReference(binding: AgentValue, input: AgentValue): AgentValue {
    let encoded = stringifyUnifiedJson(input)
    if (encoded.size > HOST_READ_VIEW_INPUT_BYTES) {
        throw LogicalJsonPayloadError("parameter input exceeds the existing worker-file bound") }
    objectValue([ValueField("binding", binding), ValueField("input_bytes", integerValue(encoded.size)),
        ValueField("input_sha256", textValue(modelPolicySha256Text(encoded))),
        ValueField("metadata", hostReadViewParameterNode(input, 0))])
}

func hostReadViewReferencedRequest(binding: AgentValue, input: AgentValue, expected: AgentValue, request: AgentValue,
    configuration!: ?HostPluginHttpConfiguration = None, tool!: String = ""): Result<AgentValue> {
    if (!httpIntentExactFields(request, ["executable", "arguments", "timeout_ms", "input_reference"])) {
        return hostPluginResourceError("read_view.parameter_reference_invalid", "worker must return only the exact captured parameter reference") }
    let returned = request.field("input_reference").getOrThrow()
    // Value equality checks all ordered metadata and original bytes/hash, not
    // just a digest chosen by the package. Recompute from the same actual input.
    if (stringifyUnifiedJson(returned) != stringifyUnifiedJson(expected) ||
        stringifyUnifiedJson(hostReadViewParameterReference(binding, input)) != stringifyUnifiedJson(expected)) {
        return hostPluginResourceError("read_view.parameter_reference_changed", "returned parameter reference differs from this actual invocation") }
    let frozen = objectValue([ValueField("executable", request.field("executable").getOrThrow()),
        ValueField("arguments", request.field("arguments").getOrThrow()),
        ValueField("timeout_ms", request.field("timeout_ms").getOrThrow()), ValueField("input", input)])
    let validation = match (configuration) { case None => hostValidatePluginProcessArguments(frozen)
        case Some(value) => hostValidateReadViewProcessRequest(value, tool, frozen) }
    match (validation) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    Result.Ok(frozen)
}

func hostPrepareReferencedReadViewInvocation(host: HostJavaScriptPluginHost, descriptor: PluginPackageDescriptor,
    configuration: HostPluginHttpConfiguration, namespace: String, tool: String, generation: UInt64,
    context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
    let payload = configuration.toolPayloadLimits(tool)
    let extent = try { logicalJsonWriteReservationBytes(call.arguments, HOST_READ_VIEW_INPUT_BYTES) }
        catch (_: Exception) { return hostPluginResourceError("read_view.parameter_input_limit", "original input exceeds its existing bounded shape") }
    // This is the existing native shared pool; no uncharged body or descriptor
    // survives its owner. Its existing aggregate limit is unchanged.
    let charge = try { reserveNativeDocumentPayload(extent + 65536) }
        catch (_: Exception) { return hostPluginResourceError("read_view.parameter_capacity", "shared input allocation is unavailable") }
    try {
        let baseBinding = objectValue([ValueField("thread_id", textValue(context.sessionId.value)),
            ValueField("run_id", textValue(context.runId.value)), ValueField("epoch", integerValue(context.epoch)),
            ValueField("call_id", textValue(call.callId)), ValueField("tool_name", textValue(call.name)),
            ValueField("plugin", textValue(namespace)), ValueField("contribution", textValue(tool)),
            ValueField("package_digest", textValue(descriptor.contentDigest)), ValueField("generation", textValue(generation.toString())),
            ValueField("configuration_digest", textValue(configuration.digest))])
        let binding = match (hostReadViewContextBinding(host, configuration, tool, context, baseBinding)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let reference = hostReadViewParameterReference(binding, call.arguments)
        let arguments = objectValue([ValueField("schema", textValue(READ_VIEW_PARAMETER_SCHEMA)), ValueField("reference", reference)])
        let encoded = stringifyUnifiedJson(arguments)
        if (encoded.size > READ_VIEW_PARAMETER_METADATA_BYTES) {
            return hostPluginResourceError("read_view.parameter_metadata_limit", "metadata exceeds the original prepare input limit") }
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let identity = JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
            epoch: context.epoch, operationId: "", callId: call.callId, kind: "prepare")
        let result = match (host.invoke(namespace, tool, encoded, identity: identity,
            cancellation: context.cancellation, processLimits: context.budget.processLimits, timeoutMillis: 5000,
            expectedInstanceGeneration: generation, authorityScope: "pure-read-view:" + configuration.digest, toolPayloadLimits: payload)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (result.isError || !httpIntentExactFields(result.value, ["intents"])) {
            return hostPluginResourceError("read_view.prepare_rejected", "native package did not return pure read-view intents") }
        let proposed = result.value.field("intents").getOrThrow()
        if (proposed.unifiedKind != ValueKind.List || proposed.items.size != 1) {
            return hostPluginResourceError("read_view.prepare_rejected", "read-view preparation requires exactly one worker intent") }
        let intent = proposed.items[0]
        if (!httpIntentExactFields(intent, ["id", "request", "resources"]) || !httpIntentIdentifier(httpIntentText(intent, "id"))) {
            return hostPluginResourceError("read_view.prepare_rejected", "read-view preparation has invalid fields") }
        let request = match (hostReadViewReferencedRequest(binding, call.arguments, reference, intent.field("request").getOrThrow(), configuration: Some(configuration), tool: tool)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let collector = HostReadViewCollector(context, host)
        let resources = match (collector.collect(intent.field("resources").getOrThrow())) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let plain = objectValue([ValueField("id", intent.field("id").getOrThrow()), ValueField("request", request),
            ValueField("resources", resources), ValueField("requires_approval", boolValue(collector.requiresApproval))])
        let frozen = match (hostFreezeReadViewDeadline(host, configuration, namespace, tool, generation, plain)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (validateReadViewIntent(frozen)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        return Result.Ok(objectValue([ValueField("input", call.arguments), ValueField("host_plan", objectValue([
            ValueField("version", textValue(HOST_READ_VIEW_VERSION)), ValueField("plugin", textValue(namespace)),
            ValueField("package_digest", textValue(descriptor.contentDigest)), ValueField("generation", textValue(generation.toString())),
            ValueField("configuration_digest", textValue(configuration.digest)), ValueField("contribution", textValue(tool)),
            ValueField("read_granted", boolValue(configuration.ordinaryReadTools.contains(tool))),
            ValueField("tool_payload_limits", match (payload) { case Some(value) => value.value(); case None => nullValue() }),
            ValueField("intents", listValue([frozen]))]))]))
    } catch (_: Exception) {
        return hostPluginResourceError("read_view.parameter_input_invalid", "parameter metadata cannot represent the complete bounded original input")
    } finally { charge.close() }
}
