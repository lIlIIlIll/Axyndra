package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import agent_extension_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

public func hostRegisterPluginDocumentService(catalog: ToolCatalog): Result<Unit> {
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_PLUGIN_DOCUMENT_TOOL,
        "Consume or compare-exchange an exact, already authorized document intent in its canonical transaction.",
        hostObjectSchema([hostSchemaProperty("schema", "string"), hostSchemaProperty("binding", "object"), hostSchemaProperty("intent", "object")],
            ["schema", "binding", "intent"])), Capability(CapabilityKind.ExtensionInvoke),
        sideEffecting: true, neverReplay: true, hostServiceOnly: true,
        implementationVersion: HOST_PLUGIN_DOCUMENT_FINGERPRINT, implementationFingerprint: HOST_PLUGIN_DOCUMENT_FINGERPRINT,
        capabilityResolver: Some({ call => Capability(CapabilityKind.ExtensionInvoke,
            resource: httpIntentText(call.arguments.field("binding") ?? nullValue(), "namespace")) }),
        sideEffectResolver: Some({ call => if(httpIntentText(call.arguments,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_INTENT_SCHEMA){
            match(parsePluginDocumentRowJournalIntent(call.arguments)){case Result.Ok(value)=>value.append;case Result.Err(_)=>true}
        }else{match (parsePluginDocumentIntent(call.arguments)) {
            case Result.Ok(value) => value.compareExchange; case Result.Err(_) => true }} }),
        networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })), HostPluginDocumentExecutor())
}

// No read or mutation here. A successful executor value is a proposal; only
// the live-guarded Store transaction commits the exact data and its Receipt.
public class HostPluginDocumentExecutor <: ToolExecutor {
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (context.cancellation.isCancelled()) { return Result.Err(AgentError(AgentErrorKind.Cancelled,
            "plugin.document_cancelled", "document call was cancelled before result proposal")) }
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived || prepared.source.operationRoot.isNone() ||
            prepared.source.parentOperationId.isNone() || !isPluginDocumentChildPlan(prepared.operationPlan)) {
            return hostPluginResourceError("plugin.document_source_invalid", "document proposal requires an exact derived child") }
        if(isPluginDocumentRowJournalChildPlan(prepared.operationPlan)){
            let actual=parsePluginDocumentRowJournalIntent(prepared.operationPlan.canonicalArguments).value().getOrThrow()
            return Result.Ok(ToolResult(prepared.call.callId,actual.result()))}
        let intent = parsePluginDocumentIntent(prepared.operationPlan.canonicalArguments).value().getOrThrow()
        Result.Ok(ToolResult(prepared.call.callId, intent.result()))
    }
    public func cancel(run: RunId): Result<Unit> { let _ = run; Result.Ok(()) }
}

public func hostDocumentChildContext(root: PreparedToolInvocation, context: ToolInvocationContext): ToolInvocationContext {
    let binding = root.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    let capability = Capability(CapabilityKind.ExtensionInvoke, resource: httpIntentText(binding, "namespace"))
    let permitted = CapabilitySet(values: root.operationPlan.requiredCapabilities).allows(capability.kind, resource: capability.resource) &&
        context.capabilities.allows(capability.kind, resource: capability.resource)
    ToolInvocationContext(context.runId, context.sessionId, CapabilitySet(values: if (permitted) { [capability] } else { [] }),
        sequence: context.currentSequence(), epoch: context.epoch,
        toolContext: ToolContextDescriptor(workspaceRoot: context.workspaceRoot, cwd: context.cwd,
            environment: ToolEnvironmentView(), services: context.services),
        cancellation: context.cancellation, approvalModeOverride: context.approvalModeOverride,
        outputSink: context.outputSink, budget: context.budget, budgetModeFn: context.budgetModeFn,
        contextProjection: context.contextProjection, toolSetSnapshot: context.legacyToolSetSnapshot159,
            ownedToolSetSnapshot159: context.forkOwnedToolSetSnapshot159())
}

public func hostExecutePluginDocument(catalog: ToolCatalog, pipeline: ToolPipeline, operations: OperationRuntimePort,
    identity: HostPluginServiceIdentity, context: ToolInvocationContext, root: PreparedToolInvocation,
    invocationId: String, requestId: String, arguments: AgentValue): JavaScriptHostResult<String> {
    if (!httpIntentExactFields(arguments, ["intent_id"]) || httpIntentText(arguments, "intent_id") != requestId) {
        return hostPluginServiceError("plugin.document_request_invalid", "document service selects only its exact frozen intent ID") }
    let value = match (pluginDocumentChildArguments(root.operationPlan.canonicalArguments, requestId)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    let guard = match (hostOpenPluginDocumentGuard(identity, context, root)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    try {
        let childContext = hostDocumentChildContext(root, context)
        let result = hostExecutePluginDocumentChildFrame159(catalog, pipeline, operations,
            context, root, invocationId, requestId, value, guard, childContext)
        // The complete prepare/execute/commit/receipt helper has returned.
        // Its output payload finally ran and no callback retains this child.
        if (childContext.hasOwnedToolSetSnapshot159()) { childContext.returnOwnedToolSetFrame159() }
        result
    } finally { guard.close() }
}

private func hostExecutePluginDocumentChildFrame159(catalog: ToolCatalog, pipeline: ToolPipeline,
    operations: OperationRuntimePort, context: ToolInvocationContext, root: PreparedToolInvocation,
    invocationId: String, requestId: String, value: AgentValue, guard: HostPluginDocumentGuard,
    childContext: ToolInvocationContext): JavaScriptHostResult<String> {
        let call = ToolCall(root.call.callId + ":document:" + requestId, HOST_PLUGIN_DOCUMENT_TOOL, value)
        let key = "document-service:" + root.call.callId + ":" + requestId
        let preparation=if(isFrozenPluginDocumentRowJournalParentPlan(root.operationPlan)){
            pipeline.prepareDerived(context,childContext,call,root,key)}else{pipeline.prepareDerived(childContext,call,root,key)}
        let child = match (preparation) {
            case Result.Err(error) => return hostPluginServiceAgentError(error)
            case Result.Ok(ToolPreparation.Ready(item)) => item
            case Result.Ok(_) => return hostPluginServiceError("plugin.document_child_denied", "document child did not inherit exact approved ParentIntent") }
        let descriptor = match (catalog.resolvedDescriptor(call, threadId: Some(ThreadId(context.sessionId.value)))) {
            case Some(item) => item; case None => return hostPluginServiceError("plugin.document_primitive_missing", "document primitive is unavailable") }
        if (!descriptor.hostServiceOnly || descriptor.implementationFingerprint != HOST_PLUGIN_DOCUMENT_FINGERPRINT) {
            return hostPluginServiceError("plugin.document_primitive_changed", "document primitive lost its host-only identity") }
        match (guard.accepts(child.operationPlan)) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
        let admitted = match (pipeline.admitDerived(childContext, child)) {
            case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
        if (admitted.value != child.operationId.value) {
            return hostPluginServiceError("plugin.document_duplicate", "document request already has an admitted child; no retry was performed") }
        let outcome = pipeline.executePrepared(childContext, child)
        let output = match (outcome) {
            case Result.Ok(ToolInvocationResult.Completed(result)) => if (!result.isError) { result }
                else { try { return hostFailDocumentChild(operations, context, root, child,
                    AgentError(AgentErrorKind.RecoveryRequired, "plugin.document_child_failed", "document result proposal failed")) }
                    finally { result.releasePayload() } }
            case Result.Err(error) => return hostFailDocumentChild(operations, context, root, child, error)
            case Result.Ok(_) => return hostFailDocumentChild(operations, context, root, child,
                AgentError(AgentErrorKind.PermissionDenied, "plugin.document_child_denied", "document child did not execute")) }
        try {
        let receipt = VNextOperationReceipt("receipt-" + child.operationId.value, child.operationId,
            OperationOutcome.Completed, output.output, objectValue([
                ValueField("request_key", textValue(key)), ValueField("parent_operation_id", textValue(root.operationId.value)),
                ValueField("invocation_id", textValue(invocationId)), ValueField("request_id", textValue(requestId)),
                ValueField("service", textValue("document.store"))]), agentUtcMillis())
        let participant = match (selectHostDocumentCommitParticipant(context, root)) {
            case Result.Err(error) => return hostFailDocumentChild(operations, context, root, child, error)
            case Result.Ok(value) => value }
        match (guard.commit(operations, child, receipt, participant: participant)) {
            case Result.Err(error) => return hostFailDocumentChild(operations, context, root, child, error)
            case Result.Ok(_) => () }
        hostPluginServiceResult(requestId, "document.store", call.callId, receipt.receiptId, output.output, false)
        } finally { output.releasePayload() }
}

public func hostFailDocumentChild(operations: OperationRuntimePort, context: ToolInvocationContext,
    root: PreparedToolInvocation, child: PreparedToolInvocation, error: AgentError): JavaScriptHostResult<String> {
    // A failed commit may have a committed Receipt if acknowledgement failed.
    // Observe it before closing any obligation and never mutate a second time.
    match (operations.loadDerivedOperationReceipt(child.operationId, context.runId)) {
        case Result.Err(readError) => return hostPluginServiceAgentError(readError)
        case Result.Ok(Some(_)) => return hostPluginServiceError("plugin.document_commit_unknown", "document has a durable outcome but delivery was interrupted")
        case Result.Ok(None) => () }
    let state = match (operations.loadDerivedOperationState(child.operationId, context.runId)) {
        case Result.Err(stateError) => return hostPluginServiceAgentError(stateError); case Result.Ok(value) => value }
    let outcome = if (state == "prepared" || state == "waiting_approval") { OperationOutcome.Rejected } else { OperationOutcome.Unknown }
    let receipt = VNextOperationReceipt("receipt-" + child.operationId.value, child.operationId, outcome,
        objectValue([ValueField("error_code", textValue(error.code))]), objectValue([]), agentUtcMillis())
    match (operations.settleDerivedOperation(context.runId, root.operationId, receipt)) {
        case Result.Err(settleError) => return hostPluginServiceAgentError(settleError); case Result.Ok(_) => () }
    if (outcome == OperationOutcome.Unknown) {
        return hostPluginServiceAgentError(AgentError(AgentErrorKind.RecoveryRequired, "plugin.document_commit_unknown",
            "document commit or delivery did not reach a known terminal acknowledgement")) }
    hostPluginServiceAgentError(error)
}
