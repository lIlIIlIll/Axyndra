package tool_runtime

import agent_domain.*
import std.collection.*
import std.deriving.*
import std.sync.*

@Derive[Equatable]
enum NestedToolFrameStage { Ready | Yielded | Child }

class NestedToolFrame {
    let operationId: OperationId
    let toolName: String
    var stage = NestedToolFrameStage.Ready
    var executorReturned = false
    var actionReturned = false
    var calls: Int64 = 0
    init(operationId: OperationId, toolName: String) {
        this.operationId = operationId; this.toolName = toolName
    }
}

// Host scheduler bookkeeping only. This object never admits an Operation or
// grants execution. Each frame borrows the SAME reservation; only the root's
// actual scheduler calls takeRelease() and returns that one ledger slot.
public class NestedToolSlotFrames {
    public let rootOperationId: OperationId
    private let lock = Mutex()
    private let frames = ArrayList<NestedToolFrame>()
    private let identities = HashSet<String>()
    private var rootFinished = false
    private var releasePending = false
    private var released = false
    private var calls: Int64 = 0
    private var bounded = false

    public init(rootOperationId: OperationId, toolName: String) {
        this.rootOperationId = rootOperationId
        frames.add(NestedToolFrame(rootOperationId, toolName))
        identities.add(rootOperationId.value)
    }

    public func contains(operationId: OperationId): Bool {
        lock.lock()
        try { indexOf(operationId) >= 0 } finally { lock.unlock() }
    }

    public func begin(operationId: OperationId): Result<Unit> {
        lock.lock()
        try {
            let index = indexOf(operationId)
            if (rootFinished || index < 0 || index != frames.size - 1) { return denied("run.tool_slot_not_active") }
            let frame = frames[index]
            if (frame.executorReturned || frame.stage != NestedToolFrameStage.Ready) {
                return denied("run.tool_slot_transition_invalid")
            }
            if (frame.toolName != "run_program" && !frame.toolName.startsWith("plugin.")) {
                return denied("run.tool_slot_parent_denied")
            }
            // Ordinary root quotas remain enforced by their existing broker.
            // Deeper frames additionally share this non-refundable hard bound.
            if (bounded && (index >= HOST_DERIVED_MAX_DEPTH || calls >= HOST_DERIVED_MAX_OPERATIONS || frame.calls >= HOST_DERIVED_MAX_WIDTH)) { return denied("run.tool_tree_limit") }
            calls += 1; frame.calls += 1
            frame.actionReturned = false; frame.stage = NestedToolFrameStage.Yielded
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func activate(operationId: OperationId): Result<Unit> {
        lock.lock()
        try {
            let index = indexOf(operationId)
            if (index < 0 || frames[index].stage != NestedToolFrameStage.Yielded) {
                return denied("run.tool_slot_transition_invalid")
            }
            let frame = frames[index]
            if (rootFinished || frame.executorReturned) {
                frame.stage = NestedToolFrameStage.Ready; prune()
                return denied("run.tool_parent_finished")
            }
            frame.stage = NestedToolFrameStage.Child
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func restore(operationId: OperationId): Result<Unit> {
        lock.lock()
        try {
            let index = indexOf(operationId)
            if (index < 0 || frames[index].stage != NestedToolFrameStage.Yielded) {
                return denied("run.tool_slot_transition_invalid")
            }
            frames[index].stage = NestedToolFrameStage.Ready
            let finished = rootFinished || frames[index].executorReturned
            prune()
            if (finished) { denied("run.tool_parent_finished") } else { Result.Ok(()) }
        } finally { lock.unlock() }
    }

    public func returnChild(operationId: OperationId): Result<Unit> {
        lock.lock()
        try {
            let index = indexOf(operationId)
            if (index < 0 || frames[index].stage != NestedToolFrameStage.Child) {
                return denied("run.tool_slot_transition_invalid")
            }
            frames[index].actionReturned = true
            if (index != frames.size - 1) {
                // A callback returned before its deeper executor. Retain the
                // reservation until that executor AND its nested action return.
                return denied("run.tool_descendant_pending")
            }
            frames[index].stage = NestedToolFrameStage.Ready; prune()
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func enter(parent: OperationId, child: OperationId, toolName: String): Result<Unit> {
        lock.lock()
        try {
            let index = indexOf(parent)
            if (rootFinished || index < 0 || index != frames.size - 1 || index >= HOST_DERIVED_MAX_DEPTH ||
                frames[index].stage != NestedToolFrameStage.Child || frames[index].executorReturned ||
                frames[index].actionReturned || calls > HOST_DERIVED_MAX_OPERATIONS || frames[index].calls > HOST_DERIVED_MAX_WIDTH ||
                identities.contains(child.value) || identities.size >= HOST_DERIVED_MAX_OPERATIONS + 1 ||
                !toolName.startsWith("plugin.")) { return denied("run.tool_frame_invalid") }
            bounded = true; identities.add(child.value); frames.add(NestedToolFrame(child, toolName))
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func leave(child: OperationId): Result<Unit> {
        lock.lock()
        try {
            let index = indexOf(child)
            if (index <= 0 || frames[index].executorReturned) { return denied("run.tool_frame_invalid") }
            frames[index].executorReturned = true
            let pending = frames[index].stage != NestedToolFrameStage.Ready || index != frames.size - 1
            prune()
            if (pending) { denied("run.tool_descendant_pending") } else { Result.Ok(()) }
        } finally { lock.unlock() }
    }

    public func finishRoot(): Unit {
        lock.lock()
        try {
            rootFinished = true
            if (!frames.isEmpty()) { frames[0].executorReturned = true }
            prune()
        } finally { lock.unlock() }
    }

    public func takeRelease(): Bool {
        lock.lock()
        try {
            if (!releasePending || released) { return false }
            released = true; releasePending = false; true
        } finally { lock.unlock() }
    }

    private func indexOf(operationId: OperationId): Int64 {
        for (index in 0..frames.size where frames[index].operationId.value == operationId.value) { return index }
        -1
    }

    private func prune(): Unit {
        while (!frames.isEmpty()) {
            let last = frames[frames.size - 1]
            if (!last.executorReturned || last.stage != NestedToolFrameStage.Ready) { return }
            frames.remove(at: frames.size - 1)
            if (!frames.isEmpty()) {
                let parent = frames[frames.size - 1]
                if (parent.actionReturned && parent.stage == NestedToolFrameStage.Child) {
                    parent.stage = NestedToolFrameStage.Ready
                }
            }
        }
        if (rootFinished && !released) { releasePending = true }
    }

    private func denied(code: String): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
            "nested work does not own the current bounded Run tool frame"))
    }
}
