package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// This is frozen policy data, not plugin authority. Actual dispatch still needs
// the installed generation, operator HTTP grant and claimed Core Attempt.
public class HostNeutralModelPolicy {
    public let capabilities: ModelCapabilities
    public let endpointMaxOutput: ?Int64
    public let configurationDigest: String
    public init(capabilities: ModelCapabilities, endpointMaxOutput: ?Int64, configurationDigest: String) {
        this.capabilities = capabilities; this.endpointMaxOutput = endpointMaxOutput
        this.configurationDigest = configurationDigest
    }
}

public class HostModelConfiguration {
    public let namespace: String
    public let packageDigest: String
    public let policy: HostNeutralModelPolicy
    private let encodedMapping: String
    init(namespace: String, packageDigest: String, policy: HostNeutralModelPolicy, mapping: AgentValue) {
        this.namespace = namespace; this.packageDigest = packageDigest; this.policy = policy
        this.encodedMapping = mapping.stringify()
    }
    public func mapping(): AgentValue { parseUnifiedJson(encodedMapping) }
}

func modelConfigurationError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Configuration, code,
        if (code == "model.provider_mapping_migration_required") {
            "ModelProvider mappings require version 2 and explicit neutral capabilities; review the package's offline migration proposal"
        } else if (code == "model.provider_not_configured") {
            "Select an installed ModelProvider contribution in plugins/services.json"
        } else { "Invalid versioned ModelProvider configuration" }))
}

func neutralModelInteger(value: AgentValue, name: String): Int64 {
    let raw = value.field(name).getOrThrow()
    if (raw.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("expected neutral integer") }
    let number = Int64.parse(raw.asNumberText())
    if (number < 1 || number.toString() != raw.asNumberText()) {
        throw IllegalArgumentException("neutral integer exceeds policy bounds")
    }
    number
}
func neutralModelBoolean(value: AgentValue, name: String): Bool {
    let raw = value.field(name).getOrThrow()
    if (raw.unifiedKind != ValueKind.Boolean) { throw IllegalArgumentException("expected neutral boolean") }
    raw.asBool()
}
func neutralModelThinkingLevel(text: String): ThinkingLevel {
    match (text) {
        case "minimal" => ThinkingLevel.Minimal; case "low" => ThinkingLevel.Low
        case "medium" => ThinkingLevel.Medium; case "high" => ThinkingLevel.High
        case "xhigh" => ThinkingLevel.XHigh; case "max" => ThinkingLevel.Max
        case _ => throw IllegalArgumentException("invalid neutral thinking level")
    }
}

public func parseHostNeutralModelPolicy(value: AgentValue, digest: String): HostNeutralModelPolicy {
    if (!httpIntentDigest(digest) || !httpIntentExactFields(value, ["context_window", "max_output", "endpoint_max_output",
        "thinking", "tools", "parallel_tools", "images", "structured_output", "prompt_cache"])) {
        throw IllegalArgumentException("invalid neutral capability fields")
    }
    let context = neutralModelInteger(value, "context_window")
    let maximum = neutralModelInteger(value, "max_output")
    if (maximum > context) { throw IllegalArgumentException("output exceeds context") }
    let rawEndpoint = value.field("endpoint_max_output").getOrThrow()
    let endpoint: ?Int64 = if (rawEndpoint.unifiedKind == ValueKind.Null) { None }
        else { Some(neutralModelInteger(value, "endpoint_max_output")) }
    let raw = value.field("thinking").getOrThrow()
    if (!httpIntentExactFields(raw, ["mode", "levels", "tiers"])) { throw IllegalArgumentException("invalid thinking fields") }
    let mode = match (httpIntentText(raw, "mode")) {
        case "none" => ThinkingControlMode.NoThinking; case "toggle" => ThinkingControlMode.Toggle
        case "effort" => ThinkingControlMode.Effort; case "budget" => ThinkingControlMode.Budget
        case "adaptive" => ThinkingControlMode.Adaptive
        case _ => throw IllegalArgumentException("invalid neutral thinking mode")
    }
    let levels = ArrayList<ThinkingLevel>(); let tiers = ArrayList<ThinkingBudgetTier>()
    let rawLevels = raw.field("levels").getOrThrow(); let rawTiers = raw.field("tiers").getOrThrow()
    if (rawLevels.unifiedKind != ValueKind.List || rawTiers.unifiedKind != ValueKind.List ||
        rawLevels.items.size > 6 || rawTiers.items.size > 6) { throw IllegalArgumentException("thinking policy exceeds bounds") }
    for (level in rawLevels.items) {
        if (level.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("thinking level must be text") }
        levels.add(neutralModelThinkingLevel(level.text))
    }
    for (tier in rawTiers.items) {
        if (!httpIntentExactFields(tier, ["level", "tokens"])) { throw IllegalArgumentException("invalid thinking tier") }
        tiers.add(ThinkingBudgetTier(neutralModelThinkingLevel(httpIntentText(tier, "level")), neutralModelInteger(tier, "tokens")))
    }
    if (mode == ThinkingControlMode.Toggle) {
        let canonical = canonicalNonOffThinkingLevels()
        if (levels.size != canonical.size) { throw IllegalArgumentException("toggle must declare its normalized levels") }
        for (index in 0..canonical.size where levels[index] != canonical[index]) { throw IllegalArgumentException("toggle levels changed") }
    }
    // Numeric budgets are explicit; do not let the Domain's compatibility
    // constructor synthesize a default for a new operator mapping.
    if (mode == ThinkingControlMode.Budget && (tiers.isEmpty() || levels.size != tiers.size)) {
        throw IllegalArgumentException("explicit thinking budget coverage is required")
    }
    let thinking = ThinkingCapabilities(mode, supportedLevels: if (mode == ThinkingControlMode.Toggle) { [] } else { levels.toArray() },
        budgetTiers: tiers.toArray())
    let tools = neutralModelBoolean(value, "tools"); let parallel = neutralModelBoolean(value, "parallel_tools")
    if (parallel && !tools) { throw IllegalArgumentException("parallel tools require tool capability") }
    HostNeutralModelPolicy(ModelCapabilities(toolCalling: tools, parallelToolCalling: parallel,
        reasoning: mode != ThinkingControlMode.NoThinking, vision: neutralModelBoolean(value, "images"),
        structuredOutput: neutralModelBoolean(value, "structured_output"), promptCache: neutralModelBoolean(value, "prompt_cache"),
        contextWindowTokens: context, maxOutputTokens: maximum, thinking: Some(thinking)), endpoint, digest)
}

public func loadHostModelConfiguration(settingsRoot: String, model: String): Result<HostModelConfiguration> {
    if (!exists(Path(settingsRoot).join("plugins/services.json"))) { return modelConfigurationError("model.provider_not_configured") }
    let source = match (readHostPluginHttpConfiguration(settingsRoot)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        let root = parseUnifiedJson(source, maxBytes: HOST_PLUGIN_HTTP_CONFIGURATION_MAX_BYTES)
        let plugins = root.field("plugins").getOrThrow()
        if (plugins.unifiedKind != ValueKind.List || plugins.items.size > 64) { return modelConfigurationError("model.provider_mapping_invalid") }
        let digest = modelPolicySha256Text(source)
        var selected: ?HostModelConfiguration = None
        for (plugin in plugins.items) {
            let configuration = plugin.field("configuration").getOrThrow()
            match (configuration.field("model_providers")) {
                case None => ()
                case Some(mappings) =>
                    if (mappings.unifiedKind != ValueKind.List || mappings.items.size > 64) { return modelConfigurationError("model.provider_mapping_invalid") }
                    for (value in mappings.items) {
                        if (value.field("version").isNone() || value.field("capabilities").isNone()) {
                            return modelConfigurationError("model.provider_mapping_migration_required")
                        }
                        if (!httpIntentExactFields(value, ["version", "model", "contribution", "wire_model", "provider_id", "configuration", "credential_refs", "capabilities"]) ||
                            neutralModelInteger(value, "version") != 2) { return modelConfigurationError("model.provider_mapping_invalid") }
                        let policy = parseHostNeutralModelPolicy(value.field("capabilities").getOrThrow(), digest)
                        if (httpIntentText(value, "model") == model) {
                            if (selected.isSome()) { return modelConfigurationError("model.provider_mapping_invalid") }
                            selected = Some(HostModelConfiguration(httpIntentText(plugin, "namespace"),
                                httpIntentText(plugin, "package_digest"), policy, value))
                        }
                    }
            }
        }
        match (selected) { case Some(value) => Result.Ok(value); case None => modelConfigurationError("model.provider_not_configured") }
    } catch (_: Exception) { modelConfigurationError("model.provider_mapping_invalid") }
}

