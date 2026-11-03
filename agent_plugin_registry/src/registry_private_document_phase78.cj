package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.sync.*
import yjson.*

class PluginRegistryPrivateRowHolder78 {
    let payment: PluginRegistryPrivateDocumentPayment78
    var node: ?JsonNode = None
    init(payment: PluginRegistryPrivateDocumentPayment78) { this.payment = payment }
}
class PluginRegistryPrivateRowRetirement78 {
    private let actual: PluginRegistryPrivateDocumentPayment78
    private var used = false
    private init(actual: PluginRegistryPrivateDocumentPayment78) { this.actual = actual }
    static func issue(holder: PluginRegistryPrivateRowHolder78): PluginRegistryPrivateRowRetirement78 {
        if (holder.node.isSome()) { throw IllegalStateException("registry row DOM remains live") }
        PluginRegistryPrivateRowRetirement78(holder.payment)
    }
    func consume(payment: PluginRegistryPrivateDocumentPayment78): Bool {
        if (used || !refEq(actual, payment)) { return false }; used = true; true
    }
}
func pluginRegistryOpenRowHolder78(accounting: PluginPackageMetadataAccounting, source: String): PluginRegistryPrivateRowHolder78 {
    let actual = match (accounting as PluginPackagePrivateDocumentAccounting78) {
        case Some(value) => value.beginPrivateDocument78(source)
        case None => throw LogicalJsonPayloadError("actual registry loader has no private document payer")
    }
    let payment = match (actual as PluginRegistryPrivateDocumentPayment78) {
        case Some(value) => value
        case None => throw LogicalJsonPayloadError("actual registry row has no same-custody payment")
    }
    PluginRegistryPrivateRowHolder78(payment)
}
func pluginRegistryRetireRow78(holder: PluginRegistryPrivateRowHolder78): Unit {
    holder.node = None
    holder.payment.retireRow78(PluginRegistryPrivateRowRetirement78.issue(holder))
}

// The DEFAULT StateMemory and captured-generation accounting implement this
// route. Its temporary document child is from the same actual metadata payer;
// descriptor/components/error data is separately paid before leaving a frame.
class PluginRegistryPrivateDocumentPayment78 <: PluginPackagePrivateDocumentPayment78 {
    private let lock = Mutex()
    private var document: ?LogicalJsonOwnerReservation
    private var retainData: ?(Int64) -> Unit
    init(document: LogicalJsonOwnerReservation, retainData: (Int64) -> Unit) {
        this.document = Some(document); this.retainData = Some(retainData)
    }
    public func retainDescriptor78(value: PluginPackageDescriptor): Unit {
        lock.lock()
        try { retainData.getOrThrow()(pluginOwnedDescriptorInvoice78(value)) }
        finally { lock.unlock() }
    }
    public func retainComponents78(values: Array<PluginComponent>): Unit {
        lock.lock()
        try {
            var invoice = 2048 + values.size * 64
            for (value in values) { invoice = pluginRegistryInvoiceAdd78(invoice, pluginOwnedComponentInvoice78(value)) }
            retainData.getOrThrow()(invoice)
        } finally { lock.unlock() }
    }
    public func retainError78(value: PluginPackageError): Unit {
        lock.lock()
        try { retainData.getOrThrow()((value.code.size + value.message.size + value.source.size + value.field.size) * 8 + 8192) }
        finally { lock.unlock() }
    }
    public func retireDocument78(retirement: PluginPackagePrivateDocumentRetirement78): Unit {
        lock.lock()
        try {
            if (document.isNone() || !retirement.consumeFor78(this)) {
                throw LogicalJsonPayloadError("private document retirement is foreign or replayed")
            }
            retainData = None
            let actual = document.getOrThrow(); document = None; actual.close()
        } finally { lock.unlock() }
    }
    func retireRow78(retirement: PluginRegistryPrivateRowRetirement78): Unit {
        lock.lock()
        try {
            if (document.isNone() || !retirement.consume(this)) {
                throw LogicalJsonPayloadError("registry row retirement is foreign or replayed")
            }
            retainData = None
            let actual = document.getOrThrow(); document = None; actual.close()
        } finally { lock.unlock() }
    }
}

func pluginRegistryBeginPrivateDocument78(parent: PluginRegistryMetadataPayment,
    source: String, retainData: (Int64) -> Unit): PluginPackagePrivateDocumentPayment78 {
    // This is an actual child in the existing LogicalJsonSharedCustody SUM
    // ledger, not a counter-only subpayment of its monotone root invoice.
    // Closing it after the real private helper/holder end retires that lease;
    // the original physical floor/high-water remains until the final owner.
    let document = parent.deriveLogicalData(4096)
    try {
        if (source.size > 16777216) { throw LogicalJsonPayloadError("private manifest exceeds its original text bound") }
        // Pay the full scan Array and phase/header BEFORE creating them.
        let raw = source.size * 16 + 65536
        document.ensureRetainedPeak(raw)
        let nodes = pluginRegistryPrivateDocumentNodes78(source)
        document.ensureRetainedPeak(pluginRegistryInvoiceAdd78(raw, nodes * 512))
        PluginRegistryPrivateDocumentPayment78(document, retainData)
    } catch (error: Exception) { document.close(); throw error }
}

func pluginRegistryPrivateDocumentNodes78(source: String): Int64 {
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
    }; nodes
}
