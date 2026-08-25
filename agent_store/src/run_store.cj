package agent_store

import std.convert.*
import agent_domain.*
import agent_runtime.*
import agent_skills.*

public class DurableRunSnapshot {
    public let id: RunId
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let epoch: Int64
    public let state: RunState
    public let transitionSequence: Int64
    public let lane: ?ModelLane
    public let skills: ?SkillStackSnapshot
    public let budget: AgentValue
    public let usage: AgentValue
    public let startedAtMillis: Int64
    public let finishedAtMillis: ?Int64
    public let cancellationReason: ?String
    public let executionLaneId: LaneId

    public init(
        id: RunId,
        threadId: ThreadId,
        turnId: SemanticTurnId,
        epoch: Int64,
        state: RunState,
        transitionSequence: Int64,
        lane: ?ModelLane,
        skills: ?SkillStackSnapshot,
        budget: AgentValue,
        usage: AgentValue,
        startedAtMillis: Int64,
        finishedAtMillis: ?Int64,
        cancellationReason: ?String,
        executionLaneId!: LaneId = LaneId("main")
    ) {
        this.id = id
        this.threadId = threadId
        this.turnId = turnId
        this.epoch = epoch
        this.state = state
        this.transitionSequence = transitionSequence
        this.lane = lane
        this.skills = skills
        this.budget = budget
        this.usage = usage
        this.startedAtMillis = startedAtMillis
        this.finishedAtMillis = finishedAtMillis
        this.cancellationReason = cancellationReason
        this.executionLaneId = executionLaneId
    }

    public func hasRecoverableLaunchSnapshot(): Bool {
        lane.isSome() && skills.isSome()
    }
}

public class SqliteRunStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func load(runId: RunId): DurableRunSnapshot {
        let rows = database.query(
            "SELECT runs.thread_id,runs.turn_id,runs.epoch,runs.state,runs.lane_snapshot," +
                "runs.skill_snapshot,runs.budget,runs.usage,runs.started_at_millis," +
                "runs.finished_at_millis,runs.cancellation_reason,binding.lane_id FROM runs " +
                "JOIN run_lane_bindings binding ON binding.run_id=runs.id WHERE runs.id=" +
                sqliteText(runId.value)
        )
        if (rows.size != 1) { throw IllegalStateException("durable Run does not exist") }
        let row = rows[0]
        let laneValue = decodeStoredValue(row.required(4))
        let skillValue = decodeStoredValue(row.required(5))
        let lane: ?ModelLane = if (emptyStoredObject(laneValue)) {
            None
        } else {
            Some(modelLaneFromSnapshotValue(laneValue))
        }
        let skills: ?SkillStackSnapshot = if (emptyStoredObject(skillValue)) {
            None
        } else {
            Some(skillStackFromSnapshotValue(skillValue))
        }
        let journalRows = database.query(
            "SELECT COALESCE(MAX(sequence),0) FROM run_journal WHERE run_id=" +
                sqliteText(runId.value)
        )
        DurableRunSnapshot(
            runId, ThreadId(row.required(0)), SemanticTurnId(row.required(1)),
            parseRunStoreInt(row.required(2), "Run epoch"),
            runStateFromName(row.required(3)),
            parseRunStoreInt(journalRows[0].required(0), "Run journal sequence"),
            lane, skills, decodeStoredValue(row.required(6)), decodeStoredValue(row.required(7)),
            parseRunStoreInt(row.required(8), "Run start timestamp"),
            optionalRunStoreInt(row[9], "Run finish timestamp"), row[10],
            executionLaneId: LaneId(row.required(11))
        )
    }

    public func loadActive(threadId: ThreadId): ?DurableRunSnapshot {
        let rows = database.query(
            "SELECT runs.id FROM runs JOIN threads ON threads.active_turn_id=runs.turn_id " +
                "AND threads.id=runs.thread_id WHERE threads.id=" + sqliteText(threadId.value)
        )
        if (rows.isEmpty()) { return None }
        if (rows.size != 1) { throw IllegalStateException("Thread has multiple active durable Runs") }
        Some(load(RunId(rows[0].required(0))))
    }
}

func emptyStoredObject(value: AgentValue): Bool {
    value.kind == ValueKind.Object && value.fields.isEmpty()
}

func parseRunStoreInt(value: String, field: String): Int64 {
    try { Int64.parse(value) } catch (_: Exception) {
        throw IllegalStateException(field + " is not an integer")
    }
}

func optionalRunStoreInt(value: ?String, field: String): ?Int64 {
    match (value) {
        case Some(item) => Some(parseRunStoreInt(item, field))
        case None => None
    }
}
