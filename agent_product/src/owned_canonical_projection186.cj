package agent_product

import agent_host_runtime.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import yjson.*
import yjson_support.*

class ProductOwnedCanonicalProjectionRoute186 <: HostOwnedCanonicalProjectionRoute186 {
    private let database: SqliteDatabase
    private let canonicalHost173: ProductJavaScriptPluginHost
    private let summaryTimeout173: Int64
    init(database: SqliteDatabase, host: ProductJavaScriptPluginHost, summaryTimeout: Int64) {
        this.database = database; this.canonicalHost173 = host; this.summaryTimeout173 = summaryTimeout
    }

    public func executeData173(host: HostJavaScriptPluginHost, selected: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, recipe: AgentValue,
        failure: HostCanonicalExecutionFailure173): Result<ToolResult> {
        selected.withOwnedConfigurationFrame186({ => executeData173Frame186(host, selected, context, prepared, recipe, failure) })
    }
    private func executeData173Frame186(host: HostJavaScriptPluginHost, selected: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, recipe: AgentValue,
        failure: HostCanonicalExecutionFailure173): Result<ToolResult> {
        if (!selected.ownsExecutionFailure186(failure)) { throw IllegalArgumentException("execution failure holder belongs to another selection") }
        if (!refEq(host, canonicalHost173)) { throw IllegalArgumentException("canonical projection host differs from its actual composition") }
        let phase = selected.deriveDataPayment173(1048576)
        try {
            let policy = productOwnedCanonicalPolicySelection186(selected)
            try { executeProjectionFrame173(canonicalHost173, selected, context, prepared, recipe, failure, policy) }
            finally { policy.returnOwnedPolicy186() }
        }
        finally { phase.close() }
    }
    private func executeProjectionFrame173(host: ProductJavaScriptPluginHost, selected: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, recipe: AgentValue,
        held: HostCanonicalExecutionFailure173, selection: ProductPolicySelection): Result<ToolResult> {
        match (selected.requirePlan173(context, prepared.operationPlan)) {
            case Result.Err(error) => return Result<ToolResult>.Err(error); case Result.Ok(_) => () }
        let allocate: (Int64) -> LogicalJsonOwnerReservation = { bytes => selected.deriveDataPayment173(bytes) }
        let binding = match (selection.policyBinding193(host)) {
            case Result.Err(error) => return captureOwnedCanonicalExecutionError186(selected, context, prepared, error, held)
            case Result.Ok(value) => value }
        match (selection.validateBinding(host, binding)) {
            case Result.Err(error) => return captureOwnedCanonicalExecutionError186(selected, context, prepared, error, held); case Result.Ok(_) => () }
        let query = try { ProductCompactionReferenceQuery(host, selection, modelPolicySha256Text(prepared.call.callId),
            ThreadId(context.sessionId.value), context.cancellation, prepared.call.callId, binding) }
            catch (failure: ProductCompactionDataError) { return captureOwnedCanonicalExecutionError186(selected, context, prepared, failure.error, held) }
        try {
            try {
                let tool = query.references.intern(prepared.operationPlan.toolName)
                let selectedData = query.query(canonicalProjectionPhase173(Some(recipe), "execution", "select", ""),
                    [ValueField("tool", tool)])
                if (!httpIntentExactFields(selectedData, ["argument"])) { throw IllegalStateException("invalid Native argument selector") }
                let argument = query.references.value(query.references.captureDetachedText113(httpIntentText(selectedData, "argument")))
                if (argument == "" || argument.size > 128) { throw IllegalStateException("Native argument selector is not bounded DATA") }
                query.release(selectedData)
                let arguments = prepared.operationPlan.canonicalArguments.field("projection_arguments").getOrThrow()
                let actual = arguments.field(argument)
                let typed = match (actual) { case Some(value) => value.unifiedKind == ValueKind.Text; case None => false }
                let source = query.references.intern(match (actual) {
                    case Some(value) => if (typed) { value.text } else { "" }; case None => "" })
                let range = checkpointPolicyTrimReference113(query, source, phase173:
                    canonicalProjectionPhase173(Some(recipe), "execution", "trim", ""))
                let validation = query.query(canonicalProjectionPhase173(Some(recipe), "execution", "validate", ""),
                    [ValueField("tool", tool), ValueField("present", boolValue(actual.isSome())),
                        ValueField("kind", textValue(if (typed) { "text" } else { "other" })),
                        ValueField("source", source), ValueField("range", range)])
                // Original closed constant errors are decoded before the
                // first Thread read and retain their complete original values.
                match (checkpointPolicyClosedError113(validation)) {
                    case Some(error) => return Result<ToolResult>.Err(error); case None => () }
                checkpointOwnedRequireValidation113(validation, "Native argument validation changed")
                query.release(validation)
                let cursor = SqlitePaidCanonicalThreadCursor113(database, allocate)
                let state = CanonicalProjectionExecutionData173()
                let answer = cursor.withHeader(ThreadId(context.sessionId.value), { => context.cancellation.check() }, { header =>
                    executeProjectionHeader173(selected, context, prepared, recipe, query, cursor, header,
                        tool, source, range, allocate, state, held)
                })
                if (state.failed) { return selected.consumeExecutionFailure173(context, prepared, held) }
                match (answer) {
                    case Result.Err(error) => return captureOwnedCanonicalExecutionError186(selected, context, prepared, error, held)
                    case Result.Ok(_) => Result<ToolResult>.Ok(state.result.getOrThrow()) }
            } catch (failure: OwnedCanonicalPaidFailure113) {
                held.adoptPaidFailure173(failure)
                selected.consumeExecutionFailure173(context, prepared, held) }
            catch (failure: ProductCompactionDataError) { captureOwnedCanonicalExecutionError186(selected, context, prepared, failure.error, held) }
            catch (failure: OwnedCanonicalDataFailure113) { captureOwnedCanonicalExecutionError186(selected, context, prepared, failure.error, held) }
            catch (_: Exception) { productPolicySelectionError<ToolResult>("checkpoint.policy_data_invalid") }
        } finally { query.close() }
    }
    private func executeProjectionHeader173(selected: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, recipe: AgentValue,
        query: ProductCompactionReferenceQuery, cursor: SqlitePaidCanonicalThreadCursor113, header: ThreadRecord,
        tool: AgentValue, source: AgentValue, range: AgentValue,
        allocate: (Int64) -> LogicalJsonOwnerReservation, state: CanonicalProjectionExecutionData173,
        held: HostCanonicalExecutionFailure173): Result<Unit> {
        try {
            let history = checkpointSaveActualOwnedHistory113(query, cursor, header.id, header.revision,
                header.nextItemOrdinal, prepared.call.callId, { => context.cancellation.check() }, routeRecipe173: Some(recipe))
            let checked = query.query(canonicalProjectionPhase173(Some(recipe), "execution", "check", ""),
                [ValueField("tool", tool), ValueField("state", history)])
            match (checkpointPolicyClosedError113(checked)) {
                case Some(error) => return Result<Unit>.Err(error); case None => () }
            checkpointOwnedRequireValidation113(checked, "Native complete history validation changed")
            query.release(checked)
            let clock = query.references.intern(checkpointTimestamp())
            let proposal = query.query(canonicalProjectionPhase173(Some(recipe), "execution", "result", ""),
                [ValueField("tool", tool), ValueField("state", history), ValueField("source", source),
                    ValueField("range", range), ValueField("timestamp", clock)])
            match (checkpointPolicyClosedError113(proposal)) {
                case Some(error) => return Result<Unit>.Err(error); case None => () }
            let output = checkpointPolicyMaterialize113(query, proposal)
            query.check()
            let copied = HostPaidValueProjection151(allocate(4096))
            var published = false
            try {
                copied.retainValue151(1, output); copied.projectValue151(1)
                let value = CanonicalProjectionOutputData173()
                copied.withValue151({ actual => value.value = Some(actual) })
                query.check()
                let payload = copied.publicationLease151(); published = true
                state.result = Some(ToolResult(prepared.call.callId, value.value.getOrThrow(), payloadLease: Some(payload)))
                value.value = None<AgentValue>
                Result<Unit>.Ok(())
            } finally { if (!published) { copied.closeUnpublished151() } }
        } catch (failure: OwnedCanonicalPaidFailure113) {
            held.adoptPaidFailure173(failure); state.failed = true; Result<Unit>.Ok(()) }
        catch (failure: ProductCompactionDataError) {
            held.adoptConsumer173(captureExecutionConsumer173(failure.error, allocate)); state.failed = true; Result<Unit>.Ok(()) }
        catch (failure: OwnedCanonicalDataFailure113) {
            held.adoptConsumer173(captureExecutionConsumer173(failure.error, allocate)); state.failed = true; Result<Unit>.Ok(()) }
    }
    public func afterCanonicalData173(selected: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, plan: NormalizedOperationPlan, result: ToolResult,
        boundary: ?DirectPostCanonicalProjectionBoundary): OwnedFailureDataOutcome113<Unit> {
        selected.withOwnedConfigurationFrame186({ => afterCanonicalData173Frame186(selected, context, plan, result, boundary) })
    }
    private func afterCanonicalData173Frame186(selected: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, plan: NormalizedOperationPlan, result: ToolResult,
        boundary: ?DirectPostCanonicalProjectionBoundary): OwnedFailureDataOutcome113<Unit> {
        let allocate: (Int64) -> LogicalJsonOwnerReservation = { bytes => selected.deriveDataPayment173(bytes) }
        let phase = allocate(1048576)
        var owned: ?SharedToolSetSnapshot159 = None<SharedToolSetSnapshot159>
        try {
            owned = context.forkOwnedToolSetSnapshot159()
            let policy = productOwnedCanonicalPolicySelection186(selected)
            try { afterProjectionFrame173(selected, context, plan, result, boundary, allocate, owned, policy) }
            finally { policy.returnOwnedPolicy186() }
        } finally {
            // The complete callback/TX/query helper returned before this share.
            match (owned) { case Some(value) => value.close159(); case None => () }
            owned = None<SharedToolSetSnapshot159>
            phase.close()
        }
    }
    private func afterProjectionFrame173(selected: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, plan: NormalizedOperationPlan, result: ToolResult,
        boundary: ?DirectPostCanonicalProjectionBoundary,
        allocate: (Int64) -> LogicalJsonOwnerReservation,
        ownedToolSet185: ?SharedToolSetSnapshot159, selection: ProductPolicySelection): OwnedFailureDataOutcome113<Unit> {
        match (selected.requirePlan173(context, plan)) {
            case Result.Err(error) => return captureOwnedFailureData113<Unit>(error, allocate); case Result.Ok(_) => () }
        let recipe = plan.canonicalArguments.field("projection_recipe").getOrThrow()
        if (recipe.field("post_canonical").getOrThrow().unifiedKind == ValueKind.Null) {
            return OwnedFailureDataOutcome113<Unit>.Value(()) }
        let host = canonicalHost173
        let binding = match (selection.policyBinding193(host)) {
            case Result.Err(error) => return captureOwnedFailureData113<Unit>(error, allocate); case Result.Ok(value) => value }
        let cursor = SqlitePaidCanonicalThreadCursor113(database, allocate)
        queryProductOwnedCheckpointSave113(host, selection, binding, context, result, cursor, allocate, summaryTimeout173,
            { header, through, goal, digest, projection, current =>
                let guard: () -> Result<Unit> = { => match (context.cancellation.check()) {
                    case Result.Err(error) => Result<Unit>.Err(error); case Result.Ok(_) => current() } }
                let checkpoint = ContextCheckpoint("tool-rewind-" + context.sessionId.value + "-" + result.callId,
                    header.id, through, projection, digest, "agent-product-v1", "agent-core", activeGoal: goal)
                let store = SqlitePostCanonicalCheckpointStore(database, allocate)
                match (ownedToolSet185) {
                    case Some(owned) => match (boundary) {
                        case Some(actual) => store.saveDirectOwned185(checkpoint, header, context.contextProjection, owned,
                            plan.toolName, plan, result, agentUtcMillis(), actual, guard)
                        case None =>
                            if (header.activeTurnId.isNone()) {
                                store.saveRetainedOwned185(checkpoint, header, context.runId, context.epoch,
                                    context.contextProjection, owned, plan, result, agentUtcMillis(), guard)
                            } else {
                                store.saveOwned185(checkpoint, header, context.runId, context.epoch, context.contextProjection,
                                    owned, plan.toolName, plan, result, agentUtcMillis(), guard) } }
                    case None =>
                match (boundary) {
                    case Some(actual) => store.saveDirect(checkpoint, header, context.contextProjection, context.legacyToolSetSnapshot159,
                        plan.toolName, plan, result, agentUtcMillis(), actual, guard)
                    case None =>
                        if (header.activeTurnId.isNone()) {
                            store.saveRetainedData173(checkpoint, header, context.runId, context.epoch,
                                context.contextProjection, context.legacyToolSetSnapshot159, plan, result, agentUtcMillis(), guard)
                        } else {
                            store.save(checkpoint, header, context.runId, context.epoch, context.contextProjection,
                                context.legacyToolSetSnapshot159, plan.toolName, plan, result, agentUtcMillis(), guard) } }
                }
            }, result.callId, context.cancellation, routeRecipe173: Some(recipe))
    }
}

func captureOwnedCanonicalExecutionError186(selected: HostOwnedCanonicalProjectionSelection186, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, error: AgentError, held: HostCanonicalExecutionFailure173): Result<ToolResult> {
    held.adoptConsumer173(captureExecutionConsumer173(error, { bytes => selected.deriveDataPayment173(bytes) }))
    selected.consumeExecutionFailure173(context, prepared, held)
}
