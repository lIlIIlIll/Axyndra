package agent_product

import agent_core.*
import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginContextPayloadTests {
    @TestCase
    func actualCanonicalReadAndPureSkillsRoundTripLargeReferenceIntoSameRunContext(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            let source = fixture.root + "/.omp/skills"
            writeObservedSkill(source, "Large observed reference instructions\n")
            let reference = String.fromUtf8(Array<Byte>(1048500, repeat: b'r')) + "\nfinal-reference-marker\n"
            File.writeTo(source + "/review/references/details.md", reference.toArray())
            let base = skillsReadRequest(fixture)
            // This case exercises the 1-MiB context payload/receipt path, so
            // explicitly provision the model input budget for those facts.
            // Production defaults and the actual payload bytes are unchanged.
            let request = AgentRunRequest(base.runId, base.sessionId, base.model, base.prompt,
                system: base.system, thinking: base.thinking,
                userRequestedThinking: base.requestedPolicy.userRequestedThinking,
                thinkingSource: base.requestedPolicy.thinkingSource,
                modelCapabilitiesSnapshot: Some(base.modelCapabilitiesSnapshot), resolverVersion: base.resolverVersion,
                capabilities: base.capabilities, interactions: base.interactions,
                approvalModeOverride: base.approvalModeOverride, autoRetry: base.autoRetry,
                serviceTier: base.serviceTier, pricing: base.pricing, imageInputs: base.imageInputs,
                structuredOutput: base.structuredOutput, cachePolicy: base.cachePolicy, cacheKey: base.cacheKey,
                parallelToolCalls: base.parallelToolCalls, toolContext: base.toolContext,
                contextSnapshot: base.contextSnapshot, initializeContext: base.initializeContext, contextWindow: 2101024,
                providerSafetyMargin: base.providerSafetyMargin, executionLaneId: base.executionLaneId,
                budget: ResourceBudget(maxInputTokens: 2000000, maxOutputTokens: base.budget.maxOutputTokens,
                    requestOutputBudget: Some(base.budget.requestOutputBudget),
                    maxTotalInputTokens: base.budget.maxTotalInputTokens, maxTotalOutputTokens: base.budget.maxTotalOutputTokens,
                    maxModelRequests: base.budget.maxModelRequests, maxTurns: base.budget.maxTurns,
                    maxDrainModelRequests: base.budget.maxDrainModelRequests, maxDrainTurns: base.budget.maxDrainTurns,
                    maxToolCalls: base.budget.maxToolCalls, maxWallMillis: base.budget.maxWallMillis,
                    maxIdleMillis: base.budget.maxIdleMillis, maxChildren: base.budget.maxChildren,
                    maxDepth: base.budget.maxDepth, maxConcurrentChildren: base.budget.maxConcurrentChildren,
                    maxContextMessages: base.budget.maxContextMessages, maxConcurrentTools: base.budget.maxConcurrentTools,
                    maxCostMicros: base.budget.maxCostMicros, deadlineMillis: base.budget.deadlineMillis,
                    processLimits: base.budget.processLimits))
            let capture = SkillsReadUpdateCapture(fixture, request,
                listValue([skillsReadResource(source, "workspace")]), ["workspace"])
            @Expect(contextDiagnosticRun(fixture, "large-reference", fixture.product.client.start(request, { event => capture.event(event) })).isOk())
            @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Applied)
            @Expect(skillsReadCount(fixture, "completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
            let snapshot = skillsReadSnapshot(fixture, request)
            let selected = snapshot.contributions()[1]
            @Expect(selected.references()[0].content.getOrThrow(), reference)
            @Expect(stringifyUnifiedJson(contextSnapshotValue(snapshot)).size > 196608)
            let operation = fixture.database.query("SELECT operation_id FROM operation_effect_records WHERE tool_id=?",
                [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])[0].required(0)
            let fact = lifecycleTestRequire(DurableOperationStore(fixture.database).loadContextReadFact(OperationId(operation), request.runId))
            @Expect(fact.outputBytes > 262144)
            @Expect(fact.origin.parentCallItemId, "")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            File.writeTo(source + "/review/references/details.md", "later unrelated contents".toArray())
            @Expect(lifecycleTestRequire(fixture.product.readPluginContextResource(snapshot, selected.owner,
                selected.id, "details.md", fixture.thread, cancellation: fixture.cancellation.token)), reference)
            let reopened = SqliteDatabase(fixture.root + "/state/state.db")
            try {
                let restored = contextSnapshotFromValue(decodeStoredValue(reopened.query("SELECT skill_snapshot FROM runs WHERE id=?",
                    [SqlParameter.Text(request.runId.value)])[0].required(0)))
                @Expect(restored.contributions()[1].references()[0].content.getOrThrow(), reference)
            } finally { reopened.close() }
            skillsReadSettled(fixture)
        } finally { fixture.close() }
    }

    @TestCase
    func publicPureQueryDoesNotAcquireExpandedObservedFactAuthorityOrAnOperation(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            let large = String.fromUtf8(Array<Byte>(262144, repeat: b'x'))
            let result = fixture.product.resolvePluginContext(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "skills",
                objectValue([ValueField("schema", textValue("axyndra.skills-query/v1")), ValueField("action", textValue("resolve")),
                    ValueField("prompt", textValue(large))]), fixture.thread, cancellation: fixture.cancellation.token)
            @Expect(result.isError())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.query("$review").isOk())
        } finally { fixture.close() }
    }
}
