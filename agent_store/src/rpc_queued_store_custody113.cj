package agent_store

import agent_domain.*
import agent_runtime.*

func prepareRpcQueuedStoreCell113(value: QueuedRunInitiatorData113,
    allocate: (Int64) -> RpcQueuedStorePayment113,
    retain: (RpcQueuedStoreFailure113) -> Unit): RpcQueuedStoreFailure113 {
    var bytes: Int64 = 0
    for (size in [value.entryId.value.size, value.threadId.value.size, value.laneId.value.size,
        value.correlationId.size, value.kind.size, value.input.size]) {
        if (size > Int64.Max - bytes) { throw IllegalStateException("queued expected input extent overflow") }
        bytes += size }
    if (bytes > (Int64.Max - 131072) / 64) { throw IllegalStateException("queued expected codec invoice overflow") }
    // The original envelope policy pays the expected StoredValue codec and
    // SQL-bound parameter copies, not a claimed exact maximum of SQLite errmsg.
    let peak = 131072 + bytes * 64
    let paid = allocate(peak)
    let cell = RpcQueuedStoreFailure113(value, paid, peak)
    // Unknown registration keeps caller-provided payment alive. Production
    // retain checks/assigns only; no take-before-accept or after-SQL holder.
    retain(cell)
    cell
}
