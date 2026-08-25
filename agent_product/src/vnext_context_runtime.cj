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
        executionLaneId: LaneId,
        stepId: StepId,
        stepOrdinal: Int64,
        projection: ModelContextProjection,
        lane: ModelLane,
        renderedRequest: AgentValue,
        estimatedInputTokens: Int64,
        observedAtMillis: Int64
    ): Result<Unit> {
        let intent = match (currentIntent(projection, turnId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let exactFields = ArrayList<ValueField>()
        exactFields.add(all: renderedRequest.fields)
        exactFields.add(ValueField("request_id", textValue(requestId.value)))
        let exactRequest = objectValue(exactFields.toArray())
        let system = match (exactRequest.field("system")) {
            case Some(value) => if (value.kind == ValueKind.Text) { value.text } else {
                return contextRuntimeError(
                    "context.rendered_system_invalid",
                    "rendered model request system field is not text"
                )
            }
            case None => return contextRuntimeError(
                "context.rendered_system_missing",
                "rendered model request has no system field"
            )
        }
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
        let (inputEntryId, acceptedItemId) = if (stepOrdinal > 0 &&
            intent.provenance.source == "interaction") {
            (Some(InboxEntryId(intent.id.value)), Some(intent.id))
        } else {
            (Option<InboxEntryId>.None, Option<ItemId>.None)
        }
        match (store.ensureModelStep(
            request.runId,
            ThreadId(request.sessionId.value),
            executionLaneId,
            turnId,
            stepId,
            stepOrdinal,
            inputEntryId,
            acceptedItemId,
            observedAtMillis
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let compiled = compiler.compile(ContextCompileInput(
            manifestId,
            ThreadId(request.sessionId.value),
            executionLaneId,
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
    ): Result<ThreadItem> {
        var selected: ?ThreadItem = None
        for (item in projection.recentItems where item.turnId.value == turnId.value) {
            match (item.content) {
                case ThreadItemContent.UserMessage(_) => selected = Some(item)
                case _ => ()
            }
        }
        match (selected) {
            case Some(value) => Result.Ok(value)
            case None => contextRuntimeError<ThreadItem>(
                "context.turn_intent_missing",
                "current model request has no durable Turn intent Item"
            )
        }
    }
}

func contextRuntimeError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired,
        code,
        message
    ))
}
