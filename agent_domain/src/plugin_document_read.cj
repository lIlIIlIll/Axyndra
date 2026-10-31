package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

public let PLUGIN_DOCUMENT_READ_SCHEMA = "axyndra.plugin-document-read/v1"
public let PLUGIN_DOCUMENT_READ_RESULT_SCHEMA = "axyndra.plugin-document-read-result/v1"

// Optional data from the Host's original canonical accounting implementation.
// It is frozen into the whole ContextRead output digest, never an allowance.
public func pluginDocumentObservationValid(value: AgentValue, request: AgentValue): Bool {
    try {
        if (!httpIntentExactFields(value, ["schema", "thread_id", "run_id", "observed_at_millis", "input_tokens", "output_tokens"]) ||
            httpIntentText(value, "schema") != "axyndra.document-observation/v1") { return false }
        let binding = request.field("binding").getOrThrow()
        if (httpIntentText(value, "thread_id") != httpIntentText(binding, "thread_id") ||
            httpIntentText(value, "run_id") != httpIntentText(binding, "run_id")) { return false }
        let now = documentContractInteger(value.field("observed_at_millis").getOrThrow())
        let input = documentContractInteger(value.field("input_tokens").getOrThrow())
        let output = documentContractInteger(value.field("output_tokens").getOrThrow())
        now >= 0 && input >= 0 && output >= 0 && input <= 9223372036854775807 - output &&
            stringifyUnifiedJson(value).size <= 4096
    } catch (_: Exception) { false }
}

// A request for one canonical ContextRead. It contains logical addresses, not
// document contents, paths, a repository handle, or authority from the worker.
public func pluginDocumentReadRequestValid(value: AgentValue): Bool {
    if(httpIntentText(value,"schema")==PLUGIN_DOCUMENT_CONTEXT_READ_SCHEMA){return pluginDocumentContextReadRequestValid(value)}
    try {
        if (!httpIntentExactFields(value, ["schema", "binding", "projection_digest", "keys"]) ||
            !([PLUGIN_DOCUMENT_READ_SCHEMA, PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA].contains(httpIntentText(value, "schema"))) ||
            !httpIntentDigest(httpIntentText(value, "projection_digest")) ||
            validatePluginDocumentBinding(value.field("binding").getOrThrow()).isError()) { return false }
        let keys = value.field("keys").getOrThrow()
        if (keys.unifiedKind != ValueKind.List || keys.items.isEmpty() || keys.items.size > 8) { return false }
        let seen = HashSet<String>()
        for (key in keys.items) {
            if (key.unifiedKind != ValueKind.Text || !documentContractIdentifier(key.text) || seen.contains(key.text)) { return false }
            seen.add(key.text)
        }
        stringifyUnifiedJson(value).size <= 16384
    } catch (_: Exception) { false }
}

public func pluginDocumentReadAuthority(plan: NormalizedOperationPlan): Bool {
    if (!pluginDocumentReadRequestValid(plan.canonicalArguments) || plan.requiredCapabilities.size != 1 ||
        !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty()) { return false }
    let binding = plan.canonicalArguments.field("binding").getOrThrow()
    plan.requiredCapabilities[0].kind == CapabilityKind.ExtensionInvoke &&
        plan.requiredCapabilities[0].resource == httpIntentText(binding, "namespace")
}

public func pluginDocumentReadResultValid(value: AgentValue, request: AgentValue): Bool {
    try {
        if (!pluginDocumentReadRequestValid(request) ||
            !(if (value.field("observation").isSome()) {
                httpIntentExactFields(value, ["schema", "request_digest", "documents", "observation"]) &&
                    pluginDocumentObservationValid(value.field("observation").getOrThrow(), request)
            } else { httpIntentExactFields(value, ["schema", "request_digest", "documents"]) }) ||
            httpIntentText(value, "schema") != (if (httpIntentText(request, "schema") == PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA) {
                PLUGIN_DOCUMENT_PAYLOAD_READ_RESULT_SCHEMA } else { PLUGIN_DOCUMENT_READ_RESULT_SCHEMA }) ||
            httpIntentText(value, "request_digest") != modelPolicySha256Text(canonicalAgentValue(request))) { return false }
        let documents = value.field("documents").getOrThrow()
        let keys = request.field("keys").getOrThrow()
        if (documents.unifiedKind != ValueKind.List || documents.items.size != keys.items.size) { return false }
        for (index in 0..keys.items.size) {
            let item = documents.items[index]
            if (httpIntentText(request, "schema") == PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA) {
                if (!pluginDocumentPayloadSnapshotValid(item, keys.items[index].text)) { return false }; continue }
            if (!httpIntentExactFields(item, ["key", "revision", "json", "sha256"]) ||
                httpIntentText(item, "key") != keys.items[index].text ||
                item.field("json").getOrThrow().unifiedKind != ValueKind.Text) { return false }
            let raw = httpIntentText(item, "json")
            let revision = documentContractInteger(item.field("revision").getOrThrow())
            if (revision < 0 || (revision == 0 && raw != "null") || raw.size > PLUGIN_DOCUMENT_MAX_BYTES ||
                httpIntentText(item, "sha256") != modelPolicySha256Text(raw)) { return false }
        }
        true
    } catch (_: Exception) { false }
}
