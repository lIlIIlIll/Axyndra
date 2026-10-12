package agent_app

import agent_domain.*
import agent_product.*
import agent_rpc.*
import agent_runtime.*
import std.sync.*
import std.time.*

// This is a NEW frontend policy: 5000ms after this frontend OBSERVES EOF,
// completion of its once command, or a startup failure. It is not the old
// service deadline, a runner timeout, or proof of physical process exit.
// Ordinary ready/response writes and handle() before that observation retain
// their old synchronous behavior. A blocked path there remains outside this
// narrow stage; no arbitrary-EOF or OS-write cancellation claim is made.
let RPC_FRONTEND_OBSERVED_EXIT_MILLIS113: Int64 = 5000

// Caller prepaid this cell and its Future/action/control references before
// constructing it. Dynamic secondary errors get another SAME-bank share.
class RpcFrontendTask113 {
    var future: ?Future<Unit> = None<Future<Unit>>
    var metadata: ?LogicalJsonOwnerReservation
    var starting = true
    var unavailable = false
    var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    let failed = AtomicBool(false)
    init(metadata: LogicalJsonOwnerReservation) { this.metadata = Some(metadata) }
}

// Main, not serveRpc's local scope, owns this controller. Its original Native
// control root stays alive for Root lifetime: Session subscription has no
// unsubscribe, and physical exit is never treated as an output ACK/refund.
class RpcFrontendShutdown113 {
    private let metadata: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private let output = RpcOutput()
    private var session: ?ApplicationSession = None<ApplicationSession>
    private var server: ?ProductJsonlRpcServer = None<ProductJsonlRpcServer>
    private var startup: ?RpcFrontendTask113 = None<RpcFrontendTask113>
    private var pump: ?RpcFrontendTask113 = None<RpcFrontendTask113>
    private var cleanup: ?RpcFrontendTask113 = None<RpcFrontendTask113>
    private var startupStaging: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var pumpStaging: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var cleanupStaging: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var cleanupLaunched = false
    private let startupFailed = AtomicBool(false)
    private let startupReturned = AtomicBool(false)
    private let cleanupReady = AtomicBool(false)
    private let debt = AtomicBool(false)
    private let exitRequested = AtomicBool(false)
    private let expired = AtomicBool(false)

    init(metadata: LogicalJsonOwnerReservation) { this.metadata = metadata }

    func install113(product: ProductRuntime): ApplicationSession {
        let actual = product.applicationSession()
        session = Some(actual)
        // The registered Session subscriber retains this exact controller via
        // emit; its metadata never depends on a disappearing local holder.
        server = Some(ProductJsonlRpcServer(actual,
            { frame => writePlain113(frame) }, ownedOutput: Some<OwnedRpcFrameOutput>(output)))
        actual
    }
    func server113(): ProductJsonlRpcServer { server.getOrThrow() }
    func writePlain113(frame: String): Unit { output.write(frame) }
    func observedStartupFailure113(): Bool { startupFailed.load() }
    func startupReturned113(): Bool { startupReturned.load() }

    private func task113(kind: Int64): ?RpcFrontendTask113 {
        match (kind) { case 0 => startup; case 1 => pump; case _ => cleanup }
    }
    private func setTask113(kind: Int64, value: ?RpcFrontendTask113): Unit {
        match (kind) { case 0 => startup = value; case 1 => pump = value; case _ => cleanup = value }
    }
    private func setStaging113(kind: Int64, value: ?LogicalJsonOwnerReservation): Unit {
        match (kind) { case 0 => startupStaging = value; case 1 => pumpStaging = value; case _ => cleanupStaging = value }
    }
    private func reserveTask113(kind: Int64): ?RpcFrontendTask113 {
        lock.lock()
        try {
            if (task113(kind).isSome()) { return None<RpcFrontendTask113> }
            let paid = metadata.deriveRetainedLease()
            setStaging113(kind, Some(paid))
            try { paid.ensureRetainedPeak(65536) }
            catch (_: Exception) {
                setStaging113(kind, None<LogicalJsonOwnerReservation>)
                paid.close(); debt.store(true); return None<RpcFrontendTask113>
            }
            // SUM funding above precedes the cell, action closure and spawn.
            let value = RpcFrontendTask113(paid)
            setTask113(kind, Some(value))
            setStaging113(kind, None<LogicalJsonOwnerReservation>)
            Some(value)
        } catch (_: Exception) { debt.store(true); None<RpcFrontendTask113> }
        finally { lock.unlock() }
    }
    private func registerFuture113(task: RpcFrontendTask113, value: Future<Unit>): Unit {
        lock.lock(); try { task.future = Some(value); task.starting = false } finally { lock.unlock() }
    }
    private func unknownSpawn113(task: RpcFrontendTask113): Unit {
        lock.lock(); try { task.unavailable = true; debt.store(true) } finally { lock.unlock() }
        // The registered paid cell is kept. Unknown spawn is not no-producer.
    }

    func startStartup113(): Unit {
        let value = match (reserveTask113(0)) {
            case Some(actual) => actual
            case None => startupFailed.store(true); return }
        try { registerFuture113(value, spawn { startupFrame113(value) }) }
        catch (_: Exception) { startupFailed.store(true); unknownSpawn113(value) }
    }
    private func startupFrame113(task: RpcFrontendTask113): Unit {
        try {
            match (session.getOrThrow().resumeStartup()) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    // This flag starts the NEW exit window; it is not an ACK
                    // or proof that this real producer Future has returned.
                    startupFailed.store(true)
                    if (!server.getOrThrow().admitStartupCheckpointFailure113(error)) {
                        // Preserve the old plain, non-marker branch exactly
                        // once. A true owned marker never takes this fallback.
                        if (error.code.size > Int64.Max - error.message.size) {
                            throw IllegalStateException("rpc.startup_output_extent_overflow") }
                        let size = error.code.size + error.message.size
                        if (size < 0 || size > (Int64.Max - 65536) / 8) {
                            throw IllegalStateException("rpc.startup_output_extent_overflow") }
                        task.metadata.getOrThrow().ensureRetainedPeak(65536 + size * 8)
                        printError(error)
                    }
            }
        } catch (failure: OwnedCanonicalPaidFailure113) {
            startupFailed.store(true); retainPaidFailure113(task, failure.takeConsumer())
        } catch (failure: OwnedCanonicalDataFailure113) {
            startupFailed.store(true); captureFailure113(task, failure.error)
        } catch (failure: Exception) {
            startupFailed.store(true); captureException113(task, failure)
        }
    }

    func requestPump113(): Unit {
        collectFinishedTasks113()
        if (exitRequested.load() || debt.load()) { return }
        let value = match (reserveTask113(1)) { case Some(actual) => actual; case None => return }
        try { registerFuture113(value, spawn { pumpFrame113(value) }) }
        catch (_: Exception) { unknownSpawn113(value) }
    }
    private func pumpFrame113(task: RpcFrontendTask113): Unit {
        try { server.getOrThrow().collectOwnedCheckpointFailures113() }
        catch (failure: OwnedCanonicalPaidFailure113) { retainPaidFailure113(task, failure.takeConsumer()) }
        catch (failure: OwnedCanonicalDataFailure113) { captureFailure113(task, failure.error) }
        catch (failure: Exception) { captureException113(task, failure) }
    }

    private func retainPaidFailure113(task: RpcFrontendTask113, value: OwnedFailureDataConsumer113): Unit {
        // No ACK of the independent complete secondary, and no retry of IO.
        lock.lock(); try { task.secondary = Some(value); task.failed.store(true); debt.store(true) }
        finally { lock.unlock() }
    }
    private func captureFailure113(task: RpcFrontendTask113, error: AgentError): Unit {
        let actual = task.metadata.getOrThrow()
        let secondary = match (captureOwnedFailureData113<Unit>(error,
            { _ => actual.deriveRetainedLease() })) {
            case OwnedFailureDataOutcome113.Failure(value) => value
            case OwnedFailureDataOutcome113.Value(_) => throw IllegalStateException("rpc.failure_capture_missing") }
        retainPaidFailure113(task, secondary)
    }
    private func captureException113(task: RpcFrontendTask113, failure: Exception): Unit {
        let bytes = failure.message.size
        if (bytes < 0 || bytes > (Int64.Max - 65536) / 8) {
            throw IllegalStateException("rpc.frontend_failure_extent_overflow") }
        task.metadata.getOrThrow().ensureRetainedPeak(65536 + bytes * 8)
        captureFailure113(task, AgentError(AgentErrorKind.Transport,
            "rpc.frontend_cleanup_failed", failure.message, retryable: false, fallbackAllowed: false))
        // If cloning/pressure itself throws, the actual exceptional Future and
        // its original paid cell stay registered; query failure never refunds.
    }

    func requestShutdown113(cancelBash: Bool): Unit {
        exitRequested.store(true)
        lock.lock()
        let first = try {
            if (cleanupLaunched) { false } else { cleanupLaunched = true; true }
        } finally { lock.unlock() }
        if (!first) { return }
        let value = match (reserveTask113(2)) { case Some(actual) => actual; case None => return }
        try { registerFuture113(value, spawn { cleanupFrame113(value, cancelBash) }) }
        catch (_: Exception) { unknownSpawn113(value) }
    }
    private func cleanupFrame113(task: RpcFrontendTask113, cancelBash: Bool): Unit {
        try {
            let actual = server.getOrThrow()
            // All server/frame/output locks and potentially blocking waits are
            // taken ONLY by this separately paid producer, never by the parent.
            actual.beginRunWorkerShutdown113()
            actual.close(cancelBash: cancelBash)
            while (!expired.load()) {
                let dataClear = actual.collectFrontendOutputRetirement113()
                let workersClear = actual.collectRunWorkerRetirement113()
                if (startupReturned.load() && dataClear && workersClear &&
                    session.getOrThrow().queuedCount() == 0) {
                    cleanupReady.store(true); return
                }
                sleep(Duration.millisecond * 10)
            }
        } catch (failure: OwnedCanonicalPaidFailure113) { retainPaidFailure113(task, failure.takeConsumer()) }
        catch (failure: OwnedCanonicalDataFailure113) { captureFailure113(task, failure.error) }
        catch (failure: Exception) { captureException113(task, failure) }
    }

    // The only completion query used by the parent. It touches this short
    // metadata lock and Future.tryGet, never server/frame/output/stdout locks.
    // A successful helper removes Future/cell aliases before returning a lease.
    private func takeReturnedTaskLease113(kind: Int64): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            let value = match (task113(kind)) { case Some(actual) => actual; case None => return None<LogicalJsonOwnerReservation> }
            if (value.starting || value.unavailable || value.failed.load() || value.secondary.isSome()) {
                return None<LogicalJsonOwnerReservation> }
            let actual = value.future.getOrThrow()
            let returned = try { actual.tryGet().isSome() }
                catch (_: Exception) { value.unavailable = true; debt.store(true); false }
            if (!returned) { return None<LogicalJsonOwnerReservation> }
            value.future = None<Future<Unit>>
            let paid = value.metadata
            value.metadata = None<LogicalJsonOwnerReservation>
            setTask113(kind, None<RpcFrontendTask113>)
            if (kind == 0) { startupReturned.store(true) }
            paid
        } finally { lock.unlock() }
    }
    func collectFinishedTasks113(): Unit {
        for (kind in 0..3) {
            let paid = takeReturnedTaskLease113(kind)
            // All real Future/action/cell/helper references have gone before
            // this specific SUM child is closed. The Root control stays alive.
            match (paid) { case Some(actual) => actual.close(); case None => () }
        }
    }
    private func hasLiveTasks113(): Bool {
        lock.lock(); try {
            startup.isSome() || pump.isSome() || cleanup.isSome() ||
                startupStaging.isSome() || pumpStaging.isSome() || cleanupStaging.isSome()
        } finally { lock.unlock() }
    }
    func finishObservedExit113(status: Int64, cancelBash: Bool): Int64 {
        let until = MonoTime.now() + Duration.millisecond * RPC_FRONTEND_OBSERVED_EXIT_MILLIS113
        requestShutdown113(cancelBash)
        while (MonoTime.now() < until) {
            collectFinishedTasks113()
            if (cleanupReady.load() && !hasLiveTasks113() && !debt.load()) { return status }
            sleep(Duration.millisecond * 10)
        }
        expired.store(true)
        // No possibly-blocking stderr/stdout message on this parent path.
        // Root still holds every unACKed source/output/secondary and Future.
        // Returning nonzero is not a physical exit/kill or consumption receipt.
        1
    }
    func finishRootStatus113(status: Int64): Int64 {
        // This explicit use AFTER serveRpc's return keeps the Root-scope owner
        // alive through the mode call. Subscription/Future owners retain it.
        if (debt.load() || (exitRequested.load() && !cleanupReady.load())) { 1 } else { status }
    }
}
