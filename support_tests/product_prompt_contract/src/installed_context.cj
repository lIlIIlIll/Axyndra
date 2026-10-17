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
    for (value in snapshot.contributions() where value.id != "catalog") { return true }
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

func promptCreateGoal(product: ProductRuntime, session: SessionId, temporary: String, objective: String): Unit {
    let record = match (product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("workflow goal component import failed") }
    let namespace = promptRegistryText(record.descriptor.copyText(PluginDescriptorText.Namespace))
    let digest = promptRegistryText(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
    let directory = product.settingsRoot + "/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    let goalRight = objectValue([ValueField("key", textValue("goal")), ValueField("read", boolValue(true)), ValueField("write", boolValue(true))])
    File.writeTo(directory + "/documents.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
            ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(digest)),
            ValueField("tools", listValue([objectValue([ValueField("name", textValue("goal")),
                ValueField("preparation_provider", textValue("prepare_document")),
                ValueField("documents", listValue([goalRight]))])]))])]))])).toArray())
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
    let enabled = match (product.setPluginEnabled(namespace, true)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw IllegalStateException("contract component enable failed for " + packageVariable) }
    enabled.close()
    namespace
}
