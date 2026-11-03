package agent_plugin_registry

import agent_domain.*

public class ProductPluginAcquisitionSpec {
    public let kind: PluginSourceKind
    public let locator: String
    public let packageName: String
    public let version: String
    public let revision: String
    public let registryUrl: String
    public let sourceLocator: String
    public let networkPolicy: NetworkPolicy
    public let workspaceSource: Bool

    public init(
        kind: PluginSourceKind,
        locator: String,
        packageName: String,
        version: String,
        revision: String,
        registryUrl: String,
        sourceLocator: String,
        workspaceSource: Bool,
        networkPolicy: NetworkPolicy
    ) {
        this.kind = kind
        this.locator = locator
        this.packageName = packageName
        this.version = version
        this.revision = revision
        this.registryUrl = registryUrl
        this.sourceLocator = sourceLocator
        this.networkPolicy = networkPolicy
        this.workspaceSource = workspaceSource
    }
}

public class ProductAcquiredPluginSource {
    public let kind: PluginSourceKind
    public let locator: String
    public let version: String
    public let revision: String
    public let integrity: String
    public let packageRoot: String
    public let stageRoot: String

    public init(
        kind: PluginSourceKind,
        locator: String,
        version: String,
        revision: String,
        integrity: String,
        packageRoot: String,
        stageRoot: String
    ) {
        this.kind = kind
        this.locator = locator
        this.version = version
        this.revision = revision
        this.integrity = integrity
        this.packageRoot = packageRoot
        this.stageRoot = stageRoot
    }
}

public func productPluginExactGitRevision(value: String): Bool {
    if (value.size != 40 && value.size != 64) { return false }
    for (rune in value.toRuneArray()) {
        if (!((rune >= r'0' && rune <= r'9') || (rune >= r'a' && rune <= r'f') ||
            (rune >= r'A' && rune <= r'F'))) {
            return false
        }
    }
    true
}
