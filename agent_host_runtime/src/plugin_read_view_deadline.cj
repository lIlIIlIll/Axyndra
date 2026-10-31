package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.math.*
import yjson.*
import yjson_support.*

func hostValidateReadViewProcessRequest(configuration: HostPluginHttpConfiguration, tool: String, request: AgentValue): Result<Unit> {
    let selected = configuration.readViewDeadlineMaximum(tool)
    if (selected.isNone()) { return hostValidatePluginProcessArguments(request) }
    let maximum = selected.getOrThrow()
    let millis = hostPluginProcessTimeout(request)
    if (millis < 1 || millis > maximum) {
        return hostPluginResourceError("read_view.deadline_profile_invalid", "worker timeout exceeds the selected operator finite deadline") }
    let fields = ArrayList<ValueField>()
    for (field in request.fields) { fields.add(ValueField(field.name, if (field.name == "timeout_ms") { integerValue(min(millis, 60000)) } else { field.value })) }
    hostValidatePluginProcessArguments(objectValue(fields.toArray()))
}
func hostReadViewDeadlineProfile(host: HostJavaScriptPluginHost, configuration: HostPluginHttpConfiguration,
    namespace: String, tool: String, generation: UInt64): Result<?AgentValue> {
    match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let maximum = match (configuration.readViewDeadlineMaximum(tool)) { case None => return Result<?AgentValue>.Ok(Option<AgentValue>.None); case Some(value) => value }
    // The operator must also select a protocol call lease that can contain its
    // requested profile. Neither this data nor startup approval extends a lease.
    if (configuration.protocolLimits.callTimeoutMillis < maximum) {
        return hostPluginResourceError("read_view.deadline_lease_missing", "finite deadline exceeds the operator protocol call lease") }
    let schema = match (host.currentToolSchemaDigest(namespace, tool, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    Result.Ok(Some(objectValue([ValueField("version", textValue(READ_VIEW_FINITE_DEADLINE_VERSION)),
        ValueField("maximum_ms", integerValue(maximum)), ValueField("schema_digest", textValue(schema))])))
}
func hostFreezeReadViewDeadline(host: HostJavaScriptPluginHost, configuration: HostPluginHttpConfiguration,
    namespace: String, tool: String, generation: UInt64, frozen: AgentValue): Result<AgentValue> {
    let profile = match (hostReadViewDeadlineProfile(host, configuration, namespace, tool, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (profile.isNone()) { return Result.Ok(frozen) }
    let fields = ArrayList<ValueField>(); for (field in frozen.fields) { fields.add(field) }
    fields.add(ValueField("deadline_profile", profile.getOrThrow()))
    Result.Ok(objectValue(fields.toArray()))
}
func hostValidateReadViewDeadline(host: HostJavaScriptPluginHost, configuration: HostPluginHttpConfiguration,
    namespace: String, tool: String, generation: UInt64, intent: AgentValue): Result<Unit> {
    let selected = match (hostReadViewDeadlineProfile(host, configuration, namespace, tool, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let frozen = intent.field("deadline_profile")
    if (canonicalAgentValue(selected ?? nullValue()) != canonicalAgentValue(frozen ?? nullValue()) || validateReadViewIntent(intent).isError()) {
        return hostPluginResourceError("read_view.deadline_profile_changed", "finite deadline differs from the actual current operator and ready Tool") }
    Result.Ok(())
}


class HostReadViewCallWindow {
    private let host: HostJavaScriptPluginHost
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let namespace: String; private let contribution: String; private let generation: UInt64
    private let configurationDigest: String; private let profileText: String
    init(host: HostJavaScriptPluginHost, context: ToolInvocationContext, prepared: PreparedToolInvocation,
        namespace: String, contribution: String, generation: UInt64, configurationDigest: String, profile: AgentValue) {
        this.host = host; this.context = context; this.prepared = prepared; this.namespace = namespace
        this.contribution = contribution; this.generation = generation; this.configurationDigest = configurationDigest
        this.profileText = canonicalAgentValue(profile)
    }
    func scope(): String { configurationDigest + ":" + profileText }
    func validate(actualHost: HostJavaScriptPluginHost, identity: JavaScriptHostInvocationIdentity,
        expectedGeneration: UInt64): Result<Int64> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!refEq(host, actualHost) || expectedGeneration != generation || identity.kind != "tool" ||
            identity.threadId != context.sessionId.value || identity.runId != context.runId.value || identity.epoch != context.epoch ||
            identity.operationId != prepared.operationId.value || identity.callId != prepared.call.callId ||
            prepared.source.operationRoot.isNone() || prepared.operationPlan.toolName != "plugin." + namespace + "." + contribution ||
            !isFrozenReadViewParentPlan(prepared.operationPlan)) {
            return hostPluginResourceError("read_view.deadline_owner_changed", "finite call window belongs to another actual Root invocation") }
        match (host.readViewInput(prepared, namespace, contribution, generation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let frozen = prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
        let profile = frozen.field("intents").getOrThrow().items[0].field("deadline_profile") ?? nullValue()
        if (httpIntentText(frozen, "configuration_digest") != configurationDigest || canonicalAgentValue(profile) != profileText) {
            return hostPluginResourceError("read_view.deadline_owner_changed", "finite call window lost its exact current frozen profile") }
        Result.Ok(Int64.parse(profile.field("maximum_ms").getOrThrow().asNumberText()))
    }
}
