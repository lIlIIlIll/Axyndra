package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Pure codec probes only; these do not assert provider, Store, or restart
// acceptance and do not construct a fake continuation/approval/Attempt.
class ContextBoundaryLocalOwnedSink107 <: OwnedAgentEventSink {
    public func emit(event: OwnedAgentEvent): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "test.local_only", "not an event owner"))
    }
}

class ContextBoundaryRequestTestInteractions <: AgentInteractionSource {
    public func takeSteering(): Array<AgentQueuedInput> { [] }
    public func hasSteering(): Bool { true }
    public func takeFollowUps(): Array<AgentQueuedInput> { [] }
    public func interruptMode(): RunInterruptMode { RunInterruptMode.Wait }
}

func contextBoundaryRequestTestRequest(): AgentRunRequest {
    let thinking = ThinkingCapabilities(ThinkingControlMode.Budget,
        supportedLevels: [ThinkingLevel.Low, ThinkingLevel.Medium, ThinkingLevel.High],
        budgetTiers: [ThinkingBudgetTier(ThinkingLevel.Low, 13), ThinkingBudgetTier(ThinkingLevel.Medium, 29),
            ThinkingBudgetTier(ThinkingLevel.High, 47)])
    AgentRunRequest(RunId("codec-run"), SessionId("codec-thread"), "codec-model", "original prompt 雪",
        system: "original system", thinking: ThinkingLevel.High,
        userRequestedThinking: Some(ThinkingLevel.Max), thinkingSource: ThinkingPreferenceSource.ExplicitUser,
        modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot("codec-model", thinking, 401,
            endpointMaxOutputTokens: Some(307), configurationDigest: modelPolicySha256Text("configuration"),
            snapshotSchemaVersion: 7)), resolverVersion: 9,
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead, resource: "source"),
            Capability(CapabilityKind.NetworkAccess, resource: "https://example.invalid")]),
        budget: ResourceBudget(maxInputTokens: 101, requestOutputBudget: Some(RequestOutputBudget(103, minVisibleResponseTokens: 107)),
            maxTotalInputTokens: 109, maxTotalOutputTokens: 113, maxModelRequests: 127, maxTurns: 131,
            maxDrainModelRequests: 137, maxDrainTurns: 139, maxToolCalls: 149, maxWallMillis: 151,
            maxIdleMillis: 157, maxChildren: 163, maxDepth: 167, maxConcurrentChildren: 173,
            maxContextMessages: 179, maxConcurrentTools: 181, maxCostMicros: 191, deadlineMillis: 193,
            processLimits: ExecutionResourceLimits(maxOutputBytes: 197, addressSpaceBytes: 199, fileSizeBytes: 211,
                openFiles: 223, processes: 227, cpuSeconds: 229)),
        interactions: Some(ContextBoundaryRequestTestInteractions()), approvalModeOverride: Some(ApprovalMode.Write),
        autoRetry: false, serviceTier: "original-tier",
        pricing: Some(ModelPricing(inputMicrosPerMillion: Some(0), outputMicrosPerMillion: None,
            cacheReadMicrosPerMillion: Some(233), cacheWriteMicrosPerMillion: Some(239))),
        imageInputs: [ModelImage(ModelImageSourceKind.Url, "https://example.invalid/input.png", detail: ModelImageDetail.High),
            ModelImage(ModelImageSourceKind.Base64, "AA==", mediaType: "image/png", detail: ModelImageDetail.Low)],
        structuredOutput: Some(StructuredOutputSpec("reply", objectValue([ValueField("type", textValue("object"))]),
            description: "original structured output", strict: true)),
        cachePolicy: ModelCachePolicy.StablePrefix, cacheKey: "original-cache-key", parallelToolCalls: true,
        toolContext: ToolContextDescriptor(workspaceRoot: "original-root", cwd: "original-cwd",
            environment: ToolEnvironmentView(entries: [ToolEnvironmentEntry("CODEC_VALUE", "original-value")]),
            services: ToolServiceView(descriptors: [ToolServiceDescriptor(ToolServiceKind.Custom, "codec", version: "3")])),
        contextSnapshot: InvocationContextProjection(sourceDigest: modelPolicySha256Text("source context"),
            contributions: [InvocationContextContribution("skills", "codec", "original-ref", "original skill",
                ContextContentTrust.UserSelected, validUntilMillis: 251,
                references: [ContextResourceReference("loaded", "original-locator", content: Some("original bytes")),
                    ContextResourceReference("unloaded", "pending-locator")])]),
        contextWindow: 257, providerSafetyMargin: 263, executionLaneId: LaneId("codec-lane"), initializeContext: true)
}

func contextBoundaryRequestTestWithout(value: AgentValue, name: String): AgentValue {
    let fields = ArrayList<ValueField>()
    for (field in value.fields where field.name != name) { fields.add(ValueField(field.name, field.value)) }
    objectValue(fields.toArray())
}

func contextBoundaryRequestTestRejects(value: AgentValue): Bool {
    try { let _ = coreContextBoundaryRequestFromValue(value); false } catch (_: Exception) { true }
}

@Test
class ContextBoundaryFullRequestCodecTests {
    @TestCase
    func currentOwnedEventSinkIsCallerLocalAndNeverDecodedFromMetadata107(): Unit {
        let encoded = coreContextBoundaryRequestValue(contextBoundaryRequestTestRequest())
        let local = ContextBoundaryLocalOwnedSink107()
        let restored = coreContextBoundaryRequestFromValue(encoded, ownedEvents: Some(local))
        let actual = (restored.ownedEvents.getOrThrow() as ContextBoundaryLocalOwnedSink107).getOrThrow()
        @Expect(refEq(actual, local))
        @Expect(coreContextBoundaryRequestFromValue(encoded).ownedEvents.isNone())
        @Expect(canonicalAgentValue(coreContextBoundaryRequestValue(restored)), canonicalAgentValue(encoded))
    }

    @TestCase
    func allSemanticDataAndOriginalCeilingsRoundTripWithCallerLocalInteractions(): Unit {
        let request = contextBoundaryRequestTestRequest()
        let value = coreContextBoundaryRequestValue(request)
        let restored = coreContextBoundaryRequestFromValue(value)
        @Expect(canonicalAgentValue(coreContextBoundaryRequestValue(restored)), canonicalAgentValue(value))
        @Expect(restored.interactions.isNone())
        @Expect(restored.budget.deadlineMillis, 193)
        @Expect(restored.budget.maxWallMillis, 151)
        @Expect(restored.budget.requestOutputBudget.minVisibleResponseTokens, 107)
        @Expect(restored.budget.processLimits.cpuSeconds, 229)
        @Expect(restored.pricing.getOrThrow().inputMicrosPerMillion.getOrThrow(), 0)
        @Expect(restored.pricing.getOrThrow().outputMicrosPerMillion.isNone())
        @Expect(restored.modelCapabilitiesSnapshot.capabilityFingerprint, request.modelCapabilitiesSnapshot.capabilityFingerprint)
        @Expect(restored.modelCapabilitiesSnapshot.thinking.budgetTiers[1].budgetTokens, 29)
        @Expect(restored.modelCapabilitiesSnapshot.endpointMaxOutputTokens.getOrThrow(), 307)
        @Expect(restored.contextSnapshot.contributions()[0].validUntilMillis, 251)
        @Expect(restored.initializeContext)
        let local = coreContextBoundaryRequestFromValue(value, interactions: Some(ContextBoundaryRequestTestInteractions()))
        @Expect(local.interactions.getOrThrow().hasSteering())
        @Expect(canonicalAgentValue(coreContextBoundaryRequestValue(local)), canonicalAgentValue(value))
    }

    @TestCase
    func decodedRequestAndEncodedValueDoNotShareMutableModelOrCapabilityData(): Unit {
        let original = contextBoundaryRequestTestRequest()
        let value = coreContextBoundaryRequestValue(original)
        let before = canonicalAgentValue(value)
        original.structuredOutput.getOrThrow().schema.put("type", textValue("string"))
        original.imageInputs[0] = ModelImage(ModelImageSourceKind.Url, "https://example.invalid/changed.png")
        original.capabilities.values[0] = Capability(CapabilityKind.WorkspaceWrite)
        @Expect(canonicalAgentValue(value), before)
        let restored = coreContextBoundaryRequestFromValue(value)
        value.field("model_input").getOrThrow().put("cache_key", textValue("changed-cache"))
        value.field("model_capabilities").getOrThrow().field("thinking").getOrThrow().put("supported_levels", listValue([]))
        @Expect(canonicalAgentValue(coreContextBoundaryRequestValue(restored)), before)
    }

    @TestCase
    func toggleAndEmptyOptionalDataRemainExactlyRepresentable(): Unit {
        for (thinking in [ThinkingCapabilities(ThinkingControlMode.NoThinking), ThinkingCapabilities(ThinkingControlMode.Toggle),
            ThinkingCapabilities(ThinkingControlMode.Adaptive)]) {
            let request = AgentRunRequest(RunId("codec-minimal"), SessionId("codec-minimal"), "codec-model", "prompt",
                thinking: ThinkingLevel.Off, modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot("codec-model", thinking, 281)),
                budget: ResourceBudget(maxOutputTokens: 283, minVisibleResponseTokens: 0, maxWallMillis: 0))
            let value = coreContextBoundaryRequestValue(request)
            let restored = coreContextBoundaryRequestFromValue(value)
            @Expect(canonicalAgentValue(coreContextBoundaryRequestValue(restored)), canonicalAgentValue(value))
            @Expect(restored.modelCapabilitiesSnapshot.thinking.supportedLevels.size, thinking.supportedLevels.size)
            @Expect(restored.pricing.isNone() && restored.structuredOutput.isNone() && restored.imageInputs.isEmpty())
            @Expect(restored.budget.maxWallMillis, 0)
        }
    }

    @TestCase
    func everyOuterOrBudgetFieldIsRequiredAndUnknownNestedFieldsAreRejected(): Unit {
        let value = coreContextBoundaryRequestValue(contextBoundaryRequestTestRequest())
        for (field in value.fields) { @Expect(contextBoundaryRequestTestRejects(contextBoundaryRequestTestWithout(value, field.name))) }
        let budget = value.field("budget").getOrThrow()
        for (field in budget.fields) {
            let changed = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
            changed.put("budget", contextBoundaryRequestTestWithout(budget, field.name))
            @Expect(contextBoundaryRequestTestRejects(changed))
        }
        for (path in ["requested_policy", "model_capabilities", "model_input", "tool_context", "context_snapshot"]) {
            let changed = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
            changed.field(path).getOrThrow().put("unexpected", nullValue())
            @Expect(contextBoundaryRequestTestRejects(changed))
        }
    }

    @TestCase
    func driftedFingerprintsAliasesVersionsAndDescriptorsCannotBeSilentlyNormalized(): Unit {
        let value = coreContextBoundaryRequestValue(contextBoundaryRequestTestRequest())
        let fingerprint = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
        fingerprint.field("model_capabilities").getOrThrow().put("capability_fingerprint", textValue(""))
        @Expect(contextBoundaryRequestTestRejects(fingerprint))
        let alias = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
        alias.field("requested_policy").getOrThrow().field("request_output_budget").getOrThrow().put("hard_limit", integerValue(293))
        @Expect(contextBoundaryRequestTestRejects(alias))
        for (invalid in [integerValue(-1), integerValue(4294967296), numberValue("1.0"), textValue("9")]) {
            let changed = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
            changed.put("resolver_version", invalid)
            @Expect(contextBoundaryRequestTestRejects(changed))
        }
        let approval = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
        approval.put("approval_mode", textValue("unknown"))
        @Expect(contextBoundaryRequestTestRejects(approval))
        let duplicate = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
        let tool = duplicate.field("tool_context").getOrThrow()
        let entry = tool.field("environment").getOrThrow().items[0]
        tool.put("environment", listValue([entry, entry]))
        @Expect(contextBoundaryRequestTestRejects(duplicate))
        let hidden = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
        hidden.field("model_input").getOrThrow().field("messages").getOrThrow().items[0].field("blocks").getOrThrow().items[0].put("receipt_id", textValue("hidden-execution-state"))
        @Expect(contextBoundaryRequestTestRejects(hidden))
    }

    @TestCase
    func originalJsonDuplicatesAndOriginalEightMiBBoundAreEnforced(): Unit {
        let value = coreContextBoundaryRequestValue(contextBoundaryRequestTestRequest())
        let encoded = stringifyUnifiedJson(value)
        let duplicate = "{\"run_id\":\"duplicate\"," + encoded[1..]
        var rejected = false
        try { let _ = coreContextBoundaryRequestFromValue(parseUnifiedJson(duplicate, maxBytes: 8388608)) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected)
        let oversizedPrompt = String.fromUtf8(Array<UInt8>(8388609, repeat: b'x'))
        rejected = false
        try { let _ = coreContextBoundaryRequestValue(AgentRunRequest(RunId("too-large"), SessionId("too-large"), "codec-model", oversizedPrompt)) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }
}
