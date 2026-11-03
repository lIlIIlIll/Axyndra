package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import agent_sdk.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Kernel-side DATA adapter installed by the actual Product composition. IPC
// cannot implement this interface or create its original prepared invocation.
public interface HostOwnedCanonicalProjectionRoute186 {
    func executeData173(host: HostJavaScriptPluginHost, selection: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, prepared: PreparedToolInvocation,
        recipe: AgentValue, failure: HostCanonicalExecutionFailure173): Result<ToolResult>
    func afterCanonicalData173(selection: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, plan: NormalizedOperationPlan, result: ToolResult,
        boundary: ?DirectPostCanonicalProjectionBoundary): OwnedFailureDataOutcome113<Unit>
}

// This exact object is published once in the existing catalog; all actual
// frozen-executor/refEq, handoff, canonical result and Scope gates stay there.
class HostOwnedCanonicalProjectionToolExecutor186 <: ToolExecutor &
    PreparedPostCanonicalToolObserver & DirectPostCanonicalToolObserver &
    PaidPreparedPostCanonicalToolObserver113 & PaidDirectPostCanonicalToolObserver113 &
    ReturnedToolExecutionFrameObserver173 {
    private let host: HostJavaScriptPluginHost
    private let selected: HostOwnedCanonicalProjectionSelection186
    private let native: HostJavaScriptPluginToolExecutor
    private let route: HostOwnedCanonicalProjectionRoute186

    init(host: HostJavaScriptPluginHost, selected: HostOwnedCanonicalProjectionSelection186,
        native: HostJavaScriptPluginToolExecutor, route: HostOwnedCanonicalProjectionRoute186) {
        this.host = host; this.selected = selected; this.native = native; this.route = route
    }
    public func acquireHandoffLease(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        selected.withOwnedConfigurationFrame186({ => acquireHandoffLeaseFrame186(context, prepared) })
    }
    private func acquireHandoffLeaseFrame186(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        match (selected.requirePlan173(context, prepared.operationPlan)) {
            case Result.Err(error) => return Result<ToolExecutionHandoffLease>.Err(error); case Result.Ok(_) => () }
        native.acquireHandoffLease(context, prepared)
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        selected.withOwnedConfigurationFrame186({ => executeFrame186(context, prepared) })
    }
    private func executeFrame186(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        match (selected.requirePlan173(context, prepared.operationPlan)) {
            case Result.Err(error) => return Result<ToolResult>.Err(error); case Result.Ok(_) => () }
        // Register paid error custody before ANY Native/query/SQL producer.
        // Pressure here cannot move or strand an already-produced consumer.
        let failure = selected.reservePreparedExecutionFailure173(prepared)
        // The actual published Native executor runs with the original real
        // operation, call, Run/Epoch, capability and zero-service observer.
        let inputPayment = selected.deriveDataPayment173(1048576)
        let recipe = try { hostInvokeCanonicalDataRecipeOwned186(host, selected, context, prepared, inputPayment) }
            catch (error: Exception) { inputPayment.close(); throw error }
        let response = match (recipe) { case Result.Err(error) => inputPayment.close(); return Result<ToolResult>.Err(error)
            case Result.Ok(value) => value }
        try {
            match (selected.requirePlan173(context, prepared.operationPlan)) {
                case Result.Err(error) => return Result<ToolResult>.Err(error); case Result.Ok(_) => () }
            if (response.isError) {
                return hostPluginResourceError("plugin.canonical_projection_recipe_invalid",
                    "the actual Native Tool did not return its complete leased data recipe") }
            if (httpIntentText(response.value, "schema") != "axyndra.canonical-data-recipe/v1" ||
                !selected.textEquals186(4, httpIntentText(response.value, "action")) ||
                !selected.textEquals186(3, httpIntentText(response.value, "provider"))) {
                return hostPluginResourceError("plugin.canonical_projection_recipe_changed",
                    "Native data recipe differs from the exact operator-selected action/provider") }
            let comparison = selected.deriveDataPayment173(1048576)
            let meter = HostPaidValueProjection151(comparison)
            try {
                let frozen = prepared.operationPlan.canonicalArguments.field("projection_recipe").getOrThrow()
                let left = meter.measureBorrowedValue151(frozen)
                let right = meter.measureBorrowedValue151(response.value)
                meter.fundAdditional151(left.bytes + right.bytes, left.nodes + right.nodes)
                if (encodeAgentValue(frozen) != encodeAgentValue(response.value)) {
                    return hostPluginResourceError("plugin.canonical_projection_recipe_changed",
                        "the whole Native recipe changed after its actual prepared plan was frozen") }
            } finally { meter.closeUnpublished151() }
            // The full recipe stays paid in its Native payload loan until all
            // adapter/helper references return; its scalar fields grant nothing.
            route.executeData173(host, selected, context, prepared, response.value, failure)
        } finally { response.releasePayload(); inputPayment.close() }
    }
    public func afterToolExecutionFrameReturned173(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Unit {
        selected.withOwnedConfigurationFrame186({ => afterToolExecutionFrameReturned173Frame186(context, prepared) })
    }
    private func afterToolExecutionFrameReturned173Frame186(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Unit {
        // Same published executor and actual immutable prepared pointer from
        // Pipeline. No JSON outcome, fence.close or scheduler catch can call it.
        selected.returnedExecutionFrame173(prepared)
    }
    public func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        selected.withOwnedConfigurationFrame186({ => afterPreparedResultPersistedOwned113Frame186(context, originalPlan, result) })
    }
    private func afterPreparedResultPersistedOwned113Frame186(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        Some(route.afterCanonicalData173(selected, context, originalPlan, result,
            Option<DirectPostCanonicalProjectionBoundary>.None))
    }
    public func afterDirectResultPersistedOwned113(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit> {
        selected.withOwnedConfigurationFrame186({ => afterDirectResultPersistedOwned113Frame186(context, prepared, result, boundary) })
    }
    private func afterDirectResultPersistedOwned113Frame186(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit> {
        Some(route.afterCanonicalData173(selected, context, prepared.operationPlan, result, Some(boundary)))
    }
    public func afterPreparedResultPersisted(context: ToolInvocationContext,
        plan: NormalizedOperationPlan, result: ToolResult): Result<Unit> {
        selected.withOwnedConfigurationFrame186({ => afterPreparedResultPersistedFrame186(context, plan, result) })
    }
    private func afterPreparedResultPersistedFrame186(context: ToolInvocationContext,
        plan: NormalizedOperationPlan, result: ToolResult): Result<Unit> {
        // The ordinary API cannot retire full dynamic errors. It never falls
        // back to the old hardcoded business callback or raw Thread snapshot.
        hostPluginResourceError("plugin.canonical_projection_paid_consumer_required",
            "canonical-data projection requires its actual paid consumer entry")
    }
    public func afterDirectResultPersisted(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): Result<Unit> {
        selected.withOwnedConfigurationFrame186({ => afterDirectResultPersistedFrame186(context, prepared, result, boundary) })
    }
    private func afterDirectResultPersistedFrame186(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): Result<Unit> {
        hostPluginResourceError("plugin.canonical_projection_paid_consumer_required",
            "Direct canonical-data projection requires its actual paid consumer entry")
    }
}

// The bounded Native input describes the already-frozen recipe. Original
// arguments and full history remain paid references in the actual Kernel
// adapter; no 16 KiB whole-thread frame or artificial history ceiling appears.
func hostInvokeCanonicalDataRecipeOwned186(host: HostJavaScriptPluginHost,
    selected: HostOwnedCanonicalProjectionSelection186, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, payment: LogicalJsonOwnerReservation): Result<HostJavaScriptPluginInvocationResult> {
    match (selected.requirePlan173(context, prepared.operationPlan)) {
        case Result.Err(error) => return Result<HostJavaScriptPluginInvocationResult>.Err(error); case Result.Ok(_) => () }
    selected.invokeNativeRecipe193(host, context, prepared, payment)
}
// The actual known Native invocation consumes the original metadata solely
// within the view's complete frame. Its timer uses the paid private action
// protocol, so no SDK Future closure retains these borrowed names.
func hostInvokeCanonicalDataRecipeFrame193(host: HostJavaScriptPluginHost,
    selected: HostCanonicalProjectionSelection173, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, payment: LogicalJsonOwnerReservation): Result<HostJavaScriptPluginInvocationResult> {
    let profile = match (host.toolExecutionProfile(selected.namespace, selected.localTool, selected.generation)) {
        case Result.Err(error) => return Result<HostJavaScriptPluginInvocationResult>.Err(error); case Result.Ok(value) => value }
    if (profile != PluginToolExecutionProfile.DataOnly) { return hostPluginResourceError("plugin.canonical_projection_profile_changed",
        "canonical-data recipe invocation requires its actual Native DataOnly contribution") }
    payment.ensureRetainedPeak(1048576)
    try {
        let input = objectValue([ValueField("projection_binding", prepared.operationPlan.canonicalArguments.field("projection_binding").getOrThrow()),
            ValueField("projection_recipe", prepared.operationPlan.canonicalArguments.field("projection_recipe").getOrThrow())])
        // The fixed indexed counter and temporary fields are already paid.
        // Scalar native-codec temporaries enlarge this same phase first.
        let measured = hostProjectionMeasure151(input, { bytes =>
            if (bytes > Int64.Max - 1048576) { throw LogicalJsonPayloadError("canonical input scalar invoice overflow") }
            payment.ensureRetainedPeak(1048576 + bytes) })
        if (measured.bytes > (Int64.Max - 1048576) / 16 ||
            measured.nodes > (Int64.Max - 1048576 - measured.bytes * 16) / 512) {
            throw LogicalJsonPayloadError("canonical input codec invoice overflow") }
        payment.ensureRetainedPeak(1048576 + measured.bytes * 16 + measured.nodes * 512)
        measured.clearScalarPayment151()
        let encoded = encodeAgentValue(input)
        let observer = HostJavaScriptPluginInvocationObserver(context, prepared, Option<HostJavaScriptPluginServiceBroker>.None)
        host.invoke(selected.namespace, selected.localTool, encoded,
            identity: JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
                epoch: context.epoch, operationId: prepared.operationId.value, callId: prepared.call.callId),
            cancellation: context.cancellation, cwd: context.cwd, processLimits: context.budget.processLimits,
            expectedInstanceGeneration: selected.generation,
            authorityScope: "data-only:" + selected.namespace + ":" + prepared.operationPlan.implementation.toolVersion + ":" +
                prepared.operationPlan.implementation.implementationFingerprint, observer: Some(observer))
    } finally {
        // This helper no longer owns input aliases. Its parent phase remains
        // charged while the response and all route/helper frames are live.
        // The owner is closed only by the wrapper's actual final response loan.
    }
}

class HostLegacyCanonicalProjectionRouteHeld186 <: HostOwnedCanonicalProjectionRoute186 {
    private let raw: HostCanonicalProjectionRoute173
    init(raw: HostCanonicalProjectionRoute173) { this.raw = raw }
    public func executeData173(host: HostJavaScriptPluginHost, selection: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, prepared: PreparedToolInvocation,
        recipe: AgentValue, failure: HostCanonicalExecutionFailure173): Result<ToolResult> {
        selection.withOwnedConfigurationFrame186({ => raw.executeData173(host,
            selection.exportCompatibilityHeld186(), context, prepared, recipe, failure) })
    }
    public func afterCanonicalData173(selection: HostOwnedCanonicalProjectionSelection186,
        context: ToolInvocationContext, plan: NormalizedOperationPlan, result: ToolResult,
        boundary: ?DirectPostCanonicalProjectionBoundary): OwnedFailureDataOutcome113<Unit> {
        selection.withOwnedConfigurationFrame186({ => raw.afterCanonicalData173(
            selection.exportCompatibilityHeld186(), context, plan, result, boundary) })
    }
}
