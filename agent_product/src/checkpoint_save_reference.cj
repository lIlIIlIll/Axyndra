package agent_product

import agent_domain.*
import agent_core.modelMessagesFromCanonicalItems
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// A synchronous, invocation-local data loan. The selected current Native
// provider chooses business fields and recipes. The consumer must independently
// use the canonical Store proof; a provider ordinal cannot grant a legal cut.
public type ProductCheckpointSavePolicy113 = (ToolInvocationContext, ToolResult,
    () -> Result<AgentThreadSnapshot>,
    (SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure>,
    (AgentThreadSnapshot, Int64, String, AgentValue, () -> Result<Unit>) -> Result<Unit>) -> Result<Unit>

func checkpointSaveClosedError113(value: AgentValue): ?AgentError {
    if (!httpIntentExactFields(value, ["error"])) { return None<AgentError> }
    let actual = value.field("error").getOrThrow()
    for ((kind, error) in [
        ("internal", AgentError(AgentErrorKind.Internal, "tool.rewind_report_missing",
            "persisted rewind result does not contain a report")),
        ("conflict", AgentError(AgentErrorKind.Conflict, "tool.checkpoint_missing",
            "No active checkpoint. Create a checkpoint before calling rewind.")),
        ("recovery_required", AgentError(AgentErrorKind.RecoveryRequired, "tool.rewind_result_not_canonical",
            "rewind checkpoint cannot be saved before its canonical ToolResult"))]) {
        let template = objectValue([ValueField("kind", textValue(kind)), ValueField("code", textValue(error.code)),
            ValueField("message", textValue(error.message)), ValueField("fields", listValue([]))])
        if (canonicalAgentValuesEqual(actual, template)) { return Some(error) }
    }
    throw IllegalStateException("checkpoint save error differs from its original closed codec")
}

func checkpointSaveActualHistory113(query: ProductCompactionReferenceQuery,
    thread: AgentThreadSnapshot, target: String): AgentValue {
    var state = query.query("checkpoint_begin", [ValueField("total", integerValue(thread.items.size))])
    let actualTarget = query.references.intern(target)
    for (after in [false, true]) {
        if (after) {
            let next = query.query("checkpoint_after_begin", [ValueField("state", state)])
            query.release(state); state = next }
        var offset: Int64 = 0
        while (offset < thread.items.size) {
            query.check()
            let end = min(thread.items.size, offset + 64); let events = ArrayList<AgentValue>()
            for (item in thread.items[offset..end]) { events.add(checkpointPolicyReferenceEvent113(query, thread, item)) }
            let batch = query.copy(listValue(events.toArray()))
            let fields = ArrayList<ValueField>([ValueField("state", state), ValueField("events", batch)])
            if (!after) { fields.add(ValueField("target_call", actualTarget)) }
            let next = try { query.query(if (after) { "checkpoint_after_batch" } else { "checkpoint_latest_batch" }, fields.toArray()) }
                finally { query.release(batch) }
            if (compactionPageInteger(next, "offset") != end || compactionPageInteger(next, "total") != thread.items.size) {
                throw IllegalStateException("checkpoint save did not consume the complete actual event batch") }
            query.release(state); state = next; offset = end
        }
    }
    state
}

func queryProductCheckpointSavePolicy113(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
    binding: ProductPluginPolicyBinding, context: ToolInvocationContext, result: ToolResult,
    loadThread: () -> Result<AgentThreadSnapshot>,
    summary: (SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure>,
    consume: (AgentThreadSnapshot, Int64, String, AgentValue, () -> Result<Unit>) -> Result<Unit>,
    requestId: String, cancellation: CancellationToken): Result<Unit> {
    let query = try { ProductCompactionReferenceQuery(host, selection, modelPolicySha256Text(requestId),
        ThreadId(context.sessionId.value), cancellation, requestId, binding) }
        catch (error: ProductCompactionDataError) { return Result<Unit>.Err(error.error) }
    var structure: ?ProductCompactionStructure = None<ProductCompactionStructure>
    var retained: ?ProductPolicyValueLease = None<ProductPolicyValueLease>
    try {
        let layout = query.query("checkpoint_save_layout", [])
        if (!httpIntentExactFields(layout, ["report", "goal"])) { throw IllegalStateException("invalid checkpoint save layout") }
        let reportName = httpIntentText(layout, "report"); let goalName = httpIntentText(layout, "goal")
        if (reportName == "" || goalName == "" || reportName.size > 128 || goalName.size > 128) {
            throw IllegalStateException("checkpoint save selectors are not bounded metadata") }
        query.release(layout)
        let reportField = result.output.field(reportName)
        let report = query.references.intern(match (reportField) {
            case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else { "" }
            case None => "" })
        let reportRange = checkpointPolicyTrimReference113(query, report)
        let validation = query.query("checkpoint_save_validate", [ValueField("source", report), ValueField("range", reportRange)])
        match (checkpointSaveClosedError113(validation)) { case Some(error) => return Result<Unit>.Err(error); case None => () }
        if (!httpIntentExactFields(validation, ["valid"]) || validation.field("valid").getOrThrow().unifiedKind != ValueKind.Boolean ||
            !validation.field("valid").getOrThrow().asBool()) {
            throw IllegalStateException("checkpoint save report validation changed") }
        query.release(validation)
        // Original report validation still precedes the actual Thread read.
        // The inherited whole loader is an explicitly open resource seam;
        // event batches do not claim that the whole snapshot is now streamed.
        let thread = match (loadThread()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
        let state = checkpointSaveActualHistory113(query, thread, result.callId)
        let check = query.query("checkpoint_save_check", [ValueField("state", state)])
        match (checkpointSaveClosedError113(check)) { case Some(error) => return Result<Unit>.Err(error); case None => () }
        if (!httpIntentExactFields(check, ["valid"]) || check.field("valid").getOrThrow().unifiedKind != ValueKind.Boolean ||
            !check.field("valid").getOrThrow().asBool()) {
            throw IllegalStateException("checkpoint save canonical observation changed") }
        query.release(check)
        let checkpoint = compactionPageInteger(state, "checkpoint")
        let rewind = compactionPageInteger(state, "rewind")
        let prefix = ArrayList<ThreadItem>(); var goalData = ""
        for (item in thread.items) {
            if (item.ordinal <= checkpoint) { prefix.add(item) }
            if (item.ordinal == checkpoint) {
                match (item.content) {
                    case ThreadItemContent.ToolResult(_, _, _, output, _) =>
                        match (output.field(goalName)) { case Some(value) =>
                            if (value.unifiedKind == ValueKind.Text) { goalData = value.text }
                            case None => () }
                    case _ => () }
            }
        }
        let goal = query.references.intern(goalData); let goalRange = checkpointPolicyTrimReference113(query, goal)
        let actualStructure = match (summary(context.sessionId, modelMessagesFromCanonicalItems(prefix.toArray()), context.cancellation)) {
            case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
        structure = Some(actualStructure)
        match (actualStructure.validate()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        let recipe = query.query("checkpoint_save_recipe", [ValueField("state", state), ValueField("report", report),
            ValueField("report_range", reportRange), ValueField("goal", goal), ValueField("goal_range", goalRange),
            ValueField("structured", query.references.intern(actualStructure.text)), ValueField("provenance", actualStructure.provenance),
            ValueField("call_id", query.references.intern(result.callId))])
        match (checkpointSaveClosedError113(recipe)) { case Some(error) => return Result<Unit>.Err(error); case None => () }
        if (!httpIntentExactFields(recipe, ["through", "prefix_through", "active_goal", "projection"]) ||
            compactionPageInteger(recipe, "through") != rewind || compactionPageInteger(recipe, "prefix_through") != checkpoint) {
            throw IllegalStateException("checkpoint save recipe changed its supplied event boundaries") }
        let data = checkpointPolicyMaterialize113(query, recipe.field("projection").getOrThrow())
        let activeGoal = query.references.compose(recipe.field("active_goal").getOrThrow(), 8388608)
        let actual = retainProductPolicyData(objectValue([ValueField("active_goal", textValue(activeGoal)), ValueField("projection", data)]))
        retained = Some(actual)
        query.check()
        match (actualStructure.validate()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        // Both actual leases remain live through the complete synchronous
        // Store before/after-INSERT proof and physical consumer callback.
        query.consumeCurrentData113({ current: () -> Result<Unit> =>
            let guard: () -> Result<Unit> = { =>
                match (current()) { case Result.Err(error) => Result<Unit>.Err(error)
                    case Result.Ok(_) => actualStructure.validateRetainedData113() } }
            consume(thread, rewind, actual.value.field("active_goal").getOrThrow().text,
                actual.value.field("projection").getOrThrow(), guard)
        })
    } catch (error: ProductCompactionDataError) { Result<Unit>.Err(error.error) }
    catch (_: Exception) { productPolicySelectionError<Unit>("checkpoint.save_policy_data_invalid") }
    finally {
        match (retained) { case Some(value) => value.close(); case None => () }
        match (structure) { case Some(value) => value.close(); case None => () }
        query.close()
    }
}
