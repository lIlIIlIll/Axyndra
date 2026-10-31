package agent_host_runtime

import agent_domain.*

public class HostReadTargetInfo {
    public let requestedPath: String
    public let normalizedPath: String
    public let permissionClass: String
    public let reason: String
    public let baseRisk: ApprovalRiskLevel
    public let exists: Bool
    public let isDirectory: Bool
    public let sensitive: Bool

    public init(
        requestedPath: String,
        normalizedPath: String,
        permissionClass: String,
        reason: String,
        baseRisk: ApprovalRiskLevel,
        exists: Bool,
        isDirectory: Bool,
        sensitive: Bool
    ) {
        this.requestedPath = requestedPath
        this.normalizedPath = normalizedPath
        this.permissionClass = permissionClass
        this.reason = reason
        this.baseRisk = baseRisk
        this.exists = exists
        this.isDirectory = isDirectory
        this.sensitive = sensitive
    }
}

// Trusted host composition only. These are classification observations,
// never source, approval, generation or commit authority. Callers must still
// check the actual canonical root/capabilities, protected roots and native
// complete-file witness before opening/copying content. No plugin/SDK/JS
// decoder or contribution registry exposes this port or its factory.
public interface HostReadTargetInspector {
    func inspectReadTarget(path: String): Result<HostReadTargetInfo>
}

public type HostReadTargetInspectorFactory = (String) -> HostReadTargetInspector
