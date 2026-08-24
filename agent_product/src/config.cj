package agent_product

import agent_domain.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*

let productConfigLockSequence = AtomicInt64(0)

public class ProductSettings {
    public let model: String
    public let asyncEnabled: Bool
    public let theme: String

    public let approval: ProductApprovalSettings
    public let compaction: ProductCompactionSettings

    public init(
        model!: String = "",
        asyncEnabled!: Bool = true,
        theme!: String = "axyndra",
        approval!: ProductApprovalSettings = ProductApprovalSettings(),
        compaction!: ProductCompactionSettings = ProductCompactionSettings()
    ) {
        this.model = model
        this.asyncEnabled = asyncEnabled
        this.approval = approval
        this.compaction = compaction
        this.theme = if (theme.trimAscii() == "") {
            "axyndra"
        } else {
            theme.trimAscii().toAsciiLower()
        }
    }
}

// A typed scalar edit keeps callers out of the YAML rendering details while
// still allowing every config writer to share the same lossless mutation
// path. Dotted keys address mapping members (for example async.enabled).
public enum ProductConfigScalar {
    Text(String) | Boolean(Bool) | Integer(Int64)
}

public class ProductConfigEdit {
    public let key: String
    public let value: ProductConfigScalar

    public init(key: String, value: ProductConfigScalar) {
        if (key.trimAscii() == "") {
            throw IllegalArgumentException("product config edit key must not be empty")
        }
        this.key = key.trimAscii()
        this.value = value
    }
}

public class ProductModelCompactionSettings {
    public let model: String
    public let maxInputTokens: ?Int64
    public let triggerPercent: ?Int64
    public let targetPercent: ?Int64

    public init(
        model: String,
        maxInputTokens!: ?Int64 = None,
        triggerPercent!: ?Int64 = None,
        targetPercent!: ?Int64 = None
    ) {
        let normalized = model.trimAscii()
        if (normalized == "") {
            throw IllegalArgumentException("compaction model ID must not be empty")
        }
        if (maxInputTokens.isNone() && triggerPercent.isNone() && targetPercent.isNone()) {
            throw IllegalArgumentException("compaction model override must define at least one watermark field")
        }
        match (maxInputTokens) {
            case Some(value) =>
                if (value < 1) {
                    throw IllegalArgumentException("compaction model max_input_tokens must be positive")
                }
            case None => ()
        }
        match (triggerPercent) {
            case Some(value) =>
                if (value < 1 || value > 100) {
                    throw IllegalArgumentException("compaction model trigger_percent must be between 1 and 100")
                }
            case None => ()
        }
        match (targetPercent) {
            case Some(value) =>
                if (value < 1 || value > 100) {
                    throw IllegalArgumentException("compaction model target_percent must be between 1 and 100")
                }
            case None => ()
        }
        this.model = normalized
        this.maxInputTokens = maxInputTokens
        this.triggerPercent = triggerPercent
        this.targetPercent = targetPercent
    }
}

public class ProductCompactionSettings {
    public let enabled: Bool
    public let maxInputTokens: Int64
    public let requestMaxMessages: Int64
    public let triggerPercent: Int64
    public let targetPercent: Int64
    public let emergencyMaxMessages: Int64
    public let keepRecentTokens: Int64
    public let keepRecentMessages: Int64
    public let oversizedToolResultTokens: Int64
    public let summaryStrategy: String
    public let summaryModel: String
    public let summaryTimeoutMillis: Int64
    public let summaryMaxOutputTokens: Int64
    public let summaryFailurePolicy: String
    public let modelOverrides: Array<ProductModelCompactionSettings>

    public init(
        enabled!: Bool = true,
        maxInputTokens!: Int64 = 100000,
        requestMaxMessages!: Int64 = 24,
        triggerPercent!: Int64 = 88,
        targetPercent!: Int64 = 60,
        emergencyMaxMessages!: Int64 = 512,
        keepRecentTokens!: Int64 = 50000,
        keepRecentMessages!: Int64 = 12,
        oversizedToolResultTokens!: Int64 = 12000,
        summaryStrategy!: String = "structured",
        summaryModel!: String = "",
        summaryTimeoutMillis!: Int64 = 5000,
        summaryMaxOutputTokens!: Int64 = 800,
        summaryFailurePolicy!: String = "fallback_structured",
        modelOverrides!: Array<ProductModelCompactionSettings> = []
    ) {
        if (maxInputTokens < 1 || requestMaxMessages < 0 || triggerPercent < 1 || triggerPercent > 100 ||
            targetPercent < 1 || targetPercent >= triggerPercent || emergencyMaxMessages < 1 ||
            keepRecentTokens < 1 || keepRecentMessages < 1 || oversizedToolResultTokens < 64 ||
            summaryTimeoutMillis < 1 || summaryTimeoutMillis > 60000 || summaryMaxOutputTokens < 1 ||
            summaryMaxOutputTokens > 4096) {
            throw IllegalArgumentException("compaction settings are out of range")
        }
        if (summaryStrategy != "structured" && summaryStrategy != "hybrid") {
            throw IllegalArgumentException("compaction.summary_strategy must be structured or hybrid")
        }
        if (summaryFailurePolicy != "fallback_structured") {
            throw IllegalArgumentException("compaction.summary_failure_policy must be fallback_structured")
        }
        let models = ArrayList<String>()
        for (modelSettings in modelOverrides) {
            if (containsString(models, modelSettings.model)) {
                throw IllegalArgumentException("duplicate compaction model override: " + modelSettings.model)
            }
            models.add(modelSettings.model)
            let resolvedTrigger = optionalInt64Or(modelSettings.triggerPercent, triggerPercent)
            let resolvedTarget = optionalInt64Or(modelSettings.targetPercent, targetPercent)
            if (resolvedTarget >= resolvedTrigger) {
                throw IllegalArgumentException(
                    "compaction model target_percent must be lower than trigger_percent: " + modelSettings.model
                )
            }
        }
        this.enabled = enabled
        this.maxInputTokens = maxInputTokens
        this.requestMaxMessages = requestMaxMessages
        this.triggerPercent = triggerPercent
        this.targetPercent = targetPercent
        this.emergencyMaxMessages = emergencyMaxMessages
        this.keepRecentTokens = keepRecentTokens
        this.keepRecentMessages = keepRecentMessages
        this.oversizedToolResultTokens = oversizedToolResultTokens
        this.summaryStrategy = summaryStrategy
        this.summaryModel = summaryModel.trimAscii()
        this.summaryTimeoutMillis = summaryTimeoutMillis
        this.summaryMaxOutputTokens = summaryMaxOutputTokens
        this.summaryFailurePolicy = summaryFailurePolicy
        this.modelOverrides = modelOverrides
    }

    // Model IDs are the full request IDs (for example provider-profile/model).
    // Missing fields inherit the product-wide defaults above.
    public func resolvedForModel(model: String): ProductCompactionSettings {
        let selected = model.trimAscii()
        for (modelSettings in modelOverrides where modelSettings.model == selected) {
            return ProductCompactionSettings(
                enabled: enabled,
                maxInputTokens: optionalInt64Or(modelSettings.maxInputTokens, maxInputTokens),
                requestMaxMessages: requestMaxMessages,
                triggerPercent: optionalInt64Or(modelSettings.triggerPercent, triggerPercent),
                targetPercent: optionalInt64Or(modelSettings.targetPercent, targetPercent),
                emergencyMaxMessages: emergencyMaxMessages,
                keepRecentTokens: keepRecentTokens,
                keepRecentMessages: keepRecentMessages,
                oversizedToolResultTokens: oversizedToolResultTokens,
                summaryStrategy: summaryStrategy,
                summaryModel: summaryModel,
                summaryTimeoutMillis: summaryTimeoutMillis,
                summaryMaxOutputTokens: summaryMaxOutputTokens,
                summaryFailurePolicy: summaryFailurePolicy
            )
        }
        this
    }
}

func optionalInt64Or(value: ?Int64, fallback: Int64): Int64 {
    match (value) {
        case Some(resolved) => resolved
        case None => fallback
    }
}

public class ProductApprovalSettings {
    public let mode: ApprovalRoutingMode
    public let failurePolicy: ApprovalFailurePolicy
    public let timeoutMillis: Int64
    public let logDecisions: Bool
    public let reviewerModel: String
    public let reasoning: ThinkingLevel
    public let allowWorkspaceWrites: Bool
    public let askOnNetwork: Bool
    public let askOnOutsideWorkspaceWrite: Bool
    public let askOnDestructiveCommands: Bool

    public init(
        mode!: ApprovalRoutingMode = ApprovalRoutingMode.Manual,
        failurePolicy!: ApprovalFailurePolicy = ApprovalFailurePolicy.AskUser,
        timeoutMillis!: Int64 = 30000,
        logDecisions!: Bool = true,
        reviewerModel!: String = "",
        reasoning!: ThinkingLevel = ThinkingLevel.Medium,
        allowWorkspaceWrites!: Bool = true,
        askOnNetwork!: Bool = true,
        askOnOutsideWorkspaceWrite!: Bool = true,
        askOnDestructiveCommands!: Bool = true
    ) {
        if (timeoutMillis < 1) {
            throw IllegalArgumentException("approval.timeout_ms must be positive")
        }
        this.mode = mode
        this.failurePolicy = failurePolicy
        this.timeoutMillis = timeoutMillis
        this.logDecisions = logDecisions
        this.reviewerModel = reviewerModel.trimAscii()
        this.reasoning = reasoning
        this.allowWorkspaceWrites = allowWorkspaceWrites
        this.askOnNetwork = askOnNetwork
        this.askOnOutsideWorkspaceWrite = askOnOutsideWorkspaceWrite
        this.askOnDestructiveCommands = askOnDestructiveCommands
    }
}

public class ProviderProfile {
    public let id: String
    public let provider: String
    public let protocol: String
    public let baseUrl: String
    public let apiKeyEnv: String
    public let authentication: String
    public let timeoutMillis: Int64
    public let dialect: String
    public let endpointMaxOutputTokens: ?Int64

    public init(
        id: String,
        provider: String,
        protocol: String,
        baseUrl: String,
        apiKeyEnv: String,
        authentication!: String = "api-key",
        timeoutMillis!: Int64 = 120000,
        dialect!: String = "",
        endpointMaxOutputTokens!: ?Int64 = None
    ) {
        if (id.trimAscii() == "" || provider.trimAscii() == "" || protocol.trimAscii() == "" || baseUrl.trimAscii() == "") {
            throw IllegalArgumentException("provider profile fields must not be empty")
        }
        if (authentication != "api-key" && authentication != "oauth") {
            throw IllegalArgumentException("provider profile authentication must be api-key or oauth")
        }
        if (authentication == "api-key" && apiKeyEnv.trimAscii() == "") {
            throw IllegalArgumentException("API-key provider profile requires api_key_env")
        }
        if (!isSafeProfileId(id)) {
            throw IllegalArgumentException("provider profile ID may contain letters, digits, '-' and '_'")
        }
        if (protocol != "messages" && protocol != "responses" && protocol != "completions" && protocol !=
            "chat-completions") {
            throw IllegalArgumentException("provider profile protocol must be messages, responses, or completions")
        }
        if (!secureProviderProfileUrl(baseUrl)) {
            throw IllegalArgumentException(
                "provider profile base URL must use HTTPS or loopback HTTP"
            )
        }
        if (timeoutMillis < 1) {
            throw IllegalArgumentException("provider profile timeout must be positive")
        }
        if (dialect != "" && dialect != "anthropic_messages" &&
            dialect != "deepseek_messages" && dialect != "openai_responses" &&
            dialect != "openai_chat" && dialect != "generic_messages" &&
            dialect != "generic_chat") {
            throw IllegalArgumentException("unknown provider profile dialect")
        }
        if ((dialect.endsWith("_messages") && protocol != "messages") ||
            (dialect == "openai_responses" && protocol != "responses") ||
            ((dialect == "openai_chat" || dialect == "generic_chat") &&
                protocol != "completions" && protocol != "chat-completions")) {
            throw IllegalArgumentException("provider dialect is incompatible with protocol")
        }
        if (match (endpointMaxOutputTokens) {
            case Some(value) => value < 1
            case None => false
        }) {
            throw IllegalArgumentException("provider endpoint output limit must be positive")
        }
        this.id = id
        this.provider = provider
        this.protocol = protocol
        this.baseUrl = baseUrl.removeSuffix("/")
        this.apiKeyEnv = apiKeyEnv
        this.authentication = authentication
        this.timeoutMillis = timeoutMillis
        this.dialect = dialect
        this.endpointMaxOutputTokens = endpointMaxOutputTokens
    }
}

func secureProviderProfileUrl(value: String): Bool {
    if (value.startsWith("https://")) {
        let authority = providerProfileUrlAuthority(value, "https://")
        return authority != "" && authority.trimAscii() == authority &&
            authority.indexOf("@").isNone()
    }
    if (!value.startsWith("http://")) { return false }
    providerProfileLoopbackAuthority(
        providerProfileUrlAuthority(value, "http://")
    )
}

func providerProfileUrlAuthority(value: String, prefix: String): String {
    let remainder = value[prefix.size..]
    var end = remainder.size
    for (separator in ["/", "?", "#"]) {
        match (remainder.indexOf(separator)) {
            case Some(index) => end = min(end, index)
            case None => ()
        }
    }
    remainder[..end]
}

func providerProfileLoopbackAuthority(authority: String): Bool {
    if (authority == "127.0.0.1" || authority == "localhost" || authority == "[::1]") {
        return true
    }
    for (host in ["127.0.0.1", "localhost", "[::1]"]) {
        let prefix = host + ":"
        if (authority.startsWith(prefix) &&
            providerProfileAsciiDecimal(authority[prefix.size..])) {
            return true
        }
    }
    false
}

func providerProfileAsciiDecimal(value: String): Bool {
    if (value == "") { return false }
    for (byte in unsafe { value.rawData() }) {
        if (byte < b'0' || byte > b'9') { return false }
    }
    true
}

public class ModelCatalogEntry {
    public let id: String
    public let providerProfile: String
    public let contextWindow: ?Int64
    public let maxOutputTokens: ?Int64
    public let thinking: ?ThinkingCapabilities
    public let structuredOutput: ?Bool
    public let promptCache: ?Bool
    public let inputModalities: ?Array<String>
    public let outputModalities: ?Array<String>
    public let inputCostMicrosPerMillion: ?Int64
    public let outputCostMicrosPerMillion: ?Int64
    public let cacheReadCostMicrosPerMillion: ?Int64
    public let cacheWriteCostMicrosPerMillion: ?Int64
    public let fastServiceTier: String

    public init(
        id: String,
        providerProfile!: String = "",
        contextWindow!: ?Int64 = None,
        maxOutputTokens!: ?Int64 = None,
        thinking!: ?ThinkingCapabilities = None,
        structuredOutput!: ?Bool = None,
        promptCache!: ?Bool = None,
        inputModalities!: ?Array<String> = None,
        outputModalities!: ?Array<String> = None,
        inputCostMicrosPerMillion!: ?Int64 = None,
        outputCostMicrosPerMillion!: ?Int64 = None,
        cacheReadCostMicrosPerMillion!: ?Int64 = None,
        cacheWriteCostMicrosPerMillion!: ?Int64 = None,
        fastServiceTier!: String = ""
    ) {
        if (id.trimAscii() == "") {
            throw IllegalArgumentException("model id must not be empty")
        }
        if (providerProfile != "" && !isSafeProfileId(providerProfile)) {
            throw IllegalArgumentException("model provider profile ID is invalid")
        }
        for (value in [contextWindow, maxOutputTokens]) {
            match (value) {
                case Some(number) => if (number < 1) {
                    throw IllegalArgumentException("model token limits must be positive")
                }
                case None => ()
            }
        }
        match ((contextWindow, maxOutputTokens)) {
            case (Some(window), Some(output)) =>
                if (output > window) {
                    throw IllegalArgumentException(
                        "model max output tokens must not exceed its context window"
                    )
                }
            case _ => ()
        }
        for (value in [
            inputCostMicrosPerMillion,
            outputCostMicrosPerMillion,
            cacheReadCostMicrosPerMillion,
            cacheWriteCostMicrosPerMillion
        ]) {
            match (value) {
                case Some(number) => if (number < 0) {
                    throw IllegalArgumentException("model costs must not be negative")
                }
                case None => ()
            }
        }
        validateModelModalities(inputModalities, "input")
        validateModelModalities(outputModalities, "output")
        if (fastServiceTier != "" && fastServiceTier != "auto" &&
            fastServiceTier != "default" && fastServiceTier != "flex" &&
            fastServiceTier != "scale" && fastServiceTier != "priority") {
            throw IllegalArgumentException("model fast service tier is invalid")
        }
        this.id = id
        this.providerProfile = providerProfile
        this.contextWindow = contextWindow
        this.maxOutputTokens = maxOutputTokens
        this.thinking = thinking
        this.structuredOutput = structuredOutput
        this.promptCache = promptCache
        this.inputModalities = inputModalities
        this.outputModalities = outputModalities
        this.inputCostMicrosPerMillion = inputCostMicrosPerMillion
        this.outputCostMicrosPerMillion = outputCostMicrosPerMillion
        this.cacheReadCostMicrosPerMillion = cacheReadCostMicrosPerMillion
        this.cacheWriteCostMicrosPerMillion = cacheWriteCostMicrosPerMillion
        this.fastServiceTier = fastServiceTier
    }

    public func displayId(): String {
        if (providerProfile == "") {
            id
        } else {
            providerProfile + "/" + id
        }
    }

    public func pricing(): ?ModelPricing {
        if (inputCostMicrosPerMillion.isNone() &&
            outputCostMicrosPerMillion.isNone() &&
            cacheReadCostMicrosPerMillion.isNone() &&
            cacheWriteCostMicrosPerMillion.isNone()) {
            return None
        }
        Some(ModelPricing(
            inputMicrosPerMillion: inputCostMicrosPerMillion,
            outputMicrosPerMillion: outputCostMicrosPerMillion,
            cacheReadMicrosPerMillion: cacheReadCostMicrosPerMillion,
            cacheWriteMicrosPerMillion: cacheWriteCostMicrosPerMillion
        ))
    }
}

// Configuration creation must persist capabilities explicitly so runtime
// routing never guesses them from provider names or endpoint URLs.
public func configuredThinkingForDialect(dialect: String): ThinkingCapabilities {
    match (dialect) {
        case "deepseek_messages" => ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: [
                ThinkingLevel.Low,
                ThinkingLevel.Medium,
                ThinkingLevel.High,
                ThinkingLevel.XHigh,
                ThinkingLevel.Max
            ]
        )
        case "anthropic_messages" => ThinkingCapabilities(
            ThinkingControlMode.Budget,
            supportedLevels: canonicalNonOffThinkingLevels()
        )
        case "openai_responses" | "openai_chat" => ThinkingCapabilities(
            ThinkingControlMode.Effort,
            supportedLevels: canonicalNonOffThinkingLevels()
        )
        case _ => ThinkingCapabilities(ThinkingControlMode.NoThinking)
    }
}

public func configuredDialectForSetup(
    provider: String,
    protocol: String,
    baseUrl: String
): String {
    let endpoint = baseUrl.trimAscii().toAsciiLower().removeSuffix("/")
    if (provider == "anthropic" && protocol == "messages" &&
        (endpoint == "https://api.deepseek.com/anthropic" ||
            endpoint == "https://api.deepseek.com/anthropic/v1")) {
        "deepseek_messages"
    } else if (provider == "anthropic" && protocol == "messages" &&
        (endpoint == "https://api.anthropic.com" ||
            endpoint == "https://api.anthropic.com/v1")) {
        "anthropic_messages"
    } else if (provider == "openai" && protocol == "responses") {
        "openai_responses"
    } else if (provider == "openai" &&
        (protocol == "completions" || protocol == "chat-completions")) {
        "openai_chat"
    } else if (protocol == "messages") {
        "generic_messages"
    } else if (protocol == "responses") {
        "openai_responses"
    } else {
        "generic_chat"
    }
}

func validateModelModalities(
    values: ?Array<String>,
    label: String
): Unit {
    match (values) {
        case Some(items) =>
            if (items.isEmpty()) {
                throw IllegalArgumentException("model " + label + " modalities must not be empty")
            }
            let seen = HashSet<String>()
            for (item in items) {
                let normalized = item.trimAscii()
                if (normalized == "" || seen.contains(normalized)) {
                    throw IllegalArgumentException("model " + label + " modalities are invalid")
                }
                seen.add(normalized)
            }
        case None => ()
    }
}

public func loadProductSettings(root: String): Result<ProductSettings> {
    let path = root + "/config.yml"
    if (!exists(Path(path))) {
        return Result.Ok(ProductSettings())
    }
    try {
        let source = String.fromUtf8(File.readFrom(path))
        validateProductConfigKeys(source)
        Result.Ok(
            ProductSettings(
                model: topLevelSetting(source, "default_model"),
                asyncEnabled: parseAsyncEnabled(source),
                theme: topLevelSetting(source, "theme"),
                approval: parseApprovalSettings(source),
                compaction: parseCompactionSettings(source)
            )
        )
    } catch (error: Exception) {
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "config.invalid",
                "cannot read product configuration: " + error.message,
                fields: [ErrorField("path", path)]
            )
        )
    }
}

// Apply all edits as one read/validate/patch/write transaction. The source is
// deliberately re-read after the inter-process lock is acquired: callers may
// have inspected an older ProductSettings snapshot before reaching this
// function, but that snapshot must never be used to rewrite unrelated keys.
public func updateProductConfig(
    root: String,
    edits: Array<ProductConfigEdit>
): Result<Unit> {
    if (edits.isEmpty()) {
        return Result.Ok(())
    }
    match (ensureProductLayout(root)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let lock = ProductConfigFileLock(root)
    match (lock.acquire()) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let path = root + "/config.yml"
        let source = try {
            if (exists(Path(path))) {
                String.fromUtf8(File.readFrom(path))
            } else {
                ""
            }
        } catch (error: Exception) {
            return Result.Err(productConfigMutationError(
                "config.read_failed",
                "cannot read product configuration: " + error.message,
                path
            ))
        }
        // Future keys are ignored by the typed reader, while malformed values
        // for fields we do understand remain hard failures.
        try {
            validateProductConfigSource(source)
        } catch (error: Exception) {
            return Result.Err(productConfigMutationError(
                "config.invalid",
                "cannot read product configuration: " + error.message,
                path
            ))
        }
        let updated = match (patchProductConfigSource(source, edits)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            validateProductConfigSource(updated)
        } catch (error: Exception) {
            return Result.Err(productConfigMutationError(
                "config.invalid",
                "cannot write invalid product configuration: " + error.message,
                path
            ))
        }
        atomicConfigWrite(path, updated)
    } finally {
        lock.release()
    }
}

func validateProductConfigSource(source: String): Unit {
    validateProductConfigKeys(source)
    _ = topLevelSetting(source, "default_model")
    _ = topLevelSetting(source, "theme")
    _ = parseAsyncEnabled(source)
    _ = parseApprovalSettings(source)
    _ = parseCompactionSettings(source)
}

class ProductConfigYamlLine {
    var text: String
    var ending: String

    init(text: String, ending: String) {
        this.text = text
        this.ending = ending
    }
}

func patchProductConfigSource(
    source: String,
    edits: Array<ProductConfigEdit>
): Result<String> {
    let path = "config.yml"
    let seen = ArrayList<String>()
    let lines = productConfigYamlLines(source)
    for (edit in edits) {
        if (containsString(seen, edit.key)) {
            return Result.Err(productConfigMutationError(
                "config.edit_duplicate",
                "duplicate product configuration edit: " + edit.key,
                path
            ))
        }
        seen.add(edit.key)
        let segments = edit.key.split(".")
        if (segments.isEmpty() || segments.size > 2) {
            return Result.Err(productConfigMutationError(
                "config.edit_key_invalid",
                "product configuration edit keys must contain one or two path segments: " + edit.key,
                path
            ))
        }
        for (segment in segments) {
            if (!isSafeProductConfigKey(segment)) {
                return Result.Err(productConfigMutationError(
                    "config.edit_key_invalid",
                    "product configuration edit key is invalid: " + edit.key,
                    path
                ))
            }
        }
        let rendered = productConfigScalar(edit.value)
        let result = if (segments.size == 1) {
            patchTopLevelProductConfig(lines, segments[0], rendered)
        } else {
            patchNestedProductConfig(lines, segments[0], segments[1], rendered)
        }
        match (result) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    Result.Ok(renderProductConfigYamlLines(lines))
}

func patchTopLevelProductConfig(
    lines: ArrayList<ProductConfigYamlLine>,
    key: String,
    rendered: String
): Result<Unit> {
    var found: Int64 = -1
    for (index in 0..lines.size) {
        let line = lines[index].text
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#") || yamlIndent(line) != 0) {
            continue
        }
        let separator = trimmed.indexOf(":")
        if (separator.isNone() || trimmed[..separator.getOrThrow()].trimAscii() != key) {
            continue
        }
        if (found >= 0) {
            return Result.Err(productConfigMutationError(
                "config.edit_ambiguous",
                "duplicate product configuration key: " + key,
                "config.yml"
            ))
        }
        found = index
    }
    if (found >= 0) {
        lines[found].text = replaceProductConfigScalar(lines[found].text, rendered)
    } else {
        appendProductConfigLines(lines, [key + ": " + rendered])
    }
    Result.Ok(())
}

func patchNestedProductConfig(
    lines: ArrayList<ProductConfigYamlLine>,
    section: String,
    key: String,
    rendered: String
): Result<Unit> {
    var sectionIndex: Int64 = -1
    var sectionEnd: Int64 = lines.size
    for (index in 0..lines.size) {
        let line = lines[index].text
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#") || yamlIndent(line) != 0) {
            continue
        }
        let separator = trimmed.indexOf(":")
        if (separator.isNone()) {
            continue
        }
        let candidate = trimmed[..separator.getOrThrow()].trimAscii()
        if (candidate == section) {
            if (sectionIndex >= 0) {
                return Result.Err(productConfigMutationError(
                    "config.edit_ambiguous",
                    "duplicate product configuration section: " + section,
                    "config.yml"
                ))
            }
            let value = stripInlineYamlComment(trimmed[separator.getOrThrow() + 1..].trimAscii())
            if (value != "") {
                return Result.Err(productConfigMutationError(
                    "config.invalid",
                    section + " must be a mapping",
                    "config.yml"
                ))
            }
            sectionIndex = index
            sectionEnd = lines.size
        } else if (sectionIndex >= 0 && sectionEnd == lines.size) {
            sectionEnd = index
        }
    }
    if (sectionIndex < 0) {
        appendProductConfigLines(lines, [section + ":", "  " + key + ": " + rendered])
        return Result.Ok(())
    }

    var found: Int64 = -1
    var childIndent = ""
    for (index in (sectionIndex + 1)..sectionEnd) {
        let line = lines[index].text
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#")) {
            continue
        }
        let indent = yamlIndent(line)
        if (indent <= 0) {
            continue
        }
        if (childIndent == "") {
            childIndent = line[..indent]
        }
        if (indent != childIndent.size) {
            continue
        }
        let separator = trimmed.indexOf(":")
        if (separator.isNone() || trimmed[..separator.getOrThrow()].trimAscii() != key) {
            continue
        }
        if (found >= 0) {
            return Result.Err(productConfigMutationError(
                "config.edit_ambiguous",
                "duplicate product configuration key: " + section + "." + key,
                "config.yml"
            ))
        }
        found = index
    }
    if (found >= 0) {
        lines[found].text = replaceProductConfigScalar(lines[found].text, rendered)
        return Result.Ok(())
    }

    if (childIndent == "") {
        childIndent = "  "
    }
    let newline = productConfigNewline(lines)
    let preserveFinalNewline = productConfigHasFinalNewline(lines)
    if (lines[sectionIndex].ending == "") {
        lines[sectionIndex].ending = newline
    }
    let insertedEnding = if (sectionEnd < lines.size || preserveFinalNewline) { newline } else { "" }
    lines.add(ProductConfigYamlLine(childIndent + key + ": " + rendered, insertedEnding), at: sectionIndex + 1)
    Result.Ok(())
}

func replaceProductConfigScalar(line: String, rendered: String): String {
    let separator = line.indexOf(":").getOrThrow()
    let rest = line[separator + 1..]
    let comment = inlineYamlCommentIndex(rest)
    let scalar = match (comment) {
        case Some(index) => rest[..index]
        case None => rest
    }
    var leading: Int64 = 0
    let bytes = unsafe { scalar.rawData() }
    while (leading < bytes.size && (bytes[leading] == b' ' || bytes[leading] == b'\t')) {
        leading += 1
    }
    var trailing = bytes.size
    while (trailing > leading && (bytes[trailing - 1] == b' ' || bytes[trailing - 1] == b'\t')) {
        trailing -= 1
    }
    let suffix = match (comment) {
        case Some(index) => rest[index..]
        case None => ""
    }
    line[..separator + 1] + scalar[..leading] + rendered + scalar[trailing..] + suffix
}

func appendProductConfigLines(
    lines: ArrayList<ProductConfigYamlLine>,
    values: Array<String>
): Unit {
    let newline = productConfigNewline(lines)
    let preserveFinalNewline = productConfigHasFinalNewline(lines)
    let addFinalNewline = preserveFinalNewline || lines.isEmpty()
    if (!lines.isEmpty() && lines[lines.size - 1].ending == "") {
        lines[lines.size - 1].ending = newline
    }
    for (index in 0..values.size) {
        let ending = if (index + 1 < values.size || addFinalNewline) { newline } else { "" }
        lines.add(ProductConfigYamlLine(values[index], ending))
    }
}

func productConfigYamlLines(source: String): ArrayList<ProductConfigYamlLine> {
    let lines = ArrayList<ProductConfigYamlLine>()
    let bytes = unsafe { source.rawData() }
    var start: Int64 = 0
    for (index in 0..bytes.size) {
        if (bytes[index] != b'\n') {
            continue
        }
        let crlf = index > start && bytes[index - 1] == b'\r'
        let end = if (crlf) { index - 1 } else { index }
        lines.add(ProductConfigYamlLine(source[start..end], if (crlf) { "\r\n" } else { "\n" }))
        start = index + 1
    }
    if (start < bytes.size) {
        lines.add(ProductConfigYamlLine(source[start..], ""))
    }
    lines
}

func renderProductConfigYamlLines(lines: ArrayList<ProductConfigYamlLine>): String {
    var source = ""
    for (line in lines) {
        source += line.text + line.ending
    }
    source
}

func productConfigNewline(lines: ArrayList<ProductConfigYamlLine>): String {
    for (line in lines where line.ending != "") {
        return line.ending
    }
    "\n"
}

func productConfigHasFinalNewline(lines: ArrayList<ProductConfigYamlLine>): Bool {
    !lines.isEmpty() && lines[lines.size - 1].ending != ""
}

func productConfigScalar(value: ProductConfigScalar): String {
    match (value) {
        case ProductConfigScalar.Text(text) => configYamlQuote(text)
        case ProductConfigScalar.Boolean(enabled) => enabled.toString()
        case ProductConfigScalar.Integer(number) => number.toString()
    }
}

func isSafeProductConfigKey(value: String): Bool {
    if (value == "") {
        return false
    }
    for (byte in unsafe { value.rawData() }) {
        let safe = (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-'
        if (!safe) {
            return false
        }
    }
    true
}

class ProductConfigFileLock {
    private let path: String
    private let token: String
    private var held = false

    init(root: String) {
        this.path = root + "/config.yml.lock"
        // PID separates live processes; the atomic sequence makes concurrent
        // lock objects in this process distinct even when their clocks match.
        this.token = getProcessId().toString() + "-" + productConfigNowMillis().toString() + "-" +
            productConfigLockSequence.fetchAdd(1).toString()
    }

    func acquire(): Result<Unit> {
        let deadline = MonoTime.now() + Duration.millisecond * 5000
        let candidate = path + ".pending-" + token
        try {
            Directory.create(candidate)
            File.writeTo(
                candidate + "/owner",
                (token + "\n" + getProcessId().toString() + "\n" + productConfigNowMillis().toString() + "\n").toArray()
            )
        } catch (error: Exception) {
            let _ = removeIfExists(candidate, recursive: true)
            return Result.Err(productConfigMutationError(
                "config.lock_failed",
                "cannot prepare the product configuration lock: " + error.message,
                path
            ))
        }
        while (MonoTime.now() < deadline) {
            try {
                rename(candidate, to: path, overwrite: false)
                held = true
                return Result.Ok(())
            } catch (_: Exception) {}
            sleep(Duration.millisecond * 10)
        }
        let _ = removeIfExists(candidate, recursive: true)
        Result.Err(productConfigMutationError(
            "config.lock_timeout",
            "timed out waiting for the product configuration lock",
            path
        ))
    }

    func release(): Unit {
        if (!held) {
            return
        }
        // Move the directory we acquired to a token-specific release path
        // before deleting it. A new writer may then acquire `path`, but this
        // release can only remove the claimed directory and never that new
        // owner's lock.
        let claimed = path + ".release-" + token
        try {
            rename(path, to: claimed, overwrite: false)
            if (claimedByThisOwner(claimed)) {
                let _ = removeIfExists(claimed, recursive: true)
            } else {
                restoreUnexpectedOwner(claimed)
            }
        } catch (_: Exception) {}
        held = false
    }

    private func claimedByThisOwner(claimed: String): Bool {
        try {
            let ownerPath = claimed + "/owner"
            if (!exists(Path(ownerPath))) {
                return false
            }
            let owner = String.fromUtf8(File.readFrom(ownerPath)).split("\n")
            !owner.isEmpty() && owner[0].trimAscii() == token
        } catch (_: Exception) {
            false
        }
    }

    private func restoreUnexpectedOwner(claimed: String): Unit {
        try {
            rename(claimed, to: path, overwrite: false)
        } catch (_: Exception) {}
    }
}

func productConfigNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func productConfigMutationError(
    code: String,
    message: String,
    path: String
): AgentError {
    AgentError(
        AgentErrorKind.Configuration,
        code,
        message,
        fields: [ErrorField("path", path)]
    )
}

func validateProductConfigKeys(source: String): Unit {
    for (line in source.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#")) {
            continue
        }
        let separator = trimmed.indexOf(":")
        if (separator.isNone()) {
            continue
        }
        if (yamlIndent(line) != 0) {
            continue
        }
        let key = trimmed[..separator.getOrThrow()].trimAscii()
        if (isObsoleteSingleProviderConfigKey(key)) {
            throw IllegalArgumentException(
                "removed single-provider key '" + key +
                    "' is not supported in config.yml; use providers.yml and models.yml"
            )
        }
        if (key == "async" || key == "approval" || key == "compaction" || key == "model_roles" || key ==
            "modelRoles") {
            let value = stripInlineYamlComment(trimmed[separator.getOrThrow() + 1..].trimAscii())
            if (value != "") {
                throw IllegalArgumentException(key + " must be a mapping")
            }
        }
    }
}

func isObsoleteSingleProviderConfigKey(key: String): Bool {
    key == "provider" || key == "model" || key == "base_url" || key == "baseUrl" || key == "api_key" || key ==
        "apiKey" || key == "api_key_env" || key == "apiKeyEnv" || key == "protocol"
}

func parseCompactionSettings(source: String): ProductCompactionSettings {
    var inCompaction = false
    var inModels = false
    var enabled = true
    var maxInputTokens: Int64 = 100000
    var requestMaxMessages: Int64 = 24
    var triggerPercent: Int64 = 88
    var targetPercent: Int64 = 60
    var emergencyMaxMessages: Int64 = 512
    var keepRecentTokens: Int64 = 50000
    var keepRecentMessages: Int64 = 12
    var oversizedToolResultTokens: Int64 = 12000
    var summaryStrategy = "structured"
    var summaryModel = ""
    var summaryTimeoutMillis: Int64 = 5000
    var summaryMaxOutputTokens: Int64 = 800
    var summaryFailurePolicy = "fallback_structured"
    let modelOverrides = ArrayList<ProductModelCompactionSettings>()
    var currentModel = ""
    var modelMaxInputTokens: ?Int64 = None
    var modelTriggerPercent: ?Int64 = None
    var modelTargetPercent: ?Int64 = None
    for (line in source.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#")) {
            continue
        }
        let indent = yamlIndent(line)
        let separator = trimmed.indexOf(":")
        if (separator.isNone()) {
            continue
        }
        let key = trimmed[..separator.getOrThrow()].trimAscii()
        let value = yamlScalar(stripInlineYamlComment(trimmed[separator.getOrThrow() + 1..].trimAscii()))
        if (indent == 0) {
            appendCompactionModelOverride(
                modelOverrides,
                currentModel,
                modelMaxInputTokens,
                modelTriggerPercent,
                modelTargetPercent
            )
            currentModel = ""
            modelMaxInputTokens = None
            modelTriggerPercent = None
            modelTargetPercent = None
            inModels = false
            inCompaction = key == "compaction"
            continue
        }
        if (!inCompaction) {
            continue
        }
        if (indent == 2) {
            appendCompactionModelOverride(
                modelOverrides,
                currentModel,
                modelMaxInputTokens,
                modelTriggerPercent,
                modelTargetPercent
            )
            currentModel = ""
            modelMaxInputTokens = None
            modelTriggerPercent = None
            modelTargetPercent = None
            if (key == "models") {
                inModels = true
                continue
            }
            inModels = false
            match (key) {
                case "enabled" => enabled = parseConfigBool(key, value)
                case "max_input_tokens" | "maxInputTokens" => maxInputTokens = Int64.parse(value)
                case "request_max_messages" | "requestMaxMessages" => requestMaxMessages = Int64.parse(value)
                case "trigger_percent" | "triggerPercent" => triggerPercent = Int64.parse(value)
                case "target_percent" | "targetPercent" => targetPercent = Int64.parse(value)
                case "emergency_max_messages" | "emergencyMaxMessages" => emergencyMaxMessages = Int64.parse(value)
                case "keep_recent_tokens" | "keepRecentTokens" => keepRecentTokens = Int64.parse(value)
                case "keep_recent_messages" | "keepRecentMessages" => keepRecentMessages = Int64.parse(value)
                case "oversized_tool_result_tokens" | "oversizedToolResultTokens" =>
                    oversizedToolResultTokens = Int64.parse(value)
                case "summary_strategy" | "summaryStrategy" => summaryStrategy = value.toAsciiLower()
                case "summary_model" | "summaryModel" => summaryModel = value
                case "summary_timeout_ms" | "summaryTimeoutMs" => summaryTimeoutMillis = Int64.parse(value)
                case "summary_max_output_tokens" | "summaryMaxOutputTokens" =>
                    summaryMaxOutputTokens = Int64.parse(value)
                case "summary_failure_policy" | "summaryFailurePolicy" =>
                    summaryFailurePolicy = value.toAsciiLower()
                case _ => ()
            }
        } else if (indent == 4 && inModels) {
            appendCompactionModelOverride(
                modelOverrides,
                currentModel,
                modelMaxInputTokens,
                modelTriggerPercent,
                modelTargetPercent
            )
            currentModel = yamlScalar(key).trimAscii()
            modelMaxInputTokens = None
            modelTriggerPercent = None
            modelTargetPercent = None
        } else if (indent == 6 && inModels && currentModel != "") {
            match (key) {
                case "max_input_tokens" | "maxInputTokens" => modelMaxInputTokens = Some(Int64.parse(value))
                case "trigger_percent" | "triggerPercent" => modelTriggerPercent = Some(Int64.parse(value))
                case "target_percent" | "targetPercent" => modelTargetPercent = Some(Int64.parse(value))
                case _ => ()
            }
        }
    }
    appendCompactionModelOverride(
        modelOverrides,
        currentModel,
        modelMaxInputTokens,
        modelTriggerPercent,
        modelTargetPercent
    )
    ProductCompactionSettings(
        enabled: enabled,
        maxInputTokens: maxInputTokens,
        requestMaxMessages: requestMaxMessages,
        triggerPercent: triggerPercent,
        targetPercent: targetPercent,
        emergencyMaxMessages: emergencyMaxMessages,
        keepRecentTokens: keepRecentTokens,
        keepRecentMessages: keepRecentMessages,
        oversizedToolResultTokens: oversizedToolResultTokens,
        summaryStrategy: summaryStrategy,
        summaryModel: summaryModel,
        summaryTimeoutMillis: summaryTimeoutMillis,
        summaryMaxOutputTokens: summaryMaxOutputTokens,
        summaryFailurePolicy: summaryFailurePolicy,
        modelOverrides: modelOverrides.toArray()
    )
}

func appendCompactionModelOverride(
    values: ArrayList<ProductModelCompactionSettings>,
    model: String,
    maxInputTokens: ?Int64,
    triggerPercent: ?Int64,
    targetPercent: ?Int64
): Unit {
    if (model != "") {
        values.add(
            ProductModelCompactionSettings(
                model,
                maxInputTokens: maxInputTokens,
                triggerPercent: triggerPercent,
                targetPercent: targetPercent
            )
        )
    }
}

func parseApprovalSettings(source: String): ProductApprovalSettings {
    var section = ""
    var subsection = ""
    var mode = ApprovalRoutingMode.Manual
    var failure = ApprovalFailurePolicy.AskUser
    var timeout: Int64 = 30000
    var logDecisions = true
    var reviewerModel = ""
    var roleModel = ""
    var reasoning = ThinkingLevel.Medium
    var allowWorkspaceWrites = true
    var askOnNetwork = true
    var askOnOutside = true
    var askOnDestructive = true
    for (line in source.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#")) {
            continue
        }
        let indent = yamlIndent(line)
        let separator = trimmed.indexOf(":")
        if (separator.isNone()) {
            continue
        }
        let key = trimmed[..separator.getOrThrow()].trimAscii()
        let raw = stripInlineYamlComment(trimmed[separator.getOrThrow() + 1..].trimAscii())
        let value = yamlScalar(raw)
        if (indent == 0) {
            section = key
            subsection = ""
            continue
        }
        if (indent <= 2 && (key == "reviewer" || key == "policy")) {
            subsection = key
            continue
        }
        if (section == "model_roles" || section == "modelRoles") {
            if (key == "approval") {
                roleModel = value
            }
            continue
        }
        if (section != "approval") {
            continue
        }
        match (key) {
            case "mode" => mode = approvalRoutingModeNamed(value)
            case "failure_policy" | "failurePolicy" => failure = approvalFailurePolicyNamed(value)
            case "timeout_ms" | "timeoutMs" => timeout = Int64.parse(value)
            case "log_decisions" | "logDecisions" => logDecisions = parseConfigBool(key, value)
            case "reviewer_model" => reviewerModel = value
            case "model" =>
                if (subsection == "reviewer") {
                    reviewerModel = value
                }
            case "reasoning_effort" | "reasoningEffort" => reasoning = approvalThinkingNamed(value)
            case "allow_workspace_writes" => allowWorkspaceWrites = parseConfigBool(key, value)
            case "ask_on_network" => askOnNetwork = parseConfigBool(key, value)
            case "ask_on_outside_workspace_write" => askOnOutside = parseConfigBool(key, value)
            case "ask_on_destructive_commands" => askOnDestructive = parseConfigBool(key, value)
            case _ => ()
        }
    }
    ProductApprovalSettings(
        mode: mode,
        failurePolicy: failure,
        timeoutMillis: timeout,
        logDecisions: logDecisions,
        reviewerModel: if (roleModel != "") {
            roleModel
        } else {
            reviewerModel
        },
        reasoning: reasoning,
        allowWorkspaceWrites: allowWorkspaceWrites,
        askOnNetwork: askOnNetwork,
        askOnOutsideWorkspaceWrite: askOnOutside,
        askOnDestructiveCommands: askOnDestructive
    )
}

func yamlIndent(line: String): Int64 {
    let bytes = unsafe { line.rawData() }
    var count: Int64 = 0
    while (count < bytes.size && (bytes[count] == 32 || bytes[count] == 9)) {
        count += 1
    }
    count
}

public func approvalRoutingModeNamed(value: String): ApprovalRoutingMode {
    match (value.trimAscii().toAsciiLower()) {
        case "ai" => ApprovalRoutingMode.Ai
        case "never" => ApprovalRoutingMode.Never
        case "trusted" => ApprovalRoutingMode.Trusted
        case _ => ApprovalRoutingMode.Manual
    }
}

func approvalFailurePolicyNamed(value: String): ApprovalFailurePolicy {
    match (value.trimAscii().toAsciiLower()) {
        case "deny" => ApprovalFailurePolicy.Deny
        case "ask_user" => ApprovalFailurePolicy.AskUser
        case "approve" => throw IllegalArgumentException("approval.failure_policy cannot be approve")
        case _ => throw IllegalArgumentException("approval.failure_policy must be deny or ask_user")
    }
}

func approvalThinkingNamed(value: String): ThinkingLevel {
    match (value.trimAscii().toAsciiLower()) {
        case "off" => ThinkingLevel.Off
        case "minimal" => ThinkingLevel.Minimal
        case "low" => ThinkingLevel.Low
        case "high" => ThinkingLevel.High
        case "xhigh" => ThinkingLevel.XHigh
        case "max" => ThinkingLevel.Max
        case _ => ThinkingLevel.Medium
    }
}

func parseConfigBool(name: String, value: String): Bool {
    match (value.toAsciiLower()) {
        case "true" => true
        case "false" => false
        case _ => throw IllegalArgumentException(name + " must be true or false")
    }
}

func parseAsyncEnabled(source: String): Bool {
    var inAsync = false
    for (line in source.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#")) {
            continue
        }
        let nested = line.startsWith(" ") || line.startsWith("\t")
        if (!nested) {
            inAsync = trimmed == "async:" || trimmed.startsWith("async: #")
            continue
        }
        if (!inAsync) {
            continue
        }
        let separator = trimmed.indexOf(":")
        if (separator.isNone()) {
            continue
        }
        let key = trimmed[..separator.getOrThrow()].trimAscii()
        if (key != "enabled") {
            continue
        }
        let raw = trimmed[separator.getOrThrow() + 1..].trimAscii()
        let value = stripInlineYamlComment(raw)
        if (value == "true") {
            return true
        }
        if (value == "false") {
            return false
        }
        throw IllegalArgumentException("async.enabled must be true or false")
    }
    true
}

func stripInlineYamlComment(value: String): String {
    match (inlineYamlCommentIndex(value)) {
        case Some(index) => value[..index].trimAscii()
        case None => value.trimAscii()
    }
}

func inlineYamlCommentIndex(value: String): ?Int64 {
    let bytes = unsafe { value.rawData() }
    var singleQuoted = false
    var doubleQuoted = false
    var escaped = false
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (doubleQuoted && escaped) {
            escaped = false
            continue
        }
        if (doubleQuoted && byte == b'\\') {
            escaped = true
            continue
        }
        if (!singleQuoted && byte == b'"') {
            doubleQuoted = !doubleQuoted
            continue
        }
        if (!doubleQuoted && byte == b'\'') {
            singleQuoted = !singleQuoted
            continue
        }
        if (!singleQuoted && !doubleQuoted && byte == b'#' &&
            (index == 0 || bytes[index - 1] == b' ' || bytes[index - 1] == b'\t')) {
            return Some(index)
        }
    }
    None
}

func encodeProductSettings(
    model: String,
    asyncEnabled: Bool,
    theme!: String = "axyndra",
    approval!: ProductApprovalSettings = ProductApprovalSettings(),
    compaction!: ProductCompactionSettings = ProductCompactionSettings()
): String {
    var result = "default_model: " + configYamlQuote(model) + "\n" + "theme: " + configYamlQuote(theme) + "\n" + "async:\n" +
        "  enabled: " + asyncEnabled.toString() + "\n" + "approval:\n" + "  mode: " + approvalRoutingModeName(
        approval.mode) + "\n" + "  failure_policy: " + approvalFailurePolicyName(approval.failurePolicy) + "\n" +
        "  timeout_ms: " + approval.timeoutMillis.toString() + "\n" + "  log_decisions: " +
        approval.logDecisions.toString() + "\n" + "  reviewer_model: " + configYamlQuote(approval.reviewerModel) + "\n" +
        "  reasoning_effort: " + thinkingConfigName(approval.reasoning) + "\n" + "  allow_workspace_writes: " +
        approval.allowWorkspaceWrites.toString() + "\n" + "  ask_on_network: " + approval.askOnNetwork.toString() + "\n" +
        "  ask_on_outside_workspace_write: " + approval.askOnOutsideWorkspaceWrite.toString() + "\n" +
        "  ask_on_destructive_commands: " + approval.askOnDestructiveCommands.toString() + "\n" +
        "compaction:\n" +
        "  enabled: " + compaction.enabled.toString() + "\n" +
        // Trigger is the high-water mark; target is the lower post-compaction
        // destination that provides hysteresis before the next trigger.
        "  max_input_tokens: " + compaction.maxInputTokens.toString() + "\n" +
        "  request_max_messages: " + compaction.requestMaxMessages.toString() + "\n" +
        "  trigger_percent: " + compaction.triggerPercent.toString() + "\n" +
        "  target_percent: " + compaction.targetPercent.toString() + "\n" +
        "  emergency_max_messages: " + compaction.emergencyMaxMessages.toString() + "\n" +
        "  keep_recent_tokens: " + compaction.keepRecentTokens.toString() + "\n" +
        "  keep_recent_messages: " + compaction.keepRecentMessages.toString() + "\n" +
        "  oversized_tool_result_tokens: " + compaction.oversizedToolResultTokens.toString() + "\n" +
        "  summary_strategy: " + compaction.summaryStrategy + "\n" +
        "  summary_model: " + configYamlQuote(compaction.summaryModel) + "\n" +
        "  summary_timeout_ms: " + compaction.summaryTimeoutMillis.toString() + "\n" +
        "  summary_max_output_tokens: " + compaction.summaryMaxOutputTokens.toString() + "\n" +
        "  summary_failure_policy: " + compaction.summaryFailurePolicy + "\n"
    if (!compaction.modelOverrides.isEmpty()) {
        result += "  models:\n"
        for (modelSettings in compaction.modelOverrides) {
            result += "    " + configYamlQuote(modelSettings.model) + ":\n"
            match (modelSettings.maxInputTokens) {
                case Some(value) => result += "      max_input_tokens: " + value.toString() + "\n"
                case None => ()
            }
            match (modelSettings.triggerPercent) {
                case Some(value) => result += "      trigger_percent: " + value.toString() + "\n"
                case None => ()
            }
            match (modelSettings.targetPercent) {
                case Some(value) => result += "      target_percent: " + value.toString() + "\n"
                case None => ()
            }
        }
    }
    result
}

func approvalRoutingModeName(value: ApprovalRoutingMode): String {
    match (value) {
        case ApprovalRoutingMode.Manual => "manual"
        case ApprovalRoutingMode.Ai => "ai"
        case ApprovalRoutingMode.Never => "never"
        case ApprovalRoutingMode.Trusted => "trusted"
    }
}

func approvalFailurePolicyName(value: ApprovalFailurePolicy): String {
    match (value) {
        case ApprovalFailurePolicy.Deny => "deny"
        case ApprovalFailurePolicy.AskUser => "ask_user"
    }
}

func thinkingConfigName(value: ThinkingLevel): String {
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

public func ensureProductLayout(root: String): Result<Unit> {
    try {
        if (!exists(Path(root))) {
            Directory.create(root, recursive: true)
        }
        if (!exists(Path(root + "/credentials"))) {
            Directory.create(root + "/credentials", recursive: true)
        }
        if (!exists(Path(root + "/sessions"))) {
            Directory.create(root + "/sessions", recursive: true)
        }
        Result.Ok(())
    } catch (error: Exception) {
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "config.layout_failed",
                "cannot create product configuration directory: " + error.message,
                fields: [ErrorField("path", root)]
            )
        )
    }
}

public func loadModelNames(root: String): Result<Array<String>> {
    match (loadModelCatalog(root)) {
        case Result.Ok(entries) =>
            let values = ArrayList<String>()
            for (entry in entries) {
                let candidate = entry.displayId()
                if (!containsString(values, candidate)) {
                    values.add(candidate)
                }
            }
            Result.Ok(values.toArray())
        case Result.Err(error) => Result.Err(error)
    }
}

public func loadModelCatalog(root: String): Result<Array<ModelCatalogEntry>> {
    let path = root + "/models.yml"
    if (!exists(Path(path))) {
        return Result.Ok([])
    }
    try {
        let values = ArrayList<ModelCatalogEntry>()
        var currentId = ""
        var currentProvider = ""
        var contextWindow: ?Int64 = None
        var maxOutputTokens: ?Int64 = None
        var thinkingMode = ""
        var thinkingLevels: ?Array<String> = None
        let thinkingBudgets = ArrayList<ThinkingBudgetTier>()
        var inThinking = false
        var inThinkingBudgets = false
        var structuredOutput: ?Bool = None
        var promptCache: ?Bool = None
        var inputModalities: ?Array<String> = None
        var outputModalities: ?Array<String> = None
        var inputCost: ?Int64 = None
        var outputCost: ?Int64 = None
        var cacheReadCost: ?Int64 = None
        var cacheWriteCost: ?Int64 = None
        var fastServiceTier = ""
        let seenFields = HashSet<String>()
        var sawRoot = false
        for (line in String.fromUtf8(File.readFrom(path)).split("\n")) {
            let trimmed = line.trimAscii()
            if (trimmed == "" || trimmed.startsWith("#")) {
                continue
            }
            if (trimmed == "models:") {
                if (sawRoot) {
                    throw IllegalArgumentException("duplicate models root")
                }
                sawRoot = true
                continue
            }
            if (!sawRoot) {
                throw IllegalArgumentException("model entry appears before models root")
            }
            if (!trimmed.startsWith("- id:") && !trimmed.startsWith("id:") && currentId == "") {
                throw IllegalArgumentException("models.yml field appears before model id: " + trimmed)
            }
            if (trimmed.startsWith("- id:")) {
                appendModelEntry(
                    values,
                    currentId,
                    currentProvider,
                    contextWindow,
                    maxOutputTokens,
                    thinkingMode,
                    thinkingLevels,
                    thinkingBudgets.toArray(),
                    structuredOutput,
                    promptCache,
                    inputModalities,
                    outputModalities,
                    inputCost,
                    outputCost,
                    cacheReadCost,
                    cacheWriteCost,
                    fastServiceTier
                )
                currentId = yamlScalar(trimmed[5..].trimAscii())
                currentProvider = ""
                contextWindow = None
                maxOutputTokens = None
                thinkingMode = ""
                thinkingLevels = None
                thinkingBudgets.clear()
                inThinking = false
                inThinkingBudgets = false
                structuredOutput = None
                promptCache = None
                inputModalities = None
                outputModalities = None
                inputCost = None
                outputCost = None
                cacheReadCost = None
                cacheWriteCost = None
                fastServiceTier = ""
                seenFields.clear()
                claimModelField(seenFields, "id")
            } else if (trimmed.startsWith("id:")) {
                appendModelEntry(
                    values,
                    currentId,
                    currentProvider,
                    contextWindow,
                    maxOutputTokens,
                    thinkingMode,
                    thinkingLevels,
                    thinkingBudgets.toArray(),
                    structuredOutput,
                    promptCache,
                    inputModalities,
                    outputModalities,
                    inputCost,
                    outputCost,
                    cacheReadCost,
                    cacheWriteCost,
                    fastServiceTier
                )
                currentId = yamlScalar(trimmed[3..].trimAscii())
                currentProvider = ""
                contextWindow = None
                maxOutputTokens = None
                thinkingMode = ""
                thinkingLevels = None
                thinkingBudgets.clear()
                inThinking = false
                inThinkingBudgets = false
                structuredOutput = None
                promptCache = None
                inputModalities = None
                outputModalities = None
                inputCost = None
                outputCost = None
                cacheReadCost = None
                cacheWriteCost = None
                fastServiceTier = ""
                seenFields.clear()
                claimModelField(seenFields, "id")
            } else if (trimmed == "thinking:") {
                claimModelField(seenFields, "thinking")
                inThinking = true
                inThinkingBudgets = false
            } else if (inThinking && trimmed.startsWith("mode:")) {
                thinkingMode = yamlScalar(trimmed[5..].trimAscii())
            } else if (inThinking && trimmed.startsWith("levels:")) {
                thinkingLevels = parseCatalogModalities(
                    trimmed[7..].trimAscii(), "thinking.levels"
                )
            } else if (inThinking && trimmed == "budgets:") {
                inThinkingBudgets = true
            } else if (inThinking && inThinkingBudgets &&
                line.startsWith("        ") && trimmed.contains(":")) {
                let parts = trimmed.split(":")
                if (parts.size != 2) {
                    throw IllegalArgumentException("thinking budget tier is invalid")
                }
                let level = parseThinkingLevelName(parts[0].trimAscii())
                let tokens = parseCatalogInteger(
                    parts[1].trimAscii(), "thinking.budgets", positive: true
                ).getOrThrow()
                thinkingBudgets.add(ThinkingBudgetTier(level, tokens))
            } else if (trimmed.startsWith("provider:")) {
                inThinking = false
                inThinkingBudgets = false
                claimModelField(seenFields, "provider")
                currentProvider = yamlScalar(trimmed[9..].trimAscii())
            } else if (trimmed.startsWith("context_window:")) {
                claimModelField(seenFields, "context_window")
                contextWindow = parseCatalogInteger(trimmed[15..].trimAscii(), "context_window", positive: true)
            } else if (trimmed.startsWith("max_output_tokens:")) {
                claimModelField(seenFields, "max_output_tokens")
                maxOutputTokens = parseCatalogInteger(trimmed[18..].trimAscii(), "max_output_tokens", positive: true)
            } else if (trimmed.startsWith("structured_output:")) {
                claimModelField(seenFields, "structured_output")
                structuredOutput = parseCatalogBoolean(
                    trimmed[18..].trimAscii(),
                    "structured_output"
                )
            } else if (trimmed.startsWith("prompt_cache:")) {
                claimModelField(seenFields, "prompt_cache")
                promptCache = parseCatalogBoolean(
                    trimmed[13..].trimAscii(),
                    "prompt_cache"
                )
            } else if (trimmed.startsWith("input_modalities:")) {
                claimModelField(seenFields, "input_modalities")
                inputModalities = parseCatalogModalities(trimmed[17..].trimAscii(), "input_modalities")
            } else if (trimmed.startsWith("output_modalities:")) {
                claimModelField(seenFields, "output_modalities")
                outputModalities = parseCatalogModalities(trimmed[18..].trimAscii(), "output_modalities")
            } else if (trimmed.startsWith("input_cost_micros_per_million:")) {
                claimModelField(seenFields, "input_cost_micros_per_million")
                inputCost = parseCatalogInteger(trimmed[30..].trimAscii(), "input_cost_micros_per_million")
            } else if (trimmed.startsWith("output_cost_micros_per_million:")) {
                claimModelField(seenFields, "output_cost_micros_per_million")
                outputCost = parseCatalogInteger(trimmed[31..].trimAscii(), "output_cost_micros_per_million")
            } else if (trimmed.startsWith("cache_read_cost_micros_per_million:")) {
                claimModelField(seenFields, "cache_read_cost_micros_per_million")
                cacheReadCost = parseCatalogInteger(trimmed[35..].trimAscii(), "cache_read_cost_micros_per_million")
            } else if (trimmed.startsWith("cache_write_cost_micros_per_million:")) {
                claimModelField(seenFields, "cache_write_cost_micros_per_million")
                cacheWriteCost = parseCatalogInteger(trimmed[36..].trimAscii(), "cache_write_cost_micros_per_million")
            } else if (trimmed.startsWith("fast_service_tier:")) {
                claimModelField(seenFields, "fast_service_tier")
                fastServiceTier = yamlScalar(trimmed[18..].trimAscii())
            } else {
                throw IllegalArgumentException("unknown models.yml field: " + trimmed)
            }
        }
        if (!sawRoot) {
            throw IllegalArgumentException("missing models root")
        }
        appendModelEntry(
            values,
            currentId,
            currentProvider,
            contextWindow,
            maxOutputTokens,
            thinkingMode,
            thinkingLevels,
            thinkingBudgets.toArray(),
            structuredOutput,
            promptCache,
            inputModalities,
            outputModalities,
            inputCost,
            outputCost,
            cacheReadCost,
            cacheWriteCost,
            fastServiceTier
        )
        Result.Ok(values.toArray())
    } catch (error: Exception) {
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "models.invalid",
                "cannot read model catalog: " + error.message,
                fields: [ErrorField("path", path)]
            )
        )
    }
}

public func loadProviderProfiles(root: String): Result<Array<ProviderProfile>> {
    let path = root + "/providers.yml"
    if (!exists(Path(path))) {
        return Result.Ok([])
    }
    try {
        let values = ArrayList<ProviderProfile>()
        var id = ""
        var provider = ""
        var protocol = ""
        var baseUrl = ""
        var apiKeyEnv = ""
        var authentication = "api-key"
        var timeoutMillis: Int64 = 120000
        var dialect = ""
        var endpointMaxOutputTokens: ?Int64 = None
        for (line in String.fromUtf8(File.readFrom(path)).split("\n")) {
            let trimmed = line.trimAscii()
            if (trimmed.startsWith("- id:")) {
                appendProviderProfile(
                    values,
                    id,
                    provider,
                    protocol,
                    baseUrl,
                    apiKeyEnv,
                    authentication,
                    timeoutMillis,
                    dialect,
                    endpointMaxOutputTokens
                )
                id = yamlScalar(trimmed[5..].trimAscii())
                provider = ""
                protocol = ""
                baseUrl = ""
                apiKeyEnv = ""
                authentication = "api-key"
                timeoutMillis = 120000
                dialect = ""
                endpointMaxOutputTokens = None
            } else if (trimmed.startsWith("provider:")) {
                provider = yamlScalar(trimmed[9..].trimAscii())
            } else if (trimmed.startsWith("protocol:")) {
                protocol = yamlScalar(trimmed[9..].trimAscii())
            } else if (trimmed.startsWith("base_url:")) {
                baseUrl = yamlScalar(trimmed[9..].trimAscii())
            } else if (trimmed.startsWith("api_key_env:")) {
                apiKeyEnv = yamlScalar(trimmed[12..].trimAscii())
            } else if (trimmed.startsWith("authentication:")) {
                authentication = yamlScalar(trimmed[15..].trimAscii())
            } else if (trimmed.startsWith("timeout_millis:")) {
                timeoutMillis = parseIntegerOr(
                    yamlScalar(trimmed[15..].trimAscii()),
                    120000
                )
            } else if (trimmed.startsWith("dialect:")) {
                dialect = yamlScalar(trimmed[8..].trimAscii())
            } else if (trimmed.startsWith("endpoint_max_output_tokens:")) {
                endpointMaxOutputTokens = parseCatalogInteger(
                    yamlScalar(trimmed[27..].trimAscii()),
                    "endpoint_max_output_tokens",
                    positive: true
                )
            }
        }
        appendProviderProfile(
            values,
            id,
            provider,
            protocol,
            baseUrl,
            apiKeyEnv,
            authentication,
            timeoutMillis,
            dialect,
            endpointMaxOutputTokens
        )
        Result.Ok(values.toArray())
    } catch (error: Exception) {
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "providers.invalid",
                "cannot read provider profiles: " + error.message,
                fields: [ErrorField("path", path)]
            )
        )
    }
}

public func upsertProviderProfile(
    root: String,
    profile: ProviderProfile
): Result<Unit> {
    let loaded = match (loadProviderProfiles(root)) {
        case Result.Ok(values) => values
        case Result.Err(error) => return Result.Err(error)
    }
    let output = ArrayList<ProviderProfile>()
    var replaced = false
    for (candidate in loaded) {
        if (candidate.id == profile.id) {
            output.add(profile)
            replaced = true
        } else {
            output.add(candidate)
        }
    }
    if (!replaced) {
        output.add(profile)
    }
    atomicConfigWrite(
        root + "/providers.yml",
        encodeProviderProfiles(output.toArray())
    )
}

public func upsertModelCatalogEntry(
    root: String,
    entry: ModelCatalogEntry
): Result<Unit> {
    let loaded = match (loadModelCatalog(root)) {
        case Result.Ok(values) => values
        case Result.Err(error) => return Result.Err(error)
    }
    let output = ArrayList<ModelCatalogEntry>()
    var replaced = false
    for (candidate in loaded) {
        if (candidate.id == entry.id && candidate.providerProfile == entry.providerProfile) {
            output.add(entry)
            replaced = true
        } else {
            output.add(candidate)
        }
    }
    if (!replaced) {
        output.add(entry)
    }
    atomicConfigWrite(
        root + "/models.yml",
        encodeModelCatalog(output.toArray())
    )
}

public func saveProviderCredential(
    root: String,
    profileId: String,
    credential: String
): Result<String> {
    if (credential.trimAscii() == "") {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "credential.empty",
                "API key must not be empty"
            )
        )
    }
    let safeId = safeProfileId(profileId)
    if (safeId.isError()) {
        return Result.Err(safeId.error().getOrThrow())
    }
    let path = root + "/credentials/" + safeId.value().getOrThrow() + ".key"
    let temporary = path + ".tmp"
    try {
        File.writeTo(temporary, (credential + "\n").toArray())
        let (code, _, error) = executeWithOutput(
            "chmod",
            ["600", temporary]
        )
        if (code != 0) {
            let _ = removeConfigFile(temporary)
            return Result.Err(
                AgentError(
                    AgentErrorKind.PermissionDenied,
                    "credential.permissions_failed",
                    String.fromUtf8(error).trimAscii()
                )
            )
        }
        rename(temporary, to: path, overwrite: true)
        Result.Ok(path)
    } catch (error: Exception) {
        let _ = removeConfigFile(temporary)
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "credential.save_failed",
                error.message
            )
        )
    }
}

public func providerCredentialPath(
    root: String,
    profileId: String
): Result<String> {
    match (safeProfileId(profileId)) {
        case Result.Ok(value) => Result.Ok(root + "/credentials/" + value + ".key")
        case Result.Err(error) => Result.Err(error)
    }
}

func appendModelEntry(
    values: ArrayList<ModelCatalogEntry>,
    id: String,
    provider: String,
    contextWindow: ?Int64,
    maxOutputTokens: ?Int64,
    thinkingMode: String,
    thinkingLevels: ?Array<String>,
    thinkingBudgets: Array<ThinkingBudgetTier>,
    structuredOutput: ?Bool,
    promptCache: ?Bool,
    inputModalities: ?Array<String>,
    outputModalities: ?Array<String>,
    inputCost: ?Int64,
    outputCost: ?Int64,
    cacheReadCost: ?Int64,
    cacheWriteCost: ?Int64,
    fastServiceTier: String
): Unit {
    if (id == "") {
        return
    }
    for (candidate in values where candidate.id == id && candidate.providerProfile == provider) {
        throw IllegalArgumentException("duplicate model catalog entry: " + candidate.displayId())
    }
    values.add(ModelCatalogEntry(
        id,
        providerProfile: provider,
        contextWindow: contextWindow,
        maxOutputTokens: maxOutputTokens,
        thinking: buildCatalogThinkingCapabilities(
            thinkingMode, thinkingLevels, thinkingBudgets
        ),
        structuredOutput: structuredOutput,
        promptCache: promptCache,
        inputModalities: inputModalities,
        outputModalities: outputModalities,
        inputCostMicrosPerMillion: inputCost,
        outputCostMicrosPerMillion: outputCost,
        cacheReadCostMicrosPerMillion: cacheReadCost,
        cacheWriteCostMicrosPerMillion: cacheWriteCost,
        fastServiceTier: fastServiceTier
    ))
}

func appendProviderProfile(
    values: ArrayList<ProviderProfile>,
    id: String,
    provider: String,
    protocol: String,
    baseUrl: String,
    apiKeyEnv: String,
    authentication: String,
    timeoutMillis: Int64,
    dialect: String,
    endpointMaxOutputTokens: ?Int64
): Unit {
    if (id == "") {
        return
    }
    values.add(
        ProviderProfile(
            id,
            if (provider == "") {
                id
            } else {
                provider
            },
            protocol,
            baseUrl,
            apiKeyEnv,
            authentication: authentication,
            timeoutMillis: timeoutMillis,
            dialect: dialect,
            endpointMaxOutputTokens: endpointMaxOutputTokens
        )
    )
}

func encodeProviderProfiles(values: Array<ProviderProfile>): String {
    var source = "providers:\n"
    for (value in values) {
        source += "  - id: " + configYamlQuote(value.id) + "\n" + "    provider: " + configYamlQuote(value.provider) +
            "\n" + "    protocol: " + configYamlQuote(value.protocol) + "\n" + "    base_url: " + configYamlQuote(
            value.baseUrl) + "\n" + "    api_key_env: " + configYamlQuote(value.apiKeyEnv) + "\n" +
            "    authentication: " + configYamlQuote(value.authentication) + "\n" + "    timeout_millis: " +
            value.timeoutMillis.toString() + "\n"
        if (value.dialect != "") {
            source += "    dialect: " + configYamlQuote(value.dialect) + "\n"
        }
        match (value.endpointMaxOutputTokens) {
            case Some(limit) => source += "    endpoint_max_output_tokens: " + limit.toString() + "\n"
            case None => ()
        }
    }
    source
}

func encodeModelCatalog(values: Array<ModelCatalogEntry>): String {
    var source = "models:\n"
    for (value in values) {
        source += "  - id: " + configYamlQuote(value.id) + "\n"
        if (value.providerProfile != "") {
            source += "    provider: " + configYamlQuote(value.providerProfile) + "\n"
        }
        source += encodeCatalogOptionalInteger("context_window", value.contextWindow)
        source += encodeCatalogOptionalInteger("max_output_tokens", value.maxOutputTokens)
        match (value.thinking) {
            case Some(thinking) => source += encodeCatalogThinking(thinking)
            case None => ()
        }
        match (value.structuredOutput) {
            case Some(enabled) => source += "    structured_output: " + enabled.toString() + "\n"
            case None => ()
        }
        match (value.promptCache) {
            case Some(enabled) => source += "    prompt_cache: " + enabled.toString() + "\n"
            case None => ()
        }
        source += encodeCatalogModalities("input_modalities", value.inputModalities)
        source += encodeCatalogModalities("output_modalities", value.outputModalities)
        source += encodeCatalogOptionalInteger(
            "input_cost_micros_per_million",
            value.inputCostMicrosPerMillion
        )
        source += encodeCatalogOptionalInteger(
            "output_cost_micros_per_million",
            value.outputCostMicrosPerMillion
        )
        source += encodeCatalogOptionalInteger(
            "cache_read_cost_micros_per_million",
            value.cacheReadCostMicrosPerMillion
        )
        source += encodeCatalogOptionalInteger(
            "cache_write_cost_micros_per_million",
            value.cacheWriteCostMicrosPerMillion
        )
        if (value.fastServiceTier != "") {
            source += "    fast_service_tier: " + configYamlQuote(value.fastServiceTier) + "\n"
        }
    }
    source
}

func encodeCatalogThinking(value: ThinkingCapabilities): String {
    let mode = match (value.mode) {
        case ThinkingControlMode.NoThinking => "none"
        case ThinkingControlMode.Toggle => "toggle"
        case ThinkingControlMode.Effort => "effort"
        case ThinkingControlMode.Budget => "budget"
        case ThinkingControlMode.Adaptive => "adaptive"
    }
    var source = "    thinking:\n      mode: " + mode + "\n"
    if (!value.supportedLevels.isEmpty()) {
        source += "      levels: ["
        var first = true
        for (level in value.supportedLevels) {
            if (!first) { source += ", " }
            source += thinkingConfigName(level)
            first = false
        }
        source += "]\n"
    }
    if (!value.budgetTiers.isEmpty()) {
        source += "      budgets:\n"
        for (tier in value.budgetTiers) {
            source += "        " + thinkingConfigName(tier.level) + ": " +
                tier.budgetTokens.toString() + "\n"
        }
    }
    source
}

func claimModelField(seen: HashSet<String>, name: String): Unit {
    if (seen.contains(name)) {
        throw IllegalArgumentException("duplicate models.yml field: " + name)
    }
    seen.add(name)
}

func parseCatalogInteger(
    source: String,
    name: String,
    positive!: Bool = false
): ?Int64 {
    let scalar = yamlScalar(source)
    if (scalar == "null") {
        return None
    }
    let value = try {
        Int64.parse(scalar)
    } catch (_: Exception) {
        throw IllegalArgumentException("model field is not an integer: " + name)
    }
    if ((positive && value < 1) || (!positive && value < 0)) {
        throw IllegalArgumentException("model field is out of range: " + name)
    }
    Some(value)
}

func parseCatalogBoolean(source: String, name: String): ?Bool {
    match (yamlScalar(source)) {
        case "true" => Some(true)
        case "false" => Some(false)
        case "null" => None
        case _ => throw IllegalArgumentException("model field is not boolean: " + name)
    }
}

func parseCatalogModalities(source: String, name: String): ?Array<String> {
    let scalar = source.trimAscii()
    if (scalar == "null") {
        return None
    }
    if (!scalar.startsWith("[") || !scalar.endsWith("]")) {
        throw IllegalArgumentException("model modalities must be an inline list: " + name)
    }
    let body = scalar[1..scalar.size - 1].trimAscii()
    if (body == "") {
        throw IllegalArgumentException("model modalities must not be empty: " + name)
    }
    let values = ArrayList<String>()
    for (part in body.split(",")) {
        let value = yamlScalar(part.trimAscii())
        if (value == "") {
            throw IllegalArgumentException("model modality must not be empty: " + name)
        }
        values.add(value)
    }
    Some(values.toArray())
}

func parseThinkingLevelName(source: String): ThinkingLevel {
    match (yamlScalar(source).toAsciiLower()) {
        case "minimal" => ThinkingLevel.Minimal
        case "low" => ThinkingLevel.Low
        case "medium" => ThinkingLevel.Medium
        case "high" => ThinkingLevel.High
        case "xhigh" => ThinkingLevel.XHigh
        case "max" => ThinkingLevel.Max
        case _ => throw IllegalArgumentException("unknown thinking level: " + source)
    }
}

func buildCatalogThinkingCapabilities(
    mode: String,
    levelNames: ?Array<String>,
    budgets: Array<ThinkingBudgetTier>
): ?ThinkingCapabilities {
    if (mode == "") {
        if (levelNames.isSome() || !budgets.isEmpty()) {
            throw IllegalArgumentException("thinking capability requires an explicit mode")
        }
        return None
    }
    let levels = ArrayList<ThinkingLevel>()
    match (levelNames) {
        case Some(values) => for (value in values) {
            levels.add(parseThinkingLevelName(value))
        }
        case None => ()
    }
    let control = match (mode.toAsciiLower()) {
        case "none" => ThinkingControlMode.NoThinking
        case "toggle" => ThinkingControlMode.Toggle
        case "effort" => ThinkingControlMode.Effort
        case "budget" => ThinkingControlMode.Budget
        case "adaptive" => ThinkingControlMode.Adaptive
        case _ => throw IllegalArgumentException("unknown thinking mode: " + mode)
    }
    Some(ThinkingCapabilities(
        control,
        supportedLevels: levels.toArray(),
        budgetTiers: budgets
    ))
}

func encodeCatalogOptionalInteger(name: String, value: ?Int64): String {
    match (value) {
        case Some(number) => "    " + name + ": " + number.toString() + "\n"
        case None => ""
    }
}

func encodeCatalogModalities(name: String, value: ?Array<String>): String {
    match (value) {
        case Some(items) =>
            var output = "    " + name + ": ["
            for (index in 0..items.size) {
                if (index > 0) {
                    output += ", "
                }
                output += configYamlQuote(items[index])
            }
            output + "]\n"
        case None => ""
    }
}

func atomicConfigWrite(path: String, source: String): Result<Unit> {
    let temporary = path + ".tmp"
    try {
        File.writeTo(temporary, source.toArray())
        rename(temporary, to: path, overwrite: true)
        Result.Ok(())
    } catch (error: Exception) {
        let _ = removeConfigFile(temporary)
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "config.write_failed",
                error.message,
                fields: [ErrorField("path", path)]
            )
        )
    }
}

func safeProfileId(value: String): Result<String> {
    if (value.trimAscii() == "") {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "provider_profile.id_empty",
                "provider profile ID must not be empty"
            )
        )
    }
    if (!isSafeProfileId(value)) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "provider_profile.id_invalid",
                "provider profile ID may contain letters, digits, '-' and '_'"
            )
        )
    }
    Result.Ok(value)
}

func isSafeProfileId(value: String): Bool {
    if (value == "") {
        return false
    }
    for (byte in unsafe { value.rawData() }) {
        let allowed = (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || (byte >= b'0' && byte <= b'9') ||
            byte == b'-' || byte == b'_'
        if (!allowed) {
            return false
        }
    }
    true
}

func configYamlQuote(value: String): String {
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}

func parseIntegerOr(value: String, fallback: Int64): Int64 {
    try {
        Int64.parse(value)
    } catch (_: Exception) {
        fallback
    }
}

func removeConfigFile(path: String): Bool {
    removeIfExists(path)
}

func topLevelSetting(source: String, expected: String): String {
    var found = false
    var result = ""
    for (line in source.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed == "" || trimmed.startsWith("#") || yamlIndent(line) != 0) {
            continue
        }
        let separator = trimmed.indexOf(":")
        if (separator.isNone()) {
            continue
        }
        let index = separator.getOrThrow()
        let key = trimmed[..index].trimAscii()
        if (key != expected) {
            continue
        }
        if (found) {
            throw IllegalArgumentException("duplicate config.yml key '" + expected + "'")
        }
        found = true
        result = yamlScalar(trimmed[index + 1..].trimAscii())
    }
    result
}

func yamlScalar(source: String): String {
    let value = stripInlineYamlComment(source)
    if (value.size >= 2 && ((value.startsWith("\"") && value.endsWith("\"")) || (value.startsWith("'") &&
        value.endsWith("'")))) {
        let inner = value[1..value.size - 1]
        if (value.startsWith("\"")) {
            inner.replace("\\\"", "\"").replace("\\\\", "\\")
        } else {
            inner
        }
    } else {
        value
    }
}

func containsString(values: ArrayList<String>, expected: String): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}
