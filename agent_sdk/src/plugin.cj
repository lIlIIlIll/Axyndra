package agent_sdk

import std.deriving.*

// EXPERIMENTAL: contribution identity is independent of package identity and
// runtime generation. A declaration requests a host port; it never grants one.
@Derive[Equatable]
public enum PluginContributionKind { Tool | Command | View | Skill | Provider | ModelProvider | ContextProvider | ResourceProvider | Event | Service }

// A restriction implemented by the Host, not a package-supplied capability.
// Brokered preserves the existing default. DataOnly has no Host services.
@Derive[Equatable]
public enum PluginToolExecutionProfile { Brokered | DataOnly }

// EXPERIMENTAL: shared by package inspection and the isolated host handshake.
public class PluginContributionDefinition {
    public let name: String
    public let kind: PluginContributionKind
    public let supportsPreparationReference: Bool
    public let executionProfile: PluginToolExecutionProfile
    public let inputAttachmentField: String
    public let inputAttachmentMaxBytes: Int64
    private let userControls: Array<String>
    public func allowedUserControls(): Array<String> { userControls.clone() }

    public init(name: String, kind: PluginContributionKind, supportsPreparationReference!: Bool = false,
        allowedUserControls!: Array<String> = [],
        executionProfile!: PluginToolExecutionProfile = PluginToolExecutionProfile.Brokered,
        inputAttachmentField!: String = "", inputAttachmentMaxBytes!: Int64 = 0) {
        let normalized = name.trimAscii()
        if (normalized == "" || normalized.size > 128 || normalized.contains("\u{0000}")) {
            throw IllegalArgumentException("plugin contribution name must be bounded nonempty text")
        }
        if (supportsPreparationReference && kind != PluginContributionKind.Service) {
            throw IllegalArgumentException("only a Service may declare preparation references")
        }
        if (!allowedUserControls.isEmpty() && (kind != PluginContributionKind.Command ||
            allowedUserControls.size != 1 || !["continuation", "plan_review"].contains(allowedUserControls[0]))) {
            throw IllegalArgumentException("only a Command may request exactly one supported user control")
        }
        if (executionProfile != PluginToolExecutionProfile.Brokered && kind != PluginContributionKind.Tool) {
            throw IllegalArgumentException("only a Tool may request the data-only execution restriction")
        }
        if (!validPluginInputAttachmentDeclaration(inputAttachmentField, inputAttachmentMaxBytes) ||
            (inputAttachmentField != "" && (kind != PluginContributionKind.Tool ||
                executionProfile != PluginToolExecutionProfile.Brokered))) {
            throw IllegalArgumentException("input attachment metadata belongs only to a brokered native Tool")
        }
        this.inputAttachmentField = inputAttachmentField
        this.inputAttachmentMaxBytes = inputAttachmentMaxBytes
        this.executionProfile = executionProfile
        this.userControls = allowedUserControls.clone()
        this.name = normalized
        this.kind = kind
        this.supportsPreparationReference = supportsPreparationReference
    }
}
