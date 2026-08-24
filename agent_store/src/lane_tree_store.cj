package agent_store

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
