package agent_product

import agent_domain.*
import std.sync.*
import std.time.*

// One Product owns this coordinator. No descriptor, permission or Run is
// published by it: the existing assembly still performs all real mounts.
class ProductExecutionReadiness {
    private let lock = Mutex()
    private let cancellation = CancellationSource()
    private var prepare: ?(CancellationToken) -> Result<Unit> = None
    private var pending: ?Future<Result<Unit>> = None
    private var closing = false

    func configure(action: (CancellationToken) -> Result<Unit>): Unit {
        lock.lock()
        try {
            if (closing || pending.isSome() || prepare.isSome()) {
                throw IllegalStateException("execution readiness is already configured or closed") }
            prepare = Some(action)
        } finally { lock.unlock() }
    }

    func ensure(waiter: ?CancellationToken): Result<Unit> {
        match (waiter) { case Some(token) => match (token.check()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        lock.lock()
        let future = try {
            if (closing) { return readinessClosed() }
            if (pending.isNone()) {
                match (prepare) {
                    case None => return Result.Ok(())
                    case Some(action) => pending = Some(spawn { =>
                        try { action(cancellation.token) }
                        catch (_: Exception) { Result<Unit>.Err(AgentError(AgentErrorKind.Internal,
                            "product.execution_preparation_failed", "Product execution preparation failed")) }
                    })
                }
            }
            pending.getOrThrow()
        } finally { lock.unlock() }
        while (future.tryGet().isNone()) {
            match (waiter) { case Some(token) => match (token.check()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
            sleep(Duration.millisecond * 10)
        }
        match (waiter) { case Some(token) => match (token.check()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        let result = future.get()
        lock.lock()
        try { if (closing) { return readinessClosed() }; result }
        finally { lock.unlock() }
    }

    func close(): Unit {
        lock.lock()
        let future = try { closing = true; cancellation.cancel(); pending }
            finally { lock.unlock() }
        // Joining every original helper precedes Catalog/Registry teardown.
        // A failed or thrown preparation is not translated into successful
        // readiness; close merely collects its physical producer frame.
        match (future) { case Some(value) => let _ = value.get(); case None => () }
        lock.lock(); try { prepare = None; pending = None } finally { lock.unlock() }
    }
    private func readinessClosed(): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.Cancelled, "product.execution_readiness_closed",
            "Product execution preparation is closed"))
    }
}
