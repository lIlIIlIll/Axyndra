package agent_product

import agent_domain.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Pure, current installed-policy data. The actual prepared operation, Thread
// read, Receipt commit and context cut remain in their existing kernel paths.
// This bridge never admits a plan or treats a returned ordinal as a Source.
public type ProductCheckpointExecutionPolicy = (ToolInvocationContext, ToolCall,
    () -> Result<AgentThreadSnapshot>, () -> String) -> Result<ToolResult>

func checkpointPolicyReferenceEvent113(query: ProductCompactionReferenceQuery,
    thread: AgentThreadSnapshot, item: ThreadItem): AgentValue {
    var kind = "other"; var name = ""; var callId = ""; var failed = false
    match (item.content) {
        case ThreadItemContent.ToolCall(value, actualName, _) =>
            kind = "call"; name = actualName; callId = value.value
        case ThreadItemContent.ToolResult(value, _, _, _, isError) =>
            kind = "result"; callId = value.value; failed = isError
            // This is generic canonical call/result correlation, including
            // the original first matching call and absent-call empty name.
            for (candidate in thread.items) {
                match (candidate.content) {
                    case ThreadItemContent.ToolCall(actualCall, actualName, _) =>
                        if (actualCall.value == callId) { name = actualName; break }
                    case _ => ()
                }
            }
        case _ => ()
    }
    objectValue([ValueField("kind", textValue(kind)), ValueField("ordinal", integerValue(item.ordinal)),
        ValueField("name", if (kind == "other") { nullValue() } else { query.references.intern(name) }),
        ValueField("call_id", if (kind == "other") { nullValue() } else { query.references.intern(callId) }),
        ValueField("is_error", boolValue(failed))])
}

func checkpointPolicyTrimReference113(query: ProductCompactionReferenceQuery, source: AgentValue,
    phase173!: String = "checkpoint_trim"): AgentValue {
    let text = query.references.value(source)
    var offset: Int64 = 0; var carry = nullValue(); var previous: ?AgentValue = None<AgentValue>
    while (true) {
        query.check()
        let chunk = query.references.chunk(source, offset)
        let result = query.query(phase173, [ValueField("source", source),
            ValueField("offset", integerValue(offset)), ValueField("text", textValue(chunk)), ValueField("carry", carry)])
        match (previous) { case Some(value) => query.release(value); case None => () }
        if (!httpIntentExactFields(result, ["source", "next_offset", "complete", "carry", "range"]) ||
            canonicalAgentValue(result.field("source").getOrThrow()) != canonicalAgentValue(source) ||
            result.field("complete").getOrThrow().unifiedKind != ValueKind.Boolean) {
            throw IllegalStateException("checkpoint reference trim coverage is invalid") }
        let next = compactionPageInteger(result, "next_offset")
        if (next != offset + chunk.size || next > text.size || (next == offset && text.size != 0)) {
            throw IllegalStateException("checkpoint reference trim did not consume the actual fragment") }
        previous = Some(result); carry = result.field("carry").getOrThrow(); offset = next
        if (result.field("complete").getOrThrow().asBool()) {
            if (offset != text.size) { throw IllegalStateException("checkpoint reference trim ended before EOF") }
            let range = result.field("range").getOrThrow()
            if (!httpIntentExactFields(range, ["source", "offset", "bytes"]) ||
                canonicalAgentValue(range.field("source").getOrThrow()) != canonicalAgentValue(source)) {
                throw IllegalStateException("checkpoint reference trim changed the actual source") }
            // The ordinary reference resolver checks every actual UTF8 range;
            // it does not choose or alter the provider's trimming rule.
            let _ = query.references.slice(source, compactionPageInteger(range, "offset"), compactionPageInteger(range, "bytes"))
            query.check(); return query.copy(range)
        }
    }
    throw IllegalStateException("checkpoint reference trim has no terminal range")
}

// A closed error wire decoder. Provider classification is preserved, but no
// response-backed String/JsonNode escapes its paid query. The original error
// values are static codec atoms; this function never examines Thread state or
// decides whether a checkpoint/rewind is legal.
func checkpointPolicyClosedError113(value: AgentValue): ?AgentError {
    if (!httpIntentExactFields(value, ["error"])) { return None<AgentError> }
    let wire = value.field("error").getOrThrow()
    let variants = ArrayList<AgentError>()
    for (tool in ["checkpoint", "rewind"]) {
        let argument = if (tool == "checkpoint") { "goal" } else { "report" }
        for (message in ["required argument is missing", "argument must be a string",
            if (tool == "checkpoint") { "investigation goal must not be empty" } else { "Report cannot be empty." }]) {
            variants.add(AgentError(AgentErrorKind.InvalidInput, "tool.invalid_argument", message,
                fields: [ErrorField("tool", tool), ErrorField("argument", argument)]))
        }
    }
    variants.add(AgentError(AgentErrorKind.Conflict, "tool.checkpoint_active", "Checkpoint already active."))
    variants.add(AgentError(AgentErrorKind.Conflict, "tool.checkpoint_completed",
        "Checkpoint already completed; continue from the retained rewind report instead of calling rewind again."))
    variants.add(AgentError(AgentErrorKind.Conflict, "tool.checkpoint_missing", "No active checkpoint. Create a checkpoint before calling rewind."))
    for (error in variants) {
        let fields = ArrayList<AgentValue>()
        for (field in error.fields) { fields.add(objectValue([ValueField("name", textValue(field.name)), ValueField("value", textValue(field.value))])) }
        let template = objectValue([ValueField("kind", textValue(if (error.kind == AgentErrorKind.InvalidInput) { "invalid_input" } else { "conflict" })),
            ValueField("code", textValue(error.code)), ValueField("message", textValue(error.message)), ValueField("fields", listValue(fields.toArray()))])
        if (canonicalAgentValue(wire) == canonicalAgentValue(template)) { return Some(error) }
    }
    throw IllegalStateException("checkpoint policy returned an error outside its original closed codec")
}

func checkpointPolicyMaterialize113(query: ProductCompactionReferenceQuery, value: AgentValue): AgentValue {
    if (!httpIntentExactFields(value, ["fields"])) { throw IllegalStateException("checkpoint policy result shape is invalid") }
    let fields = value.field("fields").getOrThrow()
    if (fields.unifiedKind != ValueKind.List || fields.items.size > 32) { throw IllegalStateException("checkpoint policy field metadata is invalid") }
    let result = ArrayList<ValueField>(); let seen = HashSet<String>()
    for (field in fields.items) {
        let name = httpIntentText(field, "name"); let kind = httpIntentText(field, "kind")
        if (name == "" || name.size > 128 || seen.contains(name)) { throw IllegalStateException("checkpoint policy field names are ambiguous") }
        seen.add(name)
        if (kind == "text" && httpIntentExactFields(field, ["name", "kind", "recipe"])) {
            result.add(ValueField(name, textValue(query.references.compose(field.field("recipe").getOrThrow(), 8388608))))
        } else if (kind == "boolean" && httpIntentExactFields(field, ["name", "kind", "value"]) &&
            field.field("value").getOrThrow().unifiedKind == ValueKind.Boolean) {
            result.add(ValueField(name, boolValue(field.field("value").getOrThrow().asBool())))
        } else if (kind == "data" && httpIntentExactFields(field, ["name", "kind", "value"])) {
            // Original selected-provider data is copied under the real query
            // reservation; it is never interpreted as a Source or cut proof.
            result.add(ValueField(name, query.copy(field.field("value").getOrThrow())))
        } else { throw IllegalStateException("checkpoint policy returned an unsupported neutral data recipe") }
    }
    objectValue(result.toArray())
}

func queryProductCheckpointPolicy113(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
    binding: ProductPluginPolicyBinding, context: ToolInvocationContext, call: ToolCall,
    loadThread: () -> Result<AgentThreadSnapshot>, timestamp: () -> String, requestId: String, cancellation: CancellationToken): Result<ToolResult> {
    let query = try { ProductCompactionReferenceQuery(host, selection,
        modelPolicySha256Text(requestId), ThreadId(context.sessionId.value), cancellation, requestId, binding) }
        catch (error: ProductCompactionDataError) { return Result.Err(error.error) }
    try {
        let tool = query.references.intern(call.name)
        let selected = query.query("checkpoint_select", [ValueField("tool", tool)])
        if (!httpIntentExactFields(selected, ["argument"])) { throw IllegalStateException("checkpoint policy argument selector is invalid") }
        let argument = httpIntentText(selected, "argument")
        if (argument == "" || argument.size > 128) { throw IllegalStateException("checkpoint policy argument selector is not bounded") }
        let actual = call.arguments.field(argument)
        let typed = match (actual) { case Some(value) => value.unifiedKind == ValueKind.Text; case None => false }
        let source = query.references.intern(match (actual) { case Some(value) => if (typed) { value.text } else { "" }; case None => "" })
        let range = checkpointPolicyTrimReference113(query, source)
        let validation = query.query("checkpoint_validate", [ValueField("tool", tool), ValueField("present", boolValue(actual.isSome())),
            ValueField("kind", textValue(if (typed) { "text" } else { "other" })), ValueField("source", source), ValueField("range", range)])
        match (checkpointPolicyClosedError113(validation)) { case Some(error) => return Result.Err(error); case None => () }
        if (!httpIntentExactFields(validation, ["valid"]) || validation.field("valid").getOrThrow().unifiedKind != ValueKind.Boolean ||
            !validation.field("valid").getOrThrow().asBool()) { throw IllegalStateException("checkpoint policy did not validate actual arguments") }
        // Preserve original argument-error precedence: the actual Thread read
        // occurs only after the provider's original requiredString/trim rule.
        let thread = match (loadThread()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        var state = query.query("checkpoint_begin", [ValueField("total", integerValue(thread.items.size))])
        let target = query.references.intern(call.callId)
        var offset: Int64 = 0
        while (offset < thread.items.size) {
            query.check()
            let events = ArrayList<AgentValue>()
            let end = min(thread.items.size, offset + 64)
            for (item in thread.items[offset..end]) { events.add(checkpointPolicyReferenceEvent113(query, thread, item)) }
            let batch = query.copy(listValue(events.toArray()))
            let next = try { query.query("checkpoint_latest_batch", [ValueField("state", state),
                ValueField("events", batch), ValueField("target_call", target)]) } finally { query.release(batch) }
            if (compactionPageInteger(next, "offset") != end || compactionPageInteger(next, "total") != thread.items.size) {
                throw IllegalStateException("checkpoint policy did not consume the complete actual first-pass batch") }
            query.release(state); state = next
            offset = end
        }
        let next = query.query("checkpoint_after_begin", [ValueField("state", state)])
        query.release(state); state = next
        offset = 0
        while (offset < thread.items.size) {
            query.check()
            let events = ArrayList<AgentValue>()
            let end = min(thread.items.size, offset + 64)
            for (item in thread.items[offset..end]) { events.add(checkpointPolicyReferenceEvent113(query, thread, item)) }
            let batch = query.copy(listValue(events.toArray()))
            let next = try { query.query("checkpoint_after_batch", [ValueField("state", state),
                ValueField("events", batch)]) } finally { query.release(batch) }
            if (compactionPageInteger(next, "offset") != end || compactionPageInteger(next, "total") != thread.items.size) {
                throw IllegalStateException("checkpoint policy did not consume the complete actual second-pass batch") }
            query.release(state); state = next
            offset = end
        }
        let admissible = query.query("checkpoint_check", [ValueField("tool", tool), ValueField("state", state)])
        match (checkpointPolicyClosedError113(admissible)) { case Some(error) => return Result.Err(error); case None => () }
        if (!httpIntentExactFields(admissible, ["valid"]) || admissible.field("valid").getOrThrow().unifiedKind != ValueKind.Boolean ||
            !admissible.field("valid").getOrThrow().asBool()) { throw IllegalStateException("checkpoint policy state check is invalid") }
        let clock = query.references.intern(timestamp())
        let proposal = query.query("checkpoint_result", [ValueField("tool", tool), ValueField("state", state),
            ValueField("source", source), ValueField("range", range), ValueField("timestamp", clock)])
        match (checkpointPolicyClosedError113(proposal)) { case Some(error) => return Result.Err(error); case None => () }
        let output = checkpointPolicyMaterialize113(query, proposal)
        query.check()
        let retained = retainProductPolicyData(output)
        try {
            query.check()
            Result.Ok(ToolResult(call.callId, retained.value,
                payloadLease: Some(ToolResultPayloadLease({ => retained.close() }))))
        } catch (error: Exception) { retained.close(); throw error }
    } catch (error: ProductCompactionDataError) { Result.Err(error.error) }
    catch (_: Exception) { productPolicySelectionError("checkpoint.policy_data_invalid") }
    finally { query.close() }
}
