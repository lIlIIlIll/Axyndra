package agent_store

import agent_domain.*

public class OperationSemanticCommit {
    public let operationId: String
    public let runId: String
    public let receiptId: String
    public let outcome: OperationOutcome
    public let receiptDetail: String
    public let verification: String
    public let toolResultItemId: String
    public let threadId: String
    public let turnId: String
    public let itemOrdinal: Int64
    public let itemPayload: String
    public let itemProvenance: String
    public let createdAtMillis: Int64
    public let expectedThreadRevision: Int64
    public let nextRunState: String

    public init(
        operationId: String,
        runId: String,
        receiptId: String,
        outcome: OperationOutcome,
        receiptDetail: String,
        verification: String,
        toolResultItemId: String,
        threadId: String,
        turnId: String,
        itemOrdinal: Int64,
        itemPayload: String,
        itemProvenance: String,
        createdAtMillis: Int64,
        expectedThreadRevision: Int64,
        nextRunState: String
    ) {
        for (value in [
            operationId, runId, receiptId, toolResultItemId,
            threadId, turnId, itemPayload, itemProvenance, nextRunState
        ] where value.trimAscii() == "") {
            throw IllegalArgumentException("operation semantic commit fields must not be empty")
        }
        if (itemOrdinal < 1 || createdAtMillis < 0 || expectedThreadRevision < 0) {
            throw IllegalArgumentException("operation semantic commit counters are invalid")
        }
        this.operationId = operationId
        this.runId = runId
        this.receiptId = receiptId
        this.outcome = outcome
        this.receiptDetail = receiptDetail
        this.verification = verification
        this.toolResultItemId = toolResultItemId
        this.threadId = threadId
        this.turnId = turnId
        this.itemOrdinal = itemOrdinal
        this.itemPayload = itemPayload
        this.itemProvenance = itemProvenance
        this.createdAtMillis = createdAtMillis
        this.expectedThreadRevision = expectedThreadRevision
        this.nextRunState = nextRunState
    }
}

public class AgentStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        this.database = database
    }

    // This is the only durable boundary that turns an external effect into a
    // canonical ToolResult. A partial receipt/operation/item/run transition is
    // never observable after rollback or process recovery.
    public func commitOperationResult(commit: OperationSemanticCommit): Unit {
        database.transaction { transaction =>
            requireRow(
                transaction,
                "SELECT run_id,state FROM operations WHERE id=" +
                    sqliteText(commit.operationId),
                [commit.runId, "executing"],
                "operation is not the expected executing operation"
            )
            requireRow(
                transaction,
                "SELECT thread_id,turn_id FROM runs WHERE id=" + sqliteText(commit.runId),
                [commit.threadId, commit.turnId],
                "operation run ownership changed before commit"
            )
            requireRow(
                transaction,
                "SELECT revision,next_item_ordinal,active_turn_id FROM threads WHERE id=" +
                    sqliteText(commit.threadId),
                [
                    commit.expectedThreadRevision.toString(),
                    commit.itemOrdinal.toString(),
                    commit.turnId
                ],
                "thread revision or active turn changed before operation commit"
            )
            transaction.execute(
                "INSERT INTO operation_receipts " +
                    "(id,operation_id,outcome,detail,verification,created_at_millis) VALUES (" +
                    sqliteText(commit.receiptId) + "," +
                    sqliteText(commit.operationId) + "," +
                    sqliteText(operationOutcomeName(commit.outcome)) + "," +
                    sqliteText(commit.receiptDetail) + "," +
                    sqliteText(commit.verification) + "," +
                    commit.createdAtMillis.toString() + ")"
            )
            transaction.execute(
                "UPDATE operations SET state='committed',revision=revision+1 WHERE id=" +
                    sqliteText(commit.operationId) + " AND state='executing'"
            )
            requireChanged(transaction, "operation state transition lost its owner")
            transaction.execute(
                "INSERT INTO items " +
                    "(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (" +
                    sqliteText(commit.toolResultItemId) + "," +
                    sqliteText(commit.threadId) + "," +
                    sqliteText(commit.turnId) + "," +
                    commit.itemOrdinal.toString() + ",'tool_result'," +
                    sqliteText(commit.itemPayload) + "," +
                    sqliteText(commit.itemProvenance) + "," +
                    commit.createdAtMillis.toString() + ")"
            )
            transaction.execute(
                "UPDATE runs SET state=" + sqliteText(commit.nextRunState) +
                    " WHERE id=" + sqliteText(commit.runId)
            )
            requireChanged(transaction, "run transition lost its owner")
            transaction.execute(
                "UPDATE threads SET revision=revision+1,next_item_ordinal=next_item_ordinal+1 " +
                    "WHERE id=" + sqliteText(commit.threadId) + " AND revision=" +
                    commit.expectedThreadRevision.toString() + " AND next_item_ordinal=" +
                    commit.itemOrdinal.toString() + " AND active_turn_id=" +
                    sqliteText(commit.turnId)
            )
            requireChanged(transaction, "thread commit lost its semantic owner")
        }
    }
}

func requireRow(
    transaction: SqliteTransaction,
    sql: String,
    expected: Array<String>,
    message: String
): Unit {
    let rows = transaction.query(sql)
    if (rows.size != 1 || rows[0].size != expected.size) {
        throw IllegalStateException(message)
    }
    for (index in 0..expected.size) {
        if (rows[0].required(index) != expected[index]) {
            throw IllegalStateException(message)
        }
    }
}

func requireChanged(transaction: SqliteTransaction, message: String): Unit {
    if (transaction.query("SELECT changes()")[0].required(0) != "1") {
        throw IllegalStateException(message)
    }
}
