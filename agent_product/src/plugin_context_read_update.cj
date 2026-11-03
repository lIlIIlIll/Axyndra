package agent_product

import agent_plugin_registry.*

import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

class ProductContextProviderRead {
    let read: ToolPreparationRead
    let validity: () -> Result<Unit>
    init(read: ToolPreparationRead, validity: () -> Result<Unit>) { this.read = read; this.validity = validity }
}

func productContextProviderRead(host: ProductJavaScriptPluginHost, namespace: String, provider: String,
    before: ActiveRunSnapshot, resources: AgentValue, query: AgentValue, cancellation: CancellationToken,
    selectedIds: Array<String>, invocationId: String,
    sourceDigest!: String = "", sourceValidity!: () -> Result<Unit> = { => Result.Ok(()) }): Result<ProductContextProviderRead> {
    let binding = match (host.contentProviderBinding(namespace, provider, false)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    let frozenQuery = try { FrozenPluginContentQuery(query, selectedIds) } catch (_: Exception) {
        return pluginProcessError("context.read_query_invalid", "content query must be bounded immutable data") }
    if (frozenQuery.query.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
        return pluginProcessError("context.read_query_invalid", "caller cannot supply the reserved observed-resource field") }
    let frozenResources = try { parseUnifiedJson(stringifyUnifiedJson(resources), maxBytes: 65536) }
        catch (_: Exception) { return pluginProcessError("context.read_request_invalid", "resource requests exceed the bounded metadata shape") }
    let configurationFields = ArrayList<ValueField>([
        ValueField("query", frozenQuery.query), ValueField("resources", frozenResources),
        ValueField("selected", listValue(frozenQuery.selectedIds.map { value => textValue(value) }))])
    if (sourceDigest != "") { configurationFields.add(ValueField("source_digest", textValue(sourceDigest))) }
    let configuration = modelPolicySha256Text(canonicalAgentValue(objectValue(configurationFields.toArray())))
    let expectedProjection = contextReadProjectionDigest(before.contextSnapshot)
    let identity = objectValue([ValueField("schema", textValue("axyndra.context-provider-read/v1")),
        ValueField("plugin", textValue(namespace)), ValueField("provider", textValue(provider)),
        ValueField("package_digest", textValue(binding.digest)), ValueField("generation", textValue(binding.generation.toString())),
        ValueField("thread_id", textValue(before.threadId.value)), ValueField("run_id", textValue(before.runId.value)),
        ValueField("epoch", integerValue(before.epoch)), ValueField("projection_digest", textValue(expectedProjection)),
        ValueField("configuration_digest", textValue(configuration))])
    let identityDigest = canonicalAgentValue(identity)
    let valid = { =>
        match (sourceValidity()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        if (cancellation.isCancelled()) { return pluginProcessError<Unit>("context.update_source_stale", "context selection was withdrawn") }
        match (host.servicePackage(namespace, binding.generation)) {
            case Result.Err(_) => pluginProcessError<Unit>("context.update_source_stale", "content provider was revoked or replaced")
            case Result.Ok(value) => if (value.textEquals(PluginDescriptorText.ContentDigest, binding.digest)) { Result.Ok(()) }
                else { pluginProcessError<Unit>("context.update_source_stale", "content provider package changed") }
        }
    }
    let read = ToolPreparationRead(namespace, binding.digest, configuration,
        objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)),
            ValueField("binding", identity), ValueField("resources", frozenResources)]),
        { context, facts =>
            match (valid()) { case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(_) => () }
            if (facts.size != 1 || facts[0].runId.value != before.runId.value ||
                facts[0].origin.parentCallItemId != "" || facts[0].origin.ownerNamespace != namespace ||
                facts[0].origin.packageDigest != binding.digest || facts[0].origin.configurationDigest != configuration ||
                facts[0].origin.projectionDigest != expectedProjection) {
                return pluginProcessError<AgentValue>("context.read_fact_invalid", "content query requires its exact canonical resource fact") }
            let fields = ArrayList<ValueField>()
            for (field in frozenQuery.query.fields) { fields.add(field) }
            fields.add(ValueField(CONTEXT_READ_INPUT_FIELD, objectValue([
                ValueField("schema", textValue("axyndra.context-read-input/v1")),
                ValueField("data", facts[0].output()), ValueField("facts", contextReadFactLinksValue([facts[0].link()]))])))
            let selected = match (resolveObservedProductPluginContext(host, namespace, provider, objectValue(fields.toArray()),
                before.threadId, frozenQuery.selectedIds, context.cancellation, invocationId)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result<AgentValue>.Err(error) }
            match (valid()) { case Result.Err(error) => return Result<AgentValue>.Err(error); case Result.Ok(_) => () }
            let owner = namespace + "/context/" + provider
            let items = ArrayList<InvocationContextContribution>()
            for (item in before.contextSnapshot.contributions() where item.owner != owner) { items.add(item) }
            for (item in selected.contributions()) {
                if (item.owner != owner) { return pluginProcessError<AgentValue>("context.update_owner_invalid", "provider returned a foreign content owner") }
                items.add(item)
            }
            let data = InvocationContextProjection(contributions: items.toArray())
            Result.Ok(contextSnapshotValue(InvocationContextProjection(contributions: items.toArray(), sourceDigest:
                modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("context", contextSnapshotValue(data)),
                    ValueField("facts", contextReadFactLinksValue([facts[0].link()]))]))))))
        }, boundary: Some({ context, arguments =>
            if (context.sessionId.value != before.threadId.value || context.runId.value != before.runId.value || context.epoch != before.epoch ||
                contextReadProjectionDigest(context.contextProjection) != expectedProjection ||
                canonicalAgentValue(arguments.field("binding") ?? nullValue()) != identityDigest) {
                return pluginProcessError<Unit>("context.read_binding_invalid", "resource preparation lost its actual host binding") }
            valid()
        }))
    Result.Ok(ProductContextProviderRead(read, valid))
}
