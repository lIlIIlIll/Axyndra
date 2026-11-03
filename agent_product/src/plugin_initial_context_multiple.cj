package agent_product

import agent_core.*
import agent_domain.*
import agent_domain as domain
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// The ordered wrapper selects only existing typed providers. Each child uses
// the original strict v1..v5 parser and the whole configuration digest; no
// child JSON can mint a Source or replace a canonical ContextRead fact.
func loadInitialContextSelections(settingsRoot: String, runtime!: ?ProductPluginRuntime = None): Result<Array<ProductInitialContextSelection>> {
    let text = match (initialContextConfigText(settingsRoot)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    parseInitialContextSelections(settingsRoot, text, runtime)
}
func initialContextSelectionMaximumReads(selection: ProductInitialContextSelection): Int64 {
    if (selection.windowProtocol) { return 8 }
    if (selection.preparationProtocol) { if (selection.componentSources.isSome()) { 3 } else { 2 } } else { 1 }
}
func parseInitialContextSelections(settingsRoot: String, text: String,
    runtime: ?ProductPluginRuntime): Result<Array<ProductInitialContextSelection>> {
    try {
        let value = parseUnifiedJson(text, maxBytes: 65536, maxDepth: 32)
        if (value.field("version").isNone() || value.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
            value.field("version").getOrThrow().asNumberText() != "6") {
            return match (parseInitialContextSelection(settingsRoot, text, runtime)) {
                case Result.Err(error) => Result.Err(error); case Result.Ok(item) => Result.Ok([item]) }
        }
        if (!httpIntentExactFields(value, ["version", "selections"]) ||
            value.field("selections").getOrThrow().unifiedKind != ValueKind.List ||
            value.field("selections").getOrThrow().items.size < 1 || value.field("selections").getOrThrow().items.size > 8) {
            return initialContextError("context.initial_configuration_invalid") }
        let selections = ArrayList<ProductInitialContextSelection>(); let owners = HashSet<String>(); var reads: Int64 = 0
        for (entry in value.field("selections").getOrThrow().items) {
            let selection = match (parseInitialContextSelection(settingsRoot, stringifyUnifiedJson(entry), runtime,
                configurationText: Some(text))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
            let owner = selection.namespace + "/context/" + selection.provider
            reads += initialContextSelectionMaximumReads(selection)
            if (owners.contains(owner) || reads > 8) { return initialContextError("context.initial_configuration_invalid") }
            owners.add(owner); selections.add(selection)
        }
        Result.Ok(selections.toArray())
    } catch (_: Exception) { initialContextError("context.initial_configuration_invalid") }
}

// Inspect configuration and actual installed bindings before accepting a Run.
// This performs no document read, model query, Tool or Operation. The real
// Run preparation freezes and rechecks all these bindings again before reads.
func preflightInitialContextSelections(host: ProductJavaScriptPluginHost,
    selections: Array<ProductInitialContextSelection>, prompt: String): Result<Unit> {
    for (selection in selections) {
        match (selection.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let binding = match (host.contentProviderBinding(selection.namespace, selection.provider, false)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (binding.digest != selection.packageDigest) { return initialContextError("context.initial_binding_changed") }
        if (selection.journalProtocol) {
            match (preflightInitialJournalContextSelection(host, selection, binding, prompt)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            continue
        }
        let frozen = try { FrozenPluginContentQuery(selection.query(prompt), []) }
            catch (_: Exception) { return initialContextError("context.query_limit") }
        try {
            if (frozen.query.field(CONTEXT_READ_INPUT_FIELD).isSome() || frozen.query.field("_axyndra_context_provider").isSome()) {
                return initialContextError("context.initial_configuration_invalid") }
        } finally { frozen.close() }
        if (selection.windowProtocol) {
            match (preflightInitialDocumentWindowSelection(host, selection, binding)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        if (selection.documentProtocol) {
            let configuration = match (host.documentContextConfiguration(selection.namespace, binding.digest, selection.provider)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            for (key in selection.resources().items where !configuration.permits(key.text)) {
                return initialContextError("context.document_rights_denied") }
            match (configuration.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
    }
    Result.Ok(())
}

// Framework-owned composition of existing preparations. Native contributions
// remain data. Every stage has its own canonical approval and paid Root;
// only the final complete snapshot reaches the original atomic context cut.
class ProductInitialContextMultipleSequence {
    let maximumReads: Int64
    private let host: ProductJavaScriptPluginHost
    private let selections: Array<ProductInitialContextSelection>
    private let plans: Array<InitialContextPreparation>
    private let before: ActiveRunSnapshot
    private let cancellation: domain.CancellationToken
    private let generationValues: Array<UInt64>
    private let projections = ArrayList<InvocationContextProjection>()
    private var index: Int64 = 0
    private var factOffset: Int64 = 0
    private var currentRead: ToolPreparationRead
    private var transitionFrom: ?ToolPreparationRead = None
    private var transitionTo: ?ToolPreparationRead = None
    init(host: ProductJavaScriptPluginHost, selections: Array<ProductInitialContextSelection>,
        plans: Array<InitialContextPreparation>, before: ActiveRunSnapshot, cancellation: domain.CancellationToken) {
        this.host = host; this.selections = selections.clone(); this.plans = plans.clone()
        this.before = before; this.cancellation = cancellation; this.currentRead = plans[0].read
        let generations = ArrayList<UInt64>(); var reads: Int64 = 0
        for (position in 0..selections.size) {
            generations.add(host.contentProviderBinding(selections[position].namespace, selections[position].provider, false).value().getOrThrow().generation)
            reads += plans[position].sequence.map { value => value.maximumReads } ?? 1
        }
        generationValues = generations.toArray(); maximumReads = reads
    }
    func first(): ToolPreparationRead { currentRead }
    func validate(): Result<Unit> {
        if (cancellation.isCancelled()) { return initialContextError("context.read_update_cancelled") }
        for (position in 0..plans.size) {
            match (plans[position].validity()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let selection = selections[position]
            let binding = match (host.contentProviderBinding(selection.namespace, selection.provider, false)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (binding.digest != selection.packageDigest || binding.generation != generationValues[position]) {
                return initialContextError("context.initial_binding_changed") }
        }
        Result.Ok(())
    }
    private func sameRead(left: ToolPreparationRead, right: ToolPreparationRead): Bool {
        left.ownerNamespace == right.ownerNamespace && left.packageDigest == right.packageDigest &&
        left.configurationDigest == right.configurationDigest && canonicalAgentValue(left.request()) == canonicalAgentValue(right.request())
    }
    func validateTransition(old: ToolPreparationRead, next: ToolPreparationRead): Result<Unit> {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (transitionFrom.isNone() || transitionTo.isNone() || !sameRead(old, transitionFrom.getOrThrow()) ||
            !sameRead(next, transitionTo.getOrThrow())) { return initialContextError("context.read_update_next_invalid") }
        transitionFrom = None; transitionTo = None
        Result.Ok(())
    }
    private func nextRead(next: ToolPreparationRead): Result<ContextReadNext> {
        transitionFrom = Some(currentRead); transitionTo = Some(next); currentRead = next
        Result.Ok(ContextReadNext.Read(next))
    }
    func advance(context: ToolInvocationContext, facts: Array<ContextReadFact>): Result<ContextReadNext> {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (index >= plans.size || facts.size <= factOffset || facts.size > maximumReads ||
            context.sessionId.value != before.threadId.value || context.runId.value != before.runId.value || context.epoch != before.epoch ||
            contextReadProjectionDigest(context.contextProjection) != contextReadProjectionDigest(before.contextSnapshot)) {
            return initialContextError("context.sequence_fact_invalid") }
        let plan = plans[index]; let selectedFacts = facts[factOffset..]
        let step = match (plan.sequence) {
            case Some(sequence) => match (sequence.advance(context, selectedFacts)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            case None =>
                if (selectedFacts.size != 1) { return initialContextError("context.sequence_fact_invalid") }
                let output = match (plan.read.complete(context, selectedFacts)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let snapshot = try { contextSnapshotFromValue(output) }
                    catch (_: Exception) { return initialContextError("context.read_update_projection_invalid") }
                ContextReadNext.Ready(snapshot)
        }
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (step) {
            case ContextReadNext.Read(next) =>
                if (plan.sequence.isNone() || selectedFacts.size >= plan.sequence.getOrThrow().maximumReads ||
                    next.ownerNamespace != selections[index].namespace || next.packageDigest != selections[index].packageDigest) {
                    return initialContextError("context.read_update_next_invalid") }
                return nextRead(next)
            case ContextReadNext.Ready(snapshot) => projections.add(snapshot)
        }
        index++; factOffset = facts.size
        if (index < plans.size) { return nextRead(plans[index].read) }
        let owners = selections.map { selection => selection.namespace + "/context/" + selection.provider }
        let items = ArrayList<InvocationContextContribution>()
        for (item in before.contextSnapshot.contributions() where !owners.contains(item.owner)) { items.add(item) }
        for (position in 0..projections.size) {
            for (item in projections[position].contributions() where item.owner == owners[position]) { items.add(item) }
        }
        let snapshot = try { InvocationContextProjection(contributions: items.toArray()) }
            catch (_: Exception) { return initialContextError("context.read_update_projection_invalid") }
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(ContextReadNext.Ready(InvocationContextProjection(contributions: items.toArray(), sourceDigest:
            modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("context", contextSnapshotValue(snapshot)),
                ValueField("facts", contextReadFactLinksValue(facts.map { fact => fact.link() }))]))))))
    }
}
