package agent_product

import agent_core.*
import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import tool_runtime.*

@Test
class ApplicationHandoffRequestTests {
    @TestCase
    func planModeRaisesDefaultThinkingByTwoWithHighFloor(): Unit {
        @Expect(planModeThinking(ThinkingLevel.Off) == ThinkingLevel.High)
        @Expect(planModeThinking(ThinkingLevel.Minimal) == ThinkingLevel.High)
        @Expect(planModeThinking(ThinkingLevel.Low) == ThinkingLevel.High)
        @Expect(planModeThinking(ThinkingLevel.Medium) == ThinkingLevel.XHigh)
        @Expect(planModeThinking(ThinkingLevel.High) == ThinkingLevel.Max)
        @Expect(planModeThinking(ThinkingLevel.XHigh) == ThinkingLevel.Max)
        @Expect(planModeThinking(ThinkingLevel.Max) == ThinkingLevel.Max)
    }

    @TestCase
    func handoffPreservesProviderAndRuntimeProtocol(): Unit {
        let interactions = HandoffTestInteractions()
        let base = AgentRunRequest(
            RunId("handoff-run"),
            SessionId("handoff-session"),
            "priced-model",
            "handoff prompt",
            system: "base system",
            thinking: ThinkingLevel.High,
            capabilities: CapabilitySet(values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.NetworkAccess)
            ]),
            budget: ResourceBudget(
                maxInputTokens: 1234,
                maxOutputTokens: 567,
                maxWallMillis: 890,
                maxCostMicros: 4321
            ),
            interactions: Some(interactions),
            approvalModeOverride: Some(ApprovalMode.Yolo),
            autoRetry: false,
            serviceTier: "priority",
            pricing: Some(ModelPricing(
                inputMicrosPerMillion: Some(100),
                outputMicrosPerMillion: Some(200),
                cacheReadMicrosPerMillion: Some(25),
                cacheWriteMicrosPerMillion: Some(125)
            )),
            imageInputs: [ModelImage(
                ModelImageSourceKind.Url,
                "https://example.test/image.png",
                detail: ModelImageDetail.High
            )],
            structuredOutput: Some(StructuredOutputSpec(
                "handoff_document",
                objectValue([ValueField("type", textValue("object"))])
            )),
            cachePolicy: ModelCachePolicy.StablePrefix,
            cacheKey: "handoff-cache-key",
            parallelToolCalls: true,
            toolContext: ToolContextDescriptor(
                workspaceRoot: "/workspace",
                cwd: "/workspace/subdir"
            )
        )

        let request = handoffRunRequest(base)

        @Expect(request.runId.value, base.runId.value)
        @Expect(request.sessionId.value, base.sessionId.value)
        @Expect(request.model, base.model)
        @Expect(request.prompt, base.prompt)
        @Expect(request.system.contains("Return only the document and do not call tools."))
        @Expect(request.thinking == ThinkingLevel.High)
        @Expect(request.capabilities.allows(CapabilityKind.WorkspaceRead))
        @Expect(request.capabilities.allows(CapabilityKind.NetworkAccess))
        @Expect(request.budget.maxInputTokens, 1234)
        @Expect(request.budget.maxOutputTokens, 567)
        @Expect(request.budget.maxWallMillis, 890)
        @Expect(request.budget.maxCostMicros, 4321)
        @Expect(request.interactions.isSome())
        @Expect(request.approvalModeOverride == Some(ApprovalMode.Yolo))
        @Expect(!request.autoRetry)
        @Expect(request.serviceTier, "priority")
        @Expect(match (request.pricing) {
            case Some(value) => value.inputMicrosPerMillion == Some(100) &&
                value.outputMicrosPerMillion == Some(200) &&
                value.cacheReadMicrosPerMillion == Some(25) &&
                value.cacheWriteMicrosPerMillion == Some(125)
            case None => false
        })
        @Expect(request.imageInputs.size, 1)
        @Expect(request.imageInputs[0].data, "https://example.test/image.png")
        @Expect(match (request.structuredOutput) {
            case Some(value) => value.name == "handoff_document" && value.strict
            case None => false
        })
        @Expect(request.cachePolicy == ModelCachePolicy.StablePrefix)
        @Expect(request.cacheKey, "handoff-cache-key")
        @Expect(request.parallelToolCalls)
        @Expect(request.toolContext.workspaceRoot, "/workspace")
        @Expect(request.toolContext.cwd, "/workspace/subdir")
    }
}

class HandoffTestInteractions <: AgentInteractionSource {
    public func takeSteering(): Array<AgentQueuedInput> { [] }
    public func hasSteering(): Bool { false }
    public func takeFollowUps(): Array<AgentQueuedInput> { [] }
    public func interruptMode(): RunInterruptMode { RunInterruptMode.Wait }
}
