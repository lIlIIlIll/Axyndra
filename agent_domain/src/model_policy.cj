package agent_domain

import yjson.*

import yjson_support.*

import std.collection.*
import std.deriving.*
import std.overflow.*

public let MODEL_POLICY_RESOLUTION_VERSION: UInt32 = 1u32
public let MODEL_CAPABILITY_SNAPSHOT_VERSION: UInt32 = 1u32
public let DEFAULT_VISIBLE_RESPONSE_TOKENS: Int64 = 1024

@Derive[Equatable]
public enum ThinkingControlMode {
    NoThinking | Toggle | Effort | Budget | Adaptive
}

@Derive[Equatable]
public enum ThinkingPreferenceSource {
    ExplicitUser | ModePreference | ModelDefault
}

@Derive[Equatable]
public enum ResolutionConstraintTarget {
    OutputLimit | ThinkingLevel
}

@Derive[Equatable]
public enum ResolutionConstraintKind {
    ModelOutputLimit
    | EndpointOutputLimit
    | ModelSupportedLevel
    | AttemptRecoveryCeiling
    | AvailableThinkingBudget
}

@Derive[Equatable]
public enum ResolutionValue {
    TokenLimit(Int64) | ThinkingValue(ThinkingLevel)
}

public class ResolutionConstraint {
    public let target: ResolutionConstraintTarget
    public let kind: ResolutionConstraintKind
    public let before: ResolutionValue
    public let after: ResolutionValue

    public init(
        target: ResolutionConstraintTarget,
        kind: ResolutionConstraintKind,
        before: ResolutionValue,
        after: ResolutionValue
    ) {
        let valid = match ((target, kind, before, after)) {
            case (ResolutionConstraintTarget.OutputLimit,
                ResolutionConstraintKind.ModelOutputLimit,
                ResolutionValue.TokenLimit(left), ResolutionValue.TokenLimit(right)) =>
                left > 0 && right > 0 && left != right
            case (ResolutionConstraintTarget.OutputLimit,
                ResolutionConstraintKind.EndpointOutputLimit,
                ResolutionValue.TokenLimit(left), ResolutionValue.TokenLimit(right)) =>
                left > 0 && right > 0 && left != right
            case (ResolutionConstraintTarget.ThinkingLevel,
                ResolutionConstraintKind.ModelSupportedLevel,
                ResolutionValue.ThinkingValue(left), ResolutionValue.ThinkingValue(right)) =>
                left != right
            case (ResolutionConstraintTarget.ThinkingLevel,
                ResolutionConstraintKind.AttemptRecoveryCeiling,
                ResolutionValue.ThinkingValue(left), ResolutionValue.ThinkingValue(right)) =>
                left != right
            case (ResolutionConstraintTarget.ThinkingLevel,
                ResolutionConstraintKind.AvailableThinkingBudget,
                ResolutionValue.ThinkingValue(left), ResolutionValue.ThinkingValue(right)) =>
                left != right
            case _ => false
        }
        if (!valid) {
            throw IllegalArgumentException("resolution constraint target or value is invalid")
        }
        this.target = target
        this.kind = kind
        this.before = before
        this.after = after
    }
}

public class ThinkingBudgetTier {
    public let level: ThinkingLevel
    public let budgetTokens: Int64

    public init(level: ThinkingLevel, budgetTokens: Int64) {
        if (level == ThinkingLevel.Off || budgetTokens < 1) {
            throw IllegalArgumentException("thinking budget tier is invalid")
        }
        this.level = level
        this.budgetTokens = budgetTokens
    }
}

public class ThinkingCapabilities {
    public let mode: ThinkingControlMode
    public let supportedLevels: Array<ThinkingLevel>
    public let budgetTiers: Array<ThinkingBudgetTier>

    public init(
        mode: ThinkingControlMode,
        supportedLevels!: Array<ThinkingLevel> = [],
        budgetTiers!: Array<ThinkingBudgetTier> = []
    ) {
        let normalizedLevels = match (mode) {
            case ThinkingControlMode.NoThinking =>
                if (!supportedLevels.isEmpty() || !budgetTiers.isEmpty()) {
                    throw IllegalArgumentException("none thinking capability cannot declare levels or budgets")
                }
                Array<ThinkingLevel>()
            case ThinkingControlMode.Toggle =>
                if (!supportedLevels.isEmpty() || !budgetTiers.isEmpty()) {
                    throw IllegalArgumentException("toggle thinking capability has no effort granularity")
                }
                canonicalNonOffThinkingLevels()
            case ThinkingControlMode.Budget | ThinkingControlMode.Effort =>
                requireCanonicalSupportedLevels(supportedLevels)
                supportedLevels
            case ThinkingControlMode.Adaptive =>
                if (!supportedLevels.isEmpty()) {
                    requireCanonicalSupportedLevels(supportedLevels)
                }
                if (!budgetTiers.isEmpty()) {
                    throw IllegalArgumentException("adaptive thinking capability cannot declare token budgets")
                }
                supportedLevels
        }
        let normalizedBudgets = match (mode) {
            case ThinkingControlMode.Budget =>
                let values = if (budgetTiers.isEmpty()) {
                    defaultThinkingBudgetTiers(normalizedLevels)
                } else {
                    budgetTiers
                }
                requireBudgetCoverage(normalizedLevels, values)
                values
            case _ =>
                if (!budgetTiers.isEmpty()) {
                    throw IllegalArgumentException("numeric thinking budgets require budget mode")
                }
                Array<ThinkingBudgetTier>()
        }
        this.mode = mode
        this.supportedLevels = normalizedLevels
        this.budgetTiers = normalizedBudgets
    }

    public func budgetFor(level: ThinkingLevel): ?Int64 {
        for (tier in budgetTiers where tier.level == level) {
            return Some(tier.budgetTokens)
        }
        None
    }
}

public class RequestOutputBudget {
    public let hardLimit: Int64
    public let minVisibleResponseTokens: Int64
    // Compatibility alias: this budget protects the complete Decision frame,
    // not merely user-visible prose.
    public let decisionReserveTokens: Int64

    public init(
        hardLimit: Int64,
        minVisibleResponseTokens!: Int64 = DEFAULT_VISIBLE_RESPONSE_TOKENS
    ) {
        if (hardLimit < 1 || minVisibleResponseTokens < 0) {
            throw IllegalArgumentException("request output budget is invalid")
        }
        this.hardLimit = hardLimit
        this.minVisibleResponseTokens = minVisibleResponseTokens
        this.decisionReserveTokens = minVisibleResponseTokens
    }
}

public class RequestedModelPolicy {
    public let userRequestedThinking: ?ThinkingLevel
    public let policyRequestedThinking: ThinkingLevel
    public let thinkingSource: ThinkingPreferenceSource
    public let requestOutputBudget: RequestOutputBudget

    public init(
        policyRequestedThinking: ThinkingLevel,
        requestOutputBudget: RequestOutputBudget,
        userRequestedThinking!: ?ThinkingLevel = None,
        thinkingSource!: ThinkingPreferenceSource = ThinkingPreferenceSource.ModelDefault
    ) {
        this.userRequestedThinking = userRequestedThinking
        this.policyRequestedThinking = policyRequestedThinking
        this.thinkingSource = thinkingSource
        this.requestOutputBudget = requestOutputBudget
    }
}

public class ModelExecutionCapabilitiesSnapshot {
    public let snapshotSchemaVersion: UInt32
    public let modelId: String
    public let thinking: ThinkingCapabilities
    public let modelMaxOutputTokens: Int64
    public let endpointMaxOutputTokens: ?Int64
    public let capabilityFingerprint: String

    public init(
        modelId: String,
        thinking: ThinkingCapabilities,
        modelMaxOutputTokens: Int64,
        endpointMaxOutputTokens!: ?Int64 = None,
        capabilityFingerprint!: String = "",
        snapshotSchemaVersion!: UInt32 = MODEL_CAPABILITY_SNAPSHOT_VERSION
    ) {
        if (modelId.trimAscii() == "" || modelMaxOutputTokens < 1 ||
            match (endpointMaxOutputTokens) {
                case Some(value) => value < 1
                case None => false
            }) {
            throw IllegalArgumentException("model execution capability snapshot is invalid")
        }
        this.snapshotSchemaVersion = snapshotSchemaVersion
        this.modelId = modelId
        this.thinking = thinking
        this.modelMaxOutputTokens = modelMaxOutputTokens
        this.endpointMaxOutputTokens = endpointMaxOutputTokens
        let normalizedFingerprint = modelCapabilitySnapshotFingerprint(
            snapshotSchemaVersion,
            modelId,
            thinking,
            modelMaxOutputTokens,
            endpointMaxOutputTokens
        )
        if (capabilityFingerprint != "" && capabilityFingerprint != normalizedFingerprint) {
            throw IllegalArgumentException("model capability snapshot fingerprint mismatch")
        }
        this.capabilityFingerprint = normalizedFingerprint
    }
}

public class AttemptPolicyInput {
    public let requestedPolicy: RequestedModelPolicy
    public let capabilities: ModelExecutionCapabilitiesSnapshot
    public let recoveryCeiling: ?ThinkingLevel
    public let resolverVersion: UInt32

    public init(
        requestedPolicy: RequestedModelPolicy,
        capabilities: ModelExecutionCapabilitiesSnapshot,
        recoveryCeiling!: ?ThinkingLevel = None,
        resolverVersion!: UInt32 = MODEL_POLICY_RESOLUTION_VERSION
    ) {
        this.requestedPolicy = requestedPolicy
        this.capabilities = capabilities
        this.recoveryCeiling = recoveryCeiling
        this.resolverVersion = resolverVersion
    }
}

public class OutputLimitResolution {
    public let requestedHardLimit: Int64
    public let effectiveWireLimit: Int64
    public let constraints: Array<ResolutionConstraint>

    public init(
        requestedHardLimit: Int64,
        effectiveWireLimit: Int64,
        constraints!: Array<ResolutionConstraint> = []
    ) {
        this.requestedHardLimit = requestedHardLimit
        this.effectiveWireLimit = effectiveWireLimit
        this.constraints = constraints
    }
}

public class ThinkingResolution {
    public let requested: ThinkingLevel
    public let effective: ThinkingLevel
    public let mode: ThinkingControlMode
    public let budgetTokens: ?Int64
    public let adaptiveEffort: ?ThinkingLevel
    public let constraints: Array<ResolutionConstraint>

    public init(
        requested: ThinkingLevel,
        effective: ThinkingLevel,
        mode: ThinkingControlMode,
        budgetTokens!: ?Int64 = None,
        adaptiveEffort!: ?ThinkingLevel = None,
        constraints!: Array<ResolutionConstraint> = []
    ) {
        this.requested = requested
        this.effective = effective
        this.mode = mode
        this.budgetTokens = budgetTokens
        this.adaptiveEffort = adaptiveEffort
        this.constraints = constraints
    }
}

public class ResolvedModelRequestPolicy {
    public let thinking: ThinkingResolution
    public let output: OutputLimitResolution
    public let policyResolutionVersion: UInt32
    public let capabilitySnapshotVersion: UInt32
    public let capabilityFingerprint: String
    public let capabilitySnapshotPayload: String
    public let minVisibleResponseTokens: Int64
    public let decisionReserveTokens: Int64
    public let thinkingSource: ThinkingPreferenceSource
    public let userRequestedThinking: ?ThinkingLevel

    public init(
        thinking: ThinkingResolution,
        output: OutputLimitResolution,
        policyResolutionVersion!: UInt32 = MODEL_POLICY_RESOLUTION_VERSION,
        capabilitySnapshotVersion!: UInt32 = MODEL_CAPABILITY_SNAPSHOT_VERSION,
        capabilityFingerprint!: String = "",
        capabilitySnapshotPayload!: String = "",
        minVisibleResponseTokens!: Int64 = DEFAULT_VISIBLE_RESPONSE_TOKENS,
        thinkingSource!: ThinkingPreferenceSource = ThinkingPreferenceSource.ModelDefault,
        userRequestedThinking!: ?ThinkingLevel = None
    ) {
        this.thinking = thinking
        this.output = output
        this.policyResolutionVersion = policyResolutionVersion
        this.capabilitySnapshotVersion = capabilitySnapshotVersion
        this.capabilityFingerprint = capabilityFingerprint
        this.capabilitySnapshotPayload = capabilitySnapshotPayload
        this.minVisibleResponseTokens = minVisibleResponseTokens
        this.decisionReserveTokens = minVisibleResponseTokens
        this.thinkingSource = thinkingSource
        this.userRequestedThinking = userRequestedThinking
    }
}

public func resolveModelAttemptPolicy(
    input: AttemptPolicyInput
): Result<ResolvedModelRequestPolicy> {
    if (input.resolverVersion != MODEL_POLICY_RESOLUTION_VERSION) {
        return Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.policy_resolution_version_unsupported",
            "model attempt policy resolver version is unsupported",
            fields: [ErrorField("version", input.resolverVersion.toString())]
        ))
    }
    let outputConstraints = ArrayList<ResolutionConstraint>()
    var wireLimit = input.requestedPolicy.requestOutputBudget.hardLimit
    if (input.capabilities.modelMaxOutputTokens < wireLimit) {
        outputConstraints.add(tokenConstraint(
            ResolutionConstraintKind.ModelOutputLimit,
            wireLimit,
            input.capabilities.modelMaxOutputTokens
        ))
        wireLimit = input.capabilities.modelMaxOutputTokens
    }
    match (input.capabilities.endpointMaxOutputTokens) {
        case Some(value) => if (value < wireLimit) {
            outputConstraints.add(tokenConstraint(
                ResolutionConstraintKind.EndpointOutputLimit,
                wireLimit,
                value
            ))
            wireLimit = value
        }
        case None => ()
    }
    let output = OutputLimitResolution(
        input.requestedPolicy.requestOutputBudget.hardLimit,
        wireLimit,
        constraints: outputConstraints.toArray()
    )
    let thinking = match (resolveAttemptThinking(input, wireLimit)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(ResolvedModelRequestPolicy(
        thinking,
        output,
        policyResolutionVersion: input.resolverVersion,
        capabilitySnapshotVersion: input.capabilities.snapshotSchemaVersion,
        capabilityFingerprint: input.capabilities.capabilityFingerprint,
        capabilitySnapshotPayload: canonicalModelCapabilitySnapshotPayload(
            input.capabilities.snapshotSchemaVersion,
            input.capabilities.modelId,
            input.capabilities.thinking,
            input.capabilities.modelMaxOutputTokens,
            input.capabilities.endpointMaxOutputTokens
        ),
        minVisibleResponseTokens: input.requestedPolicy.requestOutputBudget.minVisibleResponseTokens,
        thinkingSource: input.requestedPolicy.thinkingSource,
        userRequestedThinking: input.requestedPolicy.userRequestedThinking
    ))
}

func resolveAttemptThinking(
    input: AttemptPolicyInput,
    wireLimit: Int64
): Result<ThinkingResolution> {
    let requested = input.requestedPolicy.policyRequestedThinking
    let capabilities = input.capabilities.thinking
    if (requested == ThinkingLevel.Off) {
        return Result.Ok(ThinkingResolution(
            requested,
            ThinkingLevel.Off,
            capabilities.mode
        ))
    }
    if (capabilities.mode == ThinkingControlMode.NoThinking) {
        return incompatibleThinking(input, "model does not support thinking")
    }
    if (capabilities.mode == ThinkingControlMode.Toggle ||
        (capabilities.mode == ThinkingControlMode.Adaptive && capabilities.supportedLevels.isEmpty())) {
        return Result.Ok(ThinkingResolution(requested, requested, capabilities.mode))
    }
    let constraints = ArrayList<ResolutionConstraint>()
    var effective = match (highestSupportedAtMost(capabilities.supportedLevels, requested)) {
        case Some(value) => value
        case None => return incompatibleThinking(input, "no supported thinking level is compatible with the request")
    }
    if (effective != requested) {
        constraints.add(thinkingConstraint(
            ResolutionConstraintKind.ModelSupportedLevel,
            requested,
            effective
        ))
    }
    match (input.recoveryCeiling) {
        case Some(ThinkingLevel.Off) => if (effective != ThinkingLevel.Off) {
            let before = effective
            effective = ThinkingLevel.Off
            constraints.add(thinkingConstraint(
                ResolutionConstraintKind.AttemptRecoveryCeiling,
                before,
                effective
            ))
        }
        case Some(ceiling) => if (thinkingLevelRank(effective) > thinkingLevelRank(ceiling)) {
            let before = effective
            effective = match (highestSupportedAtMost(capabilities.supportedLevels, ceiling)) {
                case Some(value) => value
                case None => return incompatibleThinking(input, "attempt recovery ceiling excludes every supported level")
            }
            constraints.add(thinkingConstraint(
                ResolutionConstraintKind.AttemptRecoveryCeiling,
                before,
                effective
            ))
        }
        case None => ()
    }
    var budgetTokens: ?Int64 = None
    if (capabilities.mode == ThinkingControlMode.Budget && effective != ThinkingLevel.Off) {
        let available = wireLimit - input.requestedPolicy.requestOutputBudget.minVisibleResponseTokens
        let budgetLevel = highestBudgetLevelAtMost(capabilities, effective, available)
        let selected = match (budgetLevel) {
            case Some(value) => value
            case None => return incompatibleThinking(input, "output budget cannot fit any compatible non-zero thinking level")
        }
        if (selected != effective) {
            constraints.add(thinkingConstraint(
                ResolutionConstraintKind.AvailableThinkingBudget,
                effective,
                selected
            ))
            effective = selected
        }
        budgetTokens = capabilities.budgetFor(effective)
    }
    Result.Ok(ThinkingResolution(
        requested,
        effective,
        capabilities.mode,
        budgetTokens: budgetTokens,
        adaptiveEffort: if (capabilities.mode == ThinkingControlMode.Adaptive) {
            Some(effective)
        } else {
            None
        },
        constraints: constraints.toArray()
    ))
}

// Select the next real model-supported recovery ceiling. Off is the final
// fail-closed step and is always available as the absence of thinking.
public func nextLowerThinkingCeiling(
    capabilities: ModelExecutionCapabilitiesSnapshot,
    effective: ThinkingLevel
): ?ThinkingLevel {
    if (effective == ThinkingLevel.Off) { return None }
    var candidate = ThinkingLevel.Off
    for (level in capabilities.thinking.supportedLevels where
        thinkingLevelRank(level) < thinkingLevelRank(effective)) {
        candidate = level
    }
    Some(candidate)
}

func incompatibleThinking(
    input: AttemptPolicyInput,
    message: String
): Result<ThinkingResolution> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "model.thinking_policy_incompatible",
        message,
        fields: [
            ErrorField("model", input.capabilities.modelId),
            ErrorField("requested", modelPolicyThinkingLevelName(
                input.requestedPolicy.policyRequestedThinking
            ))
        ]
    ))
}

func tokenConstraint(
    kind: ResolutionConstraintKind,
    before: Int64,
    after: Int64
): ResolutionConstraint {
    ResolutionConstraint(
        ResolutionConstraintTarget.OutputLimit,
        kind,
        ResolutionValue.TokenLimit(before),
        ResolutionValue.TokenLimit(after)
    )
}

func thinkingConstraint(
    kind: ResolutionConstraintKind,
    before: ThinkingLevel,
    after: ThinkingLevel
): ResolutionConstraint {
    ResolutionConstraint(
        ResolutionConstraintTarget.ThinkingLevel,
        kind,
        ResolutionValue.ThinkingValue(before),
        ResolutionValue.ThinkingValue(after)
    )
}

public func thinkingLevelRank(value: ThinkingLevel): Int64 {
    match (value) {
        case ThinkingLevel.Off => 0
        case ThinkingLevel.Minimal => 1
        case ThinkingLevel.Low => 2
        case ThinkingLevel.Medium => 3
        case ThinkingLevel.High => 4
        case ThinkingLevel.XHigh => 5
        case ThinkingLevel.Max => 6
    }
}

public func modelPolicyThinkingLevelName(value: ThinkingLevel): String {
    match (value) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

public func canonicalNonOffThinkingLevels(): Array<ThinkingLevel> {
    [
        ThinkingLevel.Minimal,
        ThinkingLevel.Low,
        ThinkingLevel.Medium,
        ThinkingLevel.High,
        ThinkingLevel.XHigh,
        ThinkingLevel.Max
    ]
}

public func defaultThinkingBudget(level: ThinkingLevel): Int64 {
    match (level) {
        case ThinkingLevel.Off => 0
        case ThinkingLevel.Minimal => 1024
        case ThinkingLevel.Low => 2048
        case ThinkingLevel.Medium => 8192
        case ThinkingLevel.High => 16384
        case ThinkingLevel.XHigh | ThinkingLevel.Max => 32768
    }
}

public func canonicalModelCapabilitySnapshotPayload(
    snapshotSchemaVersion: UInt32,
    modelId: String,
    thinking: ThinkingCapabilities,
    modelMaxOutputTokens: Int64,
    endpointMaxOutputTokens: ?Int64
): String {
    var result = "snapshot_schema_version=" + snapshotSchemaVersion.toString() + "\n"
    result += "model_id=" + modelId.size.toString() + ":" + modelId + "\n"
    result += "thinking_mode=" + thinkingControlModeCanonicalName(thinking.mode) + "\n"
    result += "supported_levels="
    for (level in thinking.supportedLevels) {
        result += thinkingLevelCanonicalName(level) + ","
    }
    result += "\nbudget_tiers="
    for (tier in thinking.budgetTiers) {
        result += thinkingLevelCanonicalName(tier.level) + ":" + tier.budgetTokens.toString() + ","
    }
    result += "\nmodel_max_output_tokens=" + modelMaxOutputTokens.toString() + "\n"
    result += "endpoint_max_output_tokens=" + match (endpointMaxOutputTokens) {
        case Some(value) => value.toString()
        case None => "-"
    } + "\n"
    result
}

public func canonicalResolvedModelRequestPolicy(value: ResolvedModelRequestPolicy): String {
    var result = "policy_resolution_version=" + value.policyResolutionVersion.toString() + "\n"
    result += "capability_snapshot_version=" + value.capabilitySnapshotVersion.toString() + "\n"
    result += "capability_fingerprint=" + value.capabilityFingerprint + "\n"
    result += "capability_snapshot_payload=" + value.capabilitySnapshotPayload.size.toString() +
        ":" + value.capabilitySnapshotPayload + "\n"
    result += "response_reserve=" + value.minVisibleResponseTokens.toString() + "\n"
    result += "thinking_source=" + thinkingPreferenceSourceCanonicalName(value.thinkingSource) + "\n"
    result += "user_requested_thinking=" + match (value.userRequestedThinking) {
        case Some(level) => thinkingLevelCanonicalName(level)
        case None => "-"
    } + "\n"
    result += "output=" + value.output.requestedHardLimit.toString() + ":" +
        value.output.effectiveWireLimit.toString() + "\n"
    for (constraint in value.output.constraints) {
        result += canonicalResolutionConstraint(constraint) + "\n"
    }
    result += "thinking=" + thinkingLevelCanonicalName(value.thinking.requested) + ":" +
        thinkingLevelCanonicalName(value.thinking.effective) + ":" +
        thinkingControlModeCanonicalName(value.thinking.mode) + ":" +
        match (value.thinking.budgetTokens) {
            case Some(tokens) => tokens.toString()
            case None => "-"
        } + ":" + match (value.thinking.adaptiveEffort) {
            case Some(level) => thinkingLevelCanonicalName(level)
            case None => "-"
        } + "\n"
    for (constraint in value.thinking.constraints) {
        result += canonicalResolutionConstraint(constraint) + "\n"
    }
    result
}

func thinkingPreferenceSourceCanonicalName(value: ThinkingPreferenceSource): String {
    match (value) {
        case ThinkingPreferenceSource.ExplicitUser => "explicit_user"
        case ThinkingPreferenceSource.ModePreference => "mode_preference"
        case ThinkingPreferenceSource.ModelDefault => "model_default"
    }
}

func canonicalResolutionConstraint(value: ResolutionConstraint): String {
    let target = match (value.target) {
        case ResolutionConstraintTarget.OutputLimit => "output"
        case ResolutionConstraintTarget.ThinkingLevel => "thinking"
    }
    let kind = match (value.kind) {
        case ResolutionConstraintKind.ModelOutputLimit => "model_output"
        case ResolutionConstraintKind.EndpointOutputLimit => "endpoint_output"
        case ResolutionConstraintKind.ModelSupportedLevel => "model_level"
        case ResolutionConstraintKind.AttemptRecoveryCeiling => "recovery"
        case ResolutionConstraintKind.AvailableThinkingBudget => "budget"
    }
    target + ":" + kind + ":" + canonicalResolutionValue(value.before) + ":" +
        canonicalResolutionValue(value.after)
}

func canonicalResolutionValue(value: ResolutionValue): String {
    match (value) {
        case ResolutionValue.TokenLimit(tokens) => tokens.toString()
        case ResolutionValue.ThinkingValue(level) => thinkingLevelCanonicalName(level)
    }
}

public func modelCapabilitySnapshotFingerprint(
    snapshotSchemaVersion: UInt32,
    modelId: String,
    thinking: ThinkingCapabilities,
    modelMaxOutputTokens: Int64,
    endpointMaxOutputTokens: ?Int64
): String {
    modelPolicySha256(canonicalModelCapabilitySnapshotPayload(
        snapshotSchemaVersion,
        modelId,
        thinking,
        modelMaxOutputTokens,
        endpointMaxOutputTokens
    ).toArray())
}

func thinkingControlModeCanonicalName(value: ThinkingControlMode): String {
    match (value) {
        case ThinkingControlMode.NoThinking => "none"
        case ThinkingControlMode.Toggle => "toggle"
        case ThinkingControlMode.Effort => "effort"
        case ThinkingControlMode.Budget => "budget"
        case ThinkingControlMode.Adaptive => "adaptive"
    }
}

func thinkingLevelCanonicalName(value: ThinkingLevel): String {
    match (value) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

public func modelPolicySha256(bytes: Array<Byte>): String {
    let constants: Array<UInt32> = [
        0x428a2f98u32,0x71374491u32,0xb5c0fbcfu32,0xe9b5dba5u32,0x3956c25bu32,0x59f111f1u32,0x923f82a4u32,0xab1c5ed5u32,
        0xd807aa98u32,0x12835b01u32,0x243185beu32,0x550c7dc3u32,0x72be5d74u32,0x80deb1feu32,0x9bdc06a7u32,0xc19bf174u32,
        0xe49b69c1u32,0xefbe4786u32,0x0fc19dc6u32,0x240ca1ccu32,0x2de92c6fu32,0x4a7484aau32,0x5cb0a9dcu32,0x76f988dau32,
        0x983e5152u32,0xa831c66du32,0xb00327c8u32,0xbf597fc7u32,0xc6e00bf3u32,0xd5a79147u32,0x06ca6351u32,0x14292967u32,
        0x27b70a85u32,0x2e1b2138u32,0x4d2c6dfcu32,0x53380d13u32,0x650a7354u32,0x766a0abbu32,0x81c2c92eu32,0x92722c85u32,
        0xa2bfe8a1u32,0xa81a664bu32,0xc24b8b70u32,0xc76c51a3u32,0xd192e819u32,0xd6990624u32,0xf40e3585u32,0x106aa070u32,
        0x19a4c116u32,0x1e376c08u32,0x2748774cu32,0x34b0bcb5u32,0x391c0cb3u32,0x4ed8aa4au32,0x5b9cca4fu32,0x682e6ff3u32,
        0x748f82eeu32,0x78a5636fu32,0x84c87814u32,0x8cc70208u32,0x90befffau32,0xa4506cebu32,0xbef9a3f7u32,0xc67178f2u32
    ]
    var state = [0x6a09e667u32,0xbb67ae85u32,0x3c6ef372u32,0xa54ff53au32,
        0x510e527fu32,0x9b05688cu32,0x1f83d9abu32,0x5be0cd19u32]
    let remainder = bytes.size % 64
    let zeros = if (remainder <= 55) { 55 - remainder } else { 119 - remainder }
    let paddedSize = bytes.size + 1 + zeros + 8
    let bitLength = UInt64(bytes.size).wrappingMul(8u64)
    var block: Int64 = 0
    while (block < paddedSize) {
        let words = Array<UInt32>(64, repeat: 0u32)
        for (index in 0..16) {
            let start = block + index * 4
            words[index] = (UInt32(modelPolicyShaPaddedByte(bytes,start,paddedSize,bitLength)) << 24) |
                (UInt32(modelPolicyShaPaddedByte(bytes,start+1,paddedSize,bitLength)) << 16) |
                (UInt32(modelPolicyShaPaddedByte(bytes,start+2,paddedSize,bitLength)) << 8) |
                UInt32(modelPolicyShaPaddedByte(bytes,start+3,paddedSize,bitLength))
        }
        for (index in 16..64) {
            let s0 = modelPolicyRotateRight(words[index-15],7u32) ^ modelPolicyRotateRight(words[index-15],18u32) ^ (words[index-15] >> 3)
            let s1 = modelPolicyRotateRight(words[index-2],17u32) ^ modelPolicyRotateRight(words[index-2],19u32) ^ (words[index-2] >> 10)
            words[index] = words[index-16].wrappingAdd(s0).wrappingAdd(words[index-7]).wrappingAdd(s1)
        }
        var a=state[0]; var b=state[1]; var c=state[2]; var d=state[3]
        var e=state[4]; var f=state[5]; var g=state[6]; var h=state[7]
        for (index in 0..64) {
            let big1=modelPolicyRotateRight(e,6u32)^modelPolicyRotateRight(e,11u32)^modelPolicyRotateRight(e,25u32)
            let t1=h.wrappingAdd(big1).wrappingAdd((e&f)^((!e)&g)).wrappingAdd(constants[index]).wrappingAdd(words[index])
            let big0=modelPolicyRotateRight(a,2u32)^modelPolicyRotateRight(a,13u32)^modelPolicyRotateRight(a,22u32)
            let t2=big0.wrappingAdd((a&b)^(a&c)^(b&c))
            h=g; g=f; f=e; e=d.wrappingAdd(t1); d=c; c=b; b=a; a=t1.wrappingAdd(t2)
        }
        state[0]=state[0].wrappingAdd(a); state[1]=state[1].wrappingAdd(b)
        state[2]=state[2].wrappingAdd(c); state[3]=state[3].wrappingAdd(d)
        state[4]=state[4].wrappingAdd(e); state[5]=state[5].wrappingAdd(f)
        state[6]=state[6].wrappingAdd(g); state[7]=state[7].wrappingAdd(h)
        block += 64
    }
    let hex=["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    var result=""
    for (word in state) { for (shift in [24u32,16u32,8u32,0u32]) {
        let value=Int64((word>>shift)&0xffu32); result += hex[value/16]+hex[value%16]
    }}
    result
}

public func modelPolicySha256Text(value: String): String {
    modelPolicySha256(value.toArray())
}

func modelPolicyShaPaddedByte(bytes:Array<Byte>,index:Int64,paddedSize:Int64,bitLength:UInt64):Byte {
    if (index < bytes.size) { return bytes[index] }
    if (index == bytes.size) { return 0x80u8 }
    if (index >= paddedSize-8) { return UInt8((bitLength >> UInt64((paddedSize-1-index)*8)) & 0xffu64) }
    0u8
}

func modelPolicyRotateRight(value:UInt32,distance:UInt32):UInt32 {
    (value>>distance)|(value<<(32u32-distance))
}

func defaultThinkingBudgetTiers(
    levels: Array<ThinkingLevel>
): Array<ThinkingBudgetTier> {
    let result = ArrayList<ThinkingBudgetTier>()
    for (level in levels) {
        result.add(ThinkingBudgetTier(level, defaultThinkingBudget(level)))
    }
    result.toArray()
}

func requireCanonicalSupportedLevels(levels: Array<ThinkingLevel>): Unit {
    if (levels.isEmpty()) {
        throw IllegalArgumentException("thinking capability must declare supported levels")
    }
    var previous: Int64 = 0
    for (level in levels) {
        let rank = thinkingLevelRank(level)
        if (rank < 1 || rank <= previous) {
            throw IllegalArgumentException("thinking levels must be unique and in canonical order")
        }
        previous = rank
    }
}

func requireBudgetCoverage(
    levels: Array<ThinkingLevel>,
    tiers: Array<ThinkingBudgetTier>
): Unit {
    if (levels.size != tiers.size) {
        throw IllegalArgumentException("thinking budgets must exactly cover supported levels")
    }
    var previousBudget: Int64 = 0
    for (index in 0..levels.size) {
        if (tiers[index].level != levels[index]) {
            throw IllegalArgumentException("thinking budgets must exactly cover supported levels in canonical order")
        }
        if (tiers[index].budgetTokens < previousBudget) {
            throw IllegalArgumentException("thinking budgets must be monotonically non-decreasing")
        }
        previousBudget = tiers[index].budgetTokens
    }
}

func highestSupportedAtMost(
    levels: Array<ThinkingLevel>,
    ceiling: ThinkingLevel
): ?ThinkingLevel {
    var result: ?ThinkingLevel = None
    for (level in levels where thinkingLevelRank(level) <= thinkingLevelRank(ceiling)) {
        result = Some(level)
    }
    result
}

func highestBudgetLevelAtMost(
    capabilities: ThinkingCapabilities,
    ceiling: ThinkingLevel,
    availableTokens: Int64
): ?ThinkingLevel {
    var result: ?ThinkingLevel = None
    for (tier in capabilities.budgetTiers where
        thinkingLevelRank(tier.level) <= thinkingLevelRank(ceiling) &&
        tier.budgetTokens <= availableTokens) {
        result = Some(tier.level)
    }
    result
}
