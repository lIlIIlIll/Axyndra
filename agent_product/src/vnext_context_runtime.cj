package agent_product

import std.collection.*
import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*

// Production bridge between AgentCore's provider effect boundary and the
// durable ContextManifest store. A request that cannot be reconstructed is
// rejected before it reaches ModelPort.
class ProductContextManifestRuntime <: ModelContextManifestRuntimePort {
    private let store: SqliteContextManifestStore
    private let compiler = ContextCompiler("agent-product-context-v1")

    init(database: SqliteDatabase) {
        store = SqliteContextManifestStore(database)
    }

    public func recordBeforeModelEffect(
        request: AgentRunRequest,
        requestId: RequestId,
        turnId: SemanticTurnId,
        stepId: StepId,
        projection: ModelContextProjection,
        lane: ModelLane,
        renderedRequest: AgentValue,
        estimatedInputTokens: Int64,
        observedAtMillis: Int64
    ): Result<Unit> {
        let intent = currentIntent(projection, turnId)
        let exactFields = ArrayList<ValueField>()
        exactFields.add(all: renderedRequest.fields)
        exactFields.add(ValueField("request_id", textValue(requestId.value)))
        let exactRequest = objectValue(exactFields.toArray())
        let system = exactRequest.field("system").getOrThrow().text
        let artifact = PromptArtifact(system)
        let contribution = PromptContribution(
            "agent-product-core", "run", "system.core", artifact.hash,
            PromptVisibility.Model
        )
        let skillIds = ArrayList<String>()
        for (activation in request.skillStack.active) {
            skillIds.add(activation.descriptor.id)
        }
        let memoryReferences = ArrayList<String>()
        for (reference in request.skillStack.loadedReferences) {
            memoryReferences.add(reference.skillId + "/" + reference.referenceId)
        }
        let manifestId = ContextManifestId(
            "context-" + request.runId.value + "-" + requestId.value
        )
        let boundedProjection = ModelContextProjection(
            projection.threadRevision,
            projection.checkpoint,
            projection.recentItems,
            projection.dynamicState,
            estimatedInputTokens,
            false
        )
        let compiled = compiler.compile(ContextCompileInput(
            manifestId,
            ThreadId(request.sessionId.value),
            LaneId("main"),
            turnId,
            stepId,
            boundedProjection,
            intent.id,
            objectValue([
                ValueField("thread_revision", integerValue(projection.threadRevision))
            ]),
            skillIds.toArray(),
            memoryReferences.toArray(),
            [contribution],
            [artifact],
            lane,
            exactRequest
        ))
        match (compiled) {
            case Result.Ok(manifest) => match (store.save(
                manifest, [artifact], observedAtMillis
            )) {
                case Result.Ok(_) => store.recordContextReady(
                    request.runId, manifest, observedAtMillis
                )
                case Result.Err(error) => Result.Err(error)
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func currentIntent(
        projection: ModelContextProjection,
        turnId: SemanticTurnId
    ): ThreadItem {
        var selected: ?ThreadItem = None
        for (item in projection.recentItems where item.turnId.value == turnId.value) {
            match (item.content) {
                case ThreadItemContent.UserMessage(_) => selected = Some(item)
                case _ => ()
            }
        }
        match (selected) {
            case Some(value) => value
            case None => throw IllegalStateException(
                "current model request has no durable Turn intent Item"
            )
        }
    }
}
