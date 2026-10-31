package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.{reserveNativeContentJson}
import agent_extension_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Discovery identity only; invoke rechecks the enabled generation before and
// after the pure query. Provider output never chooses its owner or trust level.
type ProductPluginContentBinding = HostPluginContentBinding

class ProductContentQueryResult {
    let value: AgentValue
    private let response: ProductJavaScriptPluginInvocationResult
    init(response: ProductJavaScriptPluginInvocationResult) { this.response = response; this.value = response.value }
    func close(): Unit { response.releasePayload() }
}

func contentProviderQuery(host: ProductJavaScriptPluginHost, binding: ProductPluginContentBinding,
    query: AgentValue, thread: ThreadId, cancellation: CancellationToken, requestId: String): Result<ProductContentQueryResult> {
    let source = stringifyUnifiedJson(query)
    if (source.size > CONTENT_PAYLOAD_INPUT_BYTES) { return pluginProcessError("context.query_limit", "content query exceeds its finite input bound") }
    let identity = JavaScriptHostInvocationIdentity(threadId: thread.value, runId: "", epoch: 0, operationId: "",
        callId: requestId, kind: if (binding.resource) { "resource_provider" } else { "context_provider" })
    let response = match (host.invoke(binding.namespace, binding.contribution, source, identity: identity,
        cancellation: cancellation, expectedInstanceGeneration: binding.generation,
        authorityScope: "pure-content", timeoutMillis: 5000)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(value) => value
    }
    var retained = false
    try {
        if (response.isError || stringifyUnifiedJson(response.value).size > CONTENT_PAYLOAD_RESULT_BYTES) {
            return pluginProcessError("context.query_failed", "content provider returned an error or an oversized value")
        }
        let current = match (host.contentProviderBinding(binding.namespace, binding.contribution, binding.resource)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        if (current.generation != binding.generation || current.digest != binding.digest || cancellation.isCancelled()) {
            return pluginProcessError("context.provider_changed", "content query lost its exact installed generation")
        }
        let output = ProductContentQueryResult(response)
        retained = true
        Result.Ok(output)
    } catch (_: Exception) {
        pluginProcessError("context.query_result_invalid", "content result exceeds its bounded data codec")
    } finally { if (!retained) { response.releasePayload() } }
}

func pluginContentLocator(binding: ProductPluginContentBinding, provider: String, resourceId: String): String {
    "plugin-resource:" + stringifyUnifiedJson(objectValue([
        ValueField("namespace", textValue(binding.namespace)), ValueField("package_digest", textValue(binding.digest)),
        ValueField("version", textValue(binding.version)), ValueField("provider", textValue(provider)),
        ValueField("resource_id", textValue(resourceId))]))
}

func pluginContentIdentifier(value: AgentValue, name: String): String {
    let text = httpIntentText(value, name)
    if (text.trimAscii() == "" || text.size > 128 || text.contains("\u{0000}")) {
        throw IllegalArgumentException("context.content_identity_invalid")
    }
    text
}

// Capture both inputs before package verification or process scheduling can
// yield. Caller-owned JSON and arrays must never change this query's provenance.
type FrozenPluginContentQuery = agent_host_runtime.HostFrozenPluginContentQuery

func resolveProductPluginContext(host: ProductJavaScriptPluginHost, namespace: String, provider: String,
    query: AgentValue, thread: ThreadId, selectedIds: Array<String>, cancellation: CancellationToken,
    requestId: String): Result<InvocationContextProjection> {
    let frozen = try { FrozenPluginContentQuery(query, selectedIds) }
        catch (_: Exception) { return pluginProcessError("context.query_invalid", "content query exceeds its bounded codec") }
    try { resolveFrozenProductPluginContext(host, namespace, provider, frozen, thread, cancellation, requestId) }
    finally { frozen.close() }
}

// Only the actual ContextRead consumer calls this expanded-data entry. The
// caller still supplies its same Run/epoch-validated fact, not read authority.
func resolveObservedProductPluginContext(host: ProductJavaScriptPluginHost, namespace: String, provider: String,
    query: AgentValue, thread: ThreadId, selectedIds: Array<String>, cancellation: CancellationToken,
    requestId: String, observedFacts!: Array<ContextReadFact> = []): Result<InvocationContextProjection> {
    let frozen = try { FrozenPluginContentQuery(query, selectedIds, observed: true) }
        catch (_: Exception) { return pluginProcessError("context.query_invalid", "observed content exceeds its bounded codec or aggregate capacity") }
    try { resolveFrozenProductPluginContext(host, namespace, provider, frozen, thread, cancellation, requestId, observedFacts: observedFacts) }
    finally { frozen.close() }
}

func resolveFrozenProductPluginContext(host: ProductJavaScriptPluginHost, namespace: String, provider: String,
    frozen: FrozenPluginContentQuery, thread: ThreadId, cancellation: CancellationToken,
    requestId: String, observedFacts!: Array<ContextReadFact> = []): Result<InvocationContextProjection> {
    let query = frozen.query
    let selectedIds = frozen.selectedIds
    let binding = match (host.contentProviderBinding(namespace, provider, false)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
    }
    let response = match (contentProviderQuery(host, binding, query, thread, cancellation, requestId)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(output) => output
    }
    try {
        resolveObservedProductContextValue(host, binding, query, selectedIds, cancellation,
            response.value, observedFacts)
    } finally { response.close() }
}

// Inert data validation only. The caller owns the actual query transport and
// its payload lease; this function never queries a provider or grants authority.
func resolveObservedProductContextValue(host: ProductJavaScriptPluginHost, binding: ProductPluginContentBinding,
    query: AgentValue, selectedIds: Array<String>, cancellation: CancellationToken,
    value: AgentValue, observedFacts: Array<ContextReadFact>): Result<InvocationContextProjection> {
    let namespace = binding.namespace
    let provider = binding.contribution
    try {
        if (!httpIntentExactFields(value, ["schema", "contributions"]) ||
            httpIntentText(value, "schema") != "axyndra.context-result/v1") {
            return pluginProcessError("context.result_invalid", "content result requires the exact context schema")
        }
        let rows = value.field("contributions").getOrThrow()
        if (rows.unifiedKind != ValueKind.List || rows.items.size > 128 || selectedIds.size > 128) {
            return pluginProcessError("context.result_limit", "content result exceeds its contribution bound")
        }
        let selected = HashSet<String>()
        for (id in selectedIds) {
            if (id.trimAscii() == "" || id.size > 128 || id.contains("\u{0000}") || selected.contains(id)) {
                return pluginProcessError("context.selection_invalid", "host selection contains an invalid or duplicate contribution identity")
            }
            selected.add(id)
        }
        let observedLocators = match (observedContextResourceLocators(binding, observedFacts)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let contributions = ArrayList<InvocationContextContribution>()
        for (row in rows.items) {
            if (!(httpIntentExactFields(row, ["id", "content", "references"]) ||
                httpIntentExactFields(row, ["id", "content", "references", "valid_until_millis"])) ||
                row.field("content").getOrThrow().unifiedKind != ValueKind.Text) {
                return pluginProcessError("context.result_invalid", "provider may return content and declared references only")
            }
            let validUntilMillis = contextValueValidUntilMillis(row)
            if (validUntilMillis > 0 && agentUtcMillis() >= validUntilMillis) {
                return pluginProcessError("context.contribution_expired", "content contribution expired before consumption") }
            let id = pluginContentIdentifier(row, "id")
            let refs = row.field("references").getOrThrow()
            if (refs.unifiedKind != ValueKind.List || refs.items.size > 32) {
                return pluginProcessError("context.reference_limit", "content references exceed their per-contribution bound")
            }
            let references = ArrayList<ContextResourceReference>()
            for (ref in refs.items) {
                if (httpIntentExactFields(ref, ["id", "content"])) {
                    if (ref.field("content").getOrThrow().unifiedKind != ValueKind.Text) {
                        return pluginProcessError("context.reference_invalid", "inline reference must contain only untrusted text") }
                    references.add(ContextResourceReference(pluginContentIdentifier(ref, "id"),
                        "inline-context:" + binding.digest + ":" + provider + ":" + id,
                        content: Some(ref.field("content").getOrThrow().text)))
                    continue
                }
                if (httpIntentExactFields(ref, ["id", "observed_path"])) {
                    let locator = match (observedLocators.get(httpIntentText(ref, "observed_path"))) {
                        case Some(value) => value; case None => return pluginProcessError("context.reference_unobserved", "provider cannot declare a path without canonical metadata") }
                    let referenceId = httpIntentText(ref, "id")
                    if (referenceId.trimAscii() == "" || referenceId.size > 255 || referenceId.contains("\u{0000}")) {
                        return pluginProcessError("context.reference_invalid", "observed reference identity exceeds its filesystem name bound") }
                    references.add(ContextResourceReference(referenceId, locator))
                    continue
                }
                if (!httpIntentExactFields(ref, ["id", "provider", "resource_id"])) {
                    return pluginProcessError("context.reference_invalid", "references require typed resource identities")
                }
                let resourceProvider = pluginContentIdentifier(ref, "provider")
                let declaration = match (host.contentProviderBinding(namespace, resourceProvider, true)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(current) => current
                }
                if (declaration.generation != binding.generation || declaration.digest != binding.digest) {
                    return pluginProcessError("context.provider_changed", "content and resource providers must use the same frozen package")
                }
                references.add(ContextResourceReference(pluginContentIdentifier(ref, "id"),
                    pluginContentLocator(binding, resourceProvider, pluginContentIdentifier(ref, "resource_id"))))
            }
            contributions.add(InvocationContextContribution(namespace + "/context/" + provider, id,
                "plugin-context:" + binding.digest + ":" + provider + ":" + id,
                row.field("content").getOrThrow().text,
                if (selectedIds.contains(id)) { ContextContentTrust.UserSelected } else { ContextContentTrust.UntrustedData },
                references: references.toArray(), validUntilMillis: validUntilMillis))
        }
        for (id in selectedIds) {
            var found = false
            for (entry in contributions where entry.id == id) { found = true }
            if (!found) { return pluginProcessError("context.selection_missing", "selected contribution was not returned by the frozen provider") }
        }
        let current = match (host.contentProviderBinding(namespace, provider, false)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(current) => current
        }
        if (current.generation != binding.generation || cancellation.isCancelled()) {
            return pluginProcessError("context.provider_changed", "content provider changed before snapshot publication")
        }
        match (validateContextSnapshotUse(InvocationContextProjection(contributions: contributions.toArray()))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let provenance = objectValue([ValueField("package_digest", textValue(binding.digest)),
            ValueField("namespace", textValue(namespace)), ValueField("provider", textValue(provider)),
            ValueField("selected_ids", listValue(selectedIds.map { id => textValue(id) })),
            ValueField("query", query), ValueField("result", value)])
        Result.Ok(validatedContextSnapshot(InvocationContextProjection(contributions: contributions.toArray(),
            sourceDigest: modelPolicySha256Text(canonicalAgentValue(provenance)))))
    } catch (_: Exception) { pluginProcessError("context.result_invalid", "content result is malformed or exceeds the snapshot codec") }
}

func readProductPluginContextResource(host: ProductJavaScriptPluginHost, snapshot: InvocationContextProjection,
    owner: String, contribution: String, reference: String, thread: ThreadId,
    cancellation: CancellationToken, requestId: String): Result<String> {
    let context = match (snapshot.contribution(owner, contribution)) {
        case Some(value) => value; case None => return pluginProcessError("context.reference_inactive", "resource is not declared in this frozen snapshot")
    }
    match (validateContextSnapshotUse(InvocationContextProjection(contributions: [context]))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let resource = match (context.reference(reference)) {
        case Some(value) => value; case None => return pluginProcessError("context.reference_missing", "resource is not declared by the contribution")
    }
    match (resource.content) { case Some(value) => return Result.Ok(value); case None => () }
    try {
        if (!resource.locator.startsWith("plugin-resource:")) {
            return pluginProcessError("context.reference_kind", "resource locator is not owned by a plugin provider")
        }
        let locator = parseUnifiedJson(resource.locator[16..], maxBytes: 4096)
        if (!httpIntentExactFields(locator, ["namespace", "package_digest", "version", "provider", "resource_id"])) {
            return pluginProcessError("context.reference_invalid", "stored resource locator is malformed")
        }
        let binding = match (host.contentProviderBinding(httpIntentText(locator, "namespace"), httpIntentText(locator, "provider"), true)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        if (binding.digest != httpIntentText(locator, "package_digest") || binding.version != httpIntentText(locator, "version")) {
            return pluginProcessError("context.reference_version_missing", "the frozen resource package version is not active")
        }
        let response = match (contentProviderQuery(host, binding, objectValue([
            ValueField("schema", textValue("axyndra.resource-query/v1")), ValueField("resource_id", locator.field("resource_id").getOrThrow())]),
            thread, cancellation, requestId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        try {
        let output = response.value
        if (!httpIntentExactFields(output, ["schema", "content"]) || httpIntentText(output, "schema") != "axyndra.resource-result/v1" ||
            output.field("content").getOrThrow().unifiedKind != ValueKind.Text) {
            return pluginProcessError("context.resource_invalid", "resource provider must return only bounded content")
        }
        match (validateContextSnapshotUse(InvocationContextProjection(contributions: [context]))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(output.field("content").getOrThrow().text)
        } finally { response.close() }
    } catch (_: Exception) { pluginProcessError("context.reference_invalid", "stored resource reference is invalid") }
}
