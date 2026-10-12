package agent_product

import agent_plugin_registry
import agent_plugin_registry.*

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Compatibility name for the one existing registry's locked data projection.
type ProductContextComponentSnapshot = agent_plugin_registry.RegistryContextComponentSnapshot

func contextComponentKind(kind: PluginComponentKind): String { agent_plugin_registry.registryContextComponentKind(kind) }

class ProductInitialContextInputs {
    private let encodedResources: String
    private let encodedQuery: String
    init(resources: AgentValue, query: AgentValue) {
        this.encodedResources = stringifyUnifiedJson(resources); this.encodedQuery = stringifyUnifiedJson(query)
    }
    func resources(): AgentValue { parseUnifiedJson(encodedResources, maxBytes: RUN_CONTEXT_SNAPSHOT_MAX_BYTES) }
    func query(): AgentValue { parseUnifiedJson(encodedQuery, maxBytes: RUN_CONTEXT_SNAPSHOT_MAX_BYTES) }
}

class ProductComponentHeaderSelection {
    private let inputs: ProductInitialContextInputs
    let paths: Array<String>
    init(resources: AgentValue, query: AgentValue, paths: Array<String>) {
        this.inputs = ProductInitialContextInputs(resources, query); this.paths = paths.clone()
    }
    func resources(): AgentValue { inputs.resources() }
    func query(): AgentValue { inputs.query() }
}

func selectComponentContextHeaders(host: ProductJavaScriptPluginHost, binding: ProductPluginContentBinding,
    selection: ProductInitialContextSelection, query: AgentValue, observed: Array<AgentValue>, thread: ThreadId,
    cancellation: CancellationToken, ids: ProductIds): Result<ProductComponentHeaderSelection> {
    let frozen = try { FrozenPluginContentQuery(query, [], observed: true) }
        catch (_: Exception) { return initialContextError("context.component_projection_limit") }
    let response = try { contentProviderQuery(host, binding, frozen.query, thread, cancellation, ids.nextInvocationId()) }
        finally { frozen.close() }
    let output = match (response) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    try {
        let value = output.value
        if (!httpIntentExactFields(value, ["schema", "reads", "query"]) || httpIntentText(value, "schema") != "axyndra.context-preparation/v1" ||
            value.field("reads").getOrThrow().unifiedKind != ValueKind.List || value.field("reads").getOrThrow().items.size > 1024 ||
            value.field("query").getOrThrow().unifiedKind != ValueKind.Object || value.field("query").getOrThrow().field(CONTEXT_READ_INPUT_FIELD).isSome()) {
            return initialContextError("context.component_headers_invalid") }
        let requests = ArrayList<AgentValue>(); let paths = ArrayList<String>()
        let profile = selection.componentProfile(); let header = profile.field("header").getOrThrow()
        for (item in value.field("reads").getOrThrow().items) {
            if (!httpIntentExactFields(item, ["path", "mode"]) || httpIntentText(item, "mode") != "header") {
                return initialContextError("context.component_headers_invalid") }
            let path = httpIntentText(item, "path")
            if (!readViewRelativePath(path) || paths.contains(path)) { return initialContextError("context.component_headers_invalid") }
            var source: ?String = None; var witness = ""
            for (resource in observed where httpIntentText(resource, "kind") == "index") {
                let prefix = httpIntentText(resource, "path") + "/"
                if (!path.startsWith(prefix)) { continue }
                let relative = path[prefix.size..]
                for (entry in resource.field("entries").getOrThrow().items where httpIntentText(entry, "kind") == "file" &&
                    httpIntentText(entry, "relative") == relative) {
                    if (source.isSome()) { return initialContextError("context.component_headers_invalid") }
                    source = Some(Path(httpIntentText(resource, "source")).join(relative).toString()); witness = httpIntentText(entry, "witness")
                }
            }
            if (source.isNone()) { return initialContextError("context.component_header_unobserved") }
            let fields = ArrayList<ValueField>([ValueField("source", textValue(source.getOrThrow())), ValueField("path", textValue(path)),
                ValueField("mode", textValue("observed_header")), ValueField("expected_witness", textValue(witness)),
                ValueField("max_file_bytes", profile.field("index").getOrThrow().field("max_file_bytes").getOrThrow()),
                ValueField("basename", profile.field("index").getOrThrow().field("basename").getOrThrow()),
                ValueField("depth", integerValue(0)), ValueField("max_files", integerValue(1))])
            for (field in header.fields) { fields.add(field) }
            requests.add(objectValue(fields.toArray())); paths.add(path)
        }
        match (selection.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(ProductComponentHeaderSelection(listValue(requests.toArray()), value.field("query").getOrThrow(), paths.toArray()))
    } catch (_: Exception) { initialContextError("context.component_headers_invalid") }
    finally { output.close() }
}

func contextComponentProfileValid(profile: AgentValue): Bool {
    if (!httpIntentExactFields(profile, ["kinds", "index", "header"])) { return false }
    let kinds = profile.field("kinds").getOrThrow()
    if (kinds.unifiedKind != ValueKind.List || kinds.items.size < 1 || kinds.items.size > 8) { return false }
    let seen = HashSet<String>()
    for (kind in kinds.items) {
        if (kind.unifiedKind != ValueKind.Text || !["skill", "mcp", "prompt", "extension", "hook", "command", "theme", "hosted"].contains(kind.text) ||
            seen.contains(kind.text)) { return false }; seen.add(kind.text)
    }
    let index = profile.field("index").getOrThrow(); let header = profile.field("header").getOrThrow()
    if (!httpIntentExactFields(index, ["basename", "max_file_bytes", "depth", "max_directories"]) ||
        !httpIntentExactFields(header, ["max_bytes", "start_marker", "end_marker", "trim_ascii"]) ||
        header.field("trim_ascii").getOrThrow().unifiedKind != ValueKind.Boolean) { return false }
    let request = ArrayList<ValueField>([ValueField("source", textValue("/bounded")), ValueField("path", textValue("bounded")),
        ValueField("mode", textValue("optional_directory_index")), ValueField("order", textValue("native")), ValueField("starts", listValue([textValue("")]))])
    for (field in index.fields) { request.add(field) }
    if (!contextIndexRequestValid(objectValue(request.toArray())) || header.field("max_bytes").getOrThrow().unifiedKind != ValueKind.Number) { return false }
    let maximum = try { Int64.parse(header.field("max_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    if (maximum < 1 || maximum > 65536) { return false }
    for (key in ["start_marker", "end_marker"]) {
        let marker = httpIntentText(header, key)
        if (marker == "" || marker.size > 64) { return false }
        for (byte in marker.toArray() where byte < 33 || byte > 126) { return false }
    }
    true
}

func contextComponentInputs(host: ProductJavaScriptPluginHost, selection: ProductInitialContextSelection,
    binding: ProductPluginContentBinding, prompt: String, thread: ThreadId, cancellation: CancellationToken,
    ids: ProductIds): Result<ProductInitialContextInputs> {
    let captured = match (selection.componentSources) {
        case Some(value) => value
        case None => return Result.Ok(ProductInitialContextInputs(selection.resources(), selection.query(prompt))) }
    match (selection.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let query = objectValue([ValueField("schema", textValue("axyndra.context-sources-query/v1")),
        ValueField("components", productRegistryCopyJson83(captured.copyValueJson())), ValueField("query", selection.query(prompt))])
    let frozen = try { FrozenPluginContentQuery(query, []) } catch (_: Exception) { return initialContextError("context.component_projection_limit") }
    let response = try { contentProviderQuery(host, binding, frozen.query, thread, cancellation, ids.nextInvocationId()) }
        finally { frozen.close() }
    let output = match (response) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    try {
        let value = output.value
        if (!httpIntentExactFields(value, ["schema", "reads", "query"]) || httpIntentText(value, "schema") != "axyndra.context-sources/v1" ||
            value.field("reads").getOrThrow().unifiedKind != ValueKind.List || value.field("reads").getOrThrow().items.size > 256 ||
            value.field("query").getOrThrow().unifiedKind != ValueKind.Object || value.field("query").getOrThrow().field(CONTEXT_READ_INPUT_FIELD).isSome()) {
            return initialContextError("context.component_projection_invalid") }
        let resources = ArrayList<AgentValue>(selection.resources().items.toArray()); let aliases = HashSet<String>()
        let profile = selection.componentProfile().field("index").getOrThrow()
        let maximumDepth = Int64.parse(profile.field("depth").getOrThrow().asNumberText())
        for (item in value.field("reads").getOrThrow().items) {
            if (!httpIntentExactFields(item, ["alias", "starts", "depth", "order"]) || item.field("depth").getOrThrow().unifiedKind != ValueKind.Number) {
                return initialContextError("context.component_projection_invalid") }
            let alias = httpIntentText(item, "alias"); let depth = Int64.parse(item.field("depth").getOrThrow().asNumberText())
            if (aliases.contains(alias) || depth < 0 || depth > maximumDepth) { return initialContextError("context.component_projection_invalid") }
            aliases.add(alias)
            let root = match (captured.root(alias)) {
                case PluginRegistryResult.Ok(current) => productRegistryCopyText83(PluginRegistryResult.Ok(current))
                case PluginRegistryResult.Err(error) => return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code,
                    productRegistryErrorText83(error, PluginRegistryErrorText.Message))) }
            let fields = ArrayList<ValueField>([ValueField("source", textValue(root)), ValueField("path", textValue(alias)),
                ValueField("mode", textValue("optional_directory_index")), ValueField("order", item.field("order").getOrThrow()), ValueField("starts", item.field("starts").getOrThrow())])
            for (field in profile.fields) { fields.add(if (field.name == "depth") { ValueField("depth", integerValue(depth)) } else { field }) }
            let request = objectValue(fields.toArray())
            if (!contextIndexRequestValid(request)) { return initialContextError("context.component_projection_invalid") }
            resources.add(request)
        }
        if (resources.size > 256) { return initialContextError("context.component_projection_limit") }
        match (selection.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(ProductInitialContextInputs(listValue(resources.toArray()), value.field("query").getOrThrow()))
    } catch (_: Exception) { initialContextError("context.component_projection_invalid") }
    finally { output.close() }
}
