package product_prompt_contract

import agent_core.*
import agent_domain.*
import agent_product.*
import agent_store.*
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
