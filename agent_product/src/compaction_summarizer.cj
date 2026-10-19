package agent_product

import agent_domain.*
import agent_domain.CancellationSource as CompactionCancellationSource
import agent_core.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class ProductCompactionOverview {
    let text: String
    let provenance: AgentValue
    private let owned: ProductPolicyValueLease
    init(text: String, binding: ProductPluginPolicyBinding, configuration: String) {
        let copy = retainProductPolicyData(objectValue([ValueField("text", textValue(text)),
            ValueField("provenance", objectValue([ValueField("namespace", textValue(binding.namespace)),
                ValueField("provider", textValue(binding.contribution)), ValueField("package_digest", textValue(binding.digest)),
                ValueField("configuration_digest", textValue(configuration)), ValueField("authoritative", boolValue(false))]))]))
        this.owned = copy; this.text = copy.value.field("text").getOrThrow().text
        this.provenance = copy.value.field("provenance").getOrThrow()
    }
    func close(): Unit { owned.close() }
}

// Callers retain this owner until the actual model/checkpoint consumer finishes.
// close() releases its data charge and is idempotent; validate rejects reuse.
public class ProductCompactionStructure {
    let text: String
    let provenance: AgentValue
    private let owned: ProductPolicyValueLease
    private let verify: () -> Result<Unit>
    init(text: String, provenance: AgentValue, verify: () -> Result<Unit>) {
        let copy = retainProductPolicyData(objectValue([ValueField("text", textValue(text)), ValueField("provenance", provenance)]))
        this.owned = copy; this.text = copy.value.field("text").getOrThrow().text
        this.provenance = copy.value.field("provenance").getOrThrow(); this.verify = verify
    }
    func validate(): Result<Unit> {
        if (!owned.available()) { return productPolicySelectionError("compaction.result_released") }; verify()
    }
// This local data check takes no Host, Registry or database lock.
    // The enclosing actual Host current-data gate holds the publication fence.
    func validateRetainedData113(): Result<Unit> {
        if (!owned.available()) { return productPolicySelectionError<Unit>("compaction.result_released") }
        Result<Unit>.Ok(())
    }
    public func close(): Unit { owned.close() }
}

class ProductCompactedMessages {
    let messages: Array<ModelMessage>
    private let structure: ProductCompactionStructure
    init(messages: Array<ModelMessage>, structure: ProductCompactionStructure) {
        this.messages = messages; this.structure = structure
    }
    func close(): Unit { structure.close() }
}

class ProductCompactionScope {
    let token: CancellationToken
    private let release: () -> Unit
    private let lock = Mutex()
    private var closed = false
    init(token: CancellationToken, release: () -> Unit) { this.token = token; this.release = release }
    func close(): Unit {
        lock.lock()
        let owned = try { if (closed) { false } else { closed = true; true } } finally { lock.unlock() }
        if (owned) { release() }
    }
}

interface CompactionSummarizer {
    func openScope(sessionId: SessionId): ProductCompactionScope
    func structure(sessionId: SessionId, messages: Array<ModelMessage>, goal: AgentValue,
        todos: AgentValue, timeoutMillis: Int64, parentCancellation: ?CancellationToken): Result<ProductCompactionStructure>
    func summarize(parent: AgentRunRequest, structuredFacts: String, timeoutMillis: Int64,
        maxOutputTokens: Int64, parentCancellation: ?CancellationToken): Result<?ProductCompactionOverview>
    func checkpoint(context: ToolInvocationContext, call: ToolCall, loadThread: () -> Result<AgentThreadSnapshot>, timestamp: () -> String): Result<ToolResult>
    func checkpointRetainIndex173(sessionId: SessionId, messages: Array<ModelMessage>, cancellation: CancellationToken): Result<Int64>
    func checkpointRetainOrdinal173(sessionId: SessionId, expected: ThreadRecord, database: SqliteDatabase,
        cancellation: CancellationToken): Result<Int64>
    func checkpointRetentionFailure173(sessionId: SessionId, cancellation: CancellationToken): Result<Unit>
    func cancel(sessionId: SessionId): Result<Unit>
}

// The installed policy proposes prompts and interprets the observed reply.
// Only the existing canonical internal-model port can dispatch/account a call;
// Product independently retains checkpoint facts, legal cut and input limits.
class InstalledCompactionSummarizer <: CompactionSummarizer & OwnedCompactionMaintenanceFailureReader173 & OwnedCompletedThreadForkData173d {
    private let modelControl: ControlledModelPort
    private let host: ProductJavaScriptPluginHost
    private let settingsRoot: String
    private let requestLock = Mutex()
    private var requestCounter: Int64 = 0
    private let active = ArrayList<ActiveCompactionSummary>()
    private let heldCheckpointRetention173 = ArrayList<NativeCheckpointRetentionHeld173>()
    init(modelControl: ControlledModelPort, host: ProductJavaScriptPluginHost, settingsRoot: String) {
        this.modelControl = modelControl; this.host = host; this.settingsRoot = settingsRoot
    }
    // One cancellation owner spans proposal, optional overview and canonical
    // commit. Individual provider/model deadlines remain per phase, as before.
    public func openScope(sessionId: SessionId): ProductCompactionScope {
        let requestId = nextRequestId(sessionId)
        let source = CompactionCancellationSource()
        let entry = ActiveCompactionSummary(sessionId.value, requestId, source)
        requestLock.lock(); try { active.add(entry) } finally { requestLock.unlock() }
        ProductCompactionScope(source.token, { =>
            requestLock.lock(); try {
                for (index in 0..active.size where active[index].requestId == requestId) { active.remove(at: index); break }
            } finally { requestLock.unlock() }
            source.close()
        })
    }
    func retainCheckpointFailure173(value: NativeCheckpointRetentionHeld173): Unit {
        requestLock.lock(); try { heldCheckpointRetention173.add(value) } finally { requestLock.unlock() }
    }
    private func findMaintenanceFailure173(session: SessionId, marker: AgentError): ?NativeCheckpointRetentionHeld173 {
        requestLock.lock(); try {
            for (value in heldCheckpointRetention173) {
                if (value.matches173(session, marker)) { return Some(value) }
            }
            None<NativeCheckpointRetentionHeld173>
        } finally { requestLock.unlock() }
    }
    public func hasMaintenanceFailure173(session: SessionId, marker: AgentError): Bool {
        match (findMaintenanceFailure173(session, marker)) {
            case Some(actual) => actual.available173(); case None => false }
    }
    public func admitMaintenanceFailure173(session: SessionId, marker: AgentError,
        accept: (OwnedAgentRunResult113) -> Bool): Bool {
        match (findMaintenanceFailure173(session, marker)) {
            case Some(actual) => actual.admit173(accept); case None => false }
    }
    public func takeMaintenanceFailure173(session: SessionId, marker: AgentError): ?OwnedAgentRunResult113 {
        match (findMaintenanceFailure173(session, marker)) {
            case Some(actual) => actual.take173(); case None => None<OwnedAgentRunResult113> }
    }
    private func detachOneReturnedMaintenanceFailure173(): ?LogicalJsonOwnerReservation {
        requestLock.lock(); try {
            for (index in 0..heldCheckpointRetention173.size) {
                let detached = heldCheckpointRetention173[index].detachReturned173()
                if (detached.isSome()) {
                    heldCheckpointRetention173.remove(at: index)
                    return detached
                }
            }
            None<LogicalJsonOwnerReservation>
        } finally { requestLock.unlock() }
    }
    public func collectMaintenanceFailures173(): Unit {
        while (true) {
            // The helper and removed cell references have actually returned
            // before refunding that cleared cell's original metadata owner.
            match (detachOneReturnedMaintenanceFailure173()) {
                case Some(actual) => actual.close(); case None => return }
        }
    }
    public func checkpointRetainIndex173(sessionId: SessionId, messages: Array<ModelMessage>, cancellation: CancellationToken): Result<Int64> {
        queryNativeModelCheckpointRetention173(host, settingsRoot, sessionId, messages, cancellation,
            { value => retainCheckpointFailure173(value) }, { => collectMaintenanceFailures173() })
    }
    public func checkpointRetainOrdinal173(sessionId: SessionId, expected: ThreadRecord, database: SqliteDatabase,
        cancellation: CancellationToken): Result<Int64> {
        queryNativeCanonicalCheckpointRetention173(host, settingsRoot, sessionId, expected, database, cancellation,
            { value => retainCheckpointFailure173(value) }, { => collectMaintenanceFailures173() })
    }
    public func checkpointRetentionFailure173(sessionId: SessionId, cancellation: CancellationToken): Result<Unit> {
        queryNativeCheckpointRetentionError173(host, settingsRoot, sessionId, cancellation,
            { value => retainCheckpointFailure173(value) }, { => collectMaintenanceFailures173() })
    }
    public func forkCompletedThreadData173d(source: SessionId, target: SessionId, workspace: String,
        database: SqliteDatabase, cancellation: CancellationToken): Result<Unit> {
        withNativeCheckpointRetention173<Unit>(host, settingsRoot, source, cancellation,
            { value => retainCheckpointFailure173(value) }, { => collectMaintenanceFailures173() }, { query, owner =>
                // Enter Host/Registry first. The Store TX's current callback is
                // the original local witness, never a reverse Host/DB lock.
                query.consumeCurrentData113({ current =>
                    SqliteOwnedCompletedThreadFork173d(database).fork173d(ThreadId(source.value), ThreadId(target.value),
                        workspace, owner, current)
                })
            })
    }
    public func structure(sessionId: SessionId, messages: Array<ModelMessage>, goal: AgentValue,
        todos: AgentValue, timeoutMillis: Int64, parentCancellation: ?CancellationToken): Result<ProductCompactionStructure> {
        let requestId = nextRequestId(sessionId)
        let source = CompactionCancellationSource(parent: parentCancellation, deadlineMillis: agentUtcMillis() + timeoutMillis)
        let entry = ActiveCompactionSummary(sessionId.value, requestId, source)
        requestLock.lock(); try { active.add(entry) } finally { requestLock.unlock() }
        let snapshotOwner = ProductPolicyDataReferences(modelPolicySha256Text(requestId + ":snapshot"))
        try {
            let selection = match (loadProductPolicySelection(settingsRoot, "compaction")) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            // Reuse the provider-neutral domain codec. This container is only
            // a history projection; it is never admitted or sent to a model.
            let diagnosticCapture = MonoTime.now()
            let projection = snapshotOwner.captureProjection(ModelRequest("compaction-history", messages))
            compactionDiagnosticRecord("capture", diagnosticCapture)
            let facts = objectValue([ValueField("projection", projection),
                ValueField("goal", snapshotOwner.freeze(goal)), ValueField("todos", snapshotOwner.freeze(todos))])
            let frozen = match (modelRequestFromSnapshotValue(facts.field("projection").getOrThrow(), "")) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            let diagnosticDigest = MonoTime.now()
            let digest = ProductPolicyDataDigest().digest(facts)
            compactionDiagnosticRecord("digest", diagnosticDigest)
            let response = match (queryProductCompactionHistory(host, selection, frozen.messages, facts.field("goal").getOrThrow(), facts.field("todos").getOrThrow(), digest,
                ThreadId(sessionId.value), source.token, requestId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            try {
                match (selection.validateBinding(host, response.binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (source.token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (!httpIntentExactFields(response.value, ["snapshot_digest", "summary"]) ||
                    httpIntentText(response.value, "snapshot_digest") != digest ||
                    response.value.field("summary").getOrThrow().unifiedKind != ValueKind.Text) {
                    return productPolicySelectionError("compaction.structure_invalid") }
                let text = httpIntentText(response.value, "summary")
                let binding = response.binding
                let provenance = objectValue([ValueField("namespace", textValue(binding.namespace)),
                    ValueField("provider", textValue(binding.contribution)), ValueField("package_digest", textValue(binding.digest)),
                    ValueField("configuration_digest", textValue(selection.configurationDigest)),
                    ValueField("source_projection_digest", textValue(digest)), ValueField("authoritative", boolValue(false))])
                match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (source.token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                Result.Ok(ProductCompactionStructure(text, provenance, { =>
                    match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    // The pure phase is complete. Keep the caller's cancellation
                    // alive through consumption without extending the completed
                    // phase's deadline across a separately budgeted model call.
                    match (parentCancellation) { case Some(token) => token.check(); case None => Result.Ok(()) }
                }))
            } finally { response.close() }
        } catch (_: Exception) { productPolicySelectionError("compaction.structure_invalid") }
        finally {
            snapshotOwner.close()
            requestLock.lock(); try {
                for (index in 0..active.size where active[index].requestId == requestId) { active.remove(at: index); break }
            } finally { requestLock.unlock() }
            source.close()
        }
    }
    public func summarize(parent: AgentRunRequest, structuredFacts: String, timeoutMillis: Int64,
        maxOutputTokens: Int64, parentCancellation: ?CancellationToken): Result<?ProductCompactionOverview> {
        let requestId = nextRequestId(parent.sessionId)
        let source = CompactionCancellationSource(parent: parentCancellation, deadlineMillis: agentUtcMillis() + timeoutMillis)
        let entry = ActiveCompactionSummary(parent.sessionId.value, requestId, source)
        requestLock.lock(); try { active.add(entry) } finally { requestLock.unlock() }
        var referenceOwner: ?ProductCompactionReferenceQuery = None
        let started = MonoTime.now()
        try {
            let selection = match (loadProductPolicySelection(settingsRoot, "compaction")) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let binding = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let query = ProductCompactionReferenceQuery(host, selection,
                ProductPolicyDataDigest().digest(textValue(structuredFacts)), ThreadId(parent.sessionId.value), source.token, requestId, binding)
            referenceOwner = Some(query)
            let facts = query.references.intern(structuredFacts)
            let value = query.query("prepare_reference", [ValueField("facts", facts), ValueField("model", textValue(parent.model)),
                ValueField("max_output_tokens", integerValue(maxOutputTokens))])
            if (!httpIntentExactFields(value, ["model", "system", "user_recipe", "thinking"]) ||
                httpIntentText(value, "model") != parent.model || httpIntentText(value, "thinking") != "low" ||
                value.field("system").getOrThrow().unifiedKind != ValueKind.Text || httpIntentText(value, "system").size > 65536) {
                return productPolicySelectionError("compaction.proposal_invalid") }
            let request = ModelRequest(parent.model,
                [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text,
                    text: query.references.compose(value.field("user_recipe").getOrThrow(), 8388608))])],
                system: httpIntentText(value, "system"), tools: [], thinking: ThinkingLevel.Low,
                maxOutputTokens: maxOutputTokens, streaming: false, parallelToolCalls: false, requestId: requestId,
                serviceTier: parent.serviceTier, cachePolicy: parent.cachePolicy, cacheKey: parent.cacheKey,
                toolChoice: ModelToolChoice.NoTools)
            // The complete neutral request envelope must remain decodable; a
            // data recipe is not permission to bypass the model/store bound.
            if (!productPolicyJsonFits(modelRequestSnapshotValue(request), 8388608, 65536)) {
                return productPolicySelectionError("compaction.request_capacity") }
            query.check()
            let remaining = timeoutMillis - (MonoTime.now() - started).toMilliseconds()
            if (remaining < 1) { return productPolicySelectionError("compaction.deadline_exceeded") }
            let outcome = modelControl.executeInternal(request, InternalModelCallOptions(
                purpose: Some(InternalModelPurpose.ContextCompaction), parent: Some(parent), standaloneAccounting: true,
                timeoutMillis: remaining, maxAttempts: if (parent.autoRetry) { 2 } else { 1 }, cancellation: Some(source.token)))
            match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let reply = match (outcome) {
                case Result.Err(error) =>
                    compactionDiagnosticError(error.code)
                    // Cancellation or unsettled ownership cannot be disguised
                    // as a usable checkpoint. Ordinary provider failure keeps
                    // the documented deterministic-only fallback.
                    let timedOut = match (source.token.reason()) {
                        case Some(reason) => reason.kind == CancellationReasonKind.Deadline; case None => false }
                    if ((error.kind == AgentErrorKind.Cancelled && !timedOut) || error.kind == AgentErrorKind.RecoveryRequired ||
                        error.kind == AgentErrorKind.BudgetExceeded) { return Result.Err(error) }
                    if (!timedOut) {
                        match (source.token.check()) { case Result.Err(cancelled) => return Result.Err(cancelled); case Result.Ok(_) => () }
                    }
                    return Result.Ok(Option<ProductCompactionOverview>.None)
                case Result.Ok(value) => value
            }
            match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let finalized = productCompactionOverviewFromReferences(query, reply, maxOutputTokens)
            query.check()
            if (!httpIntentExactFields(finalized, ["overview"])) { return productPolicySelectionError("compaction.proposal_invalid") }
            let overview = finalized.field("overview").getOrThrow()
            if (overview.unifiedKind == ValueKind.Null) { query.check(); return Result.Ok(Option<ProductCompactionOverview>.None) }
            if (overview.unifiedKind != ValueKind.Text || overview.text.trimAscii() == "" ||
                overview.text.toRuneArray().size > max(64, maxOutputTokens * 4) + 1) {
                return productPolicySelectionError("compaction.proposal_invalid") }
            query.check()
            Result.Ok(Some(ProductCompactionOverview(overview.text, binding, selection.configurationDigest)))
        } catch (error: ProductCompactionDataError) { Result.Err(error.error) }
        catch (_: Exception) { productPolicySelectionError("compaction.proposal_invalid") }
        finally {
            match (referenceOwner) { case Some(query) => query.close(); case None => () }
            requestLock.lock(); try {
                for (index in 0..active.size where active[index].requestId == requestId) { active.remove(at: index); break }
            } finally { requestLock.unlock() }
            source.close()
        }
    }
    public func checkpoint(context: ToolInvocationContext, call: ToolCall,
        loadThread: () -> Result<AgentThreadSnapshot>, timestamp: () -> String): Result<ToolResult> {
        let requestId = nextRequestId(context.sessionId)
        let source = CompactionCancellationSource(parent: Some(context.cancellation))
        let entry = ActiveCompactionSummary(context.sessionId.value, requestId, source)
        requestLock.lock(); try { active.add(entry) } finally { requestLock.unlock() }
        try {
            let selection = match (loadProductPolicySelection(settingsRoot, "compaction")) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let binding = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            match (source.token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            queryProductCheckpointPolicy113(host, selection, binding, context, call, loadThread, timestamp, requestId, source.token)
        } finally {
            requestLock.lock(); try {
                for (index in 0..active.size where active[index].requestId == requestId) { active.remove(at: index); break }
            } finally { requestLock.unlock() }
            source.close()
        }
    }
    public func checkpointSave113(context: ToolInvocationContext, result: ToolResult,
        loadThread: () -> Result<AgentThreadSnapshot>,
        summary: (SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure>,
        consume: (AgentThreadSnapshot, Int64, String, AgentValue, () -> Result<Unit>) -> Result<Unit>): Result<Unit> {
        let requestId = nextRequestId(context.sessionId)
        let source = CompactionCancellationSource(parent: Some(context.cancellation))
        let entry = ActiveCompactionSummary(context.sessionId.value, requestId, source)
        requestLock.lock(); try { active.add(entry) } finally { requestLock.unlock() }
        try {
            let selection = match (loadProductPolicySelection(settingsRoot, "compaction")) {
                case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
            let binding = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
                case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
            match (source.token.check()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
            match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
            queryProductCheckpointSavePolicy113(host, selection, binding, context, result,
                loadThread, summary, consume, requestId, source.token)
        } finally {
            requestLock.lock(); try {
                for (index in 0..active.size where active[index].requestId == requestId) { active.remove(at: index); break }
            } finally { requestLock.unlock() }
            source.close()
        }
    }
    public func cancel(sessionId: SessionId): Result<Unit> {
        // Cancel every in-flight phase for this session. Callback invocation is
        // outside the collection mutex and the same token spans both policies
        // and the model registration, including cancel-before-dispatch.
        let selected = ArrayList<ActiveCompactionSummary>()
        requestLock.lock(); try {
            for (entry in active where entry.sessionId == sessionId.value) { selected.add(entry) }
        } finally { requestLock.unlock() }
        for (entry in selected) { let _ = entry.source.cancel() }
        Result.Ok(())
    }
    // Actual installation uses this paid cursor path for a current Run. Its
    // complete error consumer leaves the request alive until every query and
    // SQL callback has returned; retirement of request cancellation is not an
    // ACK of the independently retained failure data.
    public func checkpointSaveOwned113(context: ToolInvocationContext, result: ToolResult,
        cursor: SqlitePaidCanonicalThreadCursor113, allocate: (Int64) -> LogicalJsonOwnerReservation,
        timeoutMillis: Int64, consume: ProductOwnedCheckpointProjectionConsumer113): OwnedFailureDataOutcome113<Unit> {
        let requestId = nextRequestId(context.sessionId)
        let source = CompactionCancellationSource(parent: Some(context.cancellation))
        let entry = ActiveCompactionSummary(context.sessionId.value, requestId, source)
        requestLock.lock(); try { active.add(entry) } finally { requestLock.unlock() }
        try {
            let selection = match (loadProductPolicySelection(settingsRoot, "compaction")) {
                case Result.Err(error) => return captureOwnedFailureData113<Unit>(error, allocate)
                case Result.Ok(value) => value }
            let binding = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
                case Result.Err(error) => return captureOwnedFailureData113<Unit>(error, allocate)
                case Result.Ok(value) => value }
            match (source.token.check()) { case Result.Err(error) => return captureOwnedFailureData113<Unit>(error, allocate)
                case Result.Ok(_) => () }
            match (selection.validateBinding(host, binding)) {
                case Result.Err(error) => return captureOwnedFailureData113<Unit>(error, allocate); case Result.Ok(_) => () }
            queryProductOwnedCheckpointSave113(host, selection, binding, context, result,
                cursor, allocate, timeoutMillis, consume, requestId, source.token)
        } catch (failure: OwnedCanonicalPaidFailure113) { OwnedFailureDataOutcome113<Unit>.Failure(failure.takeConsumer()) }
        catch (failure: OwnedCanonicalDataFailure113) { captureOwnedFailureData113<Unit>(failure.error, allocate) }
        catch (failure: ProductCompactionDataError) { captureOwnedFailureData113<Unit>(failure.error, allocate) }
        finally {
            requestLock.lock(); try {
                for (index in 0..active.size where active[index].requestId == requestId) { active.remove(at: index); break }
            } finally { requestLock.unlock() }
            source.close()
        }
    }
    private func nextRequestId(sessionId: SessionId): String {
        requestLock.lock(); try {
            requestCounter += 1
            "compaction-summary-" + sessionId.value + "-" + requestCounter.toString()
        } finally { requestLock.unlock() }
    }
}

class ActiveCompactionSummary {
    let sessionId: String
    let requestId: String
    let source: CompactionCancellationSource
    init(sessionId: String, requestId: String, source: CompactionCancellationSource) {
        this.sessionId = sessionId; this.requestId = requestId; this.source = source
    }
}
