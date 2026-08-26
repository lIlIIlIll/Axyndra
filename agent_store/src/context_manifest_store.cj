package agent_store

import yjson_support.*

import yjson.*

import std.collection.*
import std.convert.*
import agent_domain.*
import agent_runtime.*

public class SqliteContextManifestStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func ensureModelStep(
        runId: RunId,
        threadId: ThreadId,
        laneId: LaneId,
        turnId: SemanticTurnId,
        stepId: StepId,
        ordinal: Int64,
        inputEntryId: ?InboxEntryId,
        acceptedItemId: ?ItemId,
        observedAtMillis: Int64
    ): Result<Unit> {
        if (ordinal < 0 || observedAtMillis < 0 ||
            inputEntryId.isSome() != acceptedItemId.isSome()) {
            return manifestStoreError<Unit>(
                "context.step_invalid", "model Step enclosure is invalid"
            )
        }
        try {
            database.transaction { transaction =>
                let run = transaction.query(
                    "SELECT runs.thread_id,runs.turn_id,binding.lane_id FROM runs " +
                        "JOIN run_lane_bindings binding ON binding.run_id=runs.id WHERE runs.id=?",
                    [SqlParameter.Text(runId.value)]
                )
                if (run.size != 1 || run[0].required(0) != threadId.value ||
                    run[0].required(1) != turnId.value || run[0].required(2) != laneId.value) {
                    throw IllegalStateException("model Step Run/Lane enclosure changed")
                }
                let existing = transaction.query(
                    "SELECT thread_id,lane_id,turn_id,run_id,ordinal FROM step_records WHERE id=?",
                    [SqlParameter.Text(stepId.value)]
                )
                if (!existing.isEmpty()) {
                    if (existing.size != 1 || existing[0].required(0) != threadId.value ||
                        existing[0].required(1) != laneId.value ||
                        existing[0].required(2) != turnId.value ||
                        existing[0].required(3) != runId.value ||
                        manifestRowInt(existing[0].required(4), "Step ordinal") != ordinal) {
                        throw IllegalStateException("model Step id owns another enclosure")
                    }
                    return Result.Ok(())
                }

                let previous = transaction.query(
                    "SELECT id,input_entry_id FROM step_records WHERE run_id=? " +
                        "AND ordinal<? AND status='open' ORDER BY ordinal",
                    [SqlParameter.Text(runId.value), SqlParameter.Int64Value(ordinal)]
                )
                for (row in previous) {
                    transaction.execute(
                        "UPDATE step_records SET status='completed',settled_at_millis=?," +
                            "revision=revision+1 WHERE id=? AND status='open'",
                        [SqlParameter.Int64Value(observedAtMillis),
                            SqlParameter.Text(row.required(0))]
                    )
                    match (row[1]) {
                        case Some(entry) => transaction.execute(
                            "UPDATE lane_inbox_entries SET status='applied',revision=revision+1 " +
                                "WHERE id=? AND status='claimed' AND claimed_step_id=?",
                            [SqlParameter.Text(entry), SqlParameter.Text(row.required(0))]
                        )
                        case None => ()
                    }
                }

                match ((inputEntryId, acceptedItemId)) {
                    case (Some(entry), Some(item)) =>
                        if (transaction.query(
                            "SELECT 1 FROM lane_inbox_entries WHERE id=? AND thread_id=? " +
                                "AND lane_id=? AND status='queued'",
                            [SqlParameter.Text(entry.value), SqlParameter.Text(threadId.value),
                                SqlParameter.Text(laneId.value)]
                        ).size != 1 || transaction.query(
                            "SELECT 1 FROM items WHERE id=? AND thread_id=? AND turn_id=?",
                            [SqlParameter.Text(item.value), SqlParameter.Text(threadId.value),
                                SqlParameter.Text(turnId.value)]
                        ).size != 1) {
                            throw IllegalStateException(
                                "model Step Inbox entry or accepted Item is missing"
                            )
                        }
                    case (None, None) => ()
                    case _ => throw IllegalStateException("partial model Step input enclosure")
                }
                transaction.execute(
                    "INSERT INTO step_records(id,thread_id,lane_id,turn_id,run_id,ordinal," +
                        "input_entry_id,accepted_item_id,status,opened_at_millis," +
                        "settled_at_millis,revision) VALUES (?,?,?,?,?,?,?,?," +
                        "'open',?,NULL,1)",
                    [
                        SqlParameter.Text(stepId.value), SqlParameter.Text(threadId.value),
                        SqlParameter.Text(laneId.value), SqlParameter.Text(turnId.value),
                        SqlParameter.Text(runId.value), SqlParameter.Int64Value(ordinal),
                        optionalInboxParameter(inputEntryId),
                        optionalItemParameter(acceptedItemId),
                        SqlParameter.Int64Value(observedAtMillis)
                    ]
                )
                match (inputEntryId) {
                    case Some(entry) => transaction.execute(
                        "UPDATE lane_inbox_entries SET status='claimed',claimed_step_id=?," +
                            "revision=revision+1 WHERE id=? AND status='queued'",
                        [SqlParameter.Text(stepId.value), SqlParameter.Text(entry.value)]
                    )
                    case None => ()
                }
                Result.Ok(())
            }
        } catch (error: Exception) {
            manifestStoreError<Unit>("context.step_commit_failed", error.message)
        }
    }

    public func save(
        manifest: ModelContextManifest,
        artifacts: Array<PromptArtifact>,
        createdAtMillis: Int64
    ): Result<Unit> {
        if (!manifest.isSealed() || createdAtMillis < 0) {
            return manifestStoreError<Unit>(
                "context.manifest_invalid", "Context Manifest is not sealed"
            )
        }
        let payload = encodeContextManifest(manifest)
        try {
            database.transaction { transaction =>
                for (artifact in artifacts) {
                    let existing = transaction.query(
                        "SELECT content FROM prompt_contribution_artifacts WHERE hash=?",
                        [SqlParameter.Text(artifact.hash)]
                    )
                    if (existing.isEmpty()) {
                        transaction.execute(
                            "INSERT INTO prompt_contribution_artifacts(hash,content,created_at_millis) " +
                                "VALUES (?,?,?)",
                            [
                                SqlParameter.Text(artifact.hash), SqlParameter.Text(artifact.content),
                                SqlParameter.Int64Value(createdAtMillis)
                            ]
                        )
                    } else if (existing.size != 1 || existing[0].required(0) != artifact.content) {
                        throw IllegalStateException("Prompt artifact hash owns different content")
                    }
                }
                for (contribution in manifest.promptContributions) {
                    if (transaction.query(
                        "SELECT 1 FROM prompt_contribution_artifacts WHERE hash=?",
                        [SqlParameter.Text(contribution.artifactHash)]
                    ).size != 1) {
                        throw IllegalStateException("Context Manifest Prompt artifact is missing")
                    }
                }
                let existing = transaction.query(
                    "SELECT digest,payload FROM context_manifests WHERE id=?",
                    [SqlParameter.Text(manifest.id.value)]
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO context_manifests(" +
                            "id,thread_id,lane_id,turn_id,step_id,digest,payload,created_at_millis" +
                            ") VALUES (?,?,?,?,?,?,?,?)",
                        [
                            SqlParameter.Text(manifest.id.value),
                            SqlParameter.Text(manifest.threadId.value),
                            SqlParameter.Text(manifest.laneId.value),
                            SqlParameter.Text(manifest.turnId.value),
                            SqlParameter.Text(manifest.stepId.value),
                            SqlParameter.Text(manifest.digest), SqlParameter.Text(payload),
                            SqlParameter.Int64Value(createdAtMillis)
                        ]
                    )
                } else if (existing.size != 1 || existing[0].required(0) != manifest.digest ||
                    existing[0].required(1) != payload) {
                    throw IllegalStateException("Context Manifest id owns different content")
                }
                Result.Ok(())
            }
        } catch (error: Exception) {
            manifestStoreError<Unit>("context.manifest_commit_failed", error.message)
        }
    }

    public func load(id: ContextManifestId): Result<ModelContextManifest> {
        try {
            let rows = database.query(
                "SELECT digest,payload FROM context_manifests WHERE id=?",
                [SqlParameter.Text(id.value)]
            )
            if (rows.size != 1) {
                return manifestStoreError<ModelContextManifest>(
                    "context.manifest_missing", "Context Manifest does not exist"
                )
            }
            let value = decodeContextManifest(rows[0].required(1))
            if (value.id.value != id.value || value.digest != rows[0].required(0) ||
                !value.isSealed()) {
                return manifestStoreError<ModelContextManifest>(
                    "context.manifest_corrupt", "Context Manifest identity or digest is corrupt"
                )
            }
            Result.Ok(value)
        } catch (error: Exception) {
            manifestStoreError<ModelContextManifest>(
                "context.manifest_corrupt", error.message
            )
        }
    }

    // Advances the total continuation after the manifest is durable and
    // before AgentCore is allowed to dispatch the provider request.
    public func recordContextReady(
        runId: RunId,
        manifest: ModelContextManifest,
        observedAtMillis: Int64
    ): Result<Unit> {
        if (!manifest.isSealed() || observedAtMillis < 0) {
            return manifestStoreError<Unit>(
                "context.manifest_invalid", "Context Manifest is not sealed"
            )
        }
        try {
            database.transaction { transaction =>
                let enclosure = transaction.query(
                    "SELECT manifest.thread_id,manifest.lane_id,manifest.turn_id," +
                        "manifest.step_id,step.thread_id,step.lane_id,step.turn_id," +
                        "step.run_id,step.ordinal FROM context_manifests manifest " +
                        "JOIN step_records step ON step.id=manifest.step_id " +
                        "WHERE manifest.id=? AND manifest.digest=?",
                    [SqlParameter.Text(manifest.id.value), SqlParameter.Text(manifest.digest)]
                )
                if (enclosure.size != 1) {
                    throw IllegalStateException("Context Manifest is not durably committed")
                }
                let row = enclosure[0]
                if (row.required(0) != manifest.threadId.value ||
                    row.required(1) != manifest.laneId.value ||
                    row.required(2) != manifest.turnId.value ||
                    row.required(3) != manifest.stepId.value ||
                    row.required(4) != manifest.threadId.value ||
                    row.required(5) != manifest.laneId.value ||
                    row.required(6) != manifest.turnId.value ||
                    row.required(7) != runId.value) {
                    throw IllegalStateException(
                        "Context Manifest Step enclosure is inconsistent"
                    )
                }
                let stepOrdinal = manifestRowInt(row.required(8), "Step ordinal")
                let run = transaction.query(
                    "SELECT runs.thread_id,runs.turn_id,binding.snapshot_id FROM runs " +
                    "JOIN run_composition_bindings binding ON binding.run_id=runs.id " +
                        "WHERE runs.id=?",
                    [SqlParameter.Text(runId.value)]
                )
                if (run.size != 1 || run[0].required(0) != manifest.threadId.value ||
                    run[0].required(1) != manifest.turnId.value) {
                    throw IllegalStateException("Context Manifest Run enclosure changed")
                }
                let continuation = preserveRunContinuationProjection(
                    transaction,
                    sealDurableRunContinuation(DurableRunContinuationV1(
                    runId,
                    manifest.laneId,
                    manifest.turnId,
                    stepOrdinal,
                    RunExecutionPhase.ContextReady(DurablePhaseState(objectValue([
                        ValueField("context_manifest_id", textValue(manifest.id.value)),
                        ValueField("context_manifest_digest", textValue(manifest.digest))
                    ]))),
                    CompositionSnapshotId(run[0].required(2)),
                    ModelLaneSnapshotId("model-lane-" + runId.value),
                    contextManifestId: Some(manifest.id)
                )))
                let revision = contextManifestInt(transaction.query(
                    "SELECT COALESCE(MAX(revision),0) FROM run_continuation_facts WHERE run_id=?",
                    [SqlParameter.Text(runId.value)]
                )[0].required(0)) + 1
                let sequence = nextLegacyCommitSequence(transaction, manifest.threadId)
                let payload = encodeDurableRunContinuation(continuation)
                transaction.execute(
                    "INSERT INTO run_continuation_facts(" +
                        "run_id,thread_id,revision,commit_sequence,phase,payload,digest,created_at_millis" +
                        ") VALUES (?,?,?,?,?,?,?,?)",
                    [
                        SqlParameter.Text(runId.value), SqlParameter.Text(manifest.threadId.value),
                        SqlParameter.Int64Value(revision), SqlParameter.Int64Value(sequence),
                        SqlParameter.Text("context_ready"), SqlParameter.Text(payload),
                        SqlParameter.Text(continuation.digest),
                        SqlParameter.Int64Value(observedAtMillis)
                    ]
                )
                transaction.execute(
                    "INSERT INTO run_continuations(" +
                        "run_id,schema_version,revision,phase,payload,digest,updated_commit_sequence" +
                        ") VALUES (?,1,?,'context_ready',?,?,?) ON CONFLICT(run_id) DO UPDATE SET " +
                        "schema_version=1,revision=excluded.revision,phase=excluded.phase," +
                        "payload=excluded.payload,digest=excluded.digest," +
                        "updated_commit_sequence=excluded.updated_commit_sequence",
                    [
                        SqlParameter.Text(runId.value), SqlParameter.Int64Value(revision),
                        SqlParameter.Text(payload), SqlParameter.Text(continuation.digest),
                        SqlParameter.Int64Value(sequence)
                    ]
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            manifestStoreError<Unit>("context.continuation_commit_failed", error.message)
        }
    }
}

func optionalInboxParameter(value: ?InboxEntryId): SqlParameter {
    match (value) {
        case Some(item) => SqlParameter.Text(item.value)
        case None => SqlParameter.Null
    }
}

func optionalItemParameter(value: ?ItemId): SqlParameter {
    match (value) {
        case Some(item) => SqlParameter.Text(item.value)
        case None => SqlParameter.Null
    }
}

func manifestRowInt(value: String, name: String): Int64 {
    try { Int64.parse(value) } catch (_: Exception) {
        throw IllegalStateException("invalid " + name)
    }
}

func contextManifestInt(value: String): Int64 {
    try { Int64.parse(value) } catch (_: Exception) {
        throw IllegalStateException("Context Manifest continuation revision is invalid")
    }
}

public func encodeContextManifest(value: ModelContextManifest): String {
    if (!value.isSealed()) {
        throw IllegalArgumentException("Context Manifest must be sealed")
    }
    let items = ArrayList<AgentValue>()
    for (item in value.branchItemIds) { items.add(textValue(item.value)) }
    let skills = ArrayList<AgentValue>()
    for (item in value.activeSkillIds) { skills.add(textValue(item)) }
    let memories = ArrayList<AgentValue>()
    for (item in value.memoryReferences) { memories.add(textValue(item)) }
    let contributions = ArrayList<AgentValue>()
    for (item in value.promptContributions) {
        contributions.add(objectValue([
            ValueField("owner", textValue(item.ownerComponentId)),
            ValueField("scope", textValue(item.scope)),
            ValueField("order_band", textValue(item.orderBand)),
            ValueField("artifact_hash", textValue(item.artifactHash)),
            ValueField("visibility", textValue(manifestVisibilityName(item.visibility)))
        ]))
    }
    encodeStoredValue(objectValue([
        ValueField("version", integerValue(1)),
        ValueField("id", textValue(value.id.value)),
        ValueField("thread_id", textValue(value.threadId.value)),
        ValueField("lane_id", textValue(value.laneId.value)),
        ValueField("turn_id", textValue(value.turnId.value)),
        ValueField("step_id", textValue(value.stepId.value)),
        ValueField("thread_revision", integerValue(value.threadRevision)),
        ValueField("checkpoint_id", textValue(value.checkpointId)),
        ValueField("branch_item_ids", listValue(items.toArray())),
        ValueField("current_intent_item_id", textValue(value.currentIntentItemId.value)),
        ValueField("named_fact_versions", value.namedFactVersions),
        ValueField("active_skill_ids", listValue(skills.toArray())),
        ValueField("memory_references", listValue(memories.toArray())),
        ValueField("prompt_contributions", listValue(contributions.toArray())),
        ValueField("tool_catalog_snapshot", value.toolCatalogSnapshot),
        ValueField("token_budget", integerValue(value.tokenBudget)),
        ValueField("estimated_tokens", integerValue(value.estimatedTokens)),
        ValueField("rendered_request", value.renderedRequest),
        ValueField("compiler_version", textValue(value.compilerVersion)),
        ValueField("digest", textValue(value.digest))
    ]))
}

public func decodeContextManifest(source: String): ModelContextManifest {
    let value = decodeStoredValue(source)
    if (manifestStoreInt(value, "version") != 1) {
        throw IllegalStateException("unsupported Context Manifest version")
    }
    let items = ArrayList<ItemId>()
    for (item in manifestStoreList(value, "branch_item_ids")) {
        items.add(ItemId(manifestStoreTextValue(item, "branch item")))
    }
    let contributions = ArrayList<PromptContribution>()
    for (item in manifestStoreList(value, "prompt_contributions")) {
        contributions.add(PromptContribution(
            manifestStoreText(item, "owner"), manifestStoreText(item, "scope"),
            manifestStoreText(item, "order_band"), manifestStoreText(item, "artifact_hash"),
            parseManifestVisibility(manifestStoreText(item, "visibility"))
        ))
    }
    let result = ModelContextManifest(
        ContextManifestId(manifestStoreText(value, "id")),
        ThreadId(manifestStoreText(value, "thread_id")),
        LaneId(manifestStoreText(value, "lane_id")),
        SemanticTurnId(manifestStoreText(value, "turn_id")),
        StepId(manifestStoreText(value, "step_id")),
        manifestStoreInt(value, "thread_revision"), items.toArray(),
        ItemId(manifestStoreText(value, "current_intent_item_id")),
        manifestStoreField(value, "named_fact_versions"),
        manifestStoreStrings(value, "active_skill_ids"),
        manifestStoreStrings(value, "memory_references"), contributions.toArray(),
        manifestStoreField(value, "tool_catalog_snapshot"),
        manifestStoreInt(value, "token_budget"),
        manifestStoreInt(value, "estimated_tokens"),
        manifestStoreField(value, "rendered_request"),
        manifestStoreText(value, "compiler_version"),
        checkpointId: manifestStoreText(value, "checkpoint_id"),
        digest: manifestStoreText(value, "digest")
    )
    if (encodeContextManifest(result) != source) {
        throw IllegalStateException("Context Manifest encoding is not canonical")
    }
    result
}

func manifestStoreField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalStateException("Context Manifest field is missing: " + name)
    }
}

func manifestStoreText(value: AgentValue, name: String): String {
    manifestStoreTextValue(manifestStoreField(value, name), name)
}

func manifestStoreTextValue(value: AgentValue, name: String): String {
    if (value.unifiedKind != ValueKind.Text) {
        throw IllegalStateException("Context Manifest field is not text: " + name)
    }
    value.text
}

func manifestStoreInt(value: AgentValue, name: String): Int64 {
    let field = manifestStoreField(value, name)
    if (field.unifiedKind != ValueKind.Number) {
        throw IllegalStateException("Context Manifest field is not an integer: " + name)
    }
    try { Int64.parse(field.number) } catch (_: Exception) {
        throw IllegalStateException("Context Manifest integer is invalid: " + name)
    }
}

func manifestStoreList(value: AgentValue, name: String): Array<AgentValue> {
    let field = manifestStoreField(value, name)
    if (field.unifiedKind != ValueKind.List) {
        throw IllegalStateException("Context Manifest field is not a list: " + name)
    }
    field.items
}

func manifestStoreStrings(value: AgentValue, name: String): Array<String> {
    let result = ArrayList<String>()
    for (item in manifestStoreList(value, name)) {
        result.add(manifestStoreTextValue(item, name))
    }
    result.toArray()
}

func manifestVisibilityName(value: PromptVisibility): String {
    match (value) {
        case PromptVisibility.Model => "model"
        case PromptVisibility.AuditOnly => "audit_only"
        case PromptVisibility.Hidden => "hidden"
    }
}

func parseManifestVisibility(value: String): PromptVisibility {
    match (value) {
        case "model" => PromptVisibility.Model
        case "audit_only" => PromptVisibility.AuditOnly
        case "hidden" => PromptVisibility.Hidden
        case _ => throw IllegalStateException("unknown Prompt visibility")
    }
}

func manifestStoreError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message))
}
