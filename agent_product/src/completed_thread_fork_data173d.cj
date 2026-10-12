package agent_product

import agent_domain.*
import agent_store.*

// A synchronous historical DATA operation under the actual installed policy's
// bank/current gate. It neither executes a Tool nor offers a new permission.
interface OwnedCompletedThreadForkData173d {
    func forkCompletedThreadData173d(source: SessionId, target: SessionId, workspace: String,
        database: SqliteDatabase, cancellation: CancellationToken): Result<Unit>
}
