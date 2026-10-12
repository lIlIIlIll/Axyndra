package agent_product

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

let OBSERVED_CONTEXT_RESOURCE_PREFIX = "context-observation:"
let CONTEXT_RESOURCE_TOOL = "read_context_resource"

func observedContextResourceLocators(binding: ProductPluginContentBinding,
    facts: Array<ContextReadFact>): Result<HashMap<String, String>> {
    let result = HashMap<String, String>()
    for (fact in facts) {
        if (fact.origin.ownerNamespace != binding.namespace || fact.origin.packageDigest != binding.digest ||
            fact.origin.parentCallItemId != "") { return pluginProcessError("context.reference_fact_invalid", "references require the host context-selection facts") }
        let digest = modelPolicySha256Text(canonicalAgentValue(fact.reference()))
        // Decode each canonical output once, not once per declared reference.
        let output = fact.output()
        for (resource in output.field("resources").getOrThrow().items where httpIntentText(resource, "kind") == "metadata") {
            for (entry in resource.field("entries").getOrThrow().items) {
                let path = httpIntentText(resource, "path") + "/" + httpIntentText(entry, "name")
                if (!readViewRelativePath(path) || result.contains(path)) {
                    return pluginProcessError("context.reference_ambiguous", "reference must identify exactly one observed file") }
                result[path] = OBSERVED_CONTEXT_RESOURCE_PREFIX + stringifyUnifiedJson(objectValue([
                    ValueField("schema", textValue("axyndra.context-observed-reference/v1")), ValueField("path", textValue(path)),
                    ValueField("operation_id", textValue(fact.operationId.value)), ValueField("run_id", textValue(fact.runId.value)),
                    ValueField("fact_digest", textValue(digest))]))
            }
        }
    }
    Result.Ok(result)
}

class ObservedContextResource {
    let fact: ContextReadFact
    let source: String
    let path: String
    init(fact: ContextReadFact, source: String, path: String) { this.fact = fact; this.source = source; this.path = path }
}

// A locator cannot mint a fact. Reload the canonical Item/Operation/Receipt and
// compare its entire link before resolving a name from its bounded metadata.
func loadObservedContextResource(operations: OperationRuntimePort, locator: String): Result<ObservedContextResource> {
    try {
        if (!locator.startsWith(OBSERVED_CONTEXT_RESOURCE_PREFIX)) { return pluginProcessError("context.reference_kind", "reference does not describe observed metadata") }
        let value = parseUnifiedJson(locator[OBSERVED_CONTEXT_RESOURCE_PREFIX.size..], maxBytes: 16384)
        if (!httpIntentExactFields(value, ["schema", "path", "operation_id", "run_id", "fact_digest"]) ||
            httpIntentText(value, "schema") != "axyndra.context-observed-reference/v1" || !readViewRelativePath(httpIntentText(value, "path"))) {
            return pluginProcessError("context.reference_invalid", "stored reference has an invalid shape") }
        let operationId = httpIntentText(value, "operation_id"); let runId = httpIntentText(value, "run_id")
        if (operationId == "" || operationId.size > 512 || runId == "" || runId.size > 512 ||
            !contextReferenceDigest(httpIntentText(value, "fact_digest"))) {
            return pluginProcessError("context.reference_invalid", "stored fact identity is invalid") }
        let fact = match (operations.loadContextReadFact(OperationId(operationId), RunId(runId))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (modelPolicySha256Text(canonicalAgentValue(fact.reference())) != httpIntentText(value, "fact_digest") || fact.origin.parentCallItemId != "") {
            return pluginProcessError("context.reference_fact_changed", "reference metadata no longer matches its canonical records") }
        let path = httpIntentText(value, "path")
        var source = ""
        for (resource in fact.output().field("resources").getOrThrow().items where httpIntentText(resource, "kind") == "metadata") {
            for (entry in resource.field("entries").getOrThrow().items where httpIntentText(resource, "path") + "/" + httpIntentText(entry, "name") == path) {
                if (source != "") { return pluginProcessError("context.reference_ambiguous", "reference is repeated in canonical metadata") }
                source = Path(httpIntentText(resource, "source")).join(httpIntentText(entry, "name")).toString()
            }
        }
        if (source == "") { return pluginProcessError("context.reference_unobserved", "reference was not declared by canonical metadata") }
        Result.Ok(ObservedContextResource(fact, source, path))
    } catch (_: Exception) { pluginProcessError("context.reference_invalid", "stored reference could not be validated") }
}

func selectedContextResource(context: ToolInvocationContext, input: AgentValue): Result<ContextResourceReference> {
    let business = contextReadBusinessInput(input)
    if (!httpIntentExactFields(business, ["owner", "contribution", "reference"])) {
        return pluginProcessError("context.reference_arguments", "reference calls accept only their declared identities") }
    let contribution = match (context.contextProjection.contribution(httpIntentText(business, "owner"), httpIntentText(business, "contribution"))) {
        case Some(value) => value; case None => return pluginProcessError("context.reference_inactive", "contribution is not active in this Run") }
    match (contribution.reference(httpIntentText(business, "reference"))) {
        case Some(value) => Result.Ok(value); case None => pluginProcessError("context.reference_missing", "reference is not declared by the active contribution") }
}

class ProductContextResourceTool <: ToolExecutor {
    private let host: ProductJavaScriptPluginHost
    private let operations: OperationRuntimePort
    init(host: ProductJavaScriptPluginHost, operations: OperationRuntimePort) { this.host = host; this.operations = operations }

    func preparation(context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        if (call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) { return pluginProcessError("context.read_input_unattested", "caller cannot provide a read fact envelope") }
        let selected = match (selectedContextResource(context, call.arguments)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (selected.content.isSome() || !selected.locator.startsWith(OBSERVED_CONTEXT_RESOURCE_PREFIX)) { return Result.Ok(Option<ToolPreparationRead>.None) }
        let observed = match (loadObservedContextResource(operations, selected.locator)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let original = stringifyUnifiedJson(call.arguments); let projection = contextReadProjectionDigest(context.contextProjection)
        let runId = context.runId.value; let threadId = context.sessionId.value; let epoch = context.epoch
        let configuration = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("locator", textValue(selected.locator)), ValueField("input", call.arguments), ValueField("projection", textValue(projection))])))
        let binding = objectValue([ValueField("schema", textValue("axyndra.context-reference-read/v1")),
            ValueField("thread_id", textValue(threadId)), ValueField("run_id", textValue(runId)), ValueField("epoch", integerValue(epoch)),
            ValueField("projection_digest", textValue(projection)), ValueField("configuration_digest", textValue(configuration))])
        let exactBinding = canonicalAgentValue(binding)
        Result.Ok(Some(ToolPreparationRead(observed.fact.origin.ownerNamespace, observed.fact.origin.packageDigest, configuration,
            objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)), ValueField("binding", binding),
                ValueField("resources", listValue([objectValue([ValueField("source", textValue(observed.source)),
                    ValueField("path", textValue(observed.path)), ValueField("mode", textValue("bounded_file")), ValueField("max_bytes", integerValue(65536))])]))]),
            { actual, facts =>
                if (actual.runId.value != runId || actual.epoch != epoch || facts.size != 1 ||
                    facts[0].origin.configurationDigest != configuration || facts[0].origin.parentCallItemId == "") {
                    return pluginProcessError<AgentValue>("context.reference_fact_changed", "reference continuation lost its actual parent read") }
                let input = parseUnifiedJson(original)
                input.put(CONTEXT_READ_INPUT_FIELD, objectValue([ValueField("schema", textValue("axyndra.context-read-input/v1")),
                    ValueField("data", facts[0].output()), ValueField("facts", contextReadFactLinksValue([facts[0].link()]))]))
                Result.Ok(input)
            }, boundary: Some({ actual, arguments =>
                if (actual.sessionId.value != threadId || actual.runId.value != runId || actual.epoch != epoch ||
                    contextReadProjectionDigest(actual.contextProjection) != projection ||
                    canonicalAgentValue(arguments.field("binding") ?? nullValue()) != exactBinding) {
                    return pluginProcessError<Unit>("context.reference_scope_changed", "reference read lost its frozen Run context") }
                let current = match (selectedContextResource(actual, parseUnifiedJson(original))) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (current.locator != selected.locator) { return pluginProcessError<Unit>("context.reference_changed", "reference locator changed") }
                match (loadObservedContextResource(operations, selected.locator)) {
                    case Result.Ok(value) => if (value.source == observed.source) { readViewCancellation(actual) }
                        else { pluginProcessError<Unit>("context.reference_changed", "reference source changed") }
                    case Result.Err(error) => Result.Err(error) }
            }))))
    }

    func canonicalize(context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        let selected = match (selectedContextResource(context, call.arguments)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (selected.content.isSome() || !selected.locator.startsWith(OBSERVED_CONTEXT_RESOURCE_PREFIX)) {
            if (call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) { return pluginProcessError("context.reference_input_invalid", "pure resource does not consume host file facts") }
            return Result.Ok(call.arguments)
        }
        let observed = match (loadObservedContextResource(operations, selected.locator)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let envelope = match (call.arguments.field(CONTEXT_READ_INPUT_FIELD)) { case Some(value) => value
            case None => return pluginProcessError("context.reference_read_required", "reference body requires the existing canonical read continuation") }
        let data = envelope.field("data") ?? nullValue(); let values = data.field("resources") ?? nullValue()
        if (httpIntentText(data, "schema") != "axyndra.context-read-result/v1" || values.unifiedKind != ValueKind.List || values.items.size != 1 ||
            httpIntentText(values.items[0], "kind") != "file" || httpIntentText(values.items[0], "source") != observed.source ||
            httpIntentText(values.items[0], "path") != observed.path) {
            return pluginProcessError("context.reference_read_mismatch", "reference body does not match the host-resolved declaration") }
        // ToolPipeline/Store validate the exact fact envelope against the
        // sealed original parent. This value is not a proof by itself.
        Result.Ok(call.arguments)
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let call = ToolCall(prepared.call.callId, prepared.call.name, prepared.operationPlan.canonicalArguments)
        match (canonicalize(context, call)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let input = call.arguments
        let selected = match (selectedContextResource(context, input)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let content = if (selected.content.isNone() && selected.locator.startsWith(OBSERVED_CONTEXT_RESOURCE_PREFIX)) {
            httpIntentText(input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow().field("resources").getOrThrow().items[0], "text")
        } else {
            match (readProductPluginContextResource(host, context.contextProjection, httpIntentText(input, "owner"),
                httpIntentText(input, "contribution"), httpIntentText(input, "reference"), ThreadId(context.sessionId.value), context.cancellation, prepared.call.callId)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        }
        Result.Ok(ToolResult(prepared.call.callId, objectValue([ValueField("content", textValue(content)),
            ValueField("owner", input.field("owner").getOrThrow()), ValueField("contribution", input.field("contribution").getOrThrow()),
            ValueField("reference", input.field("reference").getOrThrow())])))
    }
}

func registerProductContextResourceTool(catalog: ToolCatalog, host: ProductJavaScriptPluginHost, operations: OperationRuntimePort): Result<Unit> {
    let executor = ProductContextResourceTool(host, operations)
    catalog.register(ToolDescriptor(ModelToolDefinition(CONTEXT_RESOURCE_TOOL,
        "Read one declared reference from a context contribution active in this Run. File content crosses the normal read policy and canonical receipt boundary.",
        objectSchema([schemaProperty("owner", "string"), schemaProperty("contribution", "string"), schemaProperty("reference", "string")], ["owner", "contribution", "reference"])),
        Capability(CapabilityKind.WorkspaceRead), neverReplay: true,
        implementationVersion: "product-context-resource-v1", implementationFingerprint: "product-context-resource-v1",
        canonicalArgumentsResolver: Some({ context, call => executor.canonicalize(context, call) }),
        preparationReadResolver: Some({ context, call => executor.preparation(context, call) }),
        networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })), executor)
}

func contextReferenceDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) { if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false } }
    true
}
