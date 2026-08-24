package agent_embed

import agent_core.*
import agent_domain.*
import agent_skills.*
import std.deriving.*
import tool_runtime.*

// Later configuration layers have strictly higher authority. Calls within the
// same layer are last-writer-wins, which lets a parser apply one file or CLI
// argument stream deterministically.
@Derive[Equatable]
public enum Origin {
    Default | File | Environment | Cli | Programmatic
}

public func originPriority(origin: Origin): Int64 {
    match (origin) {
        case Origin.Default => 0
        case Origin.File => 1
        case Origin.Environment => 2
        case Origin.Cli => 3
        case Origin.Programmatic => 4
    }
}

public func originName(origin: Origin): String {
    match (origin) {
        case Origin.Default => "default"
        case Origin.File => "file"
        case Origin.Environment => "environment"
        case Origin.Cli => "cli"
        case Origin.Programmatic => "programmatic"
    }
}

public class OriginValue<T> {
    public let key: String
    public let value: T
    public let origin: Origin
    public let secret: Bool

    public init(
        key: String,
        value: T,
        origin: Origin,
        secret!: Bool = false
    ) {
        if (key.trimAscii() == "") {
            throw IllegalArgumentException("configuration key must not be empty")
        }
        this.key = key.trimAscii()
        this.value = value
        this.origin = origin
        this.secret = secret
    }

    public func merged(candidate: OriginValue<T>): OriginValue<T> {
        if (candidate.key != key) {
            throw IllegalArgumentException("configuration keys do not match")
        }
        let selected = if (originPriority(candidate.origin) >= originPriority(origin)) {
            candidate
        } else {
            this
        }
        // A key that was ever classified as secret cannot be declassified by
        // a higher-precedence layer and accidentally printed.
        OriginValue<T>(
            key,
            selected.value,
            selected.origin,
            secret: secret || candidate.secret
        )
    }

    public func describe(render: (T) -> String): String {
        key + "=" + if (secret) { "[REDACTED]" } else { render(value) } +
            " (origin=" + originName(origin) + ")"
    }
}

public func mergeOriginValues<T>(values: Array<OriginValue<T>>): OriginValue<T> {
    if (values.isEmpty()) {
        throw IllegalArgumentException("configuration merge requires at least one value")
    }
    var result = values[0]
    for (index in 1..values.size) {
        result = result.merged(values[index])
    }
    result
}

public class AgentSdkConfiguration {
    public let provider: OriginValue<String>
    public let model: OriginValue<String>
    public let tools: OriginValue<String>
    public let session: OriginValue<String>
    public let runRepository: OriginValue<String>
    public let policy: OriginValue<String>
    public let budget: OriginValue<ResourceBudget>
    public let prompt: OriginValue<PromptBuild>
    public let thinking: OriginValue<ThinkingLevel>
    public let capabilities: OriginValue<CapabilitySet>
    public let autoRetry: OriginValue<Bool>
    public let serviceTier: OriginValue<String>
    public let structuredOutput: OriginValue<?StructuredOutputSpec>
    public let cachePolicy: OriginValue<ModelCachePolicy>
    public let parallelToolCalls: OriginValue<Bool>
    public let toolContext: OriginValue<ToolContextDescriptor>
    public let skillStack: OriginValue<SkillStackSnapshot>

    init(
        provider: OriginValue<String>,
        model: OriginValue<String>,
        tools: OriginValue<String>,
        session: OriginValue<String>,
        runRepository: OriginValue<String>,
        policy: OriginValue<String>,
        budget: OriginValue<ResourceBudget>,
        prompt: OriginValue<PromptBuild>,
        thinking: OriginValue<ThinkingLevel>,
        capabilities: OriginValue<CapabilitySet>,
        autoRetry: OriginValue<Bool>,
        serviceTier: OriginValue<String>,
        structuredOutput: OriginValue<?StructuredOutputSpec>,
        cachePolicy: OriginValue<ModelCachePolicy>,
        parallelToolCalls: OriginValue<Bool>,
        toolContext: OriginValue<ToolContextDescriptor>,
        skillStack: OriginValue<SkillStackSnapshot>
    ) {
        this.provider = provider
        this.model = model
        this.tools = tools
        this.session = session
        this.runRepository = runRepository
        this.policy = policy
        this.budget = budget
        this.prompt = prompt
        this.thinking = thinking
        this.capabilities = capabilities
        this.autoRetry = autoRetry
        this.serviceTier = serviceTier
        this.structuredOutput = structuredOutput
        this.cachePolicy = cachePolicy
        this.parallelToolCalls = parallelToolCalls
        this.toolContext = toolContext
        this.skillStack = skillStack
    }

    // Prompt bodies, repository implementation details, credentials, and
    // provider objects are intentionally never included in this description.
    public func describe(): String {
        provider.describe({ value => value }) + "\n" +
            model.describe({ value => value }) + "\n" +
            tools.describe({ value => value }) + "\n" +
            session.describe({ value => value }) + "\n" +
            runRepository.describe({ value => value }) + "\n" +
            policy.describe({ value => value }) + "\n" +
            budget.describe({ value => budgetDescription(value) }) + "\n" +
            prompt.describe({ value => promptDescription(value) }) + "\n" +
            thinking.describe({ value => thinkingDescription(value) }) + "\n" +
            capabilities.describe({ value => capabilityDescription(value) }) + "\n" +
            autoRetry.describe({ value => value.toString() }) + "\n" +
            serviceTier.describe({ value => if (value == "") { "default" } else { value } }) + "\n" +
            structuredOutput.describe({ value => match (value) {
                case Some(spec) => spec.name
                case None => "none"
            } }) + "\n" +
            cachePolicy.describe({ value => cachePolicyDescription(value) }) + "\n" +
            parallelToolCalls.describe({ value => value.toString() }) + "\n" +
            toolContext.describe({ value => toolContextDescription(value) }) + "\n" +
            skillStack.describe({ value => "active=" + value.active.size.toString() +
                ",references=" + value.loadedReferences.size.toString() })
    }
}

func toolContextDescription(value: ToolContextDescriptor): String {
    "workspace=" + if (value.workspaceRoot == "") { "none" } else { "configured" } +
        ",cwd=" + if (value.cwd == "") { "none" } else { "configured" } +
        ",env_names=" + joinStrings(value.environment.names(), ",") +
        ",services=" + value.services.descriptors().size.toString()
}

func cachePolicyDescription(value: ModelCachePolicy): String {
    match (value) {
        case ModelCachePolicy.Default => "default"
        case ModelCachePolicy.StablePrefix => "stable_prefix"
    }
}

func budgetDescription(value: ResourceBudget): String {
    "turns=" + value.maxTurns.toString() +
        ",tool_calls=" + value.maxToolCalls.toString() +
        ",input_tokens=" + value.maxInputTokens.toString() +
        ",output_tokens=" + value.maxOutputTokens.toString() +
        ",deadline_ms=" + value.deadlineMillis.toString()
}

func promptDescription(value: PromptBuild): String {
    "sections=" + value.sections.size.toString() +
        ",stable_prefix_hash=" + value.stablePrefixHash +
        ",untrusted_sections=" + value.untrustedSectionCount.toString()
}

func thinkingDescription(value: ThinkingLevel): String {
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

func capabilityDescription(value: CapabilitySet): String {
    "count=" + value.values.size.toString()
}
