package tool_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

class ToolCatalogSeal {}

func toolOwnedDefinitionCopy(value: ModelToolDefinition): ModelToolDefinition {
    // canonicalAgentValue is a framed hash encoding, not JSON. Preserve the
    // actual JSON tree through the standard bounded codec before freezing it.
    ModelToolDefinition(value.name, value.description,
        parseUnifiedJson(stringifyUnifiedJson(value.inputSchema), maxBytes: 65536))
}

func toolOwnedConcurrencyCopy(value: ToolConcurrencyProfile): ToolConcurrencyProfile {
    ToolConcurrencyProfile(mode: value.mode, accesses: value.accesses.clone())
}

func toolOwnedApprovalCopy(value: ToolApprovalMetadata): ToolApprovalMetadata {
    let summary: ?WriteApprovalSummary = match (value.writeSummary) {
        case None => None
        case Some(item) => Some(WriteApprovalSummary(item.path, item.action, item.exists, item.bytes, item.lines,
            language: item.language, preview: item.preview.clone(), truncated: item.truncated,
            contentHash: item.contentHash, beforeBytes: item.beforeBytes,
            addedLines: item.addedLines, removedLines: item.removedLines))
    }
    ToolApprovalMetadata(value.capabilityLabel,
        RiskAssessment(value.assessment.level, flags: value.assessment.flags.clone(), reasons: value.assessment.reasons.clone()),
        value.grantScope, writeSummary: summary, sessionApprovalAllowed: value.sessionApprovalAllowed)
}

// An in-process host capability, never decoded from a contribution message.
// The catalog object itself is available only to trusted host composition.
public class ToolCatalogOwner {
    public let id: String
    public let namespacePrefix: String
    public let threadId: ?ThreadId
    public let maximumEntries: Int64
    public let maximumDirectoryBytes: Int64
    let seal: ToolCatalogSeal
    init(id: String, namespacePrefix: String, seal: ToolCatalogSeal, threadId: ?ThreadId, maximumEntries: Int64, maximumDirectoryBytes: Int64) {
        this.id = id
        this.namespacePrefix = namespacePrefix
        this.threadId = threadId
        this.seal = seal; this.maximumEntries = maximumEntries; this.maximumDirectoryBytes = maximumDirectoryBytes
    }
}

// The host must obtain these immutable facts from its verified package,
// operator configuration and durable instance/session lease. A new connection
// cannot reuse a prior instanceIdentity merely because its counter reset.
public class ToolContributionBinding {
    public let packageDigest: String
    public let configurationDigest: String
    public let instanceIdentity: String
    public let revision: Int64
    public init(packageDigest: String, configurationDigest: String,
        instanceIdentity: String, revision: Int64) {
        if (!packageDigest.startsWith("sha256:") || packageDigest.size != 71 ||
            !toolCatalogDigest(packageDigest[7..]) || !toolCatalogDigest(configurationDigest) ||
            !toolCatalogIdentifier(instanceIdentity, 512) || revision < 1) {
            throw IllegalArgumentException("owned contribution requires immutable host binding and positive revision")
        }
        this.packageDigest = packageDigest
        this.configurationDigest = configurationDigest
        this.instanceIdentity = instanceIdentity
        this.revision = revision
    }
}

public class ToolCatalogPublication {
    public let ownerId: String
    public let threadId: ?ThreadId
    public let revision: Int64
    public let directoryDigest: String
    public let binding: ToolContributionBinding
    public let descriptors: Array<ToolDescriptor>
    init(owner: ToolCatalogOwner, binding: ToolContributionBinding,
        directoryDigest: String, descriptors: Array<ToolDescriptor>) {
        this.ownerId = owner.id
        this.threadId = owner.threadId
        this.revision = binding.revision
        this.directoryDigest = directoryDigest
        this.binding = binding
        this.descriptors = descriptors
    }
}

class ToolCatalogOwnerState {
    let owner: ToolCatalogOwner
    var revision: Int64 = 0
    var revoked = false
    init(owner: ToolCatalogOwner) { this.owner = owner }
}

func toolCatalogIdentifier(value: String, limit: Int64): Bool {
    if (value.size == 0 || value.size > limit) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'.' || byte == b'_' || byte == b':' || byte == b'-')) {
            return false
        }
    }
    true
}

func toolCatalogDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}

func toolCatalogSameIdentity(left: ToolDescriptor, right: ToolDescriptor): Bool {
    left.definition.name == right.definition.name && left.implementationVersion == right.implementationVersion &&
        left.implementationFingerprint == right.implementationFingerprint && left.schemaDigest == right.schemaDigest
}

func toolCatalogError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, message))
}

func toolOwnedDescriptorValue(descriptor: ToolDescriptor): AgentValue {
    let capabilities = ArrayList<AgentValue>()
    for (capability in descriptor.requiredCapabilities()) {
        capabilities.add(objectValue([
            ValueField("kind", textValue(capabilityName(capability.kind))),
            ValueField("resource", textValue(capability.resource))
        ]))
    }
    let accesses = ArrayList<AgentValue>()
    for (access in descriptor.concurrency.accesses) {
        accesses.add(objectValue([
            ValueField("namespace", textValue(access.namespace)),
            ValueField("resource", textValue(access.resource)),
            ValueField("mode", textValue(if (access.mode == ToolAccessMode.Read) { "read" } else { "write" })),
            ValueField("scope", textValue(if (access.scope == ToolAccessScope.Exact) { "exact" } else { "tree" }))
        ]))
    }
    objectValue([
        ValueField("name", textValue(descriptor.definition.name)),
        ValueField("description", textValue(descriptor.definition.description)),
        ValueField("schema", descriptor.definition.inputSchema),
        ValueField("version", textValue(descriptor.implementationVersion)),
        ValueField("host_adapter_fingerprint", textValue(descriptor.implementationFingerprint)),
        ValueField("policy", descriptor.ownedPolicyIdentity()),
        ValueField("capabilities", listValue(capabilities.toArray())),
        ValueField("side_effecting", boolValue(descriptor.sideEffecting)),
        ValueField("never_replay", boolValue(descriptor.neverReplay)),
        ValueField("control_only", boolValue(descriptor.controlOnly)),
        ValueField("host_service_only", boolValue(descriptor.hostServiceOnly)),
        ValueField("concurrency", textValue(if (descriptor.concurrency.mode == ToolConcurrencyMode.Exclusive) {
            "exclusive"
        } else { "shared" })),
        ValueField("accesses", listValue(accesses.toArray()))
    ])
}

func toolOwnedApprovalMetadata(metadata: ToolApprovalMetadata): AgentValue {
    let summary = match (metadata.writeSummary) {
        case None => nullValue()
        case Some(value) => objectValue([
            ValueField("path", textValue(value.path)), ValueField("action", textValue(value.action)),
            ValueField("exists", boolValue(value.exists)), ValueField("bytes", integerValue(value.bytes)),
            ValueField("lines", integerValue(value.lines)), ValueField("language", textValue(value.language)),
            ValueField("preview", operationStringList(value.preview)), ValueField("truncated", boolValue(value.truncated)),
            ValueField("content_hash", textValue(value.contentHash)), ValueField("before_bytes", integerValue(value.beforeBytes)),
            ValueField("added_lines", integerValue(value.addedLines)), ValueField("removed_lines", integerValue(value.removedLines))
        ])
    }
    objectValue([
        ValueField("capability_label", textValue(metadata.capabilityLabel)),
        ValueField("risk_level", textValue(approvalRiskLevelName(metadata.assessment.level))),
        ValueField("risk_flags", operationStringList(metadata.assessment.flags)),
        ValueField("risk_reasons", operationStringList(metadata.assessment.reasons)),
        ValueField("grant_capability", textValue(metadata.grantScope.capability)),
        ValueField("grant_path", textValue(metadata.grantScope.pathPrefix)),
        ValueField("grant_tool", textValue(metadata.grantScope.toolName)),
        ValueField("grant_host", textValue(metadata.grantScope.host)),
        ValueField("grant_session_only", boolValue(metadata.grantScope.sessionOnly)),
        ValueField("session_approval_allowed", boolValue(metadata.sessionApprovalAllowed)),
        ValueField("write_summary", summary)
    ])
}

func toolOwnedDirectoryDigest(entries: Array<ToolCatalogRegistration>): String {
    let values = ArrayList<AgentValue>()
    // Order is part of the advertised directory and therefore the digest.
    for (entry in entries) { values.add(toolOwnedDescriptorValue(entry.descriptor)) }
    modelPolicySha256Text(canonicalAgentValue(listValue(values.toArray())))
}

func toolOwnedFingerprint(owner: ToolCatalogOwner, binding: ToolContributionBinding,
    directoryDigest: String, descriptor: ToolDescriptor): String {
    let fields = ArrayList<ValueField>([
        ValueField("owner", textValue(owner.id)),
        ValueField("prefix", textValue(owner.namespacePrefix)),
        ValueField("package_digest", textValue(binding.packageDigest)),
        ValueField("configuration_digest", textValue(binding.configurationDigest)),
        ValueField("instance_identity", textValue(binding.instanceIdentity)),
        ValueField("directory_revision", integerValue(binding.revision)),
        ValueField("directory_digest", textValue(directoryDigest)),
        ValueField("tool", toolOwnedDescriptorValue(descriptor))
    ])
    match (owner.threadId) {
        case Some(value) => fields.add(ValueField("thread_id", textValue(value.value)))
        case None => ()
    }
    // Preserve the exact existing global identity; thread scope is additive.
    "owned-v1:" + modelPolicySha256Text(canonicalAgentValue(objectValue(fields.toArray())))
}

func validateOwnedToolEntries(owner: ToolCatalogOwner, entries: Array<ToolCatalogRegistration>): Result<Unit> {
    if (entries.size > owner.maximumEntries) {
        return toolCatalogError("tool.owner_directory_limit", "owned directory exceeds its sealed host entry limit")
    }
    let names = HashSet<String>()
    var bytes: Int64 = 0
    try {
        for (entry in entries) {
            let descriptor = entry.descriptor
            let name = descriptor.definition.name
            if (!toolCatalogIdentifier(name, 512) || !name.startsWith(owner.namespacePrefix) ||
                name.size <= owner.namespacePrefix.size || names.contains(name)) {
                return toolCatalogError("tool.owner_name_invalid", "owned tools require unique names in the host namespace")
            }
            if (descriptor.controlOnly || descriptor.hostServiceOnly) {
                return toolCatalogError("tool.owner_hidden_tool_denied", "external contributions cannot publish hidden host ports")
            }
            if (descriptor.definition.inputSchema.unifiedKind != ValueKind.Object ||
                descriptor.schemaDigest != modelPolicySha256Text(canonicalAgentValue(descriptor.definition.inputSchema))) {
                return toolCatalogError("tool.owner_schema_invalid", "owned tool schema is not an immutable object")
            }
            if (descriptor.sideEffecting && !sharedSideEffectHasWrite(descriptor.concurrency)) {
                return toolCatalogError("tool.shared_side_effect_without_write", "shared side effect requires a write claim")
            }
            let encoded = canonicalAgentValue(toolOwnedDescriptorValue(descriptor))
            if (encoded.size > 65536) {
                return toolCatalogError("tool.owner_schema_limit", "owned tool definition exceeds 64 KiB")
            }
            bytes += encoded.size
            if (bytes > owner.maximumDirectoryBytes) {
                return toolCatalogError("tool.owner_directory_limit", "owned directory exceeds its sealed host byte limit")
            }
            names.add(name)
        }
        Result.Ok(())
    } catch (_: Exception) {
        toolCatalogError("tool.owner_definition_invalid", "owned tool definition cannot be canonically encoded")
    }
}
