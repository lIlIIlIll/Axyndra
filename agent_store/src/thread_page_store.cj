package agent_store

import std.collection.*
import agent_domain.*

public class SqliteThreadPageStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func loadItemsPage(
        threadId: ThreadId,
        beforeOrdinal: Int64,
        limit: Int64
    ): ThreadItemsPage {
        if (beforeOrdinal < 0 || limit < 1 || limit > 1000) {
            throw IllegalArgumentException(
                "items page requires beforeOrdinal >= 0 and 1 <= limit <= 1000"
            )
        }
        database.readTransaction { transaction =>
            let threadRows = transaction.query(
                "SELECT revision,next_item_ordinal FROM threads WHERE id=" + sqliteText(threadId.value)
            )
            if (threadRows.size != 1) { throw IllegalStateException("durable Thread does not exist") }
            let revision = parseStoreInt(threadRows[0].required(0), "Thread revision")
            let end = if (beforeOrdinal == 0) {
                parseStoreInt(threadRows[0].required(1), "Thread next item ordinal")
            } else {
                beforeOrdinal
            }
            let rows = transaction.query(
                "SELECT id,turn_id,ordinal,kind,payload,provenance,created_at_millis FROM items " +
                    "WHERE thread_id=" + sqliteText(threadId.value) + " AND ordinal<" +
                    end.toString() + " ORDER BY ordinal DESC LIMIT " + (limit + 1).toString()
            )
            let hasMore = rows.size > limit
            let count = min(rows.size, limit)
            let items = ArrayList<ThreadItem>()
            var index = count
            while (index > 0) {
                index -= 1
                let row = rows[index]
                let content = decodeStoredThreadContent(row.required(4))
                if (storedItemKind(threadItemKind(content)) != row.required(3)) {
                    throw IllegalStateException("durable Item kind and payload disagree")
                }
                items.add(ThreadItem(
                    ItemId(row.required(0)), threadId, SemanticTurnId(row.required(1)),
                    parseStoreInt(row.required(2), "Item ordinal"), content,
                    decodeStoredProvenance(row.required(5)),
                    createdAtMillis: parseStoreInt(row.required(6), "Item timestamp")
                ))
            }
            let values = items.toArray()
            ThreadItemsPage(
                threadId, revision, beforeOrdinal,
                if (values.isEmpty()) { 0 } else { values[0].ordinal },
                hasMore, values
            )
        }
    }
}
