package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import tool_runtime.{ToolExecutionHandoffLease, PreparedToolInvocation, PreparedInvocationSourceKind}
import agent_ports.ProcessPort
import agent_runtime.*
import std.sync.*
import sandbox4cj.SandboxProcessLaunchLease
import process4cj.{ManagedProcess, ProcessCommand, ProcessWriteAdmission, ProcessWriteLease}

// Neither adapter can mint a pin. They use the private Registry capture held
// by the actual mounted generation. These leases span spawn or one physical
// write, never a worker response, HTTP response, or canonical settlement.
public interface HostRegistryPackageProcessPort {
    func executePackageReadOnlyWithRegistry(request: ProcessRequest, workspaceRoot: String,
        acquire: () -> Result<PluginRegistryExecutionFence>): Result<ProcessResult>
}

class HostRegistryDispatchLease <: JavaScriptHostDispatchLease {
    private let fence: PluginRegistryExecutionFence
    init(fence: PluginRegistryExecutionFence) { this.fence = fence }
    public func close(): Unit { fence.close() }
}

class HostRegistryToolHandoffLease <: ToolExecutionHandoffLease {
    private let fence: PluginRegistryExecutionFence
    init(fence: PluginRegistryExecutionFence) { this.fence = fence }
    public func close(): Unit { fence.close() }
}

class HostRegistryDispatchFence <: JavaScriptHostDispatchFence & JavaScriptHostRetirableDispatchData159 & JavaScriptHostResidentMetadata159h {
    private let lock159 = Mutex()
    private var pin: ?PluginRegistryExecutionPin
    private var data: ?HostRegistryMountData159
    init(pin: PluginRegistryExecutionPin, data: HostRegistryMountData159) {
        this.pin = Some(pin); this.data = Some(data)
    }
    public func enter(): JavaScriptHostResult<JavaScriptHostDispatchLease> {
        lock159.lock()
        try {
            let current = match (pin) {
                case Some(value) => value
                case None => return JavaScriptHostResult.Err(JavaScriptHostError(
                    "plugin.registry_execution_stale", "retired dispatch data cannot enter a registry fence"))
            }
            match (current.enter()) {
                case PluginImportResult.Err(error) => JavaScriptHostResult.Err(hostRegistryFenceJavaScriptError159(data.getOrThrow(), error))
                case PluginImportResult.Ok(value) => JavaScriptHostResult<JavaScriptHostDispatchLease>.Ok(HostRegistryDispatchLease(value))
            }
        } finally { lock159.unlock() }
    }
    public func deriveHookResidentMetadata159h(invoice: Int64): LogicalJsonOwnerReservation {
        lock159.lock()
        try {
            // DATA child from the original record ledger. No pin enter,
            // Source reconstruction or caller-provided allocator occurs here.
            data.getOrThrow().deriveError159(invoice)
        } finally { lock159.unlock() }
    }
    private func clearRetired159(): ?HostRegistryMountData159 {
        lock159.lock()
        try { let original = data; data = None; pin = None; original }
        finally { lock159.unlock() }
    }
    public func retireDispatchData159(): Unit {
        // Only the actual Runtime collector calls this after its joined worker
        // and write frames returned and the host's fence field was cleared.
        match (clearRetired159()) { case Some(value) => value.retiredDispatch159(); case None => () }
    }
}

class HostRegistryProcessLauncher <: JavaScriptHostProcessLauncher {
    private let inner: JavaScriptHostProcessLauncher
    private let pin: PluginRegistryExecutionPin
    private let data: HostRegistryMountData159
    init(inner: JavaScriptHostProcessLauncher, pin: PluginRegistryExecutionPin, data: HostRegistryMountData159) {
        this.inner = inner; this.pin = pin; this.data = data
    }
    public func launch(command: ProcessCommand): JavaScriptHostResult<ManagedProcess> {
        let held = match (pin.enter()) {
            case PluginImportResult.Err(error) => return JavaScriptHostResult.Err(hostRegistryFenceJavaScriptError159(data, error))
            case PluginImportResult.Ok(value) => value
        }
        try { inner.launch(command) } finally { held.close() }
    }
}

class HostRegistryPhysicalDenied <: Exception {
    let error: AgentError
    init(error: AgentError) { super(error.message); this.error = error }
}
class HostRegistryProcessWriteLease <: ProcessWriteLease {
    private let held: PluginRegistryExecutionFence
    init(held: PluginRegistryExecutionFence) { this.held = held }
    public func close(): Unit { held.close() }
}
class HostRegistryProcessWriteAdmission <: ProcessWriteAdmission {
    private let acquire: () -> Result<PluginRegistryExecutionFence>
    init(acquire: () -> Result<PluginRegistryExecutionFence>) { this.acquire = acquire }
    public func check(): Unit { let held = enter(); held.close() }
    public func enter(): ProcessWriteLease {
        match (acquire()) {
            case Result.Err(error) => throw HostRegistryPhysicalDenied(error)
            case Result.Ok(value) => HostRegistryProcessWriteLease(value)
        }
    }
}
func hostAcquireRegistryEffect(admission: ?() -> Result<PluginRegistryExecutionFence>): Result<?PluginRegistryExecutionFence> {
    match (admission) {
        case None => Result.Ok(Option<PluginRegistryExecutionFence>.None)
        case Some(acquire) => match (acquire()) { case Result.Err(error) => Result.Err(error); case Result.Ok(value) => Result.Ok(Some(value)) }
    }
}
func hostCloseRegistryEffect(held: ?PluginRegistryExecutionFence): Unit {
    match (held) { case Some(value) => value.close(); case None => () }
}

class HostRegistrySandboxLaunchLease <: SandboxProcessLaunchLease {
    private let held: PluginRegistryExecutionFence
    init(held: PluginRegistryExecutionFence) { this.held = held }
    public func close(): Unit { held.close() }
}
func hostSandboxRegistryAdmission(admission: ?() -> Result<PluginRegistryExecutionFence>): ?() -> SandboxProcessLaunchLease {
    match (admission) {
        case None => None
        case Some(acquire) => Some({ =>
            match (acquire()) {
                case Result.Err(error) => throw HostRegistryPhysicalDenied(error)
                case Result.Ok(value) => let lease: SandboxProcessLaunchLease = HostRegistrySandboxLaunchLease(value); lease
            }
        })
    }
}

func hostRegistryHandoff(selected: Result<PluginRegistryExecutionFence>): Result<ToolExecutionHandoffLease> {
    match (selected) { case Result.Err(error) => Result.Err(error)
        case Result.Ok(value) => Result<ToolExecutionHandoffLease>.Ok(HostRegistryToolHandoffLease(value)) }
}
// The actual typed canonical root supplies original control arguments for a
// derived child's additional restriction. No JSON field selects a source.
func hostRegistryRootCall(prepared: PreparedToolInvocation): ToolCall {
    if (prepared.source.kind != PreparedInvocationSourceKind.Derived) { return prepared.call }
    match (prepared.source.operationRoot) {
        case Some(OperationRootSource.Direct(value)) => value.call
        case Some(OperationRootSource.Committed(value)) => ToolCall(value.block.callId, value.block.name, value.block.arguments)
        case None => prepared.call
    }
}
