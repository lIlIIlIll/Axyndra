package agent_sdk

import std.collection.*
import yjson.*
import yjson_support.*

// Native declarations and invocation data are not Host admission, a Source,
// an Operation or permission to use I/O. The executable's protocol adapter
// remains responsible for the actual Host handshake and cancellation window.
public class NativePluginDefinition {
    public let id: String
    public let version: String
    public let contributions: Array<PluginContributionDefinition>
    public let capabilities: Array<String>

    public init(id: String, version: String,
        contributions: Array<PluginContributionDefinition>,
        capabilities!: Array<String> = []) {
        if (id.trimAscii() == "" || version.trimAscii() == "" ||
            contributions.isEmpty()) {
            throw IllegalArgumentException("native definition needs package identity and contributions")
        }
        for (index in 0..contributions.size) {
            for (prior in 0..index) {
                if (contributions[prior].kind == contributions[index].kind && contributions[prior].name == contributions[index].name) {
                    throw IllegalArgumentException("native contribution kind/name identities must be unique")
                }
            }
        }
        let requests = HashSet<String>()
        for (name in capabilities) {
            if (name.trimAscii() != name || name == "" || name.contains("\u{0000}") || requests.contains(name)) {
                throw IllegalArgumentException("native capabilities must be unique nonempty declaration names")
            }
            requests.add(name)
        }
        this.id = id.trimAscii(); this.version = version.trimAscii()
        this.contributions = contributions.clone()
        this.capabilities = capabilities.clone()
    }
}

public class NativePluginInvocation {
    public let callId: String
    public let contribution: String
    public let contributionKind: PluginContributionKind
    public let input: JsonNode
    public let cancellation: InvocationCancellation
    public let deadline: InvocationDeadline

    public init(callId: String, contribution: String, input: JsonNode,
        contributionKind!: PluginContributionKind = PluginContributionKind.Provider,
        cancellation!: InvocationCancellation = NeverCancelled(),
        deadline!: InvocationDeadline = InvocationDeadline()) {
        if (callId.trimAscii() == "" || contribution.trimAscii() == "") {
            throw IllegalArgumentException("native invocation needs descriptive call and contribution names")
        }
        this.callId = callId; this.contribution = contribution; this.contributionKind = contributionKind; this.input = input
        this.cancellation = cancellation; this.deadline = deadline
    }
}

// This interface is implemented inside the Native executable. It returns
// complete data; no workspace-search/write/Host-operation union is dispatched
// by Product on its behalf.
public interface NativePluginHandler {
    func definition(): NativePluginDefinition
    func validate(kind: PluginContributionKind, contribution: String, input: JsonNode): SdkResult<JsonNode>
    func invoke(invocation: NativePluginInvocation): SdkResult<JsonNode>
}
