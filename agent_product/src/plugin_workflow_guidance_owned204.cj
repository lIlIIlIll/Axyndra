package agent_product

import agent_domain.*
import agent_plugin_registry.*
import agent_sdk.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// The actual Catalog lends only copied names and immutable publication pins.
// Every escaped String gets an independent original-bank allocation retained
// by the existing Product compatibility-copy lifecycle, never its source loan.
private class ProductWorkflowTextCopies204 {
    private let source: ToolCatalogIdentityOwner204
    private let temporary: LogicalJsonOwnerReservation
    private var retained: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var retainedPeak: Int64 = 0
    init(source: ToolCatalogIdentityOwner204, temporary: LogicalJsonOwnerReservation) {
        this.source = source; this.temporary = temporary
    }
    func fundInput204(tools: Array<ToolCatalogIdentity204>): Unit {
        var bytes: Int64 = 0
        for (tool in tools) {
            if (tool.name.size > 134217728 - bytes) { throw LogicalJsonPayloadError("workflow input invoice overflow") }
            bytes += tool.name.size
        }
        // Temporary fields, exact name DTOs and original canonical input
        // encodings overlap until the complete concrete query helper returns.
        temporary.ensureRetainedPeak(productRegistryCopyInvoice83(bytes, 1048576 + tools.size * 4096))
    }
    private func fundReturned204(texts: Array<String>, slots: Int64): Unit {
        var bytes: Int64 = 0
        for (text in texts) {
            if (text.size > 134217728 - bytes) { throw LogicalJsonPayloadError("workflow output invoice overflow") }
            bytes += text.size
        }
        let invoice = productRegistryCopyInvoice83(bytes, 65536 + slots * 1024)
        if (retainedPeak > 134217728 - invoice) { throw LogicalJsonPayloadError("workflow retained SUM exceeds its original bound") }
        retainedPeak += invoice
        match (retained) {
            case Some(value) => value.ensureRetainedPeak(retainedPeak)
            case None => retained = Some(source.deriveRetainedAllocation204(retainedPeak))
        }
    }
    func copyBinding204(value: (String, String, String)): (String, String, String) {
        fundReturned204([value[0], value[1], value[2]], 3)
        (String.fromUtf8(value[0].toArray()), String.fromUtf8(value[1].toArray()), String.fromUtf8(value[2].toArray()))
    }
    func copyGuidance204(name: String, guide: String, system: String, correction: String,
        version: String, fingerprint: String, pin: ProductWorkflowPin): ProductWorkflowGuidance {
        fundReturned204([name, guide, system, correction, version, fingerprint], 6)
        ProductWorkflowGuidance(String.fromUtf8(name.toArray()), String.fromUtf8(guide.toArray()),
            String.fromUtf8(system.toArray()), String.fromUtf8(correction.toArray()), pin: Some(pin),
            planVersion: String.fromUtf8(version.toArray()), planFingerprint: String.fromUtf8(fingerprint.toArray()))
    }
    func copyError204(error: AgentError): AgentError {
        // Native workflow policy failures here have scalar error fields. An
        // unknown attached graph cannot be treated as a completed loan reader.
        if (error.attemptFailure.isSome() || error.observation.isSome()) {
            throw IllegalStateException("workflow error has an unowned attached graph") }
        let texts = ArrayList<String>([error.code, error.message])
        for (field in error.fields) { texts.add(field.name); texts.add(field.value) }
        fundReturned204(texts.toArray(), error.fields.size + 1)
        let fields = ArrayList<ErrorField>()
        for (field in error.fields) {
            fields.add(ErrorField(String.fromUtf8(field.name.toArray()), String.fromUtf8(field.value.toArray()))) }
        AgentError(error.kind, String.fromUtf8(error.code.toArray()), String.fromUtf8(error.message.toArray()),
            retryable: error.retryable, fallbackAllowed: error.fallbackAllowed, fields: fields.toArray())
    }
    func completeReturnedBuilder204(): Unit {
        // The entire private query/copy frame has returned. Errors have copied
        // DATA too; Result.Err alone is never interpreted as consumer return.
        match (retained) { case Some(value) => productRegistryEscapedCopies83.adopt(value); case None => () }
        retained = None<LogicalJsonOwnerReservation>
        temporary.close()
    }
}

private func productCurrentWorkflowIdentity204(runtime: ProductRuntime, sessionId: SessionId,
    tools: Array<ToolCatalogIdentity204>, selection: ProductPolicySelection,
    binding: ProductPluginPolicyBinding): Result<(String, String, String)> {
    let host = runtime.vnext.javascriptPlugins
    match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (selection.planTool == "") { return workflowConsumerError("workflow.plan_tool_missing") }
    let descriptor = match (host.servicePackage(selection.namespace, binding.generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        if (!descriptor.textEquals(PluginDescriptorText.ContentDigest, selection.digest) ||
            !descriptor.textEquals(PluginDescriptorText.Namespace, selection.namespace)) { return workflowConsumerError("workflow.source_changed") }
        if (!descriptor.hasToolExecutionProfile205(selection.planTool, PluginToolExecutionProfile.DataOnly)) {
            return workflowConsumerError("workflow.plan_tool_missing") }
        for (tool in tools where productWorkflowNameMatches205(tool.name, selection.namespace, selection.planTool)) {
            if (tool.fingerprint != selection.namespace + ":" + selection.digest ||
                !runtime.workflowPublishedIdentityMatches204(sessionId, tool.name, tool.version, tool.fingerprint)) {
                return workflowConsumerError("workflow.source_changed") }
            match (selection.validateBinding(host, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            return Result.Ok((tool.name, tool.version, tool.fingerprint))
        }
        workflowConsumerError("workflow.plan_tool_missing")
    } finally { descriptor.close() }
}

private func productWorkflowBindingCopyFrame204(runtime: ProductRuntime, sessionId: SessionId,
    tools: Array<ToolCatalogIdentity204>, copies: ProductWorkflowTextCopies204): Result<(String, String, String)> {
    let source = productWorkflowBindingFrame204(runtime, sessionId, tools)
    match (source) { case Result.Err(error) => Result.Err(copies.copyError204(error))
        case Result.Ok(value) => Result.Ok(copies.copyBinding204(value)) }
}
private func productWorkflowBindingFrame204(runtime: ProductRuntime, sessionId: SessionId,
    tools: Array<ToolCatalogIdentity204>): Result<(String, String, String)> {
    let selection = match (loadProductPolicySelection(runtime.settingsRoot, "workflow")) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let binding = match (runtime.vnext.javascriptPlugins.policyProviderBinding(selection.namespace, selection.provider)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    productCurrentWorkflowIdentity204(runtime, sessionId, tools, selection, binding)
}

func queryProductWorkflowPlanBindingOwned204(runtime: ProductRuntime, sessionId: SessionId,
    capabilities: ?CapabilitySet): Result<(String, String, String)> {
    let source = match (runtime.workflowToolIdentities204(sessionId, capabilities)) {
        case Some(value) => value; case None => return workflowConsumerError("workflow.plan_tool_missing") }
    let temporary = source.deriveRetainedAllocation204(131072)
    let copies = ProductWorkflowTextCopies204(source, temporary)
    let consumer = source.beginConsumer204()
    let result = consumer.withIdentities204({ tools => productWorkflowBindingCopyFrame204(runtime, sessionId, tools, copies) })
    copies.completeReturnedBuilder204()
    consumer.returnConsumerFrame204(); source.closeAfterCaller204()
    result
}

func queryProductWorkflowGuidanceOwned204(runtime: ProductRuntime, sessionId: SessionId, mode: String,
    capabilities: ?CapabilitySet): Result<ProductWorkflowGuidance> {
    if (mode == "" || mode == "none") { return Result.Ok(ProductWorkflowGuidance("", "", "", "")) }
    let source = match (runtime.workflowToolIdentities204(sessionId, capabilities)) {
        case Some(value) => value; case None => return workflowConsumerError("workflow.plan_tool_missing") }
    let temporary = source.deriveRetainedAllocation204(131072)
    let copies = ProductWorkflowTextCopies204(source, temporary)
    let consumer = source.beginConsumer204()
    let result = consumer.withIdentities204({ tools => productWorkflowGuidanceCopyFrame204(runtime, sessionId, mode, tools, copies) })
    copies.completeReturnedBuilder204()
    consumer.returnConsumerFrame204(); source.closeAfterCaller204()
    result
}
private func productWorkflowGuidanceCopyFrame204(runtime: ProductRuntime, sessionId: SessionId, mode: String,
    tools: Array<ToolCatalogIdentity204>, copies: ProductWorkflowTextCopies204): Result<ProductWorkflowGuidance> {
    copies.fundInput204(tools)
    match (productWorkflowGuidanceFrame204(runtime, sessionId, mode, tools, copies)) {
        case Result.Err(error) => Result.Err(copies.copyError204(error)); case Result.Ok(value) => Result.Ok(value) }
}
private func productWorkflowGuidanceFrame204(runtime: ProductRuntime, sessionId: SessionId, mode: String,
    tools: Array<ToolCatalogIdentity204>, copies: ProductWorkflowTextCopies204): Result<ProductWorkflowGuidance> {
    let selection = match (loadProductPolicySelection(runtime.settingsRoot, "workflow")) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let host = runtime.vnext.javascriptPlugins
    let binding = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let selected = match (productCurrentWorkflowIdentity204(runtime, sessionId, tools, selection, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let cancellation = CancellationSource()
    try {
        let query = match (queryProductWorkflow(runtime, "guidance", [
            ValueField("mode", textValue(mode)), ValueField("tools", listValue(tools.map { tool => textValue(tool.name) })),
            ValueField("plan_tool", textValue(selected[0]))], sessionId, cancellation.token, "workflow-mode-guidance")) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            // Only known malformed provider fields become a protocol error.
            // Output payment, copying and later current checks remain outside
            // this parser catch so an unknown reader failure stays Held.
            let text = try {
                workflowRequireFields(query.response.value, ["source_digest", "guide", "system", "correction"])
                (workflowRoleText(query.response.value, "guide"), workflowRoleText(query.response.value, "system"),
                    workflowRoleText(query.response.value, "correction"))
            } catch (_: IllegalArgumentException) { return workflowConsumerError("workflow.guidance_invalid") }
            catch (_: JsonException) { return workflowConsumerError("workflow.guidance_invalid") }
            if (query.response.binding.namespace != binding.namespace || query.response.binding.digest != binding.digest ||
                query.response.binding.contribution != binding.contribution || query.response.binding.generation != binding.generation) {
                return workflowConsumerError("workflow.source_changed") }
            let value = copies.copyGuidance204(selected[0], text[0], text[1], text[2],
                selected[1], selected[2], query.pin)
            match (value.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!runtime.workflowPublishedIdentityMatches204(sessionId, value.planTool, value.planVersion, value.planFingerprint)) {
                return workflowConsumerError("workflow.source_changed") }
            Result.Ok(value)
        } finally { query.close() }
    } finally { cancellation.close() }
}
