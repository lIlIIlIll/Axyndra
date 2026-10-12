package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Pure preparation plus host-held observer construction. No constructor or
// begin method starts an HTTP exchange; the shared manager retains the returned
// invocation before a native service may send an onServiceRequest callback.
class HostManagedHttpTransport <: HostManagedServiceTransport {
    private let runtime: HostJavaScriptPluginServiceRuntime
    private let configuration: HostPluginHttpConfiguration
    private let store: DurableOperationStore
    private let caBundle: String
    private let artifacts: ?HostArtifactStore
    private let configurationText: String
    init(runtime: HostJavaScriptPluginServiceRuntime, configuration: HostPluginHttpConfiguration,
        store: DurableOperationStore, caBundle: String, artifacts!: ?HostArtifactStore = None) {
        this.runtime = runtime; this.configuration = configuration; this.store = store; this.caBundle = caBundle; this.artifacts = artifacts
        configurationText = stringifyUnifiedJson(configuration.configuration)
        hostLifecycleRequire(configurationText.size <= 16384, "plugin.http_service_configuration_limit")
    }
    private func nonsecret(): AgentValue { parseUnifiedJson(configurationText, maxBytes: 16384) }
    public func requestedCapability(): String { "network.http" }
    public func preparationArguments(phase: HostManagedServicePhase, localName: String, input: AgentValue): AgentValue {
        match (phase) {
            case HostManagedServicePhase.Call => objectValue([ValueField("action", textValue("call")),
                ValueField("tool", textValue(localName)), ValueField("input", input)])
            case HostManagedServicePhase.Start => objectValue([ValueField("action", textValue("start")), ValueField("configuration", nonsecret())])
            case HostManagedServicePhase.Refresh => objectValue([ValueField("action", textValue("refresh")), ValueField("configuration", nonsecret())])
        }
    }
    public func freezeIntents(context: ToolInvocationContext, call: ToolCall, input: AgentValue, purePreparation: AgentValue,
        binding: AgentValue): Result<AgentValue> {
        let _ = context
        match (validateBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        var intents = match (configuration.bindStreamIntents(purePreparation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        if (intents.isEmpty()) { return hostLifecycleLeaseError("http.stream_intents_invalid") }
        let payload = servicePayloadLimits(binding).value().getOrThrow()
        if (payload.isSome()) {
            let limits = payload.getOrThrow(); var total: Int64 = 0
            for (intent in intents) {
                total += httpStreamRequestBody(intent.field("request").getOrThrow(), maximumBytes: limits.maxWriteBytes).value().getOrThrow().size
                if (total > limits.maxWriteBytes) { return hostLifecycleLeaseError("http.stream_intents_invalid") }
            }
            let actual = match (artifacts) { case Some(value) => value; case None => return hostLifecycleLeaseError("plugin.payload_store_unavailable") }
            let frozen = ArrayList<AgentValue>()
            for (intent in intents) {
                let request = intent.field("request").getOrThrow()
                let bytes = httpIntentText(request, "body_hex")
                if (bytes != "") {
                    let staged = match (actual.stageServicePayload(context, ToolCall(call.callId, call.name, input), binding,
                        httpIntentText(intent, "id"), bytes)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    let fields = ArrayList<ValueField>()
                    for (field in request.fields where field.name != "body_hex") { fields.add(field) }
                    fields.add(ValueField("body_payload", staged.field("payload").getOrThrow()))
                    intent.put("request", objectValue(fields.toArray()))
                }
                frozen.add(intent)
            }
            intents = frozen.toArray()
        }
        let canonical = objectValue([ValueField("input", input), ValueField("configuration", nonsecret()),
            ValueField("host_plan", objectValue([ValueField("version", textValue(if (payload.isSome()) { HOST_HTTP_STREAM_PAYLOAD_INTENT_VERSION } else { HOST_HTTP_STREAM_INTENT_VERSION })),
                ValueField("binding", binding), ValueField("intents", listValue(intents))]))])
        // This validates every intent, cumulative exact body bytes, and the
        // complete published binding against the same parent network ceiling.
        match (httpStreamServiceChildArguments(canonical, httpIntentText(intents[0], "id"))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        if (!hostManagedServiceDurableValueFits(canonical)) { return hostLifecycleLeaseError("plugin.lifecycle_input_codec_limit") }
        Result.Ok(parseUnifiedJson(stringifyUnifiedJson(canonical), maxBytes: httpStreamPayloadCanonicalBytes(binding)))
    }
    private func validateBinding(binding: AgentValue): Result<Unit> {
        match (validateHttpStreamBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (httpIntentText(binding, "plugin") != configuration.namespace ||
            httpIntentText(binding, "package_digest") != configuration.packageDigest ||
            httpIntentText(binding, "configuration_digest") != configuration.digest) {
            return hostLifecycleLeaseError("http.stream_configuration_mismatch")
        }
        configuration.stillCurrent()
    }
    public func validateParent(context: ToolInvocationContext, prepared: PreparedToolInvocation, binding: AgentValue): Result<Unit> {
        let _ = context
        match (validateBinding(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!isFrozenHttpStreamParentPlan(prepared.operationPlan) ||
            canonicalAgentValue(prepared.operationPlan.canonicalArguments.field("configuration").getOrThrow()) != canonicalAgentValue(nonsecret()) ||
            canonicalAgentValue(prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()) != canonicalAgentValue(binding)) {
            return hostLifecycleLeaseError("http.stream_parent_mismatch")
        }
        Result.Ok(())
    }
    public func beginInvocation(service: HostPluginManagedService, endpoint: HostPinnedNativeServiceEndpoint,
        rootContext: ToolInvocationContext, rootPrepared: PreparedToolInvocation, binding: AgentValue): Result<HostManagedServiceInvocation> {
        match (validateParent(rootContext, rootPrepared, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(HostManagedHttpInvocation(service, endpoint, rootContext, rootPrepared, configuration, store, caBundle,
            broker: Some(runtime.streamBroker(rootContext, rootPrepared, binding)), binding: Some(binding), artifacts: artifacts))
    }
    public func beginMaintenance(service: HostPluginManagedService, endpoint: HostPinnedNativeServiceEndpoint,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, action: HostServiceAction): Result<HostManagedServiceInvocation> {
        let plan = match (service.maintenancePlan(context, prepared, action)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let grant = plan.field(if (action == HostServiceAction.Start) { "grant" } else { "launch" }).getOrThrow()
        if (httpIntentText(grant, "namespace") != configuration.namespace || httpIntentText(grant, "package_digest") != configuration.packageDigest ||
            httpIntentText(grant, "configuration_digest") != configuration.digest) {
            return hostLifecycleLeaseError("http.stream_configuration_mismatch")
        }
        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(HostManagedHttpInvocation(service, endpoint, context, prepared, configuration, store, caBundle, action: Some(action), artifacts: artifacts))
    }
}
