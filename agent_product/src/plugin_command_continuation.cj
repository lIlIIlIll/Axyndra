package agent_product

import agent_plugin_registry.*

import yjson.*
import yjson_support.*

import agent_core.*
import agent_domain.*
import agent_extension_runtime.reserveNativeDocumentPayload
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import std.convert.*
import std.sync.*

// Synchronous allocation handoff only; it cannot create an admission or read
// permission. Until the real owner adopts the selection, any throw releases it.
class ProductContinuationPreparationCleanup {
    private let release: () -> Unit
    private let lock = Mutex()
    private var closed = false
    private var transferred = false
    init(release: () -> Unit) { this.release = release }
    func transfer(): Unit { lock.lock(); try { if (closed) { throw IllegalStateException("selection cleanup already closed") }; transferred = true } finally { lock.unlock() } }
    func close(): Unit {
        lock.lock()
        let dispose = try { if (closed) { false } else { closed = true; !transferred } } finally { lock.unlock() }
        if (dispose) { release() }
    }
}

class ProductCommandCommitParticipant <: PluginDocumentCommitParticipant {
    let address: ContinuationAllowanceAddress
    let proposal: ProductCommandProposal
    let nextPrompt: String
    let restriction: ?ProductContinuationRestriction
    private let facts: ContinuationAllowanceRepository
    private let expected: ?ContinuationAllowanceFacts
    private let cancellation: CancellationToken
    private let lock = Mutex()
    private var actualRun: ?RunId = None
    private var actualEpoch: Int64 = 0
    private var delegate: ?SqliteContinuationCommandParticipant = None
    private var documentRevision: Int64 = 0
    private var documentDigest = ""
    private var parentOperation = ""
    private var documentOperation = ""
    private var documentConfiguration = ""
    private var documentPayload = false
    init(facts: ContinuationAllowanceRepository, address: ContinuationAllowanceAddress,
        expected: ?ContinuationAllowanceFacts, proposal: ProductCommandProposal, cancellation: CancellationToken, nextPrompt: String, restriction: ?ProductContinuationRestriction) {
        this.facts = facts; this.address = address; this.expected = expected
        this.proposal = proposal; this.cancellation = cancellation
        this.nextPrompt = nextPrompt; this.restriction = restriction
    }
    func bindActualRun(run: RunId, epoch: Int64, parentArguments!: ?String = None): Result<Unit> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let raw = proposal.control().getOrThrow()
        let action = httpIntentText(raw, "action")
        let budget: ?Int64 = match (raw.field("token_budget")) { case Some(value) =>
            if (value.unifiedKind == ValueKind.Null) { None } else { Some(Int64.parse(value.asNumberText())) }
            case None => None }
        let control = match (action) {
            case "create" => ContinuationAllowanceControl.Create("continuation-" + proposal.sourceDigest, budget)
            case "replace" => ContinuationAllowanceControl.Replace("continuation-" + proposal.sourceDigest, budget)
            case "pause" => ContinuationAllowanceControl.Pause
            case "resume" => ContinuationAllowanceControl.Resume
            case "resume_or_create" => ContinuationAllowanceControl.ResumeOrCreate("continuation-" + proposal.sourceDigest, budget)
            case "close" => ContinuationAllowanceControl.Close
            case "set_budget" => ContinuationAllowanceControl.SetBudget(budget)
            case _ => return commandControlError("plugin.command_control_invalid") }
        lock.lock()
        try {
            if (actualRun.isSome() || epoch < 1) { return commandControlError("plugin.command_participant_rebound") }
            actualRun = Some(run); actualEpoch = epoch
            delegate = Some(SqliteContinuationCommandParticipant(facts, address, expected, control, proposal.sourceDigest,
                run, epoch, proposal.call(), proposal.binding.digest, proposal.binding.generation, cancellation,
                expectedParentArguments: parentArguments))
            Result.Ok(())
        } finally { lock.unlock() }
    }
    public func consume(proof: PluginDocumentCommitProof): Result<Unit> {
        lock.lock()
        let bound = try { match (delegate) { case Some(value) => value
            case None => return commandControlError("plugin.command_participant_unbound") } } finally { lock.unlock() }
        let checked = parsePluginDocumentIntent(proof.plan().canonicalArguments)
        if (checked.isError()) { return commandControlError("continuation.document_control_mismatch") }
        match (restriction) { case Some(value) =>
            if (httpIntentText(checked.value().getOrThrow().binding(), "configuration_digest") != value.configuration.digest) {
                return commandControlError("continuation.document_control_mismatch") }
            case None => () }
        match (bound.consume(proof)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let intent = parsePluginDocumentIntent(proof.plan().canonicalArguments).value().getOrThrow()
        lock.lock()
        try {
            documentRevision = intent.expectedRevision + 1; documentPayload = intent.referencesPayload
            documentDigest = if (intent.referencesPayload) { intent.nextPayload.getOrThrow().digest } else { modelPolicySha256Text(intent.nextJson.getOrThrow()) }
            parentOperation = proof.parentOperationId.value; documentOperation = proof.operationId.value
            documentConfiguration = httpIntentText(intent.binding(), "configuration_digest")
        }
        finally { lock.unlock() }
        Result.Ok(())
    }
    func accepted(database: SqliteDatabase): Result<ContinuationAllowanceFacts> {
        lock.lock()
        let snapshot = try { (actualRun, actualEpoch, documentRevision, documentDigest, parentOperation) } finally { lock.unlock() }
        if (snapshot[0].isNone() || snapshot[2] < 1 || snapshot[3] == "") {
            return commandControlError("continuation.control_not_committed") }
        try { database.readTransaction<Result<ContinuationAllowanceFacts>>({ tx =>
            let actual = match (facts.readFacts(tx, address)) {
                case Result.Ok(Some(value)) => value; case Result.Err(error) => return Result.Err(error)
                case Result.Ok(None) => return commandControlError("continuation.control_not_committed") }
            if (actual.controlSourceDigest != proposal.sourceDigest) { return commandControlError("continuation.control_changed") }
            let rows = tx.query("SELECT o.id FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN items i ON i.id=o.tool_call_item_id JOIN operation_receipts receipt ON receipt.operation_id=o.id " +
                "WHERE o.run_id=? AND r.thread_id=? AND r.epoch=? AND o.id=? AND r.state='completed' AND o.state='committed' AND receipt.outcome='completed'",
                [SqlParameter.Text(snapshot[0].getOrThrow().value), SqlParameter.Text(address.threadId.value), SqlParameter.Int64Value(snapshot[1]), SqlParameter.Text(snapshot[4])])
            // Exactly the parent observed by the actual child proof, after its
            // canonical terminal Tx; preparation-read Operations are separate.
            if (rows.size != 1) { return commandControlError("continuation.parent_not_completed") }
            let doc = tx.query("SELECT revision FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
                [SqlParameter.Text(address.threadId.value), SqlParameter.Text(address.laneId.value), SqlParameter.Text(address.namespace), SqlParameter.Text(address.documentKey)])
            if (doc.size != 1 || doc[0].required(0) != snapshot[2].toString()) {
                return commandControlError("continuation.document_changed") }
            Result.Ok(actual)
        }) } catch (_: Exception) { commandControlError("continuation.control_verification_failed") }
    }
    func completedDocument(database: SqliteDatabase): Result<(CompletedPluginDocumentObservation, ContinuationDocumentReadScope)> {
        lock.lock()
        let snapshot = try { (documentRevision, documentOperation, documentConfiguration, documentDigest, documentPayload) } finally { lock.unlock() }
        let scope = try { ContinuationDocumentReadScope({ bytes => reserveNativeDocumentPayload(bytes) }) }
            catch (_: Exception) { return commandControlError("continuation.observation_capacity") }
        var retained = false
        try {
            let result = database.readTransaction<Result<CompletedPluginDocumentObservation>>({ tx =>
                if (snapshot[4]) {
                    let version = match (readContinuationDocumentVersion(tx, address.threadId, address.laneId, address.namespace,
                        address.documentKey, scope)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    if (version.revision != snapshot[0] || version.payload.digest != snapshot[3]) { return commandControlError("continuation.document_changed") }
                    return observeCompletedPluginDocumentPayload(tx, version, proposal.call().name, proposal.binding.digest,
                        proposal.binding.generation.toString(), snapshot[2], scope, operationId: Some(snapshot[1]))
                }
                let rows = scope.query(tx, "SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
                    [SqlParameter.Text(address.threadId.value), SqlParameter.Text(address.laneId.value), SqlParameter.Text(address.namespace), SqlParameter.Text(address.documentKey)], 2)
                if (rows.size != 1 || rows[0].required(0) != snapshot[0].toString()) { return commandControlError("continuation.document_changed") }
                observeCompletedPluginDocument(tx, PluginDocumentSnapshot(address.threadId, address.laneId, address.namespace,
                    address.documentKey, snapshot[0], rows[0].required(1)), proposal.call().name, proposal.binding.digest,
                    proposal.binding.generation.toString(), snapshot[2], scope: scope, operationId: Some(snapshot[1]))
            })
            match (result) { case Result.Err(error) => Result.Err(error)
                case Result.Ok(value) =>
                    if (value.digest != snapshot[3]) { return commandControlError("continuation.document_changed") }
                    retained = true; Result.Ok((value, scope)) }
        } catch (_: Exception) { commandControlError("continuation.document_observation_invalid") }
        finally { if (!retained) { scope.close() } }
    }
    func documentVersion(): (Int64, String) {
        lock.lock(); try { (documentRevision, documentDigest) } finally { lock.unlock() }
    }
}

// Lives only in the actual Application that consumed the user control. Audit
// facts/history/recovery descriptions never construct this owner. Revocation
// prevents the next admission; it does not cancel an already admitted Run.
class ProductContinuationOwner {
    let address: ContinuationAllowanceAddress
    let prompt: String
    private let binding: ProductCommandBinding
    private let database: SqliteDatabase
    private let facts: ContinuationAllowanceRepository
    private let eventId: Int64
    private let generation: Int64
    private let sourceDigest: String
    private let documentRevision: Int64
    private let documentDigest: String
    private var original: ?CompletedPluginDocumentObservation
    private let restriction: ?ProductContinuationRestriction
    private let queryCancellation = CancellationSource()
    private var preparing = false
    private let originalScope: ContinuationDocumentReadScope
    private var watermarkOperation: String
    private var watermarkRevision: Int64
    private var watermarkDigest: String
    private var anchorRun = ""
    private var anchorClaim = ""
    private var pendingOrigin: ?ContinuationRunOrigin = None
    private var pendingSelection: ?ProductContinuationDocumentSelection = None
    private let applicationCurrent: () -> Result<Unit>
    private let revoked = AtomicBool(false)
    private let lock = Mutex()
    private var authority: ?ContinuationRunAuthority = None
    init(participant: ProductCommandCommitParticipant, original: CompletedPluginDocumentObservation, originalScope: ContinuationDocumentReadScope, accepted: ContinuationAllowanceFacts, prompt: String,
        database: SqliteDatabase, facts: ContinuationAllowanceRepository, current: () -> Result<Unit>) {
        this.original = Some(original); this.originalScope = originalScope
        this.watermarkOperation = original.operationId; this.watermarkRevision = original.revision; this.watermarkDigest = original.digest
        this.restriction = participant.restriction
        this.address = participant.address; this.prompt = prompt; this.binding = participant.proposal.binding
        this.database = database; this.facts = facts; this.eventId = accepted.eventId; this.generation = accepted.generation
        this.sourceDigest = accepted.controlSourceDigest; this.documentRevision = participant.documentVersion()[0]
        this.documentDigest = participant.documentVersion()[1]; this.applicationCurrent = current
    }
    func revoke(): Unit {
        lock.lock(); let active = try { revoked.store(true); authority } finally { lock.unlock() }
        queryCancellation.cancel()
        match (active) { case Some(value) => value.revoke(); case None => () }
        closeRetiredObservation()
    }
    func prepare(prepared: CoreContinuationPreparation): Result<AgentContinuationStart> {
        lock.lock()
        try {
            if (revoked.load() || authority.isSome() || preparing) { return commandControlError("continuation.owner_revoked_or_busy") }
            preparing = true
        } finally { lock.unlock() }
        try {
            let window = ProductContinuationPreparationDeadline(prepared.requestCopy().budget)
            // Only this preparation can call the pure predicate. Subsequent
            // admission checks consume the exact frozen result, never retry it.
            match (advanceWatermark(window)) { case Result.Err(error) => revoke(); return Result.Err(error); case Result.Ok(_) => () }
            let selected = match (observe(prepared, window)) { case Result.Err(error) => revoke(); return Result.Err(error); case Result.Ok(value) => value }
            let handoff = ProductContinuationPreparationCleanup({ => match (selected) { case Some(value) => value.close(); case None => () } })
            try {
                lock.lock()
                let actual = try {
                    pendingSelection = selected
                    handoff.transfer()
                    window.check()
                    if (revoked.load()) { return commandControlError("continuation.owner_revoked") }
                    let value = ContinuationRunAuthority(ProductContinuationAuthorizer(this, prepared, selected))
                    authority = Some(value); value
                } finally { lock.unlock() }
                let admission = match (actual.reserve()) { case Result.Err(error) => releaseAdmission(); revoke(); return Result.Err(error); case Result.Ok(value) => value }
                lock.lock()
                try { pendingOrigin = Some(admission.origin); pendingSelection = selected } finally { lock.unlock() }
                Result.Ok(AgentContinuationStart(prepared, admission))
            } finally { handoff.close() }
        } catch (_: Exception) { releaseAdmission(); revoke(); commandControlError("continuation.restriction_failed") }
        finally { lock.lock(); try { preparing = false } finally { lock.unlock() }; closeRetiredObservation() }
    }
    func releaseAdmission(): Unit { lock.lock(); try { authority = None } finally { lock.unlock() }; closeRetiredObservation() }
    private func closeRetiredObservation(): Unit {
        lock.lock()
        let selection = try {
            if (!revoked.load() || preparing || authority.isSome()) { return }
            let value = pendingSelection; pendingSelection = None; pendingOrigin = None; original = None; value
        } finally { lock.unlock() }
        match (selection) { case Some(value) => value.close(); case None => () }
        originalScope.close()
        queryCancellation.close()
    }
    func current(): Result<Unit> {
        if (revoked.load()) { return commandControlError("continuation.owner_revoked") }
        match (applicationCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (binding.verify()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (revoked.load()) { return commandControlError("continuation.owner_revoked") }
        Result.Ok(())
    }
    // A pure-query success is not an anchor. Advance only the exact observed
    // end of a consumed admission whose actual Run has since completed. New
    // mutations produced by that Run remain in the NEXT unchecked suffix.
    private func advanceWatermark(window: ProductContinuationPreparationDeadline): Result<Unit> {
        window.check()
        lock.lock()
        let pending = try { (pendingOrigin, pendingSelection) } finally { lock.unlock() }
        if (pending[0].isNone()) { return Result.Ok(()) }
        let origin = pending[0].getOrThrow()
        let reading = try { ContinuationDocumentReadScope({ bytes => reserveNativeDocumentPayload(bytes) }, current: { => window.check() }) }
            catch (_: Exception) { return commandControlError("continuation.observation_capacity") }
        let claim = try { database.readTransaction<Result<String>>({ tx =>
            let rows = reading.query(tx, "SELECT a.payload FROM audit_events a JOIN runs r ON r.id=a.run_id AND r.thread_id=a.thread_id " +
                "JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id WHERE a.thread_id=? AND a.run_id=? " +
                "AND a.kind='host_continuation_claim_consumed_v1' AND r.epoch=? AND r.state='completed' AND t.state='completed' " +
                "AND t.active_run_id IS NULL", [SqlParameter.Text(address.threadId.value), SqlParameter.Text(origin.runId), SqlParameter.Int64Value(origin.epoch)], 1)
            if (rows.size == 1) { reading.preflightStored(rows[0].required(0)) }
            if (rows.size != 1 || canonicalAgentValue(decodeStoredValue(rows[0].required(0)).field("origin").getOrThrow()) !=
                canonicalAgentValue(continuationRunOriginValue(origin))) { return commandControlError("continuation.anchor_not_completed") }
            Result.Ok(modelPolicySha256Text(rows[0].required(0)))
        }) } catch (_: Exception) { return commandControlError("continuation.anchor_not_completed") } finally { reading.close() }
        let digest = match (claim) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        lock.lock()
        try {
            if (revoked.load()) { return commandControlError("continuation.owner_revoked") }
            match (pending[1]) { case Some(value) =>
                    watermarkOperation = value.document.operationId; watermarkRevision = value.document.revision; watermarkDigest = value.document.digest
                    anchorRun = origin.runId; anchorClaim = digest
                case None => () }
            pendingOrigin = None; pendingSelection = None
            Result.Ok(())
        } finally { lock.unlock(); match (pending[1]) { case Some(value) => value.close(); case None => () } }
    }
    // A private historical upload can exist only during this actual owner's
    // preparation. It cannot be replayed from a stored observation or claim.
    func validatePayloadReadSource(expectedOwner: String, originalOperation: String, originalReceipt: String): Result<Unit> {
        lock.lock()
        try {
            if (!preparing || authority.isSome() || revoked.load() || expectedOwner != sourceDigest || original.isNone() ||
                original.getOrThrow().operationId != originalOperation || original.getOrThrow().receiptId != originalReceipt) {
                return commandControlError("continuation.payload_owner_changed") }
        } finally { lock.unlock() }
        match(applicationCurrent()) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let mounted=match(binding.host.servicePackage(binding.namespace,binding.generation)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        try {
            if (!mounted.textEquals(PluginDescriptorText.ContentDigest, binding.digest) || revoked.load()) {
                return commandControlError("continuation.payload_owner_changed") }
            Result.Ok(())
        } finally { mounted.close() }
    }
    // Pure local check for the already-held authority/SQLite admission window.
    // The full binding/facts checks remain outside or in their supplied Tx.
    func validateStartWindow(selected:?ProductContinuationDocumentSelection):Result<Unit> {
        if(revoked.load() || queryCancellation.token.isCancelled()) {return commandControlError("continuation.owner_revoked")}
        try {match(selected){case Some(value)=>value.window.check();case None=>()};Result.Ok(())}
        catch(_:Exception){commandControlError("continuation.restriction_timeout")}
    }
    // Same supplied transaction as the historical proof. This check has no
    // Host/Runtime lock or file access; only the original immutable owner and
    // canonical Host allowance facts may admit the read.
    func validatePayloadReadFacts(transaction: SqliteTransaction, expectedOwner: String): Result<Unit> {
        if (revoked.load() || queryCancellation.token.isCancelled() || expectedOwner != sourceDigest) {
            return commandControlError("continuation.payload_owner_changed") }
        continuationPayloadFactsCurrent(transaction,facts,address,eventId,generation,sourceDigest)
    }
    private func observe(prepared: CoreContinuationPreparation, window: ProductContinuationPreparationDeadline): Result<?ProductContinuationDocumentSelection> {
        window.check()
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let selected = match (restriction) { case None => return Result.Ok(Option<ProductContinuationDocumentSelection>.None); case Some(value) => value }
        match (selected.current(address.documentKey)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        let anchor = try { (watermarkOperation, watermarkRevision, watermarkDigest, anchorRun, anchorClaim, original.getOrThrow()) } finally { lock.unlock() }
        let reading = try { ContinuationDocumentReadScope({ bytes => reserveNativeDocumentPayload(bytes) }, current: { => window.check() }) }
            catch (_: Exception) { return commandControlError("continuation.observation_capacity") }
        var retained = false
        try {
        let observed = try { database.readTransaction<Result<(Array<CompletedPluginDocumentObservation>, Int64)>>({ tx =>
            let actual = match (facts.readFacts(tx, address)) { case Result.Ok(Some(value)) => value
                case Result.Err(error) => return Result.Err(error); case Result.Ok(None) => return commandControlError("continuation.control_missing") }
            if (!actual.hasRemainingTokens() || actual.eventId != eventId || actual.generation != generation || actual.controlSourceDigest != sourceDigest) {
                return commandControlError("continuation.control_changed_or_exhausted") }
            if (anchor[5].payload.isSome()) {
                let version = match (readContinuationDocumentVersion(tx, address.threadId, address.laneId, address.namespace,
                    address.documentKey, reading)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                match (observeContinuationDocumentPayloadChain(tx, version, anchor[0], anchor[1], anchor[2],
                    selected.parentTool, binding.digest, binding.generation.toString(), selected.configuration.digest, reading)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(value) => return Result.Ok((value, actual.observedTotalTokens)) }
            }
            let rows = reading.query(tx, "SELECT revision,payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
                [SqlParameter.Text(address.threadId.value), SqlParameter.Text(address.laneId.value), SqlParameter.Text(address.namespace), SqlParameter.Text(address.documentKey)], 2)
            if (rows.size != 1 || Int64.parse(rows[0].required(0)) < anchor[1]) { return commandControlError("continuation.document_changed") }
            let snapshot = PluginDocumentSnapshot(address.threadId, address.laneId, address.namespace, address.documentKey,
                Int64.parse(rows[0].required(0)), rows[0].required(1))
            match (observeContinuationDocumentChain(tx, snapshot, anchor[0], anchor[1], anchor[2],
                selected.parentTool, binding.digest, binding.generation.toString(), selected.configuration.digest, scope: reading)) {
                case Result.Err(error) => Result.Err(error); case Result.Ok(value) => Result.Ok((value, actual.observedTotalTokens)) }
        }) } catch (_: Exception) { return commandControlError("continuation.document_observation_invalid") }
        let frozen = match (observed) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (anchor[5].payload.isSome()) {
            let reader = ProductContinuationPayloadReader(this, database, address, selected, anchor[5], frozen[0],
                sourceDigest, queryCancellation.token, window)
            try {
                match (restrictProductContinuationPayload(selected, sourceDigest, anchor[5], frozen[0], address.threadId,
                    address.documentKey, frozen[1], queryCancellation.token, "continuation-restriction-" + prepared.requestCopy().runId.value,
                    anchor[3], anchor[4], reading, window, reader, prepared.requestCopy().budget.processLimits)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(value) => retained = true; return Result.Ok(Some(value)) }
            } finally { reader.close() }
        }
        match (restrictProductContinuation(selected, sourceDigest, anchor[5], frozen[0], address.threadId, address.documentKey,
            frozen[1], queryCancellation.token, "continuation-restriction-" + prepared.requestCopy().runId.value, anchor[3], anchor[4], reading, window)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(value) => retained = true; Result.Ok(Some(value)) }
        } finally { if (!retained) { reading.close() } }
    }
    func origin(prepared: CoreContinuationPreparation, selected: ?ProductContinuationDocumentSelection): Result<ContinuationRunOrigin> {
        try { match (selected) { case Some(value) => value.window.check(); case None => () } }
        catch (_: Exception) { return commandControlError("continuation.restriction_timeout") }
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (restriction) { case Some(value) =>
            // Called under the actual admission authority mutex. Return the
            // failure; its outer owner retires only after that mutex unwinds.
            match (value.current(address.documentKey)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => () }
        let request = prepared.requestCopy()
        if (request.sessionId.value != address.threadId.value || request.executionLaneId.value != address.laneId.value || request.prompt != prompt) {
            return commandControlError("continuation.request_changed") }
        let reading = try { ContinuationDocumentReadScope({ bytes => reserveNativeDocumentPayload(bytes) },
            current: { => match (selected) { case Some(value) => value.window.check(); case None => () } }) }
            catch (_: Exception) { return commandControlError("continuation.observation_capacity") }
        try { database.readTransaction<Result<ContinuationRunOrigin>>({ tx =>
            let actual = match (facts.readFacts(tx, address)) {
                case Result.Ok(Some(value)) => value; case Result.Err(error) => return Result.Err(error)
                case Result.Ok(None) => return commandControlError("continuation.control_missing") }
            if (revoked.load() || !actual.hasRemainingTokens() || actual.eventId != eventId || actual.generation != generation ||
                actual.controlSourceDigest != sourceDigest) { return commandControlError("continuation.control_changed_or_exhausted") }
            let version = match (readContinuationDocumentVersion(tx, address.threadId, address.laneId, address.namespace,
                address.documentKey, reading)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let revision = match (selected) { case Some(value) => value.document.revision; case None => documentRevision }
            let digest = match (selected) { case Some(value) => value.document.digest; case None => documentDigest }
            if (version.revision != revision || version.payload.digest != digest) { return commandControlError("continuation.document_changed") }
            match (selected) { case Some(value) =>
                if (actual.observedTotalTokens.toString() != value.observation.value().field("total_tokens").getOrThrow().asNumberText()) {
                    return commandControlError("continuation.observed_statistics_changed") }
                match (verifyContinuationDocumentObservation(tx, address.threadId, address.laneId, address.namespace,
                    address.documentKey, sourceDigest, value.observation, scope: reading)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                case None => () }
            let thread = tx.query("SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id=? AND status='open'", [SqlParameter.Text(address.threadId.value)])
            let previous = tx.query("SELECT r.id,r.epoch,r.state FROM runs r JOIN turns t ON t.id=r.turn_id AND t.thread_id=r.thread_id " +
                "WHERE r.thread_id=? ORDER BY t.ordinal DESC LIMIT 1", [SqlParameter.Text(address.threadId.value)])
            if (thread.size != 1 || thread[0].required(1) != "" || previous.size != 1 || previous[0].required(2) != "completed") {
                return commandControlError("continuation.previous_run_not_completed") }
            Result.Ok(ContinuationRunOrigin(address.threadId.value, address.laneId.value, address.namespace, address.documentKey,
                actual.allowanceId, actual.payloadDigest(), sourceDigest, previous[0].required(0), request.runId.value,
                "turn-" + request.runId.value, "continuation-" + request.runId.value, prepared.requestDigest, prepared.launchDigest,
                actual.generation, actual.eventId, Int64.parse(thread[0].required(0)), Int64.parse(previous[0].required(1)) + 1,
                documentObservation: match (selected) { case Some(value) => Some(value.observation); case None => Option<ContinuationDocumentObservation>.None }))
        }) } catch (_: Exception) { commandControlError("continuation.admission_snapshot_failed") } finally { reading.close() }
    }
}

class ProductContinuationAuthorizer <: ContinuationRunAuthorizer {
    private let owner: ProductContinuationOwner
    private let prepared: CoreContinuationPreparation
    private let selected: ?ProductContinuationDocumentSelection
    init(owner: ProductContinuationOwner, prepared: CoreContinuationPreparation, selected: ?ProductContinuationDocumentSelection) {
        this.owner = owner; this.prepared = prepared; this.selected = selected
    }
    public func authorizeNextRun(): Result<ContinuationRunOrigin> { owner.origin(prepared, selected) }
    public func validateStartWindow(_:ContinuationRunOrigin):Result<Unit> {owner.validateStartWindow(selected)}
    public func validateCurrent(origin: ContinuationRunOrigin): Result<Unit> {
        match (owner.origin(prepared, selected)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(actual) => if (canonicalAgentValue(continuationRunOriginValue(actual)) == canonicalAgentValue(continuationRunOriginValue(origin))) { Result.Ok(()) }
                else { commandControlError("continuation.admission_changed") } }
    }
}
