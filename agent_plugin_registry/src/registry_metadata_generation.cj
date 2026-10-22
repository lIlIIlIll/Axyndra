package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.sync.*

// An allocation owner only. No cached record, digest, or generation can arm a
// pin: every capture still reloads the full installed state and inspects the
// actual package. Sharing is limited to these immutable file snapshots.
class PluginRegistryMetadataGeneration {
    private let lock = Mutex()
    private let custody: PluginRegistryMetadataCustody
    private var settingsRoot: String
    private var workspaceRoot: String
    private let snapshots = ArrayList<PluginRegistryMetadataSnapshot>()
    private var allocation: ?PluginRegistryMetadataPayment = None
    private var statePayment: ?PluginRegistryMetadataPayment = None
    private var pendingStatePayment: ?PluginRegistryMetadataPayment = None
    private var loadingPayment: ?PluginRegistryMetadataPayment = None
    private var pendingStateRetention = false
    private var references: Int64 = 1
    private var closed = false
    private var revoked = false
    private var rawCost: Int64 = 0
    private var pinCost: Int64 = 0
    private var latestStateCost: Int64 = 0
    private var pendingStateCost: Int64 = 0
    private var loadingCost: Int64 = 0
    private var fenceCost: Int64 = 0
    private var loading = false
    private var stateRetained = false

    init(settingsRoot: String, workspaceRoot: String, custody: PluginRegistryMetadataCustody,
        scratch: PluginRegistryMetadataPayment) {
        this.custody = custody; this.settingsRoot = settingsRoot; this.workspaceRoot = workspaceRoot
        scratch.ensureRetainedPeak(4194304)
        try {
            // One real reservation, including absent metadata, before opening
            // retained native snapshot handles. The original floor is intact.
            allocation = Some(custody.openPayment())
            // All actual watch wrappers, full path occurrences and fixed read
            // buffers are prepaid in this SAME original allocation before the
            // first path construction/native snapshot/watch is created. The
            // grant pathname has fixed 64 hex bytes plus its original suffix.
            rawCost = add(rawCost, pluginRegistrySnapshotObservationCost76(settingsRoot.size + 20))
            if (workspaceRoot.trimAscii() != "") {
                rawCost = add(rawCost, pluginRegistrySnapshotObservationCost76(workspaceRoot.size + 30))
                rawCost = add(rawCost, pluginRegistrySnapshotObservationCost76(settingsRoot.size + 128))
            }
            pay()
            snapshots.add(PluginRegistryMetadataSnapshot(settingsRoot + "/plugins/lock.jsonl"))
            if (workspaceRoot.trimAscii() != "") {
                snapshots.add(PluginRegistryMetadataSnapshot(workspaceRoot + "/.axyndra/plugins/lock.jsonl"))
                snapshots.add(PluginRegistryMetadataSnapshot(pluginWorkspaceGrantPath(settingsRoot, workspaceRoot)))
            }
            for (snapshot in snapshots) { rawCost = add(rawCost, snapshot.storageBytes() * 8 + 32768) }
            pay()
            // All three lengths are known and their SUM prepaid before any
            // immutable native byte copy is made.
            for (snapshot in snapshots) { snapshot.freeze() }
            validateLocked()
        } catch (error: Exception) { closeLocked(); throw error }
    }

    func openDataPayment78(): PluginRegistryMetadataPayment {
        lock.lock()
        try {
            if (closed) { throw LogicalJsonPayloadError("registry metadata generation is closed") }
            allocation.getOrThrow().derivePayment()
        } finally { lock.unlock() }
    }
    // Only data lifetime changes. This payment is a real child of the same
    // generation allocation; no execution grant or caller record is exposed.
    func openScratch103(): PluginRegistryMetadataPayment {
        lock.lock()
        try {
            if (closed) { throw PluginRegistryWriteError("plugin.registry_execution_stale", "installed metadata generation is revoked") }
            let actual = allocation.getOrThrow().derivePayment()
            try { actual.ensureRetainedPeak(4194304); actual }
            catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }
    private func requireLoad103(actual: PluginRegistryMetadataPayment): Unit {
        if (closed || loadingPayment.isNone() || !refEq(loadingPayment.getOrThrow(), actual)) {
            throw IllegalStateException("installed metadata capture phase is foreign or retired")
        }
    }
    private func add(left: Int64, right: Int64): Int64 {
        if (left < 0 || right < 0 || right > 134217728 - left) {
            throw LogicalJsonPayloadError("registry metadata exceeds the existing shared aggregate")
        }
        left + right
    }
    private func pay(): Unit {
        // Permanent snapshot/path/native-watch storage has its own real loan.
        // Loader, state, selected pin and fence peaks never grow this loan.
        allocation.getOrThrow().ensureRetainedPeak(rawCost)
    }
    private func closeLocked(): Unit {
        if (closed) { return }; closed = true
        for (snapshot in snapshots) { snapshot.close() }; snapshots.clear(); settingsRoot = ""; workspaceRoot = ""
        match (allocation) { case Some(value) => value.close(); allocation = None; case None => () }
    }
    private func validateLocked(): Unit {
        if (closed || revoked) { throw PluginRegistryWriteError("plugin.registry_execution_stale", "metadata generation is retired") }
        pluginRequireRegistryPublicationComplete(settingsRoot, workspaceRoot)
        for (snapshot in snapshots) { snapshot.validate() }
    }
    // Called only while Registry holds its ordinary mutex AND both real SH
    // file locks. Registry's actual current state has its own explicit hold.
    func tryRetain(scratch: PluginRegistryMetadataPayment): Bool {
        scratch.ensureRetainedPeak(4194304)
        lock.lock(); try {
            if (closed || revoked) { return false }
            try { validateLocked() }
            catch (_: Exception) { revoked = true; return false }
            if (references == Int64.Max) { throw LogicalJsonPayloadError("registry metadata reference count exhausted") }
            references++; true
        } finally { lock.unlock() }
    }
    func release(retainedCost: Int64): Unit {
        lock.lock(); try {
            if (references <= 0 || retainedCost < 0 || retainedCost > pinCost) {
                throw IllegalStateException("registry metadata reference ownership is inconsistent")
            }
            references--; pinCost -= retainedCost
            if (references == 0) { closeLocked() } else { pay() }
        } finally { lock.unlock() }
    }
    func retainState(retainedCost: Int64, actual: PluginRegistryMetadataPayment): Unit {
        lock.lock()
        try {
            requireLoad103(actual)
            if (closed || loading || references == Int64.Max || pendingStatePayment.isSome()) {
                throw IllegalStateException("registry current state has no completed paid load")
            }
            let next = allocation.getOrThrow().derivePayment()
            try { next.ensureRetainedPeak(retainedCost) }
            catch (error: Exception) { next.close(); throw error }
            pendingStatePayment = Some(next); pendingStateCost = retainedCost
            pendingStateRetention = !stateRetained
            if (!stateRetained) { references++; stateRetained = true }
        } finally { lock.unlock() }
    }
    func completeStatePublication(actual: PluginRegistryMetadataPayment): Unit {
        lock.lock()
        try {
            requireLoad103(actual)
            if (!stateRetained || loading || closed || pendingStatePayment.isNone()) {
                throw IllegalStateException("registry state publication has no retained completed load")
            }
            // Registry.publishState has RETURNED after replacing every old
            // records/history/error reference. The NEW state was prepaid.
            let previous = statePayment
            statePayment = pendingStatePayment; pendingStatePayment = None
            pendingStateRetention = false; latestStateCost = pendingStateCost; pendingStateCost = 0
            match (previous) { case Some(value) => value.close(); case None => () }
        } finally { lock.unlock() }
    }
    func releaseState(): Unit {
        lock.lock()
        try {
            if (!stateRetained) { return }
            stateRetained = false; latestStateCost = 0; references--
            // Caller already removed every Registry records/history reference.
            let previous = statePayment; statePayment = None
            match (previous) { case Some(value) => value.close(); case None => () }
            if (references == 0) { closeLocked() } else { pay() }
        } finally { lock.unlock() }
    }
    func validate(): Unit {
        let scratch = openScratch103()
        try { validateFrame103() } finally { scratch.close() }
    }
    private func validateFrame103(): Unit {
        lock.lock(); try { validateLocked() } finally { lock.unlock() }
    }
    func validateLoad103(actual: PluginRegistryMetadataPayment): Unit {
        lock.lock(); try { requireLoad103(actual); validateLocked() } finally { lock.unlock() }
    }
    func reserveFence(): PluginRegistryMetadataPayment {
        lock.lock()
        try {
            if (closed || revoked) { throw PluginRegistryWriteError("plugin.registry_execution_stale", "metadata generation is retired") }
            let actual = allocation.getOrThrow().derivePayment()
            try { actual.ensureRetainedPeak(65536); fenceCost = add(fenceCost, 65536); actual }
            catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }
    func releaseFence(): Unit {
        lock.lock(); try { if (fenceCost < 65536) { throw IllegalStateException("registry admission lease was released twice") }; fenceCost -= 65536 }
        finally { lock.unlock() }
    }
    func source(path: String, actual: PluginRegistryMetadataPayment): ?String {
        lock.lock()
        try {
            requireLoad103(actual); validateLocked()
            for (snapshot in snapshots where snapshot.path == path) { return snapshot.source() }
            throw PluginRegistryWriteError("plugin.registry_pin_path", "metadata path was not captured by this registry")
        } finally { lock.unlock() }
    }
    func beginLoad(actual: PluginRegistryMetadataPayment): Unit {
        lock.lock()
        try {
            actual.ensureRetainedPeak(4194304)
            validateLocked()
            if (loading || loadingCost != 0 || loadingPayment.isSome()) { throw IllegalStateException("registry metadata loader overlaps") }
            loadingPayment = Some(actual); loading = true; loadingCost = 0
        } finally { lock.unlock() }
    }
    func retainLoadData103(bytes: Int64, actual: PluginRegistryMetadataPayment): Unit {
        lock.lock()
        try {
            requireLoad103(actual)
            if (!loading || closed || revoked) {
                throw IllegalStateException("registry metadata loader is not owned")
            }
            // This is the full reachable typed state, not inspection work.
            // Retain its high-water while any loader/result alias remains.
            loadingCost = max(loadingCost, bytes)
            actual.ensureRetainedPeak(add(4194304, loadingCost))
        } finally { lock.unlock() }
    }
    func openRecordInspection103(actual: PluginRegistryMetadataPayment): PluginRegistryMetadataPayment {
        lock.lock()
        try {
            requireLoad103(actual)
            if (!loading || revoked) { throw IllegalStateException("registry record inspection has no active load") }
            let working = actual.derivePayment()
            // The original loading owner retains its full4MiB caller/IO
            // working prepayment. This child adds the discovered row work.
            try { working.ensureRetainedPeak(4096); working }
            catch (error: Exception) { working.close(); throw error }
        } finally { lock.unlock() }
    }
    func finishLoad(retainedCost: Int64, identityCost: Int64, actual: PluginRegistryMetadataPayment): PluginRegistryMetadataPayment {
        lock.lock()
        try {
            requireLoad103(actual)
            if (!loading || retainedCost < 0 || retainedCost > loadingCost) {
                throw IllegalStateException("registry descriptor has no paid load")
            }
            let nextPinCost = add(pinCost, retainedCost)
            let selected = allocation.getOrThrow().derivePayment()
            try { selected.ensureRetainedPeak(pluginRegistryInvoiceAdd78(retainedCost, identityCost)) }
            catch (error: Exception) { selected.close(); throw error }
            pinCost = nextPinCost; loading = false; selected
        } finally { lock.unlock() }
    }
    // Called ONLY after captureInstalledOwnedFrame101 has RETURNED. Old pins
    // carry no token for a later capture and cannot abort its private phase.
    func abortLoad(actual: PluginRegistryMetadataPayment): Unit {
        lock.lock()
        try {
            requireLoad103(actual)
            let pending = pendingStatePayment; pendingStatePayment = None; pendingStateCost = 0
            match (pending) { case Some(value) => value.close(); case None => () }
            if (pendingStateRetention) { stateRetained = false; references-- }
            pendingStateRetention = false; loadingCost = 0; loading = false; loadingPayment = None
        } finally { lock.unlock() }
    }
}

class PluginRegistryInspectionMemory <: PluginPackagePrivateDocumentAccounting78 {
    private let owner: PluginRegistryMetadataGeneration
    private var actual: ?PluginRegistryMetadataPayment = None
    private var working: ?PluginRegistryMetadataPayment = None
    private var workingInvoice: Int64 = 0
    init(owner: PluginRegistryMetadataGeneration) { this.owner = owner }
    func beginLoad103(payment: PluginRegistryMetadataPayment): Unit {
        if (actual.isSome()) { throw IllegalStateException("inspection phase already adopted") }; actual = Some(payment)
    }
    func retireLoad103(payment: PluginRegistryMetadataPayment): Unit {
        if (actual.isNone() || !refEq(actual.getOrThrow(), payment)) { throw IllegalStateException("inspection phase is foreign or retired") }
        // Called only after the entire capture helper returned, including
        // exceptional partial row construction that could not hand off DATA.
        if (working.isSome()) { let returned = takeReturnedRecordPayment103(); returned.close() }
        actual = None
    }
    func beginRecord103(): Unit {
        if (working.isSome()) { throw IllegalStateException("registry record inspection overlaps a live producer") }
        working = Some(owner.openRecordInspection103(actual.getOrThrow())); workingInvoice = 4096
    }
    func takeReturnedRecordPayment103(): PluginRegistryMetadataPayment {
        let returned = working.getOrThrow(); working = None; workingInvoice = 0; returned
    }
    func chargeWork103(bytes: Int64): Unit {
        let next = pluginRegistryInvoiceAdd78(workingInvoice, bytes)
        working.getOrThrow().ensureRetainedPeak(next); workingInvoice = next
    }
    public func beginPrivateDocument78(source: String): PluginPackagePrivateDocumentPayment78 {
        pluginRegistryBeginPrivateDocument78(working.getOrThrow(), source, { bytes => chargeWork103(bytes) })
    }
    public func beforeDocument(source: String): Unit {
        // A lexical count, not a new node quota or a parser replacement.
        // The unchanged parser still validates all JSON grammar and limits.
        // Raw copies are prepaid before scanning, not after their creation.
        chargeWork103(source.size * 8 + 16384)
        var quoted = false; var escaped = false; var scalar = false; var nodes: Int64 = 0; var lines: Int64 = 1
        for (byte in source.toArray()) {
            if (byte == 10) { lines++ }
            if (quoted) {
                if (escaped) { escaped = false }
                else if (byte == b'\\') { escaped = true }
                else if (byte == b'"') { quoted = false }
            } else if (byte == b'"') { quoted = true; scalar = false; nodes++ }
            else if (byte == b'{' || byte == b'[') { scalar = false; nodes++ }
            else if (byte == b'}' || byte == b']' || byte == b',' || byte == b':' || byte == 32 || byte == 9 || byte == 10 || byte == 13) { scalar = false }
            else if (!scalar) { scalar = true; nodes++ }
        }
        chargeWork103(nodes * 512 + lines * 64)
    }
    public func beforeTreePath(bytes: Int64): Unit {
        if (bytes < 0 || bytes > 16777216) { throw LogicalJsonPayloadError("registry package metadata path is outside resource bounds") }
        chargeWork103(bytes * 8 + 1024)
    }
}
