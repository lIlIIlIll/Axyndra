package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.sync.*

// Physical metadata ownership only. A payment cannot inspect, enable, mint a
// pin, or admit execution. One REAL original Native reservation covers this
// Registry's constructor state, overlapping reload, generations and fences.
class PluginRegistryMetadataCustody {
    private let lock = Mutex()
    private let allocation: LogicalJsonOwnerReservation
    private let costs = HashMap<Int64, Int64>()
    private let payments = HashMap<Int64, LogicalJsonOwnerReservation>()
    private var serial: Int64 = 0
    private var total: Int64 = 0
    private var rootClosed = false
    private var released = false

    // Installed-registry metadata is charged to its own declared pool rather
    // than the shared native-payload bank: this root is taken once per mounted
    // plugin and each acquisition pays the 16 MiB floor, so installed plugins
    // would otherwise hold tens of MiB of the shared bank for the whole session
    // and starve the ordinary tool-call audit frame. See
    // `agent_extension_runtime/src/native_payload.cj` and E412.
    init() { allocation = reserveNativeRegistryMetadata(4096) }

    func openPayment(): PluginRegistryMetadataPayment {
        lock.lock()
        try {
            if (rootClosed || released || serial == Int64.Max) {
                throw LogicalJsonPayloadError("registry metadata custody cannot retain a new owner")
            }
            if (total > 134217728 - 1024) { throw LogicalJsonPayloadError("registry payment headers exceed the original aggregate") }
            let actual = allocation.deriveRetainedLease()
            try { actual.ensureRetainedPeak(1024) }
            catch (error: Exception) { actual.close(); throw error }
            serial++; costs[serial] = 1024; payments[serial] = actual; total += 1024
            PluginRegistryMetadataPayment(this, serial)
        } finally { lock.unlock() }
    }

    func derivePayment(parent: Int64): PluginRegistryMetadataPayment {
        lock.lock()
        try {
            if (released || !costs.contains(parent) || serial == Int64.Max) {
                throw LogicalJsonPayloadError("registry metadata parent payment is closed")
            }
            // A live child can copy private data after its Registry root has
            // closed, while sharing the exact original reservation and slot.
            if (total > 134217728 - 1024) { throw LogicalJsonPayloadError("registry payment headers exceed the original aggregate") }
            let actual = payments[parent].deriveRetainedLease()
            try { actual.ensureRetainedPeak(1024) }
            catch (error: Exception) { actual.close(); throw error }
            serial++; costs[serial] = 1024; payments[serial] = actual; total += 1024
            PluginRegistryMetadataPayment(this, serial)
        } finally { lock.unlock() }
    }
    func deriveRetainedData113(minimum: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (rootClosed || released || minimum < 0 || minimum > 134217728) {
                throw LogicalJsonPayloadError("registry data bank cannot admit another live loan")
            }
            let actual = allocation.deriveRetainedLease()
            try { actual.ensureRetainedPeak(minimum); actual }
            catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }
    func deriveLogicalData(parent: Int64, minimum: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (released || !costs.contains(parent) || minimum < 0 || minimum > 134217728) {
                throw LogicalJsonPayloadError("registry copied data has no retained actual parent")
            }
            let actual = payments[parent].deriveRetainedLease()
            try { actual.ensureRetainedPeak(minimum); actual }
            catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }

    func ensure(id: Int64, minimum: Int64): Unit {
        lock.lock()
        try {
            if (released || minimum < 0 || minimum > 134217728 || !costs.contains(id)) {
                throw LogicalJsonPayloadError("registry metadata payment is not retained")
            }
            let peak = max(costs[id], minimum)
            let other = total - costs[id]
            if (peak > 134217728 - other) {
                throw LogicalJsonPayloadError("registry metadata live owners exceed the original aggregate")
            }
            // Each actual state/backing owns a child in the SAME original
            // SUM ledger. Its historical peak belongs only to that child.
            // Closing retired state removes its lease, while the physical
            // floor/high-water stays until the final actual owner closes.
            payments[id].ensureRetainedPeak(peak)
            costs[id] = peak; total = other + peak
        } finally { lock.unlock() }
    }

    func release(id: Int64): Unit {
        lock.lock()
        try {
            match (costs.remove(id)) { case Some(value) => total -= value; case None => return }
            let actual = payments.remove(id).getOrThrow()
            actual.close()
            finishLocked()
        } finally { lock.unlock() }
    }
    private func finishLocked(): Unit {
        if (rootClosed && costs.isEmpty() && !released) { released = true; allocation.close() }
    }
    func close(): Unit {
        lock.lock(); try { rootClosed = true; finishLocked() } finally { lock.unlock() }
    }
}

class PluginRegistryMetadataPayment {
    private let owner: PluginRegistryMetadataCustody
    private let id: Int64
    private let lock = Mutex()
    private var closed = false
    private var retained: Int64 = 1024
    init(owner: PluginRegistryMetadataCustody, id: Int64) { this.owner = owner; this.id = id }
    func ensureRetainedPeak(bytes: Int64): Unit {
        lock.lock()
        try {
            if (closed) { throw LogicalJsonPayloadError("registry metadata payment is closed") }
            owner.ensure(id, bytes); retained = max(retained, bytes)
        } finally { lock.unlock() }
    }
    func growBy(bytes: Int64): Unit {
        lock.lock()
        try {
            if (closed || bytes < 0 || bytes > 134217728 - retained) { throw LogicalJsonPayloadError("registry data view exceeds its retained payment") }
            owner.ensure(id, retained + bytes); retained += bytes
        } finally { lock.unlock() }
    }
    func derivePayment(): PluginRegistryMetadataPayment {
        lock.lock(); try {
            if (closed) { throw LogicalJsonPayloadError("registry metadata payment is closed") }
            owner.derivePayment(id)
        } finally { lock.unlock() }
    }
    func deriveLogicalData(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (closed) { throw LogicalJsonPayloadError("registry metadata payment is closed") }
            owner.deriveLogicalData(id, invoice)
        } finally { lock.unlock() }
    }
    func close(): Unit {
        lock.lock(); try { if (!closed) { closed = true; owner.release(id) } } finally { lock.unlock() }
    }
}

// Detached loading and management mutations retain their actual decoded
// records under this token until Registry clears/replaces those containers.
// It has no registry authority and is never supplied by external callers.
class PluginRegistryStateMemory <: PluginPackagePrivateDocumentAccounting78 {
    private let payment: PluginRegistryMetadataPayment
    private var retained: Int64 = 4194304
    private var closed = false
    init(custody: PluginRegistryMetadataCustody) {
        payment = custody.openPayment()
        try { payment.ensureRetainedPeak(retained) } catch (error: Exception) { payment.close(); throw error }
    }
    func charge(bytes: Int64): Unit {
        if (closed || bytes < 0 || bytes > 134217728 - retained) {
            throw LogicalJsonPayloadError("registry state metadata exceeds its retained owner")
        }
        payment.ensureRetainedPeak(retained + bytes); retained += bytes
    }
    func source(path: String): ?String {
        if (closed) { throw LogicalJsonPayloadError("registry state is closed") }
        charge(pluginRegistrySnapshotObservationCost76(path.size))
        let snapshot = PluginRegistryMetadataSnapshot(path)
        try {
            // Length and FD/type checks precede native freeze/copy and UTF8.
            // The original maximum still belongs to the snapshot primitive.
            charge(snapshot.storageBytes() * 8 + 32768)
            snapshot.freeze(); let value = snapshot.source(); snapshot.validate()
            match (value) {
                case Some(text) =>
                    var lines: Int64 = 1
                    for (byte in text.toArray() where byte == 10) { lines++ }
                    // The unchanged loader uses split. Pay its actual line
                    // container even for a file containing only blank lines.
                    charge(lines * 64)
                case None => ()
            }
            value
        } finally { snapshot.close() }
    }
    public func beginPrivateDocument78(source: String): PluginPackagePrivateDocumentPayment78 {
        if (closed) { throw LogicalJsonPayloadError("registry state is closed") }
        pluginRegistryBeginPrivateDocument78(payment, source, { bytes => charge(bytes) })
    }
    func openDataPayment78(): PluginRegistryMetadataPayment { payment.derivePayment() }
    public func beforeDocument(source: String): Unit {
        // Pay raw scanning copies BEFORE making them, then all lexical nodes
        // BEFORE the unchanged parser constructs its DOM.
        charge(source.size * 8 + 16384)
        var quoted = false; var escaped = false; var scalar = false; var nodes: Int64 = 0
        for (byte in source.toArray()) {
            if (quoted) {
                if (escaped) { escaped = false }
                else if (byte == b'\\') { escaped = true }
                else if (byte == b'"') { quoted = false }
            } else if (byte == b'"') { quoted = true; scalar = false; nodes++ }
            else if (byte == b'{' || byte == b'[') { scalar = false; nodes++ }
            else if (byte == b'}' || byte == b']' || byte == b',' || byte == b':' || byte == 32 || byte == 9 || byte == 10 || byte == 13) { scalar = false }
            else if (!scalar) { scalar = true; nodes++ }
        }
        charge(nodes * 512)
    }
    public func beforeTreePath(bytes: Int64): Unit {
        if (bytes < 0 || bytes > 16777216) { throw LogicalJsonPayloadError("registry tree path is outside metadata bounds") }
        charge(bytes * 8 + 1024)
    }
    // The restore API adopts caller data rather than a freshly inspected
    // descriptor. Pay that actual graph before records/history retain it.
    // No stringify/DOM or unbounded array copy is needed for this traversal.
    func beforeLoadedRecord78(record: RawProductPluginRecord): Unit { charge(pluginOwnedRecordInvoice78(record)) }
    func beforeCopiedRecord78(record: RawProductPluginRecord): Unit {
        charge(8192); charge(pluginOwnedRecordInvoice78(record) * 8 + 65536)
    }
    func beforeRetainedRecord(record: RawProductPluginRecord): Unit {
        let descriptor = record.descriptor
        beforeTreePath(0)
        for (text in [record.locator, record.versionLock, record.revisionLock,
            record.integrityLock, record.contentLock, descriptor.id, descriptor.namespace,
            descriptor.version, descriptor.source, descriptor.root, descriptor.manifestPath,
            descriptor.overlayPath, descriptor.compatibilityProfile, descriptor.entrypoint,
            descriptor.sdkRange, descriptor.protocolRange, descriptor.contentDigest,
            descriptor.declaredContentDigest, descriptor.signature]) { beforeTreePath(text.size) }
        for (component in descriptor.components) {
            beforeTreePath(0)
            for (text in [component.relativePath, component.name, component.identity]) { beforeTreePath(text.size) }
            for (text in component.dependencies) { beforeTreePath(text.size) }
        }
        for (hook in descriptor.hookDeclarations) {
            beforeTreePath(0)
            for (text in [hook.event, hook.matcher, hook.command]) { beforeTreePath(text.size) }
        }
        for (dependency in descriptor.dependencies) {
            beforeTreePath(0); beforeTreePath(dependency.name.size); beforeTreePath(dependency.versionRange.size)
        }
        // The descriptor's original constructor bounds this clone to 32.
        // Each contribution's original constructor bounds its control clone
        // to one; pay both bounded copies before calling their getters.
        charge(32768)
        for (dependency in descriptor.componentDependencies) {
            beforeTreePath(0)
            for (text in [dependency.namespace, dependency.versionRange, dependency.name]) { beforeTreePath(text.size) }
        }
        for (contribution in descriptor.contributions) {
            beforeTreePath(0); beforeTreePath(contribution.name.size)
            beforeTreePath(contribution.inputAttachmentField.size); charge(1024)
            for (text in contribution.allowedUserControls()) { beforeTreePath(text.size) }
        }
        for (text in descriptor.missingDependencies) { beforeTreePath(text.size) }
        for (text in descriptor.requestedCapabilities) { beforeTreePath(text.size) }
    }
    func close(): Unit { if (!closed) { closed = true; payment.close() } }
}
