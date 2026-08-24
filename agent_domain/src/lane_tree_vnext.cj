package agent_domain

import std.deriving.*

@Derive[Equatable]
public enum LaneKind {
    Main | SharedHistoryChild | ForkedThread
}

@Derive[Equatable]
public enum LaneStatus {
    Open | Closed
}

public class LaneRecord {
    public let id: LaneId
    public let threadId: ThreadId
    public let kind: LaneKind
    public let parentLaneId: ?LaneId
    public let forkItemId: ?ItemId
    public let config: AgentValue
    public let status: LaneStatus
    public let createdAtMillis: Int64

    public init(
        id: LaneId,
        threadId: ThreadId,
        kind: LaneKind,
        config: AgentValue,
        parentLaneId!: ?LaneId = None,
        forkItemId!: ?ItemId = None,
        status!: LaneStatus = LaneStatus.Open,
        createdAtMillis!: Int64 = 0
    ) {
        let child = kind == LaneKind.SharedHistoryChild
        if (config.kind != ValueKind.Object || createdAtMillis < 0 ||
            (child && (parentLaneId.isNone() || forkItemId.isNone())) ||
            (!child && (parentLaneId.isSome() || forkItemId.isSome()))) {
            throw IllegalArgumentException("Lane record ancestry is invalid")
        }
        this.id = id
        this.threadId = threadId
        this.kind = kind
        this.parentLaneId = parentLaneId
        this.forkItemId = forkItemId
        this.config = config
        this.status = status
        this.createdAtMillis = createdAtMillis
    }
}

public class ItemTreeEdge {
    public let itemId: ItemId
    public let threadId: ThreadId
    public let laneId: LaneId
    public let parentItemId: ?ItemId
    public let depth: Int64

    public init(
        itemId: ItemId,
        threadId: ThreadId,
        laneId: LaneId,
        parentItemId: ?ItemId,
        depth: Int64
    ) {
        if (depth < 0 || (depth == 0 && parentItemId.isSome()) ||
            (depth > 0 && parentItemId.isNone())) {
            throw IllegalArgumentException("Item tree edge is invalid")
        }
        this.itemId = itemId
        this.threadId = threadId
        this.laneId = laneId
        this.parentItemId = parentItemId
        this.depth = depth
    }
}

public func laneKindName(value: LaneKind): String {
    match (value) {
        case LaneKind.Main => "main"
        case LaneKind.SharedHistoryChild => "shared_history_child"
        case LaneKind.ForkedThread => "forked_thread"
    }
}
