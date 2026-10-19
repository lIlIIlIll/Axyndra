package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import process4cj as process
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Host-only fixed package adapter authorization. This is not a process lease,
// canonical source or broker I/O grant. Each owner supplies its real policy.
public interface HostNativeServiceEndpointGrant {
    public func endpointTargetThread(): ThreadId
    public func endpointInstanceIdentity(): String
    public func endpointGrantDigest(): String
    public func endpointBinding(): AgentValue
    public func stillCurrent(): Result<Unit>
}

public class HostServiceEndpointSeal { init() {} }

// A failed selection can still own native resources. It must not disappear
// inside Result.Err while the lifecycle manager returns its reservation.
public enum HostServiceEndpointSelection {
    Ready(HostPinnedNativeServiceEndpoint) |
    Rejected(AgentError) |
    CleanupRequired(HostPinnedNativeServiceEndpoint, AgentError, AgentError)
}

public func hostServiceSelectionError(code: String, message: String): HostServiceEndpointSelection {
    HostServiceEndpointSelection.Rejected(AgentError(AgentErrorKind.Protocol, code, message))
}

public func hostFailedServiceSelection(endpoint: HostPinnedNativeServiceEndpoint,
    original: AgentError): HostServiceEndpointSelection {
    match (endpoint.close()) {
        case Result.Ok(_) => HostServiceEndpointSelection.Rejected(original)
        case Result.Err(cleanup) => HostServiceEndpointSelection.CleanupRequired(endpoint, original, cleanup)
    }
}

// Internal routing/ownership capability. Never serialized, decoded from plugin
// input, or substituted for a canonical source, approval or lifecycle lease.
public class HostPinnedNativeServiceEndpoint {
    let seal: HostServiceEndpointSeal
    public let generation: HostJavaScriptPluginGeneration
    public let namespace: String
    public let endpointIdentity: String
    public let workerGeneration: UInt64
    public let route: String
    public let targetThread: ThreadId
    public let maintenanceThread: ThreadId
    public let permissionDomain: String
    private let entry: HostJavaScriptPluginThreadHost
    private let worker: JavaScriptExtensionHost
    private let grant: HostNativeServiceEndpointGrant
    private let deadline: MonoTime
    private let stateLock = Mutex()
    private var stopping = false
    private var active = false
    private var released = false
    private var generationRegistration: ?process.CancellationRegistration = None
    private let lifecycle = process.CancellationSource()

    init(seal: HostServiceEndpointSeal, generation: HostJavaScriptPluginGeneration,
        entry: HostJavaScriptPluginThreadHost, grant: HostNativeServiceEndpointGrant,
        maintenanceThread: ThreadId, route: String, nonce: String) {
        this.seal = seal; this.generation = generation; this.entry = entry
        this.worker = entry.host; this.workerGeneration = entry.host.generation
        this.namespace = generation.extensionId; this.route = route; this.grant = grant
        this.targetThread = grant.endpointTargetThread(); this.maintenanceThread = maintenanceThread
        let plan = grant.endpointBinding()
        this.permissionDomain = hostLifecycleText(plan, "permission_domain")
        this.deadline = MonoTime.now() + Duration.millisecond * hostLifecycleInt(plan, "lifetime_ms", 3600000)
        this.endpointIdentity = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("schema", textValue("axyndra.pinned-native-endpoint/v1")),
            ValueField("nonce", textValue(nonce)), ValueField("grant", textValue(grant.endpointGrantDigest())),
            ValueField("instance", textValue(generation.instanceIdentity)),
            ValueField("worker_generation", textValue(workerGeneration.toString())),
            ValueField("target", textValue(targetThread.value)), ValueField("maintenance", textValue(maintenanceThread.value)),
            ValueField("route", textValue(route)), ValueField("permission_domain", textValue(permissionDomain))
        ])))
    }

    public func attachRevocation(registration: process.CancellationRegistration): Unit {
        stateLock.lock()
        let dispose = try {
            if (stopping) { true }
            else { generationRegistration = Some(registration); false }
        } finally { stateLock.unlock() }
        if (dispose) { registration.dispose() }
    }

    // Data-only observation of this exact endpoint's existing RPC scope.
    // invoke() clears active only after disposing its real cancellation loan.
    // This is neither process closure nor a Source/terminal acknowledgement.
    func hasActiveInvocation():Bool{
        stateLock.lock();try{active}finally{stateLock.unlock()}
    }
    public func available(): Bool {
        stateLock.lock()
        try { !stopping && !worker.isClosed && !worker.processExited && !generation.isClosing() && MonoTime.now() < deadline }
        finally { stateLock.unlock() }
    }

    public func observeRevocation(callback: () -> Unit): process.CancellationRegistration {
        // Registering after revocation invokes immediately, so a manager can
        // install its publication fence then recheck without a lost event.
        lifecycle.token.onCancel({ _ => callback() })
    }

    // No wait on the active invocation, any observer, or the stdin writer.
    public func revoke(): Unit {
        stateLock.lock()
        try { stopping = true } finally { stateLock.unlock() }
        let _ = lifecycle.cancel()
        worker.requestAbort()
    }

    public func close(timeoutMillis!: Int64 = 1000): Result<Unit> {
        if (timeoutMillis < 0 || timeoutMillis > 2000) {
            return hostPluginResourceError("plugin.service_cleanup_timeout_invalid", "endpoint cleanup wait must be within 0..2000 ms")
        }
        revoke()
        let until = MonoTime.now() + Duration.millisecond * timeoutMillis
        match (worker.awaitCleanup(timeoutMillis: timeoutMillis)) {
            case JavaScriptHostResult.Err(error) => return Result.Err(hostJavascriptPluginAgentError(error))
            case JavaScriptHostResult.Ok(_) => ()
        }
        while (true) {
            stateLock.lock()
            let busy = try { active } finally { stateLock.unlock() }
            if (!busy) { break }
            if (MonoTime.now() >= until) {
                return hostPluginResourceError("plugin.service_cleanup_pending", "native process ended but invocation cleanup remains owned")
            }
            sleep(Duration.millisecond)
        }
        stateLock.lock()
        let registration = try {
            if (released) { return Result.Ok(()) }
            released = true
            let previous = generationRegistration
            generationRegistration = None
            previous
        } finally { stateLock.unlock() }
        match (registration) { case Some(value) => value.dispose(); case None => () }
        lifecycle.close()
        generation.releasePinnedHost(entry)
        Result.Ok(())
    }

    public func supportsPreparationReference(): Bool {
        for (service in generation.services where service.name == route) { return service.supportsPreparationReference }
        false
    }

    public func invoke(argumentsJson: String, identity: JavaScriptHostInvocationIdentity,
        context: ToolInvocationContext, timeoutMillis: Int64,
        observer: ?JavaScriptHostObserver, prepared!: ?PreparedToolInvocation = None): Result<HostJavaScriptPluginInvocationResult> {
        var delegated = false
        match (prepared) { case Some(actual) =>
            if (hostManagedJobSource(actual.source.operationRoot).isSome()) {
                if (identity.kind != "service" || !supportsPreparationReference() || identity.operationId != actual.operationId.value ||
                    identity.callId != actual.call.callId || actual.source.kind == PreparedInvocationSourceKind.Derived) {
                    return hostResourceError("task.managed_job_endpoint_unsupported") }
                let binding = actual.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
                match (hostValidateManagedJobResource(context, actual.source.operationRoot, targetThread, permissionDomain, binding: Some(binding))) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (hostLifecycleText(binding, "endpoint_identity") != endpointIdentity) { return hostResourceError("task.managed_job_endpoint_changed") }
                delegated = true
            }
            case None => () }
        if (identity.threadId != context.sessionId.value || identity.runId != context.runId.value ||
            identity.epoch != context.epoch || context.epoch < 1 ||
            (!delegated && identity.threadId != targetThread.value && identity.threadId != maintenanceThread.value) ||
            hostPluginInvocationAuthorityScope(context) != permissionDomain) {
            return hostPluginResourceError("plugin.service_scope_mismatch", "actual invocation does not match this endpoint's Thread and permission domain")
        }
        let configuredTimeout = serviceProtocolLimits(grant.endpointBinding()).value().getOrThrow().callTimeoutMillis
        if (timeoutMillis < 1 || timeoutMillis > max(120000, configuredTimeout)) {
            return hostPluginResourceError("plugin.service_timeout_invalid", "service invocation exceeds the finite host-selected profile timeout")
        }
        if (context.cancellation.isCancelled()) {
            return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>("extension.cancelled", "service invocation was cancelled before dispatch")
        }
        if (MonoTime.now() >= deadline) {
            revoke()
            return hostPluginResourceError("plugin.service_endpoint_stale", "selected endpoint lifetime expired")
        }
        stateLock.lock()
        try {
            if (stopping || worker.isClosed || worker.processExited || generation.isClosing() || MonoTime.now() >= deadline) {
                return hostPluginResourceError("plugin.service_endpoint_stale", "fixed service endpoint expired or ended and cannot restart")
            }
            if (active) { return hostPluginResourceError("plugin.service_endpoint_busy", "fixed endpoint already owns an active invocation") }
            active = true
        } finally { stateLock.unlock() }
        let source = lifecycle.child(deadlineMillis: context.cancellation.deadlineMillis)
        let registration = context.cancellation.onCancel({ _ => revoke() })
        try {
            match (grant.stillCurrent()) {
                case Result.Err(error) => revoke(); return Result.Err(error)
                case Result.Ok(_) => ()
            }
            // A declaration/package check during mount is not a continuing
            // content binding for a worker that may read package files later.
            match (generation.registryPackageMatches81(generation.descriptor.root, namespace: Some(namespace),
                digest: Some(generation.descriptor.contentDigest), version: Some(generation.descriptor.version))) {
                case Result.Ok(packageMatches) =>
                    if (!packageMatches) {
                        revoke()
                        return hostPluginResourceError("plugin.snapshot_stale", "selected service package no longer matches its snapshot") }
                case Result.Err(_) =>
                    revoke()
                    return hostPluginResourceError("plugin.snapshot_stale", "selected service package cannot be revalidated")
            }
            if (!available() || context.cancellation.isCancelled()) {
                revoke()
                return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>("extension.cancelled", "selected service was revoked before dispatch")
            }
            var remaining = (deadline - MonoTime.now()).toMilliseconds()
            let now = agentUtcMillis()
            for (limit in [context.cancellation.deadlineMillis, context.budget.deadlineMillis] where limit > 0) {
                remaining = min(remaining, limit - now)
            }
            if (remaining < 1) { revoke(); return hostPluginResourceError("plugin.service_endpoint_stale", "selected endpoint lifetime expired") }
            let window = min(timeoutMillis, remaining)
            // Host-owned quota, never a frame field. Two 25 ms polling streams
            // fit the finite remaining call/lease window; all requests still
            // count and the broker must also enforce cumulative byte budgets.
            let requestLimit = if (identity.kind == "service_prepare") { 0 }
                else { min(8192, 2 * ((window + 24) / 25) + 2) }
            let response = hostPhysicalTransportDiagnostic(10, if (identity.kind == "service_prepare") { 1 } else { 2 }, argumentsJson.size, { => worker.invoke(route, argumentsJson, identity: identity,
                context: Some(JavaScriptHostInvocationContext(cwd: context.cwd, hasUI: false)),
                cancellation: source.token, timeoutMillis: window, serviceRequestLimit: requestLimit,
                observer: if (identity.kind == "service_prepare") { None } else { observer }) })
            hostPhysicalTransportDiagnosticOutcome(if (identity.kind == "service_prepare") { 1 } else { 2 }, response)
            if (context.cancellation.isCancelled() || generation.isClosing() || source.token.isCancelled()) {
                match (response) { case JavaScriptHostResult.Ok(value) => value.releasePayload(); case _ => () }
                revoke()
                return hostJavascriptPluginError<HostJavaScriptPluginInvocationResult>("extension.cancelled", "selected service invocation was cancelled")
            }
            match (response) {
                case JavaScriptHostResult.Err(error) => revoke(); Result.Err(hostJavascriptPluginAgentError(error))
                case JavaScriptHostResult.Ok(value) =>
                    match (hostPhysicalTransportDiagnostic(12, if (identity.kind == "service_prepare") { 1 } else { 2 }, value.resultJson.size, { => hostJavascriptPluginDecodeValue(value.resultJson, maxBytes: match (servicePayloadLimits(grant.endpointBinding()).value().getOrThrow()) {
                        case Some(limits) => if (identity.kind == "service_prepare") { limits.maxPrepareBytes } else { limits.maxResultBytes }
                        case None => if (identity.kind == "service_prepare") { serviceProtocolLimits(grant.endpointBinding()).value().getOrThrow().maxPrepareBytes }
                            else { serviceProtocolLimits(grant.endpointBinding()).value().getOrThrow().maxResultBytes }
                    }) })) {
                        case Result.Ok(result) => Result.Ok(HostJavaScriptPluginInvocationResult(result, value.isError, releasePayload: { => value.releasePayload() }))
                        case Result.Err(_) =>
                            value.releasePayload()
                            revoke()
                            hostPluginResourceError("extension.result_invalid", "service result is not bounded valid JSON")
                    }
            }
        } catch (_: Exception) {
            revoke()
            hostPluginResourceError("extension.protocol_failed", "fixed service invocation failed")
        } finally {
            registration.dispose()
            source.close()
            stateLock.lock()
            try { active = false } finally { stateLock.unlock() }
        }
    }
}
