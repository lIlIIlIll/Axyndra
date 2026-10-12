package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import yjson_support.*

// No arbitrary callback proves retirement. These callers have already let
// their complete consuming helper return normally before clearing a share.
func hostReturnDistinctDerivedSnapshotFrame159(actual: ToolInvocationContext,
    retained: ToolInvocationContext): Unit {
    if (!refEq(actual, retained) && actual.hasOwnedToolSetSnapshot159()) { actual.returnOwnedToolSetFrame159() }
}
func hostSameReadonlySnapshotBackingFrame159(left: ?SharedToolSetSnapshot159,
    right: ?SharedToolSetSnapshot159, legacyLeft: String, legacyRight: String): Bool {
    match (left) {
        case Some(value) => match (right) { case Some(other) => value.sameBacking159(other); case None => false }
        case None => right.isNone() && legacyLeft == legacyRight
    }
}
// Consumes the exact paid share on success; normal failure leaves it with the
// caller, which clears it only after this complete closed helper has returned.
func hostFreezeOwnedReadonlyTargetFrame159(catalog: ToolCatalog, context: ToolInvocationContext,
    call: ToolCall, snapshot: SharedToolSetSnapshot159,
    readView: ?HostReadOnlyExecReadView): Result<HostPluginReadOnlyExecTarget> {
    if (!snapshot.hasBoundThread159()) {
        return hostPluginResourceError("extension.exec_thread_missing", "readonly exec snapshot must retain its actual Thread") }
    if (!snapshot.requiredThreadMatches159(ThreadId(context.sessionId.value))) {
        return hostPluginResourceError("extension.exec_thread_changed", "readonly exec catalog snapshot belongs to another Thread") }
    let captured = try { ToolCall(call.callId, call.name,
        parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES)) }
        catch (_: Exception) { return hostPluginResourceError("extension.exec_arguments_invalid", "readonly exec request exceeds its bounded frozen JSON envelope") }
    if (!snapshot.hasExportName159(captured.name)) {
        return hostPluginResourceError("extension.exec_capability_missing", "readonly exec target was not published to the actual Run") }
    if (!snapshot.availableCompleteExport159(captured.name)) {
        return hostPluginResourceError("extension.exec_target_unavailable", "readonly exec target was unavailable or unbound at the actual snapshot") }
    let descriptor = match (catalog.resolvedDescriptor(captured, threadId: Some(ThreadId(context.sessionId.value)))) {
        case Some(value) => value
        case None => return hostPluginResourceError("extension.exec_target_missing", "readonly exec target is no longer published") }
    if (!snapshot.strictAvailableExport159(captured.name, descriptor.implementationVersion,
        descriptor.implementationFingerprint, descriptor.schemaDigest) ||
        descriptor.controlOnly || descriptor.hostServiceOnly || (descriptor.sideEffecting && readView.isNone())) {
        return hostPluginResourceError("extension.exec_target_changed", "readonly exec target differs from its frozen ordinary readonly publication") }
    let network = match (descriptor.networkPolicy(captured)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!networkPolicyModeIsDenied(network.mode)) {
        return hostPluginResourceError("extension.exec_network_denied", "readonly exec requires the exact current denied-network policy") }
    match (readView) { case Some(value) => match (value.current(catalog, context, captured)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
    for (required in descriptor.requiredCapabilities(captured)) {
        if ((required.kind != CapabilityKind.WorkspaceRead && !(readView.isSome() && required.kind == CapabilityKind.ExtensionInvoke && required.resource == captured.name)) ||
            !context.capabilities.allows(required.kind, resource: required.resource)) {
            return hostPluginResourceError("extension.exec_capability_denied", "readonly exec target exceeds the actual Run workspace read ceiling") }
    }
    Result.Ok(HostPluginReadOnlyExecTarget(captured, snapshot, descriptor, readView: readView))
}

func hostInvokeDirectApprovalFrame159(action: (ApprovalDecision, Bool) -> Result<ToolInvocationResult>,
    decision: ApprovalDecision, cancelling: Bool): Result<ToolInvocationResult> {
    action(decision, cancelling)
}
