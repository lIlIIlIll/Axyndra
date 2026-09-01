package agent_store

import yjson_support.*

import yjson.*

import std.collection.*
import std.convert.*
import agent_domain.*

public class SqliteLaneTreeStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func createLane(value: LaneRecord): Result<Unit> {
        if (value.kind != LaneKind.SharedHistoryChild) {
            return laneConflict<Unit>("only shared-history child Lane creation is supported here")
        }
        try {
            database.transaction { transaction =>
                let parent = value.parentLaneId.getOrThrow()
                let fork = value.forkItemId.getOrThrow()
                let ancestry = transaction.query(
                    "SELECT lanes.status FROM lanes JOIN item_tree_edges edge " +
                        "ON edge.thread_id=lanes.thread_id AND edge.lane_id=lanes.lane_id " +
                        "WHERE lanes.thread_id=? AND lanes.lane_id=? AND edge.item_id=?",
                    [
                        SqlParameter.Text(value.threadId.value),
                        SqlParameter.Text(parent.value), SqlParameter.Text(fork.value)
                    ]
                )
                if (ancestry.size != 1 || ancestry[0].required(0) != "open") {
                    return laneConflict<Unit>("Lane fork point is not owned by an open parent Lane")
                }
                let payload = encodeStoredValue(value.config)
                let existing = transaction.query(
                    "SELECT kind,parent_lane_id,fork_item_id,config,status FROM lanes " +
                        "WHERE thread_id=? AND lane_id=?",
                    [SqlParameter.Text(value.threadId.value), SqlParameter.Text(value.id.value)]
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO lanes(thread_id,lane_id,kind,parent_lane_id,fork_item_id," +
                            "config,status,created_at_millis) VALUES (?,?,?,?,?,?,'open',?)",
                        [
                            SqlParameter.Text(value.threadId.value),
                            SqlParameter.Text(value.id.value),
                            SqlParameter.Text(laneKindName(value.kind)),
                            SqlParameter.Text(parent.value), SqlParameter.Text(fork.value),
                            SqlParameter.Text(payload),
                            SqlParameter.Int64Value(value.createdAtMillis)
                        ]
                    )
                    Result.Ok(())
                } else if (existing.size == 1 &&
                    existing[0].required(0) == laneKindName(value.kind) &&
                    existing[0].required(1) == parent.value &&
                    existing[0].required(2) == fork.value &&
                    existing[0].required(3) == payload) {
                    Result.Ok(())
                } else {
                    laneConflict<Unit>("Lane id already owns different ancestry")
                }
            }
        } catch (error: Exception) {
            laneRecovery<Unit>("lane.create_failed", error.message)
        }
    }

    // Legacy append paths are automatically linked to main by SQLite. A
    // vNext child-Lane append rebinds that provisional edge in the same outer
    // transaction that created the Item.
    public func bindItem(
        itemId: ItemId,
        threadId: ThreadId,
        laneId: LaneId,
        parentItemId: ItemId
    ): Result<Unit> {
        try {
            database.transaction { transaction =>
                let rows = transaction.query(
                    "SELECT items.thread_id,edge.lane_id FROM items JOIN item_tree_edges edge " +
                        "ON edge.item_id=items.id WHERE items.id=?",
                    [SqlParameter.Text(itemId.value)]
                )
                if (rows.size != 1 || rows[0].required(0) != threadId.value) {
                    return laneConflict<Unit>("Item is not owned by the target Thread")
                }
                if (!branchContainsLocked(transaction, threadId, laneId, parentItemId)) {
                    return laneConflict<Unit>("Item parent is outside the target Lane branch")
                }
                let depthRows = transaction.query(
                    "SELECT depth FROM item_tree_edges WHERE item_id=?",
                    [SqlParameter.Text(parentItemId.value)]
                )
                transaction.execute(
                    "UPDATE item_tree_edges SET lane_id=?,parent_item_id=?,depth=? WHERE item_id=?",
                    [
                        SqlParameter.Text(laneId.value), SqlParameter.Text(parentItemId.value),
                        SqlParameter.Int64Value(laneDepth(depthRows[0].required(0)) + 1),
                        SqlParameter.Text(itemId.value)
                    ]
                )
                Result.Ok(())
            }
        } catch (error: Exception) {
            laneRecovery<Unit>("lane.bind_item_failed", error.message)
        }
    }

    public func branchItemIds(
        threadId: ThreadId,
        laneId: LaneId
    ): Result<Array<ItemId>> {
        try {
            database.readTransaction { transaction =>
                Result.Ok(loadBranchLocked(transaction, threadId, laneId, 0))
            }
        } catch (error: Exception) {
            laneRecovery<Array<ItemId>>("lane.branch_read_failed", error.message)
        }
    }

    public func readyLaneIds(
        threadId: ThreadId,
        afterLaneId!: String = "",
        limit!: Int64 = 64
    ): Result<Array<LaneId>> {
        if (limit < 1 || limit > 256) {
            return laneConflict<Array<LaneId>>("ready Lane query limit is invalid")
        }
        try {
            database.readTransaction { transaction =>
                let rows = transaction.query(
                    "SELECT inbox.lane_id FROM lane_inbox_entries inbox JOIN lanes " +
                        "ON lanes.thread_id=inbox.thread_id AND lanes.lane_id=inbox.lane_id " +
                        "WHERE inbox.thread_id=? AND inbox.status='queued' AND lanes.status='open' " +
                        "GROUP BY inbox.lane_id ORDER BY CASE WHEN inbox.lane_id>? THEN 0 ELSE 1 END," +
                        "inbox.lane_id LIMIT ?",
                    [
                        SqlParameter.Text(threadId.value),
                        SqlParameter.Text(afterLaneId.trimAscii()),
                        SqlParameter.Int64Value(limit)
                    ]
                )
                let output = ArrayList<LaneId>()
                for (row in rows) { output.add(LaneId(row.required(0))) }
                Result.Ok(output.toArray())
            }
        } catch (error: Exception) {
            laneRecovery<Array<LaneId>>("lane.ready_query_failed", error.message)
        }
    }

    public func acquireLaneRun(
        threadId: ThreadId,
        laneId: LaneId,
        runId: RunId,
        ownerId: String,
        nowMillis: Int64,
        leaseMillis: Int64
    ): Result<LaneRunAdmission> {
        let owner = ownerId.trimAscii()
        if (owner == "" || nowMillis < 0 || leaseMillis < 1 ||
            nowMillis > Int64.Max - leaseMillis) {
            return laneConflict<LaneRunAdmission>("Lane Run lease request is invalid")
        }
        let expires = nowMillis + leaseMillis
        try {
            database.transaction { transaction =>
                let lane = transaction.query(
                    "SELECT status FROM lanes WHERE thread_id=? AND lane_id=?",
                    [SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value)]
                )
                if (lane.size != 1 || lane[0].required(0) != "open") {
                    return laneConflict<LaneRunAdmission>("Lane is absent or closed")
                }
                let existing = transaction.query(
                    "SELECT run_id,owner_id,fence_token,expires_at_millis,state,revision " +
                        "FROM lane_run_admissions WHERE thread_id=? AND lane_id=?",
                    [SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value)]
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO lane_run_admissions VALUES (?,?,?,?,?,?,'active',1)",
                        [
                            SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value),
                            SqlParameter.Text(runId.value), SqlParameter.Text(owner),
                            SqlParameter.Int64Value(1), SqlParameter.Int64Value(expires)
                        ]
                    )
                    recordLaneAdmissionAudit(
                        transaction, threadId, runId, laneId, owner, 1, "lane.run_acquired",
                        nowMillis
                    )
                    Result.Ok(LaneRunAdmission(
                        threadId, laneId, runId, owner, 1, expires
                    ))
                } else {
                    let currentRun = existing[0].required(0)
                    let currentOwner = existing[0].required(1)
                    let fence = laneDepth(existing[0].required(2))
                    let currentExpiry = laneDepth(existing[0].required(3))
                    let state = existing[0].required(4)
                    let revision = laneDepth(existing[0].required(5))
                    if (state == "active" && currentExpiry > nowMillis) {
                        if (currentRun == runId.value && currentOwner == owner) {
                            return Result.Ok(LaneRunAdmission(
                                threadId, laneId, runId, owner, fence, currentExpiry
                            ))
                        }
                        return laneConflict<LaneRunAdmission>(
                            "Lane already owns another active Run"
                        )
                    }
                    if (fence == Int64.Max || revision == Int64.Max) {
                        return laneConflict<LaneRunAdmission>("Lane Run fence is exhausted")
                    }
                    let nextFence = fence + 1
                    transaction.execute(
                        "UPDATE lane_run_admissions SET run_id=?,owner_id=?,fence_token=?," +
                            "expires_at_millis=?,state='active',revision=revision+1 " +
                            "WHERE thread_id=? AND lane_id=? AND revision=?",
                        [
                            SqlParameter.Text(runId.value), SqlParameter.Text(owner),
                            SqlParameter.Int64Value(nextFence), SqlParameter.Int64Value(expires),
                            SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value),
                            SqlParameter.Int64Value(revision)
                        ]
                    )
                    requireStoreChanged(transaction, "Lane Run acquisition lost its fence")
                    recordLaneAdmissionAudit(
                        transaction, threadId, runId, laneId, owner, nextFence,
                        "lane.run_acquired", nowMillis
                    )
                    Result.Ok(LaneRunAdmission(
                        threadId, laneId, runId, owner, nextFence, expires
                    ))
                }
            }
        } catch (error: Exception) {
            laneRecovery<LaneRunAdmission>("lane.run_acquire_failed", error.message)
        }
    }

    public func renewLaneRun(
        admission: LaneRunAdmission,
        nowMillis: Int64,
        leaseMillis: Int64
    ): Result<LaneRunAdmission> {
        if (nowMillis < 0 || leaseMillis < 1 || nowMillis > Int64.Max - leaseMillis) {
            return laneConflict<LaneRunAdmission>("Lane Run renewal is invalid")
        }
        let expires = nowMillis + leaseMillis
        try {
            database.transaction { transaction =>
                transaction.execute(
                    "UPDATE lane_run_admissions SET expires_at_millis=?,revision=revision+1 " +
                        "WHERE thread_id=? AND lane_id=? AND run_id=? AND owner_id=? " +
                        "AND fence_token=? AND state='active' AND expires_at_millis>?",
                    [
                        SqlParameter.Int64Value(expires),
                        SqlParameter.Text(admission.threadId.value),
                        SqlParameter.Text(admission.laneId.value),
                        SqlParameter.Text(admission.runId.value),
                        SqlParameter.Text(admission.ownerId),
                        SqlParameter.Int64Value(admission.fenceToken),
                        SqlParameter.Int64Value(nowMillis)
                    ]
                )
                requireStoreChanged(transaction, "Lane Run renewal lost its fence")
                Result.Ok(LaneRunAdmission(
                    admission.threadId, admission.laneId, admission.runId,
                    admission.ownerId, admission.fenceToken, expires
                ))
            }
        } catch (error: Exception) {
            laneRecovery<LaneRunAdmission>("lane.run_renew_failed", error.message)
        }
    }

    public func releaseLaneRun(
        admission: LaneRunAdmission,
        releasedAtMillis: Int64
    ): Result<Unit> {
        if (releasedAtMillis < 0) {
            return laneConflict<Unit>("Lane Run release timestamp is invalid")
        }
        try {
            database.transaction { transaction =>
                transaction.execute(
                    "UPDATE lane_run_admissions SET state='released',revision=revision+1 " +
                        "WHERE thread_id=? AND lane_id=? AND run_id=? AND owner_id=? " +
                        "AND fence_token=? AND state='active'",
                    [
                        SqlParameter.Text(admission.threadId.value),
                        SqlParameter.Text(admission.laneId.value),
                        SqlParameter.Text(admission.runId.value),
                        SqlParameter.Text(admission.ownerId),
                        SqlParameter.Int64Value(admission.fenceToken)
                    ]
                )
                requireStoreChanged(transaction, "Lane Run release lost its fence")
                recordLaneAdmissionAudit(
                    transaction, admission.threadId, admission.runId,
                    admission.laneId, admission.ownerId, admission.fenceToken,
                    "lane.run_released", releasedAtMillis
                )
                Result.Ok(())
            }
        } catch (error: Exception) {
            laneRecovery<Unit>("lane.run_release_failed", error.message)
        }
    }

    // Forking is an isolation boundary, not another cursor in the source
    // Thread. The selected branch prefix is copied into a new idle Thread in
    // one transaction and its source anchor is retained as an append-only
    // audit fact. No Run, approval, capability grant, or mutable register is
    // inherited.
    public func forkThread(
        sourceThreadId: ThreadId,
        sourceLaneId: LaneId,
        forkItemId: ItemId,
        targetThreadId: ThreadId,
        targetWorkspaceId: String,
        createdAtMillis: Int64
    ): Result<Array<ItemId>> {
        if (sourceThreadId.value == targetThreadId.value ||
            targetWorkspaceId.trimAscii() == "" || createdAtMillis < 0) {
            return laneConflict<Array<ItemId>>("isolated Thread fork request is invalid")
        }
        let forkFact = encodeStoredValue(objectValue([
            ValueField("source_thread_id", textValue(sourceThreadId.value)),
            ValueField("source_lane_id", textValue(sourceLaneId.value)),
            ValueField("source_item_id", textValue(forkItemId.value)),
            ValueField("target_thread_id", textValue(targetThreadId.value)),
            ValueField("target_workspace_id", textValue(targetWorkspaceId.trimAscii()))
        ]))
        try {
            database.transaction { transaction =>
                let existing = transaction.query(
                    "SELECT workspace_id FROM threads WHERE id=?",
                    [SqlParameter.Text(targetThreadId.value)]
                )
                if (!existing.isEmpty()) {
                    let facts = transaction.query(
                        "SELECT payload FROM audit_events WHERE thread_id=? AND kind='thread.forked'",
                        [SqlParameter.Text(targetThreadId.value)]
                    )
                    if (existing.size == 1 &&
                        existing[0].required(0) == targetWorkspaceId.trimAscii() &&
                        facts.size == 1 && facts[0].required(0) == forkFact) {
                        return Result.Ok(loadBranchLocked(
                            transaction, targetThreadId, LaneId("main"), 0
                        ))
                    }
                    return laneConflict<Array<ItemId>>(
                        "target Thread already owns a different fork"
                    )
                }

                let sourceBranch = loadBranchLocked(
                    transaction, sourceThreadId, sourceLaneId, 0
                )
                let selected = ArrayList<ItemId>()
                var found = false
                for (item in sourceBranch) {
                    selected.add(item)
                    if (item.value == forkItemId.value) {
                        found = true
                        break
                    }
                }
                if (!found || selected.isEmpty()) {
                    return laneConflict<Array<ItemId>>(
                        "fork Item is outside the selected Lane branch"
                    )
                }

                let sourceTurns = ArrayList<String>()
                let targetTurns = ArrayList<String>()
                let sourceUserItems = ArrayList<String>()
                let targetUserItems = ArrayList<String>()
                for (item in selected) {
                    let rows = transaction.query(
                        "SELECT items.turn_id,turns.state,turns.user_item_id FROM items " +
                            "JOIN turns ON turns.id=items.turn_id WHERE items.id=? " +
                            "AND items.thread_id=?",
                        [SqlParameter.Text(item.value), SqlParameter.Text(sourceThreadId.value)]
                    )
                    if (rows.size != 1 || rows[0].required(1) == "active") {
                        return laneConflict<Array<ItemId>>(
                            "Thread fork requires a stable, terminal source Turn"
                        )
                    }
                    let sourceTurn = rows[0].required(0)
                    if (!sourceTurns.contains(sourceTurn)) {
                        sourceTurns.add(sourceTurn)
                        targetTurns.add(
                            "fork-turn-" + targetThreadId.value + "-" +
                                sourceTurns.size.toString()
                        )
                        sourceUserItems.add(rows[0].required(2))
                    }
                }
                for (sourceUser in sourceUserItems) {
                    var targetUser = ""
                    for (index in 0..selected.size where
                        selected[index].value == sourceUser) {
                        targetUser = forkedItemId(targetThreadId, index)
                    }
                    if (targetUser == "") {
                        return laneConflict<Array<ItemId>>(
                            "fork prefix does not contain its Turn user Item"
                        )
                    }
                    targetUserItems.add(targetUser)
                }

                transaction.execute(
                    "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal," +
                        "active_turn_id) VALUES (?,?,?,'open',?,NULL)",
                    [
                        SqlParameter.Text(targetThreadId.value),
                        SqlParameter.Int64Value(selected.size),
                        SqlParameter.Text(targetWorkspaceId.trimAscii()),
                        SqlParameter.Int64Value(selected.size + 1)
                    ]
                )
                for (index in 0..sourceTurns.size) {
                    let source = transaction.query(
                        "SELECT state FROM turns WHERE id=? AND thread_id=?",
                        [SqlParameter.Text(sourceTurns[index]),
                            SqlParameter.Text(sourceThreadId.value)]
                    )
                    transaction.execute(
                        "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                            "VALUES (?,?,?,?,?,NULL)",
                        [
                            SqlParameter.Text(targetTurns[index]),
                            SqlParameter.Text(targetThreadId.value),
                            SqlParameter.Int64Value(index + 1),
                            SqlParameter.Text(source[0].required(0)),
                            SqlParameter.Text(targetUserItems[index])
                        ]
                    )
                }

                let copied = ArrayList<ItemId>()
                for (index in 0..selected.size) {
                    let source = transaction.query(
                        "SELECT turn_id,kind,payload,provenance,created_at_millis FROM items " +
                            "WHERE id=? AND thread_id=?",
                        [SqlParameter.Text(selected[index].value),
                            SqlParameter.Text(sourceThreadId.value)]
                    )
                    var targetTurn = ""
                    for (turnIndex in 0..sourceTurns.size where
                        sourceTurns[turnIndex] == source[0].required(0)) {
                        targetTurn = targetTurns[turnIndex]
                    }
                    let targetItem = ItemId(forkedItemId(targetThreadId, index))
                    copied.add(targetItem)
                    transaction.execute(
                        "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance," +
                            "created_at_millis) VALUES (?,?,?,?,?,?,?,?)",
                        [
                            SqlParameter.Text(targetItem.value),
                            SqlParameter.Text(targetThreadId.value),
                            SqlParameter.Text(targetTurn),
                            SqlParameter.Int64Value(index + 1),
                            SqlParameter.Text(source[0].required(1)),
                            SqlParameter.Text(source[0].required(2)),
                            SqlParameter.Text(source[0].required(3)),
                            SqlParameter.Int64Value(laneDepth(source[0].required(4)))
                        ]
                    )
                }
                transaction.execute(
                    "INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload," +
                        "created_at_millis,commit_sequence) VALUES (?,NULL,NULL,'thread.forked',?,?,0)",
                    [SqlParameter.Text(targetThreadId.value),
                        SqlParameter.Text(forkFact),
                        SqlParameter.Int64Value(createdAtMillis)]
                )
                Result.Ok(copied.toArray())
            }
        } catch (error: Exception) {
            laneRecovery<Array<ItemId>>("lane.fork_thread_failed", error.message)
        }
    }
}

func recordLaneAdmissionAudit(
    transaction: SqliteTransaction,
    threadId: ThreadId,
    runId: RunId,
    laneId: LaneId,
    ownerId: String,
    fenceToken: Int64,
    kind: String,
    observedAtMillis: Int64
): Unit {
    transaction.execute(
        "INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload," +
            "created_at_millis) VALUES (?,?,NULL,?,?,?)",
        [
            SqlParameter.Text(threadId.value), SqlParameter.Text(runId.value),
            SqlParameter.Text(kind), SqlParameter.Text(encodeStoredValue(objectValue([
                ValueField("lane_id", textValue(laneId.value)),
                ValueField("owner_id", textValue(ownerId)),
                ValueField("fence_token", integerValue(fenceToken))
            ]))),
            SqlParameter.Int64Value(observedAtMillis)
        ]
    )
}

func forkedItemId(threadId: ThreadId, zeroBasedOrdinal: Int64): String {
    "fork-item-" + threadId.value + "-" + (zeroBasedOrdinal + 1).toString()
}

func loadBranchLocked(
    transaction: SqliteTransaction,
    threadId: ThreadId,
    laneId: LaneId,
    depth: Int64
): Array<ItemId> {
    if (depth > 64) { throw IllegalStateException("Lane ancestry cycle or excessive depth") }
    let lane = transaction.query(
        "SELECT kind,COALESCE(parent_lane_id,''),COALESCE(fork_item_id,'') FROM lanes " +
            "WHERE thread_id=? AND lane_id=?",
        [SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value)]
    )
    if (lane.size != 1) { throw IllegalStateException("Lane does not exist") }
    let output = ArrayList<ItemId>()
    if (lane[0].required(0) == "shared_history_child") {
        let parent = loadBranchLocked(
            transaction, threadId, LaneId(lane[0].required(1)), depth + 1
        )
        var found = false
        for (item in parent) {
            output.add(item)
            if (item.value == lane[0].required(2)) { found = true; break }
        }
        if (!found) { throw IllegalStateException("Lane fork Item is outside parent ancestry") }
    }
    let own = transaction.query(
        "SELECT edge.item_id FROM item_tree_edges edge JOIN items ON items.id=edge.item_id " +
            "WHERE edge.thread_id=? AND edge.lane_id=? ORDER BY items.ordinal",
        [SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value)]
    )
    for (row in own) { output.add(ItemId(row.required(0))) }
    output.toArray()
}

func branchContainsLocked(
    transaction: SqliteTransaction,
    threadId: ThreadId,
    laneId: LaneId,
    itemId: ItemId
): Bool {
    for (item in loadBranchLocked(transaction, threadId, laneId, 0) where
        item.value == itemId.value) { return true }
    false
}

func laneDepth(value: String): Int64 {
    try { Int64.parse(value) } catch (_: Exception) {
        throw IllegalStateException("Item tree depth is invalid")
    }
}

func laneConflict<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, "lane.conflict", message))
}

func laneRecovery<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message))
}
