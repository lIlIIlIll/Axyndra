package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import std.time.*
import yjson.*
import yjson_support.*

type ProductPluginPolicyBinding = HostPluginPolicyBinding

type ProductPluginPolicyResult = agent_host_runtime.HostPluginPolicyResult

func queryProductPluginPolicy(host: ProductJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, input: AgentValue, thread: ThreadId, cancellation: CancellationToken,
    requestId: String, deadline!: ?MonoTime = None): Result<ProductPluginPolicyResult> {
    agent_host_runtime.hostQueryPluginPolicy(host, namespace, contribution, expectedDigest, input, thread, cancellation, requestId, deadline: deadline)
}

func policyQueryRemaining(deadline: ?MonoTime): Int64 {
    agent_host_runtime.hostPolicyQueryRemaining(deadline)
}
