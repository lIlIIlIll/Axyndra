package agent_host_runtime

// Identity-only mounted contribution data. It is neither a capability, source,
// approval nor an execution grant. Query callers retain their existing enabled
// generation, package inspect, finite payload, and before/after checks.
public class HostPluginContentBinding {
    public let namespace: String; public let digest: String; public let version: String
    public let generation: UInt64; public let contribution: String; public let resource: Bool
    public init(namespace: String, digest: String, version: String, generation: UInt64, contribution: String, resource: Bool) {
        this.namespace = namespace; this.digest = digest; this.version = version
        this.generation = generation; this.contribution = contribution; this.resource = resource
    }
}


public class HostPluginPolicyBinding {
    public let namespace: String; public let contribution: String; public let digest: String; public let generation: UInt64
    public init(namespace: String, contribution: String, digest: String, generation: UInt64) {
        this.namespace = namespace; this.contribution = contribution; this.digest = digest; this.generation = generation
    }
}

