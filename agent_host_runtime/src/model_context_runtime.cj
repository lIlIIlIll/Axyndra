package agent_host_runtime

import yjson_support.*

import yjson.*

import std.collection.*
import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*

// Production bridge between AgentCore's provider effect boundary and the
// durable ContextManifest store. A request that cannot be reconstructed is
// rejected before it reaches ModelPort.
public open class HostContextManifestRuntime <: ModelContextManifestRuntimePort & ReturningModelContextManifestRuntime159 {
    private let store: SqliteContextManifestStore
    private let database: SqliteDatabase
    private let compiler: ContextCompiler
    private let promptOwner: String

    public init(database: SqliteDatabase, compilerVersion!: String = "agent-host-context-v1",
        promptOwner!: String = "agent-host-core") {
        this.database = database
        this.compiler = ContextCompiler(compilerVersion); this.promptOwner = promptOwner
        store = SqliteContextManifestStore(database)
    }

    public func recordBeforeModelEffectWithOwnedLane159(loan: ?ModelInputToolsBorrow159,
        active: OwnedActiveRunFrame159, request: AgentRunRequest, requestId: RequestId,
        stepId: StepId, stepOrdinal: Int64, projection: ModelContextProjection,
        renderedRequest: AgentValue, estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        let result = recordWithActiveLaneFrame159(active, request, requestId, stepId,
            stepOrdinal, projection, renderedRequest, estimatedInputTokens, observedAtMillis)
        match (result) {
            case Result.Ok(_) =>
                // The entire concrete lane/manifest/compiler/SQL call returned;
                // clear the view before returning its independent payment.
                active.returnActiveRunFrame159()
                match (loan) { case Some(value) => value.returnModelToolsFrame159(); case None => () }
            case Result.Err(_) => ()
        }
        result
    }
    private func recordWithActiveLaneFrame159(active: OwnedActiveRunFrame159,
        request: AgentRunRequest, requestId: RequestId, stepId: StepId,
        stepOrdinal: Int64, projection: ModelContextProjection, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        let value = active.snapshot159()
        recordBeforeModelEffectOwnedFrame159(request, requestId, value.turnId,
            value.executionLaneId, stepId, stepOrdinal, projection, value.lane,
            renderedRequest, estimatedInputTokens, observedAtMillis)
    }

    public func recordBeforeModelEffectReturning159(loan: ModelInputToolsBorrow159,
        request: AgentRunRequest, requestId: RequestId, turnId: SemanticTurnId,
        executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64): Result<Unit> {
        // Uses the closed concrete wrapper and its private whole SQL body.
        // No manifest/DOM/request is stored in this host object.
        let result = recordBeforeModelEffectOwnedFrame159(request, requestId, turnId, executionLaneId, stepId, stepOrdinal, projection, lane, renderedRequest, estimatedInputTokens, observedAtMillis)
        match (result) { case Result.Ok(_) => loan.returnModelToolsFrame159(); case Result.Err(_) => () }
        result
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
        recordBeforeModelEffectOwnedFrame159(request, requestId, turnId, executionLaneId,
            stepId, stepOrdinal, projection, lane, renderedRequest, estimatedInputTokens, observedAtMillis)
    }

    private func recordBeforeModelEffectOwnedFrame159(
        request: AgentRunRequest, requestId: RequestId, turnId: SemanticTurnId,
        executionLaneId: LaneId, stepId: StepId, stepOrdinal: Int64,
        projection: ModelContextProjection, lane: ModelLane, renderedRequest: AgentValue,
        estimatedInputTokens: Int64, observedAtMillis: Int64
    ): Result<Unit> {
        var catalog159 = lane.ownedManifestCatalog159()
        // The complete concrete helper contains all input, manifest, codec,
        // transaction closures and SQL statements. It returns no raw catalog.
        let result = recordBeforeModelEffectFrame159(request, requestId, turnId, executionLaneId, stepId, stepOrdinal, projection, lane, renderedRequest, estimatedInputTokens, observedAtMillis, catalog159)
        match (result) {
            case Result.Ok(_) =>
                match (catalog159) { case Some(value) => value.closeAfterManifestStoreFrame159(); case None => () }
                catalog159 = None<OwnedToolCatalogValue159>
            case Result.Err(_) => ()
        }
        result
    }

    private func recordBeforeModelEffectFrame159(
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
        observedAtMillis: Int64, catalog159: ?OwnedToolCatalogValue159
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
            case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else {
                return hostContextRuntimeError(
                    "context.rendered_system_invalid",
                    "rendered model request system field is not text"
                )
            }
            case None => return hostContextRuntimeError(
                "context.rendered_system_missing",
                "rendered model request has no system field"
            )
        }
        let artifact = PromptArtifact(system)
        let contribution = PromptContribution(
            promptOwner, "run", "system.core", artifact.hash,
            PromptVisibility.Model
        )
        let skillIds = ArrayList<String>()
        let memoryReferences = ArrayList<String>()
        for (contribution in request.contextSnapshot.contributions()) {
            // Reuse the existing immutable manifest dimensions. Qualify every
            // identity by provider; there is no second catalog or revision.
            let identity = canonicalAgentValue(listValue([textValue(contribution.owner), textValue(contribution.id)]))
            skillIds.add(identity)
            for (reference in contribution.references() where reference.content.isSome()) {
                memoryReferences.add(canonicalAgentValue(listValue([
                    textValue(contribution.owner), textValue(contribution.id), textValue(reference.id)
                ])))
            }
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
        let compileInput159 = ContextCompileInput(
            manifestId,
            ThreadId(request.sessionId.value),
            executionLaneId,
            turnId,
            stepId,
            boundedProjection,
            intent.id,
            objectValue([
                ValueField("thread_revision", integerValue(projection.threadRevision)),
                ValueField("context_snapshot_digest", textValue(contextReadProjectionDigest(request.contextSnapshot)))
            ]),
            skillIds.toArray(),
            memoryReferences.toArray(),
            [contribution],
            [artifact],
            lane,
            exactRequest
        )
        let compiled = match (catalog159) {
            case Some(value) => compiler.compileOwnedCatalog159(compileInput159, value)
            case None => compiler.compile(compileInput159)
        }
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
                case ThreadItemContent.SystemNote(_) =>
                    if (isContinuationInitiatorDescription(item)) {
                        try {
                            // This only reads the actual consumed claim. It does
                            // not mint an owner or reinterpret an arbitrary note.
                            database.readTransaction<Unit>({ tx =>
                                let _ = consumedContinuationRequest(tx, item)
                            })
                            selected = Some(item)
                        } catch (_: Exception) {
                            return hostContextRuntimeError<ThreadItem>("context.continuation_claim_invalid",
                                "current continuation intent has no exact consumed Run claim")
                        }
                    }
                case _ => ()
            }
        }
        match (selected) {
            case Some(value) => Result.Ok(value)
            case None => hostContextRuntimeError<ThreadItem>(
                "context.turn_intent_missing",
                "current model request has no durable Turn intent Item"
            )
        }
    }
}

func hostContextRuntimeError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired,
        code,
        message
    ))
}
