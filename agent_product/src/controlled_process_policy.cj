package agent_product

import agent_domain.*

// Shared host policy for ordinary Shell calls and plugin maintenance. The
// caller's requested policy is never a grant; ToolPipeline freezes and approves
// the normalized plan before either executor uses these controlled primitives.
func controlledProcessNetworkPolicy(
    mode: ShellNetworkMode,
    requested: ?NetworkPolicy
): Result<NetworkPolicy> {
    match (requested) {
        case Some(policy) =>
            if (mode == ShellNetworkMode.Proxy && networkPolicyModeIsHost(policy.mode)) {
                return Result.Err(AgentError(
                    AgentErrorKind.PermissionDenied, "network.mode_denied",
                    "proxy shell mode forbids HostNetwork", retryable: false, fallbackAllowed: false
                ))
            }
            if (networkPolicyModeIsMediated(policy.mode) && !policy.publish.isEmpty()) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput, "network.publish_not_supported",
                    "shell processes cannot publish mediated ports", retryable: false, fallbackAllowed: false
                ))
            }
            Result.Ok(policy)
        case None => Result.Ok(match (mode) {
            case ShellNetworkMode.Restricted => NetworkPolicy(NetworkPolicyMode.Denied)
            case ShellNetworkMode.Proxy => NetworkPolicy(NetworkPolicyMode.Mediated)
            case ShellNetworkMode.TrustedHost => NetworkPolicy(NetworkPolicyMode.HostNetwork)
        })
    }
}
