package agent_rpc

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_runtime.*
import agent_core.OwnedAgentRunResult113
import agent_product.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*

public type AcpProductFactory = (String) -> Result<ProductRuntime>
public type AcpProductCloser = (ProductRuntime) -> Result<Unit>
public type AcpApplicationFactory180 = (ProductRuntime, ?SessionId) -> ApplicationSession

// Standalone ACP owns its Product; an owner-backed ACP peer owns an actual
// DATA loan to the longliving Root instead. Both lifetimes have real close.
enum AcpProductScope180 {
    Standalone(AcpProductCloser) | RootLoan(LogicalJsonOwnerReservation)
    func close180(product: ProductRuntime): Result<Unit> {
        match (this) {
            case Standalone(closer) => closer(product)
            case RootLoan(paid) => paid.close(); Result.Ok(())
        }
    }
}

public class ProductAcpServer {
    private let host: ProductRuntime
    private let requestIdAllocator180: ?(() -> Int64)
    private let applicationFactory180: AcpApplicationFactory180
    private let sharedRootPayment180: ?LogicalJsonOwnerReservation
    private let factory: AcpProductFactory
    private let closer: AcpProductCloser
    private let hostOwner: AcpProductOwner
    private let emit: (String) -> Unit
    private let ownedResponseOutput113: ?AcpOwnedResponseOutput113
    private let responses113: AcpOwnedResponseRegistry113
    private let closeJournal113: AcpOwnedCloseJournal113
    private var ownedInput113: ?AcpOwnedInput113 = None<AcpOwnedInput113>
    private var closeFailedConsumed113 = false
    private var closeCollectionPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var constructingMetadata113: ?AcpOwnedMetadata113 = None<AcpOwnedMetadata113>
    private var deferredSnapshot113: ?ArrayList<AcpDeferredUpdate> = None<ArrayList<AcpDeferredUpdate>>
    private var deferredSnapshotPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var deferredWorking113 = false
    private var workerCollectionPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var workerCollectionSnapshot113: ?ArrayList<AcpSessionRecord> = None<ArrayList<AcpSessionRecord>>



    private let lock = Mutex()
    private let control113: AcpOwnedWorkerControl113
    private let ownedFailureOutput113: ?OwnedRpcFailureOutput113
    private var checkpointCollectionActive113 = false
    private var checkpointCollectionPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private let retiringRecords113 = ArrayList<AcpSessionRecord>()
    private var closeAttempt113 = false
    private let records = ArrayList<AcpSessionRecord>()
    private let deferred = ArrayList<AcpDeferredUpdate>()
    private var initialized = false
    private var closed = false
    private var closeError: ?AgentError = None
    private var requestCounter: Int64 = 0

    public init(
        host: ProductRuntime,
        factory: AcpProductFactory,
        emit: (String) -> Unit,
        closer!: AcpProductCloser = closeAcpProduct,
        control113!: AcpOwnedWorkerControl113 = newAcpOwnedWorkerControl113(),
        ownedFailureOutput113!: ?OwnedRpcFailureOutput113 = None<OwnedRpcFailureOutput113>,
        ownedResponseOutput113!: ?AcpOwnedResponseOutput113 = None<AcpOwnedResponseOutput113>,
        sharedRootPayment180!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>,
        applicationFactory180!: AcpApplicationFactory180 = { product, id => product.applicationSession(sessionId: id) },
        requestIdAllocator180!: ?(() -> Int64) = None<() -> Int64>
    ) {
        this.control113 = control113
        this.requestIdAllocator180 = requestIdAllocator180
        this.applicationFactory180 = applicationFactory180
        this.sharedRootPayment180 = sharedRootPayment180
        this.ownedResponseOutput113 = ownedResponseOutput113
        this.responses113 = AcpOwnedResponseRegistry113(control113)
        this.closeJournal113 = AcpOwnedCloseJournal113(control113)
        if (ownedResponseOutput113.isNone()) { control113.holdUnsafeLegacyAliases113() }
        this.ownedFailureOutput113 = ownedFailureOutput113
        this.host = host
        this.factory = factory
        this.emit = emit
        this.closer = closer
        let hostMetadata = control113.prepareMetadata113(65536)
        let scope = match (sharedRootPayment180) {
            case None => AcpProductScope180.Standalone(closer)
            case Some(root) => let paid = root.deriveRetainedLease()
                paid.ensureRetainedPeak(65536); AcpProductScope180.RootLoan(paid)
        }
        this.hostOwner = AcpProductOwner(host, scope, control113, closeJournal113, hostMetadata)
        hostMetadata.observeHelperReturned113()
        this.hostOwner.retain()
        if (ownedResponseOutput113.isNone()) { control113.registerUnsafeFixtureServer113(this) }
    }
    private func productScope180(): AcpProductScope180 {
        match (sharedRootPayment180) {
            case None => AcpProductScope180.Standalone(closer)
            case Some(root) =>
                let paid = root.deriveRetainedLease()
                paid.ensureRetainedPeak(65536)
                AcpProductScope180.RootLoan(paid)
        }
    }
    // Production accepts the actual paid source, and returns no escaping
    // String/DOM. Main retires that source only after this whole helper returns.
    public func handleOwnedInput113(input: AcpOwnedInput113): Result<Unit> {
        if (ownedResponseOutput113.isNone()) { return acpOwnedWorkersPending113<Unit>() }
        lock.lock()
        try {
            if (ownedInput113.isSome()) { return acpOwnedWorkersPending113<Unit>() }
            ownedInput113 = Some(input)
        } finally { lock.unlock() }
        if (!control113.beginCall113()) { return acpOwnedWorkersPending113<Unit>() }
        try {
            collectReturnedWorkers113()
            input.withLine113({ source, _ =>
                if (!input.prepareParser113()) { return acpOwnedWorkersPending113<Unit>() }
                handleOwnedInputHelper113(source)
            })
        } finally { control113.endCall113() }
    }
    public func afterOwnedInputHelperReturn113(input: AcpOwnedInput113): Bool {
        lock.lock()
        try {
            match (ownedInput113) { case None => return false; case Some(actual) =>
                if (!refEq(actual, input) || !input.isHandled113()) { return false } }
        } finally { lock.unlock() }
        closeJournal113.collectAfterInputHelperReturn113()
        clearConstructingAfterInputHelperReturn113()
        let _ = control113.collectMetadataAfterCallerReturn113()
        lock.lock(); try { ownedInput113 = None<AcpOwnedInput113> } finally { lock.unlock() }
        true
    }

    private func prepareSessionMetadata113(bytes: Int64): AcpOwnedMetadata113 {
        lock.lock()
        try {
            if (constructingMetadata113.isSome()) { throw IllegalStateException("ACP retains an unfinished session producer") }
            let actual = control113.prepareMetadata113(bytes)
            constructingMetadata113 = Some(actual); actual
        } finally { lock.unlock() }
    }
    private func clearConstructingAfterInputHelperReturn113(): Unit {
        lock.lock()
        try {
            match (constructingMetadata113) {
                case Some(actual) => actual.observeHelperReturned113(); actual.requestRetirement113()
                    constructingMetadata113 = None<AcpOwnedMetadata113>
                case None => () }
        } finally { lock.unlock() }
    }

    private func handleOwnedInputHelper113(source: String): Result<Unit> {
        let value = match (decodeAgentValue(source)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return sendAgentError113(nullValue(), error, wireCode: Some(-32700)) }
        if (value.unifiedKind != ValueKind.Object) { return sendError113(nullValue(), -32600, "Invalid Request") }
        let method = acpText(value, "method")
        if (method == "") { handleClientResponse(value); return Result<Unit>.Ok(()) }
        let id = match (value.field("id")) { case Some(item) => item; case None => nullValue() }
        let params = match (value.field("params")) { case Some(item) => item; case None => objectValue([]) }
        let notification = value.field("id").isNone()
        let dispatched = if (method == "session/prompt") { acpWithField(params, "_acpRequestId", id) } else { params }
        let result = dispatch(method, dispatched)
        if (notification) { return Result<Unit>.Ok(()) }
        match (result) {
            case Result.Ok(payload) =>
                if (acpBool(payload, "_deferred", false)) { Result<Unit>.Ok(()) } else { sendResult113(id, payload) }
            case Result.Err(error) =>
                if (holdOwnedCheckpointMarker113(error, id)) { Result<Unit>.Ok(()) } else { sendAgentError113(id, error) }
        }
    }
    private func sendResult113(id: AgentValue, result: AgentValue): Result<Unit> {
        match (ownedResponseOutput113) {
            case None => emit(acpResult(id, result)); Result<Unit>.Ok(())
            case Some(output) =>
                let frame = responses113.prepare113()
                if (!frame.buildValue113({ _ => objectValue([ValueField("jsonrpc", textValue("2.0")),
                    ValueField("id", id), ValueField("result", result)]) })) { return acpOwnedWorkersPending113<Unit>() }
                if (responses113.offer113(frame, output)) { Result<Unit>.Ok(()) } else { acpOwnedWorkersPending113<Unit>() }
        }
    }
    private func sendError113(id: AgentValue, code: Int64, message: String): Result<Unit> {
        match (ownedResponseOutput113) {
            case None => emit(acpError(id, code, message)); Result<Unit>.Ok(())
            case Some(output) =>
                let frame = responses113.prepare113()
                if (!frame.buildValue113({ _ => objectValue([ValueField("jsonrpc", textValue("2.0")), ValueField("id", id),
                    ValueField("error", objectValue([ValueField("code", integerValue(code)), ValueField("message", textValue(message))]))]) })) {
                    return acpOwnedWorkersPending113<Unit>() }
                if (responses113.offer113(frame, output)) { Result<Unit>.Ok(()) } else { acpOwnedWorkersPending113<Unit>() }
        }
    }
    private func sendAgentError113(id: AgentValue, error: AgentError, wireCode!: ?Int64 = None<Int64>): Result<Unit> {
        match (ownedResponseOutput113) {
            case None => emit(acpAgentError(id, error)); Result<Unit>.Ok(())
            case Some(output) =>
                let frame = responses113.prepare113()
                let rendered = closeJournal113.prepareCurrentResponseReceipt113()
                if (!frame.buildAgentError113(id, error, wireCode: wireCode, closeData: Some({ fund => closeJournal113.renderCurrentSecondary113(fund, rendered) }))) { return acpOwnedWorkersPending113<Unit>() }
                if (responses113.offer113(frame, output)) { closeJournal113.noteCurrentResponseWritten113(rendered); Result<Unit>.Ok(()) } else { acpOwnedWorkersPending113<Unit>() }
        }
    }
    private func sendWorkerAgentError113(id: AgentValue, error: AgentError,
        producer: AcpOwnedCloseProducer113): Result<Unit> {
        match (ownedResponseOutput113) {
            case None => emit(acpAgentError(id, error)); Result<Unit>.Ok(())
            case Some(output) =>
                let frame = responses113.prepare113()
                let rendered = closeJournal113.prepareCurrentResponseReceipt113(primary: Some(producer))
                if (!frame.buildAgentError113(id, error,
                    closeData: Some({ fund => closeJournal113.renderCurrentSecondary113(fund, rendered, excluding: Some(producer)) }))) {
                    return acpOwnedWorkersPending113<Unit>() }
                if (responses113.offer113(frame, output)) { closeJournal113.noteCurrentResponseWritten113(rendered); Result<Unit>.Ok(()) }
                else { acpOwnedWorkersPending113<Unit>() }
        }
    }

    private func sendValue113(value: AgentValue): Unit {
        match (ownedResponseOutput113) {
            case None => emit(encodeAgentValue(value))
            case Some(output) =>
                let frame = responses113.prepare113()
                if (frame.buildValue113({ _ => value })) { let _ = responses113.offer113(frame, output) }
        }
    }

    // Called only after Main's complete frontend body returned. A cached
    // raw close error or unpaid/unknown output keeps the original server.
    // Explicit Support-only teardown. Its caller must hold an independently
    // prepaid driver and observe the registered Unit task's whole get return;
    // arbitrary production bare String aliases are not made refundable.
    func finalizeUnsafeFixtureAfterActualTaskReturn113(): Bool {
        if (!control113.isUnsafeFixtureRetiring113() || !responses113.collectUnpublished113()) { return false }
        lock.lock()
        try {
            if (!closed || closeAttempt113 || ownedInput113.isSome() || !records.isEmpty() || !retiringRecords113.isEmpty()) { return false }
            closeError = None<AgentError>
        } finally { lock.unlock() }
        if (!closeJournal113.finalizeUnsafeAfterWholeTaskReturn113()) { return false }
        retireDeferredAfterHelperReturn113(); retireWorkerCollectionAfterFrontendReturn113()
        control113.collectMetadataAfterCallerReturn113()
    }

    public func canClearFrontendReference113(): Bool {
        if (!responses113.collectUnpublished113()) { return false }
        lock.lock()
        try { closed && closeError.isNone() && records.isEmpty() && retiringRecords113.isEmpty() && deferred.isEmpty() }
        finally { lock.unlock() }
    }

    public func handle(source: String): String {
        if (!control113.beginCall113()) {
            return acpError(nullValue(), -32000, "ACP server is closing")
        }
        try {
            control113.retainInput113(source)
            collectReturnedWorkers113()
            handlePaidInput113(source)
        } finally { control113.endCall113() }
    }

    private func handlePaidInput113(source: String): String {
        let value = match (decodeAgentValue(source)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return acpError(nullValue(), -32700, error.message)
        }
        if (value.unifiedKind != ValueKind.Object) {
            return acpError(nullValue(), -32600, "Invalid Request")
        }
        let method = acpText(value, "method")
        if (method == "") {
            handleClientResponse(value)
            return ""
        }
        let id = match (value.field("id")) {
            case Some(item) => item
            case None => nullValue()
        }
        let params = match (value.field("params")) {
            case Some(item) => item
            case None => objectValue([])
        }
        let notification = value.field("id").isNone()
        let dispatchedParams = if (method == "session/prompt") {
            acpWithField(params, "_acpRequestId", id)
        } else {
            params
        }
        let result = dispatch(method, dispatchedParams)
        if (notification) {
            return ""
        }
        match (result) {
            case Result.Ok(payload) =>
                if (acpBool(payload, "_deferred", false)) {
                    ""
                } else {
                    acpResult(id, payload)
                }
            case Result.Err(error) =>
                if (holdOwnedCheckpointMarker113(error, id)) { "" } else { acpAgentError(id, error) }
        }
    }

    // Own every ProductRuntime opened for ACP until its final session record
    // is gone. Repeated shutdown returns the original typed result without
    // closing the Product again.
    // Explicit unsafe fixture/convenience API: escaped raw Result aliases
    // keep their original bank until the WHOLE owning fixture scope returns.
    public func close(): Result<Unit> { control113.holdUnsafeLegacyAliases113(); closePaidCompatibilityHelper113() }
    public func closeOwned113(): AcpOwnedCloseStatus113 {
        if (closeJournal113.isConsumed113()) {
            return if (closeFailedConsumed113) { AcpOwnedCloseStatus113.FailedConsumed } else { AcpOwnedCloseStatus113.Complete } }
        let result = closePaidCompatibilityHelper113()
        lock.lock(); let complete = try { closed } finally { lock.unlock() }
        if (!complete || !closeJournal113.freezeAfterCloseHelperReturn113()) { return AcpOwnedCloseStatus113.Held }
        match (result) {
            case Result.Ok(_) => AcpOwnedCloseStatus113.Complete
            case Result.Err(_) => AcpOwnedCloseStatus113.Failed }
    }
    public func retainFrontendFailure113(error: AgentError): Unit { closeJournal113.captureFrontendFailure113(error) }
    public func retainFrontendFailure113(error: Exception): Unit { closeJournal113.captureFrontendFailure113(error) }
    public func retainFrontendFailure113(error: OwnedFailureDataConsumer113): Unit { closeJournal113.captureFrontendFailure113(error) }
    public func writeFrontendFailure113(writer: (AcpOwnedResponse113)->OwnedFailureDataOutcome113<Unit>): Bool {
        closeJournal113.offerFrontendFailure113(responses113.prepare113(), writer)
    }

    public func writeOwnedClose113(writer: (AcpOwnedResponse113)->OwnedFailureDataOutcome113<Unit>): Bool {
        closeJournal113.offerClose113(responses113.prepare113(), writer)
    }
    public func detachFailedInputAfterClosedFrontendReturn113(): Bool {
        // Called only after the WHOLE frontend body physically returned.
        // This is failed-session input destruction, never request/Tool ACK.
        if (!closeJournal113.canRetireAfterCallerReturn113() || !responses113.collectUnpublished113()) { return false }
        lock.lock()
        try {
            if (!closed || closeAttempt113 || !records.isEmpty() || !retiringRecords113.isEmpty()) { return false }
            match (ownedInput113) { case Some(actual) => if (!actual.canDestroyAfterFailedFrontendReturn113()) { return false }; case None => () }
            ownedInput113 = None<AcpOwnedInput113>; true
        } finally { lock.unlock() }
    }

    private func detachWorkerCollectionAfterFrontendReturn113(): Unit {
        lock.lock(); try { workerCollectionSnapshot113 = None<ArrayList<AcpSessionRecord>> } finally { lock.unlock() }
    }
    private func retireWorkerCollectionAfterFrontendReturn113(): Unit {
        detachWorkerCollectionAfterFrontendReturn113()
        match (workerCollectionPaid113) { case Some(paid) => paid.close(); workerCollectionPaid113 = None<LogicalJsonOwnerReservation>; case None => () }
    }

    public func retireOwnedCloseAfterFrontendHelperReturn113(): Bool {
        if (control113.isUnsafeLegacyHeld113() || !closeJournal113.canRetireAfterCallerReturn113()) { return false }
        lock.lock()
        try {
            if (!closed || ownedInput113.isSome() || closeAttempt113) { return false }
            closeFailedConsumed113 = closeJournal113.hasPrimary113()
            // Raw close/body/print helpers are no longer on stack. Owned
            // output has real write+flush/ACK, so these exact caches may clear.
            closeError = None<AgentError>
        } finally { lock.unlock() }
        hostOwner.clearCompatibilityCacheAfterCallerReturn113()
        retireDeferredAfterHelperReturn113()
        retireWorkerCollectionAfterFrontendReturn113()
        if (!closeJournal113.retireAfterOutputAndCallerReturn113()) { return false }
        control113.collectMetadataAfterCallerReturn113()
    }

    private func closePaidCompatibilityHelper113(): Result<Unit> {
        if (!collectOwnedCheckpointFailures113()) { return acpOwnedWorkersPending113<Unit>() }
        if (!responses113.collectUnpublished113()) { return acpOwnedWorkersPending113<Unit>() }
        if (!control113.beginShutdown113()) { return acpOwnedWorkersPending113<Unit>() }
        lock.lock()
        let attemptPaid = try {
            if (closed) {
                if (closeFailedConsumed113) { return Result<Unit>.Err(AgentError(AgentErrorKind.Internal,
                    "acp.server_shutdown_failed", "ACP server shutdown failed; its owned error data was consumed")) }
                return match (closeError) {
                    case Some(error) => Result.Err(error)
                    case None => Result.Ok(())
                }
            }
            if (closeAttempt113) { return acpOwnedWorkersPending113<Unit>() }
            // Each concurrent attempt prepays its own actual snapshot before
            // any array/cell allocation. The invoice stays at Root lifetime.
            let exactPaid = control113.deriveMetadata113(acpOwnedAdd113(32768,
                acpOwnedMultiply113(acpOwnedAdd113(records.size, retiringRecords113.size), 4096)))
            closeCollectionPaid113 = Some(exactPaid)
            closeAttempt113 = true
            exactPaid
        } finally { lock.unlock() }
        // A thrown/unknown producer keeps this exact registered lease and
        // gate. Only a whole returned snapshot/aggregate helper reaches cleanup.
        let result = closeRetainedRecords113(attemptPaid)
        lock.lock()
        try {
            if (!closeAttempt113 || closeCollectionPaid113.isNone() ||
                !refEq(closeCollectionPaid113.getOrThrow(), attemptPaid)) {
                throw IllegalStateException("ACP close attempt lost its exact payment identity")
            }
            // Keep the gate through actual close and reference clear. A second
            // closer can never replace or refund this attempt snapshot lease.
            attemptPaid.close()
            closeCollectionPaid113 = None<LogicalJsonOwnerReservation>
            closeAttempt113 = false
        } finally { lock.unlock() }
        result
    }

    private func closeRetainedRecords113(attemptPaid: LogicalJsonOwnerReservation): Result<Unit> {
        lock.lock()
        let pending = try {
            attemptPaid.ensureRetainedPeak(acpOwnedAdd113(32768,
                acpOwnedMultiply113(acpOwnedAdd113(records.size, retiringRecords113.size), 4096)))
            let actual = ArrayList<AcpSessionRecord>()
            for (record in records) { actual.add(record) }
            for (record in retiringRecords113) { actual.add(record) }
            actual
        } finally { lock.unlock() }
        let failures = ArrayList<AgentError>()
        for (record in pending) {
            let result = record.close()
            if (!record.isReleased113()) { return acpOwnedWorkersPending113<Unit>() }
            match (result) {
                case Result.Ok(_) => ()
                case Result.Err(error) => failures.add(error)
            }
        }
        match (hostOwner.release()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => failures.add(error)
        }
        let aggregate = closeJournal113.prepareProducer113()
        let result = aggregate.run113({ => acpAggregateFailures(
            "acp.server_shutdown_failed",
            "ACP server shutdown failed",
            failures
        ) })
        aggregate.observeReturned113()
        if (result.isError()) { closeJournal113.installPrimary113(aggregate) }
        lock.lock()
        try {
            // The actual Future/emit helpers returned before every owner
            // release; only now can the registered source records be removed.
            for (item in deferred) { item.metadata113.requestRetirement113() }
            match (deferredSnapshot113) {
                case Some(actual) =>
                    for (item in actual) { item.metadata113.requestRetirement113() }
                    actual.clear(); deferredSnapshot113 = None<ArrayList<AcpDeferredUpdate>>
                case None => () }
            deferredWorking113 = false
            records.clear()
            retiringRecords113.clear()
            deferred.clear()
            closed = true
            match (result) {
                case Result.Err(error) => closeError = Some(error)
                case Result.Ok(_) => ()
            }
        } finally { lock.unlock() }
        result
    }
    public func flushDeferred(): Unit {
        if (!control113.beginCall113()) { return }
        try { flushPaidDeferred113(); retireDeferredAfterHelperReturn113() }
        finally { control113.endCall113() }
    }

    private func flushPaidDeferred113(): Unit {
        lock.lock()
        let pending = try {
            if (deferredWorking113 || deferredSnapshot113.isSome()) {
                throw IllegalStateException("ACP keeps an unfinished deferred producer") }
            let paid = control113.deriveMetadata113(acpOwnedAdd113(32768, acpOwnedMultiply113(deferred.size, 4096)))
            deferredSnapshotPaid113 = Some(paid)
            let actual = ArrayList<AcpDeferredUpdate>()
            for (item in deferred) { actual.add(item) }
            deferredSnapshot113 = Some(actual); deferredWorking113 = true
            deferred.clear(); actual
        } finally { lock.unlock() }
        for (item in pending) {
            if (item.record.closed) { continue }
            if (item.replay) { replayHistory(item.record) }
            emitBootstrap(item.record)
        }
        lock.lock(); try { deferredWorking113 = false } finally { lock.unlock() }
    }
    private func retireDeferredAfterHelperReturn113(): Unit {
        lock.lock()
        try {
            if (deferredWorking113) { return }
            match (deferredSnapshot113) {
                case Some(actual) =>
                    for (item in actual) { item.metadata113.requestRetirement113() }
                    actual.clear(); deferredSnapshot113 = None<ArrayList<AcpDeferredUpdate>>
                case None => () }
            match (deferredSnapshotPaid113) {
                case Some(paid) => paid.close(); deferredSnapshotPaid113 = None<LogicalJsonOwnerReservation>
                case None => () }
        } finally { lock.unlock() }
        let _ = control113.collectMetadataAfterCallerReturn113()
    }

    private func dispatch(
        method: String,
        params: AgentValue
    ): Result<AgentValue> {
        if (isClosed()) {
            return acpFailure(
                AgentErrorKind.Conflict,
                "acp.server_closed",
                "ACP server is closed"
            )
        }
        if (method != "initialize" && !isInitialized()) {
            return acpFailure(
                AgentErrorKind.Conflict,
                "acp.not_initialized",
                "initialize must be called before other ACP methods"
            )
        }
        match (method) {
            case "initialize" => initialize()
            case "authenticate" => authenticate(params)
            case "session/new" => newSession(params)
            case "session/load" => loadSession(params, true)
            case "session/list" => listSessions(params)
            case "session/resume" => loadSession(params, false)
            case "session/fork" => forkSession(params)
            case "session/close" => closeSession(params)
            case "session/set_mode" => setMode(params)
            case "session/set_config_option" => setConfigOption(params)
            case "session/prompt" => prompt(params)
            case "session/cancel" => cancel(params)
            case _ => acpFailure(
                AgentErrorKind.RecoveryRequired,
                "acp.method_not_found",
                "Method not found: " + method
            )
        }
    }

    // The authenticated native ACP coordinator already consumed the real
    // initialize response on its first Owner. A newly selected workspace
    // connection installs that same protocol state, without manufacturing a
    // duplicate response or acknowledging any unpublished output.
    public func initializeOwnerConnection180(): Unit { let _ = initialize() }

    private func initialize(): Result<AgentValue> {
        lock.lock()
        try {
            initialized = true
        } finally {
            lock.unlock()
        }
        Result.Ok(
            objectValue(
                [
                    ValueField("protocolVersion", integerValue(1)),
                    ValueField(
                        "agentInfo",
                        objectValue(
                            [
                                ValueField("name", textValue("axyndra")),
                                ValueField("title", textValue("Axyndra")),
                                ValueField("version", textValue("17.2.3"))
                            ]
                        )
                    ),
                    ValueField(
                        "authMethods",
                        listValue(
                            [
                                objectValue(
                                    [
                                        ValueField("id", textValue("agent")),
                                        ValueField(
                                            "name",
                                            textValue("Use existing local credentials")
                                        ),
                                        ValueField(
                                            "description",
                                            textValue(
                                                "Authenticate with provider credentials " +
                                                    "already configured under ~/.Axyndra.")
                                        )
                                    ]
                                )
                            ]
                        )
                    ),
                    ValueField(
                        "agentCapabilities",
                        objectValue(
                            [
                                ValueField("loadSession", boolValue(true)),
                                ValueField(
                                    "promptCapabilities",
                                    objectValue(
                                        [
                                            ValueField("embeddedContext", boolValue(true)),
                                            ValueField("image", boolValue(false)),
                                            ValueField("audio", boolValue(false))
                                        ]
                                    )
                                ),
                                ValueField(
                                    "sessionCapabilities",
                                    objectValue(
                                        [
                                            ValueField("list", objectValue([])),
                                            ValueField("fork", objectValue([])),
                                            ValueField("resume", objectValue([])),
                                            ValueField("close", objectValue([]))
                                        ]
                                    )
                                )
                            ]
                        )
                    )
                ]
            )
        )
    }

    private func authenticate(params: AgentValue): Result<AgentValue> {
        if (acpText(params, "methodId") != "agent") {
            return acpInvalid("Unknown ACP auth method")
        }
        Result.Ok(objectValue([]))
    }

    private func newSession(params: AgentValue): Result<AgentValue> {
        let authoredCwd = acpText(params, "cwd")
        match (validateSessionCwd(authoredCwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let metadata = prepareSessionMetadata113(acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedUtf8Bytes113(authoredCwd), 8)))
        let product = match (factory(authoredCwd)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        let owner = AcpProductOwner(product, productScope180(), control113, closeJournal113, metadata)
        let session = applicationFactory180(product, None<SessionId>)
        match (product.replaceMessages(session.id(), [])) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = product.removeConversation(session.id())
                let closeResult = owner.closeUnretained()
                return acpOperationAndCloseFailure(error, closeResult)
        }
        match (product.setSessionWorkspace(
            session.id(),
            cwd: product.workspace.rootPath()
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = product.removeConversation(session.id())
                let closeResult = owner.closeUnretained()
                return acpOperationAndCloseFailure(error, closeResult)
        }
        let record = AcpSessionRecord(
            owner,
            session,
            product.workspace.rootPath(),
            control113, metadata
        )
        match (addRecord(record)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        deferBootstrap(record, false)
        Result.Ok(sessionSetupValue(record, true))
    }

    private func loadSession(
        params: AgentValue,
        replay: Bool
    ): Result<AgentValue> {
        let cwd = acpText(params, "cwd")
        let sessionId = acpText(params, "sessionId")
        match (validateSessionCwd(cwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (sessionId == "") {
            return acpInvalid("sessionId is required")
        }
        let record = match (findOrLoad(sessionId, cwd)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        match (record.session.resumeStartup()) {
            case Result.Ok(Some(response)) => match (response.approval) {
                case Some(approval) => requestPermission(record, approval)
                case None => ()
            }
            case Result.Ok(None) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        deferBootstrap(record, replay)
        Result.Ok(sessionSetupValue(record, false))
    }

    private func listSessions(params: AgentValue): Result<AgentValue> {
        let authoredCwd = acpText(params, "cwd")
        if (authoredCwd != "" && !isAbsolutePath(authoredCwd)) {
            return acpInvalid("cwd must be an absolute path")
        }
        let cwd = if (authoredCwd == "") {
            ""
        } else {
            match (canonicalAcpCwd(authoredCwd)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let offset = match (parseCursor(acpText(params, "cursor"))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let sessions = match (host.sessions()) {
            case Result.Ok(items) => items
            case Result.Err(error) => return Result.Err(error)
        }
        let allValues = ArrayList<AgentValue>()
        for (sessionId in sessions) {
                let workspace = match (host.sessionWorkspaceRoot(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let sessionCwd = match (host.sessionCwd(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (cwd != "" && sessionCwd != cwd) { continue }
                let title = match (host.sessionName(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => ""
                }
                let fields = ArrayList<ValueField>()
                fields.add(
                    ValueField(
                        "sessionId",
                        textValue(sessionId.value)
                    )
                )
                fields.add(
                    ValueField(
                        "cwd",
                        textValue(sessionCwd)
                    )
                )
                fields.add(ValueField("workspace", textValue(workspace)))
                if (title != "") {
                    fields.add(ValueField("title", textValue(title)))
                }
                allValues.add(objectValue(fields.toArray()))
        }
        let values = ArrayList<AgentValue>()
        let limit: Int64 = 50
        let end = minAcp(allValues.size, offset + limit)
        if (offset < allValues.size) {
            for (index in offset..end) { values.add(allValues[index]) }
        }
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("sessions", listValue(values.toArray())))
        if (end < allValues.size) {
            fields.add(
                ValueField(
                    "nextCursor",
                    textValue(end.toString())
                )
            )
        }
        Result.Ok(objectValue(fields.toArray()))
    }

    private func forkSession(params: AgentValue): Result<AgentValue> {
        let cwd = acpText(params, "cwd")
        let sourceId = acpText(params, "sessionId")
        match (validateSessionCwd(cwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let source = match (findOrLoad(sourceId, cwd)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let metadata = prepareSessionMetadata113(acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedUtf8Bytes113(source.cwd), 8)))
        let target = source.product.ids.nextSessionId()
        match (source.product.forkSession(source.session.id(), target)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (source.product.setSessionModel(target, source.session.model())) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (source.product.setSessionWorkspace(target, cwd: source.cwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let record = AcpSessionRecord(
            source.owner,
            applicationFactory180(source.product, Some(target)),
            source.cwd,
            control113, metadata
        )
        match (addRecord(record)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        deferBootstrap(record, false)
        Result.Ok(sessionSetupValue(record, true))
    }

    private func closeSession(params: AgentValue): Result<AgentValue> {
        let sessionId = acpText(params, "sessionId")
        var target: ?AcpSessionRecord = None
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < records.size) {
                if (records[index].session.id().value == sessionId) {
                    target = Some(records[index])
                    break
                }
                index += 1
            }
        } finally {
            lock.unlock()
        }
        match (target) {
            case Some(record) =>
                let result = record.close()
                if (record.isReleased113()) { removeReleasedRecord113(record) }
                match (result) {
                case Result.Ok(_) => Result.Ok(objectValue([]))
                case Result.Err(error) => Result.Err(error)
            }
            case None => Result.Ok(objectValue([]))
        }
    }

    private func setMode(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let mode = acpText(params, "modeId")
        if (mode != "agent") {
            return acpInvalid("unknown session mode: " + mode)
        }
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField("sessionUpdate", textValue("current_mode_update")),
                    ValueField("currentModeId", textValue("agent"))
                ]
            )
        )
        Result.Ok(objectValue([]))
    }

    private func setConfigOption(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let id = acpText(params, "configId")
        let value = acpText(params, "value")
        if (id == "model") {
            match (record.session.selectModel(value)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        } else if (id == "thinking") {
            let thinking = match (acpThinking(value)) {
                case Some(item) => item
                case None => return acpInvalid("unknown thinking level: " + value)
            }
            record.session.setThinking(thinking)
        } else if (id == "mode") {
            if (value != "agent") {
                return acpInvalid("unknown session mode: " + value)
            }
        } else {
            return acpInvalid("unknown ACP config option: " + id)
        }
        let options = configOptions(record.session)
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField("sessionUpdate", textValue("config_option_update")),
                    ValueField("configOptions", options)
                ]
            )
        )
        Result.Ok(objectValue([ValueField("configOptions", options)]))
    }

    private func prompt(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let text = match (promptText(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let id = match (params.field("_acpRequestId")) {
            case Some(value) => value
            case None => nullValue()
        }
        record.turnLock.lock()
        var generation: Int64 = 0
        var worker113: ?AcpOwnedWorker113 = None<AcpOwnedWorker113>
        try {
            if (record.running || record.pendingPromptId.isSome() || record.activeWorkers > 0) {
                return acpFailure(AgentErrorKind.Conflict, "acp.session_busy",
                    "session is already processing a prompt")
            }
            worker113 = Some(record.workers113.prepare113(acpOwnedUtf8Bytes113(text)))
            record.installWorkerProducer113(worker113.getOrThrow())
            record.generation += 1
            generation = record.generation
            record.running = true
            record.activeWorkers += 1
            record.pendingPromptId = Some(record.copyPromptIdentity113(id))
        } finally { record.turnLock.unlock() }
        let turn = generation
        worker113.getOrThrow().start113({ => runPrompt(record, text, turn) })
        Result.Ok(acpDeferredValue())
    }

    private func cancel(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        record.turnLock.lock()
        try {
            match (record.session.cancel()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
            record.generation += 1
            record.permissionRequestId = -1
            record.operationId = ""
            if (record.pendingPromptId.isSome()) {
                if (record.activeWorkers > 0 || record.cancelledPromptGeneration113.isSome() ||
                    record.hasRetainedCheckpoint113()) {
                    // This original pending id already has its independent
                    // metadata/payment. Keep it until the REAL worker returns;
                    // repeated cancel cannot replace the first generation.
                    if (record.cancelledPromptGeneration113.isNone()) {
                        record.cancelledPromptGeneration113 = Some(record.generation - 1)
                        record.cancelledPromptOffered113 = false
                    }
                } else {
                    let id = takePromptId(record)
                    let _ = sendResult113(id, objectValue([ValueField("stopReason", textValue("cancelled"))]))
                }
            }
            record.running = false
            Result.Ok(objectValue([]))
        } finally { record.turnLock.unlock() }
    }

    private func runPrompt(record: AcpSessionRecord, text: String, generation: Int64): Unit {
        record.turnLock.lock()
        let active = record.generation == generation
        record.turnLock.unlock()
        let result = if (active) { record.session.handle(text) } else {
                Result<ApplicationResponse>.Err(AgentError(AgentErrorKind.Cancelled,
                    "acp.prompt_cancelled", "prompt was cancelled"))
            }
        finishTurn(record, result, generation)
    }

    private func finishTurn(
        record: AcpSessionRecord,
        result: Result<ApplicationResponse>,
        generation: Int64
    ): Unit {
        record.turnLock.lock()
        try {
        record.activeWorkers -= 1
        match (result) {
            case Result.Err(error) => let _ = record.holdCheckpoint113(error, record.pendingPromptId)
            case Result.Ok(_) => ()
        }
        if (record.closed || record.generation != generation) {
            let _ = record.session.cancel()
            return
        }
        if (record.pendingPromptId.isNone()) { return }
        match (result) {
            case Result.Err(error) =>
                if (record.holdCheckpoint113(error, record.pendingPromptId)) { return }
                let id = takePromptId(record)
                if (error.kind == AgentErrorKind.Cancelled) {
                    let _ = sendResult113(id, objectValue([ValueField("stopReason", textValue("cancelled"))]))
                } else {
                    let _ = sendAgentError113(id, error)
                }
            case Result.Ok(response) => match (response.approval) {
                case Some(approval) => requestPermission(record, approval)
                case None =>
                    let id = takePromptId(record)
                    let _ = sendResult113(
                            id,
                            objectValue(
                                [
                                    ValueField(
                                        "stopReason",
                                        textValue("end_turn")
                                    )
                                ]
                            )
                        )
            }
        }
            } finally { record.turnLock.unlock() }
    }
    private func requestPermission(record: AcpSessionRecord, approval: ApprovalRequest): Unit {
        if (!record.workers113.beginEmit113()) { return }
        try { requestPermissionBody113(record, approval) }
        finally { record.workers113.endEmit113() }
    }

    private func requestPermissionBody113(
        record: AcpSessionRecord,
        approval: ApprovalRequest
    ): Unit {
        record.metadata113.ensure113(acpOwnedAdd113(131072,
            acpOwnedMultiply113(acpOwnedAdd113(acpOwnedUtf8Bytes113(approval.operationId.value),
                acpOwnedAdd113(acpOwnedUtf8Bytes113(approval.callId), acpOwnedUtf8Bytes113(approval.toolName))), 8)))
        let requestId = nextRequestId()
        record.permissionRequestId = requestId
        record.operationId = approval.operationId.value
        record.allowSession = approval.sessionApprovalAllowed
        let options = ArrayList<AgentValue>()
        options.add(permissionOption("allow_once", "Allow once", "allow_once"))
        if (approval.sessionApprovalAllowed) {
            options.add(permissionOption(
                "allow_session",
                "Allow for this session",
                "allow_always"
            ))
        }
        options.add(permissionOption("reject", "Reject", "reject_once"))
        sendValue113(
                objectValue(
                    [
                        ValueField("jsonrpc", textValue("2.0")),
                        ValueField("id", integerValue(requestId)),
                        ValueField(
                            "method",
                            textValue("session/request_permission")
                        ),
                        ValueField(
                            "params",
                            objectValue(
                                [
                                    ValueField(
                                        "sessionId",
                                        textValue(record.session.id().value)
                                    ),
                                    ValueField(
                                        "toolCall",
                                        objectValue(
                                            [
                                                ValueField(
                                                    "toolCallId",
                                                    textValue(approval.callId)
                                                ),
                                                ValueField(
                                                    "title",
                                                    textValue(approval.toolName)
                                                ),
                                                ValueField(
                                                    "kind",
                                                    textValue(acpToolKind(approval.toolName))
                                                ),
                                                ValueField("status", textValue("pending")),
                                                ValueField("rawInput", approvalReviewerArguments(approval))
                                            ]
                                        )
                                    ),
                                    ValueField(
                                        "options",
                                        listValue(options.toArray())
                                    )
                                ]
                            )
                        )
                    ]
                )
            )
    }

    private func handleClientResponse(value: AgentValue): Unit {
        let id = acpInteger(value, "id", -1)
        if (id < 0) {
            return
        }
        let record = findPermissionRecord(id)
        if (record.isNone()) {
            return
        }
        let target = record.getOrThrow()
        target.turnLock.lock()
        if (target.permissionRequestId != id || target.pendingPromptId.isNone()) {
            target.turnLock.unlock()
            return
        }
        let worker113 = try {
            let actual = target.workers113.prepare113(acpOwnedUtf8Bytes113(target.operationId), failureCode: "acp.permission_failed")
            target.installWorkerProducer113(actual); actual }
            catch (error: Exception) { target.turnLock.unlock(); throw error }
        let generation = target.generation
        let operationId = target.operationId
        target.permissionRequestId = -1
        target.operationId = ""
        target.activeWorkers += 1
        target.turnLock.unlock()
        let resultValue = match (value.field("result")) {
            case Some(item) => item
            case None =>
                worker113.start113({ =>
                    finishPermission(
                        target,
                        ApprovalDecision.Reject, generation, operationId
                    )
                })
                return
        }
        let outcome = match (resultValue.field("outcome")) {
            case Some(item) => item
            case None => objectValue([])
        }
        let kind = acpText(outcome, "outcome")
        let option = acpText(outcome, "optionId")
        let decision = if (kind == "selected" && option == "allow_once") {
            ApprovalDecision.Approve
        } else if (kind == "selected" && option == "allow_session" && target.allowSession) {
            ApprovalDecision.ApproveSession
        } else {
            ApprovalDecision.Reject
        }
        worker113.start113({ => finishPermission(target, decision, generation, operationId) })
    }

    private func finishPermission(
        record: AcpSessionRecord,
        decision: ApprovalDecision,
        generation: Int64,
        operationId: String
    ): Unit {
        record.turnLock.lock()
        let active = record.generation == generation
        record.turnLock.unlock()
        let result = if (active) { record.session.decide(operationId, decision) } else {
                Result<ApplicationResponse>.Err(AgentError(AgentErrorKind.Cancelled,
                    "acp.prompt_cancelled", "prompt was cancelled"))
            }
        finishTurn(record, result, generation)
    }

    private func addRecord(record: AcpSessionRecord): Result<Unit> {
        // Publish this exact source record before any fallible subscription
        // lease/cell/closure/array construction; exceptions cannot orphan it.
        lock.lock()
        try {
            control113.ensureRegistryMetadata113(1, acpOwnedAdd113(65536,
                acpOwnedMultiply113(acpOwnedAdd113(acpOwnedAdd113(records.size, retiringRecords113.size), 2), 4096)))
            retiringRecords113.add(record)
            record.metadata113.observeHelperReturned113()
            constructingMetadata113 = None<AcpOwnedMetadata113>
        }
        finally { lock.unlock() }
        let paid = record.prepareSubscription113()
        let token = record.session.subscribeRetirableOwned113(paid, {
            event => if (!record.closed) { forwardEvent(record, event) }
        }, CallbackOwnedAgentEventSink({ event => ignoreOwnedAcpToolExtension(event) }),
            failures: Some(AcpOwnedCheckpointSink113(record.checkpoints113,
                { run => record.observeCheckpointRun113(run) })))
        record.installSubscription113(token)
        var replaced: ?AcpSessionRecord = None
        lock.lock()
        try {
            for (index in 0..records.size) {
                if (records[index].session.id().value == record.session.id().value) {
                    replaced = Some(records[index])
                    control113.ensureRegistryMetadata113(1, acpOwnedAdd113(65536,
                        acpOwnedMultiply113(acpOwnedAdd113(acpOwnedAdd113(records.size, retiringRecords113.size), 2), 4096)))
                    retiringRecords113.add(records[index])
                    records.remove(at: index)
                    break
                }
            }
            records.add(record)
            for (index in 0..retiringRecords113.size) {
                if (refEq(retiringRecords113[index], record)) { retiringRecords113.remove(at: index); break }
            }
        } finally {
            lock.unlock()
        }
        match (replaced) {
            case Some(value) => match (value.close()) {
                case Result.Ok(_) => Result.Ok(())
                case Result.Err(error) => Result.Err(AgentError(
                    AgentErrorKind.Internal,
                    "acp.session_replace_failed",
                    "replacement session opened but the previous product failed to close",
                    fields: acpFailureFields([error])
                ))
            }
            case None => Result.Ok(())
        }
    }

    private func deferBootstrap(
        record: AcpSessionRecord,
        replay: Bool
    ): Unit {
        lock.lock()
        try {
            control113.ensureRegistryMetadata113(2, acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedAdd113(deferred.size, 1), 4096)))
            let paid = control113.prepareMetadata113(65536)
            let item = AcpDeferredUpdate(record, replay, paid)
            deferred.add(item); paid.observeHelperReturned113()
        } finally {
            lock.unlock()
        }
    }
    private func forwardEvent(record: AcpSessionRecord, event: AgentEvent): Unit {
        if (!record.workers113.beginEmit113()) { return }
        try { forwardEventBody113(record, event) }
        finally { record.workers113.endEmit113() }
    }

    private func forwardEventBody113(
        record: AcpSessionRecord,
        event: AgentEvent
    ): Unit {
        match (acpUpdateFromEvent(event)) {
            case Some(update) => emitUpdate(record, update)
            case None => ()
        }
    }

    private func emitBootstrap(record: AcpSessionRecord): Unit {
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField(
                        "sessionUpdate",
                        textValue("current_mode_update")
                    ),
                    ValueField("currentModeId", textValue("agent"))
                ]
            )
        )
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField(
                        "sessionUpdate",
                        textValue("config_option_update")
                    ),
                    ValueField(
                        "configOptions",
                        configOptions(record.session)
                    )
                ]
            )
        )
    }

    private func replayHistory(record: AcpSessionRecord): Unit {
        let messages = match (record.session.messages()) {
            case Result.Ok(value) => value
            case Result.Err(_) => return
        }
        for (index in 0..messages.size) {
            let message = messages[index]
            let updateKind = match (message.role) {
                case ModelRole.User => "user_message_chunk"
                case ModelRole.Assistant => "agent_message_chunk"
            }
            for (block in message.blocks where block.kind == ModelBlockKind.Text && block.text != "") {
                emitUpdate(
                    record,
                    objectValue(
                        [
                            ValueField(
                                "sessionUpdate",
                                textValue(updateKind)
                            ),
                            ValueField(
                                "content",
                                objectValue(
                                    [
                                        ValueField("type", textValue("text")),
                                        ValueField("text", textValue(block.text))
                                    ]
                                )
                            ),
                            ValueField(
                                "messageId",
                                textValue(record.session.id().value + "-" + index.toString())
                            )
                        ]
                    )
                )
            }
        }
    }

    private func emitUpdate(
        record: AcpSessionRecord,
        update: AgentValue
    ): Unit {
        sendValue113(
                objectValue(
                    [
                        ValueField("jsonrpc", textValue("2.0")),
                        ValueField("method", textValue("session/update")),
                        ValueField(
                            "params",
                            objectValue(
                                [
                                    ValueField(
                                        "sessionId",
                                        textValue(record.session.id().value)
                                    ),
                                    ValueField("update", update)
                                ]
                            )
                        )
                    ]
                )
            )
    }

    private func sessionSetupValue(
        record: AcpSessionRecord,
        includeId: Bool
    ): AgentValue {
        let fields = ArrayList<ValueField>()
        if (includeId) {
            fields.add(
                ValueField(
                    "sessionId",
                    textValue(record.session.id().value)
                )
            )
        }
        fields.add(ValueField("modes", modeState()))
        fields.add(
            ValueField(
                "configOptions",
                configOptions(record.session)
            )
        )
        objectValue(fields.toArray())
    }

    private func requiredRecord(params: AgentValue): Result<AcpSessionRecord> {
        let sessionId = acpText(params, "sessionId")
        if (sessionId == "") {
            return acpInvalid("sessionId is required")
        }
        match (findRecord(sessionId)) {
            case Some(value) => Result.Ok(value)
            case None => acpFailure(
                AgentErrorKind.RecoveryRequired,
                "acp.session_not_found",
                "session not found: " + sessionId
            )
        }
    }

    private func findOrLoad(
        sessionId: String,
        cwd: String
    ): Result<AcpSessionRecord> {
        match (findRecord(sessionId)) {
            case Some(value) => match (ensureAcpWorkspaceMatch(
                value.cwd,
                cwd,
                sessionId
            )) {
                case Result.Ok(_) => Result.Ok(value)
                case Result.Err(error) => Result.Err(error)
            }
            case None =>
                let session = SessionId(sessionId)
                if (!containsSession(host, sessionId)) {
                    return acpFailure(
                        AgentErrorKind.RecoveryRequired,
                        "acp.session_not_found",
                        "session not found: " + sessionId
                    )
                }
                let workspace = match (host.sessionWorkspaceRoot(session)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let persistedCwd = match (host.sessionCwd(session)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                match (ensureAcpWorkspaceMatch(persistedCwd, cwd, sessionId)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                let metadata = prepareSessionMetadata113(acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedAdd113(acpOwnedUtf8Bytes113(workspace), acpOwnedUtf8Bytes113(persistedCwd)), 8)))
                let product = match (factory(workspace)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let owner = AcpProductOwner(product, productScope180(), control113, closeJournal113, metadata)
                if (product.workspace.rootPath() != workspace) {
                    let error = AgentError(
                        AgentErrorKind.Conflict,
                        "acp.session_workspace_factory_mismatch",
                        "session product factory returned a different workspace",
                        fields: [
                            ErrorField("session_id", sessionId),
                            ErrorField("expected", workspace),
                            ErrorField("actual", product.workspace.rootPath())
                        ]
                    )
                    return acpOperationAndCloseFailure(
                        error,
                        owner.closeUnretained()
                    )
                }
                if (!containsSession(product, sessionId)) {
                    let error = AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "acp.session_not_found",
                        "session not found: " + sessionId
                    )
                    return acpOperationAndCloseFailure(
                        error,
                        owner.closeUnretained()
                    )
                }
                let record = AcpSessionRecord(
                    owner,
                    applicationFactory180(product, Some(SessionId(sessionId))),
                    persistedCwd,
                    control113, metadata
                )
                match (addRecord(record)) {
                    case Result.Ok(_) => Result.Ok(record)
                    case Result.Err(error) => Result.Err(error)
                }
        }
    }

    private func findRecord(sessionId: String): ?AcpSessionRecord {
        lock.lock()
        try {
            for (record in records where record.session.id().value == sessionId && !record.closed) {
                return Some(record)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    private func findPermissionRecord(requestId: Int64): ?AcpSessionRecord {
        lock.lock()
        let snapshot = try {
            control113.ensureRegistryMetadata113(1, acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedAdd113(records.size, retiringRecords113.size), 4096)))
            records.toArray()
        } finally { lock.unlock() }
        for (record in snapshot where !record.closed) {
            record.turnLock.lock()
            let matches = record.permissionRequestId == requestId
            record.turnLock.unlock()
            if (matches) { return Some(record) }
        }
        None
    }

    private func takePromptId(record: AcpSessionRecord): AgentValue {
        let id = match (record.pendingPromptId) {
            case Some(value) => value
            case None => nullValue()
        }
        record.pendingPromptId = None
        record.running = false
        id
    }

    private func removeReleasedRecord113(target: AcpSessionRecord): Unit {
        lock.lock()
        try {
            for (index in 0..records.size) {
                if (refEq(records[index], target)) { records.remove(at: index); break }
            }
        } finally { lock.unlock() }
    }

    // Concrete output happens outside server/turn/subscription mutexes.
    // A throwing cleanup keeps its exact derived payment in this server.
    public func collectOwnedCheckpointFailures113(): Bool {
        control113.beginCollection113()
        try { collectCheckpointCollectionFrame113() } finally { control113.endCall113() }
    }
    private func collectCheckpointCollectionFrame113(): Bool {
        lock.lock()
        try {
            if (checkpointCollectionActive113 || checkpointCollectionPaid113.isSome()) { return false }
            checkpointCollectionPaid113 = Some(control113.deriveMetadata113(acpOwnedAdd113(32768,
                acpOwnedMultiply113(acpOwnedAdd113(records.size, retiringRecords113.size), 512))))
            checkpointCollectionActive113 = true
        } finally { lock.unlock() }
        let complete = try { collectCheckpointRecordsHelper113() }
        finally { lock.lock(); try { checkpointCollectionActive113 = false } finally { lock.unlock() } }
        // The complete snapshot/output helper physically returned. Keep the
        // lease reachable until its actual close helper also returns.
        retireCheckpointCollectionPaymentHelper113(checkpointCollectionPaid113.getOrThrow())
        lock.lock(); try { checkpointCollectionPaid113 = None<LogicalJsonOwnerReservation> } finally { lock.unlock() }
        complete
    }
    private func collectCheckpointRecordsHelper113(): Bool {
        lock.lock()
        let snapshot = try {
            // Re-read the exact arrays and fund their actual growth under the
            // SAME lock that copies them; earlier collector admission is not
            // an exclusion against concurrent handle/addRecord.
            checkpointCollectionPaid113.getOrThrow().ensureRetainedPeak(acpOwnedAdd113(32768,
                acpOwnedMultiply113(acpOwnedAdd113(records.size, retiringRecords113.size), 512)))
            let actual = ArrayList<AcpSessionRecord>()
            for (record in records) { actual.add(record) }
            for (record in retiringRecords113) { actual.add(record) }
            actual
        } finally { lock.unlock() }
        var complete = true
        for (record in snapshot) {
            if (!record.collectCancelledPromptAfterJoin113({ id =>
                sendResult113(id, objectValue([ValueField("stopReason", textValue("cancelled"))])).isOk()
            })) { complete = false }
            if (!record.collectCheckpoint113(ownedFailureOutput113)) { complete = false }
        }
        complete
    }
    private func retireCheckpointCollectionPaymentHelper113(paid: LogicalJsonOwnerReservation): Unit { paid.close() }

    private func collectReturnedWorkers113(): Unit {
        lock.lock()
        let paid = try {
            if (workerCollectionPaid113.isSome()) { throw IllegalStateException("ACP keeps an unfinished worker collection") }
            let actual = control113.deriveMetadata113(65536)
            workerCollectionPaid113 = Some(actual); actual
        } finally { lock.unlock() }
        collectReturnedSnapshotHelper113(paid)
        // Complete snapshot/record/write/loan helpers physically returned.
        paid.close(); workerCollectionPaid113 = None<LogicalJsonOwnerReservation>
    }
    private func collectReturnedSnapshotHelper113(paid: LogicalJsonOwnerReservation): Unit {
        lock.lock()
        let snapshot = try {
            paid.ensureRetainedPeak(acpOwnedAdd113(65536,
                acpOwnedMultiply113(acpOwnedAdd113(records.size, retiringRecords113.size), 4096)))
            let actual = ArrayList<AcpSessionRecord>()
            for (record in records) { actual.add(record) }
            for (record in retiringRecords113) { actual.add(record) }
            workerCollectionSnapshot113 = Some(actual)
            actual
        } finally { lock.unlock() }
        collectReturnedRecordHelpers113(snapshot)
        workerCollectionSnapshot113 = None<ArrayList<AcpSessionRecord>>
    }
    private func collectReturnedRecordHelpers113(snapshot: ArrayList<AcpSessionRecord>): Unit {
        for (record in snapshot) {
            let _ = record.collectFailedWorkerAfterJoin113({ id, error, source => sendWorkerAgentError113(id, error, source).isOk() })
            let _ = record.collectReturnedWorkersAndIdentity113() }
    }

    private func holdOwnedCheckpointMarker113(error: AgentError, id: AgentValue): Bool {
        lock.lock()
        try {
            for (record in records) {
                if (record.holdCheckpoint113(error, Some(id))) { return true }
            }
            false
        } finally { lock.unlock() }
    }
    private func nextRequestId(): Int64 {
        match (requestIdAllocator180) { case Some(allocate) => return allocate(); case None => () }
        lock.lock()
        try {
            requestCounter += 1
            requestCounter
        } finally {
            lock.unlock()
        }
    }

    private func isInitialized(): Bool {
        lock.lock()
        try {
            initialized
        } finally {
            lock.unlock()
        }
    }

    private func isClosed(): Bool {
        lock.lock()
        try { closed } finally { lock.unlock() }
    }
}

func acpUpdateFromEvent(event: AgentEvent): ?AgentValue {
    match (event.payload) {
        case AgentEventPayload.TextDelta(text) => Some(acpMessageUpdate(
            "agent_message_chunk",
            text,
            event.runId.value
        ))
        case AgentEventPayload.ReasoningDelta(text) => Some(acpMessageUpdate(
            "agent_thought_chunk",
            text,
            event.runId.value
        ))
        case AgentEventPayload.ToolStarted(callId, name, _) => Some(objectValue([
            ValueField("sessionUpdate", textValue("tool_call")),
            ValueField("toolCallId", textValue(callId.value)),
            ValueField("title", textValue(name)),
            ValueField("kind", textValue(acpToolKind(name))),
            ValueField("status", textValue("in_progress")),
            ValueField("rawInput", objectValue([]))
        ]))
        case AgentEventPayload.ToolOutput(callId, channel, delta) => Some(objectValue([
            ValueField("sessionUpdate", textValue("tool_call_update")),
            ValueField("toolCallId", textValue(callId.value)),
            ValueField("status", textValue("in_progress")),
            ValueField("rawOutput", objectValue([
                ValueField("channel", textValue(acpToolOutputChannel(channel))),
                ValueField("delta", textValue(delta))
            ]))
        ]))
        case AgentEventPayload.ToolCompleted(callId, succeeded, _) => Some(objectValue([
            ValueField("sessionUpdate", textValue("tool_call_update")),
            ValueField("toolCallId", textValue(callId.value)),
            ValueField("status", textValue(if (succeeded) { "completed" } else { "failed" }))
        ]))
        case _ => None
    }
}

func acpMessageUpdate(
    kind: String,
    text: String,
    messageId: String
): AgentValue {
    objectValue([
        ValueField("sessionUpdate", textValue(kind)),
        ValueField("content", objectValue([
            ValueField("type", textValue("text")),
            ValueField("text", textValue(text))
        ])),
        ValueField("messageId", textValue(messageId))
    ])
}

func acpToolOutputChannel(channel: ToolOutputChannel): String {
    match (channel) {
        case ToolOutputChannel.Stdout => "stdout"
        case ToolOutputChannel.Stderr => "stderr"
        case ToolOutputChannel.Progress => "progress"
        case ToolOutputChannel.Artifact => "artifact"
        case ToolOutputChannel.Summary => "summary"
    }
}

class AcpSessionRecord {
    let owner: AcpProductOwner
    let product: ProductRuntime
    let session: ApplicationSession
    let cwd: String
    private let control113: AcpOwnedWorkerControl113
    let workers113: AcpOwnedWorkerRegistry113
    let metadata113: AcpOwnedMetadata113
    private var cancelResult113: ?Result<Unit> = None<Result<Unit>>
    private var cancelProducer113: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>
    let checkpoints113 = AcpOwnedCheckpointQueue113()
    private let checkpointLock113 = Mutex()
    private var checkpointWorking113 = false
    private var checkpointCallerAdmitted113 = false
    private var checkpointRun113: ?RunId = None<RunId>
    private var secondaryCaller113: ?OwnedAgentRunResult113 = None<OwnedAgentRunResult113>
    private var checkpointWaveCount113: ?Int64 = None<Int64>
    private var subscription113: ?ApplicationOwnedSubscription113 = None<ApplicationOwnedSubscription113>
    private var subscriptionPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var subscriptionStarting113 = false
    private var checkpointMarker113: ?AgentError = None<AgentError>
    private var checkpointRequest113: ?AgentValue = None<AgentValue>
    private let lifecycleLock = Mutex()
    private var released = false
    private var releaseError: ?AgentError = None
    let turnLock = Mutex()
    var generation: Int64 = 0
    var activeWorkers: Int64 = 0
    var running = false
    var closed = false
    var pendingPromptId: ?AgentValue = None
    var cancelledPromptGeneration113: ?Int64 = None<Int64>
    var cancelledPromptOffered113 = false
    private var cancelledPromptWorking113 = false
    private var promptIdentity113: ?AgentValue = None<AgentValue>
    private var promptIdentityPaid113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var promptIdentityPeak113: Int64 = 65536
    private var workerFailureProducer113: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>

    var permissionRequestId: Int64 = -1
    var operationId = ""
    var allowSession = false

    init(
        owner: AcpProductOwner,
        session: ApplicationSession,
        cwd: String,
        control113: AcpOwnedWorkerControl113,
        metadata113: AcpOwnedMetadata113
    ) {
        this.metadata113 = metadata113
        metadata113.ensure113(acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedUtf8Bytes113(cwd), 8)))
        this.control113 = control113
        this.workers113 = AcpOwnedWorkerRegistry113(control113, owner.closeJournal113)
        this.owner = owner
        this.product = owner.product
        this.session = session
        this.cwd = cwd
        owner.retain()
        if (!refEq(metadata113, owner.metadata113)) {
            metadata113.setGuard113({ => clearCompatibilityCachesAfterCallerReturn113() }) }

    }
    func installWorkerProducer113(worker: AcpOwnedWorker113): Unit { workerFailureProducer113 = Some(worker.producer113()) }
    func collectFailedWorkerAfterJoin113(send: (AgentValue, AgentError, AcpOwnedCloseProducer113)->Bool): Bool {
        if (!workers113.collectReturned113()) { return false }
        let producer = match (workerFailureProducer113) { case Some(actual) => actual; case None => return true }
        if (!producer.hasFailure113()) { workerFailureProducer113 = None<AcpOwnedCloseProducer113>; return true }
        // Complete producer and real Future.get/tryGet have returned. The
        // original request identity is retained until the one full DATA frame
        // truly writes and flushes, even on closed/generation changes.
        turnLock.lock()
        try {
            let id = match (pendingPromptId) { case Some(actual) => actual; case None => return false }
            metadata113.ensure113(262144)
            let answer = AcpOwnedCloseText113()
            match (producer.withError113({ error, _ => answer.failed = !send(id, error, producer) })) {
                case Result.Err(_) => return false
                case Result.Ok(_) => () }
            if (answer.failed) { return false }
            producer.markPrinted113()
            pendingPromptId = None<AgentValue>; permissionRequestId = -1; operationId = ""
            running = false; activeWorkers = 0
            workerFailureProducer113 = None<AcpOwnedCloseProducer113>
            cancelledPromptGeneration113 = None<Int64>; cancelledPromptOffered113 = false; true
        } finally { turnLock.unlock() }
    }

    // The original cancel request is still applied immediately. Its prompt
    // terminal waits for the registered worker's REAL get/tryGet return, so
    // a canonical checkpoint failure can retain this exact original id.
    // No generation counter or callback return is a producer-return witness.
    // Neither cancellation nor a scalar counter is a producer return ACK.
    // This package accessor copies no marker and exposes no mutable identity.
    func hasRetainedCheckpoint113(): Bool { checkpointMarkerSnapshot113().isSome() }
    func collectCancelledPromptAfterJoin113(send: (AgentValue) -> Bool): Bool {
        if (!workers113.collectReturned113()) { return false }
        turnLock.lock()
        try {
            if (cancelledPromptGeneration113.isNone()) { return true }
            if (hasRetainedCheckpoint113()) { return true }
            match (workerFailureProducer113) {
                case Some(value) => if (value.hasFailure113()) { return false }
                case None => () }
            if (cancelledPromptWorking113 || cancelledPromptOffered113) { return false }
            if (pendingPromptId.isNone()) {
                cancelledPromptGeneration113 = None<Int64>; return true }
        } finally { turnLock.unlock() }
        // ONLY a Bool escapes this helper. Its id, output callback, renderer,
        // response child and all borrowed aliases have actually returned.
        if (!collectCancelledPromptOutputHelper113(send)) { return false }
        turnLock.lock()
        try {
            if (pendingPromptId.isNone() || cancelledPromptGeneration113.isNone() ||
                !cancelledPromptOffered113 || cancelledPromptWorking113) { return false }
            pendingPromptId = None<AgentValue>
            cancelledPromptGeneration113 = None<Int64>
            cancelledPromptOffered113 = false; running = false
            true
        } finally { turnLock.unlock() }
    }
    private func collectCancelledPromptOutputHelper113(send: (AgentValue) -> Bool): Bool {
        turnLock.lock()
        let id = try {
            if (cancelledPromptGeneration113.isNone() || hasRetainedCheckpoint113() ||
                cancelledPromptWorking113 || cancelledPromptOffered113) { return false }
            let actual = match (pendingPromptId) {
                case Some(value) => value
                case None => return false }
            metadata113.ensure113(8192)
            cancelledPromptWorking113 = true; cancelledPromptOffered113 = true
            actual
        } finally { turnLock.unlock() }
        // This exact original id stays in its paid record while the real
        // output helper executes without the turn/server lock. Failure holds
        // the one-offered id, and repeated cancel can never offer it again.
        try { send(id) }
        catch (_: Exception) { false }
        finally { turnLock.lock(); try { cancelledPromptWorking113 = false } finally { turnLock.unlock() } }
    }

    private func fundPromptIdentity113(bytes: Int64): Result<Unit> {
        let wanted = acpOwnedAdd113(promptIdentityPeak113, bytes)
        promptIdentityPaid113.getOrThrow().ensureRetainedPeak(wanted)
        promptIdentityPeak113 = wanted
        Result<Unit>.Ok(())
    }
    func copyPromptIdentity113(id: AgentValue): AgentValue {
        match (promptIdentity113) {
            case Some(actual) =>
                if (refEq(actual, id)) { return actual }
                throw IllegalStateException("ACP retains a different prompt request identity")
            case None => () }
        if (promptIdentityPaid113.isSome()) { throw IllegalStateException("ACP keeps an unfinished request identity producer") }
        promptIdentityPaid113 = Some(control113.deriveMetadata113(65536))
        let encoded = match (encodeOwnedFailureError113(None<AgentError>,
            [ValueField("id", id)], "__acp_identity_end_113", { bytes => fundPromptIdentity113(bytes) })) {
            case Result.Ok(actual) => actual
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error) }
        // The original parser estimate is measured without allocating from
        // the actual encoded bytes, then paid BEFORE the independent DOM.
        match (fundPromptIdentity113(acpOwnedInputInvoice113(encoded))) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(_) => () }
        let decoded = match (decodeAgentValue(encoded)) {
            case Result.Ok(actual) => actual
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error) }
        let actual = decoded.field("id").getOrThrow()
        promptIdentity113 = Some(actual); actual
    }
    func collectReturnedWorkersAndIdentity113(): Bool {
        if (!workers113.collectReturned113()) { return false }
        turnLock.lock()
        try {
            checkpointLock113.lock()
            try {
                if (pendingPromptId.isSome() || checkpointMarker113.isSome() || checkpointRequest113.isSome()) { return false }
                // Every producer/observer helper Future already returned;
                // clear the DOM alias before retiring its original child.
                promptIdentity113 = None<AgentValue>
                match (promptIdentityPaid113) {
                    case Some(paid) => paid.close(); promptIdentityPaid113 = None<LogicalJsonOwnerReservation>
                    case None => () }
                true
            } finally { checkpointLock113.unlock() }
        } finally { turnLock.unlock() }
    }

    func prepareSubscription113(): LogicalJsonOwnerReservation {
        lifecycleLock.lock()
        try {
            if (subscriptionStarting113 || subscription113.isSome() || subscriptionPaid113.isSome()) {
                throw IllegalStateException("ACP retains an unfinished subscription registration") }
            let paid = control113.deriveMetadata113(65536)
            subscriptionPaid113 = Some(paid); subscriptionStarting113 = true
            paid
        } finally { lifecycleLock.unlock() }
    }
    func installSubscription113(token: ApplicationOwnedSubscription113): Unit {
        lifecycleLock.lock()
        try { subscription113 = Some(token); subscriptionStarting113 = false }
        finally { lifecycleLock.unlock() }
    }
    func observeCheckpointRun113(run: RunId): Unit {
        checkpointLock113.lock()
        try {
            match (checkpointRun113) { case Some(actual) =>
                if (actual.value != run.value) { throw IllegalStateException("ACP checkpoint changed actual run identity") }
                return
                case None => () }
            metadata113.ensure113(acpOwnedAdd113(131072, acpOwnedMultiply113(acpOwnedUtf8Bytes113(run.value), 8)))
            checkpointRun113 = Some(RunId(String.fromUtf8(run.value.toArray())))
        } finally { checkpointLock113.unlock() }
    }
    func holdCheckpoint113(error: AgentError, id: ?AgentValue): Bool {
        if (!session.hasOwnedCheckpointFailure113(error)) { return false }
        checkpointLock113.lock()
        try {
            match (checkpointMarker113) {
                case Some(actual) => if (!refEq(actual, error)) {
                    throw IllegalStateException("ACP retains another actual checkpoint marker") }
                case None =>
                    let copied = match (id) { case Some(actual) => Some(copyPromptIdentity113(actual)); case None => None<AgentValue> }
                    checkpointMarker113 = Some(error); checkpointRequest113 = copied
            }
            // The exact App slot keeps its full result until the real queue
            // admission succeeds. Recognition occurs before closed/generation
            // early returns in the unchanged worker finishTurn path.
            true
        } finally { checkpointLock113.unlock() }
    }
    func collectCheckpoint113(output: ?OwnedRpcFailureOutput113): Bool {
        checkpointLock113.lock()
        try {
            if (checkpointWorking113) { return false }
            checkpointWorking113 = true
        } finally { checkpointLock113.unlock() }
        try { collectCheckpointHelper113(output) }
        finally { checkpointLock113.lock(); try { checkpointWorking113 = false } finally { checkpointLock113.unlock() } }
    }
private func collectCheckpointHelper113(output: ?OwnedRpcFailureOutput113): Bool {
        // activeWorkers--/cancel/close are never substitutes. This exact
        // registry observes its registered Futures and all emitter frames.
        if (!workers113.collectReturned113()) { return false }
        let marker = match (checkpointMarkerSnapshot113()) {
            case Some(value) => value
            case None => return !checkpoints113.pending113() }
        if (!checkpointCallerWasAdmitted113()) {
            let id = match (checkpointRequestSnapshot113()) { case Some(value) => value; case None => return false }
            let admitted = session.pollAndAdmitOwnedCheckpointFailure113(marker,
                { actual => checkpoints113.admitCaller113(actual, id) })
            checkpointLock113.lock(); try { checkpointCallerAdmitted113 = admitted } finally { checkpointLock113.unlock() }
            if (!admitted) { return false }
        }
        if (checkpointRunSnapshot113().isNone()) {
            // A genuine failed save/append can prevent Event delivery. The
            // actual caller publication retains the original Run metadata;
            // borrowing it does not construct or invent a Diagnostic event.
            if (!checkpoints113.observeCallerRun113({ run => observeCheckpointRun113(run) })) {
                // A first Pending DATA result lacks publication metadata.
                // Borrow only the exact matching original App slot identity;
                // neither an absent Event nor activeRunId guesses a Run.
                match (session.withOwnedCheckpointRunIdentity113(marker,
                    { run => observeCheckpointRun113(run); Result<Unit>.Ok(()) })) {
                    case Result.Ok(true) => ()
                    case _ => return false }
            }
        }
        let run = match (checkpointRunSnapshot113()) { case Some(value) => value; case None => return false }
        if (checkpointWaveCount113.isNone()) {
            while (true) {
                match (secondaryCaller113) { case Some(value) =>
                    if (!checkpoints113.admitSecondary113(value)) { return false }
                    // The entire admission helper returned before our slot
                    // drops its duplicate reference. False retains it here.
                    secondaryCaller113 = None<OwnedAgentRunResult113>
                    case None => () }
                let (quiet, count, remaining) = checkpoints113.prepareWave113(session, run)
                if (!quiet) { return false }
                if (checkpoints113.count113() == count && remaining == 0) {
                    checkpointWaveCount113 = Some(count); break }
                if (checkpoints113.count113() >= count || remaining == 0) { return false }
                // Root's original metadata pays the temporary transfer slot
                // BEFORE the installed chain moves an actual caller alias.
                metadata113.ensure113(262144)
                let next = try { session.takeOwnedCheckpointFailure113(run) }
                    catch (failure: OwnedCanonicalPaidFailure113) { OwnedAgentRunResult113.Pending(failure.takeConsumer()) }
                match (next) {
                    case OwnedAgentRunResult113.Failed(_) | OwnedAgentRunResult113.Pending(_) => secondaryCaller113 = Some(next)
                    case _ => return false }
            }
        }
        if (!checkpoints113.collect113(output, session, run, checkpointWaveCount113.getOrThrow())) { return false }
        // All real caller shares and expected Event shares consumed their
        // complete bytes after the one whole stdout helper returned.
        session.collectOwnedCheckpointFailure113()
        metadata113.ensure113(262144)
        let next = try { session.takeOwnedCheckpointFailure113(run) }
            catch (failure: OwnedCanonicalPaidFailure113) { OwnedAgentRunResult113.Pending(failure.takeConsumer()) }
        match (next) {
            case OwnedAgentRunResult113.Existing(_) =>
                checkpointLock113.lock()
                try {
                    checkpointMarker113 = None<AgentError>; checkpointRequest113 = None<AgentValue>
                    checkpointRun113 = None<RunId>; checkpointCallerAdmitted113 = false
                    checkpointWaveCount113 = None<Int64>
                } finally { checkpointLock113.unlock() }
                turnLock.lock()
                try { pendingPromptId = None<AgentValue>; permissionRequestId = -1; operationId = ""; running = false
                    cancelledPromptGeneration113 = None<Int64>; cancelledPromptOffered113 = false }
                finally { turnLock.unlock() }
                session.collectOwnedCheckpointFailure113(); true
            case OwnedAgentRunResult113.Held => false
            case _ =>
                // An unexpected later producer cannot obtain a second
                // terminal response or disappear behind a count/exit flag.
                secondaryCaller113 = Some(next); false
        }
    }
    private func checkpointMarkerSnapshot113(): ?AgentError {
        checkpointLock113.lock(); try { checkpointMarker113 } finally { checkpointLock113.unlock() }
    }
    private func checkpointRequestSnapshot113(): ?AgentValue {
        checkpointLock113.lock(); try { checkpointRequest113 } finally { checkpointLock113.unlock() }
    }
    private func checkpointRunSnapshot113(): ?RunId {
        checkpointLock113.lock(); try { checkpointRun113 } finally { checkpointLock113.unlock() }
    }
    private func checkpointCallerWasAdmitted113(): Bool {
        checkpointLock113.lock(); try { checkpointCallerAdmitted113 } finally { checkpointLock113.unlock() }
    }
    private func checkpointRetirementReady113(): Bool {
        checkpointLock113.lock()
        try { !checkpointWorking113 && checkpointMarker113.isNone() && secondaryCaller113.isNone() && !checkpoints113.pending113() }
        finally { checkpointLock113.unlock() }
    }
    private func retireSubscription113(): Bool {
        if (subscriptionStarting113) { return false }
        match (subscription113) {
            case Some(token) =>
                if (!session.unsubscribeRetirableOwned113(token)) { return false }
                // The entire App removal helper returned before token close.
                if (!token.retireAfterUnsubscribe113()) { return false }
                subscription113 = None<ApplicationOwnedSubscription113>
                subscriptionPaid113 = None<LogicalJsonOwnerReservation>
                true
            case None => subscriptionPaid113.isNone()
        }
    }


    private func clearCompatibilityCachesAfterCallerReturn113(): Bool {
        if (control113.isUnsafeLegacyHeld113() && !control113.isUnsafeFixtureRetiring113()) { return false }
        lifecycleLock.lock()
        try {
            if (!released) { return false }
            if (!workers113.retireRegistryAfterWorkersHelperReturn113()) { return false }
            cancelResult113 = None<Result<Unit>>; releaseError = None<AgentError>
            if (!refEq(metadata113, owner.metadata113)) { metadata113.requestRetirement113() }
            true
        } finally { lifecycleLock.unlock() }
    }

    func isReleased113(): Bool {
        lifecycleLock.lock()
        try { released } finally { lifecycleLock.unlock() }
    }

    func close(): Result<Unit> {
        lifecycleLock.lock()
        try {
            if (released) {
                return match (releaseError) {
                    case Some(error) => Result.Err(error)
                    case None => Result.Ok(())
                }
            }
            workers113.blockAdmissions113()
            closed = true
            if (control113.hasConcurrentCalls113()) { return acpOwnedWorkersPending113<Unit>() }
            if (cancelResult113.isNone()) {
                let actual = owner.closeJournal113.prepareProducer113()
                cancelProducer113 = Some(actual)
                actual.setRetirementGuard113({ => clearCompatibilityCachesAfterCallerReturn113() })
                let result = actual.run113({ => session.cancel() })
                actual.observeReturned113()
                cancelResult113 = Some(result)
            }
            if (!collectReturnedWorkersAndIdentity113() || !checkpointRetirementReady113() || !retireSubscription113()) {
                return acpOwnedWorkersPending113<Unit>()
            }
            released = true
            let failures = ArrayList<AgentError>()
            match (cancelResult113.getOrThrow()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => failures.add(error)
            }
            match (owner.release()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => failures.add(error)
            }
            let aggregate = owner.closeJournal113.prepareProducer113()
            aggregate.setRetirementGuard113({ => clearCompatibilityCachesAfterCallerReturn113() })
            let result = aggregate.run113({ => acpAggregateFailures(
                "acp.session_close_failed",
                "ACP session close failed",
                failures
            ) })
            aggregate.observeReturned113()
            match (result) {
                case Result.Err(error) => releaseError = Some(error)
                case Result.Ok(_) => ()
            }
            result
        } finally {
            lifecycleLock.unlock()
        }
    }
}

class AcpProductOwner {
    let product: ProductRuntime
    let metadata113: AcpOwnedMetadata113
    let closeJournal113: AcpOwnedCloseJournal113
    private let control113: AcpOwnedWorkerControl113
    private var closeProducer113: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>
    private var closeInvoked113 = false
    private var fixtureProductCleanupReturned113 = false
    private var fixtureProductCleanupSucceeded113 = false
    private var fixtureProductCleanup113: ?AcpOwnedCloseProducer113 = None<AcpOwnedCloseProducer113>

    private let scope180: AcpProductScope180
    private let lock = Mutex()
    private var references: Int64 = 0
    private var closed = false
    private var closeError: ?AgentError = None

    init(product: ProductRuntime, scope180: AcpProductScope180, control113: AcpOwnedWorkerControl113, closeJournal113: AcpOwnedCloseJournal113, metadata113: AcpOwnedMetadata113) {
        this.metadata113 = metadata113
        this.product = product
        this.scope180 = scope180
        this.control113 = control113
        this.closeJournal113 = closeJournal113
        metadata113.setGuard113({ => clearCompatibilityCacheAfterCallerReturn113() })
    }

    func retain(): Unit {
        lock.lock()
        try {
            if (closed) {
                throw IllegalStateException("cannot retain a closed ACP product")
            }
            references++
        } finally {
            lock.unlock()
        }
    }

    func release(): Result<Unit> {
        lock.lock()
        try {
            if (references > 0) { references-- }
            if (references > 0) { return Result.Ok(()) }
            closeLocked()
        } finally {
            lock.unlock()
        }
    }

    func closeUnretained(): Result<Unit> {
        lock.lock()
        try {
            if (references != 0) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "acp.product_still_referenced",
                    "cannot abandon an ACP product while sessions still reference it"
                ))
            }
            closeLocked()
        } finally {
            lock.unlock()
        }
    }

    func clearCompatibilityCacheAfterCallerReturn113(): Bool {
        if (control113.isUnsafeLegacyHeld113() && !control113.isUnsafeFixtureRetiring113()) { return false }
        lock.lock()
        try {
            if (!closed || references != 0) { return false }
            if (control113.isUnsafeFixtureUnitScope113() && (!fixtureProductCleanupReturned113 || !fixtureProductCleanupSucceeded113)) { return false }
            closeError = None<AgentError>; metadata113.requestRetirement113(); true
        } finally { lock.unlock() }
    }

    private func closeLocked(): Result<Unit> {
        if (closed) {
            return match (closeError) {
                case Some(error) => Result.Err(error)
                case None => Result.Ok(())
            }
        }
        if (closeInvoked113) { return acpOwnedWorkersPending113<Unit>() }
        let producer = closeJournal113.prepareProducer113()
        closeProducer113 = Some(producer)
        producer.setRetirementGuard113({ => clearCompatibilityCacheAfterCallerReturn113() })
        closeInvoked113 = true
        let result = producer.run113({ => scope180.close180(product) })
        producer.observeReturned113()
        if (control113.isUnsafeFixtureUnitScope113()) {
            // Register/fund BEFORE the additional actual Product callback.
            // This never invokes the synthetic closer a second time.
            let cleanup = closeJournal113.prepareProducer113()
            fixtureProductCleanup113 = Some(cleanup)
            let cleanupResult = cleanup.run113({ => product.close() })
            cleanup.observeReturned113()
            fixtureProductCleanupSucceeded113 = cleanupResult.isOk()
            fixtureProductCleanupReturned113 = true
            // A real cleanup error is full-data/paid and blocks final scope
            // retirement. It cannot be ignored by the old counter oracle.
        }
        closed = true
        match (result) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) =>
                closeError = Some(error)
                Result.Err(error)
        }
    }
}

class AcpDeferredUpdate {
    let metadata113: AcpOwnedMetadata113
    let record: AcpSessionRecord
    let replay: Bool

    init(record: AcpSessionRecord, replay: Bool, metadata113: AcpOwnedMetadata113) {
        this.metadata113 = metadata113
        this.record = record
        this.replay = replay
    }
}

func acpResult(id: AgentValue, result: AgentValue): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("jsonrpc", textValue("2.0")),
                ValueField("id", id),
                ValueField("result", result)
            ]
        )
    )
}

func acpError(id: AgentValue, code: Int64, message: String): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("jsonrpc", textValue("2.0")),
                ValueField("id", id),
                ValueField(
                    "error",
                    objectValue(
                        [
                            ValueField("code", integerValue(code)),
                            ValueField("message", textValue(message))
                        ]
                    )
                )
            ]
        )
    )
}

func acpAgentError(id: AgentValue, error: AgentError): String {
    let data = ArrayList<ValueField>()
    data.add(ValueField("code", textValue(error.code)))
    let fieldValues = ArrayList<AgentValue>()
    for (field in error.fields) {
        fieldValues.add(objectValue([
            ValueField("name", textValue(field.name)),
            ValueField("value", textValue(field.value))
        ]))
    }
    data.add(ValueField("fields", listValue(fieldValues.toArray())))
    encodeAgentValue(objectValue([
        ValueField("jsonrpc", textValue("2.0")),
        ValueField("id", id),
        ValueField("error", objectValue([
            ValueField("code", integerValue(acpErrorCode(error))),
            ValueField("message", textValue(error.message)),
            ValueField("data", objectValue(data.toArray()))
        ]))
    ]))
}

func acpErrorCode(error: AgentError): Int64 {
    match (error.code) {
        case "acp.method_not_found" => -32601
        case "acp.invalid_params" => -32602
        case _ => -32000
    }
}

func acpFailure<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

func closeAcpProduct(product: ProductRuntime): Result<Unit> {
    product.close()
}

func acpFailureFields(errors: Array<AgentError>): Array<ErrorField> {
    let fields = ArrayList<ErrorField>()
    fields.add(ErrorField("failure_count", errors.size.toString()))
    for (index in 0..errors.size) {
        fields.add(ErrorField(
            "error_" + index.toString() + "_code",
            errors[index].code
        ))
        fields.add(ErrorField(
            "error_" + index.toString() + "_message",
            errors[index].message
        ))
    }
    fields.toArray()
}

func acpAggregateFailures(
    code: String,
    message: String,
    failures: ArrayList<AgentError>
): Result<Unit> {
    if (failures.isEmpty()) { return Result.Ok(()) }
    Result.Err(AgentError(
        AgentErrorKind.Internal,
        code,
        message + ": " + failures.size.toString() + " failure(s)",
        fields: acpFailureFields(failures.toArray())
    ))
}

func acpOperationAndCloseFailure<T>(
    operationError: AgentError,
    closeResult: Result<Unit>
): Result<T> {
    match (closeResult) {
        case Result.Ok(_) => Result.Err(operationError)
        case Result.Err(closeError) => Result.Err(AgentError(
            AgentErrorKind.Internal,
            "acp.product_cleanup_failed",
            "ACP operation failed and its product could not be closed",
            fields: acpFailureFields([operationError, closeError])
        ))
    }
}

public func canonicalAcpCwd(value: String): Result<String> {
    if (!isAbsolutePath(value)) {
        return acpInvalid("cwd must be an absolute path")
    }
    try {
        Result.Ok(canonicalize(Path(value)).toString())
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "acp.cwd_unresolved",
            "cwd cannot be resolved: " + error.message,
            fields: [ErrorField("cwd", value)]
        ))
    }
}

func ensureAcpWorkspaceMatch(
    persistedCwd: String,
    authoredCwd: String,
    sessionId: String
): Result<Unit> {
    let canonical = match (canonicalAcpCwd(authoredCwd)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (canonical != persistedCwd) {
        return Result.Err(AgentError(
            AgentErrorKind.Conflict,
            "acp.session_workspace_mismatch",
            "session is bound to a different workspace",
            fields: [
                ErrorField("session_id", sessionId),
                ErrorField("expected_cwd", persistedCwd),
                ErrorField("actual_cwd", canonical)
            ]
        ))
    }
    Result.Ok(())
}

func acpInvalid<T>(message: String): Result<T> {
    acpFailure(
        AgentErrorKind.InvalidInput,
        "acp.invalid_params",
        message
    )
}

func acpDeferredValue(): AgentValue {
    objectValue([ValueField("_deferred", boolValue(true))])
}

func acpText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func acpWithField(
    value: AgentValue,
    name: String,
    fieldValue: AgentValue
): AgentValue {
    if (value.unifiedKind != ValueKind.Object) {
        return value
    }
    let fields = ArrayList<ValueField>()
    for (field in value.fields where field.name != name) {
        fields.add(field)
    }
    fields.add(ValueField(name, fieldValue))
    objectValue(fields.toArray())
}

func acpBool(
    value: AgentValue,
    name: String,
    fallback: Bool
): Bool {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Boolean) {
                item.asBool()
            } else {
                fallback
            }
        case None => fallback
    }
}

func acpInteger(
    value: AgentValue,
    name: String,
    fallback: Int64
): Int64 {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind != ValueKind.Number) {
                return fallback
            }
            try {
                Int64.parse(item.asNumberText())
            } catch (_: Exception) {
                fallback
            }
        case None => fallback
    }
}

func validateSessionCwd(cwd: String): Result<Unit> {
    if (!isAbsolutePath(cwd)) { return acpInvalid("cwd must be an absolute path") }
    Result.Ok(())
}

func isAbsolutePath(value: String): Bool {
    value.startsWith("/")
}

func containsSession(product: ProductRuntime, sessionId: String): Bool {
    match (product.sessions()) {
        case Result.Ok(values) =>
            for (value in values where value.value == sessionId) {
                return true
            }
            false
        case Result.Err(_) => false
    }
}

func parseCursor(value: String): Result<Int64> {
    if (value == "") {
        return Result.Ok(0)
    }
    try {
        let parsed = Int64.parse(value)
        if (parsed < 0) {
            acpInvalid("invalid session cursor")
        } else {
            Result.Ok(parsed)
        }
    } catch (_: Exception) {
        acpInvalid("invalid session cursor")
    }
}

func promptText(params: AgentValue): Result<String> {
    let prompt = match (params.field("prompt")) {
        case Some(value) => value
        case None => return acpInvalid("prompt is required")
    }
    if (prompt.unifiedKind != ValueKind.List) {
        return acpInvalid("prompt must be an array")
    }
    var result = ""
    for (block in prompt.items) {
        let kind = acpText(block, "type")
        var text = ""
        if (kind == "text") {
            text = acpText(block, "text")
        } else if (kind == "resource_link") {
            let uri = acpText(block, "uri")
            if (uri != "") {
                text = "[resource: " + uri + "]"
            }
        } else if (kind == "resource") {
            let resource = match (block.field("resource")) {
                case Some(value) => value
                case None => objectValue([])
            }
            text = acpText(resource, "text")
        } else if (kind == "image" || kind == "audio") {
            return acpInvalid(kind + " prompt blocks are not supported")
        }
        if (text != "") {
            if (result != "") {
                result += "\n"
            }
            result += text
        }
    }
    if (result.trimAscii() == "") {
        acpInvalid("prompt must contain text or embedded context")
    } else {
        Result.Ok(result)
    }
}

func modeState(): AgentValue {
    objectValue(
        [
            ValueField("currentModeId", textValue("agent")),
            ValueField(
                "availableModes",
                listValue(
                    [
                        objectValue(
                            [
                                ValueField("id", textValue("agent")),
                                ValueField("name", textValue("Agent")),
                                ValueField(
                                    "description",
                                    textValue("Use tools and act on the workspace.")
                                )
                            ]
                        )
                    ]
                )
            )
        ]
    )
}

func configOptions(session: ApplicationSession): AgentValue {
    let modelOptions = ArrayList<AgentValue>()
    for (model in session.models()) {
        modelOptions.add(
            objectValue(
                [
                    ValueField("value", textValue(model)),
                    ValueField("name", textValue(model))
                ]
            )
        )
    }
    let thinkingOptions = ArrayList<AgentValue>()
    for (name in [
        "off",
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
    ]) {
        thinkingOptions.add(
            objectValue(
                [
                    ValueField("value", textValue(name)),
                    ValueField("name", textValue(name))
                ]
            )
        )
    }
    listValue(
        [
            objectValue(
                [
                    ValueField("type", textValue("select")),
                    ValueField("id", textValue("mode")),
                    ValueField("name", textValue("Mode")),
                    ValueField("category", textValue("mode")),
                    ValueField("currentValue", textValue("agent")),
                    ValueField(
                        "options",
                        listValue(
                            [
                                objectValue(
                                    [
                                        ValueField("value", textValue("agent")),
                                        ValueField("name", textValue("Agent"))
                                    ]
                                )
                            ]
                        )
                    )
                ]
            ),
            objectValue(
                [
                    ValueField("type", textValue("select")),
                    ValueField("id", textValue("model")),
                    ValueField("name", textValue("Model")),
                    ValueField("category", textValue("model")),
                    ValueField("currentValue", textValue(session.model())),
                    ValueField("options", listValue(modelOptions.toArray()))
                ]
            ),
            objectValue(
                [
                    ValueField("type", textValue("select")),
                    ValueField("id", textValue("thinking")),
                    ValueField("name", textValue("Thinking")),
                    ValueField("category", textValue("thought_level")),
                    ValueField(
                        "currentValue",
                        textValue(acpThinkingName(session.thinking()))
                    ),
                    ValueField("options", listValue(thinkingOptions.toArray()))
                ]
            )
        ]
    )
}

func acpThinking(value: String): ?ThinkingLevel {
    match (value) {
        case "off" => Some(ThinkingLevel.Off)
        case "minimal" => Some(ThinkingLevel.Minimal)
        case "low" => Some(ThinkingLevel.Low)
        case "medium" => Some(ThinkingLevel.Medium)
        case "high" => Some(ThinkingLevel.High)
        case "xhigh" => Some(ThinkingLevel.XHigh)
        case "max" => Some(ThinkingLevel.Max)
        case _ => None
    }
}

func acpThinkingName(value: ThinkingLevel): String {
    match (value) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

func permissionOption(
    id: String,
    name: String,
    kind: String
): AgentValue {
    objectValue(
        [
            ValueField("optionId", textValue(id)),
            ValueField("name", textValue(name)),
            ValueField("kind", textValue(kind))
        ]
    )
}

func acpToolKind(name: String): String {
    match (name) {
        case "read" => "read"
        case "write" | "edit" => "edit"
        case "grep" | "glob" => "search"
        case "bash" | "task" | "hub" => "execute"
        case _ => "other"
    }
}

func minAcp(left: Int64, right: Int64): Int64 {
    if (left < right) {
        left
    } else {
        right
    }
}
