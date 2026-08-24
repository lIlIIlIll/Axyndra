package agent_store

import std.collection.*
import std.convert.*
import agent_domain.*

public class SqliteTeamStore {
    private let database: SqliteDatabase
    public init(database: SqliteDatabase) { this.database = database }

    public func createTeam(value: TeamRecord): Result<Unit> {
        try {
            database.transaction { transaction =>
                let lane = transaction.query(
                    "SELECT 1 FROM lanes WHERE thread_id=? AND lane_id=? AND status='open'",
                    [SqlParameter.Text(value.threadId.value), SqlParameter.Text(value.coordinatorLaneId.value)]
                )
                if (lane.size != 1) { return teamConflict<Unit>("coordinator Lane is not open") }
                let existing = transaction.query(
                    "SELECT thread_id,coordinator_lane_id,title,status,revision FROM teams WHERE id=?",
                    [SqlParameter.Text(value.id.value)]
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO teams(id,thread_id,coordinator_lane_id,title,status,created_at_millis,revision) VALUES (?,?,?,?,?,?,?)",
                        [SqlParameter.Text(value.id.value), SqlParameter.Text(value.threadId.value),
                            SqlParameter.Text(value.coordinatorLaneId.value), SqlParameter.Text(value.title),
                            SqlParameter.Text(teamStatusName(value.status)), SqlParameter.Int64Value(value.createdAtMillis),
                            SqlParameter.Int64Value(value.revision)]
                    )
                    Result.Ok(())
                } else if (existing.size == 1 && existing[0].required(0) == value.threadId.value &&
                    existing[0].required(1) == value.coordinatorLaneId.value &&
                    existing[0].required(2) == value.title && existing[0].required(3) == teamStatusName(value.status) &&
                    teamInt(existing[0].required(4)) == value.revision) { Result.Ok(()) }
                else { teamConflict<Unit>("Team id already owns different content") }
            }
        } catch (error: Exception) { teamRecovery<Unit>("team.create_failed", error.message) }
    }

    public func addMember(value: TeamMemberRecord): Result<Unit> {
        try {
            database.transaction { transaction =>
                let owner = transaction.query("SELECT thread_id,status FROM teams WHERE id=?", [SqlParameter.Text(value.teamId.value)])
                if (owner.size != 1 || owner[0].required(0) != value.threadId.value || owner[0].required(1) != "active") {
                    return teamConflict<Unit>("member must join an active Team in the same Thread")
                }
                let existing = transaction.query(
                    "SELECT thread_id,lane_id,role,status FROM team_members WHERE team_id=? AND member_id=?",
                    [SqlParameter.Text(value.teamId.value), SqlParameter.Text(value.id.value)]
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO team_members(team_id,member_id,thread_id,lane_id,role,status,joined_at_millis) VALUES (?,?,?,?,?,?,?)",
                        [SqlParameter.Text(value.teamId.value), SqlParameter.Text(value.id.value),
                            SqlParameter.Text(value.threadId.value), SqlParameter.Text(value.laneId.value),
                            SqlParameter.Text(value.role), SqlParameter.Text(teamMemberStatusName(value.status)),
                            SqlParameter.Int64Value(value.joinedAtMillis)]
                    )
                    Result.Ok(())
                } else if (existing.size == 1 && existing[0].required(0) == value.threadId.value &&
                    existing[0].required(1) == value.laneId.value && existing[0].required(2) == value.role &&
                    existing[0].required(3) == teamMemberStatusName(value.status)) { Result.Ok(()) }
                else { teamConflict<Unit>("Team member id already owns different content") }
            }
        } catch (error: Exception) { teamRecovery<Unit>("team.member_add_failed", error.message) }
    }

    public func addTask(value: TeamTaskRecord): Result<Unit> {
        try {
            database.transaction { transaction =>
                match (value.itemReference) {
                    case Some(item) => if (transaction.query(
                        "SELECT 1 FROM teams JOIN items ON items.thread_id=teams.thread_id WHERE teams.id=? AND items.id=?",
                        [SqlParameter.Text(value.teamId.value), SqlParameter.Text(item.value)]
                    ).size != 1) { return teamConflict<Unit>("Task Item reference is outside the Team Thread") }
                    case None => ()
                }
                let existing = transaction.query("SELECT title,payload,status FROM team_tasks WHERE id=?", [SqlParameter.Text(value.id.value)])
                let payload = encodeStoredValue(value.payload)
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO team_tasks(id,team_id,title,payload,status,assignee_member_id,item_reference,work_debt_id,revision,created_at_millis,updated_at_millis) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                        [SqlParameter.Text(value.id.value), SqlParameter.Text(value.teamId.value), SqlParameter.Text(value.title),
                            SqlParameter.Text(payload), SqlParameter.Text(teamTaskStatusName(value.status)), teamMemberParameter(value.assignee),
                            itemParameter(value.itemReference), SqlParameter.Text(value.workDebtId), SqlParameter.Int64Value(value.revision),
                            SqlParameter.Int64Value(value.createdAtMillis), SqlParameter.Int64Value(value.updatedAtMillis)]
                    )
                    Result.Ok(())
                } else if (existing.size == 1 && existing[0].required(0) == value.title &&
                    existing[0].required(1) == payload && existing[0].required(2) == teamTaskStatusName(value.status)) {
                    Result.Ok(())
                } else { teamConflict<Unit>("Team task id already owns different content") }
            }
        } catch (error: Exception) { teamRecovery<Unit>("team.task_add_failed", error.message) }
    }

    public func claimTask(taskId: TeamTaskId, memberId: TeamMemberId, expectedRevision: Int64, updatedAtMillis: Int64): Result<TeamTaskRecord> {
        try {
            database.transaction { transaction =>
                let task = transaction.query("SELECT team_id,status,COALESCE(assignee_member_id,''),revision FROM team_tasks WHERE id=?", [SqlParameter.Text(taskId.value)])
                if (task.size != 1) { return teamConflict<TeamTaskRecord>("Team task does not exist") }
                if (task[0].required(1) == "claimed" && task[0].required(2) == memberId.value) {
                    return Result.Ok(loadTaskLocked(transaction, taskId))
                }
                if (task[0].required(1) != "open" || teamInt(task[0].required(3)) != expectedRevision) {
                    return teamConflict<TeamTaskRecord>("Team task claim lost its revision race")
                }
                let member = transaction.query(
                    "SELECT 1 FROM team_members WHERE team_id=? AND member_id=? AND status='active'",
                    [SqlParameter.Text(task[0].required(0)), SqlParameter.Text(memberId.value)]
                )
                if (member.size != 1) { return teamConflict<TeamTaskRecord>("assignee is not an active Team member") }
                transaction.execute(
                    "UPDATE team_tasks SET status='claimed',assignee_member_id=?,revision=revision+1,updated_at_millis=? WHERE id=? AND status='open' AND revision=?",
                    [SqlParameter.Text(memberId.value), SqlParameter.Int64Value(updatedAtMillis), SqlParameter.Text(taskId.value), SqlParameter.Int64Value(expectedRevision)]
                )
                Result.Ok(loadTaskLocked(transaction, taskId))
            }
        } catch (error: Exception) { teamRecovery<TeamTaskRecord>("team.task_claim_failed", error.message) }
    }

    public func settleTask(taskId: TeamTaskId, expectedRevision: Int64, status: TeamTaskStatus, workDebtId: String, updatedAtMillis: Int64): Result<TeamTaskRecord> {
        if (status != TeamTaskStatus.Completed && status != TeamTaskStatus.Failed && status != TeamTaskStatus.Blocked) {
            return teamConflict<TeamTaskRecord>("Team task settlement requires a terminal or classified status")
        }
        if (status == TeamTaskStatus.Blocked && workDebtId.trimAscii().isEmpty()) {
            return teamConflict<TeamTaskRecord>("blocked Team task requires classified WorkDebt")
        }
        try {
            database.transaction { transaction =>
                let task = transaction.query("SELECT status,revision FROM team_tasks WHERE id=?", [SqlParameter.Text(taskId.value)])
                if (task.size != 1 || task[0].required(0) != "claimed" || teamInt(task[0].required(1)) != expectedRevision) {
                    return teamConflict<TeamTaskRecord>("Team task settlement lost its revision race")
                }
                transaction.execute(
                    "UPDATE team_tasks SET status=?,work_debt_id=?,revision=revision+1,updated_at_millis=? WHERE id=? AND status='claimed' AND revision=?",
                    [SqlParameter.Text(teamTaskStatusName(status)), SqlParameter.Text(workDebtId.trimAscii()),
                        SqlParameter.Int64Value(updatedAtMillis), SqlParameter.Text(taskId.value), SqlParameter.Int64Value(expectedRevision)]
                )
                Result.Ok(loadTaskLocked(transaction, taskId))
            }
        } catch (error: Exception) { teamRecovery<TeamTaskRecord>("team.task_settle_failed", error.message) }
    }

    public func send(value: TeamMessageRecord): Result<Unit> {
        try {
            database.transaction { transaction =>
                let members = transaction.query(
                    "SELECT member_id FROM team_members WHERE team_id=? AND member_id IN (?,?) AND status='active'",
                    [SqlParameter.Text(value.teamId.value), SqlParameter.Text(value.sender.value), SqlParameter.Text(value.recipient.value)]
                )
                let required = if (value.sender.value == value.recipient.value) { 1 } else { 2 }
                if (members.size != required) { return teamConflict<Unit>("message endpoints must be active Team members") }
                match (value.itemReference) {
                    case Some(item) => if (transaction.query(
                        "SELECT 1 FROM teams JOIN items ON items.thread_id=teams.thread_id WHERE teams.id=? AND items.id=?",
                        [SqlParameter.Text(value.teamId.value), SqlParameter.Text(item.value)]
                    ).size != 1) { return teamConflict<Unit>("Message Item reference is outside the Team Thread") }
                    case None => ()
                }
                let payload = encodeStoredValue(value.payload)
                let existing = transaction.query("SELECT sender_member_id,recipient_member_id,payload FROM team_messages WHERE id=?", [SqlParameter.Text(value.id.value)])
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO team_messages(id,team_id,sender_member_id,recipient_member_id,item_reference,payload,created_at_millis,acknowledged,revision) VALUES (?,?,?,?,?,?,?,?,?)",
                        [SqlParameter.Text(value.id.value), SqlParameter.Text(value.teamId.value),
                            SqlParameter.Text(value.sender.value), SqlParameter.Text(value.recipient.value),
                            itemParameter(value.itemReference), SqlParameter.Text(payload),
                            SqlParameter.Int64Value(value.createdAtMillis), SqlParameter.Int64Value(if (value.acknowledged) { 1 } else { 0 }),
                            SqlParameter.Int64Value(value.revision)]
                    )
                    Result.Ok(())
                } else if (existing.size == 1 && existing[0].required(0) == value.sender.value &&
                    existing[0].required(1) == value.recipient.value && existing[0].required(2) == payload) { Result.Ok(()) }
                else { teamConflict<Unit>("Team message id already owns different content") }
            }
        } catch (error: Exception) { teamRecovery<Unit>("team.message_send_failed", error.message) }
    }

    public func mailbox(teamId: TeamId, recipient: TeamMemberId): Result<Array<TeamMessageRecord>> {
        try {
            let rows = database.query(
                "SELECT id,sender_member_id,recipient_member_id,payload,COALESCE(item_reference,''),created_at_millis,acknowledged,revision FROM team_messages WHERE team_id=? AND recipient_member_id=? ORDER BY created_at_millis,id",
                [SqlParameter.Text(teamId.value), SqlParameter.Text(recipient.value)]
            )
            let output = ArrayList<TeamMessageRecord>()
            for (row in rows) {
                output.add(TeamMessageRecord(
                    TeamMessageId(row.required(0)), teamId, TeamMemberId(row.required(1)), TeamMemberId(row.required(2)),
                    decodeStoredValue(row.required(3)), itemReference: optionalItem(row.required(4)),
                    createdAtMillis: teamInt(row.required(5)), acknowledged: teamInt(row.required(6)) == 1,
                    revision: teamInt(row.required(7))
                ))
            }
            Result.Ok(output.toArray())
        } catch (error: Exception) { teamRecovery<Array<TeamMessageRecord>>("team.mailbox_read_failed", error.message) }
    }

    public func acknowledge(messageId: TeamMessageId, recipient: TeamMemberId, expectedRevision: Int64): Result<Unit> {
        try {
            database.transaction { transaction =>
                let row = transaction.query("SELECT recipient_member_id,acknowledged,revision FROM team_messages WHERE id=?", [SqlParameter.Text(messageId.value)])
                if (row.size != 1 || row[0].required(0) != recipient.value) { return teamConflict<Unit>("message is not addressed to this member") }
                if (teamInt(row[0].required(1)) == 1) { return Result.Ok(()) }
                if (teamInt(row[0].required(2)) != expectedRevision) { return teamConflict<Unit>("message acknowledgement lost its revision race") }
                transaction.execute("UPDATE team_messages SET acknowledged=1,revision=revision+1 WHERE id=? AND acknowledged=0 AND revision=?", [SqlParameter.Text(messageId.value), SqlParameter.Int64Value(expectedRevision)])
                Result.Ok(())
            }
        } catch (error: Exception) { teamRecovery<Unit>("team.message_ack_failed", error.message) }
    }

    public func roster(teamId: TeamId): Result<Array<TeamMemberRecord>> {
        try {
            let rows = database.query("SELECT member_id,thread_id,lane_id,role,status,joined_at_millis FROM team_members WHERE team_id=? ORDER BY joined_at_millis,member_id", [SqlParameter.Text(teamId.value)])
            let output = ArrayList<TeamMemberRecord>()
            for (row in rows) { output.add(TeamMemberRecord(TeamMemberId(row.required(0)), teamId, ThreadId(row.required(1)), LaneId(row.required(2)), row.required(3), status: parseMemberStatus(row.required(4)), joinedAtMillis: teamInt(row.required(5)))) }
            Result.Ok(output.toArray())
        } catch (error: Exception) { teamRecovery<Array<TeamMemberRecord>>("team.roster_read_failed", error.message) }
    }

    public func taskBoard(teamId: TeamId): Result<Array<TeamTaskRecord>> {
        try {
            database.readTransaction { transaction =>
                let rows = transaction.query("SELECT id FROM team_tasks WHERE team_id=? ORDER BY created_at_millis,id", [SqlParameter.Text(teamId.value)])
                let output = ArrayList<TeamTaskRecord>()
                for (row in rows) { output.add(loadTaskLocked(transaction, TeamTaskId(row.required(0)))) }
                Result.Ok(output.toArray())
            }
        } catch (error: Exception) { teamRecovery<Array<TeamTaskRecord>>("team.board_read_failed", error.message) }
    }
}

func loadTaskLocked(transaction: SqliteTransaction, id: TeamTaskId): TeamTaskRecord {
    let rows = transaction.query("SELECT team_id,title,payload,status,COALESCE(assignee_member_id,''),COALESCE(item_reference,''),work_debt_id,revision,created_at_millis,updated_at_millis FROM team_tasks WHERE id=?", [SqlParameter.Text(id.value)])
    if (rows.size != 1) { throw IllegalStateException("Team task is missing") }
    let row = rows[0]
    TeamTaskRecord(id, TeamId(row.required(0)), row.required(1), decodeStoredValue(row.required(2)),
        status: parseTaskStatus(row.required(3)), assignee: optionalMember(row.required(4)),
        itemReference: optionalItem(row.required(5)), workDebtId: row.required(6), revision: teamInt(row.required(7)),
        createdAtMillis: teamInt(row.required(8)), updatedAtMillis: teamInt(row.required(9)))
}

func teamStatusName(value: TeamStatus): String { match (value) { case TeamStatus.Active => "active"; case TeamStatus.Closed => "closed" } }
func teamMemberStatusName(value: TeamMemberStatus): String { match (value) { case TeamMemberStatus.Active => "active"; case TeamMemberStatus.Inactive => "inactive" } }
func teamTaskStatusName(value: TeamTaskStatus): String { match (value) { case TeamTaskStatus.Open => "open"; case TeamTaskStatus.Claimed => "claimed"; case TeamTaskStatus.Completed => "completed"; case TeamTaskStatus.Failed => "failed"; case TeamTaskStatus.Blocked => "blocked" } }
func parseMemberStatus(value: String): TeamMemberStatus { if (value == "active") { TeamMemberStatus.Active } else if (value == "inactive") { TeamMemberStatus.Inactive } else { throw IllegalStateException("invalid Team member status") } }
func parseTaskStatus(value: String): TeamTaskStatus { match (value) { case "open" => TeamTaskStatus.Open; case "claimed" => TeamTaskStatus.Claimed; case "completed" => TeamTaskStatus.Completed; case "failed" => TeamTaskStatus.Failed; case "blocked" => TeamTaskStatus.Blocked; case _ => throw IllegalStateException("invalid Team task status") } }
func teamMemberParameter(value: ?TeamMemberId): SqlParameter { match (value) { case Some(item) => SqlParameter.Text(item.value); case None => SqlParameter.Null } }
func itemParameter(value: ?ItemId): SqlParameter { match (value) { case Some(item) => SqlParameter.Text(item.value); case None => SqlParameter.Null } }
func optionalMember(value: String): ?TeamMemberId { if (value.isEmpty()) { None } else { Some(TeamMemberId(value)) } }
func optionalItem(value: String): ?ItemId { if (value.isEmpty()) { None } else { Some(ItemId(value)) } }
func teamInt(value: String): Int64 { try { Int64.parse(value) } catch (_: Exception) { throw IllegalStateException("invalid Team integer") } }
func teamConflict<T>(message: String): Result<T> { Result.Err(AgentError(AgentErrorKind.Conflict, "team.conflict", message)) }
func teamRecovery<T>(code: String, message: String): Result<T> { Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message)) }
