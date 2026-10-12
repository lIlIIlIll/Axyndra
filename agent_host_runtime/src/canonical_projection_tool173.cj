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
public interface HostCanonicalProjectionRoute173 {
    func executeData173(host: HostJavaScriptPluginHost, selection: HostCanonicalProjectionSelection173,
        context: ToolInvocationContext, prepared: PreparedToolInvocation,
        recipe: AgentValue, failure: HostCanonicalExecutionFailure173): Result<ToolResult>
    func afterCanonicalData173(selection: HostCanonicalProjectionSelection173,
        context: ToolInvocationContext, plan: NormalizedOperationPlan, result: ToolResult,
        boundary: ?DirectPostCanonicalProjectionBoundary): OwnedFailureDataOutcome113<Unit>
}

// This exact object is published once in the existing catalog; all actual
// frozen-executor/refEq, handoff, canonical result and Scope gates stay there.
class HostCanonicalProjectionToolExecutor173 <: ToolExecutor &
    PreparedPostCanonicalToolObserver & DirectPostCanonicalToolObserver &
    PaidPreparedPostCanonicalToolObserver113 & PaidDirectPostCanonicalToolObserver113 &
    ReturnedToolExecutionFrameObserver173 {
    private let host: HostJavaScriptPluginHost
    private let selected: HostCanonicalProjectionSelection173
    private let native: HostJavaScriptPluginToolExecutor
    private let route: HostCanonicalProjectionRoute173

    init(host: HostJavaScriptPluginHost, selected: HostCanonicalProjectionSelection173,
        native: HostJavaScriptPluginToolExecutor, route: HostCanonicalProjectionRoute173) {
        this.host = host; this.selected = selected; this.native = native; this.route = route
    }
    public func acquireHandoffLease(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        match (selected.requirePlan173(context, prepared.operationPlan)) {
            case Result.Err(error) => return Result<ToolExecutionHandoffLease>.Err(error); case Result.Ok(_) => () }
        native.acquireHandoffLease(context, prepared)
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        match (selected.requirePlan173(context, prepared.operationPlan)) {
            case Result.Err(error) => return Result<ToolResult>.Err(error); case Result.Ok(_) => () }
        // Register paid error custody before ANY Native/query/SQL producer.
        // Pressure here cannot move or strand an already-produced consumer.
        let failure = selected.reservePreparedExecutionFailure173(prepared)
        // The actual published Native executor runs with the original real
        // operation, call, Run/Epoch, capability and zero-service observer.
        let inputPayment = selected.deriveDataPayment173(1048576)
        let recipe = try { hostInvokeCanonicalDataRecipe173(host, selected, context, prepared, inputPayment) }
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
                httpIntentText(response.value, "action") != selected.action ||
                httpIntentText(response.value, "provider") != selected.provider) {
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
        // Same published executor and actual immutable prepared pointer from
        // Pipeline. No JSON outcome, fence.close or scheduler catch can call it.
        selected.returnedExecutionFrame173(prepared)
    }
    public func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        Some(route.afterCanonicalData173(selected, context, originalPlan, result,
            Option<DirectPostCanonicalProjectionBoundary>.None))
    }
    public func afterDirectResultPersistedOwned113(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit> {
        Some(route.afterCanonicalData173(selected, context, prepared.operationPlan, result, Some(boundary)))
    }
    public func afterPreparedResultPersisted(context: ToolInvocationContext,
        plan: NormalizedOperationPlan, result: ToolResult): Result<Unit> {
        // The ordinary API cannot retire full dynamic errors. It never falls
        // back to the old hardcoded business callback or raw Thread snapshot.
        hostPluginResourceError("plugin.canonical_projection_paid_consumer_required",
            "canonical-data projection requires its actual paid consumer entry")
    }
    public func afterDirectResultPersisted(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): Result<Unit> {
        hostPluginResourceError("plugin.canonical_projection_paid_consumer_required",
            "Direct canonical-data projection requires its actual paid consumer entry")
    }
}

// The bounded Native input describes the already-frozen recipe. Original
// arguments and full history remain paid references in the actual Kernel
// adapter; no 16 KiB whole-thread frame or artificial history ceiling appears.
func hostInvokeCanonicalDataRecipe173(host: HostJavaScriptPluginHost,
    selected: HostCanonicalProjectionSelection173, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, payment: LogicalJsonOwnerReservation): Result<HostJavaScriptPluginInvocationResult> {
    match (selected.requirePlan173(context, prepared.operationPlan)) {
        case Result.Err(error) => return Result<HostJavaScriptPluginInvocationResult>.Err(error); case Result.Ok(_) => () }
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
