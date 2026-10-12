package agent_rpc

import agent_domain.*
import agent_product.*
import agent_runtime.OwnedFailureDataOutcome113
import std.collection.*
import std.sync.*

// Construction is deliberately outside the class: the original Native bank
// is charged before the controller, locks, registries or caller closures exist.
public func newAcpOwnedWorkerControl113(): AcpOwnedWorkerControl113 {
    let paid = reserveProductControlMetadata113(65536)
    AcpOwnedWorkerControl113(paid)
}

public interface AcpFrontendCustody113 {
    func retireAfterFrontendHelperReturn113(): Bool
    func isRetired113(): Bool
}

public class AcpOwnedWorkerControl113 {
    private var paid: ?LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var retained: Int64 = 65536
    private var calls: Int64 = 0
    private var closing = false
    private var unsafeLegacyAliases113 = false
    private var frontend113: ?AcpFrontendCustody113 = None<AcpFrontendCustody113>
    private var unregisteredFrontend113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var atExitServer113: ?ProductAcpServer = None<ProductAcpServer>
    private var atExitFrames113: Int64 = 0
    private var metadata113: ?ArrayList<AcpOwnedMetadata113> = Some(ArrayList<AcpOwnedMetadata113>())
    private var unregisteredMetadata113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var metadataCollection113 = false
    private var rootRetired113 = false
    private var startupJournal113: ?AcpOwnedCloseJournal113 = None<AcpOwnedCloseJournal113>
    private var startupJournalPayment113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var startupFrame113: ?AcpOwnedResponse113 = None<AcpOwnedResponse113>
    private var startupUnregisteredFrame113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var unsafeFixtureScope113 = false
    private var unsafeFixtureBodyReturned113 = false
    private var unsafeFixtureTask113: ?Future<Unit> = None<Future<Unit>>
    private var unsafeFixtureRetiring113 = false
    private var unsafeFixtureTaskJoined113 = false
    private var unsafeFixtureServers113: ?ArrayList<ProductAcpServer> = Some(ArrayList<ProductAcpServer>())


    private let registryInvoices113 = Array<Int64>(6, repeat: 0)



    init(paid: LogicalJsonOwnerReservation) {
        paid.ensureRetainedPeak(65536)
        this.paid = Some(paid)
    }

    private func ensureRootTotalLocked113(): Unit {
        var total = retained
        for (bytes in registryInvoices113) { total = acpOwnedAdd113(total, bytes) }
        paid.getOrThrow().ensureRetainedPeak(total)
    }
    func ensureRegistryMetadata113(slot: Int64, bytes: Int64): Unit {
        lock.lock()
        try {
            if (slot < 0 || slot >= registryInvoices113.size || rootRetired113) {
                throw IllegalArgumentException("ACP registry invoice identity is invalid") }
            let wanted = max(registryInvoices113[slot], bytes)
            var total = retained
            for (index in 0..registryInvoices113.size) {
                total = acpOwnedAdd113(total, if (index == slot) { wanted } else { registryInvoices113[index] }) }
            paid.getOrThrow().ensureRetainedPeak(total); registryInvoices113[slot] = wanted
        } finally { lock.unlock() }
    }

    func prepareMetadata113(bytes: Int64): AcpOwnedMetadata113 {
        lock.lock()
        try {
            if (rootRetired113 || unregisteredMetadata113.isSome() || metadataCollection113) {
                throw IllegalStateException("ACP retains an unfinished metadata producer") }
            let capacity = acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedAdd113(metadata113.getOrThrow().size, 1), 4096))
            let wanted = max(registryInvoices113[0], capacity)
            var total = retained
            for (index in 0..registryInvoices113.size) { total = acpOwnedAdd113(total,
                if (index == 0) { wanted } else { registryInvoices113[index] }) }
            paid.getOrThrow().ensureRetainedPeak(total); registryInvoices113[0] = wanted
            let child = paid.getOrThrow().deriveRetainedLease()
            unregisteredMetadata113 = Some(child)
            child.ensureRetainedPeak(bytes)
            let actual = AcpOwnedMetadata113(child, bytes)
            metadata113.getOrThrow().add(actual); unregisteredMetadata113 = None<LogicalJsonOwnerReservation>
            actual
        } finally { lock.unlock() }
    }
    private func collectMetadataHelper113(): Bool {
        lock.lock()
        try {
            if (metadataCollection113 || unregisteredMetadata113.isSome()) { return false }
            metadataCollection113 = true
        } finally { lock.unlock() }
        try {
            var index: Int64 = 0
            while (true) {
                lock.lock()
                let actual = try { if (index >= metadata113.getOrThrow().size) { break }; metadata113.getOrThrow()[index] }
                    finally { lock.unlock() }
                if (actual.collectAfterGuardHelperReturn113()) {
                    lock.lock(); try { metadata113.getOrThrow().remove(at: index) } finally { lock.unlock() }
                } else { index++ }
            }
        } finally { lock.lock(); try { metadataCollection113 = false } finally { lock.unlock() } }
        lock.lock(); try { metadata113.getOrThrow().isEmpty() && unregisteredMetadata113.isNone() } finally { lock.unlock() }
    }
    public func collectMetadataAfterCallerReturn113(): Bool { collectMetadataHelper113() }
    // This capability belongs exclusively to explicit Support fixtures.
    // Main's owned path never enables it or admits legacy escaping strings.
    public func beginUnsafeFixtureUnitScope113(): Unit {
        lock.lock()
        try {
            if (unsafeFixtureScope113 || unsafeFixtureTask113.isSome() || calls != 0 ||
                atExitServer113.isSome() || frontend113.isSome()) {
                throw IllegalStateException("ACP Support scope already has a producer") }
            unsafeFixtureScope113 = true
        } finally { lock.unlock() }
    }
    public func observeUnsafeFixtureWholeBodyReturn113(): Unit {
        lock.lock()
        try {
            if (!unsafeFixtureScope113 || unsafeFixtureTask113.isSome() || calls != 0 ||
                atExitServer113.isSome() || frontend113.isSome()) {
                throw IllegalStateException("ACP Support has an actual live producer") }
            // Called only by the Support helper AFTER the whole original
            // synchronous Unit oracle body returned. This does not admit an
            // actual server worker: its registry still demands real tryGet.
            unsafeFixtureBodyReturned113 = true
        } finally { lock.unlock() }
    }
    func isUnsafeFixtureUnitScope113(): Bool { lock.lock(); try { unsafeFixtureScope113 } finally { lock.unlock() } }
    func isUnsafeFixtureRetiring113(): Bool { lock.lock(); try { unsafeFixtureRetiring113 } finally { lock.unlock() } }
    func registerUnsafeFixtureServer113(server: ProductAcpServer): Unit {
        lock.lock()
        try {
            if (!unsafeLegacyAliases113 || unsafeFixtureRetiring113) { throw IllegalStateException("ACP fixture registration is unavailable") }
            let wanted = max(registryInvoices113[5], acpOwnedAdd113(65536,
                acpOwnedMultiply113(acpOwnedAdd113(unsafeFixtureServers113.getOrThrow().size, 1), 4096)))
            var total = retained
            for (index in 0..registryInvoices113.size) { total = acpOwnedAdd113(total,
                if (index == 5) { wanted } else { registryInvoices113[index] }) }
            paid.getOrThrow().ensureRetainedPeak(total); registryInvoices113[5] = wanted
            unsafeFixtureServers113.getOrThrow().add(server)
        } finally { lock.unlock() }
    }
    // Only the Support driver's registered task identity is admitted here.
    // Production Main never calls any unsafe-fixture method.
    public func registerUnsafeFixtureTask113(task: Future<Unit>): Unit {
        lock.lock()
        try {
            if (!unsafeFixtureScope113 || unsafeFixtureTask113.isSome() || unsafeFixtureTaskJoined113 || unsafeFixtureRetiring113) {
                throw IllegalStateException("ACP fixture has an earlier actual task") }
            unsafeFixtureTask113 = Some(task)
        } finally { lock.unlock() }
    }
    private func observeUnsafeFixtureTaskHelper113(task: Future<Unit>): Bool {
        lock.lock()
        let actual = try { match (unsafeFixtureTask113) {
            case Some(value) => if (!refEq(value, task)) { return false }; value
            case None => return false } } finally { lock.unlock() }
        // Completed counter or callback return is not sufficient. The actual
        // Future<Unit> retrieval must really return, without an opaque error.
        actual.get(); true
    }
    public func clearUnsafeFixtureTaskAfterActualGet113(task: Future<Unit>): Bool {
        if (!observeUnsafeFixtureTaskHelper113(task)) { return false }
        lock.lock()
        try { unsafeFixtureTask113 = None<Future<Unit>>; unsafeFixtureTaskJoined113 = true; true }
        finally { lock.unlock() }
    }
    private func finalizeUnsafeFixtureServersHelper113(): Bool {
        lock.lock()
        let actual = try {
            if ((!unsafeFixtureBodyReturned113 && !unsafeFixtureTaskJoined113) || unsafeFixtureTask113.isSome() || calls != 0 ||
                atExitServer113.isSome() || atExitFrames113 != 0 || frontend113.isSome() || unregisteredFrontend113.isSome()) { return false }
            unsafeFixtureRetiring113 = true; unsafeFixtureServers113.getOrThrow()
        } finally { lock.unlock() }
        for (server in actual) { if (!server.finalizeUnsafeFixtureAfterActualTaskReturn113()) { return false } }
        lock.lock(); try { unsafeFixtureServers113 = None<ArrayList<ProductAcpServer>> } finally { lock.unlock() }
        true
    }
    public func detachUnsafeFixtureRootAfterTaskAndAliasReturn113(): ?LogicalJsonOwnerReservation {
        // The independently prepaid external Support driver retains this
        // empty carrier. It clears its controller reference only AFTER this
        // whole helper returns, then closes the detached original parent.
        if (!finalizeUnsafeFixtureServersHelper113() || !collectMetadataAfterCallerReturn113()) { return None<LogicalJsonOwnerReservation> }
        lock.lock()
        try {
            if (rootRetired113 || metadataCollection113 || unregisteredMetadata113.isSome() || !metadata113.getOrThrow().isEmpty()) { return None<LogicalJsonOwnerReservation> }
            let original = paid.getOrThrow()
            let (_, _, leases) = original.retainedCustodyUsage113()
            if (leases != 1) { return None<LogicalJsonOwnerReservation> }
            metadata113 = None<ArrayList<AcpOwnedMetadata113>>
            paid = None<LogicalJsonOwnerReservation>; rootRetired113 = true
            Some(original)
        } finally { lock.unlock() }
    }

    // Production atExit keeps this one small Root until actual process exit.
    // Standalone owners have no atExit alias: only their WHOLE server/input/
    // output helper return allows this final original Native close attempt.
    public func retireStandaloneAfterScopeReturn113(): Bool {
        if (!collectMetadataAfterCallerReturn113()) { return false }
        lock.lock()
        try {
            if (rootRetired113) { return true }
            if (unsafeLegacyAliases113 || calls != 0 || atExitServer113.isSome() || atExitFrames113 != 0 ||
                frontend113.isSome() || unregisteredFrontend113.isSome() || metadataCollection113) { return false }
            let (_, _, leases) = paid.getOrThrow().retainedCustodyUsage113()
            if (leases != 1) { return false }
            paid.getOrThrow().close(); paid = None<LogicalJsonOwnerReservation>; rootRetired113 = true; true
        } finally { lock.unlock() }
    }

    // Existing String/DOM/error aliases can escape the original String API.
    // These invoices remain at Root lifetime, rather than falsely refunding
    // them when handle() or an ordinary String emitter happens to return.
    func retainMetadata113(bytes: Int64): Unit {
        lock.lock()
        try {
            let wanted = acpOwnedAdd113(retained, bytes)
            let previous = retained
            retained = wanted
            try { ensureRootTotalLocked113() } catch (failure: Exception) { retained = previous; throw failure }
        } finally { lock.unlock() }
    }

    func retainInput113(source: String): Unit {
        holdUnsafeLegacyAliases113()
        retainMetadata113(acpOwnedInputInvoice113(source))
    }

    func deriveWorker113(retainedUtf8: Int64): LogicalJsonOwnerReservation {
        let child = paid.getOrThrow().deriveRetainedLease()
        try {
            child.ensureRetainedPeak(acpOwnedAdd113(65536, acpOwnedMultiply113(retainedUtf8, 8)))
            child
        }
        catch (error: Exception) { child.close(); throw error }
    }

    func deriveMetadata113(bytes: Int64): LogicalJsonOwnerReservation {
        let child = paid.getOrThrow().deriveRetainedLease()
        try { child.ensureRetainedPeak(bytes); child }
        catch (error: Exception) { child.close(); throw error }
    }
    // High-water of actual retained registry capacity, not a cumulative
    // invoice for every sequential production request.
    func ensureRootMetadata113(bytes: Int64): Unit {
        lock.lock()
        try {
            let previous = retained
            retained = max(retained, bytes)
            try { ensureRootTotalLocked113() } catch (failure: Exception) { retained = previous; throw failure }
        }
        finally { lock.unlock() }
    }
    func holdUnsafeLegacyAliases113(): Unit {
        lock.lock(); try { unsafeLegacyAliases113 = true } finally { lock.unlock() }
    }
    public func deriveFrontendMetadata113(bytes: Int64): LogicalJsonOwnerReservation { deriveMetadata113(bytes) }
    public func ensureFrontendRegistryMetadata113(bytes: Int64): Unit { ensureRootMetadata113(bytes) }
    func isUnsafeLegacyHeld113(): Bool { lock.lock(); try { unsafeLegacyAliases113 } finally { lock.unlock() } }
    public func prepareFrontendCustody113(): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (frontend113.isSome() || unregisteredFrontend113.isSome()) {
                throw IllegalStateException("ACP retains an earlier frontend") }
            let actual = paid.getOrThrow().deriveRetainedLease()
            unregisteredFrontend113 = Some(actual)
            actual.ensureRetainedPeak(65536)
            actual
        } finally { lock.unlock() }
    }
    public func installFrontendCustody113(value: AcpFrontendCustody113): Unit {
        lock.lock()
        try {
            if (frontend113.isSome() || unregisteredFrontend113.isNone()) {
                throw IllegalStateException("ACP frontend has no prepaid registration") }
            frontend113 = Some(value)
            unregisteredFrontend113 = None<LogicalJsonOwnerReservation>
        } finally { lock.unlock() }
    }
    public func collectFrontendAfterHelperReturn113(): Bool {
        let actual = try { lock.lock(); frontend113 } finally { lock.unlock() }
        match (actual) {
            case None => unregisteredFrontend113.isNone()
            case Some(value) =>
                if (!value.retireAfterFrontendHelperReturn113()) { return false }
                lock.lock(); try { frontend113 = None<AcpFrontendCustody113> } finally { lock.unlock() }
                true
        }
    }
    public func registerAtExitServer113(server: ProductAcpServer): Unit {
        lock.lock()
        try {
            if (atExitServer113.isSome()) { throw IllegalStateException("ACP retains an earlier frontend server") }
            atExitServer113 = Some(server)
        } finally { lock.unlock() }
    }
    public func closeRegisteredServerAtExit113(): Unit {
        lock.lock()
        let actual = try { atExitFrames113++; atExitServer113 } finally { lock.unlock() }
        try { match (actual) { case None => (); case Some(server) => let _ = server.closeOwned113() } }
        finally { lock.lock(); try { atExitFrames113-- } finally { lock.unlock() } }
    }
    public func clearAtExitServerAfterFrontendReturn113(server: ProductAcpServer): Bool {
        if (!server.canClearFrontendReference113()) { return false }
        lock.lock()
        try {
            if (atExitFrames113 != 0 || frontend113.isSome() || unregisteredFrontend113.isSome()) { return false }
            match (atExitServer113) {
                case Some(actual) => if (!refEq(actual, server)) { return false }
                case None => return true }
            atExitServer113 = None<ProductAcpServer>; true
        } finally { lock.unlock() }
    }


    func beginCollection113(): Unit {
        lock.lock()
        try { calls = acpOwnedAdd113(calls, 1) } finally { lock.unlock() }
    }

    func beginCall113(): Bool {
        lock.lock()
        try {
            if (closing) { return false }
            calls = acpOwnedAdd113(calls, 1)
            true
        } finally { lock.unlock() }
    }

    func endCall113(): Unit {
        lock.lock()
        try { calls-- } finally { lock.unlock() }
    }

    func beginShutdown113(): Bool {
        lock.lock()
        try { closing = true; calls == 0 } finally { lock.unlock() }
    }

    func hasConcurrentCalls113(): Bool {
        lock.lock()
        try { calls > 1 } finally { lock.unlock() }
    }

    public func writeProductStartupFailure113(error: AgentError,
        writer: (AcpOwnedResponse113)->OwnedFailureDataOutcome113<Unit>): Bool {
        lock.lock()
        try {
            if (startupJournal113.isSome() || startupJournalPayment113.isSome()) { return false }
            let child = paid.getOrThrow().deriveRetainedLease()
            startupJournalPayment113 = Some(child)
            child.ensureRetainedPeak(65536)
            startupJournal113 = Some(AcpOwnedCloseJournal113(this))
        } finally { lock.unlock() }
        let journal = startupJournal113.getOrThrow()
        // Complete original AgentError is captured while the failed Product
        // producer/caller is still on stack and the original bank is alive.
        journal.preparePrimary113(error)
        if (!journal.freezeAfterCloseHelperReturn113()) { return false }
        let framePayment = deriveMetadata113(65536)
        // Registered payment precedes constructing even this startup frame.
        startupUnregisteredFrame113 = Some(framePayment)
        let frame = AcpOwnedResponse113(framePayment)
        startupFrame113 = Some(frame); startupUnregisteredFrame113 = None<LogicalJsonOwnerReservation>
        journal.offerClose113(frame, writer)
    }
    public func retireStartupFailureAfterMainHelperReturn113(): Bool {
        // Original raw Product startup/catch/print frame must have returned.
        match (startupJournal113) {
            case None => return true
            case Some(actual) => if (!actual.retireAfterOutputAndCallerReturn113()) { return false } }
        startupJournal113 = None<AcpOwnedCloseJournal113>
        startupFrame113 = None<AcpOwnedResponse113>
        match (startupJournalPayment113) { case Some(child) => child.close(); startupJournalPayment113 = None<LogicalJsonOwnerReservation>; case None => () }
        true
    }

    public func observedOriginalCustody113(): (Int64, Int64, Int64) {
        lock.lock()
        try { match (paid) { case Some(actual) => actual.retainedCustodyUsage113(); case None => (0, 0, 0) } }
        finally { lock.unlock() }
    }

    public func finishRootStatus113(status: Int64): Int64 {
        // The atExit/subscription aliases have no unsubscribe witness. Keep
        // the real original-bank root alive; this is not a consumption ACK.
        lock.lock()
        try { if (calls != 0) { 1 } else { status } } finally { lock.unlock() }
    }
}

class AcpOwnedWorker113 {
    let paid: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var starting = true
    private var future: ?Future<Unit> = None<Future<Unit>>
    private var action113: ?(() -> Unit) = None<() -> Unit>
    private let failureProducer113: AcpOwnedCloseProducer113
    private let failureCode113: String
    private var actualJoinObserved113 = false

    init(paid: LogicalJsonOwnerReservation, producer: AcpOwnedCloseProducer113, code: String) {
        this.paid = paid; this.failureProducer113 = producer; this.failureCode113 = code }
    func producer113(): AcpOwnedCloseProducer113 { failureProducer113 }
    func hasActualJoinObserved113(): Bool { lock.lock(); try { actualJoinObserved113 } finally { lock.unlock() } }

    func start113(action: () -> Unit): Unit {
        lock.lock()
        try {
            // Both the action closure and this spawn closure are already paid
            // by the registered child. An unknown/throwing spawn keeps the
            // original entry and child; it cannot be called a returned worker.
            // The real original-bank child was registered/funded before
            // the caller allocated this action. Store it in the paid cell;
            // the scheduler captures only this cell, not its immutable text/
            // session action directly. Unknown spawn keeps the exact field.
            action113 = Some(action)
            future = Some(spawn { runActualActionAndCaptureHelper113() })
            starting = false
        } finally { lock.unlock() }
    }

    private func invokeRegisteredAction113(): Result<Unit> {
        action113.getOrThrow()(); Result<Unit>.Ok(())
    }
    private func runActualActionAndCaptureHelper113(): Unit {
        let _ = failureProducer113.run113({ => invokeRegisteredAction113() }, errorCode: failureCode113)
        // Complete action and capture helpers returned. This is not join;
        // an actual tryGet whole-return witness is separately mandatory.
        failureProducer113.observeReturned113()
    }
    private func observeActualFutureReturnHelper113(): Bool {
        let actual = match (future) { case Some(value) => value; case None => return false }
        try { actual.tryGet().isSome() } catch (_: Exception) { false }
    }

    func takeReturnedPayment113(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (starting) { return None<LogicalJsonOwnerReservation> }
            if (!observeActualFutureReturnHelper113()) { return None<LogicalJsonOwnerReservation> }
            // The complete tryGet helper and its local actual Future have
            // returned. Only now detach the action's real String/session/
            // closure aliases, then the registered Future reference. The
            // caller's whole detach helper returns before the child closes.
            action113 = None<() -> Unit>
            future = None<Future<Unit>>
            actualJoinObserved113 = true
            Some(paid)
        } finally { lock.unlock() }
    }
}

class AcpOwnedWorkerRegistry113 {
    private let control: AcpOwnedWorkerControl113
    private let closeJournal113: AcpOwnedCloseJournal113
    private let lock = Mutex()
    private var workers: ?ArrayList<AcpOwnedWorker113> = Some(ArrayList<AcpOwnedWorker113>())
    private var registryPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var unregisteredPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var closing = false
    private var emitFrames: Int64 = 0
    private var retiringPayment113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>

    init(control: AcpOwnedWorkerControl113, closeJournal113: AcpOwnedCloseJournal113) {
        this.control = control; this.closeJournal113 = closeJournal113 }

    func prepare113(retainedUtf8: Int64, failureCode!: String = "acp.prompt_failed"): AcpOwnedWorker113 {
        lock.lock()
        try {
            if (closing) { throw IllegalStateException("ACP worker admission is closed") }
            if (unregisteredPaid113.isSome()) {
                throw IllegalStateException("ACP keeps an unregistered paid producer")
            }
            if (registryPaid113.isNone()) { registryPaid113 = Some(control.deriveMetadata113(65536)) }
            registryPaid113.getOrThrow().ensureRetainedPeak(acpOwnedAdd113(65536,
                acpOwnedMultiply113(acpOwnedAdd113(workers.getOrThrow().size, 1), 4096)))
            let paid = control.deriveWorker113(retainedUtf8)
            // Pressure while constructing/registering a cell still leaves the
            // exact paid share reachable from the original session registry.
            unregisteredPaid113 = Some(paid)
            let producer = closeJournal113.prepareProducer113()
            let actual = AcpOwnedWorker113(paid, producer, failureCode)
            producer.setRetirementGuard113({ => actual.hasActualJoinObserved113() })
            // Store before the caller constructs or invokes its action closure.
            workers.getOrThrow().add(actual)
            unregisteredPaid113 = None<LogicalJsonOwnerReservation>
            actual
        } finally { lock.unlock() }
    }

    func blockAdmissions113(): Unit {
        lock.lock()
        try { closing = true } finally { lock.unlock() }
    }

    func beginEmit113(): Bool {
        lock.lock()
        try {
            if (closing) { return false }
            emitFrames = acpOwnedAdd113(emitFrames, 1)
            true
        } finally { lock.unlock() }
    }

    func endEmit113(): Unit {
        lock.lock()
        try { emitFrames-- } finally { lock.unlock() }
    }

    private func detachOneReturned113(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (retiringPayment113.isSome()) { return retiringPayment113 }
            if (workers.isNone()) { return None<LogicalJsonOwnerReservation> }
            for (index in 0..workers.getOrThrow().size) {
                match (workers.getOrThrow()[index].takeReturnedPayment113()) {
                    case Some(paid) => retiringPayment113 = Some(paid); workers.getOrThrow().remove(at: index); return Some(paid)
                    case None => ()
                }
            }
            None<LogicalJsonOwnerReservation>
        } finally { lock.unlock() }
    }

    func collectReturned113(): Bool {
        while (true) {
            // Both detach helpers and their local Future/worker references
            // have actually returned before closing the derived child.
            match (detachOneReturned113()) {
                case Some(paid) =>
                    closeReturnedPaymentHelper113(paid)
                    lock.lock(); try { retiringPayment113 = None<LogicalJsonOwnerReservation> } finally { lock.unlock() }
                case None => break
            }
        }
        lock.lock()
        try {
            if (workers.isNone()) { return closing && registryPaid113.isNone() }
            workers.getOrThrow().isEmpty() && emitFrames == 0 && unregisteredPaid113.isNone() && retiringPayment113.isNone()
        } finally { lock.unlock() }
    }
    private func detachRegistryAfterAllWorkersReturn113(): Bool {
        lock.lock()
        try {
            if (!closing || emitFrames != 0 || unregisteredPaid113.isSome() || retiringPayment113.isSome()) { return false }
            match (workers) { case Some(actual) => if (!actual.isEmpty()) { return false }; case None => () }
            workers = None<ArrayList<AcpOwnedWorker113>>; true
        } finally { lock.unlock() }
    }
    func retireRegistryAfterWorkersHelperReturn113(): Bool {
        if (!collectReturned113() || !detachRegistryAfterAllWorkersReturn113()) { return false }
        lock.lock()
        try {
            match (registryPaid113) { case Some(paid) => paid.close(); registryPaid113 = None<LogicalJsonOwnerReservation>; case None => () }
            true
        } finally { lock.unlock() }
    }
    private func closeReturnedPaymentHelper113(paid: LogicalJsonOwnerReservation): Unit { paid.close() }

}

func acpOwnedAdd113(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > Int64.Max - left) {
        throw IllegalArgumentException("ACP retained metadata invoice overflow")
    }
    left + right
}

func acpOwnedMultiply113(value: Int64, count: Int64): Int64 {
    if (value < 0 || count < 1 || value > Int64.Max / count) {
        throw IllegalArgumentException("ACP retained metadata invoice overflow")
    }
    value * count
}

func acpOwnedUtf8Bytes113(value: String): Int64 {
    unsafe { value.rawData().size }
}

func acpOwnedWorkersPending113<T>(): Result<T> {
    Result<T>.Err(AgentError(AgentErrorKind.RecoveryRequired,
        "acp.workers_pending", "ACP retains unfinished workers, callbacks or owned checkpoint data",
        retryable: false, fallbackAllowed: false))
}

func acpOwnedInputInvoice113(source: String): Int64 {
    // Borrow the UTF-8 storage; no toArray/stringify/parser allocation.
    let raw = unsafe { source.rawData() }
    var quoted = false
    var escaped = false
    var scalar = false
    var nodes: Int64 = 0
    for (index in 0..raw.size) {
        let byte = raw[index]
        if (quoted) {
        if (escaped) { escaped = false }
        else if (byte == b'\\') { escaped = true }
        else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') { quoted = true; scalar = false; nodes++ }
        else if (byte == b'{' || byte == b'[') { scalar = false; nodes++ }
        else if (byte == b',' || byte == b':' || byte == b'}' || byte == b']' ||
        byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n') { scalar = false }
        else if (!scalar) { scalar = true; nodes++ }
    }
    let strings = acpOwnedMultiply113(raw.size, 8)
    let decoded = acpOwnedAdd113(acpOwnedMultiply113(raw.size, 4),
        acpOwnedAdd113(acpOwnedMultiply113(nodes, 512), 1048576))
    acpOwnedAdd113(65536, max(strings, decoded))
}
