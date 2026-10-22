package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*


import agent_domain.*
import agent_extension_runtime.*
import std.time.*
import yjson.*
import yjson_support.*



public class HostPluginPolicyResult {
    public let value: AgentValue
    public let binding: HostPluginPolicyBinding
    private let response: HostJavaScriptPluginInvocationResult
    init(response: HostJavaScriptPluginInvocationResult, binding: HostPluginPolicyBinding) {
        this.response = response; this.binding = binding; this.value = response.value.field("value").getOrThrow()
    }
    public func close(): Unit { response.releasePayload() }
}

// Callers supply already-authorized facts and must validate every proposed
// value before using an existing Host model/data/commit port. Neither input
// data nor policy output grants a capability or creates canonical evidence.
// A pure input stays in the actual pinned package's DATA custody. Native
// transport reservations/floors and all authorization checks remain separate.
private func hostPolicyQueryPayment193(host: HostJavaScriptPluginHost, namespace: String,
    contribution: String, expectedDigest: String): Result<LogicalJsonOwnerReservation> {
    let binding = match (host.policyProviderBinding(namespace, contribution)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (binding.digest != expectedDigest) {
        return hostPluginResourceError("policy.provider_changed", "selected policy no longer matches its pinned package") }
    let mounted = match (host.servicePackage(namespace, binding.generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        if (!mounted.textEquals(PluginDescriptorText.Namespace, namespace) ||
            !mounted.textEquals(PluginDescriptorText.ContentDigest, expectedDigest)) {
            return hostPluginResourceError("policy.provider_changed", "policy input lost its actual package data owner") }
        Result.Ok(mounted.deriveCopiedDataPayment(65536))
    } finally { mounted.close() }
}

public func hostQueryPluginPolicy(host: HostJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, input: AgentValue, thread: ThreadId, cancellation: CancellationToken,
    requestId: String, deadline!: ?MonoTime = None): Result<HostPluginPolicyResult> {
    let payment = match (hostPolicyQueryPayment193(host, namespace, contribution, expectedDigest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        hostQueryPluginPolicyFrame193<HostPluginPolicyResult>(host, namespace, contribution, expectedDigest,
            input, thread, cancellation, requestId, deadline,
            { query => HostFrozenPluginContentQuery(query, [], payment) },
            { response, binding => HostPluginPolicyResult(response, binding) })
    } finally { payment.close() }
}

// The document caller pays the input from the actual installed descriptor.
// This path cannot allocate an unrelated reservation or fall back to one.
func hostQueryPluginPolicyPaidInput(host: HostJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, input: AgentValue, payment: LogicalJsonOwnerReservation, thread: ThreadId,
    cancellation: CancellationToken, requestId: String): Result<HostPluginPolicyResult> {
    hostQueryPluginPolicyFrame193<HostPluginPolicyResult>(host, namespace, contribution, expectedDigest,
        input, thread, cancellation, requestId, None<MonoTime>,
        { query => HostFrozenPluginContentQuery(query, [], payment) },
        { response, binding => HostPluginPolicyResult(response, binding) })
}

// The actual response has its original independent payload custody. No input
// namespace/provider/String binding is stored in this returned scalar wrapper.
public class HostPolicyScalarResult193 {
    public let value: AgentValue
    public let generation: UInt64
    private let response: HostJavaScriptPluginInvocationResult
    init(response: HostJavaScriptPluginInvocationResult, generation: UInt64) {
        this.response = response; this.generation = generation
        this.value = response.value.field("value").getOrThrow()
    }
    public func close(): Unit { response.releasePayload() }
}
public func hostQueryPluginPolicyScalars193(host: HostJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, input: AgentValue, thread: ThreadId, cancellation: CancellationToken,
    requestId: String): Result<HostPolicyScalarResult193> {
    let payment = match (hostPolicyQueryPayment193(host, namespace, contribution, expectedDigest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        hostQueryPluginPolicyFrame193<HostPolicyScalarResult193>(host, namespace, contribution, expectedDigest,
            input, thread, cancellation, requestId, None<MonoTime>,
            { query => HostFrozenPluginContentQuery(query, [], payment) },
            { response, binding => HostPolicyScalarResult193(response, binding.generation) })
    } finally { payment.close() }
}

private func hostQueryPluginPolicyFrame193<T>(host: HostJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, input: AgentValue, thread: ThreadId, cancellation: CancellationToken,
    requestId: String, deadline: ?MonoTime, capture: (AgentValue) -> HostFrozenPluginContentQuery,
    make: (HostJavaScriptPluginInvocationResult, HostPluginPolicyBinding) -> T): Result<T> {
    match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (hostPolicyQueryRemaining(deadline) <= 0) { return hostPluginResourceError("policy.deadline_exceeded", "policy observation deadline expired") }
    let query = objectValue([ValueField("schema", textValue("axyndra.policy-query/v1")), ValueField("input", input)])
    let frozen = try { capture(query) }
        catch (_: Exception) { return hostPluginResourceError("policy.query_limit", "policy input exceeds its bounded data codec or aggregate capacity") }
    try {
        let binding = match (host.policyProviderBinding(namespace, contribution)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (binding.digest != expectedDigest) {
            return hostPluginResourceError("policy.provider_changed", "selected policy no longer matches its pinned package") }
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let remaining = hostPolicyQueryRemaining(deadline)
        if (remaining <= 0) { return hostPluginResourceError("policy.deadline_exceeded", "policy observation deadline expired") }
        let identity = JavaScriptHostInvocationIdentity(threadId: thread.value, runId: "", epoch: 0,
            operationId: "", callId: requestId, kind: "provider")
        let encoded = stringifyUnifiedJson(frozen.query)
        let response = match (host.invoke(namespace, contribution, encoded, identity: identity,
            cancellation: cancellation, expectedInstanceGeneration: binding.generation,
            authorityScope: "pure-policy", timeoutMillis: remaining)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        var retained = false
        try {
            if (response.isError || !httpIntentExactFields(response.value, ["schema", "value"]) ||
                httpIntentText(response.value, "schema") != "axyndra.policy-result/v1") {
                return hostPluginResourceError("policy.result_invalid", "policy must return its exact data-only result envelope") }
            let current = match (host.policyProviderBinding(namespace, contribution)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (current.digest != expectedDigest || current.generation != binding.generation) {
                return hostPluginResourceError("policy.provider_changed", "policy changed before its data proposal was consumed") }
            match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (hostPolicyQueryRemaining(deadline) <= 0) { return hostPluginResourceError("policy.deadline_exceeded", "policy observation deadline expired") }
            let result = make(response, binding)
            retained = true
            Result.Ok(result)
        } catch (_: Exception) {
            hostPluginResourceError("policy.result_invalid", "policy proposal is malformed")
        } finally { if (!retained) { response.releasePayload() } }
    } finally { frozen.close() }
}

public func hostPolicyQueryRemaining(deadline: ?MonoTime): Int64 {
    match (deadline) { case Some(value) => min(5000, (value - MonoTime.now()).toMilliseconds()); case None => 5000 }
}
