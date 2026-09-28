package agent_product

import yjson_support.*

import yjson.*

import agent_app_protocol.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.convert.*

let RUN_INSPECTION_CONTEXT_LIMIT: Int64 = 20
let RUN_INSPECTION_MODEL_LIMIT: Int64 = 100
let RUN_INSPECTION_NESTED_LIMIT: Int64 = 100

// Projects canonical durable state into the shared App Protocol. It never
// returns prompt text, rendered requests, normalized arguments, environment
// values, receipt detail, or artifact content.
public class ProductRunInspectionProjection {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        this.database = database
    }

    public func latestRunId(threadId: ThreadId): Result<RunId> {
        try {
            let rows = database.query(
                "SELECT id FROM runs WHERE thread_id=" + sqliteText(threadId.value) +
                    " ORDER BY started_at_millis DESC,id DESC LIMIT 1"
            )
            if (rows.isEmpty()) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "inspection.run_missing",
                    "Thread has no durable Run",
                    fields: [ErrorField("thread_id", threadId.value)]
                ))
            }
            Result.Ok(RunId(rows[0].required(0)))
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "inspection.run_lookup_failed",
                error.message,
                fields: [ErrorField("thread_id", threadId.value)]
            ))
        }
    }

    public func inspect(
        threadId: ThreadId,
        runId: RunId,
        beforeCursor: Int64,
        limit: Int64
    ): Result<AppRunInspectionPage> {
        if (beforeCursor < 0 || limit < 1 || limit > 100) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "inspection.page_invalid",
                "beforeCursor must be non-negative and limit must be between 1 and 100"
            ))
        }
        try {
            database.readTransaction { transaction =>
                let revisionRows = transaction.query(
                    "SELECT revision FROM threads WHERE id=" + sqliteText(threadId.value)
                )
                if (revisionRows.size != 1) {
                    return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "product.app_thread_missing",
                        "Thread does not exist"
                    ))
                }
                let threadRevision = Int64.parse(revisionRows[0].required(0))
                let run = SqliteRunStore(database).load(transaction, runId)
                if (run.threadId.value != threadId.value) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "inspection.run_thread_mismatch",
                        "Run does not belong to the requested Thread",
                        fields: [
                            ErrorField("thread_id", threadId.value),
                            ErrorField("run_id", runId.value)
                        ]
                    ))
                }
                let warnings = ArrayList<String>()
                let lane = run.lane
                let providerId = match (lane) {
                    case Some(value) => value.providerId
                    case None =>
                        warnings.add("run.model_lane_missing")
                        ""
                }
                let modelId = match (lane) {
                    case Some(value) => value.modelId
                    case None => ""
                }
                let role = match (lane) {
                    case Some(value) => modelLaneRoleName(value.role)
                    case None => "unknown"
                }

                let activeSkillIds = ArrayList<String>()
                match (run.skills) {
                    case Some(snapshot) => for (activation in snapshot.active) {
                        if (activeSkillIds.size < RUN_INSPECTION_NESTED_LIMIT) {
                            activeSkillIds.add(activation.descriptor.id)
                        }
                    }
                    case None => warnings.add("run.skill_snapshot_missing")
                }

                var compositionProfile = ""
                var compositionVersion = ""
                var compositionDigest = ""
                var toolVisibilityDigest = ""
                var promptGraphDigest = ""
                let components = ArrayList<String>()
                match (SqliteCompositionSnapshotStore(database).loadRun(transaction, runId)) {
                    case Result.Ok(snapshot) =>
                        compositionProfile = snapshot.profileId
                        compositionVersion = snapshot.profileVersion
                        compositionDigest = snapshot.digest
                        toolVisibilityDigest = snapshot.toolVisibilityDigest
                        promptGraphDigest = snapshot.promptGraphDigest
                        for (component in snapshot.componentInstances) {
                            if (components.size < RUN_INSPECTION_NESTED_LIMIT) {
                                components.add(
                                    component.instanceId + ":" + component.componentId + "@" +
                                        component.componentVersion + "#" + component.generation.toString()
                                )
                            }
                        }
                        if (snapshot.componentInstances.size > RUN_INSPECTION_NESTED_LIMIT) {
                            warnings.add("composition.components_truncated")
                        }
                    case Result.Err(error) => warnings.add("composition:" + error.code)
                }

                let contexts = inspectContexts(transaction, runId, warnings)
                let history = inspectHistory(transaction, runId, threadId, warnings)
                let requests = inspectModelRequests(
                    transaction, runId, role, providerId, modelId, warnings
                )
                let operationPage = inspectOperations(
                    transaction, runId, beforeCursor, limit, warnings
                )

                Result.Ok(AppRunInspectionPage(
                    threadId,
                    runId,
                    threadRevision,
                    runStateName(run.state),
                    providerId,
                    modelId,
                    compositionProfile,
                    compositionVersion,
                    compositionDigest,
                    toolVisibilityDigest,
                    promptGraphDigest,
                    components.toArray(),
                    activeSkillIds.toArray(),
                    contexts,
                    history,
                    requests,
                    operationPage.operations,
                    warnings.toArray(),
                    operationPage.nextBeforeCursor
                ))
            }
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "inspection.projection_failed",
                error.message,
                fields: [ErrorField("run_id", runId.value)]
            ))
        }
    }

    private func inspectHistory(
        transaction: SqliteTransaction,
        runId: RunId,
        threadId: ThreadId,
        warnings: ArrayList<String>
    ): AppRunHistoryEvidence {
        let manifests = transaction.query(
            "SELECT manifest.payload FROM context_manifests manifest " +
                "JOIN step_records step ON step.id=manifest.step_id WHERE step.run_id=" +
                sqliteText(runId.value) +
                " ORDER BY step.ordinal DESC,manifest.id DESC LIMIT 1"
        )
        if (manifests.isEmpty()) {
            warnings.add("history.context_manifest_missing")
            return AppRunHistoryEvidence(
                "canonical_items_without_checkpoint", "", "", "", "", 0, false
            )
        }
        let checkpointId = try {
            decodeContextManifest(manifests[0].required(0)).checkpointId.trimAscii()
        } catch (_: Exception) {
            warnings.add("history.context_manifest_unreadable")
            return AppRunHistoryEvidence(
                "canonical_items_without_checkpoint", "", "", "", "", 0, false
            )
        }
        if (checkpointId == "") {
            return AppRunHistoryEvidence(
                "canonical_items_without_checkpoint", "", "", "", "", 0, false
            )
        }
        let rows = transaction.query(
            "SELECT id,covers_through_item_ordinal,projector_version,lane_compatibility," +
                "source_digest,payload FROM context_checkpoints WHERE id=" +
                sqliteText(checkpointId) + " AND thread_id=" + sqliteText(threadId.value) +
                " LIMIT 1"
        )
        if (rows.isEmpty()) {
            warnings.add("history.checkpoint_missing")
            return AppRunHistoryEvidence(
                "canonical_items_without_checkpoint", "", "", "", "", 0, false
            )
        }
        let row = rows[0]
        var summaryAvailable = false
        try {
            summaryAvailable = decodeStoredValue(row.required(5)).field("structured_summary").isSome()
        } catch (_: Exception) {
            warnings.add("history.checkpoint_payload_unreadable:" + row.required(0))
        }
        AppRunHistoryEvidence(
            "canonical_items_plus_compatible_checkpoint",
            row.required(0),
            row.required(4),
            row.required(2),
            row.required(3),
            Int64.parse(row.required(1)),
            summaryAvailable
        )
    }
    private func inspectContexts(
        transaction: SqliteTransaction,
        runId: RunId,
        warnings: ArrayList<String>
    ): Array<AppRunContextEvidence> {
        let rows = transaction.query(
            "SELECT manifest.payload FROM context_manifests manifest " +
                "JOIN step_records step ON step.id=manifest.step_id WHERE step.run_id=" +
                sqliteText(runId.value) + " ORDER BY step.ordinal DESC,manifest.id DESC LIMIT " +
                (RUN_INSPECTION_CONTEXT_LIMIT + 1).toString()
        )
        let contexts = ArrayList<AppRunContextEvidence>()
        var count: Int64 = 0
        for (row in rows) {
            if (count >= RUN_INSPECTION_CONTEXT_LIMIT) {
                warnings.add("context.manifests_truncated")
                break
            }
            count++
            try {
                let manifest = decodeContextManifest(row.required(0))
                let prompts = ArrayList<AppRunPromptEvidence>()
                for (prompt in manifest.promptContributions) {
                    if (prompts.size >= RUN_INSPECTION_NESTED_LIMIT) {
                        warnings.add("context.prompt_contributions_truncated:" + manifest.id.value)
                        break
                    }
                    prompts.add(AppRunPromptEvidence(
                        prompt.ownerComponentId,
                        prompt.scope,
                        prompt.orderBand,
                        prompt.artifactHash,
                        promptVisibilityName(prompt.visibility)
                    ))
                }
                let tools = inspectionTools(manifest.toolCatalogSnapshot, manifest.id.value, warnings)
                contexts.add(AppRunContextEvidence(
                    manifest.id.value,
                    manifest.digest,
                    manifest.compilerVersion,
                    "",
                    manifest.estimatedTokens,
                    manifest.tokenBudget,
                    inspectionBoundStrings(
                        manifest.activeSkillIds,
                        "context.skills_truncated:" + manifest.id.value,
                        warnings
                    ),
                    prompts.toArray(),
                    tools
                ))
            } catch (_: Exception) {
                warnings.add("context.manifest_unreadable")
            }
        }
        contexts.toArray()
    }

    private func inspectModelRequests(
        transaction: SqliteTransaction,
        runId: RunId,
        role: String,
        defaultProviderId: String,
        modelId: String,
        warnings: ArrayList<String>
    ): Array<AppRunModelRequestEvidence> {
        let rows = database.query(
            "SELECT recent.id,recent.provider_request_id,recent.semantic_request_id," +
                "recent.parent_attempt_id,recent.attempt_no,recent.lifecycle," +
                "recent.dispatch_state,recent.replay_barrier,recent.semantic_request_digest," +
                "recent.wire_policy_digest,recent.decision_id,recent.decision_outcome," +
                "recent.provider_id,recent.content_hash FROM (" +
                "SELECT attempt.id,attempt.provider_request_id,attempt.semantic_request_id," +
                "COALESCE(attempt.parent_attempt_id,'') AS parent_attempt_id," +
                "attempt.attempt_no,attempt.lifecycle,attempt.dispatch_state," +
                "attempt.replay_barrier,attempt.semantic_request_digest," +
                "attempt.wire_policy_digest,COALESCE(decision.id,'') AS decision_id," +
                "COALESCE(decision.decision_outcome,'') AS decision_outcome," +
                "COALESCE(decision.provider_id,'') AS provider_id," +
                "COALESCE(decision.content_hash,'') AS content_hash," +
                "attempt.started_at_millis FROM model_attempts attempt " +
                "LEFT JOIN model_decisions decision ON decision.attempt_id=attempt.id " +
                "WHERE attempt.run_id=" + sqliteText(runId.value) +
                " ORDER BY attempt.started_at_millis DESC,attempt.attempt_no DESC," +
                "attempt.id DESC LIMIT " + (RUN_INSPECTION_MODEL_LIMIT + 1).toString() +
                ") recent ORDER BY recent.started_at_millis,recent.attempt_no,recent.id"
        )
        let values = ArrayList<AppRunModelRequestEvidence>()
        let skip = if (rows.size > RUN_INSPECTION_MODEL_LIMIT) {
            warnings.add("model.requests_truncated")
            rows.size - RUN_INSPECTION_MODEL_LIMIT
        } else {
            0
        }
        var rowIndex: Int64 = 0
        var sequence: Int64 = 0
        for (row in rows) {
            if (rowIndex < skip) {
                rowIndex++
                continue
            }
            rowIndex++
            sequence++
            let decisionId = row.required(10)
            var usageSource = "unknown"
            var inputTokens: ?Int64 = None
            var outputTokens: ?Int64 = None
            var reasoningTokens: ?Int64 = None
            var cacheReadTokens: ?Int64 = None
            var cacheWriteTokens: ?Int64 = None
            var costMicros: ?Int64 = None
            if (decisionId != "") {
                try {
                    let usage = SqliteModelDecisionStore(database).loadDecision(
                        transaction, ModelDecisionId(decisionId)
                    ).usage
                    match (usage) {
                        case Some(actual) =>
                            usageSource = modelUsageSourceName(actual.source)
                            if (actual.source != ModelUsageSource.Unknown) {
                                inputTokens = Some(actual.inputTokens)
                                outputTokens = Some(actual.outputTokens)
                                reasoningTokens = Some(actual.reasoningTokens)
                                cacheReadTokens = Some(actual.cacheReadTokens)
                                cacheWriteTokens = Some(actual.cacheWriteTokens)
                                costMicros = actual.costMicros
                            }
                        case None => ()
                    }
                } catch (_: Exception) {
                    warnings.add("model.usage_unreadable:" + decisionId)
                }
            }
            values.add(AppRunModelRequestEvidence(
                row.required(0),
                row.required(1),
                row.required(2),
                row.required(3),
                sequence,
                Int64.parse(row.required(4)),
                role,
                if (row.required(12) == "") { defaultProviderId } else { row.required(12) },
                modelId,
                row.required(5),
                row.required(6),
                row.required(7),
                row.required(8),
                row.required(9),
                decisionId,
                if (row.required(11) == "") { row.required(5) } else { row.required(11) },
                row.required(13),
                usageSource,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                costMicros: costMicros
            ))
        }
        values.toArray()
    }

    private func inspectOperations(
        transaction: SqliteTransaction,
        runId: RunId,
        beforeCursor: Int64,
        limit: Int64,
        warnings: ArrayList<String>
    ): ProductOperationInspectionPage {
        let cursorClause = if (beforeCursor == 0) {
            ""
        } else {
            " AND effect.rowid<" + beforeCursor.toString()
        }
        let rows = transaction.query(
            "SELECT effect.rowid,effect.operation_id,COALESCE(derived.parent_operation_id,'')," +
                "effect.tool_id,effect.tool_version,effect.implementation_fingerprint," +
                "effect.schema_digest,effect.effective_arguments_digest,effect.replay_disposition," +
                "state.state,operation.effect_class," +
                "COALESCE((SELECT approval.decision FROM approvals approval " +
                    "WHERE approval.operation_id=effect.operation_id ORDER BY approval.rowid DESC LIMIT 1),'not_required')," +
                "COALESCE((SELECT approval.source FROM approvals approval " +
                    "WHERE approval.operation_id=effect.operation_id ORDER BY approval.rowid DESC LIMIT 1),'policy')," +
                "COALESCE(receipt.outcome,'missing'),COALESCE(result.payload,'') " +
                "FROM operation_effect_records effect " +
                "JOIN operation_state_registers state ON state.operation_id=effect.operation_id " +
                "JOIN operations operation ON operation.id=effect.operation_id " +
                "LEFT JOIN derived_operation_admissions derived ON derived.operation_id=effect.operation_id " +
                "LEFT JOIN operation_receipts receipt ON receipt.operation_id=effect.operation_id " +
                "LEFT JOIN items result ON result.id=effect.reserved_result_item_id " +
                "WHERE effect.run_id=" + sqliteText(runId.value) + cursorClause +
                " ORDER BY effect.rowid DESC LIMIT " + (limit + 1).toString()
        )
        let values = ArrayList<AppRunOperationEvidence>()
        var nextBeforeCursor: Int64 = 0
        var count: Int64 = 0
        for (row in rows) {
            if (count >= limit) {
                nextBeforeCursor = values[values.size - 1].cursor
                break
            }
            count++
            let operationId = OperationId(row.required(1))
            var reasons: Array<String> = []
            var programSourceHash = ""
            match (DurableOperationStore(database).loadPlan(
                transaction, operationId, runId
            )) {
                case Result.Ok(plan) =>
                    reasons = inspectionBoundStrings(
                        plan.approvalMetadata.assessment.reasons,
                        "operation.approval_reasons_truncated:" + operationId.value,
                        warnings
                    )
                    if (row.required(3) == "run_program") {
                        let source = inspectionValueText(plan.canonicalArguments, "source")
                        if (source != "") { programSourceHash = artifactSha256(source.toArray()) }
                    }
                case Result.Err(_) => warnings.add("operation.plan_unreadable:" + operationId.value)
            }
            let state = row.required(9)
            let outcome = row.required(13)
            let program = inspectProgramEvidence(
                row.required(3), row.required(14), programSourceHash, operationId, warnings
            )
            values.add(AppRunOperationEvidence(
                Int64.parse(row.required(0)),
                operationId,
                if (row.required(2) == "") { None } else { Some(OperationId(row.required(2))) },
                row.required(3),
                row.required(4),
                row.required(5),
                row.required(6),
                row.required(7),
                row.required(8),
                program.sdk,
                program.artifactHash,
                state,
                row.required(10),
                row.required(11),
                row.required(12),
                reasons,
                outcome,
                operationRecoveryGuidance(state, outcome)
            ))
        }
        ProductOperationInspectionPage(values.toArray(), nextBeforeCursor)
    }
}

class ProductProgramInspectionEvidence {
    let sdk: String
    let artifactHash: String

    init(sdk: String, artifactHash: String) {
        this.sdk = sdk
        this.artifactHash = artifactHash
    }
}

func inspectProgramEvidence(
    toolName: String,
    resultPayload: String,
    approvedSourceHash: String,
    operationId: OperationId,
    warnings: ArrayList<String>
): ProductProgramInspectionEvidence {
    if (toolName != "run_program") {
        return ProductProgramInspectionEvidence("", "")
    }
    let sdk = "tool-program-sdk-v1/worker-protocol-v1"
    if (resultPayload == "") {
        if (approvedSourceHash == "") {
            warnings.add("program.result_missing:" + operationId.value)
        } else {
            warnings.add("program.result_missing_using_approved_source_identity:" + operationId.value)
        }
        return ProductProgramInspectionEvidence(sdk, approvedSourceHash)
    }
    try {
        match (decodeStoredThreadContent(resultPayload)) {
            case ThreadItemContent.ToolResult(_, _, _, result, _) =>
                let artifactHash = inspectionValueText(result, "program_sha256")
                if (artifactHash == "") {
                    if (approvedSourceHash == "") {
                        warnings.add("program.artifact_hash_missing:" + operationId.value)
                    } else {
                        warnings.add("program.artifact_hash_missing_using_approved_source_identity:" + operationId.value)
                    }
                }
                ProductProgramInspectionEvidence(
                    sdk, if (artifactHash == "") { approvedSourceHash } else { artifactHash }
                )
            case _ =>
                warnings.add("program.result_unreadable:" + operationId.value)
                ProductProgramInspectionEvidence(sdk, approvedSourceHash)
        }
    } catch (_: Exception) {
        warnings.add("program.result_unreadable:" + operationId.value)
        ProductProgramInspectionEvidence(sdk, approvedSourceHash)
    }
}

class ProductOperationInspectionPage {
    let operations: Array<AppRunOperationEvidence>
    let nextBeforeCursor: Int64

    init(operations: Array<AppRunOperationEvidence>, nextBeforeCursor: Int64) {
        this.operations = operations
        this.nextBeforeCursor = nextBeforeCursor
    }
}

func inspectionTools(
    snapshot: AgentValue,
    manifestId: String,
    warnings: ArrayList<String>
): Array<AppRunToolEvidence> {
    let tools = ArrayList<AppRunToolEvidence>()
    match (snapshot.field("entries")) {
        case Some(value) => if (value.unifiedKind == ValueKind.List) {
            for (entry in value.items) {
                if (tools.size >= RUN_INSPECTION_NESTED_LIMIT) {
                    warnings.add("context.tools_truncated:" + manifestId)
                    break
                }
                let name = inspectionValueText(entry, "name")
                if (name == "") {
                    warnings.add("context.tool_identity_missing:" + manifestId)
                    continue
                }
                tools.add(AppRunToolEvidence(
                    name,
                    inspectionValueText(entry, "executor_version"),
                    inspectionValueText(entry, "implementation_fingerprint"),
                    inspectionValueText(entry, "schema_digest"),
                    inspectionValueBool(entry, "available_at_snapshot")
                ))
            }
        }
        case None => ()
    }
    tools.toArray()
}

func inspectionBoundStrings(
    source: Array<String>,
    warning: String,
    warnings: ArrayList<String>
): Array<String> {
    if (source.size <= RUN_INSPECTION_NESTED_LIMIT) { return source }
    let values = ArrayList<String>()
    for (index in 0..RUN_INSPECTION_NESTED_LIMIT) { values.add(source[index]) }
    warnings.add(warning)
    values.toArray()
}

func inspectionValueText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func inspectionValueBool(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(field) => field.unifiedKind == ValueKind.Boolean && field.asBool()
        case None => false
    }
}

func promptVisibilityName(value: PromptVisibility): String {
    match (value) {
        case PromptVisibility.Model => "model"
        case PromptVisibility.AuditOnly => "audit_only"
        case PromptVisibility.Hidden => "hidden"
    }
}

func operationRecoveryGuidance(state: String, outcome: String): String {
    if (outcome == "unknown" || outcome == "missing" || state == "executing" || state == "verifying") {
        "reconcile durable receipt and actual effects before retrying"
    } else if (state == "failed" || state == "cancelled" || state == "timed_out" ||
        state == "rejected") {
        "inspect approval and receipt evidence; reissue only as a new authorized operation"
    } else {
        ""
    }
}
