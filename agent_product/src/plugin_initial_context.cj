package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// An explicit operator selection is configuration. All selected resources
// still pass the actual Run policy, including each read in a composition.
class ProductInitialContextSelection {
    let namespace: String
    let packageDigest: String
    let provider: String
    let digest: String
    let preparationProtocol: Bool
    let documentProtocol: Bool
    let journalProtocol: Bool
    let journalDataSchema: String
    let journalPreparationSchema: String
    let windowProtocol: Bool
    let preparationProvider: String
    let componentSources: ?ProductContextComponentSnapshot
    private let runtime: ?ProductPluginRuntime
    private let componentKinds: Array<String>
    private let settingsRoot: String
    private let frozen: String
    init(settingsRoot: String, value: AgentValue, encoded: String, runtime: ?ProductPluginRuntime, kinds: Array<String>, sources: ?ProductContextComponentSnapshot) {
        this.settingsRoot = settingsRoot; this.frozen = stringifyUnifiedJson(value)
        this.digest = modelPolicySha256Text(encoded)
        this.namespace = httpIntentText(value, "namespace")
        this.packageDigest = httpIntentText(value, "package_digest")
        this.provider = httpIntentText(value, "provider")
        this.documentProtocol = value.field("version").getOrThrow().asNumberText() == "5"
        this.journalProtocol = value.field("version").getOrThrow().asNumberText() == "8"
        this.journalDataSchema = httpIntentText(value, "data_schema")
        this.journalPreparationSchema = httpIntentText(value, "preparation_schema")
        this.windowProtocol = value.field("version").getOrThrow().asNumberText() == "7"
        this.preparationProvider = httpIntentText(value, "preparation_provider")
        this.preparationProtocol = ["2","3","4"].contains(value.field("version").getOrThrow().asNumberText())
        this.runtime = runtime; this.componentKinds = kinds.clone(); this.componentSources = sources
    }
    func componentProfile(): AgentValue { parseUnifiedJson(frozen).field("component_sources").getOrThrow() }
    func resources(): AgentValue { parseUnifiedJson(frozen).field("resources").getOrThrow() }
    func query(prompt: String): AgentValue {
        let value = parseUnifiedJson(frozen)
        let fields = ArrayList<ValueField>()
        for (field in value.field("query").getOrThrow().fields) { fields.add(field) }
        let name = httpIntentText(value, "prompt_field")
        if (name != "") { fields.add(ValueField(name, textValue(prompt))) }
        objectValue(fields.toArray())
    }
    func current(): Result<Unit> {
        match (componentSources) {
            case Some(sources) => match (sources.validate(runtime.getOrThrow(), componentKinds)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => ()
        }
        match (initialContextConfigText(settingsRoot)) {
            case Result.Ok(value) => if (modelPolicySha256Text(value) == digest) { Result.Ok(()) }
                else { initialContextError("context.initial_configuration_changed") }
            case Result.Err(_) => initialContextError("context.initial_configuration_changed") }
    }
}

func hasInitialContextConfiguration(settingsRoot: String): Bool {
    // Even malformed/unsafe configuration selects the new path so it fails
    // explicitly instead of silently falling back to legacy filesystem reads.
    let path = Path(settingsRoot).join("plugins/context.json")
    if (exists(path)) { return true }
    try { FileInfo(path).isSymbolicLink() } catch (_: Exception) { false }
}
func initialContextConfigText(settingsRoot: String): Result<String> {
    try {
        let root = canonicalize(Path(settingsRoot)).toString()
        let directory = Path(root).join("plugins")
        let path = directory.join("context.json")
        if (!exists(path) || FileInfo(directory).isSymbolicLink() || FileInfo(path).isSymbolicLink() ||
            !FileInfo(path).isRegular() || FileInfo(path).size > 65536) {
            return initialContextError("context.initial_configuration_invalid") }
        let text = String.fromUtf8(File.readFrom(path))
        if (text.size < 1 || text.size > 65536) { return initialContextError("context.initial_configuration_invalid") }
        Result.Ok(text)
    } catch (_: Exception) { initialContextError("context.initial_configuration_invalid") }
}
func loadInitialContextSelection(settingsRoot: String, runtime!: ?ProductPluginRuntime = None): Result<ProductInitialContextSelection> {
    let text = match (initialContextConfigText(settingsRoot)) { case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error) }
    parseInitialContextSelection(settingsRoot, text, runtime)
}

func parseInitialContextSelection(settingsRoot: String, text: String, runtime: ?ProductPluginRuntime,
    configurationText!: ?String = None): Result<ProductInitialContextSelection> {
    try {
        let value = parseUnifiedJson(text, maxBytes: 65536, maxDepth: 32)
        if (value.field("version").isSome() && value.field("version").getOrThrow().unifiedKind == ValueKind.Number &&
            value.field("version").getOrThrow().asNumberText() == "8") {
            return parseInitialContextJournalSelection(settingsRoot, value, configurationText ?? text, runtime) }
        if (value.field("version").isSome() && value.field("version").getOrThrow().unifiedKind == ValueKind.Number &&
            value.field("version").getOrThrow().asNumberText() == "7") {
            return parseInitialContextWindowSelection(settingsRoot, value, configurationText ?? text, runtime) }
        if (value.field("version").isSome() && value.field("version").getOrThrow().unifiedKind == ValueKind.Number &&
            value.field("version").getOrThrow().asNumberText() == "4") {
            if (runtime.isNone()) { return initialContextError("context.initial_workspace_missing") }
            match (bindInitialContextRootTemplates(value, settingsRoot, runtime.getOrThrow().workspaceRoot)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        let componentMode = value.field("version").isSome() && value.field("version").getOrThrow().unifiedKind == ValueKind.Number && ["3", "4"].contains(value.field("version").getOrThrow().asNumberText())
        let fields = ArrayList<String>(["version", "namespace", "package_digest", "provider", "resources", "query", "prompt_field"])
        if (componentMode) { fields.add("component_sources") }
        if (!httpIntentExactFields(value, fields.toArray()) ||
            value.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
            !["1", "2", "3", "4", "5"].contains(value.field("version").getOrThrow().asNumberText())) { return initialContextError("context.initial_configuration_invalid") }
        for (key in ["namespace", "package_digest", "provider", "prompt_field"]) {
            if (value.field(key).getOrThrow().unifiedKind != ValueKind.Text || httpIntentText(value, key).size > 256) {
                return initialContextError("context.initial_configuration_invalid") } }
        let digest = httpIntentText(value, "package_digest")
        if (httpIntentText(value, "namespace") == "" || httpIntentText(value, "provider") == "" ||
            digest.size != 71 || !digest.startsWith("sha256:")) { return initialContextError("context.initial_configuration_invalid") }
        for (byte in digest[7..].toArray() where !((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return initialContextError("context.initial_configuration_invalid") }
        let resources = value.field("resources").getOrThrow(); let query = value.field("query").getOrThrow()
        if (resources.unifiedKind != ValueKind.List || resources.items.size < 1 || resources.items.size > 64 ||
            query.unifiedKind != ValueKind.Object || query.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
            return initialContextError("context.initial_configuration_invalid") }
        if(value.field("version").getOrThrow().asNumberText()=="5"){
            let keys=HashSet<String>()
            if(resources.items.size>8){return initialContextError("context.initial_configuration_invalid")}
            for(key in resources.items){
                if(key.unifiedKind!=ValueKind.Text || !initialContextDocumentKeyValid(key.text) || keys.contains(key.text)){
                    return initialContextError("context.initial_configuration_invalid")}
                keys.add(key.text)}
        }
        let promptField = httpIntentText(value, "prompt_field")
        if (promptField != "") {
            if (promptField.size > 64 || promptField == CONTEXT_READ_INPUT_FIELD || query.field(promptField).isSome()) {
                return initialContextError("context.initial_configuration_invalid") }
            for (byte in promptField.toArray() where !((byte >= b'a' && byte <= b'z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'_')) { return initialContextError("context.initial_configuration_invalid") }
        }
        let kinds = ArrayList<String>(); var sources: ?ProductContextComponentSnapshot = None
        if (componentMode) {
            let profile = value.field("component_sources").getOrThrow()
            if (runtime.isNone() || !contextComponentProfileValid(profile)) { return initialContextError("context.component_configuration_invalid") }
            for (kind in profile.field("kinds").getOrThrow().items) { kinds.add(kind.text) }
            sources = Some(runtime.getOrThrow().contextComponentSnapshot(kinds.toArray()))
        }
        Result.Ok(ProductInitialContextSelection(settingsRoot, value, configurationText ?? text, runtime, kinds.toArray(), sources))
    } catch (_: Exception) { initialContextError("context.initial_configuration_invalid") }
}

class ProductInitialContextPreparation <: InitialContextPreparationPort {
    private let settingsRoot: String
    private let host: ProductJavaScriptPluginHost
    private let ids: ProductIds
    private let runtime: ProductPluginRuntime
    private let operations: OperationRuntimePort
    init(settingsRoot: String, host: ProductJavaScriptPluginHost, ids: ProductIds, runtime: ProductPluginRuntime, operations: OperationRuntimePort) {
        this.settingsRoot = settingsRoot; this.host = host; this.ids = ids; this.runtime = runtime; this.operations = operations
    }
    public func prepare(request: AgentRunRequest, context: ToolInvocationContext,
        active: ActiveRunSnapshot): Result<InitialContextPreparation> {
        let selections = match (loadInitialContextSelections(settingsRoot, runtime: Some(runtime))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        match (preflightInitialContextSelections(host, selections, request.prompt)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (selections.size == 1) { return prepareOne(selections[0], request, context, active) }
        let plans = ArrayList<InitialContextPreparation>()
        for (selection in selections) {
            match (prepareOne(selection, request, context, active)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => plans.add(value) }
        }
        let multiple = ProductInitialContextMultipleSequence(host, selections, plans.toArray(), active, context.cancellation)
        return Result.Ok(InitialContextPreparation(multiple.first(), validity: { => multiple.validate() },
            sequence: Some(ContextReadSequence(multiple.maximumReads, { current, facts => multiple.advance(current, facts) },
                transition: Some({ old, next => multiple.validateTransition(old, next) })))))
    }
    private func prepareOne(selection: ProductInitialContextSelection, request: AgentRunRequest,
        context: ToolInvocationContext, active: ActiveRunSnapshot): Result<InitialContextPreparation> {
        let actual = match (host.contentProviderBinding(selection.namespace, selection.provider, false)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (actual.digest != selection.packageDigest || active.threadId.value != context.sessionId.value ||
            active.runId.value != request.runId.value || active.epoch != context.epoch) {
            return initialContextError("context.initial_binding_changed") }
        if(selection.journalProtocol){
            return productInitialJournalContextPreparation(host, operations, selection, actual, active, context, request.prompt, ids)
        }
        if(selection.windowProtocol){
            return productInitialDocumentWindowPreparation(host, operations, selection, actual, active, context, request.prompt, ids)
        }
        if(selection.documentProtocol){
            let prepared=match(productDocumentContextProviderRead(host,operations,selection.namespace,selection.provider,active,context,
                selection.resources(),selection.query(request.prompt),ids.nextInvocationId(),{=>selection.current()})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            return Result.Ok(InitialContextPreparation(prepared.read,validity:prepared.validity))
        }
        if (selection.preparationProtocol) {
            let inputs = match (contextComponentInputs(host, selection, actual, request.prompt, active.threadId, context.cancellation, ids)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            let sequence = ProductInitialContextSequence(host, selection, actual, active, request.prompt, context.cancellation, ids, inputs)
            return Result.Ok(InitialContextPreparation(sequence.first(), validity: { => sequence.validate() },
                sequence: Some(ContextReadSequence(if (selection.componentSources.isSome()) { 3 } else { 2 }, { current, facts => sequence.advance(current, facts) }))))
        }
        let prepared = match (productContextProviderRead(host, selection.namespace, selection.provider,
            active, selection.resources(), selection.query(request.prompt), context.cancellation, [], ids.nextInvocationId(),
            sourceDigest: selection.digest, sourceValidity: { => selection.current() })) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        Result.Ok(InitialContextPreparation(prepared.read, validity: prepared.validity))
    }
}
func initialContextDocumentKeyValid(value: String): Bool {
    if (value == "" || value.size > 128 || value == "." || value == "..") { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-' || byte == b'.')) { return false }
    }
    true
}
func initialContextError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code,
        "initial context configuration or its exact installed binding is unavailable"))
}
