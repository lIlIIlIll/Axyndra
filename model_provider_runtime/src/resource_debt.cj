package model_provider_runtime

import agent_domain.*
import std.sync.*
import std.time.*

// One task in the existing RunScope, admitted before any owned resource opens.
// Cancellation requests cleanup; it never substitutes for a resource ACK.
public class ModelProviderResourceDebt {
    private var dispatch: ?ModelProviderDispatch
    private var release: ?(() -> Result<Unit>)
    private var actualTask159: ?Future<Unit> = None<Future<Unit>>
    private var closeFrames159: Int64 = 0
    private var joined159 = false
    private let admissionLock = Mutex()
    private let releaseLock = Mutex()
    private var started = false
    private let admission = AtomicInt64(0)
    private let closing = AtomicBool(false)
    private let released = AtomicBool(false)
    private var joinOwned: ?ModelProviderTaskJoin = None

    public init(dispatch: ModelProviderDispatch, release: () -> Result<Unit>) {
        this.dispatch = Some(dispatch); this.release = Some(release)
    }

    public func admit(): Result<Unit> {
        admissionLock.lock()
        try {
            if (started) { return resourceDebtError("model.resource_task_duplicate") }
            started = true
        } finally { admissionLock.unlock() }
        let task = try { spawn {
            while (admission.load() == 0) { sleep(Duration.millisecond) }
            if (admission.load() < 0) { return }
            while (!released.load()) {
                if (closing.load() || dispatch.getOrThrow().cancellation.isCancelled()) {
                    closing.store(true)
                    // A callback exception is not cleanup acknowledgement.
                    let _ = attemptRelease()
                }
                if (!released.load()) { sleep(Duration.millisecond * 25) }
            }
        } } catch (_: Exception) { return resourceDebtError("model.resource_task_start_failed") }
        admissionLock.lock()
        try { actualTask159 = Some(task) } finally { admissionLock.unlock() }
        let result = try { dispatch.getOrThrow().ownResourceTask("model-resources/" + dispatch.getOrThrow().attemptId.value, task) }
            catch (_: Exception) { Result<ModelProviderTaskJoin>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "model.resource_task_registration_failed", "model resource task registration failed")) }
        admissionLock.lock()
        try { match (result) { case Result.Ok(join) => joinOwned = Some(join); case Result.Err(_) => () } }
        finally { admissionLock.unlock() }
        admission.store(if (result.isOk()) { 1 } else { -1 })
        if (result.isError()) {
            // The unowned task cannot run the callback or I/O. Reap this tiny
            // admission waiter before returning the failure to the caller.
            try { task.get() } catch (_: Exception) {}
        }
        match (result) { case Result.Ok(_) => Result.Ok(()); case Result.Err(error) => Result.Err(error) }
    }

    public func requestClose(): Unit { closing.store(true) }
    public func isReleased(): Bool { released.load() }
    public func isClosing(): Bool { closing.load() }
    public func close(): Result<Unit> {
        closing.store(true)
        admissionLock.lock()
        try {
            if (joined159 && closeFrames159 == 0) { return Result.Ok(()) }
            if (admission.load() != 1) { return resourceDebtError("model.resource_task_unowned") }
            if (closeFrames159 == Int64.Max) { return resourceDebtError("model.provider_cleanup_pending") }
            closeFrames159++
        } finally { admissionLock.unlock() }
        try { closeResourceFrames159() }
        finally {
            admissionLock.lock()
            try {
                closeFrames159--
                // Every caller's copied task/join/release helper has returned.
                // A scheduler may still retain this cell, whose payload fields
                // are now empty; no garbage-collection assumption is needed.
                if (joined159 && closeFrames159 == 0) {
                    release = None<() -> Result<Unit>>
                    dispatch = None<ModelProviderDispatch>
                    joinOwned = None<ModelProviderTaskJoin>
                    actualTask159 = None<Future<Unit>>
                }
            } finally { admissionLock.unlock() }
        }
    }

    private func closeResourceFrames159(): Result<Unit> {
        match (attemptRelease()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let result = joinResourceFrames159()
        if (result.isOk()) {
            admissionLock.lock(); try { joined159 = true } finally { admissionLock.unlock() }
        }
        result
    }
    private func joinResourceFrames159(): Result<Unit> {
        let selected = { => admissionLock.lock(); try { (joinOwned, actualTask159) }
            finally { admissionLock.unlock() } }()
        // The original RunScope join remains mandatory. In addition observe
        // this exact spawned Future, not an unrelated completion flag or Unit.
        match (selected[0]) {
            case Some(join) => match (join()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => return resourceDebtError("model.resource_task_unowned")
        }
        match (selected[1]) {
            case Some(task) => try { task.get() }
                catch (_: Exception) { return resourceDebtError("model.provider_cleanup_pending") }
            case None => return resourceDebtError("model.resource_task_unowned")
        }
        Result.Ok(())
    }
    // Closed scalar observation only. It authorizes neither I/O nor Source
    // and cannot retire a request, stream, catalog, or an external consumer.
    public func inputResourceReferencesReturned159(): Bool {
        admissionLock.lock()
        try { joined159 && closeFrames159 == 0 && release.isNone() &&
            dispatch.isNone() && joinOwned.isNone() && actualTask159.isNone() }
        finally { admissionLock.unlock() }
    }

    private func attemptRelease(): Result<Unit> {
        releaseLock.lock()
        try {
            if (released.load()) { return Result.Ok(()) }
            let result = try { release.getOrThrow()() } catch (_: Exception) { resourceDebtError("model.provider_cleanup_pending") }
            if (result.isOk()) { released.store(true) }
            result
        } finally { releaseLock.unlock() }
    }
}

func resourceDebtError(code: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "model resource task has not acknowledged ownership or cleanup"))
}
