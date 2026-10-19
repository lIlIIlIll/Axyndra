package agent_product

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import std.convert.*
import std.collection.*
import std.time.*

// One monotonic preparation window, never renewed by another predicate call.
// The future Run's shorter declared wall/deadline limit can only restrict it.
class ProductContinuationPreparationDeadline {
    let deadline: MonoTime
    init(budget: ResourceBudget) {
        var millis: Int64 = 5000
        if (budget.maxWallMillis > 0) { millis = min(millis, budget.maxWallMillis) }
        if (budget.deadlineMillis > 0) { millis = min(millis, budget.deadlineMillis - nowMillis()) }
        if (millis <= 0) { throw IllegalStateException("continuation observation deadline expired") }
        deadline = MonoTime.now() + Duration.millisecond * millis
    }
    func check(): Unit {
        if (MonoTime.now() >= deadline) { throw IllegalStateException("continuation observation deadline expired") }
    }
}

// Frozen by the actual Command scope and shown with the user control. This
// never grants a document read or Provider service: the retained exact operator
// read right and pure zero-service Provider are revalidated independently.
class ProductContinuationRestriction {
    let command: ProductCommandBinding
    let configuration: ProductPluginDocumentConfiguration
    let provider: String
    let parentTool: String
    private let selectorJson: String
    init(command: ProductCommandBinding, configuration: ProductPluginDocumentConfiguration,
        provider: String, parentTool: String, selector: AgentValue) {
        this.command = command; this.configuration = configuration; this.provider = provider
        this.parentTool = parentTool; this.selectorJson = encodeAgentValue(selector)
    }
    func selector(): AgentValue { decodeAgentValue(selectorJson, maxBytes: 4096).value().getOrThrow() }
    func current(key: String): Result<Unit> {
        match (command.verify()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (configuration.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let prefix = "plugin." + command.namespace + "."
        if (!parentTool.startsWith(prefix) || !configuration.permits(parentTool[prefix.size..], key, false)) {
            return commandControlError("continuation.document_read_revoked") }
        let actual = match (command.host.policyProviderBinding(command.namespace, provider)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (actual.digest != command.digest || actual.generation != command.generation) {
            return commandControlError("continuation.restriction_changed") }
        Result.Ok(())
    }
}

func commandContinuationRestriction(proposal: ProductCommandProposal): Result<?ProductContinuationRestriction> {
    let control = proposal.control().getOrThrow()
    let raw = match (control.field("restriction")) { case None => return Result.Ok(Option<ProductContinuationRestriction>.None); case Some(value) => value }
    let configuration = match (proposal.binding.host.documentConfiguration(proposal.binding.namespace, proposal.binding.digest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let result = ProductContinuationRestriction(proposal.binding, configuration, httpIntentText(raw, "provider"),
        proposal.call().name, raw.field("selector").getOrThrow())
    match (result.current(httpIntentText(control, "document_key"))) {
        case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(Some(result)) }
}

class ProductContinuationDocumentSelection {
    let observation: ContinuationDocumentObservation
    let document: CompletedPluginDocumentObservation
    private let allocation: ContinuationDocumentReadScope
    let window: ProductContinuationPreparationDeadline
    init(observation: ContinuationDocumentObservation, document: CompletedPluginDocumentObservation, allocation: ContinuationDocumentReadScope,
        window: ProductContinuationPreparationDeadline) {
        this.observation = observation; this.document = document; this.allocation = allocation; this.window = window
    }
    func close(): Unit { allocation.close() }
}

// Pure callback outside ALL Store/Runtime locks. The returned lease is closed
// only after validation; all retained data is a bounded immutable descriptor.
func restrictProductContinuation(restriction: ProductContinuationRestriction, ownerDigest: String,
    original: CompletedPluginDocumentObservation, chain: Array<CompletedPluginDocumentObservation>,
    thread: ThreadId, key: String, totalTokens: Int64, cancellation: CancellationToken,
    requestId: String, anchorRun: String, anchorClaim: String, allocation: ContinuationDocumentReadScope,
    window: ProductContinuationPreparationDeadline): Result<ProductContinuationDocumentSelection> {
    window.check()
    match (restriction.current(key)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (chain.isEmpty() || chain.size > 256) { return commandControlError("continuation.document_chain_invalid") }
    let observedAt = nowMillis()
    let queries = ArrayList<AgentValue>()
    allocation.preflightJson(original.encoded)
    let originalValue = decodeAgentValue(original.encoded, maxBytes: PLUGIN_DOCUMENT_MAX_BYTES).value().getOrThrow()
    for (observed in chain) {
        window.check()
        allocation.preflightJson(observed.encoded)
        match (restriction.current(key)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let query = objectValue([
            ValueField("schema", textValue("axyndra.continuation-restriction/v1")), ValueField("selector", restriction.selector()),
            ValueField("approved_document", originalValue),
            ValueField("current_document", decodeAgentValue(observed.encoded, maxBytes: PLUGIN_DOCUMENT_MAX_BYTES).value().getOrThrow()),
            ValueField("facts", objectValue([ValueField("now_millis", integerValue(observedAt)), ValueField("total_tokens", integerValue(totalTokens))]))])
        let response = match (queryProductPluginPolicy(restriction.command.host, restriction.command.namespace, restriction.provider,
            restriction.command.digest, query, thread, cancellation, requestId + "-" + observed.revision.toString(), deadline: Some(window.deadline))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            window.check()
            if (!httpIntentExactFields(response.value, ["continue"]) || response.value.field("continue").getOrThrow().unifiedKind != ValueKind.Boolean ||
                !response.value.field("continue").getOrThrow().asBool()) { return commandControlError("continuation.restriction_stopped") }
            if (response.binding.generation != restriction.command.generation || response.binding.digest != restriction.command.digest) {
                return commandControlError("continuation.restriction_changed") }
            match (restriction.current(key)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            queries.add(objectValue([ValueField("mutation", observed.descriptor()),
                ValueField("query_sha256", textValue(modelPolicySha256Text(canonicalAgentValue(query)))),
                ValueField("reply_sha256", textValue(modelPolicySha256Text(canonicalAgentValue(response.value))))]))
        } finally { response.close() }
    }
    productContinuationDocumentSelection(restriction, ownerDigest, original, chain,
        observedAt, totalTokens, queries.toArray(), anchorRun, anchorClaim, allocation, window)
}

// Both inline and referenced queries retain the same canonical observation
// schema and final admission verifier. Only their pure query bytes differ.
func productContinuationDocumentSelection(restriction: ProductContinuationRestriction, ownerDigest: String,
    original: CompletedPluginDocumentObservation, chain: Array<CompletedPluginDocumentObservation>,
    observedAt: Int64, totalTokens: Int64, queries: Array<AgentValue>, anchorRun: String, anchorClaim: String,
    allocation: ContinuationDocumentReadScope, window: ProductContinuationPreparationDeadline
): Result<ProductContinuationDocumentSelection> {
    let observed = chain[chain.size - 1]
    let transcript = listValue(queries)
        let witness = ContinuationDocumentObservation(objectValue([
            ValueField("schema", textValue("axyndra.continuation-document-observation/v1")), ValueField("owner_digest", textValue(ownerDigest)),
            ValueField("anchor_run_id", textValue(anchorRun)), ValueField("anchor_claim_sha256", textValue(anchorClaim)),
            ValueField("anchor_operation_id", textValue(chain[0].operationId)), ValueField("anchor_revision", integerValue(chain[0].revision)),
            ValueField("anchor_document_sha256", textValue(chain[0].digest)),
            ValueField("original_operation_id", textValue(original.operationId)), ValueField("original_receipt_id", textValue(original.receiptId)),
            ValueField("original_run_id", textValue(original.runId)), ValueField("original_epoch", integerValue(original.epoch)),
            ValueField("original_revision", integerValue(original.revision)), ValueField("original_document_sha256", textValue(original.digest)),
            ValueField("document_operation_id", textValue(observed.operationId)), ValueField("document_receipt_id", textValue(observed.receiptId)),
            ValueField("document_run_id", textValue(observed.runId)), ValueField("document_epoch", integerValue(observed.epoch)),
            ValueField("document_revision", integerValue(observed.revision)), ValueField("document_sha256", textValue(observed.digest)),
            ValueField("package_digest", textValue(restriction.command.digest)), ValueField("provider", textValue(restriction.provider)),
            ValueField("provider_generation", textValue(restriction.command.generation.toString())),
            ValueField("selector_sha256", textValue(modelPolicySha256Text(canonicalAgentValue(restriction.selector())))),
            ValueField("query_sha256", textValue(modelPolicySha256Text(canonicalAgentValue(transcript)))),
            ValueField("reply_sha256", textValue(modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("continue", boolValue(true))]))))),
            ValueField("configuration_digest", textValue(restriction.configuration.digest)), ValueField("parent_tool", textValue(restriction.parentTool)), ValueField("chain", transcript),
            ValueField("observed_at_millis", integerValue(observedAt)), ValueField("total_tokens", integerValue(totalTokens))]))
        window.check()
        Result.Ok(ProductContinuationDocumentSelection(witness, observed, allocation, window))
}
