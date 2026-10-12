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
public func hostQueryPluginPolicy(host: HostJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, input: AgentValue, thread: ThreadId, cancellation: CancellationToken,
    requestId: String, deadline!: ?MonoTime = None): Result<HostPluginPolicyResult> {
    hostQueryPluginPolicyFrame193<HostPluginPolicyResult>(host, namespace, contribution, expectedDigest,
        input, thread, cancellation, requestId, deadline, { response, binding => HostPluginPolicyResult(response, binding) })
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
    hostQueryPluginPolicyFrame193<HostPolicyScalarResult193>(host, namespace, contribution, expectedDigest,
        input, thread, cancellation, requestId, None<MonoTime>,
        { response, binding => HostPolicyScalarResult193(response, binding.generation) })
}

private func hostQueryPluginPolicyFrame193<T>(host: HostJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, input: AgentValue, thread: ThreadId, cancellation: CancellationToken,
    requestId: String, deadline: ?MonoTime, make: (HostJavaScriptPluginInvocationResult, HostPluginPolicyBinding) -> T): Result<T> {
    match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (hostPolicyQueryRemaining(deadline) <= 0) { return hostPluginResourceError("policy.deadline_exceeded", "policy observation deadline expired") }
    let query = objectValue([ValueField("schema", textValue("axyndra.policy-query/v1")), ValueField("input", input)])
    // TEMP_DIAGNOSTIC: fixed labels and duration only; remove before final gates.
    let diagnosticFreeze = MonoTime.now()
    let frozen = try { HostFrozenPluginContentQuery(query, [], observed: true) }
        catch (_: Exception) { return hostPluginResourceError("policy.query_limit", "policy input exceeds its bounded data codec or aggregate capacity") }
        finally { hostCompactionDiagnosticRecord("policy-freeze", diagnosticFreeze) }
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
        let diagnosticEncode = MonoTime.now()
        let encoded = try { stringifyUnifiedJson(frozen.query) }
            finally { hostCompactionDiagnosticRecord("policy-encode", diagnosticEncode) }
        let diagnosticInvoke = MonoTime.now()
        let response = try { match (host.invoke(namespace, contribution, encoded, identity: identity,
            cancellation: cancellation, expectedInstanceGeneration: binding.generation,
            authorityScope: "pure-policy", timeoutMillis: remaining)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value } }
            finally { hostCompactionDiagnosticRecord("policy-invoke", diagnosticInvoke) }
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
