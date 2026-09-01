package agent_store

import yjson_support.*

import yjson.*

import std.collection.*
import agent_domain.*
import agent_runtime.*

public class SqliteContextCheckpointStore <: ContextCheckpointRepository {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func save(
        checkpoint: ContextCheckpoint,
        thread: AgentThreadSnapshot,
        createdAtMillis: Int64
    ): Result<Unit> {
        if (createdAtMillis < 0) {
            return checkpointStoreError(
                "context.checkpoint_timestamp_invalid",
                "checkpoint timestamp must not be negative"
            )
        }
        if (checkpoint.threadId.value != thread.thread.id.value) {
            return checkpointStoreError(
                "context.checkpoint_wrong_thread",
                "checkpoint belongs to another Thread"
            )
        }
        match (validateContextCheckpointBoundary(
            thread, checkpoint.coversThroughItemOrdinal
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (checkpoint.sourceDigest != contextSourceDigest(
            thread, checkpoint.coversThroughItemOrdinal
        )) {
            return checkpointStoreError(
                "context.checkpoint_digest_mismatch",
                "checkpoint digest does not bind the canonical Thread prefix"
            )
        }
        let payload = encodeCheckpointPayload(checkpoint)
        try {
            database.transaction { transaction =>
                requireStoreRow(
                    transaction,
                    "SELECT id FROM threads WHERE id=" + sqliteText(thread.thread.id.value),
                    [thread.thread.id.value],
                    "checkpoint Thread does not exist durably"
                )
                let existing = transaction.query(
                    "SELECT thread_id,covers_through_item_ordinal,projector_version," +
                        "lane_compatibility,source_digest,payload FROM context_checkpoints WHERE id=" +
                        sqliteText(checkpoint.id)
                )
                let expected = [
                    checkpoint.threadId.value,
                    checkpoint.coversThroughItemOrdinal.toString(),
                    checkpoint.projectorVersion, checkpoint.laneCompatibility,
                    checkpoint.sourceDigest, payload
                ]
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO context_checkpoints " +
                            "(id,thread_id,covers_through_item_ordinal,projector_version," +
                            "lane_compatibility,source_digest,payload,created_at_millis) VALUES (" +
                            sqliteText(checkpoint.id) + "," + sqliteText(checkpoint.threadId.value) + "," +
                            checkpoint.coversThroughItemOrdinal.toString() + "," +
                            sqliteText(checkpoint.projectorVersion) + "," +
                            sqliteText(checkpoint.laneCompatibility) + "," +
                            sqliteText(checkpoint.sourceDigest) + "," + sqliteText(payload) + "," +
                            createdAtMillis.toString() + ")"
                    )
                } else {
                    if (existing.size != 1 || existing[0].size != expected.size) {
                        throw IllegalStateException("checkpoint identity is ambiguous")
                    }
                    for (index in 0..expected.size where
                        existing[0].required(index) != expected[index]) {
                        throw IllegalStateException("checkpoint id already has different content")
                    }
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            checkpointStoreError("context.checkpoint_commit_failed", error.message)
        }
    }

    // Incompatible or stale checkpoints are disposable projections, never a
    // recovery failure. Callers rebuild from canonical Items when None.
    public func loadLatest(
        thread: AgentThreadSnapshot,
        projectorVersion: String,
        laneCompatibility: String
    ): ?ContextCheckpoint {
        let rows = database.query(
            "SELECT id,covers_through_item_ordinal,source_digest,payload " +
                "FROM context_checkpoints WHERE thread_id=" +
                sqliteText(thread.thread.id.value) + " AND projector_version=" +
                sqliteText(projectorVersion) + " AND lane_compatibility=" +
                sqliteText(laneCompatibility) + " ORDER BY covers_through_item_ordinal DESC,id DESC"
        )
        for (row in rows) {
            let cover = parseStoreInt(row.required(1), "checkpoint cover")
            if (cover < 1 || cover >= thread.thread.nextItemOrdinal) { continue }
            if (row.required(2) != contextSourceDigest(thread, cover)) { continue }
            match (validateContextCheckpointBoundary(thread, cover)) {
                case Result.Err(_) => continue
                case Result.Ok(_) => ()
            }
            return Some(decodeCheckpointPayload(
                row.required(0), thread.thread.id, cover, row.required(2),
                projectorVersion, laneCompatibility, row.required(3)
            ))
        }
        None
    }
}

func encodeCheckpointPayload(checkpoint: ContextCheckpoint): String {
    let notes = ArrayList<AgentValue>()
    for (note in checkpoint.durableNotes) { notes.add(textValue(note)) }
    let artifacts = ArrayList<AgentValue>()
    for (reference in checkpoint.artifactReferences) { artifacts.add(textValue(reference)) }
    encodeStoredValue(objectValue([
        ValueField("structured_summary", checkpoint.structuredSummary),
        ValueField("active_state", checkpoint.activeState),
        ValueField("active_goal", textValue(checkpoint.activeGoal)),
        ValueField("durable_notes", listValue(notes.toArray())),
        ValueField("artifact_references", listValue(artifacts.toArray()))
    ]))
}

func decodeCheckpointPayload(
    id: String,
    threadId: ThreadId,
    cover: Int64,
    sourceDigest: String,
    projectorVersion: String,
    laneCompatibility: String,
    payload: String
): ContextCheckpoint {
    let value = decodeStoredValue(payload)
    ContextCheckpoint(
        id, threadId, cover, checkpointField(value, "structured_summary"),
        sourceDigest, projectorVersion, laneCompatibility,
        activeState: checkpointField(value, "active_state"),
        activeGoal: checkpointTextField(value, "active_goal"),
        durableNotes: checkpointStringList(value, "durable_notes"),
        artifactReferences: checkpointStringList(value, "artifact_references")
    )
}

func checkpointField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalStateException("checkpoint payload field is missing: " + name)
    }
}

func checkpointTextField(value: AgentValue, name: String): String {
    let item = checkpointField(value, name)
    if (item.unifiedKind != ValueKind.Text) {
        throw IllegalStateException("checkpoint payload field is not text: " + name)
    }
    item.text
}

func checkpointStringList(value: AgentValue, name: String): Array<String> {
    let item = checkpointField(value, name)
    if (item.unifiedKind != ValueKind.List) {
        throw IllegalStateException("checkpoint payload field is not a list: " + name)
    }
    let result = ArrayList<String>()
    for (candidate in item.items) {
        if (candidate.unifiedKind != ValueKind.Text) {
            throw IllegalStateException("checkpoint payload list contains a non-text value")
        }
        result.add(candidate.text)
    }
    result.toArray()
}

func checkpointStoreError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message))
}
