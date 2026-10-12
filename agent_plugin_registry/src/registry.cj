package agent_plugin_registry

import agent_extension_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.fs.*
import std.time.*
import std.sync.*
import agent_domain.*
public enum PluginSourceKind { Local | Git | Npm }
public enum PluginInstallScope { User | Workspace }


public class PluginImportError {
    public let code: String
    public let message: String
    public init(code: String, message: String) { this.code = code; this.message = message }
}

public enum PluginImportResult<T> {
    Ok(T) | Err(PluginImportError)
    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }
}

class RawProductPluginRecord {
    public let descriptor: PluginPackageDescriptor
    public let sourceKind: PluginSourceKind
    public let locator: String
    public let versionLock: String
    public let revisionLock: String
    public let integrityLock: String
    public let contentLock: String
    public let scope: PluginInstallScope
    public let explicitlyDisabled: Bool
    public let enabled: Bool
    public let importedAt: Int64

    init(descriptor: PluginPackageDescriptor, sourceKind: PluginSourceKind, locator: String,
        versionLock: String, revisionLock: String, integrityLock: String, contentLock: String,
        enabled: Bool, importedAt: Int64, scope!: PluginInstallScope = PluginInstallScope.User,
        explicitlyDisabled!: Bool = false) {
        this.descriptor = descriptor
        this.sourceKind = sourceKind
        this.locator = locator
        this.versionLock = versionLock
        this.revisionLock = revisionLock
        this.integrityLock = integrityLock
        this.contentLock = contentLock
        this.enabled = enabled
        this.importedAt = importedAt
        this.scope = scope
        this.explicitlyDisabled = explicitlyDisabled
    }
}
func pluginAcquisitionRecordMatches(
    record: RawProductPluginRecord,
    spec: ProductPluginAcquisitionSpec
): Bool {
    let sameKind = match ((record.sourceKind, spec.kind)) {
        case (PluginSourceKind.Local, PluginSourceKind.Local) => true
        case (PluginSourceKind.Git, PluginSourceKind.Git) => true
        case (PluginSourceKind.Npm, PluginSourceKind.Npm) => true
        case _ => false
    }
    if (!sameKind || record.locator != spec.sourceLocator) { return false }
    match (spec.kind) {
        case PluginSourceKind.Git => record.revisionLock == spec.revision &&
            record.versionLock == record.descriptor.version
        case PluginSourceKind.Npm => record.versionLock == spec.version &&
            record.integrityLock.startsWith("sha512-")
        case PluginSourceKind.Local => false
    }
}
public func pluginScopeRoot(settingsRoot: String, workspaceRoot: String, scope: PluginInstallScope): String {
    match (scope) {
        case PluginInstallScope.User => settingsRoot
        case PluginInstallScope.Workspace => workspaceRoot + "/.axyndra"
    }
}

public func pluginSnapshotPackageRoot(
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope
): String {
    let root = settingsRoot + "/plugins/packages"
    match (scope) {
        case PluginInstallScope.User => root + "/user"
        case PluginInstallScope.Workspace =>
            let identity = try {
                canonicalize(Path(workspaceRoot)).toString()
            } catch (_: Exception) {
                workspaceRoot
            }
            root + "/workspaces/" + modelPolicySha256Text(identity)
    }
}

public func pluginRequireWorkspaceStorage(workspaceRoot: String, storageRoot: String, descendant: String): Unit {
    if (workspaceRoot.trimAscii() == "" || storageRoot != workspaceRoot + "/.axyndra") {
        throw IllegalArgumentException("workspace plugin storage root is invalid")
    }
    for (candidate in [storageRoot, storageRoot + "/plugins", descendant]) {
        if (exists(Path(candidate)) && FileInfo(Path(candidate)).isSymbolicLink()) {
            throw IllegalArgumentException("workspace plugin storage must not contain symbolic-link ancestors")
        }
    }
    if (exists(Path(storageRoot))) {
        let workspace = canonicalize(Path(workspaceRoot)).toString()
        let storage = canonicalize(Path(storageRoot)).toString()
        if (storage != workspace + "/.axyndra") {
            throw IllegalArgumentException("workspace plugin storage must remain inside the workspace")
        }
    }
}

public func pluginScopeName(scope: PluginInstallScope): String {
    match (scope) {
        case PluginInstallScope.User => "user"
        case PluginInstallScope.Workspace => "workspace"
    }
}

public func pluginHistoryKey(scope: PluginInstallScope, namespace: String): String {
    pluginScopeName(scope) + "|" + namespace
}

public func pluginScopeEquals(left: PluginInstallScope, right: PluginInstallScope): Bool {
    match (left) {
        case PluginInstallScope.User => match (right) {
            case PluginInstallScope.User => true
            case PluginInstallScope.Workspace => false
        }
        case PluginInstallScope.Workspace => match (right) {
            case PluginInstallScope.User => false
            case PluginInstallScope.Workspace => true
        }
    }
}

func pluginScopeRank(record: RawProductPluginRecord): Int64 {
    if (pluginScopeEquals(record.scope, PluginInstallScope.User) && record.explicitlyDisabled) { return 2 }
    if (pluginScopeEquals(record.scope, PluginInstallScope.Workspace)) { return 1 }
    0
}

private class PluginRegistryWriterOwnedPhase101 {
    var pendingMemory: ?PluginRegistryStateMemory = None<PluginRegistryStateMemory>
}
private class PluginRegistryCaptureOwnedPhase101 {
    var loadingPayment103: ?PluginRegistryMetadataPayment = None<PluginRegistryMetadataPayment>
    var pin: ?PluginRegistryExecutionPin = None<PluginRegistryExecutionPin>
    var pendingMetadata: ?PluginRegistryMetadataGeneration = None<PluginRegistryMetadataGeneration>
    var retained = false
}

public open class PluginRegistry {
    public let settingsRoot: String
    public let workspaceRoot: String
    // All registry entrypoints share this lock, including snapshot readers.
    // Locked helpers call each other without re-entering; no plugin/host
    // callback executes while it is held. File commit and rollback are atomic
    // to readers, and GC cannot race a package import.
    protected let registryLock = Mutex()
    private let records: ArrayList<RawProductPluginRecord>
    // Live preparations cannot survive disable/re-enable or rollback ABA.
    // This is a host-local freshness witness, never a restored execution grant.
    protected let contextSourceRevision = AtomicInt64(1)
    private let history: HashMap<String, ArrayList<RawProductPluginRecord>>
    private let loadErrors: ArrayList<PluginImportError>
    private var writerFence: ?PluginRegistryWriterFence = None
    private let metadataCustody: PluginRegistryMetadataCustody
    private var stateMemory: ?PluginRegistryStateMemory = None
    private var stateGeneration: ?PluginRegistryMetadataGeneration = None
    private var activeInspection: ?PluginRegistryStateMemory = None
    private let ownedBackings = ArrayList<PluginRegistryOwnedBacking>()
    private let ownedLists = ArrayList<OwnedPluginRecordList>()
    private let ownedTextLists = ArrayList<OwnedRegistryTextList>()
    private let ownedErrorLists = ArrayList<OwnedRegistryErrorList>()
    private let ownedComponentSnapshots = ArrayList<RegistryContextComponentSnapshot>()
    private var closed = false
    // This lookup pointer never authorizes a pin. Actual current state also
    // explicitly retains its generation until records/history are replaced.
    private var executionMetadata: ?PluginRegistryMetadataGeneration = None

    public init(settingsRoot: String, workspaceRoot: String) {
        this.settingsRoot = settingsRoot
        this.workspaceRoot = workspaceRoot
        let custody = PluginRegistryMetadataCustody(); this.metadataCustody = custody
        let memory = try { PluginRegistryStateMemory(custody) }
            catch (error: Exception) { custody.close(); throw error }
        let initial = try { pluginLoadRegistryInitialState(settingsRoot, workspaceRoot, memory: Some(memory)) }
            catch (error: Exception) { memory.close(); custody.close(); throw error }
        this.records = initial.records
        this.history = initial.history
        this.loadErrors = initial.loadErrors
        stateMemory = Some(memory)
    }
    protected func effectiveRecords(): OwnedPluginRecordList { requireOpenLocked(); ownRecordList78(effectiveRawRecords()) }
    private func ownOptionalRecord78(value: ?RawProductPluginRecord): ?ProductPluginRecord {
        match (value) { case Some(record) => Some(ownRecord78(record)); case None => None }
    }
    private func ownRecord78(value: RawProductPluginRecord): ProductPluginRecord {
        let payment = metadataCustody.openPayment()
        try {
            // The bounded old getters used while invoicing are prepaid first.
            payment.ensureRetainedPeak(8192)
            payment.ensureRetainedPeak(pluginOwnedRecordInvoice78(value) + 2048)
            let backing = PluginRegistryOwnedBacking(value, payment)
            ownedBackings.add(backing); ProductPluginRecord(backing)
        } catch (error: Exception) { payment.close(); throw error }
    }
    private func ownDescriptor78(value: PluginPackageDescriptor): OwnedPluginPackageDescriptor {
        let payment = metadataCustody.openPayment()
        try {
            payment.ensureRetainedPeak(8192)
            payment.ensureRetainedPeak(pluginOwnedDescriptorInvoice78(value) + 2048)
            let backing = PluginRegistryOwnedBacking(value, payment)
            ownedBackings.add(backing); OwnedPluginPackageDescriptor(backing)
        } catch (error: Exception) { payment.close(); throw error }
    }
    private func ownError78(value: PluginPackageError): PluginRegistryOwnedError {
        let payment = metadataCustody.openPayment()
        try {
            payment.ensureRetainedPeak((value.code.size + value.message.size + value.source.size + value.field.size) * 8 + 8192)
            let backing = PluginRegistryOwnedBacking(value, payment)
            ownedBackings.add(backing); PluginRegistryOwnedError(value.code, Some(backing))
        } catch (error: Exception) { payment.close(); throw error }
    }
    private func ownRecordResult78(value: PluginImportResult<RawProductPluginRecord>): PluginRegistryResult<ProductPluginRecord> {
        try {
            match (value) {
                case PluginImportResult.Ok(record) => PluginRegistryResult.Ok(ownRecord78(record))
                case PluginImportResult.Err(error) => PluginRegistryResult.Err(ownError78(PluginPackageError(error.code, error.message)))
            }
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    private func ownValueResult78<T>(value: PluginImportResult<T>): PluginRegistryResult<T> {
        try {
            match (value) {
                case PluginImportResult.Ok(item) => PluginRegistryResult.Ok(item)
                case PluginImportResult.Err(error) => PluginRegistryResult.Err(ownError78(PluginPackageError(error.code, error.message)))
            }
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }
    private func ownRecordList78(values: Array<RawProductPluginRecord>): OwnedPluginRecordList {
        let payment = metadataCustody.openPayment()
        let owned = ArrayList<ProductPluginRecord>()
        try {
            payment.ensureRetainedPeak(8192 + values.size * 512)
            for (value in values) { owned.add(ownRecord78(value)) }
            let result = OwnedPluginRecordList(owned.toArray().map({ value => Some(value) }), payment)
            ownedLists.add(result); result
        } catch (error: Exception) { for (value in owned) { value.close() }; payment.close(); throw error }
    }

    private func ownTextList78(values: Array<String>): OwnedRegistryTextList {
        let payment = metadataCustody.openPayment()
        try {
            var invoice: Int64 = 8192
            for (value in values) { invoice = pluginRegistryInvoiceAdd78(invoice, value.size * 8 + 512) }
            payment.ensureRetainedPeak(invoice)
            let result = OwnedRegistryTextList(values, payment); ownedTextLists.add(result); result
        } catch (error: Exception) { payment.close(); throw error }
    }
    private func ownErrorList78(values: Array<PluginImportError>): OwnedRegistryErrorList {
        let payment = metadataCustody.openPayment()
        let owned = ArrayList<PluginRegistryOwnedError>()
        try {
            payment.ensureRetainedPeak(8192 + values.size * 512)
            for (value in values) { owned.add(ownError78(PluginPackageError(value.code, value.message))) }
            let result = OwnedRegistryErrorList(owned.toArray(), payment); ownedErrorLists.add(result); result
        } catch (error: Exception) { for (value in owned) { value.close() }; payment.close(); throw error }
    }
    private func ownTextListResult78(value: PluginImportResult<Array<String>>): PluginRegistryResult<OwnedRegistryTextList> {
        try {
            match (value) {
                case PluginImportResult.Ok(items) => PluginRegistryResult.Ok(ownTextList78(items))
                case PluginImportResult.Err(error) => PluginRegistryResult.Err(ownError78(PluginPackageError(error.code, error.message)))
            }
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
    }

    public func ownedError(code: String, message: String, source!: String = "", field!: String = ""): PluginRegistryOwnedError {
        registryLock.lock()
        try {
            requireOpenLocked()
            let payment = metadataCustody.openPayment()
            try {
                payment.ensureRetainedPeak((code.size + message.size + source.size + field.size) * 8 + 8192)
                let value = pluginOwnedErrorCopyFrame78(code, message, source, field)
                let backing = PluginRegistryOwnedBacking(value, payment)
                ownedBackings.add(backing); PluginRegistryOwnedError(code, Some(backing))
            } catch (error: Exception) { payment.close(); throw error }
        } catch (_: LogicalJsonPayloadError) { PluginRegistryOwnedError.capacity() }
        finally { registryLock.unlock() }
    }

    private func requireOpenLocked(): Unit {
        if (closed) { throw PluginRegistryWriteError("plugin.registry_closed", "registry metadata owner is closed") }
    }
    private func publishState(initial: PluginRegistryInitialState,
        memory: ?PluginRegistryStateMemory, generation: ?PluginRegistryMetadataGeneration): Unit {
        let previousMemory = stateMemory; let previousGeneration = stateGeneration
        // Actual container references go first; only then may their payment
        // retire. Existing pins retain their own selected descriptors/fences.
        records.clear(); history.clear(); loadErrors.clear()
        records.add(all: initial.records.toArray())
        for ((key, values) in initial.history) { history[key] = values }
        loadErrors.add(all: initial.loadErrors.toArray())
        stateMemory = memory; stateGeneration = generation
        let _ = contextSourceRevision.fetchAdd(1)
        match (previousMemory) { case Some(value) => value.close(); case None => () }
        match (previousGeneration) {
            case Some(value) => if (!(match (generation) { case Some(next) => refEq(value,next); case None => false })) { value.releaseState() }
            case None => ()
        }
    }
    public func close(): Unit {
        registryLock.lock()
        try {
            if (closed) { return }; closed = true
            let _ = contextSourceRevision.fetchAdd(1)
            records.clear(); history.clear(); loadErrors.clear(); executionMetadata = None
            for (list in ownedLists) { list.close() }; ownedLists.clear()
            for (textList in ownedTextLists) { textList.close() }; ownedTextLists.clear()
            for (errorList in ownedErrorLists) { errorList.close() }; ownedErrorLists.clear()
            for (snapshot in ownedComponentSnapshots) { snapshot.close() }; ownedComponentSnapshots.clear()
            for (backing in ownedBackings) { backing.close() }; ownedBackings.clear()
            match (stateMemory) { case Some(value) => value.close(); stateMemory = None; case None => () }
            match (stateGeneration) { case Some(value) => value.releaseState(); stateGeneration = None; case None => () }
            metadataCustody.close()
        } finally { registryLock.unlock() }
    }

    public func captureContextComponentSnapshot(kinds: Array<String>): RegistryContextComponentSnapshot {
        registryLock.lock()
        try { requireOpenLocked(); captureContextComponentSnapshotLocked(kinds) } finally { registryLock.unlock() }
    }

    // The object record is only a requested identity. The pin is minted from
    // actual installed files under the same ordered OS locks used by writers.
    // A caller cannot restore a pin from a JSON record, digest or old snapshot.
    public func captureExecutionPin(requested: ProductPluginRecord): PluginRegistryResult<PluginRegistryExecutionPin> {
        registryLock.lock()
        try {
            requireOpenLocked()
            requested.withRecord({ value => captureInstalledLocked78(Some(value), value.descriptor.namespace, Some(value.scope)) })
        } finally { registryLock.unlock() }
    }
    public func captureInstalledExecutionPin(namespace: String, scope: PluginInstallScope): PluginRegistryResult<PluginRegistryExecutionPin> {
        registryLock.lock()
        try { requireOpenLocked(); captureInstalledLocked78(None, namespace, Some(scope)) }
        finally { registryLock.unlock() }
    }

    private func captureInstalledLocked78(requested: ?RawProductPluginRecord, namespace: String, requestedScope: ?PluginInstallScope): PluginRegistryResult<PluginRegistryExecutionPin> {
        requireOpenLocked()
            // One REAL original-custody phase, prepaid before fence paths,
            // generation construction, parser callbacks or source copying.
            let loading = try { metadataCustody.openPayment() }
                catch (_: LogicalJsonPayloadError) { return pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
            try { loading.ensureRetainedPeak(4194304) }
            catch (_: LogicalJsonPayloadError) {
                loading.close(); return pluginRegistryStaticFailure78("plugin.registry_metadata_capacity")
            } catch (error: Exception) { loading.close(); throw error }
            let held = try { PluginRegistryWriterFence(settingsRoot, workspaceRoot, shared: true) }
                catch (error: PluginRegistryWriteError) {
                    try { return ownValueResult78(pluginImportError<PluginRegistryExecutionPin>(error.code, error.message)) }
                    finally { loading.close() }
                }
                catch (_: Exception) {
                    try { return ownValueResult78(pluginImportError<PluginRegistryExecutionPin>("plugin.registry_lock_failed", "installed state cannot be fenced")) }
                    finally { loading.close() }
                }
            let phase = PluginRegistryCaptureOwnedPhase101(); phase.loadingPayment103 = Some(loading)
            try { captureInstalledOwnedFrame101(requested, namespace, requestedScope, held, phase) }
            finally {
                // The full partial-load frame has RETURNED. Only the adopted
                // owned result and genuinely published state/pin may survive.
                match (phase.pin) { case Some(value) => value.retireLoadingPhase103(); case None => () }
                if (!phase.retained) { match (phase.pin) { case Some(value) => value.close(); case None => () } }
                phase.pin = None<PluginRegistryExecutionPin>
                let pending = phase.pendingMetadata; phase.pendingMetadata = None<PluginRegistryMetadataGeneration>
                match (pending) { case Some(value) => value.release(0); case None => () }
                phase.loadingPayment103 = None<PluginRegistryMetadataPayment>
                held.close(); loading.close()
            }
    }

    private func captureInstalledOwnedFrame101(requested: ?RawProductPluginRecord, namespace: String,
        requestedScope: ?PluginInstallScope, held: PluginRegistryWriterFence,
        phase: PluginRegistryCaptureOwnedPhase101): PluginRegistryResult<PluginRegistryExecutionPin> {
            try {
                held.validate(); pluginRequireRegistryPublicationComplete(settingsRoot, workspaceRoot)
                let shared = match (executionMetadata) {
                    case Some(value) => if (value.tryRetain(phase.loadingPayment103.getOrThrow())) { value } else {
                        let next = PluginRegistryMetadataGeneration(settingsRoot, workspaceRoot, metadataCustody, phase.loadingPayment103.getOrThrow())
                        executionMetadata = Some(next); next
                    }
                    case None =>
                        let next = PluginRegistryMetadataGeneration(settingsRoot, workspaceRoot, metadataCustody, phase.loadingPayment103.getOrThrow())
                        executionMetadata = Some(next); next
                }
                phase.pendingMetadata = Some(shared)
                let actual = PluginRegistryExecutionPin(settingsRoot, workspaceRoot, shared); phase.pin = Some(actual)
                phase.pendingMetadata = None
                actual.beginLoad(phase.loadingPayment103.getOrThrow())
                let initial = pluginLoadRegistryInitialState(settingsRoot, workspaceRoot, captured: Some(actual))
                if (!initial.loadErrors.isEmpty()) {
                    let error = initial.loadErrors[0]; return ownValueResult78(pluginImportError<PluginRegistryExecutionPin>(error.code, error.message))
                }
                held.validate()
                // Inspect detached paid state. Do not publish it and release
                // its loading owner before arm succeeds.
                for (record in pluginEffectiveRegistryRecords(initial.records) where record.descriptor.namespace == namespace) {
                    if (!record.enabled || record.explicitlyDisabled ||
                        (match (requestedScope) { case Some(scope) => !pluginScopeEquals(record.scope, scope); case None => false })) {
                        return ownValueResult78(pluginImportError<PluginRegistryExecutionPin>("plugin.registry_execution_stale", "requested package differs from the actual enabled effective installation"))
                    }
                    match (requested) {
                        case Some(value) =>
                            if (!pluginScopeEquals(record.scope, value.scope) ||
                                pluginLockLine(record) != pluginLockLine(value) ||
                                pluginPackageDiagnosticValue(record.descriptor).stringify() != pluginPackageDiagnosticValue(value.descriptor).stringify()) {
                                return ownValueResult78(pluginImportError<PluginRegistryExecutionPin>("plugin.registry_execution_stale", "requested package differs from the actual enabled effective installation"))
                            }
                        case None => ()
                    }
                    actual.arm(record); held.validate(); actual.prepareStatePublication103()
                    publishState(initial, None, Some(shared))
                    actual.completeStatePublication()
                    phase.retained = true; return ownValueResult78(PluginImportResult.Ok(actual))
                }
                ownValueResult78(pluginImportError<PluginRegistryExecutionPin>("plugin.registry_execution_stale", "requested package is no longer effectively installed"))
            } catch (error: PluginRegistryWriteError) {
                ownValueResult78(pluginImportError<PluginRegistryExecutionPin>(error.code, error.message))
            } catch (_: Exception) {
                ownValueResult78(pluginImportError<PluginRegistryExecutionPin>("plugin.registry_execution_stale", "installed execution snapshot cannot be captured"))
            }
    }

    private func captureContextComponentSnapshotLocked(kinds: Array<String>): RegistryContextComponentSnapshot {
        let revision = contextSourceRevision.load()
        let selected = ArrayList<RawProductPluginRecord>()
        for (record in effectiveRawRecords() where record.enabled && record.contentLock == record.descriptor.contentDigest) {
            selected.add(record)
        }
        let payment = metadataCustody.openPayment()
        let captured = try {
            payment.ensureRetainedPeak(8192)
            var invoice: Int64 = 65536
            for (record in selected) { invoice = pluginRegistryInvoiceAdd78(invoice, pluginOwnedRecordInvoice78(record) * 8) }
            payment.ensureRetainedPeak(invoice)
            RegistryContextComponentSnapshot(selected.toArray(), kinds, revision, payment)
        } catch (error: Exception) { payment.close(); throw error }
        ownedComponentSnapshots.add(captured)
        if (contextSourceRevision.load() != revision) {
            captured.close(); throw IllegalStateException("installed component sources changed during capture") }
        captured
    }

    public func inspect(root: String): PluginRegistryResult<OwnedPluginPackageDescriptor> {
        registryLock.lock()
        try {
            requireOpenLocked()
            let memory = PluginRegistryStateMemory(metadataCustody)
            activeInspection = Some(memory)
            try {
                match (inspectLocked(root)) {
                    case PluginPackageResult.Ok(value) =>
                        PluginRegistryResult.Ok(ownDescriptor78(value))
                    case PluginPackageResult.Err(error) =>
                        PluginRegistryResult.Err(ownError78(error))
                }
            } catch (_: LogicalJsonPayloadError) {
                pluginRegistryStaticFailure78("plugin.registry_metadata_capacity")
            } finally {
                // The actual parser helper has returned. Its raw outputs are
                // now private owned backings or have been fully discarded.
                activeInspection = None; memory.close()
            }
        } catch (_: LogicalJsonPayloadError) {
            pluginRegistryStaticFailure78("plugin.registry_metadata_capacity")
        } finally { registryLock.unlock() }
    }

    private func inspectionAccounting(): ?PluginPackageMetadataAccounting {
        match (activeInspection) { case Some(value) => return Some(value); case None => () }
        if (writerFence.isSome()) {
            match (stateMemory) { case Some(value) => return Some(value); case None => () }
        }
        // An actual inspection is never allowed to silently take the old
        // unaccounted path after capture changed the Registry's state owner.
        throw IllegalStateException("registry inspection has no actual metadata payment")
    }
    private func withTransientInspection<T>(action: () -> T): T {
        if (activeInspection.isSome() || writerFence.isSome()) { return action() }
        let memory = PluginRegistryStateMemory(metadataCustody); activeInspection = Some(memory)
        try { action() } finally { activeInspection = None; memory.close() }
    }
    private func inspectLocked(root: String): PluginPackageResult<PluginPackageDescriptor> {
        inspectPluginPackage(root, metadataAccounting: inspectionAccounting())
    }

    public func importLocal(root: String): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => importLocalLocked(root) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func importLocalLocked(root: String): PluginImportResult<RawProductPluginRecord> {
        importLocalLocked(root, PluginInstallScope.User)
    }

    public func importLocal(
        root: String,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => importLocalLocked(root, scope) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func importLocalLocked(
        root: String,
        scope: PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        if (pluginScopeEquals(scope, PluginInstallScope.Workspace) && workspaceRoot.trimAscii() == "") {
            return pluginImportError("plugin.workspace_scope_missing", "workspace scope requires an identified workspace root")
        }
        let rootInfo = try {
            FileInfo(Path(root))
        } catch (error: Exception) {
            return pluginImportError("plugin.root_invalid", error.message)
        }
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
            return pluginImportError("plugin.root_invalid", "plugin root must be a real directory")
        }
        let descriptor = match (pluginMaterializeLocalSnapshot(
            root, settingsRoot, workspaceRoot, scope, metadataAccounting: inspectionAccounting()
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let record = RawProductPluginRecord(
            descriptor,
            PluginSourceKind.Local,
            root,
            descriptor.version,
            "",
            pluginDescriptorIntegrity(descriptor),
            descriptor.contentDigest,
            false,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: scope
        )
        persist(record)
    }

    public func cachedSource(
        spec: ProductPluginAcquisitionSpec,
        scope: PluginInstallScope,
        id!: String = ""
    ): ?ProductPluginRecord {
        registryLock.lock()
        try { requireOpenLocked(); withTransientInspection({ => ownOptionalRecord78(cachedSourceLocked(spec, scope, id: id)) }) } finally { registryLock.unlock() }
    }

    private func cachedSourceLocked(
        spec: ProductPluginAcquisitionSpec,
        scope: PluginInstallScope,
        id!: String = ""
    ): ?RawProductPluginRecord {
        for (record in records where pluginScopeEquals(record.scope, scope)) {
            if (id != "" && record.descriptor.id != id && record.descriptor.namespace != id) { continue }
            if (!pluginAcquisitionRecordMatches(record, spec)) { continue }
            if (record.contentLock == "" || record.contentLock != record.descriptor.contentDigest) { continue }
            match (inspectPluginPackage(record.descriptor.root, metadataAccounting: inspectionAccounting())) {
                case PluginPackageResult.Ok(actual) =>
                    if (actual.contentDigest == record.contentLock &&
                        actual.namespace == record.descriptor.namespace && actual.version == record.descriptor.version) {
                        return Some(record)
                    }
                case _ => ()
            }
        }
        None
    }

    public func importAcquiredSource(
        source: ProductAcquiredPluginSource,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => importAcquiredSourceLocked(source, scope) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func importAcquiredSourceLocked(
        source: ProductAcquiredPluginSource,
        scope: PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        if (pluginScopeEquals(scope, PluginInstallScope.Workspace) && workspaceRoot.trimAscii() == "") {
            return pluginImportError("plugin.workspace_scope_missing", "workspace scope requires an identified workspace root")
        }
        let sourceDescriptor = match (inspectPluginPackage(source.packageRoot, metadataAccounting: inspectionAccounting())) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
        }
        let invalidPin = match (source.kind) {
            case PluginSourceKind.Git => !productPluginExactGitRevision(source.revision)
            case PluginSourceKind.Npm => source.version != sourceDescriptor.version ||
                !source.integrity.startsWith("sha512-")
            case PluginSourceKind.Local => true
        }
        if (invalidPin || sourceDescriptor.missingDependencies.size > 0) {
            return pluginImportError("plugin.acquisition_result_invalid", "acquired plugin source failed package or lock verification")
        }
        let descriptor = match (pluginMaterializeSnapshot(
            sourceDescriptor, settingsRoot, workspaceRoot, scope, metadataAccounting: inspectionAccounting()
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        persist(RawProductPluginRecord(
            descriptor,
            source.kind,
            source.locator,
            descriptor.version,
            source.revision,
            source.integrity,
            descriptor.contentDigest,
            false,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: scope
        ))
    }

    public func diagnostics(): OwnedRegistryErrorList {
        registryLock.lock()
        try { requireOpenLocked(); withTransientInspection({ => ownErrorList78(diagnosticsLocked()) }) } finally { registryLock.unlock() }
    }

    private func diagnosticsLocked(): Array<PluginImportError> {
        let errors = ArrayList<PluginImportError>()
        for (error in loadErrors) { errors.add(error) }
        for (record in records) {
            match (checkComponentDependenciesLocked(record, verifyContent: false)) {
                case PluginImportResult.Err(error) => errors.add(error)
                case PluginImportResult.Ok(_) => ()
            }
            if (!exists(Path(record.descriptor.root))) {
                errors.add(PluginImportError("plugin.root_missing",
                    "plugin package root does not exist: " + record.descriptor.root))
            } else {
                match (inspectPluginPackage(record.descriptor.root, metadataAccounting: inspectionAccounting())) {
                    case PluginPackageResult.Ok(actual) =>
                        if (record.contentLock == "" || actual.contentDigest != record.contentLock) {
                            errors.add(PluginImportError("plugin.integrity_mismatch",
                                "installed plugin snapshot differs from its content lock: " + record.descriptor.namespace))
                        }
                        if (actual.namespace != record.descriptor.namespace || actual.version != record.descriptor.version) {
                            errors.add(PluginImportError("plugin.lock_identity_mismatch",
                                "installed plugin metadata differs from its lock: " + record.descriptor.namespace))
                        }
                    case PluginPackageResult.Err(error) =>
                        errors.add(PluginImportError(error.code, error.message))
                }
            }
            for (component in record.descriptor.components) {
                if (component.status == PluginComponentStatus.Blocked) {
                    errors.add(PluginImportError("plugin.component_blocked",
                        record.descriptor.namespace + ":" + component.relativePath))
                }
            }
            match (record.sourceKind) {
                case PluginSourceKind.Local => ()
                case PluginSourceKind.Git =>
                    if (record.revisionLock == "") {
                        errors.add(PluginImportError("plugin.source_unpinned",
                            "Git source is missing its revision: " + record.descriptor.namespace))
                    }
                case PluginSourceKind.Npm =>
                    if (record.versionLock == "" || record.integrityLock == "") {
                        errors.add(PluginImportError("plugin.source_unpinned",
                            "npm source is missing its version or integrity: " + record.descriptor.namespace))
                    }
            }
        }
        for (userRecord in records where pluginScopeEquals(userRecord.scope, PluginInstallScope.User)) {
            for (workspaceRecord in records where pluginScopeEquals(workspaceRecord.scope, PluginInstallScope.Workspace) &&
                workspaceRecord.descriptor.namespace == userRecord.descriptor.namespace) {
                if (userRecord.explicitlyDisabled) {
                    errors.add(PluginImportError("plugin.scope_user_disabled",
                        userRecord.descriptor.namespace + " is explicitly disabled in user scope and suppresses workspace scope"))
                } else {
                    errors.add(PluginImportError("plugin.scope_shadowed",
                        userRecord.descriptor.namespace + " in user scope is shadowed by workspace scope"))
                }
            }
        }
        errors.toArray()
    }

    public func updateLocal(id: String, root: String): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => updateLocalLocked(id, root) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func updateLocalLocked(id: String, root: String): PluginImportResult<RawProductPluginRecord> {
        updateLocalInScope(id, root, None)
    }

    public func updateLocal(
        id: String,
        root: String,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => updateLocalLocked(id, root, scope) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func updateLocalLocked(
        id: String,
        root: String,
        scope: PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        updateLocalInScope(id, root, Some(scope))
    }

    private func updateLocalInScope(
        id: String,
        root: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let rootInfo = try {
            FileInfo(Path(root))
        } catch (error: Exception) {
            return pluginImportError("plugin.root_invalid", error.message)
        }
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
            return pluginImportError("plugin.root_invalid", "plugin root must be a real directory")
        }
        let descriptor = match (pluginMaterializeLocalSnapshot(
            root, settingsRoot, workspaceRoot, current.scope, metadataAccounting: inspectionAccounting()
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        if (descriptor.namespace != current.descriptor.namespace) {
            return pluginImportError("plugin.update_id_mismatch",
                "updated package namespace does not match the imported plugin")
        }
        replaceRecord(current.descriptor.namespace, current.scope, RawProductPluginRecord(
            descriptor,
            PluginSourceKind.Local,
            root,
            descriptor.version,
            "",
            pluginDescriptorIntegrity(descriptor),
            descriptor.contentDigest,
            current.enabled,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: current.scope,
            explicitlyDisabled: current.explicitlyDisabled
        ))
    }

    public func updateAcquiredSource(
        id: String,
        source: ProductAcquiredPluginSource,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => updateAcquiredSourceLocked(id, source, scope) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func updateAcquiredSourceLocked(
        id: String,
        source: ProductAcquiredPluginSource,
        scope: PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        updateAcquiredSourceInScope(id, source, Some(scope))
    }

    private func updateAcquiredSourceInScope(
        id: String,
        source: ProductAcquiredPluginSource,
        scope: ?PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let sourceDescriptor = match (inspectPluginPackage(source.packageRoot, metadataAccounting: inspectionAccounting())) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
        }
        let invalidPin = match (source.kind) {
            case PluginSourceKind.Git => !productPluginExactGitRevision(source.revision)
            case PluginSourceKind.Npm => source.version != sourceDescriptor.version ||
                !source.integrity.startsWith("sha512-")
            case PluginSourceKind.Local => true
        }
        if (invalidPin || sourceDescriptor.missingDependencies.size > 0) {
            return pluginImportError("plugin.acquisition_result_invalid", "acquired plugin source failed package or lock verification")
        }
        if (sourceDescriptor.namespace != current.descriptor.namespace) {
            return pluginImportError("plugin.update_id_mismatch", "updated source package namespace does not match the imported plugin")
        }
        let descriptor = match (pluginMaterializeSnapshot(
            sourceDescriptor, settingsRoot, workspaceRoot, current.scope, metadataAccounting: inspectionAccounting()
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        replaceRecord(current.descriptor.namespace, current.scope, RawProductPluginRecord(
            descriptor,
            source.kind,
            source.locator,
            descriptor.version,
            source.revision,
            source.integrity,
            descriptor.contentDigest,
            current.enabled,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: current.scope,
            explicitlyDisabled: current.explicitlyDisabled
        ))
    }

    public func rollback(id: String): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => rollbackLocked(id) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func rollbackLocked(id: String): PluginImportResult<RawProductPluginRecord> {
        rollbackInScope(id, None)
    }

    public func rollback(
        id: String,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => rollbackLocked(id, scope) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func rollbackLocked(
        id: String,
        scope: PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        rollbackInScope(id, Some(scope))
    }

    private func rollbackInScope(
        id: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let key = pluginHistoryKey(current.scope, current.descriptor.namespace)
        let values = match (history.get(key)) {
            case Some(item) => item
            case None => return pluginImportError("plugin.rollback_unavailable", "no prior plugin generation exists")
        }
        if (values.isEmpty()) {
            return pluginImportError("plugin.rollback_unavailable", "no prior plugin generation exists")
        }
        let previous = values.remove(at: values.size - 1)
        values.add(current)
        history[key] = values
        var index = -1
        for (candidate in 0..records.size) {
            if (pluginScopeEquals(records[candidate].scope, current.scope) &&
                records[candidate].descriptor.namespace == current.descriptor.namespace) {
                index = candidate
                break
            }
        }
        if (index < 0) {
            values.remove(at: values.size - 1)
            values.add(previous)
            return pluginImportError("plugin.not_found", "plugin id is not imported")
        }
        records[index] = previous
        match (writeLock(current.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(previous)
            case PluginImportResult.Err(error) =>
                records[index] = current
                values.remove(at: values.size - 1)
                values.add(previous)
                history[key] = values
                PluginImportResult.Err(error)
        }
    }

    public func uninstall(id: String): PluginRegistryResult<Unit> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<Unit, Unit>({ => uninstallLocked(id) }, { result: PluginImportResult<Unit> => ownValueResult78(result) }) } finally { registryLock.unlock() }
    }

    private func uninstallLocked(id: String): PluginImportResult<Unit> {
        uninstallInScope(id, None)
    }

    public func uninstall(
        id: String,
        scope: PluginInstallScope
    ): PluginRegistryResult<Unit> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<Unit, Unit>({ => uninstallLocked(id, scope) }, { result: PluginImportResult<Unit> => ownValueResult78(result) }) } finally { registryLock.unlock() }
    }

    private func uninstallLocked(
        id: String,
        scope: PluginInstallScope
    ): PluginImportResult<Unit> {
        uninstallInScope(id, Some(scope))
    }

    private func uninstallInScope(
        id: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<Unit> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let key = pluginHistoryKey(current.scope, current.descriptor.namespace)
        var index = -1
        for (candidate in 0..records.size) {
            if (pluginScopeEquals(records[candidate].scope, current.scope) &&
                records[candidate].descriptor.namespace == current.descriptor.namespace) {
                index = candidate
                break
            }
        }
        if (index < 0) { return pluginImportError("plugin.not_found", "plugin id is not imported") }
        records.remove(at: index)
        let values = match (history.get(key)) {
            case Some(item) => item
            case None => ArrayList<RawProductPluginRecord>()
        }
        values.add(current)
        history[key] = values
        match (writeLock(current.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(())
            case PluginImportResult.Err(error) =>
                records.add(current)
                values.remove(at: values.size - 1)
                history[key] = values
                PluginImportResult.Err(error)
        }
    }


    public func garbageCollect(): PluginRegistryResult<OwnedRegistryTextList> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<Array<String>, OwnedRegistryTextList>({ => garbageCollectLocked() }, { result: PluginImportResult<Array<String>> => ownTextListResult78(result) }) } finally { registryLock.unlock() }
    }

    private func garbageCollectLocked(): PluginImportResult<Array<String>> {
        let packageRoots = ArrayList<Path>()
        for (scope in [PluginInstallScope.User, PluginInstallScope.Workspace]) {
            let packageRoot = Path(pluginSnapshotPackageRoot(
                settingsRoot, workspaceRoot, scope
            ))
            if (!exists(packageRoot)) { continue }
            let rootInfo = try {
                FileInfo(packageRoot)
            } catch (error: Exception) {
                return pluginImportError("plugin.gc_failed", error.message)
            }
            if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
                return pluginImportError("plugin.gc_failed", "plugin package cache is not a directory")
            }
            packageRoots.add(packageRoot)
        }
        let retainedRoots = ArrayList<String>()
        for (record in records) {
            if (exists(Path(record.descriptor.root))) {
                try { retainedRoots.add(canonicalize(Path(record.descriptor.root)).toString()) } catch (_: Exception) { () }
            }
        }
        for ((_, generations) in history) {
            for (record in generations) {
                if (exists(Path(record.descriptor.root))) {
                    try { retainedRoots.add(canonicalize(Path(record.descriptor.root)).toString()) } catch (_: Exception) { () }
                }
            }
        }
        let deleted = ArrayList<String>()
        try {
            for (packageRoot in packageRoots) {
                for (entry in Directory.readFrom(packageRoot)) {
                    if (!entry.isDirectory() || entry.isSymbolicLink()) { continue }
                    let canonical = canonicalize(entry.path).toString()
                    if (retainedRoots.contains(canonical)) { continue }
                    remove(entry.path, recursive: true)
                    deleted.add(canonical)
                }
            }
            PluginImportResult.Ok(deleted.toArray())
        } catch (error: Exception) {
            pluginImportError("plugin.gc_failed", error.message)
        }
    }

    public func retainedPackageRoots(): OwnedRegistryTextList {
        registryLock.lock()
        try { requireOpenLocked(); ownTextList78(retainedPackageRootsLocked()) } finally { registryLock.unlock() }
    }

    private func retainedPackageRootsLocked(): Array<String> {
        let roots = ArrayList<String>()
        for (record in records) {
            if (exists(Path(record.descriptor.root))) {
                var known = false
                for (root in roots) { if (root == record.descriptor.root) { known = true } }
                if (!known) { roots.add(record.descriptor.root) }
            }
        }
        for ((_, generations) in history) {
            for (record in generations) {
                if (!exists(Path(record.descriptor.root))) { continue }
                var known = false
                for (root in roots) { if (root == record.descriptor.root) { known = true } }
                if (!known) { roots.add(record.descriptor.root) }
            }
        }
        roots.toArray()
    }

    private func replaceRecord(
        namespace: String,
        scope: PluginInstallScope,
        replacement: RawProductPluginRecord
    ): PluginImportResult<RawProductPluginRecord> {
        for (index in 0..records.size) {
            if (!pluginScopeEquals(records[index].scope, scope) || records[index].descriptor.namespace != namespace) { continue }
            let current = records[index]
            let key = pluginHistoryKey(scope, namespace)
            let values = match (history.get(key)) {
                case Some(item) => item
                case None => ArrayList<RawProductPluginRecord>()
            }
            values.add(current)
            history[key] = values
            records[index] = replacement
            match (writeLock(scope)) {
                case PluginImportResult.Ok(_) => return PluginImportResult.Ok(replacement)
                case PluginImportResult.Err(error) =>
                    records[index] = current
                    values.remove(at: values.size - 1)
                    history[key] = values
                    return PluginImportResult.Err(error)
            }
        }
        pluginImportError("plugin.not_found", "plugin id is not imported")
    }
    // Data projection only: no discovery, filesystem reads, grants or mounted
    // executor identities. Scope selection uses this registry's existing rule.











    private func resolveNamespace(identifier: String): PluginImportResult<String> {
        for (record in records where record.descriptor.namespace == identifier) {
            return PluginImportResult.Ok(record.descriptor.namespace)
        }
        var foundNamespace: ?String = None
        for (record in records where record.descriptor.id == identifier) {
            match (foundNamespace) {
                case Some(value) =>
                    if (value != record.descriptor.namespace) {
                        return pluginImportError("plugin.ambiguous_id", "plugin id matches multiple ecosystems; use its namespaced identity")
                    }
                case None => foundNamespace = Some(record.descriptor.namespace)
            }
        }
        match (foundNamespace) {
            case Some(value) => PluginImportResult.Ok(value)
            case None => pluginImportError("plugin.not_found", "plugin id is not imported")
        }
    }

    private func effectiveRecord(namespace: String): ?RawProductPluginRecord {
        var selected: ?RawProductPluginRecord = None
        for (record in records where record.descriptor.namespace == namespace) {
            match (selected) {
                case Some(current) =>
                    if (pluginScopeRank(record) > pluginScopeRank(current)) { selected = Some(record) }
                case None => selected = Some(record)
            }
        }
        selected
    }

    private func effectiveRawRecords(): Array<RawProductPluginRecord> {
        requireOpenLocked()
        pluginEffectiveRegistryRecords(records)
    }

    private func resolveRecord(
        id: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        let namespace = match (resolveNamespace(id)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        match (scope) {
            case Some(requested) =>
                for (record in records where pluginScopeEquals(record.scope, requested) && record.descriptor.namespace == namespace) {
                    return PluginImportResult.Ok(record)
                }
                pluginImportError("plugin.not_found_in_scope", "plugin is not installed in the requested scope")
            case None =>
                match (effectiveRecord(namespace)) {
                    case Some(record) => PluginImportResult.Ok(record)
                    case None => pluginImportError("plugin.not_found", "plugin id is not imported")
                }
        }
    }

    public func get(id: String): ?ProductPluginRecord {
        registryLock.lock()
        try { requireOpenLocked(); ownOptionalRecord78(getLocked(id)) } finally { registryLock.unlock() }
    }

    private func getLocked(id: String): ?RawProductPluginRecord {
        let namespace = match (resolveNamespace(id)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(_) => return None
        }
        effectiveRecord(namespace)
    }

    public func get(id: String, scope: PluginInstallScope): ?ProductPluginRecord {
        registryLock.lock()
        try { requireOpenLocked(); ownOptionalRecord78(getLocked(id, scope)) } finally { registryLock.unlock() }
    }

    private func getLocked(id: String, scope: PluginInstallScope): ?RawProductPluginRecord {
        let namespace = match (resolveNamespace(id)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(_) => return None
        }
        for (record in records where pluginScopeEquals(record.scope, scope) && record.descriptor.namespace == namespace) {
            return Some(record)
        }
        None
    }

    public func list(): OwnedPluginRecordList {
        registryLock.lock()
        try { requireOpenLocked(); ownRecordList78(listLocked()) } finally { registryLock.unlock() }
    }

    private func listLocked(): Array<RawProductPluginRecord> { records.toArray() }

    public func checkComponentDependencies(record: ProductPluginRecord,
        verifyContent!: Bool = true): PluginRegistryResult<Unit> {
        registryLock.lock()
        try { requireOpenLocked(); record.withRecord({ value => withTransientInspection({ => ownValueResult78(checkComponentDependenciesLocked(value, verifyContent: verifyContent)) }) }) } finally { registryLock.unlock() }
    }

    private func checkComponentDependenciesLocked(record: RawProductPluginRecord,
        verifyContent!: Bool = true): PluginImportResult<Unit> {
        let nodes = effectiveRawRecords().map { value => PluginDependencyNode(value.descriptor, value.enabled) }
        let ordered = match (resolvePluginDependencies(record.descriptor, nodes)) {
            case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
            case PluginPackageResult.Ok(value) => value
        }
        if (verifyContent) {
            for (descriptor in ordered) {
                let current = if (descriptor.namespace == record.descriptor.namespace) { record } else { match (getLocked(descriptor.namespace)) {
                    case Some(value) => value
                    case None => return pluginImportError("plugin.component_dependency_missing", descriptor.namespace)
                } }
                let actual = match (inspectPluginPackage(descriptor.root, metadataAccounting: inspectionAccounting())) {
                    case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
                    case PluginPackageResult.Ok(value) => value
                }
                if (current.contentLock == "" || actual.contentDigest != current.contentLock ||
                    actual.namespace != descriptor.namespace || actual.version != descriptor.version) {
                    return pluginImportError("plugin.component_dependency_changed", "immutable dependency package changed: " + descriptor.namespace)
                }
            }
        }
        PluginImportResult.Ok(())
    }

    // Topological startup order is derived from the existing effective records.
    // Broken roots remain in this list so startup can quarantine and diagnose
    // them without blocking unrelated packages or management commands.
    public func startupEffectiveRecords(): OwnedPluginRecordList {
        registryLock.lock()
        try { requireOpenLocked(); ownRecordList78(startupEffectiveRecordsLocked()) } finally { registryLock.unlock() }
    }

    private func startupEffectiveRecordsLocked(): Array<RawProductPluginRecord> {
        let records = effectiveRawRecords()
        let nodes = records.map { value => PluginDependencyNode(value.descriptor, value.enabled) }
        let ordered = ArrayList<RawProductPluginRecord>(); let seen = HashSet<String>()
        for (record in records where record.enabled) {
            match (resolvePluginDependencies(record.descriptor, nodes)) {
                case PluginPackageResult.Err(_) => ()
                case PluginPackageResult.Ok(values) =>
                    for (descriptor in values where !seen.contains(descriptor.namespace)) {
                        for (candidate in records where candidate.enabled && candidate.descriptor.namespace == descriptor.namespace) {
                            ordered.add(candidate); seen.add(descriptor.namespace)
                        }
                    }
            }
        }
        for (record in records where record.enabled && !seen.contains(record.descriptor.namespace)) { ordered.add(record) }
        ordered.toArray()
    }

    public func enabledEffectiveRecords(): OwnedPluginRecordList {
        registryLock.lock()
        try { requireOpenLocked(); ownRecordList78(enabledEffectiveRecordsLocked()) } finally { registryLock.unlock() }
    }

    private func enabledEffectiveRecordsLocked(): Array<RawProductPluginRecord> {
        let enabled = ArrayList<RawProductPluginRecord>()
        for (record in effectiveRawRecords() where record.enabled) {
            enabled.add(record)
        }
        enabled.toArray()
    }









    public func setEnabled(id: String, enabled: Bool): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => setEnabledLocked(id, enabled) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func setEnabledLocked(id: String, enabled: Bool): PluginImportResult<RawProductPluginRecord> {
        setEnabledInScope(id, enabled, None)
    }

    public func setEnabled(
        id: String,
        enabled: Bool,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked(); withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ => setEnabledLocked(id, enabled, scope) }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) }) } finally { registryLock.unlock() }
    }

    private func setEnabledLocked(
        id: String,
        enabled: Bool,
        scope: PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        setEnabledInScope(id, enabled, Some(scope))
    }

    private func setEnabledInScope(
        id: String,
        enabled: Bool,
        scope: ?PluginInstallScope
    ): PluginImportResult<RawProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        if (enabled) {
            match (checkComponentDependenciesLocked(current)) {
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
                case PluginImportResult.Ok(_) => ()
            }
            let actual = match (inspectPluginPackage(current.descriptor.root, metadataAccounting: inspectionAccounting())) {
                case PluginPackageResult.Ok(value) => value.contentDigest
                case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
            }
            if (current.contentLock == "" || actual != current.contentLock) {
                return pluginImportError("plugin.integrity_mismatch", "plugin snapshot content differs from its lock")
            }
        }
        let explicitlyDisabled = pluginScopeEquals(current.scope, PluginInstallScope.User) && !enabled
        if (current.enabled == enabled && current.explicitlyDisabled == explicitlyDisabled) {
            return PluginImportResult.Ok(current)
        }
        let replacement = RawProductPluginRecord(
            current.descriptor, current.sourceKind, current.locator, current.versionLock,
            current.revisionLock, current.integrityLock, current.contentLock, enabled,
            current.importedAt, scope: current.scope, explicitlyDisabled: explicitlyDisabled
        )
        var index = -1
        for (candidate in 0..records.size) {
            if (pluginScopeEquals(records[candidate].scope, current.scope) &&
                records[candidate].descriptor.namespace == current.descriptor.namespace) {
                index = candidate
                break
            }
        }
        if (index < 0) { return pluginImportError("plugin.not_found", "plugin id is not imported") }
        records[index] = replacement
        match (writeLock(current.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(replacement)
            case PluginImportResult.Err(error) =>
                records[index] = current
                PluginImportResult.Err(error)
        }
    }

    public func restoreRecord(record: ProductPluginRecord): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try { requireOpenLocked();
            record.withRecord({ raw =>
            let expected = restoreWitness(raw)
            withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ =>
                if (restoreWitness(raw) != expected) {
                    pluginImportError<RawProductPluginRecord>("plugin.registry_stale", "a newer registry mutation prevents this stale restoration")
                } else { restoreRecordLocked(raw) }
            }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) })
            })
        } finally { registryLock.unlock() }
    }

    public func restoreRecord(input: PluginRegistryCallerRecordInput): PluginRegistryResult<ProductPluginRecord> {
        registryLock.lock()
        try {
            requireOpenLocked()
            input.withInput({ raw =>
                let expected = restoreWitness(raw)
                withWriterFence<RawProductPluginRecord, ProductPluginRecord>({ =>
                    if (restoreWitness(raw) != expected) {
                        pluginImportError<RawProductPluginRecord>("plugin.registry_stale", "a newer registry mutation prevents this stale restoration")
                    } else {
                        // Original caller objects stay caller-owned. This paid
                        // clone creates no pointer back to their String/Array.
                        stateMemory.getOrThrow().beforeCopiedRecord78(raw)
                        restoreRecordLocked(pluginOwnedDeepCopyRecord78(raw))
                    }
                }, { result: PluginImportResult<RawProductPluginRecord> => ownRecordResult78(result) })
            })
        } catch (_: LogicalJsonPayloadError) {
            pluginRegistryStaticFailure78("plugin.registry_metadata_capacity")
        } finally { registryLock.unlock() }
    }

    private func restoreWitness(record: RawProductPluginRecord): String {
        for (current in records where pluginScopeEquals(current.scope, record.scope) &&
            current.descriptor.namespace == record.descriptor.namespace) { return pluginLockLine(current) }
        ""
    }

    private func restoreRecordLocked(record: RawProductPluginRecord): PluginImportResult<RawProductPluginRecord> {
        // This API retains the supplied DTO. Its caller owns any earlier
        // lifetime; Registry pays before its own actual adoption begins.
        stateMemory.getOrThrow().beforeRetainedRecord(record)
        for (current in records) {
            if (!pluginScopeEquals(current.scope, record.scope) ||
                current.descriptor.namespace != record.descriptor.namespace) { continue }
            // Restoring an installed generation must retain the displaced one.
            // Reuse the same transactional history update and rollback path as
            // updateLocal; otherwise GC can remove a still-referenced package.
            return replaceRecord(record.descriptor.namespace, record.scope, record)
        }
        let historyContainsRecord = match (history.get(pluginHistoryKey(record.scope, record.descriptor.namespace))) {
            case Some(values) =>
                var found = false
                for (retained in values where retained.descriptor.root == record.descriptor.root &&
                    retained.contentLock == record.contentLock) { found = true }
                found
            case None => false
        }
        if (!historyContainsRecord) {
            return pluginImportError("plugin.not_found_in_scope", "plugin generation is not retained in the requested scope")
        }
        records.add(record)
        match (writeLock(record.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(record)
            case PluginImportResult.Err(error) =>
                records.remove(at: records.size - 1)
                PluginImportResult.Err(error)
        }
    }

    public func doctor(): OwnedRegistryErrorList {
        registryLock.lock()
        try { requireOpenLocked(); withTransientInspection({ => ownErrorList78(doctorLocked()) }) } finally { registryLock.unlock() }
    }

    private func doctorLocked(): Array<PluginImportError> { diagnosticsLocked() }

    private func persist(record: RawProductPluginRecord): PluginImportResult<RawProductPluginRecord> {
        for (existing in records) {
            if (pluginScopeEquals(existing.scope, record.scope) &&
                existing.descriptor.namespace == record.descriptor.namespace) {
                return pluginImportError("plugin.duplicate_namespace", "plugin namespace is already imported in this scope")
            }
        }
        records.add(record)
        match (writeLock(record.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(record)
            case PluginImportResult.Err(error) =>
                records.remove(at: records.size - 1)
                PluginImportResult.Err(error)
        }
    }

    // registryLock is already held. The OS fence starts before reload or any
    // cache/materialization/GC work, and spans all original rollback paths.
    private func withWriterFence<T, U>(action: () -> PluginImportResult<T>,
        adopt: (PluginImportResult<T>) -> PluginRegistryResult<U>): PluginRegistryResult<U> {
        let fence = try { PluginRegistryWriterFence(settingsRoot, workspaceRoot) }
            catch (error: PluginRegistryWriteError) { return adopt(pluginImportError<T>(error.code, error.message)) }
            catch (error: Exception) { return adopt(pluginImportError<T>("plugin.registry_lock_failed", error.message)) }
        let phase = PluginRegistryWriterOwnedPhase101()
        try { withWriterFenceOwnedFrame101(fence, phase, action, adopt) }
        finally {
            // All partial raw state and action/error frames have RETURNED;
            // the returned owned result already has its independent payment.
            writerFence = None
            let pending = phase.pendingMemory; phase.pendingMemory = None<PluginRegistryStateMemory>
            match (pending) { case Some(value) => value.close(); case None => () }
            fence.close()
        }
    }

    private func withWriterFenceOwnedFrame101<T, U>(fence: PluginRegistryWriterFence,
        phase: PluginRegistryWriterOwnedPhase101, action: () -> PluginImportResult<T>,
        adopt: (PluginImportResult<T>) -> PluginRegistryResult<U>): PluginRegistryResult<U> {

        try {
            fence.validate()
            let _ = contextSourceRevision.fetchAdd(1)
            pluginRequireRegistryPublicationComplete(settingsRoot, workspaceRoot)
            let memory = PluginRegistryStateMemory(metadataCustody); phase.pendingMemory = Some(memory)
            let initial = pluginLoadRegistryInitialState(settingsRoot, workspaceRoot, memory: Some(memory))
            // Diagnostics from doctor/runtime dependency checks do not enter
            // this list. Only inability to reconstruct exact stored state does.
            if (!initial.loadErrors.isEmpty()) {
                let first = initial.loadErrors[0]
                let code = if (first.code == "plugin.integrity_mismatch") {
                    "plugin.component_dependency_changed" } else { first.code }
                return adopt(pluginImportError<T>(code, first.message))
            }
            fence.validate()
            publishState(initial, Some(memory), None); phase.pendingMemory = None
            writerFence = Some(fence)
            let result = action()
            fence.validate()
            pluginRequireRegistryPublicationComplete(settingsRoot, workspaceRoot)
            adopt(result)
        } catch (error: PluginRegistryWriteError) {
            if (error.code == "plugin.registry_recovery_required") {
                var index = records.size - 1
                while (index >= 0) {
                    if (pluginScopeEquals(records[index].scope, PluginInstallScope.Workspace)) { records.remove(at: index) }
                    index--
                }
                loadErrors.add(PluginImportError(error.code, error.message))
            }
            adopt(pluginImportError<T>(error.code, error.message))
        } catch (error: Exception) {
            adopt(pluginImportError<T>("plugin.registry_lock_failed", error.message))
        }
    }

    private func writeLock(scope: PluginInstallScope): PluginImportResult<Unit> {
        // Even a rolled-back attempted mutation invalidates existing live reads.
        let _ = contextSourceRevision.fetchAdd(1)
        let directory = pluginScopeRoot(settingsRoot, workspaceRoot, scope) + "/plugins"
        let lockPath = directory + "/lock.jsonl"
        let temporary = lockPath + ".tmp-" + DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
        try {
            let fence = writerFence.getOrThrow()
            fence.validate()
            if (pluginScopeEquals(scope, PluginInstallScope.Workspace)) {
                pluginRequireWorkspaceStorage(workspaceRoot, pluginScopeRoot(settingsRoot, workspaceRoot, scope), directory)
            }
            pluginCreateDirectoryTree(directory)
            pluginRequireRegularLockTarget(directory)
            var body = ""
            for (record in records where pluginScopeEquals(record.scope, scope)) {
                if (body != "") { body += "\n" }
                body += pluginLockLine(record)
            }
            for ((_, values) in history) {
                for (record in values where pluginScopeEquals(record.scope, scope)) {
                    if (body != "") { body += "\n" }
                    body += pluginLockLine(record, historyFor: record.descriptor.namespace)
                }
            }
            if (pluginScopeEquals(scope, PluginInstallScope.Workspace)) {
                pluginWriteWorkspacePluginState(settingsRoot, workspaceRoot, records, lockPath, body, fence)
            } else {
                File.writeTo(temporary, body.toArray())
                pluginRequireRegularLockTarget(directory)
                fence.validate()
                rename(temporary, to: lockPath, overwrite: true)
            }
            fence.validate()
            PluginImportResult.Ok(())
        } catch (error: Exception) {
            if (exists(Path(temporary))) {
                try { remove(Path(temporary)) } catch (_: Exception) { () }
            }
            pluginImportError("plugin.lock_write_failed", error.message)
        }
    }

}

// The original exact namespace/scope precedence, also usable on a detached
// paid reload without publishing it before pin arming succeeds.
func pluginEffectiveRegistryRecords(records: ArrayList<RawProductPluginRecord>): Array<RawProductPluginRecord> {
    let selected = ArrayList<RawProductPluginRecord>()
    for (record in records) {
        var index = -1
        for (candidate in 0..selected.size) {
            if (selected[candidate].descriptor.namespace == record.descriptor.namespace) {
                index = candidate
                break
            }
        }
        if (index < 0) {
            selected.add(record)
        } else if (pluginScopeRank(record) > pluginScopeRank(selected[index])) {
            selected[index] = record
        }
    }
    selected.toArray()
}

public func pluginCreateDirectoryTree(path: String): Unit {
    let pieces = path.split("/")
    var current = if (path.startsWith("/")) { "/" } else { "" }
    for (piece in pieces) {
        if (piece == "") { continue }
        current = if (current == "/") { "/" + piece } else if (current == "") { piece } else { current + "/" + piece }
        if (!exists(Path(current))) { Directory.create(current) }
    }
}

public func pluginImportError<T>(code: String, message: String): PluginImportResult<T> {
    PluginImportResult.Err(PluginImportError(code, message))
}

func pluginDescriptorIntegrity(descriptor: PluginPackageDescriptor): String {
    descriptor.contentDigest
}

func pluginMaterializeLocalSnapshot(
    sourceRoot: String,
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): PluginImportResult<PluginPackageDescriptor> {
    pluginMaterializeSnapshotRoot(
        sourceRoot, None, settingsRoot, workspaceRoot, scope, metadataAccounting: metadataAccounting
    )
}

func pluginMaterializeSnapshot(
    sourceDescriptor: PluginPackageDescriptor,
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): PluginImportResult<PluginPackageDescriptor> {
    if (sourceDescriptor.contentDigest == "") {
        return pluginImportError("plugin.snapshot_digest_missing", "plugin package has no content digest")
    }
    pluginMaterializeSnapshotRoot(
        sourceDescriptor.root,
        Some(sourceDescriptor.contentDigest),
        settingsRoot,
        workspaceRoot,
        scope,
        metadataAccounting: metadataAccounting
    )
}

func pluginMaterializeSnapshotRoot(
    sourceRoot: String,
    expectedDigest: ?String,
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope,
    metadataAccounting!: ?PluginPackageMetadataAccounting = None
): PluginImportResult<PluginPackageDescriptor> {
    let packagesPath = pluginSnapshotPackageRoot(settingsRoot, workspaceRoot, scope)
    try {
        pluginCreateDirectoryTree(packagesPath)
        let packageInfo = FileInfo(Path(packagesPath))
        if (!packageInfo.isDirectory() || packageInfo.isSymbolicLink()) {
            return pluginImportError("plugin.snapshot_root_invalid", "managed plugin package root must be a non-symlink directory")
        }
        let packagesRoot = canonicalize(Path(packagesPath)).toString()
        var staging = ""
        try {
            staging = Directory.createTemp(packagesRoot).toString()
            copyVerifiedPluginSnapshot(sourceRoot, staging)
            let stagedDescriptor = match (inspectPluginPackage(staging, metadataAccounting: metadataAccounting)) {
                case PluginPackageResult.Ok(value) => value
                case PluginPackageResult.Err(error) =>
                    try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                    return pluginImportError(error.code, error.message)
            }
            match (expectedDigest) {
                case Some(value) =>
                    if (stagedDescriptor.contentDigest != value) {
                        try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                        return pluginImportError(
                            "plugin.snapshot_changed",
                            "plugin package changed while its static snapshot was verified"
                        )
                    }
                case None => ()
            }
            let digest = stagedDescriptor.contentDigest
            let target = packagesRoot + "/" + modelPolicySha256Text(digest)
            if (exists(Path(target))) {
                let info = FileInfo(Path(target))
                if (!info.isDirectory() || info.isSymbolicLink()) {
                    try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                    return pluginImportError("plugin.snapshot_invalid", "content-addressed plugin snapshot is not a directory")
                }
                let existing = match (inspectPluginPackage(target, metadataAccounting: metadataAccounting)) {
                    case PluginPackageResult.Ok(value) => value
                    case PluginPackageResult.Err(error) =>
                        try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                        return pluginImportError(error.code, error.message)
                }
                try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                if (existing.contentDigest == digest) {
                    return PluginImportResult.Ok(existing)
                }
                return pluginImportError("plugin.snapshot_collision", "managed plugin snapshot digest does not match its address")
            }
            rename(staging, to: target, overwrite: false)
            match (inspectPluginPackage(target, metadataAccounting: metadataAccounting)) {
                case PluginPackageResult.Ok(value) =>
                    if (value.contentDigest == digest) {
                        PluginImportResult.Ok(value)
                    } else {
                        pluginImportError("plugin.snapshot_verification_failed", "managed plugin snapshot failed post-install verification")
                    }
                case PluginPackageResult.Err(error) => pluginImportError(error.code, error.message)
            }
        } catch (error: Exception) {
            if (staging != "" && exists(Path(staging))) {
                try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
            }
            pluginImportError("plugin.snapshot_failed", error.message)
        }
    } catch (error: Exception) {
        pluginImportError("plugin.snapshot_failed", error.message)
    }
}

func pluginLockLine(record: RawProductPluginRecord, historyFor!: String = ""): String {
    let fields = ArrayList<ValueField>()
    fields.add(all: [
        ValueField("id", textValue(record.descriptor.id)),
        ValueField("version", textValue(record.descriptor.version)),
        ValueField("namespace", textValue(record.descriptor.namespace)),
        ValueField("source_kind", textValue(pluginSourceKindName(record.sourceKind))),
        ValueField("locator", textValue(record.locator)),
        ValueField("root", textValue(record.descriptor.root)),
        ValueField("version_lock", textValue(record.versionLock)),
        ValueField("revision", textValue(record.revisionLock)),
        ValueField("integrity", textValue(record.integrityLock)),
        ValueField("content_digest", textValue(record.contentLock)),
        ValueField("enabled", boolValue(record.enabled)),
        ValueField("explicitly_disabled", boolValue(record.explicitlyDisabled))
    ])
    if (historyFor != "") {
        fields.add(ValueField("history_for", textValue(historyFor)))
    }
    stringifyUnifiedJson(objectValue(fields.toArray()))
}

public func pluginSourceKindName(kind: PluginSourceKind): String {
    match (kind) { case PluginSourceKind.Local => "local"; case PluginSourceKind.Git => "git"; case PluginSourceKind.Npm => "npm" }
}

public func pluginWorkspaceGrantPath(settingsRoot: String, workspaceRoot: String): String {
    let workspace = canonicalize(Path(workspaceRoot)).toString()
    settingsRoot + "/plugins/workspace-grants/" + modelPolicySha256Text(workspace) + ".jsonl"
}

func pluginWorkspaceGrantMatches(
    settingsRoot: String,
    workspaceRoot: String,
    namespace: String,
    contentDigest: String
): Bool {
    try {
        let path = pluginWorkspaceGrantPath(settingsRoot, workspaceRoot)
        if (!exists(Path(path))) { return false }
        for (line in String.fromUtf8(File.readFrom(Path(path))).split("\n")) {
            if (line.trimAscii() == "") { continue }
            let value = parseUnifiedJson(line, maxBytes: 1048576, maxDepth: 8)
            if (pluginLockText(value, "namespace") == namespace &&
                pluginLockText(value, "content_digest") == contentDigest) {
                return true
            }
        }
        false
    } catch (_: Exception) {
        false
    }
}

func pluginWorkspaceGrantBodyMatches(source: ?String, namespace: String, contentDigest: String,
    accounting: PluginPackageMetadataAccounting): Bool {
    match (source) { case None => return false; case Some(_) => () }
    try {
        for (line in source.getOrThrow().split("\n")) {
            if (line.trimAscii() == "") { continue }
            let holder = pluginRegistryOpenRowHolder78(accounting, line)
            let matched = pluginWorkspaceGrantMatchFrame78(holder, line, namespace, contentDigest)
            pluginRegistryRetireRow78(holder)
            if (matched) { return true }
        }; false
    } catch (_: Exception) { false }
}
private func pluginWorkspaceGrantMatchFrame78(holder: PluginRegistryPrivateRowHolder78,
    line: String, namespace: String, contentDigest: String): Bool {
    try {
        holder.node = Some(parseUnifiedJson(line, maxBytes: 1048576, maxDepth: 8))
        let value = holder.node.getOrThrow()
        pluginLockText(value, "namespace") == namespace && pluginLockText(value, "content_digest") == contentDigest
    } catch (_: Exception) { false }
}

func workspacePluginGrantBody(records: ArrayList<RawProductPluginRecord>): String {
    var body = ""
    for (record in records where
        pluginScopeEquals(record.scope, PluginInstallScope.Workspace) && record.enabled) {
        if (body != "") { body += "\n" }
        body += stringifyUnifiedJson(objectValue([
            ValueField("namespace", textValue(record.descriptor.namespace)),
            ValueField("content_digest", textValue(record.contentLock))
        ]))
    }
    body
}

func writeWorkspacePluginState(
    settingsRoot: String,
    workspaceRoot: String,
    records: ArrayList<RawProductPluginRecord>,
    lockPath: String,
    lockBody: String
): Unit {
    // This old raw-state helper cannot prove that supplied records are current.
    // Use the normal registry mutations, which reload while holding the fence.
    throw PluginRegistryWriteError("plugin.registry_unscoped_publication",
        "workspace registry publication requires an actual registry mutation")
}

func pluginWriteWorkspacePluginState(
    settingsRoot: String, workspaceRoot: String,
    records: ArrayList<RawProductPluginRecord>, lockPath: String, lockBody: String,
    fence: PluginRegistryWriterFence
): Unit {
    fence.validate()
    let grantPath = pluginWorkspaceGrantPath(settingsRoot, workspaceRoot)
    let separator = grantPath.lastIndexOf("/").getOrThrow()
    pluginCreateDirectoryTree(grantPath[..separator])
    if (exists(Path(grantPath)) && FileInfo(Path(grantPath)).isDirectory()) {
        throw IllegalStateException("workspace plugin grant path must be a file")
    }
    let suffix = ".txn-" + DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
    let lockTemporary = lockPath + suffix
    let grantTemporary = grantPath + suffix
    let lockBackup = lockPath + suffix + ".backup"
    let grantBackup = grantPath + suffix + ".backup"
    var lockBackedUp = false
    var grantBackedUp = false
    var lockInstalled = false
    // Persist before the first destructive rename; retained after any uncertain
    // rollback. A crash never lets another writer guess this pair's outcome.
    fence.publication(true)
    try {
        fence.validate()
        File.writeTo(lockTemporary, lockBody.toArray())
        File.writeTo(grantTemporary, workspacePluginGrantBody(records).toArray())
        if (exists(Path(lockPath))) {
            rename(lockPath, to: lockBackup, overwrite: true)
            lockBackedUp = true
        }
        if (exists(Path(grantPath))) {
            rename(grantPath, to: grantBackup, overwrite: true)
            grantBackedUp = true
        }
        rename(lockTemporary, to: lockPath, overwrite: true)
        lockInstalled = true
        rename(grantTemporary, to: grantPath, overwrite: true)
    } catch (error: Exception) {
        var restoreFailure = ""
        try {
            if (lockInstalled && exists(Path(lockPath))) { remove(Path(lockPath)) }
            if (lockBackedUp) { rename(lockBackup, to: lockPath, overwrite: true) }
        } catch (restoreError: Exception) {
            restoreFailure = restoreError.message
        }
        try {
            if (grantBackedUp) { rename(grantBackup, to: grantPath, overwrite: true) }
        } catch (restoreError: Exception) {
            if (restoreFailure == "") { restoreFailure = restoreError.message }
        }
        for (path in [lockTemporary, grantTemporary]) {
            if (exists(Path(path))) { try { remove(Path(path)) } catch (_: Exception) { () } }
        }
        if (restoreFailure == "") {
            fence.validate()
            fence.publication(false)
        }
        if (restoreFailure != "") {
            throw IllegalStateException(error.message + "; workspace plugin state rollback failed: " + restoreFailure)
        }
        throw error
    }
    for (path in [lockBackup, grantBackup]) {
        if (exists(Path(path))) { try { remove(Path(path)) } catch (_: Exception) { () } }
    }
    fence.validate()
    fence.publication(false)
}
public func pluginLockText(value: JsonNode, field: String): String {
    match (value.field(field)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }
        case None => ""
    }
}

public func pluginSourceKind(value: ?JsonNode): PluginSourceKind {
    match (value) {
        case Some(item) =>
            if (item.unifiedKind == UnifiedJsonKind.Text) {
                match (item.text) {
                    case "git" => PluginSourceKind.Git
                    case "npm" => PluginSourceKind.Npm
                    case _ => PluginSourceKind.Local
                }
            } else { PluginSourceKind.Local }
        case None => PluginSourceKind.Local
    }
}


// Refuse unexpected destination kinds before using the standard-library
// overwrite operation. Directory entries also expose dangling symlinks;
// exists(false) alone would incorrectly treat those as a missing lock.
// This does not claim cross-process locking or race-free path traversal.
func pluginRequireRegularLockTarget(directory: String): Unit {
    for (entry in Directory.readFrom(directory) where entry.name == "lock.jsonl") {
        if (!entry.isRegular() || entry.isSymbolicLink()) {
            throw IllegalStateException("plugin lock destination must be a regular file")
        }
    }
}
