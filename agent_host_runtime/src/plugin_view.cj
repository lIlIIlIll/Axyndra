package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import agent_ports.*
import agent_sdk.{PLUGIN_VIEW_MAX_BYTES, SdkResult, validatePluginViewDocument}
import std.time.*
import yjson.*
import yjson_support.*

public class HostPluginViewBinding {
    public let namespace: String
    public let contribution: String
    public let digest: String
    public let generation: UInt64
    init(namespace: String, contribution: String, digest: String, generation: UInt64) {
        this.namespace = namespace; this.contribution = contribution
        this.digest = digest; this.generation = generation
    }
}

// The document is borrowed from this result's actual Native payload custody.
// Keep the result open through consumption/serialization; close drops its DOM
// reference before returning the payload charge. It carries no execution fact.
public class HostPluginViewResult {
    public let binding: HostPluginViewBinding
    private var document: ?AgentValue
    private var retirement: ?() -> Unit
    init(response: HostJavaScriptPluginInvocationResult, binding: HostPluginViewBinding) {
        this.document = Some(response.value); this.retirement = Some(response.payloadRetirementCallback())
        this.binding = binding
    }
    public prop value: AgentValue { get() { document.getOrThrow() } }
    public func close(): Unit {
        document = None
        let release = retirement
        retirement = None
        match (release) { case Some(action) => action(); case None => () }
    }
}

private func hostViewQueryRemaining(deadline: ?MonoTime): Int64 {
    match (deadline) { case Some(value) => min(5000, (value - MonoTime.now()).toMilliseconds()); case None => 5000 }
}

// Only Host-constructed context may describe canonical sources. Plugin data
// never proves that a source, user event, approval or operation actually exists.
public func hostQueryPluginView(host: HostJavaScriptPluginHost, namespace: String, contribution: String,
    expectedDigest: String, context: AgentValue, input: AgentValue, thread: ThreadId,
    cancellation: CancellationToken, requestId: String, deadline!: ?MonoTime = None): Result<HostPluginViewResult> {
    match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (hostViewQueryRemaining(deadline) <= 0) {
        return hostPluginResourceError("view.deadline_exceeded", "View observation deadline expired") }
    if (context.unifiedKind != UnifiedJsonKind.Object || input.unifiedKind != UnifiedJsonKind.Object) {
        return hostPluginResourceError("view.query_invalid", "View context and input must be objects")
    }
    let binding = match (host.viewBinding(namespace, contribution)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (binding.digest != expectedDigest) {
        return hostPluginResourceError("view.changed", "selected View no longer matches its pinned package") }
    let mounted = match (host.servicePackage(namespace, binding.generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let payment = try {
        if (!mounted.textEquals(PluginDescriptorText.Namespace, namespace) ||
            !mounted.textEquals(PluginDescriptorText.ContentDigest, expectedDigest)) {
            return hostPluginResourceError("view.changed", "View query lost its actual package data owner") }
        mounted.deriveCopiedDataPayment(65536)
    } catch (_: LogicalJsonPayloadError) {
        return hostPluginResourceError("view.query_limit", "View query cannot acquire its package data custody")
    } finally { mounted.close() }
    try {
        let query = objectValue([ValueField("schema", textValue("axyndra.view-query/v1")),
            ValueField("context", context), ValueField("input", input)])
        let frozen = try {
            let _ = logicalJsonWriteReservationBytes(query, PLUGIN_VIEW_MAX_BYTES)
            HostFrozenPluginContentQuery(query, [], payment)
        } catch (_: Exception) {
            return hostPluginResourceError("view.query_limit", "View query exceeds its bounded data codec or aggregate capacity")
        }
        try {
            match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let remaining = hostViewQueryRemaining(deadline)
            if (remaining <= 0) { return hostPluginResourceError("view.deadline_exceeded", "View observation deadline expired") }
            let identity = JavaScriptHostInvocationIdentity(threadId: thread.value, runId: "", epoch: 0,
                operationId: "", callId: requestId, kind: "view")
            let encoded = stringifyUnifiedJson(frozen.query)
            let response = match (host.invoke(namespace, contribution, encoded, identity: identity,
                cancellation: cancellation, expectedInstanceGeneration: binding.generation,
                authorityScope: "pure-view:" + expectedDigest, timeoutMillis: remaining)) {
                case Result.Err(error) =>
                    if (error.code == "extension.payload_capacity") {
                        return hostPluginResourceError("view.query_limit", error.message) }
                    return Result.Err(error)
                case Result.Ok(value) => value
            }
            var retained = false
            try {
                if (response.isError) { return hostPluginResourceError("view.render_failed", "View renderer rejected its data query") }
                match (validatePluginViewDocument(response.value)) {
                    case SdkResult.Err(error) => return hostPluginResourceError("view.document_invalid", error.message)
                    case SdkResult.Ok(_) => ()
                }
                let current = match (host.viewBinding(namespace, contribution)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                if (current.digest != expectedDigest || current.generation != binding.generation) {
                    return hostPluginResourceError("view.changed", "View changed before its document was consumed") }
                match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (hostViewQueryRemaining(deadline) <= 0) {
                    return hostPluginResourceError("view.deadline_exceeded", "View observation deadline expired") }
                let result = HostPluginViewResult(response, binding)
                retained = true
                Result.Ok(result)
            } finally { if (!retained) { response.releasePayload() } }
        } finally { frozen.close() }
    } finally { payment.close() }
}
