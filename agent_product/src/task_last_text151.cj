package agent_product

import agent_domain.*
import agent_core.visitOwnedCanonicalModelMessages113
import agent_runtime.*
import agent_store.*

// Actual provider-neutral model-message boundaries, not a raw Thread snapshot.
// No complete history/messages Array is built or forwarded to Native policy.
class ProductTaskLastText151 {
    private let owner: LogicalJsonOwnerReservation
    private var current = ""
    private var selected = ""
    private var assistant = false
    init(owner: LogicalJsonOwnerReservation) { this.owner = owner; owner.ensureRetainedPeak(8192) }
    func begin(role: ModelRole): Unit {
        if (assistant && current != "") { selected = current }
        current = ""; assistant = role == ModelRole.Assistant
    }
    func block(role: ModelRole, block: ModelBlock): Unit {
        if (role != ModelRole.Assistant || block.kind != ModelBlockKind.Text) { return }
        // Old current String, complete new concatenation, independent block
        // UTF8 copy, and the previously selected message coexist. High-water
        // only grows; actual charge is not refunded when a new message begins.
        let bytes = selected.size + current.size * 2 + block.text.size * 2
        if (bytes < 0 || bytes > (Int64.Max - 8192) / 8) {
            throw IllegalStateException("Task text invoice overflow") }
        owner.ensureRetainedPeak(8192 + bytes * 8)
        current += String.fromUtf8(block.text.toArray())
    }
    func consume(consumer: (String) -> Unit): Unit {
        if (assistant && current != "") { selected = current }
        consumer(selected)
    }
    func close(): Unit { current = ""; selected = ""; owner.close() }
}

func productVisitTaskLastText151(database: SqliteDatabase, session: SessionId,
    allocate: (Int64) -> LogicalJsonOwnerReservation, local: () -> Result<Unit>, consume: (String) -> Unit): Result<Unit> {
    let owner = allocate(8192)
    let text = try { ProductTaskLastText151(owner) } catch (error: Exception) { owner.close(); throw error }
    let cursor = SqlitePaidCanonicalThreadCursor113(database, allocate)
    try {
        let answer = cursor.withHeader(ThreadId(session.value), local, { header =>
            visitOwnedCanonicalModelMessages113(cursor, header.id, header.revision, header.nextItemOrdinal,
                header.nextItemOrdinal - 1, allocate, local, local,
                { role => text.begin(role) }, { role, block, _ => text.block(role, block) }) })
        match (answer) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        text.consume(consume)
        Result<Unit>.Ok(())
    } finally { text.close() }
}
