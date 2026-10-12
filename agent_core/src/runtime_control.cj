package agent_core

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import std.collection.*
import std.sync.*

import tool_runtime.*
class CoreRunControl <: PaidExecutionFailureSink173 {
    let runId: RunId
    let traceId: TraceId
    let source: CancellationSource
    let runtime: AgentThreadRuntime
    let ledger: ExecutionBudget
    private let lock = Mutex()
    private let eventLock = Mutex()
    private var currentState: RunState
    private var budgetModeValue: BudgetMode = BudgetMode.Normal
    private var drainAttemptsValue: Int64 = 0
    private var requestCounter: Int64 = 0
    private var turnCounter: Int64 = 0
    private var batchCounter: Int64 = 0
    private var contextReadCounter: Int64 = 0
    private var activeRequestId = ""
    private var activeTurnId: ?TurnId = None
    private var activeBatchId: ?ToolBatchId = None
    private let preparationInputs = HashMap<String, CorePreparationReadInput>()
    private var pendingContextRead: ?CorePendingContextRead = None
    // Routing references only: Host retains all physical cleanup debt.
    private var pendingOwnedExecution: ?CorePendingOwnedExecution = None
    private var pendingOwnedParent: ?CorePendingOwnedParentApproval = None
    private let retainedResultAckDebts=ArrayList<CoreRetainedResultAckDebt>()
    private let retainedFailureCleanupDebts=ArrayList<CoreRetainedFailureCleanupDebt>()
    private var outerFailure333:?OwnedOuterErrorFailure333=None<OwnedOuterErrorFailure333>
    private let outerSupplements333=ArrayList<AgentError>()
    private var outerPublicationBlocked333=false
    private let canonicalDeliveryDebts=ArrayList<CoreOwnedCanonicalDeliveryResource>()
    private let checkpointFailures113 = CoreCheckpointFailureQueue113()
    private var modelInputHead159: ?CoreModelInput159 = None<CoreModelInput159>
    private var modelInputCollectorActive159 = false
    private var checkpointReturnWitness113: ?OwnedTaskReturnWitness113 = None<OwnedTaskReturnWitness113>
    private var checkpointProducerQuiet113 = false
    private var contextUpdate: ?ContextReadUpdate = None
    private let scheduledToolSlots = ArrayList<NestedToolSlotFrames>()
    private var cancellationRegistration: ?CancellationRegistration = None
    private var runtimeCancellationRegistration: ?CancellationRegistration = None
    private var closed = false

    init(
        runId: RunId,
        budget: ResourceBudget,
        runtime: AgentThreadRuntime,
        initial!: RunState = RunState.Running,
        turns!: Int64 = 0,
        modelRequests!: Int64 = 0,
        parentCancellation!: ?CancellationToken = None
    ) {
        this.runId = runId
        this.traceId = TraceId("trace-" + runId.value)
        let execution = executionBudgetFrom(budget)
        this.source = CancellationSource(parent: parentCancellation, deadlineMillis: execution.deadlineMillis)
        this.runtime = runtime
        this.currentState = initial
        this.ledger = execution
        this.turnCounter = turns
        this.requestCounter = modelRequests
    }

    // Sequence allocation, durable append, and live delivery form one ordered
    // event publication step. Parallel tool workers must not persist a later
    // sequence before an earlier worker reaches the repository.
    func serializeEvent(action: () -> Result<Unit>): Result<Unit> {
        eventLock.lock()
        try { action() } finally { eventLock.unlock() }
    }

    func retainContextUpdate(value: ContextReadUpdate): Result<Unit> {
        lock.lock(); try {
            if (isTerminalRunState(currentState) || source.token.isCancelled() || contextUpdate.isSome()) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "context.read_update_busy", "another update or terminal Run owns this slot")) }
            contextUpdate = Some(value); Result.Ok(())
        } finally { lock.unlock() }
    }
    func peekContextUpdate(): ?ContextReadUpdate {
        lock.lock(); try { contextUpdate } finally { lock.unlock() }
    }
    func releaseContextUpdate(expected: ContextReadUpdate): Unit {
        lock.lock(); try {
            match (contextUpdate) { case Some(value) => if (refEq(value, expected)) { contextUpdate = None }; case None => () }
        } finally { lock.unlock() }
    }

    func takeContextUpdate(): ?ContextReadUpdate {
        lock.lock(); try { let value = contextUpdate; contextUpdate = None; value } finally { lock.unlock() }
    }

    func preparationInput(item: ItemId): ?CorePreparationReadInput {
        lock.lock(); try { preparationInputs.get(item.value) } finally { lock.unlock() }
    }
    func retainPreparationInput(value: CorePreparationReadInput): Result<Unit> {
        lock.lock()
        try {
            if (preparationInputs.contains(value.parent.canonicalItemId.value) || preparationInputs.size >= 64) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "context.read_owner_conflict", "preparation owner is repeated or exceeds its bound")) }
            preparationInputs[value.parent.canonicalItemId.value] = value; Result.Ok(())
        } finally { lock.unlock() }
    }
    func releasePreparationInput(item: ItemId): Unit {
        lock.lock(); try { let _ = preparationInputs.remove(item.value) } finally { lock.unlock() }
    }
    func retainPendingRead(value: CorePendingContextRead): Result<Unit> {
        lock.lock(); try {
            if (pendingContextRead.isSome()) { return Result.Err(AgentError(AgentErrorKind.Conflict,
                "context.read_already_waiting", "another read owns the preparation approval slot")) }
            pendingContextRead = Some(value); Result.Ok(())
        } finally { lock.unlock() }
    }
    func pendingRead(operation: OperationId): ?CorePendingContextRead {
        lock.lock(); try {
            match (pendingContextRead) { case Some(value) => if (value.prepared.operationId.value == operation.value) { Some(value) } else { None }
                case None => None }
        } finally { lock.unlock() }
    }
    func releasePendingRead(operation: OperationId): Unit {
        lock.lock(); try {
            match (pendingContextRead) { case Some(value) => if (value.prepared.operationId.value == operation.value) { pendingContextRead = None }
                case None => () }
        } finally { lock.unlock() }
    }

    func retainPendingOwnedExecution(value:CorePendingOwnedExecution):Result<Unit> {
        lock.lock();try {
            if (closed || currentState!=RunState.Running || source.token.isCancelled() ||
                pendingOwnedExecution.isSome() || pendingOwnedParent.isSome() || pendingContextRead.isSome() ||
                value.work.prepared.source.runId.value!=runId.value) { return Result.Err(coreOwnedLiveBusy()) }
            pendingOwnedExecution=Some(value);Result.Ok(())
        } finally { lock.unlock() }
    }
    func replacePendingOwnedExecution(expected:CorePendingOwnedExecution,next:CorePendingOwnedExecution):Result<Unit> {
        lock.lock();try {
            if (closed || currentState!=RunState.Running || source.token.isCancelled() ||
                expected.work.prepared.operationId.value!=next.work.prepared.operationId.value ||
                expected.work.prepared.operationPlan.bindingDigest!=next.work.prepared.operationPlan.bindingDigest ||
                !refEq(expected.work.committed,next.work.committed) || next.work.prepared.source.runId.value!=runId.value) {
                return Result.Err(coreOwnedLiveBusy()) }
            match (pendingOwnedExecution) {
                case Some(value) => if (!refEq(value,expected)) { return Result.Err(coreOwnedLiveBusy()) }
                case None => return Result.Err(coreOwnedLiveBusy())
            }
            pendingOwnedExecution=Some(next);Result.Ok(())
        } finally { lock.unlock() }
    }
    func pendingOwnedExecutionFor(operation:OperationId):?CorePendingOwnedExecution {
        lock.lock();try { match (pendingOwnedExecution) {
            case Some(value) => if (value.publication.childOperationId.value==operation.value) { Some(value) } else { None }
            case None => None
        }} finally { lock.unlock() }
    }
    func releasePendingOwnedExecution(expected:CorePendingOwnedExecution):Unit {
        lock.lock();try { match (pendingOwnedExecution) {
            case Some(value) => if (refEq(value,expected)) { pendingOwnedExecution=None }
            case None => ()
        }} finally { lock.unlock() }
    }
    func retainPendingOwnedParent(value:CorePendingOwnedParentApproval):Result<Unit> {
        lock.lock();try {
            if (closed || currentState!=RunState.Running || source.token.isCancelled() ||
                pendingOwnedExecution.isSome() || pendingOwnedParent.isSome() || pendingContextRead.isSome() ||
                value.work.prepared.source.runId.value!=runId.value) { return Result.Err(coreOwnedLiveBusy()) }
            pendingOwnedParent=Some(value);Result.Ok(())
        } finally { lock.unlock() }
    }
    func pendingOwnedParentFor(operation:OperationId):?CorePendingOwnedParentApproval {
        lock.lock();try { match (pendingOwnedParent) {
            case Some(value) => if (value.work.prepared.operationId.value==operation.value) { Some(value) } else { None }
            case None => None
        }} finally { lock.unlock() }
    }
    func releasePendingOwnedParent(expected:CorePendingOwnedParentApproval):Unit {
        lock.lock();try { match (pendingOwnedParent) {
            case Some(value) => if (refEq(value,expected)) { pendingOwnedParent=None }
            case None => ()
        }} finally { lock.unlock() }
    }
    func replacePendingOwnedParentWithExecution(expected:CorePendingOwnedParentApproval,next:CorePendingOwnedExecution):Result<Unit> {
        lock.lock();try {
            if (closed || currentState!=RunState.Running || source.token.isCancelled() ||
                pendingOwnedExecution.isSome() || pendingContextRead.isSome() ||
                !refEq(expected.work.committed,next.work.committed) ||
                expected.work.prepared.operationId.value!=next.work.prepared.operationId.value ||
                expected.work.prepared.operationPlan.bindingDigest!=next.work.prepared.operationPlan.bindingDigest ||
                next.work.prepared.source.runId.value!=runId.value) { return Result.Err(coreOwnedLiveBusy()) }
            match (pendingOwnedParent) {
                case Some(value) => if (!refEq(value,expected)) { return Result.Err(coreOwnedLiveBusy()) }
                case None => return Result.Err(coreOwnedLiveBusy())
            }
            pendingOwnedParent=None;pendingOwnedExecution=Some(next);Result.Ok(())
        } finally { lock.unlock() }
    }

    // This is resource custody only. It cannot execute, resume, create Source,
    // amend a Receipt or release an uncommitted canonical result.
    func retainResultAckDebt(output:OwnedToolRetainedParentExecution):CoreRetainedResultAckDebt{
        lock.lock();try{
            for(value in retainedResultAckDebts where refEq(value.output,output)){return value}
            let value=CoreRetainedResultAckDebt(output);retainedResultAckDebts.add(value);value
        }finally{lock.unlock()}
    }
    func markResultCanonicalCommitted(value:CoreRetainedResultAckDebt):Unit{
        lock.lock();try{for(actual in retainedResultAckDebts where refEq(actual,value)){
            actual.canonicalCommitted=true}}
        finally{lock.unlock()}
    }
    func releaseResultAckDebt(value:CoreRetainedResultAckDebt):Unit{
        if(!value.output.isAcknowledged()){return}
        // Physical Session ACK does not retire the public canonical DOM
        // aliases retained by coordinator snapshots or extracted AgentValue.
        // Keep the SAME original high-water backing in this sole Run control.
        // No early-close API exists; complete alias retirement remains open.
        if(value.output.isCanonicalBackingRetained()){return}
        lock.lock();try{for(index in 0..retainedResultAckDebts.size){
            if(refEq(retainedResultAckDebts[index],value)){retainedResultAckDebts.remove(at:index);return}}}
        finally{lock.unlock()}
    }
    func retainFailureCleanupDebt(output:OwnedToolRetainedFailureExecution):CoreRetainedFailureCleanupDebt{
        lock.lock();try{
            for(value in retainedFailureCleanupDebts where refEq(value.output,output)){return value}
            let value=CoreRetainedFailureCleanupDebt(output);retainedFailureCleanupDebts.add(value);value
        }finally{lock.unlock()}
    }
    func outerErrorData333():?PluginLivePolicyOuterErrorDataOwner331{
        lock.lock();try{
            for(value in retainedFailureCleanupDebts){match(value.output.outerErrorData333()){
                case Some(data)=>return Some(data);case None=>()}}
            None<PluginLivePolicyOuterErrorDataOwner331>
        }finally{lock.unlock()}
    }
    func blockOuterPublication333():Unit{lock.lock();try{outerPublicationBlocked333=true}finally{lock.unlock()}}
    func isOuterPublicationBlocked333():Bool{lock.lock();try{outerPublicationBlocked333}finally{lock.unlock()}}
    func outerErrorSource333():?PluginLivePolicyPaidOuterErrorSource333{
        lock.lock();try{
            for(value in retainedFailureCleanupDebts){match(coreOwnedOuterErrorSource333(value.output)){
                case Some(source)=>return Some(source);case None=>()}}
            None<PluginLivePolicyPaidOuterErrorSource333>
        }finally{lock.unlock()}
    }
    func retainOuterSupplement333(error:AgentError):Result<Unit>{
        let source=match(outerErrorSource333()){case Some(value)=>value
            case None=>return ownedOuterErrorConsumerError333("run.owned_outer_error_source_missing")}
        match(coreOwnedOuterErrorPayAlias333(source,error)){
            case Result.Err(value)=>blockOuterPublication333();Result.Err(value)
            case Result.Ok(_)=>lock.lock();try{outerSupplements333.add(error);Result.Ok(())}finally{lock.unlock()}}
    }
    func publishOuterFailure333(value:OwnedOuterErrorFailure333):Result<Unit>{
        lock.lock();try{
            if(outerPublicationBlocked333 || outerFailure333.isSome() || !value.matchesRun(runId)){
                return ownedOuterErrorConsumerError333("run.owned_outer_error_binding_changed")}
            for(error in outerSupplements333){match(value.retainSupplement(error)){
                case Result.Err(failure)=>outerPublicationBlocked333=true;return Result.Err(failure);case Result.Ok(_)=>()}}
            outerFailure333=Some(value);Result.Ok(())
        }finally{lock.unlock()}
    }
    func outerFailureData333():?OwnedOuterErrorFailure333{lock.lock();try{outerFailure333}finally{lock.unlock()}}
    func closeOuterPhysicalDebt334(fund:(Int64)->Result<Unit>):Result<Unit>{
        // Count, prepay and capture under the same lock; another retained
        // failure cannot grow the snapshot between its invoice and allocation.
        lock.lock()
        let selected=try{
            match(fund(ownedOuterErrorAdd333(8192,ownedOuterErrorMultiply333(retainedFailureCleanupDebts.size,4096)))){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            retainedFailureCleanupDebts.toArray()
        }finally{lock.unlock()}
        for(value in selected where value.output.outerErrorData333().isSome()){
            match(value.output.closeAfterFailure()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
        Result<Unit>.Ok(())
    }
    func releaseFailureCleanupDebt(value:CoreRetainedFailureCleanupDebt):Unit{
        // Physical ACK cannot retire the separately funded data/caller aliases.
        if(value.output.outerErrorData333().isSome()){return}
        if(!value.output.isAcknowledged()){return}
        lock.lock();try{for(index in 0..retainedFailureCleanupDebts.size){
            if(refEq(retainedFailureCleanupDebts[index],value)){retainedFailureCleanupDebts.remove(at:index);return}}}
        finally{lock.unlock()}
    }
    func retainCanonicalDelivery(value: CoreOwnedCanonicalDeliveryResource): Unit {
        lock.lock(); try { canonicalDeliveryDebts.add(value) } finally { lock.unlock() }
    }
    func releaseCanonicalDelivery(value: CoreOwnedCanonicalDeliveryResource): Unit {
        if (!value.isAcknowledged()) { return }
        lock.lock(); try {
            for (at in 0..canonicalDeliveryDebts.size) {
                match (canonicalDeliveryDebts[at] as Object) { case Some(actual) =>
                    match (value as Object) { case Some(expected) => if (refEq(actual, expected)) {
                        canonicalDeliveryDebts.remove(at: at); return }; case None => () }
                    case None => () }
            }
        } finally { lock.unlock() }
    }

    public func captureExecutionFailure173(context: ToolInvocationContext, callId: String,
        consumer: OwnedFailureDataConsumer113, dataOnly: Bool): Result<AgentError> {
        if (context.runId.value != runId.value) {
            return Result<AgentError>.Err(AgentError(AgentErrorKind.PermissionDenied,
                "run.paid_execution_context_mismatch", "paid failure must remain in its actual Run control")) }
        // Original 113 queue pays its holder before creation and preserves
        // the original kind. Its real Storage/Event/caller alias ACKs control
        // retirement. A recoverable Tool result adds DATA only, never fatal.
        Result<AgentError>.Ok(captureCheckpointFailure113(consumer,
            primary: !dataOnly, dataOnly113: dataOnly))
    }

    func captureCheckpointFailure113(consumer: OwnedFailureDataConsumer113, primary!: Bool = true, dataOnly113!: Bool = false): AgentError {
        checkpointFailures113.capture(consumer, primary, dataOnly113)
    }
    func isCheckpointFailureMarker113(error: AgentError): Bool { checkpointFailures113.isMarker(error) }
    func hasCheckpointFailure113(): Bool { checkpointFailures113.hasDebt() }
    func hasCheckpointConsumerFrame113(): Bool { checkpointFailures113.hasActiveConsumerFrame() }
    func checkpointFailureHead113(): ?CoreCheckpointFailureEntry113 { checkpointFailures113.head() }
    func retireCheckpointFailures113(): Result<Unit> { checkpointFailures113.retireReadyHeads() }

    func retainModelInput159(value: CoreModelInput159): Unit {
        lock.lock()
        try { value.next159 = modelInputHead159; modelInputHead159 = Some(value) }
        finally { lock.unlock() }
    }
    private func takeReturnedModelInputHead159(): ?LogicalJsonOwnerReservation {
        var cursor = try { lock.lock(); modelInputHead159 } finally { lock.unlock() }
        while (cursor.isSome()) {
            let value = cursor.getOrThrow()
            // The sole collector never holds the Run lock across the real
            // Future.get helper. Concurrent admission only prepends a node.
            let next = try { lock.lock(); value.next159 } finally { lock.unlock() }
            let payment = value.takeReturnedPayment159()
            if (payment.isSome()) {
                lock.lock()
                try {
                    var prior: ?CoreModelInput159 = None<CoreModelInput159>
                    var selected = modelInputHead159
                    while (selected.isSome()) {
                        let item = selected.getOrThrow()
                        if (refEq(item, value)) {
                            match (prior) { case Some(p) => p.next159 = item.next159
                                case None => modelInputHead159 = item.next159 }
                            item.next159 = None<CoreModelInput159>
                            break
                        }
                        prior = selected; selected = item.next159
                    }
                    removeReturnedModelInputDebt159(value)
                    return payment
                } finally { lock.unlock() }
            }
            // Held is a retained allocation, not an end-of-queue marker.
            cursor = next
        }
        None<LogicalJsonOwnerReservation>
    }
    func collectReturnedModelInputs159(): Unit {
        lock.lock()
        try {
            if (modelInputCollectorActive159) { return }
            modelInputCollectorActive159 = true
        } finally { lock.unlock() }
        try {
            while (true) {
                // All request/Future/action/holder traversal frames returned
                // before closing the selected original-bank invoice.
                match (takeReturnedModelInputHead159()) {
                    case Some(payment) => payment.close()
                    case None => return
                }
            }
        } finally {
            lock.lock()
            try { modelInputCollectorActive159 = false } finally { lock.unlock() }
        }
    }

    func checkpointWaveCounts113(): (Bool, Int64, Int64) {
        collectReturnedModelInputs159()
        let witness = try { lock.lock(); checkpointReturnWitness113 } finally { lock.unlock() }
        let quiet = match (witness) { case Some(value) => value.allOwnedProducersReturned113()
            case None => try { lock.lock(); checkpointProducerQuiet113 } finally { lock.unlock() } }
        // The entire scope/task/get query has returned before the bounded cache.
        if (quiet) { lock.lock(); try { checkpointProducerQuiet113 = true } finally { lock.unlock() } }
        checkpointFailures113.waveCounts113(quiet)
    }

    func checkpointEventExpectation113(sequence: Int64): ?Bool { checkpointFailures113.eventExpectation113(sequence) }

    // Called by the caller AFTER the complete Core/Service/Client/App query
    // frame returns. Cache is scalar; only this retained scope alias is dropped.
    func retireCheckpointReturnWitness113(): Unit {
        lock.lock(); try { if (checkpointProducerQuiet113) { checkpointReturnWitness113 = None<OwnedTaskReturnWitness113> } }
        finally { lock.unlock() }
    }

    func hasResultAckDebt():Bool{lock.lock();try{
        !retainedResultAckDebts.isEmpty() || !retainedFailureCleanupDebts.isEmpty() || !canonicalDeliveryDebts.isEmpty() || checkpointFailures113.hasDebt() || modelInputHead159.isSome()
    }finally{lock.unlock()}}
    func retryResultAckDebt():Result<Unit>{
        let values=try{lock.lock();retainedResultAckDebts.toArray()}finally{lock.unlock()}
        let unpublished=try{lock.lock();retainedFailureCleanupDebts.toArray()}finally{lock.unlock()}
        let deliveries=try{lock.lock();canonicalDeliveryDebts.toArray()}finally{lock.unlock()}
        var failure:?AgentError=None
        for (value in deliveries) {
            match (value.closeAfterFailure()) { case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }
                case Result.Ok(_) => releaseCanonicalDelivery(value) }
        }
        for(value in unpublished){
            let closed=value.output.closeAfterFailure()
            match(closed){case Result.Err(error)=>if(failure.isNone()){failure=Some(error)}
                case Result.Ok(_)=>releaseFailureCleanupDebt(value)}}
        for(value in values){
            if(!value.canonicalCommitted){
                if(failure.isNone()){failure=Some(AgentError(AgentErrorKind.RecoveryRequired,
                    "tool.retained_canonical_commit_pending","actual result remains paid until its original canonical consumer commits"))}
                continue
            }
            match(value.output.closeAfterConsumption()){
                case Result.Err(error)=>if(failure.isNone()){failure=Some(error)}
                case Result.Ok(_)=>releaseResultAckDebt(value)
            }
        }
        match(failure){case Some(error)=>Result.Err(error);case None=>Result.Ok(())}
    }
    func state(): RunState {
        lock.lock()
        try { currentState } finally { lock.unlock() }
    }

    func pauseForApproval(): Result<RunTransition> {
        updateState(runtime.pauseForApproval())
    }

    func resumeAfterApproval(): Result<RunTransition> {
        updateState(runtime.resumeAfterApproval())
    }

    func finish(
        terminal: RunState,
        reason!: String = ""
    ): Result<RunTransition> {
        let from = state()
        let settlement = match (runtime.finish(terminal, 1000, reason: reason)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let result = finishSettlementFrame159(settlement, from, reason)
        settlement.run.returnOwnedLaneView159()
        result
    }
    private func finishSettlementFrame159(settlement: RuntimeSettlement, from: RunState,
        reason: String): Result<RunTransition> {
        let transition = RunTransition(
            settlement.run.transitionSequence,
            from,
            settlement.run.state,
            reason
        )
        lock.lock(); try { checkpointReturnWitness113 = settlement.ownedTaskReturnWitness113() } finally { lock.unlock() }
        setState(settlement.run.state)
        Result.Ok(transition)
    }

    func beginCancellationSettlement(epoch: Int64): Result<Unit> {
        match (runtime.beginCancellationSettlement(runId, epoch)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => setState(RunState.Cancelling); Result.Ok(())
        }
    }

    func settleCancellation(reason: CancellationReason): Result<Array<RunTransition>> {
        let from = state()
        let settlement = match (runtime.cancel(1000, reason: Some(reason))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let result = cancellationSettlementFrame159(settlement, from, reason)
        settlement.run.returnOwnedLaneView159()
        result
    }
    private func cancellationSettlementFrame159(settlement: RuntimeSettlement, from: RunState,
        reason: CancellationReason): Result<Array<RunTransition>> {
        let terminal = settlement.run.state
        let transitions = if (from == RunState.Cancelling) {
            [RunTransition(
                settlement.run.transitionSequence,
                RunState.Cancelling,
                terminal,
                reason.code
            )]
        } else {
            [
                RunTransition(
                    settlement.run.transitionSequence - 1,
                    from,
                    RunState.Cancelling,
                    reason.code
                ),
                RunTransition(
                    settlement.run.transitionSequence,
                    RunState.Cancelling,
                    terminal,
                    reason.code
                )
            ]
        }
        lock.lock(); try { checkpointReturnWitness113 = settlement.ownedTaskReturnWitness113() } finally { lock.unlock() }
        setState(terminal)
        Result.Ok(transitions)
    }

    private func updateState(result: Result<RunTransition>): Result<RunTransition> {
        match (result) {
            case Result.Ok(value) =>
                setState(value.to)
                Result.Ok(value)
            case Result.Err(error) => Result.Err(error)
        }
    }
    private func setState(value: RunState): Unit {
        lock.lock()
        try { currentState = value } finally { lock.unlock() }
    }

    func bindRuntimeCancellation(epoch: Int64): Result<Unit> {
        let registration = match (runtime.bindCancellationParent(runId, epoch, source.token)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        lock.lock()
        let retained = try {
            if (closed || runtimeCancellationRegistration.isSome()) { false }
            else { runtimeCancellationRegistration = Some(registration); true }
        } finally { lock.unlock() }
        if (!retained) {
            registration.dispose()
            return Result.Err(AgentError(AgentErrorKind.Conflict, "run.cancellation_binding_unavailable",
                "the control is closed or already owns its Runtime cancellation registration"))
        }
        Result.Ok(())
    }

    func bindCancellation(model: ModelPort, tools: ToolPipeline): Unit {
        let registration = source.token.onCancel({ _ =>
            let requestId = currentRequestId()
            if (requestId != "") {
                let _ = model.cancel(requestId)
            }
            // Older provider adapters used runId as requestId. Keeping this
            // fallback makes cancellation safe during the v3 cut-over.
            if (requestId != runId.value) {
                let _ = model.cancel(runId.value)
            }
            let _ = tools.cancel(runId, threadId: Some(coreOwnedControlMetadata(runtime).thread.id))
        })
        lock.lock()
        let retained = try {
            if (closed || cancellationRegistration.isSome()) { false }
            else { cancellationRegistration = Some(registration); true }
        } finally { lock.unlock() }
        if (!retained) { registration.dispose() }
    }

    func close(): Unit {
        collectReturnedModelInputs159()
        match (takeContextUpdate()) { case Some(value) => value.cancel(); case None => () }
        lock.lock()
        let (registration, runtimeRegistration) = try {
            closed = true
            let value = cancellationRegistration
            let runtimeValue = runtimeCancellationRegistration
            cancellationRegistration = None
            runtimeCancellationRegistration = None
            (value, runtimeValue)
        } finally {
            lock.unlock()
        }
        match (registration) {
            case Some(value) => value.dispose()
            case None => ()
        }
        match (runtimeRegistration) { case Some(value) => value.dispose(); case None => () }
        source.close()
    }

    // The actual live Run owns this serial. Approval resume creates a new
    // ToolInvocationContext whose audit counter may start at zero; that view
    // must never mint a previously used ContextRead request identity.
    func nextContextReadRequestId(): Result<String> {
        lock.lock()
        try {
            if (closed || contextReadCounter == Int64.Max) {
                return Result.Err(AgentError(AgentErrorKind.Conflict,
                    "context.read_sequence_exhausted", "live context read identity cannot be allocated")) }
            contextReadCounter += 1
            Result.Ok("context-update-read-" + runId.value + "-" + contextReadCounter.toString())
        } finally { lock.unlock() }
    }

    func nextTurnId(): TurnId {
        lock.lock()
        try {
            turnCounter += 1
            let value = TurnId(runId.value + "-turn-" + turnCounter.toString())
            activeTurnId = Some(value)
            value
        } finally {
            lock.unlock()
        }
    }

    func nextRequestId(): RequestId {
        lock.lock()
        try {
            requestCounter += 1
            RequestId(runId.value + "-request-" + requestCounter.toString())
        } finally {
            lock.unlock()
        }
    }

    func nextBatchId(): ToolBatchId {
        lock.lock()
        try {
            batchCounter += 1
            let value = ToolBatchId(runId.value + "-tools-" + batchCounter.toString())
            activeBatchId = Some(value)
            value
        } finally {
            lock.unlock()
        }
    }

    func setActiveRequest(requestId: String): Unit {
        lock.lock()
        try { activeRequestId = requestId } finally { lock.unlock() }
    }

    func clearActiveRequest(requestId: String): Unit {
        lock.lock()
        try {
            if (activeRequestId == requestId) { activeRequestId = "" }
        } finally {
            lock.unlock()
        }
    }

    // A routing fence only: permission still comes from the current SQL/Thread.
    private var boundaryPrepareRequired = false
    func requireContextBoundaryPrepare(): Unit { lock.lock(); try { boundaryPrepareRequired = true } finally { lock.unlock() } }
    func contextBoundaryPrepareRequired(): Bool { lock.lock(); try { boundaryPrepareRequired } finally { lock.unlock() } }
    func didPrepareContextBoundary(): Unit { lock.lock(); try { boundaryPrepareRequired = false } finally { lock.unlock() } }

    // Same live control serials; no physical debt is acknowledged by data capture.
    func contextBoundaryControlValue(): AgentValue {
        lock.lock(); try {
            if (closed || currentState != RunState.Running || activeRequestId != "" || activeBatchId.isSome() ||
                !scheduledToolSlots.isEmpty() || pendingContextRead.isSome() || pendingOwnedExecution.isSome() || pendingOwnedParent.isSome()) {
                throw IllegalStateException("context boundary control is not settled") }
            objectValue([ValueField("request_serial", integerValue(requestCounter)), ValueField("turn_serial", integerValue(turnCounter)),
                ValueField("batch_serial", integerValue(batchCounter)), ValueField("context_read_serial", integerValue(contextReadCounter)),
                ValueField("active_turn_id", textValue(match (activeTurnId) { case Some(value) => value.value; case None => "" })),
                ValueField("budget_mode", textValue(budgetModeName(budgetModeValue))), ValueField("drain_attempts", integerValue(drainAttemptsValue)),
                ValueField("deadline_millis", integerValue(ledger.deadlineMillis))])
        } finally { lock.unlock() }
    }
    func restoreContextBoundaryControl(value: AgentValue): Unit {
        contextBoundaryShape(value, ["request_serial", "turn_serial", "batch_serial", "context_read_serial", "active_turn_id",
            "budget_mode", "drain_attempts", "deadline_millis"])
        lock.lock(); try {
            if (closed || currentState != RunState.Running || activeRequestId != "" || activeBatchId.isSome() ||
                !scheduledToolSlots.isEmpty() || !preparationInputs.isEmpty() || pendingContextRead.isSome() ||
                pendingOwnedExecution.isSome() || pendingOwnedParent.isSome() || contextUpdate.isSome() ||
                ledger.deadlineMillis != contextBoundaryInteger(value, "deadline_millis")) {
                throw IllegalStateException("context boundary cannot replace a live physical owner") }
            requestCounter = contextBoundaryInteger(value, "request_serial")
            turnCounter = contextBoundaryInteger(value, "turn_serial")
            batchCounter = contextBoundaryInteger(value, "batch_serial")
            contextReadCounter = contextBoundaryInteger(value, "context_read_serial")
            drainAttemptsValue = contextBoundaryInteger(value, "drain_attempts")
            budgetModeValue = match (contextBoundaryText(value, "budget_mode")) {
                case "normal" => BudgetMode.Normal; case "pressure" => BudgetMode.Pressure
                case "draining" => BudgetMode.Draining; case "exhausted" => BudgetMode.Exhausted
                case _ => throw IllegalArgumentException("unsupported context boundary budget mode") }
            let turn = contextBoundaryText(value, "active_turn_id")
            if (turn != "" && turn != runId.value + "-turn-" + turnCounter.toString()) {
                throw IllegalArgumentException("context boundary stable turn identity changed") }
            activeTurnId = if (turn == "") { None } else { Some(TurnId(turn)) }
        } finally { lock.unlock() }
    }

    func atModelLaneSafeCut(): Bool {
        lock.lock()
        try { currentState == RunState.Running && activeRequestId == "" &&
            activeBatchId.isNone() && scheduledToolSlots.isEmpty() }
        finally { lock.unlock() }
    }

    func currentRequestId(): String {
        lock.lock()
        try { activeRequestId } finally { lock.unlock() }
    }

    func currentTurnId(): ?TurnId {
        lock.lock()
        try { activeTurnId } finally { lock.unlock() }
    }

    func currentBatchId(): ?ToolBatchId {
        lock.lock()
        try { activeBatchId } finally { lock.unlock() }
    }

    func clearBatch(batchId: ToolBatchId): Unit {
        lock.lock()
        try {
            match (activeBatchId) {
                case Some(value) => if (value.value == batchId.value) { activeBatchId = None }
                case None => ()
            }
        } finally {
            lock.unlock()
        }
    }

    private func scheduledFrames(operationId: OperationId): ?NestedToolSlotFrames {
        for (owner in scheduledToolSlots where owner.contains(operationId)) { return Some(owner) }
        None
    }

    private func removeScheduledFrames(owner: NestedToolSlotFrames): Unit {
        for (index in 0..scheduledToolSlots.size where refEq(scheduledToolSlots[index], owner)) {
            scheduledToolSlots.remove(at: index); return
        }
    }

    func registerScheduledToolSlot(operationId: OperationId, toolName: String): Result<Unit> {
        lock.lock()
        try {
            if (scheduledFrames(operationId).isSome()) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "run.tool_slot_duplicate",
                    "an Operation already owns a Run scheduler slot"))
            }
            scheduledToolSlots.add(NestedToolSlotFrames(operationId, toolName)); Result.Ok(())
        } finally { lock.unlock() }
    }

    func unregisterScheduledToolSlot(operationId: OperationId): Bool {
        lock.lock()
        try {
            let owner = match (scheduledFrames(operationId)) { case Some(value) => value; case None => return true }
            // Only the root scheduler owns ledger release. A child executor
            // cannot unregister the shared root reservation.
            if (owner.rootOperationId.value != operationId.value) { return false }
            owner.finishRoot()
            if (owner.takeRelease()) { removeScheduledFrames(owner); true } else { false }
        } finally { lock.unlock() }
    }

    private func transitionNested(operationId: OperationId,
        action: (NestedToolSlotFrames) -> Result<Unit>): Result<Unit> {
        var release = false
        lock.lock()
        let outcome = try {
            let owner = match (scheduledFrames(operationId)) {
                case Some(value) => value
                case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "run.tool_slot_not_active", "nested work requires its actual Run reservation"))
            }
            let result = action(owner)
            release = owner.takeRelease()
            if (release) { removeScheduledFrames(owner) }
            result
        } finally { lock.unlock() }
        if (release) {
            match (ledger.releaseTools()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        outcome
    }

    func beginNestedToolSlot(operationId: OperationId): Result<Unit> {
        transitionNested(operationId, { owner => owner.begin(operationId) })
    }
    func activateNestedToolSlot(operationId: OperationId): Result<Unit> {
        transitionNested(operationId, { owner => owner.activate(operationId) })
    }
    func restoreYieldedToolSlot(operationId: OperationId): Result<Unit> {
        transitionNested(operationId, { owner => owner.restore(operationId) })
    }
    func returnNestedToolSlot(operationId: OperationId): Result<Unit> {
        transitionNested(operationId, { owner => owner.returnChild(operationId) })
    }
    func derivedToolFrame(parent: OperationId, child: OperationId, name: String, entering: Bool): Result<Unit> {
        transitionNested(if (entering) { parent } else { child }, { owner =>
            if (entering) { owner.enter(parent, child, name) } else { owner.leave(child) }
        })
    }

    // Admission only: the ledger reports facts and the callers decide the
    // action. A rejected reserve no longer cancels the run — the work-turn
    // loop converts an exhausted work budget into a bounded graceful drain,
    // and only true hard violations reach the failure path.
    //
    // Model-request charges issued while the run is Draining are routed
    // into the drain ledger bucket (BudgetChargeClass.Drain): work can
    // never consume drain headroom, and the bounded drain never dies on
    // maxModelRequests. Cumulative token/cost parts of the charge stay in
    // the shared fungible buckets.
    func reserve(charge: BudgetCharge): Result<ExecutionUsage> {
        if (budgetMode() == BudgetMode.Draining &&
            charge.chargeClass == BudgetChargeClass.Work &&
            charge.modelRequests > 0) {
            return ledger.reserve(BudgetCharge(
                turns: charge.turns,
                modelRequests: charge.modelRequests,
                chargeClass: BudgetChargeClass.Drain,
                toolCalls: charge.toolCalls,
                toolsStarted: charge.toolsStarted,
                inputTokens: charge.inputTokens,
                outputTokens: charge.outputTokens,
                costMicros: charge.costMicros
            ))
        }
        ledger.reserve(charge)
    }

    func budgetMode(): BudgetMode {
        lock.lock()
        try { budgetModeValue } finally { lock.unlock() }
    }

    func enterPressure(): Bool {
        advanceBudgetMode(BudgetMode.Pressure)
    }

    func beginDraining(): Bool {
        advanceBudgetMode(BudgetMode.Draining)
    }

    func markExhausted(): Bool {
        advanceBudgetMode(BudgetMode.Exhausted)
    }

    func restoreDraining(): Unit {
        lock.lock()
        try { budgetModeValue = BudgetMode.Draining } finally { lock.unlock() }
    }

    private func advanceBudgetMode(mode: BudgetMode): Bool {
        lock.lock()
        try {
            if (budgetModeRank(mode) <= budgetModeRank(budgetModeValue)) {
                return false
            }
            budgetModeValue = mode
            true
        } finally {
            lock.unlock()
        }
    }

    private func budgetModeRank(mode: BudgetMode): Int64 {
        match (mode) {
            case BudgetMode.Normal => 0
            case BudgetMode.Pressure => 1
            case BudgetMode.Draining => 2
            case BudgetMode.Exhausted => 3
        }
    }

    func drainAttempts(): Int64 {
        lock.lock()
        try { drainAttemptsValue } finally { lock.unlock() }
    }

    func incrementDrainAttempts(): Int64 {
        lock.lock()
        try {
            drainAttemptsValue += 1
            drainAttemptsValue
        } finally { lock.unlock() }
    }

    func requestCancel(
        kind: CancellationReasonKind,
        code: String,
        message: String
    ): Bool {
        let result = source.cancel(reason: Some(CancellationReason(
            kind,
            code,
            message,
            cancelledAtMillis: agentUtcMillis()
        )))
        result
    }
}

class CoreRunControlRegistry {
    private let lock = Mutex()
    private let values = ArrayList<CoreRunControl>()

    func add(value: CoreRunControl): Result<Unit> {
        lock.lock()
        try {
            for (existing in values where existing.runId.value == value.runId.value) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.already_active",
                    "run already has an active control plane"
                ))
            }
            values.add(value)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    func collectReturnedModelInputs159(): Unit {
        // A scalar upper bound avoids a new snapshot allocation. Concurrent
        // admission/removal cannot invalidate a held control; later calls may
        // observe any shifted index. No registry lock spans Future.get.
        let count = try { lock.lock(); values.size } finally { lock.unlock() }
        for (index in 0..count) { collectModelInputControlFrame159(index) }
    }
    private func collectModelInputControlFrame159(index: Int64): Unit {
        let selected = try { lock.lock();
            if (index < values.size) { Some(values[index]) } else { None<CoreRunControl> }
        } finally { lock.unlock() }
        match (selected) { case Some(value) => value.collectReturnedModelInputs159(); case None => () }
    }
    func find(runId: RunId): ?CoreRunControl {
        lock.lock()
        try {
            for (value in values where value.runId.value == runId.value) {
                return Some(value)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    func remove(runId: RunId): ?CoreRunControl {
        lock.lock()
        try {
            for (index in 0..values.size where values[index].runId.value == runId.value) {
                let value = values[index]
                // An actual unacknowledged resource owner remains in this
                // same control registry even after a failed/cancelled Run.
                if(value.hasResultAckDebt()){return None}
                values.remove(at: index)
                return Some(value)
            }
            None
        } finally {
            lock.unlock()
        }
    }
}
