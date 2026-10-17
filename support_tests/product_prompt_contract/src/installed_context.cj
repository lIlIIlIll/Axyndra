package product_prompt_contract

import agent_core.*
import agent_domain.*
import agent_product.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.env.*
import yjson.*
import yjson_support.*

func promptDistributionRoot(): String {
    getVariable("AXYNDRA_CODING_DISTRIBUTION").getOrThrow()
}
func promptConfigureReadScopes(settings: String): Unit {
    Directory.create(settings + "/plugins", recursive: true)
    File.writeTo(settings + "/plugins/read-scopes.json",
        ("{\"version\":1,\"roots\":[\"$" + "{settings_root}/managed-skills\",\"$" + "{settings_root}/skills\"]}").toArray())
}
func promptStoredContext(product: ProductRuntime, run: RunId): InvocationContextProjection {
    let database = SqliteDatabase(product.stateRoot + "/state.db")
    try {
        contextSnapshotFromValue(decodeStoredValue(database.query("SELECT skill_snapshot FROM runs WHERE id=?",
            [SqlParameter.Text(run.value)])[0].required(0)))
    } finally { database.close() }
}
func promptSelectedContext(product: ProductRuntime, prompt: String): InvocationContextProjection {
    let request = product.request(prompt)
    expect(request.initializeContext && request.contextSnapshot.contributions().isEmpty(),
        "normal installed selection defers all host reads to the real Run")
    expect(product.client.start(request, { _ => () }).isOk(), "installed provider completes actual context preparation")
    promptStoredContext(product, request.runId)
}
func promptContribution(snapshot: InvocationContextProjection, id: String): ?InvocationContextContribution {
    for (value in snapshot.contributions() where value.id == id) { return Some(value) }
    None
}
func promptHasSelected(snapshot: InvocationContextProjection): Bool {
    for (value in snapshot.contributions() where value.owner.endsWith("/context/skills") && value.id != "catalog") { return true }
    false
}
func promptReference(product: ProductRuntime, snapshot: InvocationContextProjection,
    contribution: String, reference: String, thread: String): String {
    let owner = promptContribution(snapshot, contribution).getOrThrow().owner
    let arguments = objectValue([ValueField("owner", textValue(owner)), ValueField("contribution", textValue(contribution)),
        ValueField("reference", textValue(reference))])
    product.fixtureProbe.getOrThrow().enqueueToolCallReply("prompt-reference", "read_context_resource", arguments)
    let request = product.request("Load the declared reference", sessionId: Some(SessionId(thread)), contextSnapshot: Some(snapshot))
    expect(!request.initializeContext && product.client.start(request, { _ => () }).isOk(), "reference follows the same canonical Tool path")
    let database = SqliteDatabase(product.stateRoot + "/state.db")
    try {
        for (item in SqliteThreadCommitSink(database).loadThread(ThreadId(thread)).items) {
            match (item.content) {
                case ThreadItemContent.ToolResult(id, _, _, output, isError) => if (id.value == "prompt-reference") {
                    expect(!isError, "reference commits a successful canonical result")
                    return output.field("content").getOrThrow().text }
                case _ => ()
            }
        }
        throw IllegalStateException("canonical reference ToolResult is missing")
    } finally { database.close() }
}

// Canonical goal creation for this contract. A goal is a document owned by the
// workflow plugin; the product only projects it (ProductGoalState) and needs a
// matching operator selection before it can resolve the active objective. This
// installs and selects the actual package through the same public operator path
// a user takes, then runs the real /goal command. It creates no goal writer,
// Source, continuation authority or fixture-only executor.
class PromptRegistryCopyDebt {
    let payment: LogicalJsonOwnerReservation
    let previous: ?PromptRegistryCopyDebt
    init(payment: LogicalJsonOwnerReservation, previous: ?PromptRegistryCopyDebt) {
        this.payment = payment; this.previous = previous
    }
}
var promptRegistryCopyDebt: ?PromptRegistryCopyDebt = None<PromptRegistryCopyDebt>

// The copied descriptor text is paid from the SAME private registry bank the
// source path uses, exactly as the sibling installed contracts do. No payment
// is dropped before its real user returns.
func promptRegistryText(result: PluginRegistryResult<OwnedRegistryUtf8>): String {
    let source = match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("registry descriptor copy failed") }
    try {
        let size = source.byteCount
        if (size < 0 || size > (134217728 - 8192) / 64) { throw LogicalJsonPayloadError("fixture registry copy exceeds the original shared capacity") }
        let payment = source.deriveCopiedDataPayment(size * 64 + 8192)
        promptRegistryCopyDebt = Some(PromptRegistryCopyDebt(payment, promptRegistryCopyDebt))
        String.fromUtf8(Array<UInt8>(size, { index => source.byteAt(index) }))
    } finally { source.close() }
}

// Configuration-only copies stop being live after their JSON has been
// published and the command has returned. Keep returned namespace copies
// outside this scope paid for the contract's remaining lifetime.
func promptWithRegistryCopies(action: () -> Unit): Unit {
    let boundary = promptRegistryCopyDebt
    try { action() } finally {
        while (true) {
            let debt = match (promptRegistryCopyDebt) {
                case Some(value) => value
                case None => break
            }
            if (boundary.isSome() && refEq(debt, boundary.getOrThrow())) { break }
            promptRegistryCopyDebt = debt.previous
            debt.payment.close()
        }
    }
}

func promptCreateGoal(product: ProductRuntime, session: SessionId, objective: String): Unit {
    promptWithRegistryCopies({ =>
    let record = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("workflow goal component import failed") }
    let namespace = promptRegistryText(record.descriptor.copyText(PluginDescriptorText.Namespace))
    let digest = promptRegistryText(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
    record.close()
    let directory = product.settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    let goalRight = objectValue([ValueField("key", textValue("goal")), ValueField("read", boolValue(true)), ValueField("write", boolValue(true))])
    promptAppendPluginDocuments(product, objectValue([
        ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(digest)),
        ValueField("tools", listValue([objectValue([ValueField("name", textValue("goal")),
            ValueField("preparation_provider", textValue("prepare_document")),
            ValueField("documents", listValue([goalRight]))])]))]))
    File.writeTo(directory + "/goal-tools.json", stringifyUnifiedJson(objectValue([
        ValueField("schema", textValue("axyndra.goal-tools/v1")), ValueField("namespace", textValue(namespace)),
        ValueField("package_digest", textValue(digest)), ValueField("tool", textValue("goal")),
        ValueField("command", textValue("goal"))])).toArray())
    match (product.setPluginEnabled(namespace, true, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(discard) => discard.close()
        case PluginRegistryResult.Err(_) => throw IllegalStateException("workflow goal component enable failed") }
    let application = product.applicationSession(sessionId: Some(session))
    let routes = application.javascriptPluginCommands().filter { value => value.extensionId == namespace && value.name == "goal" }
    if (routes.size != 1) { throw IllegalStateException("the selected workflow goal command route is unavailable") }
    match (application.invokeJavaScriptPluginCommand(routes[0].routeName, "set \"" + objective + "\"", { _, _ => () })) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException("canonical goal creation failed: " + error.code) }
    })
}

// Install and enable one real component through the public operator path. The
// plugin-first product no longer ships bare builtin tools, so a contract that
// exercises a contributed tool must first install its actual package. This
// creates no fixture-only executor, alias or Source.
func promptInstallComponent(product: ProductRuntime, packageVariable: String): String {
    let record = match (product.importLocalPlugin(getVariable(packageVariable).getOrThrow())) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("contract component import failed for " + packageVariable) }
    let namespace = promptRegistryText(record.descriptor.copyText(PluginDescriptorText.Namespace))
    record.close()
    let enabled = match (product.setPluginEnabled(namespace, true)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("contract component enable failed for " + packageVariable) }
    enabled.close()
    namespace
}

func promptAppendPluginDocuments(product: ProductRuntime, entry: AgentValue): Unit {
    let path = product.settingsRoot + "/plugins/documents.json"
    let entries = ArrayList<AgentValue>()
    if (exists(Path(path))) {
        for (existing in parseUnifiedJson(String.fromUtf8(File.readFrom(path))).field("plugins").getOrThrow().items
            where httpIntentText(existing, "namespace") != httpIntentText(entry, "namespace")) { entries.add(existing) }
    }
    entries.add(entry)
    File.writeTo(path, stringifyUnifiedJson(objectValue([ValueField("version", integerValue(1)),
        ValueField("plugins", listValue(entries.toArray()))])).toArray())
}

func promptInstalledDigest(product: ProductRuntime, namespace: String): String {
    let records = product.pluginSnapshots()
    try {
        for (index in 0..records.size) {
            let record = records.at(index)
            if (record.descriptor.textEquals(PluginDescriptorText.Namespace, namespace)) {
                return promptRegistryText(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
            }
        }
        throw IllegalStateException("installed context package is unavailable: " + namespace)
    } finally { records.close() }
}

func promptConfigureMemory(product: ProductRuntime, namespace: String): Unit {
    promptWithRegistryCopies({ =>
    let directory = product.settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    promptAppendPluginDocuments(product, objectValue([
        ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(promptInstalledDigest(product, namespace))),
        ValueField("tools", listValue([objectValue([ValueField("name", textValue("retain")),
            ValueField("preparation_provider", textValue("prepare_document")),
            ValueField("payload_references", boolValue(true)), ValueField("effect_from_intents", boolValue(true)),
            ValueField("tool_payload_limits", OrdinaryToolPayloadLimits("retain").value()),
            ValueField("documents", listValue([objectValue([ValueField("key", textValue("journal")),
                ValueField("read", boolValue(true)), ValueField("write", boolValue(true))])]))])])),
        ValueField("backends", listValue([objectValue([ValueField("key", textValue("journal")),
            ValueField("layout", textValue("opaque-fact-events-v3"))])]))]))
    })
}

func promptSeedMemory(product: ProductRuntime, session: SessionId, namespace: String, arguments: AgentValue): Unit {
    // Native Memory deliberately has no user command contribution. Its tool
    // needs a real Run's completed ContextRead, not the rejecting Direct path.
    let application = product.applicationSession(sessionId: Some(session))
    expect(application.javascriptPluginCommands().filter { value =>
        value.extensionId == namespace && value.name == "retain" }.isEmpty(),
        "Native Memory exposes retain as a prepared tool rather than a user command")
    let call = "prompt-seed-memory"
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(call, "plugin." + namespace + ".retain", arguments)
    let request = product.request("Seed the contract memory", sessionId: Some(session))
    match (product.client.start(request, { _ => () })) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException("canonical memory seeding failed: " + error.code + ": " + error.message)
    }
    let database = SqliteDatabase(product.stateRoot + "/state.db")
    try {
        for (item in SqliteThreadCommitSink(database).loadThread(ThreadId(session.value)).items) {
            match (item.content) {
                case ThreadItemContent.ToolResult(id, _, _, output, isError) => if (id.value == call) {
                    expect(!isError, "canonical retain commits all scoped memory seeds: " + stringifyUnifiedJson(output))
                    return
                }
                case _ => ()
            }
        }
        throw IllegalStateException("canonical retain ToolResult is missing")
    } finally { database.close() }
}

func promptDocumentContextSelection(product: ProductRuntime, namespace: String, provider: String,
    key: String, query: AgentValue): AgentValue {
    objectValue([ValueField("version", integerValue(5)), ValueField("namespace", textValue(namespace)),
        ValueField("package_digest", textValue(promptInstalledDigest(product, namespace))),
        ValueField("provider", textValue(provider)), ValueField("resources", listValue([textValue(key)])),
        ValueField("query", query), ValueField("prompt_field", textValue(""))])
}

func promptConfigureBusinessContext(product: ProductRuntime, memoryNamespace: String): Unit {
    promptWithRegistryCopies({ =>
    let directory = product.settingsRoot + "/plugins"
    let goal = parseUnifiedJson(String.fromUtf8(File.readFrom(directory + "/goal-tools.json")))
    let goalNamespace = httpIntentText(goal, "namespace")
    let selections = ArrayList<AgentValue>()
    // Retain the installed distribution's real Skill discovery provider.
    let original = parseUnifiedJson(String.fromUtf8(File.readFrom(directory + "/context.json")))
    if (original.field("version").getOrThrow().asNumberText() == "6") {
        for (selection in original.field("selections").getOrThrow().items) { selections.add(selection) }
    } else { selections.add(original) }
    selections.add(promptDocumentContextSelection(product, goalNamespace, "goal_context", "goal",
        objectValue([ValueField("schema", textValue("axyndra.goal-context-query/v1"))])))
    selections.add(promptDocumentContextSelection(product, memoryNamespace, "memory_context", "journal",
        objectValue([ValueField("schema", textValue("axyndra.memory-context-query/v1")),
            ValueField("query", textValue("PROMPT-MEMORY-QUERY")), ValueField("max_bytes", integerValue(16384))])))
    let providers = [objectValue([ValueField("namespace", textValue(memoryNamespace)),
        ValueField("package_digest", textValue(promptInstalledDigest(product, memoryNamespace))),
        ValueField("provider", textValue("memory_context")), ValueField("keys", listValue([textValue("journal")]))]),
        objectValue([ValueField("namespace", textValue(goalNamespace)),
        ValueField("package_digest", textValue(promptInstalledDigest(product, goalNamespace))),
        ValueField("provider", textValue("goal_context")), ValueField("keys", listValue([textValue("goal")]))])]
    File.writeTo(directory + "/document-context.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("providers", listValue(providers))])).toArray())
    File.writeTo(directory + "/context.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(6)), ValueField("selections", listValue(selections.toArray()))])).toArray())
    })
}
