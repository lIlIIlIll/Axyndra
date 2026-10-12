package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import std.collection.*
import std.convert.*
import std.env.*
import std.time.*
import yjson.*
import yjson_support.*

// TEMP_DIAGNOSTIC: fixed phase labels and durations only; no history or paths.
// Nested timings overlap and must not be added as CPU time. Remove after diagnosis.
func compactionDiagnosticRecord(phase: String, started: MonoTime): Unit {
    agent_host_runtime.hostCompactionDiagnosticRecord(phase, started)
}
func compactionDiagnosticError(code: String): Unit {
    if (getVariable("AXYNDRA_DIAGNOSTIC_COMPACTION") == Some("1")) {
        println("COMPACTION_INTERNAL_ERROR code=" + code)
    }
}

class ProductCompactionDataError <: Exception {
    let error: AgentError
    init(error: AgentError) { super("compaction data query failed"); this.error = error }
}
func compactionDataRequire(result: Result<Unit>): Unit {
    match (result) { case Result.Ok(_) => (); case Result.Err(error) => throw ProductCompactionDataError(error) }
}

// Only transport and immutable data operations. Field selection, reduction,
// summary limits, ordering and classification all come from the provider.
class ProductCompactionReferenceQuery {
    private var completedPhaseConsumer113: ?CancellationToken = None<CancellationToken>
    let references: ProductPolicyDataReferences
    let binding: ProductPluginPolicyBinding
    private let host: ProductJavaScriptPluginHost
    private let selection: ProductPolicySelection
    private let digest: String
    private let thread: ThreadId
    private let token: CancellationToken
    private let requestId: String
    private var sequence: Int64 = 0
    private let values = ArrayList<ProductPolicyValueRecord>()
    private var closed = false
    private var eventBatch = false
    init(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
        digest: String, thread: ThreadId, token: CancellationToken, requestId: String, binding: ProductPluginPolicyBinding) {
        this.host = host; this.selection = selection; this.digest = digest
        this.thread = thread; this.token = token; this.requestId = requestId
        this.binding = binding
        this.references = ProductPolicyDataReferences(modelPolicySha256Text(requestId + ":" + digest))
    }
    func check(): Unit { if (closed) { throw IllegalStateException("compaction query closed") }; compactionDataRequire(checkCancellation113()); compactionDataRequire(selection.validateBinding(host, binding)); compactionDataRequire(checkCancellation113()) }
    private func checkCancellation113(): Result<Unit> {
        match (completedPhaseConsumer113) { case Some(actual) => actual.check(); case None => token.check() }
    }
    // Only after the actual final Native response/check has completed. The
    // original summary phase deadline ends; retained DATA remains cancelled
    // by its real parent and fully bound to the same published generation.
    func retainCompletedPurePhase113(parent: CancellationToken): Unit {
        check(); completedPhaseConsumer113 = Some(parent)
    }
    func matchesSourceDigest113(value: String): Bool { value == digest }
    // Lock order is actual Host -> Registry SH -> Store database. The loan
    // checks only the actual invocation token and immutable configuration in
    // the TX; it never reenters Host or another SQL transaction.
    func consumeCurrentData113(action: (() -> Result<Unit>) -> Result<Unit>): Result<Unit> {
        check()
        selection.consumeCurrent193(host, binding, { =>
            let current: () -> Result<Unit> = { =>
                if (closed) { return productPolicySelectionError<Unit>("compaction.query_closed") }
                match (token.check()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
                match (selection.validateCurrent()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
                token.check()
            }
            action(current)
        })
    }
    private func checkLocal(): Unit {
        if (closed) { throw IllegalStateException("compaction query closed") }
        compactionDataRequire(checkCancellation113())
        compactionDataRequire(selection.validatePinnedGeneration(host, binding))
        compactionDataRequire(checkCancellation113())
    }
    func query(phase: String, fields: Array<ValueField>, policyProvenance193!: ?String = None<String>): AgentValue {
        let diagnosticStarted = MonoTime.now()
        try {
        checkLocal()
        if (sequence == Int64.Max) { throw IllegalStateException("compaction query sequence exhausted") }
        sequence++
        let input = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.compaction-policy/v1")),
            ValueField("phase", textValue(phase)), ValueField("snapshot_digest", textValue(digest))])
        input.add(all: fields)
        let response = match (selection.queryPolicy193(host, objectValue(input.toArray()), thread, token,
            requestId + "-reference-" + sequence.toString(), policyProvenance193)) {
                case Result.Ok(value) => value; case Result.Err(error) => throw ProductCompactionDataError(error) }
        try {
            checkLocal()
            if (response.generation != binding.generation) { throw IllegalStateException("compaction generation changed") }
            let copy = references.copy(response.value)
            try { checkLocal(); values.add(ProductPolicyValueRecord(sequence, copy)); copy.value }
            catch (error: Exception) { copy.close(); throw error }
        } finally { response.close() }
        } finally { compactionDiagnosticRecord(phase, diagnosticStarted) }
    }
    func configureLayout(layout: AgentValue): Unit {
        if (httpIntentExactFields(layout, ["arguments", "state"])) { eventBatch = false; return }
        if (!httpIntentExactFields(layout, ["arguments", "state", "event_batch"]) ||
            layout.field("event_batch").getOrThrow().unifiedKind != ValueKind.Boolean) {
            throw IllegalStateException("invalid reference event negotiation") }
        eventBatch = layout.field("event_batch").getOrThrow().asBool()
    }
    func marker(): Int64 { sequence }
    // Native event/its raw transport have returned; retain every real active
    // query value before retiring an unused original text capture. This loan
    // is DATA, not an execution/operation ACK or Source grant.
    func retireCompletedEventInputs113(): Unit {
        let metadata = references.checkpointBatchMetadata113()
        try { retireCompletedEventInputsFrame113() } finally { metadata.close() }
    }
    private func retireCompletedEventInputsFrame113(): Unit {
        let roots = ArrayList<AgentValue>()
        try {
            for (entry in values) { roots.add(entry.lease.value) }
            references.finishCanonicalTextLoan113(roots.toArray())
        } finally { roots.clear() }
    }
    func copy(value: AgentValue): AgentValue {
        let lease = references.copy(value)
        try { values.add(ProductPolicyValueRecord(sequence, lease)); lease.value }
        catch (error: Exception) { lease.close(); throw error }
    }
    func release(value: AgentValue): Unit {
        var index: Int64 = 0
        while (index < values.size) {
            if (refEq(values[index].lease.value, value)) { values.remove(at: index).lease.close(); return }
            index++
        }
    }
    func releaseSince(mark: Int64, keep!: ?AgentValue = None): Unit {
        var index: Int64 = 0
        while (index < values.size) {
            let entry = values[index]
            let preserved = match (keep) { case Some(value) => refEq(entry.lease.value, value); case None => false }
            if (entry.sequence > mark && !preserved) { values.remove(at: index).lease.close() } else { index++ }
        }
    }
    func close(): Unit {
        if (closed) { return }; closed = true
        for (entry in values) { entry.lease.close() }; values.clear(); references.close()
    }
    func replaceEvent(state: AgentValue, event: AgentValue): AgentValue {
        let next = this.event(state, event); release(state); next
    }
    func reduce(task: AgentValue): AgentValue {
        let mark = marker(); var retained: ?AgentValue = None
        try {
        if (!httpIntentExactFields(task, ["key", "source", "mode", "limit"])) { throw IllegalStateException("invalid policy reduction task") }
        let source = task.field("source").getOrThrow(); let text = references.value(source)
        let mode = httpIntentText(task, "mode"); let limit = compactionPageInteger(task, "limit")
        if (!["compact", "excerpt", "hashlines", "overview"].contains(mode) || limit < 1 || limit > (if (mode == "overview") { 262144 } else { 1600 })) { throw IllegalStateException("invalid policy reduction") }
        var offset: Int64 = 0; var carry = nullValue(); var paths = listValue([])
        var previous: ?AgentValue = None
        while (true) {
            checkLocal()
            let chunk = references.chunk(source, offset)
            let fields = ArrayList<ValueField>([ValueField("source", source), ValueField("sequence", integerValue(sequence + 1)),
                ValueField("offset", integerValue(offset)), ValueField("total", integerValue(text.size)),
                ValueField("text", textValue(chunk)), ValueField("carry", carry)])
            if (mode != "hashlines") { fields.add(ValueField("mode", textValue(mode))); fields.add(ValueField("limit", integerValue(limit))) }
            let result = query(if (mode == "hashlines") { "hashline_fragment" } else if (mode == "overview") { "overview_fragment" } else { "text_fragment" }, fields.toArray())
            match (previous) { case Some(value) => release(value); case None => () }
            previous = Some(result)
            let next = compactionPageInteger(result, "next_offset")
            if (httpIntentText(result, "snapshot_digest") != digest || compactionPageInteger(result, "sequence") != sequence ||
                canonicalAgentValue(result.field("source").getOrThrow()) != canonicalAgentValue(source) ||
                next < offset || next > offset + chunk.size || (next == offset && text.size != 0)) { throw IllegalStateException("policy fragment coverage mismatch") }
            let complete = result.field("complete").getOrThrow()
            if (complete.unifiedKind != ValueKind.Boolean) { throw IllegalStateException("invalid policy fragment completion") }
            if (mode == "hashlines") {
                if (!httpIntentExactFields(result, ["snapshot_digest", "source", "sequence", "next_offset", "complete", "ranges", "carry"])) {
                    throw IllegalStateException("invalid hashline fragment result") }
                let ranges = result.field("ranges").getOrThrow(); let resolved = ArrayList<AgentValue>()
                if (ranges.unifiedKind != ValueKind.List || ranges.items.size > 129) { throw IllegalStateException("invalid policy ranges") }
                for (range in ranges.items) {
                    if (!httpIntentExactFields(range, ["offset", "bytes"])) { throw IllegalStateException("invalid policy range") }
                    let start = compactionPageInteger(range, "offset"); let bytes = compactionPageInteger(range, "bytes")
                    if (start < 0 || bytes < 0 || start > next || bytes > next - start) { throw IllegalStateException("policy range reaches unobserved data") }
                    resolved.add(references.intern(references.slice(source, start, bytes)))
                }
                // Equality IDs do not choose or rank paths. The plugin applies
                // its original first-24 unique policy to the returned values.
                let nextPaths = query("reference_paths", [ValueField("paths", paths), ValueField("values", listValue(resolved.toArray()))])
                release(paths); paths = nextPaths
                if (paths.unifiedKind != ValueKind.List || paths.items.size > 24) { throw IllegalStateException("invalid policy path state") }
                for (path in paths.items) { let _ = references.value(path) }
                if (paths.items.size == 24 || complete.asBool()) { retained = Some(paths); return paths }
            } else {
                if (!httpIntentExactFields(result, ["snapshot_digest", "source", "sequence", "next_offset", "complete", "prior", "result", "carry"])) {
                    throw IllegalStateException("invalid policy compact result") }
                if (complete.asBool()) {
                    let value = result.field("result").getOrThrow()
                    if (value.unifiedKind != ValueKind.Text || value.text.size > (if (mode == "overview") { 1048580 } else { 1603 }) || result.field("prior").getOrThrow().unifiedKind != ValueKind.Boolean) {
                        throw IllegalStateException("policy compact result exceeds bound") }
                    let output = copy(objectValue([ValueField("result", value), ValueField("prior", result.field("prior").getOrThrow())]))
                    retained = Some(output); return output
                }
            }
            if (next == text.size) { throw IllegalStateException("policy fragment failed to close at EOF") }
            carry = result.field("carry").getOrThrow(); offset = next
        }
        throw IllegalStateException("non-progressing policy reduction")
        } finally { releaseSince(mark, keep: retained) }
    }
    func event(state: AgentValue, event: AgentValue): AgentValue {
        let mark = marker(); var retained: ?AgentValue = None
        try {
        if (eventBatch) { let next = batchEvent(state, event); retained = Some(next); return next }
        let plan = query("reference_plan", [ValueField("state", state), ValueField("event", event)])
        if (!httpIntentExactFields(plan, ["tasks"])) { throw IllegalStateException("invalid policy reference plan") }
        let tasks = plan.field("tasks").getOrThrow(); let reduced = ArrayList<ValueField>(); let keys = HashSet<String>()
        if (tasks.unifiedKind != ValueKind.List || tasks.items.size > 32) { throw IllegalStateException("invalid reduction count") }
        for (task in tasks.items) {
            let key = httpIntentText(task, "key")
            if (key == "" || key.size > 128 || keys.contains(key)) { throw IllegalStateException("ambiguous reduction key") }
            keys.add(key); reduced.add(ValueField(key, reduce(task)))
        }
        let output = query("reference_fold", [ValueField("state", state), ValueField("event", event), ValueField("reduced", objectValue(reduced.toArray()))])
        if (!httpIntentExactFields(output, ["commands"])) { throw IllegalStateException("invalid reference fold") }
        let next = resolveEventCommands(state, event, output.field("commands").getOrThrow())
        // Every returned reference must still name this query's intern data.
        validateReferences(next); checkLocal(); retained = Some(next); next
        } finally { releaseSince(mark, keep: retained) }
    }
    private func batchEvent(state: AgentValue, event: AgentValue): AgentValue {
        var output = query("reference_event", [ValueField("state", state), ValueField("event", event)])
        if (httpIntentText(output, "kind") == "reduce") {
            if (!httpIntentExactFields(output, ["kind", "tasks", "reduced"])) { throw IllegalStateException("invalid batch reduction") }
            let tasks = output.field("tasks").getOrThrow(); let supplied = output.field("reduced").getOrThrow()
            if (tasks.unifiedKind != ValueKind.List || supplied.unifiedKind != ValueKind.Object ||
                tasks.items.isEmpty() || tasks.items.size + supplied.fields.size > 32) { throw IllegalStateException("invalid batch task count") }
            let fields = ArrayList<ValueField>(); let keys = HashSet<String>()
            for (field in supplied.fields) {
                if (field.name == "" || field.name.size > 128 || keys.contains(field.name) ||
                    !httpIntentExactFields(field.value, ["result", "prior"]) ||
                    field.value.field("result").getOrThrow().unifiedKind != ValueKind.Text ||
                    field.value.field("result").getOrThrow().text.size > 1603 ||
                    field.value.field("prior").getOrThrow().unifiedKind != ValueKind.Boolean) {
                    throw IllegalStateException("invalid inline reduction") }
                keys.add(field.name); fields.add(field)
            }
            for (task in tasks.items) {
                let key = httpIntentText(task, "key")
                if (key == "" || key.size > 128 || keys.contains(key)) { throw IllegalStateException("ambiguous batch reduction key") }
                keys.add(key); fields.add(ValueField(key, reduce(task)))
            }
            output = query("reference_event_fold", [ValueField("state", state), ValueField("event", event),
                ValueField("reduced", objectValue(fields.toArray()))])
        }
        let kind = httpIntentText(output, "kind")
        let next = if (kind == "state" && httpIntentExactFields(output, ["kind", "state"])) {
            // The Provider ran its original no-recipe Merge. No new reference
            // can be smuggled past the same query-local resolver below.
            copy(output.field("state").getOrThrow())
        } else if (kind == "commands" && httpIntentExactFields(output, ["kind", "commands"])) {
            resolveEventCommands(state, event, output.field("commands").getOrThrow())
        } else { throw IllegalStateException("invalid reference batch result") }
        validateReferences(next); checkLocal(); next
    }
    private func resolveEventCommands(state: AgentValue, event: AgentValue, commands: AgentValue): AgentValue {
        let entries = ArrayList<AgentValue>()
        if (commands.unifiedKind != ValueKind.List || commands.items.size > 256) { throw IllegalStateException("invalid reference recipe count") }
        for (entry in commands.items) {
            if (!httpIntentExactFields(entry, ["target", "recipe"])) { throw IllegalStateException("invalid reference recipe") }
            checkLocal()
            entries.add(objectValue([ValueField("target", entry.field("target").getOrThrow()),
                ValueField("value", references.internRecipe(entry.field("recipe").getOrThrow()))]))
        }
        query("reference_merge", [ValueField("state", state), ValueField("event", event), ValueField("commands", listValue(entries.toArray()))])
    }
    private func validateReferences(value: AgentValue): Unit {
        if (value.unifiedKind == ValueKind.Object) {
            if (value.field("ref").isSome()) { let _ = references.value(value); return }
            for (field in value.fields) { validateReferences(field.value) }
        } else if (value.unifiedKind == ValueKind.List) { for (entry in value.items) { validateReferences(entry) } }
    }
}

func queryProductCompactionReferenceHistory(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
    messages: Array<ModelMessage>, goal: AgentValue, todos: AgentValue, digest: String,
    thread: ThreadId, cancellation: CancellationToken, requestId: String, binding: ProductPluginPolicyBinding): Result<ProductCompactionPageResult> {
    let query = try { ProductCompactionReferenceQuery(host, selection, digest, thread, cancellation, requestId, binding) }
        catch (error: ProductCompactionDataError) { return Result.Err(error.error) }
    var retained = false
    try {
        let layout = query.query("reference_layout", [])
        query.configureLayout(layout)
        let argumentLayout = layout.field("arguments").getOrThrow()
        if (argumentLayout.unifiedKind != ValueKind.List || argumentLayout.items.size > 32) { throw IllegalStateException("invalid projection selectors") }
        var state = layout.field("state").getOrThrow()
        for (message in messages) {
            let role = match (message.role) { case ModelRole.User => "user"; case ModelRole.Assistant => "assistant" }
            state = query.replaceEvent(state, objectValue([ValueField("kind", textValue("message")), ValueField("role", textValue(role))]))
            for (block in message.blocks) {
                let arguments = ArrayList<ValueField>(); let seen = HashSet<String>()
                for (selector in argumentLayout.items) {
                    if (!httpIntentExactFields(selector, ["field", "kind"])) { throw IllegalStateException("invalid projection selector") }
                    let field = httpIntentText(selector, "field"); let kind = httpIntentText(selector, "kind")
                    if (field == "" || field.size > 128 || seen.contains(field) || !["text", "number"].contains(kind)) {
                        throw IllegalStateException("invalid scalar projection selector") }
                    seen.add(field)
                    let node = block.arguments.field(field) ?? nullValue()
                    let text = if (kind == "text" && node.unifiedKind == ValueKind.Text) { node.text }
                        else if (kind == "number" && node.unifiedKind == ValueKind.Number) { node.asNumberText() } else { "" }
                    arguments.add(ValueField(field, query.references.intern(text)))
                }
                // The provider-neutral model codec supplies kind names. No
                // tool name or argument field is interpreted by this caller.
                let blockValue = modelRequestSnapshotValue(ModelRequest("compaction-history", [ModelMessage(message.role, [block])]))
                    .field("messages").getOrThrow().items[0].field("blocks").getOrThrow().items[0]
                state = query.replaceEvent(state, objectValue([ValueField("kind", blockValue.field("kind").getOrThrow()),
                    ValueField("role", textValue(role)), ValueField("name", query.references.intern(block.name)),
                    ValueField("text", query.references.intern(block.text)), ValueField("is_error", boolValue(block.isError)),
                    ValueField("arguments", objectValue(arguments.toArray()))]))
            }
        }
        if (goal.unifiedKind != ValueKind.Null) {
            state = query.replaceEvent(state, objectValue([ValueField("kind", textValue("goal")),
                ValueField("objective", query.references.intern(httpIntentText(goal, "objective"))),
                ValueField("status", query.references.intern(httpIntentText(goal, "status")))]))
        }
        if (todos.unifiedKind != ValueKind.List) { throw IllegalStateException("invalid workflow projection") }
        for (phase in todos.items) {
            let name = query.references.intern(httpIntentText(phase, "name")); let tasks = phase.field("tasks").getOrThrow()
            if (tasks.unifiedKind != ValueKind.List) { throw IllegalStateException("invalid workflow task projection") }
            for (task in tasks.items) {
                state = query.replaceEvent(state, objectValue([ValueField("kind", textValue("todo")), ValueField("name", name),
                    ValueField("content", query.references.intern(httpIntentText(task, "content"))), ValueField("status", task.field("status").getOrThrow()),
                    ValueField("blocker", query.references.intern(httpIntentText(task, "blocker")))]))
            }
        }
        let final = query.query("reference_finish", [ValueField("state", state)])
        if (!httpIntentExactFields(final, ["snapshot_digest", "recipe"]) || httpIntentText(final, "snapshot_digest") != digest) {
            throw IllegalStateException("invalid final reference recipe") }
        query.check()
        let summary = query.references.compose(final.field("recipe").getOrThrow(), 8388608)
        query.check()
        let result = ProductCompactionPageResult(query.binding,
            objectValue([ValueField("snapshot_digest", textValue(digest)), ValueField("summary", textValue(summary))]),
            { => query.close() })
        retained = true; Result.Ok(result)
    } catch (error: ProductCompactionDataError) { Result.Err(error.error) }
    catch (_: Exception) { productPolicySelectionError("compaction.reference_invalid") }
    finally { if (!retained) { query.close() } }
}
