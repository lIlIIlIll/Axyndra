package agent_product

import agent_domain.*
import std.sync.*

// Constructed only after the actual installed parent's same-bank metadata
// reservation. The Task supervisor owns the returned physical future. This
// holder cannot mint a Source, a new Run, a Receipt or an unearned data ACK.
class ProductPluginChildPhysicalWorker111 {
    var worker: ?Future<Unit> = Option<Future<Unit>>.None
    func returned(): Bool {
        if (worker.isNone()) { return false }
        try { worker.getOrThrow().tryGet().isSome() }
        catch (_: Exception) { false }
    }
    func collect(): Unit { worker.getOrThrow().get() }
}

class ProductPluginChildWorkerResult111<T> {
    let physical = ProductPluginChildPhysicalWorker111()
    private var outcome: ?Result<T> = Option<Result<T>>.None
    func run(action: () -> Result<T>): Unit { outcome = Some(action()) }
    func collect(): Result<T> {
        try {
            physical.collect()
            match (outcome) {
                case Some(value) => value
                case None => taskError("child.worker_result_missing", "actual child worker returned no typed result")
            }
        } catch (_: Exception) {
            // No physical-completion witness is produced on this path. The
            // original Task collector and same-bank data owner retain custody.
            taskError("child.worker_cleanup_required", "actual child worker did not acknowledge its complete callback")
        }
    }
}
