package agent_runtime

import yjson_support.*

import yjson.*

import std.collection.*
import std.sync.*
import agent_domain.*

// A registry owns the one live mutable Runtime for each Thread. Callers may
// borrow that owner to drive a Turn, but may not construct parallel owners for
// the same Thread.
public interface ThreadRuntimeRegistry {
    func acquire(threadId: ThreadId, workspaceId: String): Result<AgentThreadRuntime>
    func recover(threadId: ThreadId, workspaceId: String): Result<AgentThreadRuntime>
    // Release only the process-local owner. Durable Thread state remains.
    func releaseInactive(threadId: ThreadId): Result<Bool>
    // Explicit lifecycle boundary for ephemeral/imported Threads. A live Run
    // can never be discarded underneath its sole mutable owner.
    func discardInactive(threadId: ThreadId): Result<Bool>
}

class InMemoryThreadRuntimeEntry {
    let threadId: ThreadId
    let runtime: AgentThreadRuntime

    init(threadId: ThreadId, runtime: AgentThreadRuntime) {
        this.threadId = threadId
        this.runtime = runtime
    }
}

public class InMemoryThreadRuntimeRegistry <: ThreadRuntimeRegistry {
    private let lock = Mutex()
    private let projector: ContextProjector
    private let nowMillis: () -> Int64
    private let entries = ArrayList<InMemoryThreadRuntimeEntry>()

    public init(projector: ContextProjector, nowMillis: () -> Int64) {
        this.projector = projector
        this.nowMillis = nowMillis
    }

    public func acquire(
        threadId: ThreadId,
        workspaceId: String
    ): Result<AgentThreadRuntime> {
        lock.lock()
        try {
            for (entry in entries where entry.threadId.value == threadId.value) {
                return Result.Ok(entry.runtime)
            }
            let runtime = AgentThreadRuntime(
                ThreadCoordinator(threadId, workspaceId, InMemoryThreadCommitSink()),
                projector,
                nowMillis
            )
            entries.add(InMemoryThreadRuntimeEntry(threadId, runtime))
            Result.Ok(runtime)
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.Internal,
                "thread.registry_acquire_failed",
                error.message,
                fields: [ErrorField("thread_id", threadId.value)]
            ))
        } finally {
            lock.unlock()
        }
    }

    public func recover(
        threadId: ThreadId,
        workspaceId: String
    ): Result<AgentThreadRuntime> {
        acquire(threadId, workspaceId)
    }

    public func discardInactive(threadId: ThreadId): Result<Bool> {
        releaseInactive(threadId)
    }

    public func releaseInactive(threadId: ThreadId): Result<Bool> {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < entries.size) {
                if (entries[index].threadId.value == threadId.value) {
                    if (entries[index].runtime.activeRun().isSome()) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "thread.registry_discard_active",
                            "cannot discard a Thread with an active Run",
                            fields: [ErrorField("thread_id", threadId.value)]
                        ))
                    }
                    entries.remove(at: index)
                    return Result.Ok(true)
                }
                index += 1
            }
            Result.Ok(false)
        } finally {
            lock.unlock()
        }
    }
}

// Deterministic conservative fallback for product and fake-model lanes. A
// provider-calibrated estimator can replace it without changing Thread truth.
public class ConservativeThreadTokenEstimator <: ThreadTokenEstimator {
    public init() {}

    public func estimateSystemInstructions(version: String): Int64 {
        estimateTextTokens(version) + 16
    }

    public func estimateToolSet(snapshot: ToolSetSnapshot): Int64 {
        var total: Int64 = 8
        for (entry in snapshot.entries) {
            total += estimateTextTokens(entry.name) +
                estimateTextTokens(entry.description) + 32
        }
        total
    }

    public func estimateCheckpoint(checkpoint: ContextCheckpoint): Int64 {
        let _ = checkpoint.structuredSummary
        var total = estimateTextTokens(checkpoint.activeGoal) + 64
        for (note in checkpoint.durableNotes) { total += estimateTextTokens(note) }
        for (reference in checkpoint.artifactReferences) {
            total += estimateTextTokens(reference)
        }
        total
    }

    public func estimateItem(item: ThreadItem): Int64 {
        match (item.content) {
            case ThreadItemContent.UserMessage(parts) => estimateParts(parts) + 8
            case ThreadItemContent.AssistantMessage(parts) => estimateParts(parts) + 8
            case ThreadItemContent.ToolCall(_, name, _) => estimateTextTokens(name) + 48
            case ThreadItemContent.ToolResult(_, _, receiptId, _, _) =>
                estimateTextTokens(receiptId) + 48
            case ThreadItemContent.ReasoningReference(referenceId, summary) =>
                estimateTextTokens(referenceId) + estimateTextTokens(summary) + 16
            case ThreadItemContent.ProviderOpaqueItem(value) =>
                estimateTextTokens(value.providerId) + estimateTextTokens(value.payload) + 16
            case ThreadItemContent.ArtifactReference(hash, mime, _) =>
                estimateTextTokens(hash) + estimateTextTokens(mime) + 16
            case ThreadItemContent.SystemNote(value) => estimateTextTokens(value) + 8
        }
    }

    public func estimateDynamicState(dynamicState: AgentValue): Int64 {
        let _ = dynamicState
        32
    }
}

func estimateParts(parts: Array<ThreadMessagePart>): Int64 {
    var total: Int64 = 0
    for (part in parts) {
        total += match (part) {
            case ThreadMessagePart.Text(value) => estimateTextTokens(value)
            case ThreadMessagePart.Refusal(value) => estimateTextTokens(value)
            case ThreadMessagePart.Image(image) =>
                if (image.sourceKind == ThreadImageSourceKind.Base64) {
                    max(256, image.data.size / 16)
                } else {
                    256
                }
        }
    }
    total
}

func estimateTextTokens(value: String): Int64 {
    max(1, (value.toArray().size + 2) / 3)
}
