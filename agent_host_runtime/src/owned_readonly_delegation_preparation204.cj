package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson_support.*
import yjson.*

func hostPrepareReadonlyDelegationOwned204(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall): Result<ToolCanonicalArgumentsOwner204> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let descriptor = match (host.servicePackage(namespace, generation)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    let paid = try { descriptor.deriveCopiedDataPayment(131072) } finally { descriptor.close() }
    let owner = try { ToolCanonicalArgumentsOwner204(paid) }
        catch (error: Exception) { paid.close(); throw error }
    try {
        buildOwnedReadonlyDelegationFrame204(host, settingsRoot, namespace, contribution, generation, context, call, owner)
        owner.producerFrameReturned204()
        Result.Ok(owner)
    } catch (error: Exception) { owner.holdUnknownConsumer204(); throw error }
}
private func buildOwnedReadonlyDelegationFrame204(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall, owner: ToolCanonicalArgumentsOwner204): Unit {
    match (hostPrepareReadonlyCatalog204(host, settingsRoot, namespace, contribution, generation, context, call, Some(owner))) {
        case Result.Err(error) => owner.installProducerError204(error); case Result.Ok(_) => () }
}
func hostPrepareReadonlyCatalog204(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall, owner: ?ToolCanonicalArgumentsOwner204): Result<AgentValue> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let shared = context.forkOwnedToolSetSnapshot159()
    try {
        let identity = match (shared) { case Some(value) => Some(value.copyIdentity159())
            case None => None<OwnedToolSnapshotIdentity159> }
        let result = readonlyCatalogCopyFrame204(host, settingsRoot, namespace, contribution, generation, context,
            call, owner, shared, context.legacyToolSetSnapshot159, identity)
        match (identity) { case Some(value) =>
            // A compatibility Raw result keeps only its own ID copy paid;
            // no historical export of the original schema graph occurred.
            if (owner.isNone()) { value.retainHistorical159() }
            value.returnCopiedFrame159()
            case None => () }
        result
    } finally { match (shared) { case Some(value) => value.close159(); case None => () } }
}
private func readonlyCatalogCopyFrame204(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, contribution: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall, owner: ?ToolCanonicalArgumentsOwner204, shared: ?SharedToolSetSnapshot159,
    legacy: ?ToolSetSnapshot, identity: ?OwnedToolSnapshotIdentity159): Result<AgentValue> {
    let raw = match (identity) {
        case Some(value) => value.withText159<Result<AgentValue>>({ text =>
            hostPrepareReadonlyDelegationDataFrame204(host, settingsRoot, namespace, contribution, generation,
                context, call, shared, legacy, Some(text)) })
        case None => hostPrepareReadonlyDelegationDataFrame204(host, settingsRoot, namespace, contribution, generation,
            context, call, shared, legacy, match (legacy) { case Some(value) => Some(value.id); case None => None<String> }) }
    match (owner) {
        case Some(output) =>
            match (raw) {
                case Result.Ok(value) =>
                    output.installProducerData204(value)
                    match (readonlyCopiedPreparationCurrent204(host, settingsRoot, namespace, generation, context, value)) {
                        case Result.Err(error) => output.rejectCopiedProducerData204(error); case Result.Ok(_) => () }
                case Result.Err(error) => output.installProducerError204(error) }
            Result.Ok(nullValue())
        case None => raw }
}

private func readonlyCopiedPreparationCurrent204(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, generation: UInt64, context: ToolInvocationContext, value: AgentValue): Result<Unit> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let descriptor = match (host.servicePackageData81(namespace, generation)) {
        case Result.Ok(current) => current; case Result.Err(error) => return Result.Err(error) }
    let plan = value.field("host_plan").getOrThrow()
    if (descriptor.contentDigest != httpIntentText(plan, "package_digest")) {
        return hostPluginResourceError("readonly_delegation.grant_changed", "installed package changed while copying preparation DATA") }
    let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
        case Result.Ok(current) => current; case Result.Err(error) => return Result.Err(error) }
    if (configuration.digest != httpIntentText(plan, "configuration_digest")) {
        return hostPluginResourceError("readonly_delegation.grant_changed", "operator configuration changed while copying preparation DATA") }
    configuration.stillCurrent()
}
