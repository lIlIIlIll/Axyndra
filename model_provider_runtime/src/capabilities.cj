package model_provider_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func providerThinkingLevel(value: ThinkingLevel): String {
    match (value) { case ThinkingLevel.Off => "off"; case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"; case ThinkingLevel.Medium => "medium"; case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"; case ThinkingLevel.Max => "max" }
}
func providerThinkingLevel(value: String): ThinkingLevel {
    match (value) { case "off" => ThinkingLevel.Off; case "minimal" => ThinkingLevel.Minimal
        case "low" => ThinkingLevel.Low; case "medium" => ThinkingLevel.Medium; case "high" => ThinkingLevel.High
        case "xhigh" => ThinkingLevel.XHigh; case "max" => ThinkingLevel.Max
        case _ => throw IllegalArgumentException("invalid provider thinking level") }
}
func providerThinkingMode(value: ThinkingControlMode): String {
    match (value) { case ThinkingControlMode.NoThinking => "none"; case ThinkingControlMode.Toggle => "toggle"
        case ThinkingControlMode.Effort => "effort"; case ThinkingControlMode.Budget => "budget"
        case ThinkingControlMode.Adaptive => "adaptive" }
}
func providerThinkingMode(value: String): ThinkingControlMode {
    match (value) { case "none" => ThinkingControlMode.NoThinking; case "toggle" => ThinkingControlMode.Toggle
        case "effort" => ThinkingControlMode.Effort; case "budget" => ThinkingControlMode.Budget
        case "adaptive" => ThinkingControlMode.Adaptive
        case _ => throw IllegalArgumentException("invalid provider thinking mode") }
}
func modelProviderCapabilityValue(value: ModelExecutionCapabilitiesSnapshot): AgentValue {
    let encoded = objectValue([
        ValueField("schema_version", integerValue(Int64(value.snapshotSchemaVersion))),
        ValueField("model", textValue(value.modelId)),
        ValueField("mode", textValue(providerThinkingMode(value.thinking.mode))),
        ValueField("levels", listValue(value.thinking.supportedLevels.map { level => textValue(providerThinkingLevel(level)) })),
        ValueField("tiers", listValue(value.thinking.budgetTiers.map { tier => objectValue([
            ValueField("level", textValue(providerThinkingLevel(tier.level))), ValueField("tokens", integerValue(tier.budgetTokens))]) })),
        ValueField("max_output", integerValue(value.modelMaxOutputTokens)),
        ValueField("endpoint_max_output", match (value.endpointMaxOutputTokens) { case Some(n) => integerValue(n); case None => nullValue() }),
        ValueField("fingerprint", textValue(value.capabilityFingerprint))
    ])
    if (value.configurationDigest != "") { encoded.put("configuration_digest", textValue(value.configurationDigest)) }
    encoded
}

// A pure serialization projection for the independently built adapter. The
// typed object is checked against the host's existing canonical snapshot; it
// never resolves a model, changes an Attempt policy, or grants inference.
public func modelProviderBindingCapabilities(binding: AgentValue): ModelCapabilities {
    let value = providerField(binding, "execution_capabilities")
    if (value.field("configuration_digest").isSome()) {
        providerExact(value, ["schema_version", "model", "mode", "levels", "tiers", "max_output", "endpoint_max_output", "fingerprint", "configuration_digest"])
    } else { providerExact(value, ["schema_version", "model", "mode", "levels", "tiers", "max_output", "endpoint_max_output", "fingerprint"]) }
    let configurationDigest = match (value.field("configuration_digest")) {
        case None => ""; case Some(_) => providerText(value, "configuration_digest") }
    if (configurationDigest != "" && configurationDigest != providerText(binding, "configuration_digest")) {
        throw IllegalArgumentException("model capability configuration changed")
    }
    if (providerInt(value, "schema_version") != Int64(MODEL_CAPABILITY_SNAPSHOT_VERSION) ||
        providerText(value, "model") != providerText(binding, "model")) {
        throw IllegalArgumentException("model capability schema changed")
    }
    let rawLevels = providerField(value, "levels"); let rawTiers = providerField(value, "tiers")
    if (rawLevels.unifiedKind != ValueKind.List || rawTiers.unifiedKind != ValueKind.List ||
        rawLevels.items.size > 7 || rawTiers.items.size > 7) { throw IllegalArgumentException("invalid thinking bounds") }
    let levels = ArrayList<ThinkingLevel>(); let tiers = ArrayList<ThinkingBudgetTier>()
    for (level in rawLevels.items) { if (level.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("invalid level") }
        levels.add(providerThinkingLevel(level.text)) }
    for (tier in rawTiers.items) { providerExact(tier, ["level", "tokens"])
        tiers.add(ThinkingBudgetTier(providerThinkingLevel(providerText(tier, "level")), providerInt(tier, "tokens"))) }
    let mode = providerThinkingMode(providerText(value, "mode"))
    let thinking = ThinkingCapabilities(mode,
        supportedLevels: if (mode == ThinkingControlMode.Toggle) { [] } else { levels.toArray() }, budgetTiers: tiers.toArray())
    let endpoint = providerField(value, "endpoint_max_output")
    let maximum = providerInt(value, "max_output")
    let snapshot = ModelExecutionCapabilitiesSnapshot(providerText(value, "model"), thinking, maximum,
        endpointMaxOutputTokens: if (endpoint.unifiedKind == ValueKind.Null) { None }
            else { Some(providerInt(value, "endpoint_max_output")) }, configurationDigest: configurationDigest)
    if (canonicalAgentValue(modelProviderCapabilityValue(snapshot)) != canonicalAgentValue(value) ||
        snapshot.capabilityFingerprint != providerText(value, "fingerprint") ||
        canonicalModelCapabilitySnapshotPayload(snapshot.snapshotSchemaVersion, snapshot.modelId,
            snapshot.thinking, snapshot.modelMaxOutputTokens, snapshot.endpointMaxOutputTokens,
            configurationDigest: snapshot.configurationDigest) != providerText(binding, "capabilities")) {
        throw IllegalArgumentException("model capability fingerprint mismatch")
    }
    ModelCapabilities(toolCalling: providerBool(binding, "tools"), parallelToolCalling: providerBool(binding, "parallel_tools"),
        reasoning: thinking.mode != ThinkingControlMode.NoThinking, vision: providerBool(binding, "images"),
        structuredOutput: providerBool(binding, "structured_output"), promptCache: providerBool(binding, "prompt_cache"),
        contextWindowTokens: providerInt(binding, "context_window"), maxOutputTokens: maximum, thinking: Some(thinking))
}
