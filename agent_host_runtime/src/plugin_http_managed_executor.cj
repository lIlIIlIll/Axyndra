package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// The only HTTP child entry in the shared catalog. It does not create or find
// arbitrary exchanges by plugin-supplied IDs. The existing manager resolves a
// retained host invocation through its actual sealed parent source.
class HostManagedHttpExecutor <: ToolExecutor {
    private let manager: HostPluginLifecycleManager
    init(manager: HostPluginLifecycleManager) { this.manager = manager }
    func descriptor(): ToolDescriptor {
        ToolDescriptor(ModelToolDefinition(HOST_HTTP_STREAM_TOOL,
            "Execute one exact approved HTTP stream request through its owned invocation.",
            objectValue([ValueField("type", textValue("object"))])),
            Capability(CapabilityKind.NetworkAccess), hostServiceOnly: true, neverReplay: true,
            implementationVersion: HOST_HTTP_STREAM_FINGERPRINT, implementationFingerprint: HOST_HTTP_STREAM_FINGERPRINT,
            capabilityResolver: Some({ call => Capability(CapabilityKind.NetworkAccess,
                resource: match (hostManagedHttpChildPolicy(call)) {
                    case Result.Ok(policy) => networkEgressResource(policy.egress[0])
                    case Result.Err(_) => "invalid-http-stream-intent"
                }) }),
            sideEffectResolver: Some({ call => match (call.arguments.field("intent")) {
                case Some(intent) => match (intent.field("request")) {
                    case Some(request) => httpIntentText(request, "method") != "GET"
                    case None => true
                }
                case None => true
            } }),
            networkPolicyResolver: Some({ call => hostManagedHttpChildPolicy(call) }),
            canonicalArgumentsResolver: Some({ _, call =>
                if (!httpIntentExactFields(call.arguments, ["binding", "intent"])) {
                    return hostLifecycleLeaseError("http.stream_arguments_invalid")
                }
                match (validateHttpStreamBinding(call.arguments.field("binding").getOrThrow())) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                }
                match (httpStreamIntentPolicy(call.arguments.field("intent").getOrThrow(), binding: call.arguments.field("binding"))) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                }
                Result.Ok(parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: 196608))
            }))
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (!isHttpStreamServiceChildPlan(prepared.operationPlan)) {
            return hostLifecycleLeaseError("http.stream_source_invalid")
        }
        manager.executeHttpStreamChild(context, prepared)
    }
    // The actual current root cancellation closes its retained exchange. A
    // detached primitive RunId must not select another invocation or grant.
    public func cancel(_: RunId): Result<Unit> { Result.Ok(()) }
}

func hostManagedHttpChildPolicy(call: ToolCall): Result<NetworkPolicy> {
    match (call.arguments.field("intent")) {
        case Some(intent) => httpStreamIntentPolicy(intent, binding: call.arguments.field("binding"))
        case None => hostLifecycleLeaseError("http.stream_intent_missing")
    }
}
