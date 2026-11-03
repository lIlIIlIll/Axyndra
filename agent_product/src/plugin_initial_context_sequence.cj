package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// Generic pure-provider preparation protocol. Only logical paths already
// observed by this exact host sequence may become selected body requests.
// Provider output never supplies host paths, grants, identities or approval.
class ProductInitialContextSequence {
    private let host: ProductJavaScriptPluginHost
    private let selection: ProductInitialContextSelection
    private let binding: ProductPluginContentBinding
    private let before: ActiveRunSnapshot
    private let prompt: String
    private let cancellation: CancellationToken
    private let ids: ProductIds
    private var nextQuery: ?String = None
    private var selectedPaths: Array<String> = []
    private var metadataPaths: Array<String> = []
    private let inputs: ProductInitialContextInputs
    private var componentQuery: ?String = None
    private var componentHeaderPaths: Array<String> = []

    init(host: ProductJavaScriptPluginHost, selection: ProductInitialContextSelection,
        binding: ProductPluginContentBinding, before: ActiveRunSnapshot, prompt: String,
        cancellation: CancellationToken, ids: ProductIds, inputs: ProductInitialContextInputs) {
        this.host = host; this.selection = selection; this.binding = binding; this.before = before
        this.prompt = prompt; this.cancellation = cancellation; this.ids = ids; this.inputs = inputs
    }
    func validate(): Result<Unit> {
        match (selection.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (cancellation.isCancelled()) { return initialContextError("context.update_source_stale") }
        let current = match (host.contentProviderBinding(binding.namespace, binding.contribution, false)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (current.generation != binding.generation || current.digest != binding.digest) {
            return initialContextError("context.update_source_stale") }
        Result.Ok(())
    }
    func first(): ToolPreparationRead { read(inputs.resources(), [], inputs.query()) }
    private func read(resources: AgentValue, facts: Array<ContextReadFact>, query: AgentValue): ToolPreparationRead {
        let configuration = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("configuration_digest", textValue(selection.digest)), ValueField("query", query),
            ValueField("resources", resources), ValueField("facts", contextReadFactLinksValue(facts.map { value => value.link() }))])))
        let identity = objectValue([ValueField("schema", textValue("axyndra.context-provider-read/v1")),
            ValueField("plugin", textValue(binding.namespace)), ValueField("provider", textValue(binding.contribution)),
            ValueField("package_digest", textValue(binding.digest)), ValueField("generation", textValue(binding.generation.toString())),
            ValueField("thread_id", textValue(before.threadId.value)), ValueField("run_id", textValue(before.runId.value)),
            ValueField("epoch", integerValue(before.epoch)),
            ValueField("projection_digest", textValue(contextReadProjectionDigest(before.contextSnapshot))),
            ValueField("configuration_digest", textValue(configuration))])
        let exact = canonicalAgentValue(identity)
        ToolPreparationRead(binding.namespace, binding.digest, configuration,
            objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)), ValueField("binding", identity),
                ValueField("resources", resources)]),
            { _, _ => initialContextError<AgentValue>("context.sequence_required") },
            boundary: Some({ context, arguments =>
                if (context.sessionId.value != before.threadId.value || context.runId.value != before.runId.value ||
                    context.epoch != before.epoch || contextReadProjectionDigest(context.contextProjection) !=
                    contextReadProjectionDigest(before.contextSnapshot) ||
                    canonicalAgentValue(arguments.field("binding") ?? nullValue()) != exact) {
                    return initialContextError<Unit>("context.read_binding_invalid") }
                validate()
            }))
    }
    private func withData(query: AgentValue, resources: Array<AgentValue>, facts: Array<ContextReadFact>): AgentValue {
        let fields = ArrayList<ValueField>()
        for (field in query.fields) { fields.add(field) }
        fields.add(ValueField(CONTEXT_READ_INPUT_FIELD, objectValue([
            ValueField("schema", textValue("axyndra.context-read-input/v1")),
            ValueField("data", objectValue([ValueField("schema", textValue("axyndra.context-read-result/v1")),
                ValueField("resources", listValue(resources))])),
            ValueField("facts", contextReadFactLinksValue(facts.map { value => value.link() }))])))
        objectValue(fields.toArray())
    }
    func advance(context: ToolInvocationContext, facts: Array<ContextReadFact>): Result<ContextReadNext> {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (facts.size < 1 || facts.size > (if (selection.componentSources.isSome()) { 3 } else { 2 }) || context.runId.value != before.runId.value || context.epoch != before.epoch) {
            return initialContextError("context.sequence_fact_invalid") }
        for (fact in facts) {
            if (fact.runId.value != before.runId.value || fact.origin.parentCallItemId != "" ||
                fact.origin.ownerNamespace != binding.namespace || fact.origin.packageDigest != binding.digest ||
                fact.origin.projectionDigest != contextReadProjectionDigest(before.contextSnapshot)) {
                return initialContextError("context.sequence_fact_invalid") }
        }
        var observed = facts[0].output().field("resources").getOrThrow().items.toArray()
        var phase = facts.size; var firstQuery = inputs.query()
        if (selection.componentSources.isSome()) {
            if (componentQuery.isNone()) {
                if (facts.size != 1) { return initialContextError("context.sequence_order_invalid") }
                let sourceQuery = withData(firstQuery, observed, facts)
                let selected = match (selectComponentContextHeaders(host, binding, selection, sourceQuery,
                    observed, before.threadId, context.cancellation, ids)) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                componentQuery = Some(stringifyUnifiedJson(selected.query()))
                componentHeaderPaths = selected.paths.clone()
                if (!componentHeaderPaths.isEmpty()) {
                    return Result.Ok(ContextReadNext.Read(read(selected.resources(), facts, selected.query()))) }
            }
            let values = ArrayList<AgentValue>()
            for (item in observed) {
                if (httpIntentText(item, "kind") != "index") { values.add(item); continue }
                for (entry in item.field("entries").getOrThrow().items where httpIntentText(entry, "kind") == "directory") {
                    let relative = httpIntentText(entry, "relative")
                    values.add(objectValue([ValueField("kind", textValue("directory")),
                        ValueField("source", textValue(if (relative == "") { httpIntentText(item, "source") } else { Path(httpIntentText(item, "source")).join(relative).toString() })),
                        ValueField("path", textValue(if (relative == "") { httpIntentText(item, "path") } else { httpIntentText(item, "path") + "/" + relative })),
                        ValueField("witness", entry.field("witness").getOrThrow()), ValueField("text", textValue("")),
                        ValueField("sha256", textValue(modelPolicySha256Text("")))]))
                }
            }
            if (!componentHeaderPaths.isEmpty()) {
                if (facts.size < 2) { return initialContextError("context.sequence_order_invalid") }
                let headers = facts[1].output().field("resources").getOrThrow()
                if (headers.items.size != componentHeaderPaths.size) { return initialContextError("context.sequence_headers_changed") }
                let seen = HashSet<String>()
                for (item in headers.items) {
                    let path = httpIntentText(item, "path")
                    if (httpIntentText(item, "kind") != "header" || !componentHeaderPaths.contains(path) || seen.contains(path)) {
                        return initialContextError("context.sequence_headers_changed") }
                    seen.add(path); values.add(item)
                }
                phase--
            }
            observed = values.toArray(); firstQuery = parseUnifiedJson(componentQuery.getOrThrow())
        }
        if (phase == 1) {
            if (nextQuery.isSome()) { return initialContextError("context.sequence_reused") }
            let raw = withData(firstQuery, observed, facts)
            let frozen = try { FrozenPluginContentQuery(raw, [], observed: true) }
                catch (_: Exception) { return initialContextError("context.query_limit") }
            let response = try { contentProviderQuery(host, binding, frozen.query, before.threadId, context.cancellation, ids.nextInvocationId()) }
                finally { frozen.close() }
            let output = match (response) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            let resources = ArrayList<AgentValue>(); let paths = ArrayList<String>(); let metadata = ArrayList<String>()
            try {
                let value = output.value
                if (!httpIntentExactFields(value, ["schema", "reads", "query"]) ||
                    httpIntentText(value, "schema") != "axyndra.context-preparation/v1" ||
                    value.field("reads").getOrThrow().unifiedKind != ValueKind.List ||
                    value.field("reads").getOrThrow().items.size > 256 ||
                    value.field("query").getOrThrow().unifiedKind != ValueKind.Object ||
                    value.field("query").getOrThrow().field(CONTEXT_READ_INPUT_FIELD).isSome()) {
                    return initialContextError("context.sequence_result_invalid") }
                let query = stringifyUnifiedJson(value.field("query").getOrThrow())
                if (query.size > 196608) { return initialContextError("context.sequence_result_limit") }
                for (item in value.field("reads").getOrThrow().items) {
                    let metadataRead = httpIntentExactFields(item, ["path", "mode"]) && httpIntentText(item, "mode") == "metadata_directory"
                    if (!metadataRead && !httpIntentExactFields(item, ["path"])) { return initialContextError("context.sequence_path_invalid") }
                    let path = httpIntentText(item, "path")
                    if (!readViewRelativePath(path) || paths.contains(path) || metadata.contains(path)) { return initialContextError("context.sequence_path_invalid") }
                    if (metadataRead) {
                        // Resolve only beneath an actual directory from the first
                        // canonical fact. No provider-supplied physical locator.
                        var parent: ?AgentValue = None
                        for (source in observed where httpIntentText(source, "kind") == "directory") {
                            let prefix = httpIntentText(source, "path")
                            if (path.startsWith(prefix + "/") && (parent.isNone() || prefix.size > httpIntentText(parent.getOrThrow(), "path").size)) {
                                parent = Some(source) }
                        }
                        if (parent.isNone() || metadata.size >= 128) { return initialContextError("context.sequence_path_unobserved") }
                        let old = parent.getOrThrow(); let prefix = httpIntentText(old, "path")
                        resources.add(objectValue([ValueField("source", textValue(Path(httpIntentText(old, "source")).join(path[prefix.size + 1..]).normalize().toString())),
                            ValueField("path", textValue(path)), ValueField("mode", textValue("optional_metadata_directory")),
                            ValueField("max_files", integerValue(32)), ValueField("max_file_bytes", integerValue(65536))]))
                        metadata.add(path); continue
                    }
                    if (paths.size >= 128) { return initialContextError("context.sequence_result_limit") }
                    var found = false
                    for (source in observed where httpIntentText(source, "path") == path) {
                        if (httpIntentText(source, "kind") != "header") { return initialContextError("context.sequence_path_invalid") }
                        if (found) { return initialContextError("context.sequence_path_invalid") }; found = true
                        resources.add(objectValue([ValueField("source", source.field("source").getOrThrow()),
                            ValueField("path", textValue(path)), ValueField("mode", textValue("observed_text")),
                            ValueField("expected_witness", source.field("witness").getOrThrow())]))
                    }
                    if (!found) { return initialContextError("context.sequence_path_unobserved") }
                    paths.add(path)
                }
                nextQuery = Some(query); selectedPaths = paths.toArray(); metadataPaths = metadata.toArray()
            } finally { output.close() }
            match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!resources.isEmpty()) { return Result.Ok(ContextReadNext.Read(read(listValue(resources.toArray()), facts,
                parseUnifiedJson(nextQuery.getOrThrow())))) }
        } else if (nextQuery.isNone()) { return initialContextError("context.sequence_order_invalid") }
        let merged = ArrayList<AgentValue>()
        let bodies: Array<AgentValue> = if (phase == 2) { facts[facts.size - 1].output().field("resources").getOrThrow().items.toArray() } else { [] }
        if (bodies.size != selectedPaths.size + metadataPaths.size) { return initialContextError("context.sequence_bodies_invalid") }
        let bodyPaths = HashSet<String>()
        for (body in bodies) {
            let path = httpIntentText(body, "path")
            if ((!selectedPaths.contains(path) && !metadataPaths.contains(path)) || bodyPaths.contains(path)) { return initialContextError("context.sequence_bodies_invalid") }
            bodyPaths.add(path)
        }
        for (old in observed) {
            var replacement: ?AgentValue = None
            // Metadata directories have their own canonical fact/validation
            // below. They may share a path with an indexed directory and must
            // never enter the selected-file replacement branch.
            for (body in bodies where selectedPaths.contains(httpIntentText(body, "path")) &&
                httpIntentText(body, "path") == httpIntentText(old, "path")) {
                if (replacement.isSome() || httpIntentText(body, "kind") != "file" ||
                    httpIntentText(old, "witness") != httpIntentText(body, "witness") ||
                    httpIntentText(old, "source") != httpIntentText(body, "source")) {
                    return initialContextError("context.sequence_bodies_changed") }
                let error = body.field("error") ?? nullValue()
                if (error.unifiedKind != ValueKind.Null) {
                    if (error.unifiedKind != ValueKind.Text || error.text != "invalid_utf8") {
                        return initialContextError("context.sequence_body_error_invalid") }
                    // Preserve the earlier metadata and attach the new actual
                    // byte observation; never substitute an empty success.
                    let fields = ArrayList<ValueField>()
                    for (field in old.fields) { fields.add(field) }
                    fields.add(ValueField("body_error", textValue(error.text)))
                    fields.add(ValueField("body_sha256", body.field("sha256").getOrThrow()))
                    replacement = Some(objectValue(fields.toArray()))
                } else { replacement = Some(body) }
            }
            merged.add(replacement ?? old)
        }
        let metadata = ArrayList<AgentValue>()
        for (body in bodies where metadataPaths.contains(httpIntentText(body, "path"))) {
            if (!["metadata", "absence"].contains(httpIntentText(body, "kind"))) { return initialContextError("context.sequence_metadata_invalid") }
            metadata.add(body)
        }
        let projection = match (mergeInitialContextMetadataProjection(merged.toArray(), metadata.toArray())) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let query = withData(parseUnifiedJson(nextQuery.getOrThrow()), projection, facts)
        let selected = match (resolveObservedProductPluginContext(host, binding.namespace, binding.contribution,
            query, before.threadId, [], context.cancellation, ids.nextInvocationId(), observedFacts: facts)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let owner = binding.namespace + "/context/" + binding.contribution
        let items = ArrayList<InvocationContextContribution>()
        for (item in before.contextSnapshot.contributions() where item.owner != owner) { items.add(item) }
        for (item in selected.contributions()) {
            if (item.owner != owner) { return initialContextError("context.update_owner_invalid") }; items.add(item) }
        let snapshot = InvocationContextProjection(contributions: items.toArray())
        Result.Ok(ContextReadNext.Ready(InvocationContextProjection(contributions: items.toArray(), sourceDigest:
            modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("context", contextSnapshotValue(snapshot)),
                ValueField("facts", contextReadFactLinksValue(facts.map { value => value.link() }))]))))))
    }
}

// Data projection only. Both observations already came from this sequence's
// canonical facts; all original fact links remain in the query and final CAS.
// An indexed directory and its later metadata are one logical source, not two
// competing entries. Only this exact witnessed refinement may replace a row.
func mergeInitialContextMetadataProjection(observed: Array<AgentValue>, metadata: Array<AgentValue>): Result<Array<AgentValue>> {
    let paths = HashSet<String>()
    for (item in metadata) {
        let path = httpIntentText(item, "path")
        if (!readViewRelativePath(path) || paths.contains(path) ||
            !["metadata", "absence"].contains(httpIntentText(item, "kind"))) {
            return initialContextError("context.sequence_metadata_invalid") }
        paths.add(path)
    }
    let result = ArrayList<AgentValue>(); let seen = HashSet<String>()
    for (old in observed) {
        let path = httpIntentText(old, "path")
        if (seen.contains(path)) { return initialContextError("context.sequence_metadata_invalid") }
        seen.add(path)
        var replacement: ?AgentValue = None
        for (item in metadata where httpIntentText(item, "path") == path) {
            if (httpIntentText(old, "kind") != "directory" || httpIntentText(item, "kind") != "metadata" ||
                httpIntentText(old, "source") == "" || httpIntentText(old, "witness") == "" ||
                httpIntentText(old, "source") != httpIntentText(item, "source") ||
                httpIntentText(old, "witness") != httpIntentText(item, "witness")) {
                return initialContextError("context.sequence_metadata_changed") }
            replacement = Some(item)
        }
        result.add(replacement ?? old)
    }
    for (item in metadata where !seen.contains(httpIntentText(item, "path"))) { result.add(item) }
    Result.Ok(result.toArray())
}
