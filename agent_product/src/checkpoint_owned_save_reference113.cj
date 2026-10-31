package agent_product

import agent_domain.*
import agent_domain.CancellationSource as OwnedCheckpointCancellationSource113
import agent_domain.CancellationToken as OwnedCheckpointCancellationToken113
import agent_core.OwnedCanonicalModelDataError113
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// A Unit synchronous DATA loan, not a source grant. The real Runtime's caller
// retains the actual original prepared plan/canonical result. Store independently
// proves that plan, Receipt/output, prefix, current Run and legal save boundary.
type ProductOwnedCheckpointProjectionConsumer113 = (ThreadRecord, Int64, String,
    String, AgentValue, () -> Result<Unit>) -> Result<Unit>
type ProductOwnedCheckpointSavePolicy113 = (ToolInvocationContext, ToolResult, SqlitePaidCanonicalThreadCursor113,
    (Int64) -> LogicalJsonOwnerReservation, ProductOwnedCheckpointProjectionConsumer113) -> OwnedFailureDataOutcome113<Unit>

class CheckpointOwnedGoalData113 {
    var value: AgentValue
    init(value: AgentValue) { this.value = value }
}
class CheckpointOwnedFailureCapture113 {
    var value: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    init() {}
    func adopt(failure: OwnedCanonicalPaidFailure113): Unit {
        if (value.isSome()) { throw IllegalStateException("checkpoint failure was already captured") }
        value = Some(failure.takeConsumer())
    }
    func capture(error: AgentError, allocate: (Int64) -> LogicalJsonOwnerReservation): Unit {
        if (value.isSome()) { throw IllegalStateException("checkpoint failure was already captured") }
        match (captureOwnedFailureData113<Unit>(error, allocate)) {
            case OwnedFailureDataOutcome113.Failure(actual) => value = Some(actual)
            case OwnedFailureDataOutcome113.Value(_) => throw IllegalStateException("failure capture returned value") }
    }
}

func queryProductOwnedCheckpointSave113(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
    binding: ProductPluginPolicyBinding, context: ToolInvocationContext, result: ToolResult,
    cursor: SqlitePaidCanonicalThreadCursor113, allocate: (Int64) -> LogicalJsonOwnerReservation,
    summaryTimeoutMillis: Int64, consume: ProductOwnedCheckpointProjectionConsumer113,
    requestId: String, cancellation: OwnedCheckpointCancellationToken113,
    routeRecipe173!: ?AgentValue = None<AgentValue>): OwnedFailureDataOutcome113<Unit> {
    let query = ProductCompactionReferenceQuery(host, selection, modelPolicySha256Text(requestId),
        ThreadId(context.sessionId.value), cancellation, requestId, binding)
    try {
        try {
            let layout = query.query(canonicalProjectionPhase173(routeRecipe173, "post_canonical", "layout", "checkpoint_save_layout"), [])
            if (!httpIntentExactFields(layout, ["report", "goal"])) { throw IllegalStateException("invalid checkpoint save layout") }
            let reportName = query.references.value(query.references.captureDetachedText113(httpIntentText(layout, "report")))
            let goalName = query.references.value(query.references.captureDetachedText113(httpIntentText(layout, "goal")))
            if (reportName == "" || goalName == "" || reportName.size > 128 || goalName.size > 128) {
                throw IllegalStateException("checkpoint save selectors are not bounded metadata") }
            query.release(layout)
            // Original leased canonical result remains held by Core/Direct.
            let field = result.output.field(reportName)
            let report = query.references.intern(match (field) {
                case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else { "" }
                case None => "" })
            let range = checkpointPolicyTrimReference113(query, report, phase173:
                canonicalProjectionPhase173(routeRecipe173, "execution", "trim", "checkpoint_trim"))
            let validation = query.query(canonicalProjectionPhase173(routeRecipe173, "post_canonical", "validate", "checkpoint_save_validate"),
                [ValueField("source", report), ValueField("range", range)])
            checkpointOwnedRequireValidation113(validation, "checkpoint save report validation changed")
            query.release(validation)
            // Preserve argument/report errors BEFORE the original Thread read.
            // Header/complete rows are actual paid SQLite loans, not loadThread.
            let failure = CheckpointOwnedFailureCapture113()
            let answer = cursor.withHeader(ThreadId(context.sessionId.value), { => context.cancellation.check() }, { thread =>
                checkpointOwnedSaveHeader113(host, selection, binding, context, result, query, cursor,
                    thread, report, range, goalName, allocate, summaryTimeoutMillis, consume, requestId, cancellation, failure, routeRecipe173) })
            match (failure.value) { case Some(actual) =>
                failure.value = None<OwnedFailureDataConsumer113>; return OwnedFailureDataOutcome113<Unit>.Failure(actual)
                case None => () }
            match (answer) { case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(())
                case Result.Err(error) => captureOwnedFailureData113<Unit>(error, allocate) }
        } catch (failure: OwnedCanonicalPaidFailure113) {
            OwnedFailureDataOutcome113<Unit>.Failure(failure.takeConsumer()) }
        catch (failure: ProductCompactionDataError) { captureOwnedFailureData113<Unit>(failure.error, allocate) }
        catch (failure: OwnedCanonicalDataFailure113) { captureOwnedFailureData113<Unit>(failure.error, allocate) }
        catch (failure: OwnedCanonicalModelDataError113) { captureOwnedFailureData113<Unit>(failure.error, allocate) }
        catch (_: Exception) {
            match (productPolicySelectionError<Unit>("checkpoint.save_policy_data_invalid")) {
                case Result.Err(error) => captureOwnedFailureData113<Unit>(error, allocate)
                case Result.Ok(_) => throw IllegalStateException("policy error unexpectedly returned a value") } }
    } finally { query.close() }
}

func checkpointOwnedRequireValidation113(value: AgentValue, message: String): Unit {
    match (checkpointSaveClosedError113(value)) { case Some(error) => throw OwnedCanonicalDataFailure113(error); case None => () }
    if (!httpIntentExactFields(value, ["valid"]) || value.field("valid").getOrThrow().unifiedKind != ValueKind.Boolean ||
        !value.field("valid").getOrThrow().asBool()) { throw IllegalStateException(message) }
}

func checkpointOwnedSaveHeader113(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
    binding: ProductPluginPolicyBinding, context: ToolInvocationContext, result: ToolResult,
    query: ProductCompactionReferenceQuery, cursor: SqlitePaidCanonicalThreadCursor113, thread: ThreadRecord,
    report: AgentValue, reportRange: AgentValue, goalName: String,
    allocate: (Int64) -> LogicalJsonOwnerReservation, summaryTimeoutMillis: Int64,
    consume: ProductOwnedCheckpointProjectionConsumer113, requestId: String, cancellation: OwnedCheckpointCancellationToken113,
    failureCapture: CheckpointOwnedFailureCapture113, routeRecipe173: ?AgentValue): Result<Unit> {
    let local: () -> Result<Unit> = { => context.cancellation.check() }
    let current: () -> Result<Unit> = { => query.checkPinnedData113(); Result<Unit>.Ok(()) }
    let metadata = query.references.checkpointBatchMetadata113()
    try {
        // Keep an initial complete-body witness, not just revision/ordinal.
        // SourceDigest for the selected cover is still separately original v1.
        let initial = ownedContextSourceDigestWithPaidCursor113(thread, cursor, thread.nextItemOrdinal - 1, local, current)
        let state = checkpointSaveActualOwnedHistory113(query, cursor, thread.id, thread.revision,
            thread.nextItemOrdinal, result.callId, local, routeRecipe173: routeRecipe173)
        let check = query.query(canonicalProjectionPhase173(routeRecipe173, "post_canonical", "check", "checkpoint_save_check"),
            [ValueField("state", state)])
        checkpointOwnedRequireValidation113(check, "checkpoint save canonical observation changed"); query.release(check)
        let checkpoint = compactionPageInteger(state, "checkpoint"); let rewind = compactionPageInteger(state, "rewind")
        if (checkpoint < 1 || rewind < 1 || checkpoint >= thread.nextItemOrdinal || rewind >= thread.nextItemOrdinal) {
            throw IllegalStateException("checkpoint save data selectors are outside the actual canonical history") }
        let goal = CheckpointOwnedGoalData113(query.references.intern(""))
        compactionDataRequire(cursor.withOrdinal(thread.id, thread.revision, thread.nextItemOrdinal, checkpoint, local, current,
            { item, _ =>
                match (item.content) { case ThreadItemContent.ToolResult(_, _, _, output, _) =>
                    match (output.field(goalName)) { case Some(value) =>
                        if (value.unifiedKind == ValueKind.Text) { goal.value = query.references.captureDetachedText113(value.text) }
                        case None => () }
                    case _ => () }
                Result<Unit>.Ok(()) }))
        let goalRange = checkpointPolicyTrimReference113(query, goal.value, phase173:
            canonicalProjectionPhase173(routeRecipe173, "execution", "trim", "checkpoint_trim"))
        let sourceDigest = ownedContextSourceDigestWithPaidCursor113(thread, cursor, rewind, local, current)
        let projectionDigest = checkpointOwnedProjectionDigest113(cursor, thread.id, thread.revision, thread.nextItemOrdinal,
            checkpoint, nullValue(), listValue([]), allocate, local, current)
        let phaseNow = agentUtcMillis()
        if (summaryTimeoutMillis < 1 || phaseNow > Int64.Max - summaryTimeoutMillis) {
            throw IllegalStateException("checkpoint summary deadline is invalid") }
        let phase = OwnedCheckpointCancellationSource113(parent: Some(cancellation),
            deadlineMillis: phaseNow + summaryTimeoutMillis)
        try {
            let summaryQuery = ProductCompactionReferenceQuery(host, selection, projectionDigest, thread.id,
                phase.token, requestId + "-owned-prefix", binding)
            try {
                let summary = checkpointOwnedReferenceSummary113(summaryQuery, cursor, thread, checkpoint, allocate, local)
                summaryQuery.retainCompletedPurePhase113(cancellation)
                let provenance = if (selection.hasOwnedPolicy193()) { nullValue() } else { objectValue([ValueField("namespace", textValue(binding.namespace)),
                    ValueField("provider", textValue(binding.contribution)), ValueField("package_digest", textValue(binding.digest)),
                    ValueField("configuration_digest", textValue(selection.configurationDigest)),
                    ValueField("source_projection_digest", textValue(projectionDigest)), ValueField("authoritative", boolValue(false))]) }
                let recipe = query.query(canonicalProjectionPhase173(routeRecipe173, "post_canonical", "result", "checkpoint_save_recipe"),
                    [ValueField("state", state), ValueField("report", report),
                    ValueField("report_range", reportRange), ValueField("goal", goal.value), ValueField("goal_range", goalRange),
                    ValueField("structured", query.references.intern(summary)), ValueField("provenance", provenance),
                    ValueField("call_id", query.references.intern(result.callId))],
                    policyProvenance193: if (selection.hasOwnedPolicy193()) { Some(projectionDigest) } else { None<String> })
                match (checkpointSaveClosedError113(recipe)) { case Some(error) => throw OwnedCanonicalDataFailure113(error); case None => () }
                if (!httpIntentExactFields(recipe, ["through", "prefix_through", "active_goal", "projection"]) ||
                    compactionPageInteger(recipe, "through") != rewind || compactionPageInteger(recipe, "prefix_through") != checkpoint) {
                    throw IllegalStateException("checkpoint save recipe changed its supplied event boundaries") }
                let data = checkpointPolicyMaterialize113(query, recipe.field("projection").getOrThrow())
                let activeGoal = query.references.compose(recipe.field("active_goal").getOrThrow(), 8388608)
                // Original actual queries own immutable strings/DOM throughout
                // save. A prepaid small container borrows them; no second full
                // 8MiB clone is made merely to wrap the same immutable data.
                summaryQuery.check(); query.check()
                if (ownedContextSourceDigestWithPaidCursor113(thread, cursor, thread.nextItemOrdinal - 1, local, current) != initial) {
                    throw IllegalStateException("canonical complete history changed during Native summary") }
                let saved = query.consumeCurrentData113({ actualCurrent: () -> Result<Unit> =>
                    // TX-local guard has no Host lookup/Native/SQL reentry.
                    consume(thread, rewind, activeGoal, sourceDigest, data, actualCurrent) })
                match (saved) { case Result.Ok(_) => Result<Unit>.Ok(())
                    case Result.Err(error) => failureCapture.capture(error, allocate); Result<Unit>.Ok(()) }
            } catch (failure: OwnedCanonicalPaidFailure113) {
                failureCapture.adopt(failure); Result<Unit>.Ok(()) }
            catch (failure: ProductCompactionDataError) {
                failureCapture.capture(failure.error, allocate); Result<Unit>.Ok(()) }
            catch (failure: OwnedCanonicalDataFailure113) {
                failureCapture.capture(failure.error, allocate); Result<Unit>.Ok(()) }
            catch (failure: OwnedCanonicalModelDataError113) {
                failureCapture.capture(failure.error, allocate); Result<Unit>.Ok(()) }
            finally { summaryQuery.close() }
        } finally { phase.close() }
    } catch (failure: OwnedCanonicalPaidFailure113) {
        failureCapture.adopt(failure); Result<Unit>.Ok(()) }
    catch (failure: ProductCompactionDataError) {
        failureCapture.capture(failure.error, allocate); Result<Unit>.Ok(()) }
    catch (failure: OwnedCanonicalDataFailure113) {
        failureCapture.capture(failure.error, allocate); Result<Unit>.Ok(()) }
    catch (failure: OwnedCanonicalModelDataError113) {
        failureCapture.capture(failure.error, allocate); Result<Unit>.Ok(()) }
    finally { metadata.close() }
}
