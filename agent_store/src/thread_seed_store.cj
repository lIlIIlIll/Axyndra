package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*

// Offline creation boundary for import/fork/branch. It deliberately cannot
// replace an existing Thread: live mutation must pass through its coordinator.
public class SqliteThreadSeedStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func createCompleted(snapshot: AgentThreadSnapshot): Result<Unit> {
        try {
            let _ = ThreadCoordinator(snapshot, InMemoryThreadCommitSink())
            if (snapshot.thread.activeTurnId.isSome() || snapshot.activeRunId.isSome() ||
                snapshot.thread.status != ThreadStatus.Open) {
                throw IllegalArgumentException("seed Thread must be open with no active owner")
            }
            for (turn in snapshot.turns where turn.state != TurnState.Completed ||
                turn.activeRunId.isSome()) {
                throw IllegalArgumentException("seed Thread may contain only completed Turns")
            }
            validateCompletedSeedProtocol(snapshot)
            database.transaction { transaction =>
                if (!transaction.query(
                    "SELECT id FROM threads WHERE id=" + sqliteText(snapshot.thread.id.value)
                ).isEmpty()) {
                    throw IllegalStateException("canonical Thread already exists")
                }
                transaction.execute(
                    "INSERT INTO threads (id,revision,workspace_id,status,next_item_ordinal,active_turn_id) VALUES (" +
                        sqliteText(snapshot.thread.id.value) + "," +
                        snapshot.thread.revision.toString() + "," +
                        sqliteText(snapshot.thread.workspaceId) + ",'open'," +
                        snapshot.thread.nextItemOrdinal.toString() + ",NULL)"
                )
                let empty = encodeStoredValue(objectValue([]))
                for (turn in snapshot.turns) {
                    let user = seedUserItem(snapshot.items, turn)
                    let runId = user.provenance.runId.getOrThrow()
                    transaction.execute(
                        "INSERT INTO turns (id,thread_id,ordinal,state,user_item_id,active_run_id) VALUES (" +
                            sqliteText(turn.id.value) + "," + sqliteText(turn.threadId.value) + "," +
                            turn.ordinal.toString() + ",'completed'," +
                            sqliteText(turn.userItemId.value) + ",NULL)"
                    )
                    transaction.execute(
                        "INSERT INTO runs (id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                            "started_at_millis,finished_at_millis,cancellation_reason) VALUES (" +
                            sqliteText(runId.value) + "," + sqliteText(turn.threadId.value) + "," +
                            sqliteText(turn.id.value) + "," + turn.ordinal.toString() +
                            ",'completed'," + sqliteText(empty) + "," + sqliteText(empty) + "," +
                            sqliteText(empty) + "," + sqliteText(empty) + "," +
                            user.createdAtMillis.toString() + "," +
                            seedTurnFinishedAt(snapshot.items, turn).toString() + ",NULL)"
                    )
                }
                for (item in snapshot.items) {
                    transaction.execute(
                        "INSERT INTO items (id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (" +
                            sqliteText(item.id.value) + "," + sqliteText(item.threadId.value) + "," +
                            sqliteText(item.turnId.value) + "," + item.ordinal.toString() + "," +
                            sqliteText(seedItemKind(item.kind)) + "," +
                            sqliteText(encodeStoredThreadContent(item.content)) + "," +
                            sqliteText(encodeStoredProvenance(item.provenance)) + "," +
                            item.createdAtMillis.toString() + ")"
                    )
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "thread.seed_failed",
                error.message,
                fields: [ErrorField("thread_id", snapshot.thread.id.value)]
            ))
        }
    }
}

// Converts a provider-neutral transcript into immutable completed semantic
// history. ModelMessage remains an adapter DTO; callers may only use this for
// offline creation of a new Thread, never to mutate a live Thread.
public func completedThreadSeedSnapshot(
    threadId: ThreadId,
    workspaceId: String,
    messages: Array<ModelMessage>,
    createdAtMillis!: Int64 = 0
): AgentThreadSnapshot {
    let turns = ArrayList<TurnRecord>()
    let items = ArrayList<ThreadItem>()
    let pending = HashSet<String>()
    var currentTurn: ?SemanticTurnId = None
    var currentRun: ?RunId = None
    var itemOrdinal: Int64 = 1
    var turnOrdinal: Int64 = 0

    for (message in messages) {
        if (message.role == ModelRole.User) {
            let toolResults = ArrayList<ModelBlock>()
            let ordinary = ArrayList<ModelBlock>()
            for (block in message.blocks) {
                if (block.kind == ModelBlockKind.ToolResult) {
                    toolResults.add(block)
                } else {
                    ordinary.add(block)
                }
            }
            if (!toolResults.isEmpty() && !ordinary.isEmpty()) {
                throw IllegalArgumentException(
                    "seed user message cannot mix ToolResult and ordinary content"
                )
            }
            if (!toolResults.isEmpty()) {
                let turnId = match (currentTurn) {
                    case Some(value) => value
                    case None => throw IllegalArgumentException(
                        "seed ToolResult has no preceding user Turn"
                    )
                }
                let runId = currentRun.getOrThrow()
                for (block in toolResults) {
                    if (block.callId.trimAscii() == "" || !pending.contains(block.callId)) {
                        throw IllegalArgumentException(
                            "seed ToolResult has no pending ToolCall in its Turn"
                        )
                    }
                    let operationId = OperationId(
                        "seed-operation-" + threadId.value + "-" + itemOrdinal.toString()
                    )
                    let receiptId = if (block.receiptId.trimAscii() == "") {
                        "seed-receipt-" + threadId.value + "-" + itemOrdinal.toString()
                    } else {
                        block.receiptId
                    }
                    items.add(ThreadItem(
                        ItemId("seed-item-" + threadId.value + "-" + itemOrdinal.toString()),
                        threadId,
                        turnId,
                        itemOrdinal,
                        ThreadItemContent.ToolResult(
                            CanonicalToolCallId(block.callId),
                            operationId,
                            receiptId,
                            block.arguments,
                            block.isError
                        ),
                        ItemProvenance(
                            "seed", runId: Some(runId), operationId: Some(operationId)
                        ),
                        createdAtMillis: createdAtMillis + itemOrdinal
                    ))
                    pending.remove(block.callId)
                    itemOrdinal += 1
                }
                continue
            }
            if (!pending.isEmpty()) {
                throw IllegalArgumentException(
                    "seed transcript starts a new Turn before ToolResult completion"
                )
            }
            let parts = seedMessageParts(ordinary.toArray(), true)
            turnOrdinal += 1
            let turnId = SemanticTurnId(
                "seed-turn-" + threadId.value + "-" + turnOrdinal.toString()
            )
            let runId = RunId(
                "seed-run-" + threadId.value + "-" + turnOrdinal.toString()
            )
            let userItemId = ItemId(
                "seed-item-" + threadId.value + "-" + itemOrdinal.toString()
            )
            turns.add(TurnRecord(
                turnId,
                threadId,
                turnOrdinal,
                TurnState.Completed,
                userItemId
            ))
            items.add(ThreadItem(
                userItemId,
                threadId,
                turnId,
                itemOrdinal,
                ThreadItemContent.UserMessage(parts),
                ItemProvenance("seed", runId: Some(runId)),
                createdAtMillis: createdAtMillis + itemOrdinal
            ))
            itemOrdinal += 1
            currentTurn = Some(turnId)
            currentRun = Some(runId)
            continue
        }

        let turnId = match (currentTurn) {
            case Some(value) => value
            case None => throw IllegalArgumentException(
                "seed assistant message has no preceding user Turn"
            )
        }
        let runId = currentRun.getOrThrow()
        for (block in message.blocks) {
            if (!pending.isEmpty() && block.kind != ModelBlockKind.ToolCall) {
                throw IllegalArgumentException(
                    "seed assistant content cannot cross an incomplete tool round"
                )
            }
            let content = seedAssistantContent(
                block, threadId, itemOrdinal, pending
            )
            match (content) {
                case Some(value) =>
                    items.add(ThreadItem(
                        ItemId("seed-item-" + threadId.value + "-" + itemOrdinal.toString()),
                        threadId,
                        turnId,
                        itemOrdinal,
                        value,
                        ItemProvenance("seed", runId: Some(runId)),
                        createdAtMillis: createdAtMillis + itemOrdinal
                    ))
                    itemOrdinal += 1
                case None => ()
            }
            if (block.kind != ModelBlockKind.Unknown && block.opaqueState.isSome()) {
                if (!pending.isEmpty()) {
                    throw IllegalArgumentException(
                        "provider opaque state cannot cross an incomplete tool round"
                    )
                }
                items.add(ThreadItem(
                    ItemId("seed-item-" + threadId.value + "-" + itemOrdinal.toString()),
                    threadId,
                    turnId,
                    itemOrdinal,
                    ThreadItemContent.ProviderOpaqueItem(block.opaqueState.getOrThrow()),
                    ItemProvenance("seed", runId: Some(runId)),
                    createdAtMillis: createdAtMillis + itemOrdinal
                ))
                itemOrdinal += 1
            }
        }
    }
    if (!pending.isEmpty()) {
        throw IllegalArgumentException("seed transcript ends with incomplete ToolCall")
    }
    let snapshot = AgentThreadSnapshot(
        ThreadRecord(
            threadId,
            1,
            workspaceId,
            ThreadStatus.Open,
            itemOrdinal
        ),
        turns.toArray(),
        items.toArray(),
        activeEpoch: turnOrdinal
    )
    validateCompletedSeedProtocol(snapshot)
    snapshot
}

// Exact semantic clone used by fork. Unlike a ModelMessage round trip, this
// preserves artifacts, system notes and provider opaque Items.
public func completedThreadCloneSnapshot(
    targetThreadId: ThreadId,
    workspaceId: String,
    source: AgentThreadSnapshot
): AgentThreadSnapshot {
    validateCompletedSeedProtocol(source)
    let turns = ArrayList<TurnRecord>()
    let items = ArrayList<ThreadItem>()
    let runByTurn = HashMap<String, RunId>()
    for (turn in source.turns) {
        let runId = RunId(
            "seed-run-" + targetThreadId.value + "-" + turn.ordinal.toString()
        )
        runByTurn.add(turn.id.value, runId)
        turns.add(TurnRecord(
            SemanticTurnId(
                "seed-turn-" + targetThreadId.value + "-" + turn.ordinal.toString()
            ),
            targetThreadId,
            turn.ordinal,
            TurnState.Completed,
            ItemId(
                "seed-item-" + targetThreadId.value + "-" +
                    seedSourceUserOrdinal(source.items, turn).toString()
            )
        ))
    }
    for (item in source.items) {
        let targetTurn = SemanticTurnId(
            "seed-turn-" + targetThreadId.value + "-" +
                seedSourceTurnOrdinal(source.turns, item.turnId).toString()
        )
        let runId = runByTurn[item.turnId.value]
        let content = match (item.content) {
            case ThreadItemContent.ToolResult(callId, _, receiptId, result, isError) =>
                let operationId = OperationId(
                    "seed-operation-" + targetThreadId.value + "-" +
                        item.ordinal.toString()
                )
                ThreadItemContent.ToolResult(
                    callId, operationId, receiptId, result, isError
                )
            case value => value
        }
        let operationId: ?OperationId = match (content) {
            case ThreadItemContent.ToolResult(_, value, _, _, _) => Some(value)
            case _ => None
        }
        items.add(ThreadItem(
            ItemId(
                "seed-item-" + targetThreadId.value + "-" + item.ordinal.toString()
            ),
            targetThreadId,
            targetTurn,
            item.ordinal,
            content,
            ItemProvenance(
                "fork", runId: Some(runId), operationId: operationId
            ),
            createdAtMillis: item.createdAtMillis
        ))
    }
    let snapshot = AgentThreadSnapshot(
        ThreadRecord(
            targetThreadId,
            1,
            workspaceId,
            ThreadStatus.Open,
            source.thread.nextItemOrdinal
        ),
        turns.toArray(),
        items.toArray(),
        activeEpoch: Int64(turns.size)
    )
    validateCompletedSeedProtocol(snapshot)
    snapshot
}

func seedSourceTurnOrdinal(
    turns: Array<TurnRecord>,
    turnId: SemanticTurnId
): Int64 {
    for (turn in turns where turn.id.value == turnId.value) {
        return turn.ordinal
    }
    throw IllegalArgumentException("seed source Item references a missing Turn")
}

func seedSourceUserOrdinal(items: Array<ThreadItem>, turn: TurnRecord): Int64 {
    for (item in items where item.id.value == turn.userItemId.value &&
        item.turnId.value == turn.id.value && item.kind == ItemKind.UserMessage) {
        return item.ordinal
    }
    throw IllegalArgumentException("seed source Turn is missing its user Item")
}

func seedMessageParts(blocks: Array<ModelBlock>, user: Bool): Array<ThreadMessagePart> {
    let parts = ArrayList<ThreadMessagePart>()
    for (block in blocks) {
        match (block.kind) {
            case ModelBlockKind.Text => if (block.text != "") {
                parts.add(ThreadMessagePart.Text(block.text))
            }
            case ModelBlockKind.Image =>
                let image = block.image.getOrThrow()
                parts.add(ThreadMessagePart.Image(ThreadImage(
                    match (image.sourceKind) {
                        case ModelImageSourceKind.Url => ThreadImageSourceKind.Url
                        case ModelImageSourceKind.Base64 => ThreadImageSourceKind.Base64
                    },
                    image.data,
                    mediaType: image.mediaType
                )))
            case ModelBlockKind.Refusal | ModelBlockKind.Error =>
                if (user || block.text == "") {
                    throw IllegalArgumentException("seed user message contains assistant-only content")
                }
                parts.add(ThreadMessagePart.Refusal(block.text))
            case _ => throw IllegalArgumentException(
                "seed message contains content invalid for its role"
            )
        }
    }
    if (parts.isEmpty()) {
        throw IllegalArgumentException("seed message has no semantic content")
    }
    parts.toArray()
}

func seedAssistantContent(
    block: ModelBlock,
    threadId: ThreadId,
    itemOrdinal: Int64,
    pending: HashSet<String>
): ?ThreadItemContent {
    match (block.kind) {
        case ModelBlockKind.Text | ModelBlockKind.Image |
            ModelBlockKind.Refusal | ModelBlockKind.Error =>
            Some(ThreadItemContent.AssistantMessage(seedMessageParts([block], false)))
        case ModelBlockKind.ToolCall =>
            if (block.callId.trimAscii() == "" || pending.contains(block.callId)) {
                throw IllegalArgumentException("seed ToolCall id is empty or duplicated")
            }
            let value = ThreadItemContent.ToolCall(
                CanonicalToolCallId(block.callId), block.name, block.arguments
            )
            pending.add(block.callId)
            Some(value)
        case ModelBlockKind.Reasoning =>
            if (block.text.trimAscii() == "") { None } else {
                Some(ThreadItemContent.ReasoningReference(
                    "seed-reasoning-" + threadId.value + "-" + itemOrdinal.toString(),
                    block.text
                ))
            }
        case ModelBlockKind.Unknown => match (block.opaqueState) {
            case Some(value) => Some(ThreadItemContent.ProviderOpaqueItem(value))
            case None => if (block.text.trimAscii() == "") { None } else {
                Some(ThreadItemContent.SystemNote(block.text))
            }
        }
        case ModelBlockKind.ToolResult => throw IllegalArgumentException(
            "seed assistant message cannot contain ToolResult"
        )
    }
}

func validateCompletedSeedProtocol(snapshot: AgentThreadSnapshot): Unit {
    let pending = HashSet<String>()
    var currentTurn = ""
    for (item in snapshot.items) {
        if (item.turnId.value != currentTurn) {
            if (!pending.isEmpty()) {
                throw IllegalArgumentException(
                    "seed Turn ends with incomplete ToolCall"
                )
            }
            currentTurn = item.turnId.value
        }
        match (item.content) {
            case ThreadItemContent.ToolCall(callId, _, _) =>
                if (pending.contains(callId.value)) {
                    throw IllegalArgumentException("seed ToolCall id is duplicated in its Turn")
                }
                pending.add(callId.value)
            case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                if (!pending.contains(callId.value)) {
                    throw IllegalArgumentException(
                        "seed ToolResult has no pending ToolCall in its Turn"
                    )
                }
                pending.remove(callId.value)
            case _ => if (!pending.isEmpty()) {
                throw IllegalArgumentException(
                    "seed semantic Item crosses an incomplete tool round"
                )
            }
        }
    }
    if (!pending.isEmpty()) {
        throw IllegalArgumentException("seed Thread ends with incomplete ToolCall")
    }
}

func seedUserItem(items: Array<ThreadItem>, turn: TurnRecord): ThreadItem {
    for (item in items where item.id.value == turn.userItemId.value &&
        item.turnId.value == turn.id.value && item.kind == ItemKind.UserMessage) {
        return item
    }
    throw IllegalArgumentException("completed seed Turn is missing its user Item")
}

func seedTurnFinishedAt(items: Array<ThreadItem>, turn: TurnRecord): Int64 {
    var value: Int64 = 0
    for (item in items where item.turnId.value == turn.id.value) {
        value = max(value, item.createdAtMillis)
    }
    value
}

func seedItemKind(kind: ItemKind): String {
    match (kind) {
        case ItemKind.UserMessage => "user_message"
        case ItemKind.AssistantMessage => "assistant_message"
        case ItemKind.ToolCall => "tool_call"
        case ItemKind.ToolResult => "tool_result"
        case ItemKind.ReasoningReference => "reasoning_reference"
        case ItemKind.ProviderOpaqueItem => "provider_opaque"
        case ItemKind.ArtifactReference => "artifact_reference"
        case ItemKind.SystemNote => "system_note"
    }
}
