package agent_store

import std.collection.*
import std.convert.*
import agent_domain.*
import agent_runtime.*

public class SqliteContextManifestStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

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
    if (value.kind != ValueKind.Text) {
        throw IllegalStateException("Context Manifest field is not text: " + name)
    }
    value.text
}

func manifestStoreInt(value: AgentValue, name: String): Int64 {
    let field = manifestStoreField(value, name)
    if (field.kind != ValueKind.Number) {
        throw IllegalStateException("Context Manifest field is not an integer: " + name)
    }
    try { Int64.parse(field.number) } catch (_: Exception) {
        throw IllegalStateException("Context Manifest integer is invalid: " + name)
    }
}

func manifestStoreList(value: AgentValue, name: String): Array<AgentValue> {
    let field = manifestStoreField(value, name)
    if (field.kind != ValueKind.List) {
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
