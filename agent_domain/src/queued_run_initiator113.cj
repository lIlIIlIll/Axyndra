package agent_domain

// Immutable DATA from the actual paid RPC queue object. This supplies no
// Source, execution grant or receipt. The original TurnStarted transaction
// repeats the full existing Inbox/Thread/Lane/content checks before claim.
public class QueuedRunInitiatorData113 {
    public let entryId: InboxEntryId
    public let threadId: ThreadId
    public let laneId: LaneId
    public let correlationId: String
    public let kind: String
    public let input: String
    public init(entryId: InboxEntryId, threadId: ThreadId, laneId: LaneId,
        correlationId: String, kind: String, input: String) {
        if (input == "" || correlationId == "" || kind == "steer" || kind == "cancel" ||
            scopedInboxEntryId(threadId, laneId, correlationId).value != entryId.value) {
            throw IllegalArgumentException("queued Run initiator differs from its original enclosure") }
        this.entryId=entryId; this.threadId=threadId; this.laneId=laneId
        this.correlationId=correlationId; this.kind=kind; this.input=input
    }
}
