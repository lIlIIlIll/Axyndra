package pure_provider_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Opt-in Tool-only transport. A descriptor is data, never a Host grant.
// The worker cannot replace a frozen service or add its execution arguments.
// Host still resolves intent_id from the actual canonical parent and performs
// its original Source, approval, current, handoff and Receipt checks.
public class FrozenPrimitiveBroker111 {
    private let window: DocumentProtocolWindow
    private let intents: JsonNode
    private let dataOnlyCompletion152: Bool
    private let claimed = HashSet<String>()
    private var sequence: Int64 = 2
    private var failed = false

    init(window: DocumentProtocolWindow) {
        if (providerText(window.invocation, "kind") != "tool") {
            throw PureProviderError("primitive.tool_required", "only an actual Tool invocation has a primitive broker") }
        let arguments = window.invocation.field("arguments") ?? jsonNull()
        let host = arguments.field("host_plan") ?? jsonNull()
        let dataCompletion = pluginPreparedCompletionArgumentsValid152(arguments)
        let values = if (dataCompletion) { jsonArray([]) } else { host.field("intents") ?? jsonNull() }
        if (!dataCompletion) {
        if (providerText(host, "version") != "axyndra.frozen-host-primitives/v1" ||
            values.unifiedKind != UnifiedJsonKind.List || values.items.isEmpty() || values.items.size > 32) {
            throw PureProviderError("primitive.plan_invalid", "expected a bounded frozen primitive plan") }
        let ids = HashSet<String>()
        for (value in values.items) {
            if (!httpIntentExactFields(value, ["id", "service", "input"]) ||
                !httpIntentIdentifier(providerText(value, "id")) ||
                !primitiveService111(providerText(value, "service")) ||
                value.field("input").getOrThrow().unifiedKind != UnifiedJsonKind.Object ||
                ids.contains(providerText(value, "id"))) {
                throw PureProviderError("primitive.plan_invalid", "frozen primitive identities must be unique") }
            ids.add(providerText(value, "id"))
        }
        }
        this.window = window
        this.intents = values
        this.dataOnlyCompletion152 = dataCompletion
    }

    public func consume(intentId: String): JsonNode {
        if (dataOnlyCompletion152) {
            failed = true
            throw PureProviderError("primitive.completion_no_service", "frozen data completion has no callable service")
        }
        if (failed || !httpIntentIdentifier(intentId) || claimed.contains(intentId) || claimed.size >= 32) {
            throw PureProviderError("primitive.intent_reused", "primitive requests are bounded and single-use") }
        var service = ""
        for (value in intents.items where providerText(value, "id") == intentId) {
            service = providerText(value, "service")
        }
        if (service == "") {
            throw PureProviderError("primitive.intent_missing", "the request is absent from the frozen parent") }
        claimed.add(intentId)
        try {
            providerDeadline(window.deadline)
            let fields = providerEnvelope(window.invocation, "service_request")
            fields.add(JsonObjectEntry("request_id", jsonString(intentId)))
            fields.add(JsonObjectEntry("service", jsonString(service)))
            fields.add(JsonObjectEntry("arguments", jsonObject([
                JsonObjectEntry("intent_id", jsonString(intentId))])))
            providerEmit(jsonObject(fields.toArray()))
            let response = window.documentResponse(sequence, intentId)
            sequence++
            if (providerText(response, "service") != service) {
                throw PureProviderError("primitive.response_service", "the response has another primitive identity") }
            response
        } catch (error: Exception) { failed = true; throw error }
    }

    func requireComplete(): Unit {
        if (failed) {
            throw PureProviderError("primitive.service_failed", "a refused primitive cannot become Tool success") }
    }
}

func primitiveService111(name: String): Bool {
    // Share the Kernel service vocabulary; Host still validates each frozen intent.
    pluginPrimitiveService111(name)
}
