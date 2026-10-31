package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.sync.*
import std.fs.*

foreign func axyndra_registry_snapshot_open(path: CString): Int64
foreign func axyndra_registry_snapshot_size(handle: Int64): Int64
foreign func axyndra_registry_snapshot_freeze(handle: Int64): Int32
foreign func axyndra_registry_snapshot_copy(handle: Int64, bytes: CPointer<UInt8>, capacity: Int64): Int32
foreign func axyndra_registry_snapshot_validate(handle: Int64): Int32
foreign func axyndra_registry_snapshot_close(handle: Int64): Unit

// Data/resource extent only: no Source, execution or pin authority. Includes
// real snapshot/watcher wrappers, one retained 16 KiB native buffer reused for
// events and byte comparisons, bound parent/name arrays and full path copies.
// Kernel queues, like pipe queues, remain kernel FD resources; overflow or lost
// watch evidence revokes the snapshot and never yields a partial admission.
func pluginRegistrySnapshotObservationCost76(pathBytes: Int64): Int64 {
    if (pathBytes < 0 || pathBytes > 16777216) {
        throw LogicalJsonPayloadError("registry metadata observation path exceeds its original resource bounds")
    }
    pathBytes * 8 + 65536
}

class PluginRegistryMetadataSnapshot {
    var path: String
    private let handle: Int64
    private let absent: Bool
    private let size: Int64
    private var closed = false

    init(path: String) {
        this.path = path
        let physical = if (Path(path).isAbsolute()) { path }
            else { pluginRegistryFencePath180(path, canonicalize(Path(".")).toString()) }
        handle = unsafe {
            let raw = LibC.mallocCString(physical)
            try { axyndra_registry_snapshot_open(raw) } finally { LibC.free(raw) }
        }
        pluginRegistryNativeFailure(handle)
        let count = unsafe { axyndra_registry_snapshot_size(handle) }
        absent = count == -1; size = if (absent) { 0 } else { count }
        try {
            if (count < -1 || count > 16777216) {
                throw PluginRegistryWriteError("plugin.registry_metadata_invalid", "installed metadata has no bounded regular extent")
            }
        } catch (error: Exception) { close(); throw error }
    }

    func storageBytes(): Int64 { size }
    func freeze(): Unit {
        pluginRegistryNativeFailure(Int64(unsafe { axyndra_registry_snapshot_freeze(handle) }))
        validate()
    }

    func source(): ?String {
        if (closed) { throw PluginRegistryWriteError("plugin.registry_pin_closed", "metadata snapshot is closed") }
        if (absent) { return None }
        if (size == 0) { return Some("") }
        let bytes = Array<UInt8>(size, repeat: 0)
        let status = unsafe {
            let raw = acquireArrayRawData(bytes)
            try { axyndra_registry_snapshot_copy(handle, raw.pointer, size) }
            finally { releaseArrayRawData(raw) }
        }
        pluginRegistryNativeFailure(Int64(status))
        Some(String.fromUtf8(bytes))
    }

    func validate(): Unit {
        if (closed) { throw PluginRegistryWriteError("plugin.registry_pin_closed", "metadata snapshot is closed") }
        let status = unsafe { axyndra_registry_snapshot_validate(handle) }
        if (status < 0) {
            throw PluginRegistryWriteError("plugin.registry_execution_stale", "installed metadata path, inode or complete bytes changed")
        }
    }

    func close(): Unit {
        if (closed) { return }; closed = true
        unsafe { axyndra_registry_snapshot_close(handle) }; path = ""
    }
}

// A short synchronous physical admission holds shared locks. It never owns a
// Run/Operation, never authorizes a worker response, and never crosses IPC.
public class PluginRegistryExecutionFence {
    private let lock = Mutex()
    private var release: ?() -> Unit
    init(release: () -> Unit) { this.release = Some(release) }
    public func close(): Unit {
        let action = synchronized(lock) { let selected = release; release = None; selected }
        match (action) { case Some(value) => value(); case None => () }
    }
}

// Constructor and arming are package-private. Deserialized records are data:
// only Registry.captureExecutionPin arms this after reading exact installed
// state under both actual OS locks. Closing cannot release active snapshots
// until the last physical admission has acknowledged its short fence.
public class PluginRegistryExecutionPin {
    private let lock = Mutex()
    private var settingsRoot: String
    private var workspaceRoot: String
    private let generation: PluginRegistryMetadataGeneration
    private let memory: PluginRegistryInspectionMemory
    private var retainedCost: Int64 = 0
    private var selectedPayment103: ?PluginRegistryMetadataPayment = None
    private var loadingPayment103: ?PluginRegistryMetadataPayment = None
    private var generationReleased = false
    private var loading = false
    private var pendingStatePublication = false
    private var armed = false
    private var revoked = false
    private var closed = false
    private var active: Int64 = 0
    private var identity = ""
    private var installed: ?RawProductPluginRecord = None
    private let ownedBackings = ArrayList<PluginRegistryOwnedBacking>()
    private var scope: PluginInstallScope = PluginInstallScope.User

    // The registry transfers one already-retained generation reference here.
    init(settingsRoot: String, workspaceRoot: String, generation: PluginRegistryMetadataGeneration) {
        this.settingsRoot = settingsRoot; this.workspaceRoot = workspaceRoot
        this.generation = generation; this.memory = PluginRegistryInspectionMemory(generation)
    }
    func beginLoad(actual: PluginRegistryMetadataPayment): Unit {
        generation.beginLoad(actual); loadingPayment103 = Some(actual); memory.beginLoad103(actual); loading = true
    }
    func prepareStatePublication103(initial: PluginRegistryInitialState): Unit {
        generation.retainState(pluginRegistryRetainedStateInvoice103(initial.records, initial.history, initial.loadErrors), loadingPayment103.getOrThrow())
    }
    // The Registry outer capture finally calls this after its full inner frame
    // returns. This never claims that caller-owned record/data aliases ended.
    func retireLoadingPhase103(): Unit {
        match (loadingPayment103) {
            case Some(actual) =>
                memory.retireLoad103(actual); generation.abortLoad(actual)
                loadingPayment103 = None; loading = false; pendingStatePublication = false
            case None => ()
        }
    }
    func beginRecordInspection103(): Unit { memory.beginRecord103() }
    func finishRecordInspection103(records: ArrayList<RawProductPluginRecord>,
        history: HashMap<String, ArrayList<RawProductPluginRecord>>, errors: ArrayList<PluginImportError>): Unit {
        generation.retainLoadData103(pluginRegistryRetainedStateInvoice103(records, history, errors), loadingPayment103.getOrThrow())
        // The complete private row helper returned. Only prepaid typed state
        // remains reachable; no tree/DOM producer local exits this helper.
        let returned = memory.takeReturnedRecordPayment103()
        returned.close()
    }
    func retainLoadedState103(initial: PluginRegistryInitialState): Unit {
        generation.retainLoadData103(pluginRegistryRetainedStateInvoice103(initial.records, initial.history, initial.loadErrors), loadingPayment103.getOrThrow())
    }
    func inspectionMemory(): PluginPackageMetadataAccounting { memory }
    func beforeLoadedRecord78(record: RawProductPluginRecord): Unit { memory.chargeWork103(pluginOwnedRecordInvoice78(record)) }
    func source(path: String): ?String {
        let selected = generation.source(path, loadingPayment103.getOrThrow())
        // Includes repeated workspace-grant DOM decoding in the real loader.
        // Every actual grant/row parser opens its own closed DOM phase.
        selected
    }
    func arm(record: RawProductPluginRecord): Unit {
        if (armed || closed || revoked || !record.enabled || record.explicitlyDisabled) {
            throw PluginRegistryWriteError("plugin.registry_execution_stale", "installed execution pin cannot be armed")
        }
        validateSnapshots()
        let cost = pluginOwnedRecordInvoice78(record)
        let selected = generation.finishLoad(cost, pluginRegistryPinIdentityInvoice103(record), loadingPayment103.getOrThrow())
        selectedPayment103 = Some(selected); retainedCost = cost; loading = false; pendingStatePublication = true
        identity = pluginLockLine(record); scope = record.scope; installed = Some(record); armed = true
    }
    func completeStatePublication(): Unit {
        if (!pendingStatePublication || closed || !armed) {
            throw IllegalStateException("installed pin has no pending state publication")
        }
        generation.completeStatePublication(loadingPayment103.getOrThrow()); pendingStatePublication = false
    }
    // Actual mount obtains the freshly inspected installed record from its own
    // capture, never the caller-provided descriptor used as a lookup identity.
    public func capturedRecord(): PluginRegistryResult<ProductPluginRecord> {
        lock.lock()
        try {
            if (!armed || closed || revoked) { return pluginRegistryStaticFailure78("plugin.registry_execution_stale", reason: PluginRegistryStaticReason.ExecutionNotCurrent) }
            match (installed) {
                case Some(value) =>
                    let payment = generation.openDataPayment78()
                    try {
                        payment.ensureRetainedPeak(8192)
                        payment.ensureRetainedPeak(pluginOwnedRecordInvoice78(value) + 2048)
                        let backing = PluginRegistryOwnedBacking(value, payment)
                        ownedBackings.add(backing); PluginRegistryResult.Ok(ProductPluginRecord(backing))
                    } catch (error: Exception) { payment.close(); throw error }
                case None => pluginRegistryStaticFailure78("plugin.registry_execution_stale", reason: PluginRegistryStaticReason.InstalledRecordAbsent)
            }
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
        finally { lock.unlock() }
    }
    public func matches(record: ProductPluginRecord): Bool {
        lock.lock()
        try {
            if (!armed || closed || revoked) { return false }
            try {
                let scratch = generation.openScratch103()
                try { matchesFrame103(record, scratch) } finally { scratch.close() }
            } catch (_: LogicalJsonPayloadError) { false }
        } finally { lock.unlock() }
    }
    private func matchesFrame103(record: ProductPluginRecord, scratch: PluginRegistryMetadataPayment): Bool {
        record.withRecord({ value =>
            // The temporary comparison String is a separate full escaped
            // occurrence, additional to the original 4MiB fixed scratch.
            scratch.ensureRetainedPeak(pluginRegistryInvoiceAdd78(4194304, pluginRegistryPinIdentityInvoice103(value)))
            pluginScopeEquals(scope, value.scope) && identity == pluginLockLine(value)
        })
    }
    private func validateSnapshots(): Unit {
        match (loadingPayment103) {
            case Some(actual) => generation.validateLoad103(actual)
            case None => generation.validate()
        }
    }
    private func releaseSnapshots(): Unit {
        if ((!closed && !revoked) || active != 0) { return }
        if (generationReleased) { return }
        if (loading || pendingStatePublication || loadingPayment103.isSome()) {
            // The unpublished pin is private to the Registry capture frame;
            // its outer finally retires this exact token after frame RETURN.
            throw IllegalStateException("capture phase must return before pin retirement")
        }
        generationReleased = true
        installed = None; identity = ""
        for (backing in ownedBackings) { backing.close() }; ownedBackings.clear()
        settingsRoot = ""; workspaceRoot = ""
        let selected = selectedPayment103; selectedPayment103 = None
        match (selected) { case Some(value) => value.close(); case None => () }
        generation.release(retainedCost); retainedCost = 0
    }
    private func leave(): Unit {
        lock.lock(); try { active--; generation.releaseFence(); releaseSnapshots() } finally { lock.unlock() }
    }
    public func enter(): PluginImportResult<PluginRegistryExecutionFence> {
        lock.lock()
        try {
            if (!armed || closed || revoked) { return pluginImportError("plugin.registry_execution_stale", "installed execution pin is not current") }
            let admission = try { generation.reserveFence() }
            catch (error: PluginRegistryWriteError) { return pluginImportError(error.code, error.message) }
            catch (_: Exception) { return pluginImportError("plugin.registry_metadata_capacity", "actual admission metadata cannot fit its shared owner") }
            let held = try { PluginRegistryWriterFence(settingsRoot, workspaceRoot, shared: true) }
                catch (error: PluginRegistryWriteError) { generation.releaseFence(); admission.close(); return pluginImportError(error.code, error.message) }
                catch (_: Exception) { generation.releaseFence(); admission.close(); return pluginImportError("plugin.registry_lock_failed", "installed state cannot be fenced") }
            var entered = false
            try {
                held.validate(); validateSnapshots(); held.validate()
                active++; entered = true
                PluginImportResult.Ok(PluginRegistryExecutionFence({ => held.close(); leave(); admission.close() }))
            } catch (error: PluginRegistryWriteError) {
                if (entered) { active-- }; generation.releaseFence()
                held.close(); revoked = true; releaseSnapshots(); admission.close(); pluginImportError(error.code, error.message)
            } catch (error: LogicalJsonPayloadError) {
                // Budget refusal, not a revocation: report the capacity limit the
                // caller actually hit and leave the generation usable.
                if (entered) { active-- }; generation.releaseFence()
                held.close(); releaseSnapshots(); admission.close()
                pluginImportError("plugin.registry_metadata_capacity", "actual admission metadata cannot fit its shared owner")
            } catch (_: Exception) {
                if (entered) { active-- }; generation.releaseFence()
                held.close(); revoked = true; releaseSnapshots(); admission.close(); pluginImportError("plugin.registry_execution_stale", "installed metadata cannot be revalidated")
            }
        } finally { lock.unlock() }
    }
    public func current(): PluginImportResult<Unit> {
        match (enter()) {
            case PluginImportResult.Err(error) => PluginImportResult<Unit>.Err(error)
            case PluginImportResult.Ok(held) => held.close(); PluginImportResult<Unit>.Ok(())
        }
    }
    public func close(): Unit {
        lock.lock(); try { closed = true; releaseSnapshots() } finally { lock.unlock() }
    }
}

// The retained identity is a SECOND String, separate from installed RawRecord.
// Preserve the original full row delta and add all escaped UTF8 occurrences.
func pluginRegistryPinIdentityInvoice103(record: RawProductPluginRecord): Int64 {
    var invoice: Int64 = 8192
    for (text in [record.descriptor.id, record.descriptor.version, record.descriptor.namespace,
        record.locator, record.descriptor.root, record.versionLock, record.revisionLock,
        record.integrityLock, record.contentLock]) {
        invoice = pluginRegistryInvoiceAdd78(invoice, text.size * 48)
    }; invoice
}
