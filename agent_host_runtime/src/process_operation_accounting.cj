package agent_host_runtime

import agent_domain.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.sync.*

class HostProcessOperation {
    let id: OperationId
    let runId: RunId
    var cancelled = false
    init(id: OperationId, runId: RunId) { this.id = id; this.runId = runId }
}

// Register ownership before entering the process port. LocalProcessPort's
// reservation bridges cancellation between admission and its onStarted hook.
public class HostProcessOperations {
    private let lock = Mutex()
    private let active = ArrayList<HostProcessOperation>()
    private let reserve: (OperationId) -> Unit
    private let release: (OperationId) -> Unit
    private let stop: (OperationId) -> Result<Unit>
    public init(prefix: String, reserve: (OperationId) -> Unit,
        release: (OperationId) -> Unit, stop: (OperationId) -> Result<Unit>) {
        let _ = prefix
        this.reserve = reserve
        this.release = release
        this.stop = stop
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        action: (OperationId) -> Result<ProcessResult>): Result<ProcessResult> {
        match (context.cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case _ => ()
        }
        executeWithOperation(context, prepared, prepared.operationId, action)
    }

    public func executeWithOperation(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        operationId: OperationId,
        action: (OperationId) -> Result<ProcessResult>
    ): Result<ProcessResult> {
        let _ = prepared
        let operation = HostProcessOperation(operationId, context.runId)
        lock.lock()
        try {
            reserve(operation.id)
            active.add(operation)
        } finally {
            lock.unlock()
        }
        let registration = context.cancellation.onCancel({ _ => let _ = cancelOperation(operation) })
        try {
            match (context.cancellation.check()) {
                case Result.Err(error) => return Result.Err(error)
                case _ => ()
            }
            if (wasCancelled(operation)) { return cancelledResult() }
            let result = action(operation.id)
            if (wasCancelled(operation)) { return cancelledResult() }
            match (context.cancellation.check()) {
                case Result.Err(error) => return Result.Err(error)
                case _ => ()
            }
            result
        } finally {
            registration.dispose()
            lock.lock()
            try {
                for (index in 0..active.size) {
                    if (active[index].id.value == operation.id.value) {
                        active.remove(at: index)
                        break
                    }
                }
                release(operation.id)
            } finally {
                lock.unlock()
            }
        }
    }
    private func cancelledResult(): Result<ProcessResult> {
        Result.Err(AgentError(AgentErrorKind.Cancelled, "process.cancelled", "process tool operation was cancelled"))
    }
    private func wasCancelled(operation: HostProcessOperation): Bool {
        lock.lock(); try { operation.cancelled } finally { lock.unlock() }
    }
    private func cancelOperation(operation: HostProcessOperation): Result<Unit> {
        lock.lock()
        try { operation.cancelled = true } finally { lock.unlock() }
        // stop() can synchronously finish the action and enter execute()'s
        // cleanup. Never hold the operation registry lock across that call.
        stop(operation.id)
    }
    public func cancel(runId: RunId): Result<Unit> {
        let targets = ArrayList<OperationId>()
        lock.lock()
        try {
            for (operation in active where operation.runId.value == runId.value) {
                operation.cancelled = true
                targets.add(operation.id)
            }
        } finally { lock.unlock() }
        var failure: ?AgentError = None
        for (operationId in targets) {
            match (stop(operationId)) {
                case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }
                case Result.Ok(_) => ()
            }
        }
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
    }
}

public func hostProcessOperations(processes: ProcessPort, prefix: String): HostProcessOperations {
    HostProcessOperations(prefix,
        { id => processes.reserveOperation(id) },
        { id => processes.releaseOperation(id) },
        { id => processes.cancel(id) })
}
