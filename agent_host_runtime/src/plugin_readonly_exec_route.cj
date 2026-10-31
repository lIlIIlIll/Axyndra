package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// Trusted distribution composition only. This selects an existing published
// catalog contribution; it cannot launch, admit, settle or mint a source.
// No plugin/JS/SDK decoder or registration accepts this port or its target.
public interface HostPluginReadOnlyExecRoute {
    func select(catalog: ToolCatalog, context: ToolInvocationContext, callId: String,
        arguments: AgentValue): Result<HostPluginReadOnlyExecTarget>
    func selectBound(host: HostJavaScriptPluginHost, catalog: ToolCatalog, context: ToolInvocationContext,
        callId: String, arguments: AgentValue): Result<HostPluginReadOnlyExecTarget> {
        select(catalog, context, callId, arguments)
    }
}

// A frozen descriptive selection, never approval or canonical authority.
// Only the shared helper constructs it after actual snapshot/catalog checks.
public class HostPluginReadOnlyExecTarget {
    private let callId: String
    private let name: String
    private let arguments: String
    private let snapshotId: String
    private let version: String
    private let fingerprint: String
    private let schemaDigest: String
    private let readView: ?HostReadOnlyExecReadView
    private let snapshotLock159 = Mutex()
    private var ownedSnapshot159: ?SharedToolSetSnapshot159 = None<SharedToolSetSnapshot159>
    private var snapshotReturned159 = false

    init(call: ToolCall, snapshot: ToolSetSnapshot, descriptor: ToolDescriptor,
        readView!: ?HostReadOnlyExecReadView = None) {
        this.callId = call.callId; this.name = call.name
        this.arguments = stringifyUnifiedJson(call.arguments)
        this.snapshotId = snapshot.id; this.version = descriptor.implementationVersion
        this.fingerprint = descriptor.implementationFingerprint; this.schemaDigest = descriptor.schemaDigest
        this.readView = readView
    }

    // Consumes one already paid share after all closed snapshot checks.
    init(call: ToolCall, snapshot: SharedToolSetSnapshot159, descriptor: ToolDescriptor,
        readView!: ?HostReadOnlyExecReadView = None) {
        this.callId = call.callId; this.name = call.name
        this.arguments = stringifyUnifiedJson(call.arguments)
        this.snapshotId = ""; this.version = descriptor.implementationVersion
        this.fingerprint = descriptor.implementationFingerprint; this.schemaDigest = descriptor.schemaDigest
        this.readView = readView; this.ownedSnapshot159 = Some(snapshot)
    }
    private func forkOwnedSnapshot159(): ?SharedToolSetSnapshot159 {
        snapshotLock159.lock()
        try {
            if (snapshotReturned159) { throw IllegalStateException("readonly target snapshot frame has returned") }
            match (ownedSnapshot159) { case Some(value) => Some(value.fork159())
                case None => None<SharedToolSetSnapshot159> }
        } finally { snapshotLock159.unlock() }
    }
    // Only an actual complete internal target consumer may return this frame.
    // Route/callback exports keep the original share until their owner returns.
    func returnOwnedTargetFrame159(): Unit {
        let returned = clearOwnedTargetFrame159()
        match (returned) { case Some(value) => value.close159(); case None => () }
    }
    private func clearOwnedTargetFrame159(): ?SharedToolSetSnapshot159 {
        snapshotLock159.lock()
        try {
            if (snapshotReturned159) { return None<SharedToolSetSnapshot159> }
            let returned = ownedSnapshot159
            ownedSnapshot159 = None<SharedToolSetSnapshot159>; snapshotReturned159 = true
            returned
        } finally { snapshotLock159.unlock() }
    }
    private func sameSnapshotFrame159(other: HostPluginReadOnlyExecTarget): Bool {
        let left = forkOwnedSnapshot159(); let right = other.forkOwnedSnapshot159()
        let equal = hostSameReadonlySnapshotBackingFrame159(left, right, snapshotId, other.snapshotId)
        match (right) { case Some(value) => value.close159(); case None => () }
        match (left) { case Some(value) => value.close159(); case None => () }
        equal
    }
    private func validateCurrentFrame159(current: HostPluginReadOnlyExecTarget): Result<Unit> {
        if (!sameSnapshotFrame159(current) || current.version != version ||
            current.fingerprint != fingerprint || current.schemaDigest != schemaDigest) {
            return hostPluginResourceError("extension.exec_target_changed", "readonly exec publication differs from its actual Run snapshot")
        }
        Result.Ok(())
    }

    public prop call: ToolCall {
        get() { ToolCall(callId, name, parseUnifiedJson(arguments, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES)) }
    }

    func isNativeReadView(): Bool { readView.isSome() }
    func context(root: PreparedToolInvocation, parent: ToolInvocationContext,
        ordinary: ToolInvocationContext): Result<ToolInvocationContext> {
        if (readView.isNone()) { return Result.Ok(ordinary) }
        let ceiling = CapabilitySet(values: root.operationPlan.requiredCapabilities)
        if (!ceiling.allows(CapabilityKind.ExtensionInvoke, resource: name) || !parent.capabilities.allows(CapabilityKind.ExtensionInvoke, resource: name)) {
            return hostPluginResourceError("extension.exec_parent_ceiling", "actual parent does not authorize the selected readonly QName") }
        let caps = ArrayList<Capability>()
        for (cap in ordinary.capabilities.values where cap.kind == CapabilityKind.WorkspaceRead) { caps.add(cap) }
        caps.add(Capability(CapabilityKind.ExtensionInvoke, resource: name))
        let child = ToolInvocationContext(parent.runId, parent.sessionId, CapabilitySet(values: caps.toArray()),
            sequence: parent.currentSequence(), epoch: parent.epoch,
            toolContext: ToolContextDescriptor(workspaceRoot: parent.workspaceRoot, cwd: parent.cwd, environment: parent.environment, services: parent.services, executionSettings180: parent.executionSettings180, modelFaultCounters180: parent.modelFaultCounters180),
            cancellation: parent.cancellation, approvalModeOverride: parent.approvalModeOverride, outputSink: parent.outputSink,
            budget: parent.budget, budgetModeFn: parent.budgetModeFn, contextProjection: parent.contextProjection, toolSetSnapshot: parent.legacyToolSetSnapshot159,
            ownedToolSetSnapshot159: parent.forkOwnedToolSetSnapshot159())
        match (child.inheritExecutionControlFrom(parent)) {
            case Result.Err(error) => if (child.hasOwnedToolSetSnapshot159()) { child.returnOwnedToolSetFrame159() }; return Result.Err(error)
            case Result.Ok(_) => () }
        Result.Ok(child)
    }
    func validate(catalog: ToolCatalog, context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Result<Unit> {
        if (prepared.call.callId != callId || prepared.call.name != name ||
            canonicalAgentValue(prepared.call.arguments) != canonicalAgentValue(call.arguments) ||
            prepared.operationPlan.toolName != name ||
            prepared.operationPlan.implementation.toolVersion != version ||
            prepared.operationPlan.implementation.implementationFingerprint != fingerprint ||
            prepared.operationPlan.implementation.schemaDigest != schemaDigest ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly ||
            !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return hostPluginResourceError("extension.exec_plan_changed", "readonly exec child lost its frozen request, implementation or denied-network plan")
        }
        match (readView) { case Some(value) => match (value.validate(catalog, context, prepared)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        let current = match (hostFreezePluginReadOnlyExecTarget(catalog, context, call, readView: readView)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let result = validateCurrentFrame159(current)
        // This fresh current target has never crossed a route/callback export.
        // Its entire scalar comparison helper returned before the clear.
        current.returnOwnedTargetFrame159()
        result
    }
}

public func hostFreezePluginReadOnlyExecTarget(catalog: ToolCatalog, context: ToolInvocationContext,
    call: ToolCall, readView!: ?HostReadOnlyExecReadView = None): Result<HostPluginReadOnlyExecTarget> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (context.hasOwnedToolSetSnapshot159()) {
        let snapshot = context.forkOwnedToolSetSnapshot159().getOrThrow()
        let result = hostFreezeOwnedReadonlyTargetFrame159(catalog, context, call, snapshot, readView)
        match (result) { case Result.Err(_) => snapshot.close159(); case Result.Ok(_) => () }
        return result
    }
    let snapshot = match (context.legacyToolSetSnapshot159) { case Some(value) => value
        case None => return hostPluginResourceError("extension.exec_snapshot_missing", "readonly exec requires the actual Run catalog snapshot") }
    match (snapshot.threadId) {
        case Some(thread) => if (thread.value != context.sessionId.value) {
            return hostPluginResourceError("extension.exec_thread_changed", "readonly exec catalog snapshot belongs to another Thread") }
        case None => return hostPluginResourceError("extension.exec_thread_missing", "readonly exec snapshot must retain its actual Thread")
    }
    let captured = try { ToolCall(call.callId, call.name,
        parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES)) }
        catch (_: Exception) { return hostPluginResourceError("extension.exec_arguments_invalid", "readonly exec request exceeds its bounded frozen JSON envelope") }
    var selected: ?ToolSnapshotEntry = None
    for (entry in snapshot.entries where entry.name == captured.name) { selected = Some(entry) }
    let entry = match (selected) { case Some(value) => value
        case None => return hostPluginResourceError("extension.exec_capability_missing", "readonly exec target was not published to the actual Run") }
    if (!entry.availableAtSnapshot || !entry.hasCompleteIdentity()) {
        return hostPluginResourceError("extension.exec_target_unavailable", "readonly exec target was unavailable or unbound at the actual snapshot") }
    let descriptor = match (catalog.resolvedDescriptor(captured, threadId: Some(ThreadId(context.sessionId.value)))) {
        case Some(value) => value
        case None => return hostPluginResourceError("extension.exec_target_missing", "readonly exec target is no longer published") }
    // Preserve the full executorVersion, including an existing instance binding.
    // The canonical pipeline remains the sole actual findForSnapshot/source owner.
    if (descriptor.implementationVersion != entry.executorVersion ||
        descriptor.implementationFingerprint != entry.implementationFingerprint || descriptor.schemaDigest != entry.schemaDigest ||
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

public class HostPublishedReadonlyExecRoute159 <: HostPluginReadOnlyExecRoute {
    public init() {}
    public func select(catalog: ToolCatalog, context: ToolInvocationContext, callId: String,
        arguments: AgentValue): Result<HostPluginReadOnlyExecTarget> {
        hostFreezePluginReadOnlyExecTarget(catalog, context, ToolCall(callId, "plugin.axyndra:shell-readonly.exec", arguments))
    }
    public func selectBound(host: HostJavaScriptPluginHost, catalog: ToolCatalog, context: ToolInvocationContext,
        callId: String, arguments: AgentValue): Result<HostPluginReadOnlyExecTarget> {
        hostFreezePluginReadOnlyReadViewTarget(host, catalog, context, ToolCall(callId, "plugin.axyndra:shell-readonly.exec", arguments))
    }
}
