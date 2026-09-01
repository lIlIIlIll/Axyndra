package agent_domain

import yjson.*

import yjson_support.*

import std.deriving.*

public class TeamId {
    public let value: String
    public init(value: String) { this.value = teamIdentifier("team", value) }
}

public class TeamMemberId {
    public let value: String
    public init(value: String) { this.value = teamIdentifier("team member", value) }
}

public class TeamTaskId {
    public let value: String
    public init(value: String) { this.value = teamIdentifier("team task", value) }
}

public class TeamMessageId {
    public let value: String
    public init(value: String) { this.value = teamIdentifier("team message", value) }
}

@Derive[Equatable]
public enum TeamStatus { Active | Closed }

@Derive[Equatable]
public enum TeamMemberStatus { Active | Inactive }

@Derive[Equatable]
public enum TeamTaskStatus { Open | Claimed | Completed | Failed | Blocked }

public class TeamRecord {
    public let id: TeamId
    public let threadId: ThreadId
    public let coordinatorLaneId: LaneId
    public let title: String
    public let status: TeamStatus
    public let createdAtMillis: Int64
    public let revision: Int64

    public init(id: TeamId, threadId: ThreadId, coordinatorLaneId: LaneId, title: String, status!: TeamStatus = TeamStatus.Active, createdAtMillis!: Int64 = 0, revision!: Int64 = 0) {
        if (title.trimAscii().isEmpty() || createdAtMillis < 0 || revision < 0) {
            throw IllegalArgumentException("team title and counters are invalid")
        }
        this.id = id; this.threadId = threadId; this.coordinatorLaneId = coordinatorLaneId
        this.title = title.trimAscii(); this.status = status
        this.createdAtMillis = createdAtMillis; this.revision = revision
    }
}

public class TeamMemberRecord {
    public let id: TeamMemberId
    public let teamId: TeamId
    public let threadId: ThreadId
    public let laneId: LaneId
    public let role: String
    public let status: TeamMemberStatus
    public let joinedAtMillis: Int64

    public init(id: TeamMemberId, teamId: TeamId, threadId: ThreadId, laneId: LaneId, role: String, status!: TeamMemberStatus = TeamMemberStatus.Active, joinedAtMillis!: Int64 = 0) {
        if (role.trimAscii().isEmpty() || joinedAtMillis < 0) { throw IllegalArgumentException("team member role is invalid") }
        this.id = id; this.teamId = teamId; this.threadId = threadId; this.laneId = laneId
        this.role = role.trimAscii(); this.status = status; this.joinedAtMillis = joinedAtMillis
    }
}

public class TeamTaskRecord {
    public let id: TeamTaskId
    public let teamId: TeamId
    public let title: String
    public let payload: AgentValue
    public let status: TeamTaskStatus
    public let assignee: ?TeamMemberId
    public let itemReference: ?ItemId
    public let workDebtId: String
    public let revision: Int64
    public let createdAtMillis: Int64
    public let updatedAtMillis: Int64

    public init(id: TeamTaskId, teamId: TeamId, title: String, payload: AgentValue, status!: TeamTaskStatus = TeamTaskStatus.Open, assignee!: ?TeamMemberId = None, itemReference!: ?ItemId = None, workDebtId!: String = "", revision!: Int64 = 0, createdAtMillis!: Int64 = 0, updatedAtMillis!: Int64 = 0) {
        if (title.trimAscii().isEmpty() || revision < 0 || createdAtMillis < 0 || updatedAtMillis < 0) {
            throw IllegalArgumentException("team task fields are invalid")
        }
        this.id = id; this.teamId = teamId; this.title = title.trimAscii(); this.payload = payload
        this.status = status; this.assignee = assignee; this.itemReference = itemReference
        this.workDebtId = workDebtId.trimAscii(); this.revision = revision
        this.createdAtMillis = createdAtMillis; this.updatedAtMillis = updatedAtMillis
    }
}

public class TeamMessageRecord {
    public let id: TeamMessageId
    public let teamId: TeamId
    public let sender: TeamMemberId
    public let recipient: TeamMemberId
    public let payload: AgentValue
    public let itemReference: ?ItemId
    public let createdAtMillis: Int64
    public let acknowledged: Bool
    public let revision: Int64

    public init(id: TeamMessageId, teamId: TeamId, sender: TeamMemberId, recipient: TeamMemberId, payload: AgentValue, itemReference!: ?ItemId = None, createdAtMillis!: Int64 = 0, acknowledged!: Bool = false, revision!: Int64 = 0) {
        if (createdAtMillis < 0 || revision < 0) { throw IllegalArgumentException("team message counters are invalid") }
        this.id = id; this.teamId = teamId; this.sender = sender; this.recipient = recipient
        this.payload = payload; this.itemReference = itemReference; this.createdAtMillis = createdAtMillis
        this.acknowledged = acknowledged; this.revision = revision
    }
}

func teamIdentifier(kind: String, value: String): String {
    let normalized = value.trimAscii()
    if (normalized.isEmpty()) { throw IllegalArgumentException("${kind} id must not be empty") }
    normalized
}
