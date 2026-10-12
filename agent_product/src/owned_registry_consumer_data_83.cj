package agent_product

import agent_domain.*
import agent_plugin_registry.*
import std.sync.*
import yjson.*
import yjson_support.*

// These are DATA payments for copied maintenance/presentation values. They
// confer no registration, Source, effect, approval or I/O authority. Existing
// public response/history strings have no retirement contract, so their real
// copied backing remains paid rather than being refunded when a frame returns.
class ProductRegistryEscapedCopyNode83 {
    private let payment: LogicalJsonOwnerReservation
    private let errors: ?OwnedRegistryErrorList
    private let previous: ?ProductRegistryEscapedCopyNode83
    init(payment: LogicalJsonOwnerReservation, previous: ?ProductRegistryEscapedCopyNode83, errors: ?OwnedRegistryErrorList) {
        this.payment = payment; this.previous = previous; this.errors = errors
    }
}

class ProductRegistryEscapedCopyDebt83 {
    private let lock = Mutex()
    private var head: ?ProductRegistryEscapedCopyNode83 = None<ProductRegistryEscapedCopyNode83>
    func adopt(payment: LogicalJsonOwnerReservation, errors!: ?OwnedRegistryErrorList = None): Unit {
        lock.lock()
        try { head = Some(ProductRegistryEscapedCopyNode83(payment, head, errors)) }
        finally { lock.unlock() }
    }
}

// No budget is created here. Every node below is prepaid from the actual
// incoming Registry byte loan in the original process aggregate.
let productRegistryEscapedCopies83 = ProductRegistryEscapedCopyDebt83()

func productRegistryCopyInvoice83(bytes: Int64, extra: Int64): Int64 {
    if (bytes < 0 || extra < 0 || extra > 134217728 - 8192 ||
        bytes > (134217728 - 8192 - extra) / 64) {
        throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")
    }
    // Incoming bytes are already paid. This adds the actual copied byte
    // Array, UTF-8 String backing/validation scratch, returned aliases, and
    // the linked payment holder. Extra is for a caller's simultaneous cells.
    bytes * 64 + extra + 8192
}

func productRegistryCopyText83(result: PluginRegistryResult<OwnedRegistryUtf8>, extra!: Int64 = 0, custody!: ?OwnedApplicationRegistryResponse161 = None): String {
    let bytes = match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) =>
            throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")
    }
    try {
        let size = bytes.byteCount
        let payment = bytes.deriveCopiedDataPayment(productRegistryCopyInvoice83(size, extra))
        // Adopt before allocating or decoding any copied bytes. A failed copy
        // keeps this debt; no finally block pretends an escaped value retired.
        productRegistryAdoptCopied161(payment, custody: custody)
        let copied = Array<UInt8>(size, { index => bytes.byteAt(index) })
        String.fromUtf8(copied)
    } finally { bytes.close() }
}

func productRegistryErrorText83(error: PluginRegistryOwnedError, field: PluginRegistryErrorText, custody!: ?OwnedApplicationRegistryResponse161 = None): String {
    let message = match (error.staticReason) {
        case PluginRegistryStaticReason.MetadataCapacity => "registry metadata cannot fit the original shared capacity"
        case PluginRegistryStaticReason.ExecutionNotCurrent => "installed execution pin is not current"
        case PluginRegistryStaticReason.InstalledRecordAbsent => "installed record is absent"
        case PluginRegistryStaticReason.ComponentAliasInvalid => "initial context configuration or its exact installed binding is unavailable"
        case PluginRegistryStaticReason.None => return productRegistryCopyText83(error.copyText(field), custody: custody)
    }
    match (field) { case PluginRegistryErrorText.Message => message; case PluginRegistryErrorText.Source => ""; case PluginRegistryErrorText.Field => "" }
}

func productRegistryRecords83(list: OwnedPluginRecordList, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<ProductPluginRecord> {
    try {
        let size = list.size
        if (size == 0) { return [] }
        if (size > (134217728 - 8192) / 256) { throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity") }
        let payment = list.deriveCopiedDataPayment(size * 256 + 8192)
        productRegistryAdoptCopied161(payment, custody: custody)
        Array<ProductPluginRecord>(size, { index => productRegistryKeepRecord161(list.take(index), custody) })
    } finally { list.close() }
}

func productRegistryContributions83(descriptor: OwnedPluginPackageDescriptor, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<OwnedPluginContribution> {
    let size = descriptor.contributionCount
    if (size == 0) { return [] }
    let source = match (descriptor.copyText(PluginDescriptorText.Namespace)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")
    }
    try {
        if (size > (134217728 - 8192) / 256) { throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity") }
        let payment = source.deriveCopiedDataPayment(size * 256 + 8192)
        productRegistryAdoptCopied161(payment, custody: custody)
        Array<OwnedPluginContribution>(size, { index => descriptor.contribution(index) })
    } finally { source.close() }
}


func productRegistryFailure83<T>(runtime: ProductPluginRuntime, code: String, message: String): PluginRegistryResult<T> {
    PluginRegistryResult.Err(runtime.ownedError(code, message))
}

func productRegistryPrepayCells83(descriptor: OwnedPluginPackageDescriptor, count: Int64, custody!: ?OwnedApplicationRegistryResponse161 = None): Unit {
    if (count < 0 || count > (134217728 - 8192) / 256) {
        throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")
    }
    let payment = descriptor.deriveCopiedDataPayment(count * 256 + 8192)
    productRegistryAdoptCopied161(payment, custody: custody)
}

func productRegistryComponents83(descriptor: OwnedPluginPackageDescriptor, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<OwnedPluginComponent> {
    let size = descriptor.componentCount
    if (size == 0) { return [] }
    productRegistryPrepayCells83(descriptor, size, custody: custody)
    Array<OwnedPluginComponent>(size, { index => descriptor.component(index) })
}

func productRegistryHooks83(descriptor: OwnedPluginPackageDescriptor, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<OwnedPluginHookDeclaration> {
    let size = descriptor.hookCount
    if (size == 0) { return [] }
    productRegistryPrepayCells83(descriptor, size, custody: custody)
    Array<OwnedPluginHookDeclaration>(size, { index => descriptor.hook(index) })
}

func productRegistryCapabilities83(descriptor: OwnedPluginPackageDescriptor, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<String> {
    let size = descriptor.capabilityCount
    if (size == 0) { return [] }
    productRegistryPrepayCells83(descriptor, size, custody: custody)
    Array<String>(size, { index => productRegistryCopyText83(descriptor.copyCapability(index), custody: custody) })
}

func productRegistryDependencies83(descriptor: OwnedPluginPackageDescriptor, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<OwnedPluginPackageDependency> {
    let size = descriptor.dependencyCount
    if (size == 0) { return [] }
    productRegistryPrepayCells83(descriptor, size, custody: custody)
    Array<OwnedPluginPackageDependency>(size, { index => descriptor.dependency(index) })
}

func productRegistryMissingDependencies83(descriptor: OwnedPluginPackageDescriptor, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<String> {
    let size = descriptor.missingDependencyCount
    if (size == 0) { return [] }
    productRegistryPrepayCells83(descriptor, size, custody: custody)
    Array<String>(size, { index => productRegistryCopyText83(descriptor.copyMissingDependency(index), custody: custody) })
}


func productRegistryCopyJson83(result: PluginRegistryResult<OwnedRegistryUtf8>, custody!: ?OwnedApplicationRegistryResponse161 = None): AgentValue {
    let source = match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")
    }
    try {
        let size = source.byteCount
        var quoted = false; var escaped = false; var primitive = false; var nodes: Int64 = 0
        for (index in 0..size) {
            let byte = source.byteAt(index)
            if (quoted) {
                if (escaped) { escaped = false }
                else if (byte == 92u8) { escaped = true }
                else if (byte == 34u8) { quoted = false }
                continue
            }
            if (byte == 34u8) { nodes += 1; quoted = true; primitive = false }
            else if (byte == 123u8 || byte == 91u8) { nodes += 1; primitive = false }
            else if (byte == 44u8 || byte == 58u8 || byte == 125u8 || byte == 93u8 || byte <= 32u8) { primitive = false }
            else if (!primitive) { nodes += 1; primitive = true }
        }
        if (nodes > (134217728 - 8192) / 1024) { throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity") }
        let payment = source.deriveCopiedDataPayment(productRegistryCopyInvoice83(size, nodes * 1024))
        productRegistryAdoptCopied161(payment, custody: custody)
        let bytes = Array<UInt8>(size, { index => source.byteAt(index) })
        // Preserve the original component snapshot's semantic decode limit.
        parseUnifiedJson(String.fromUtf8(bytes), maxBytes: RUN_CONTEXT_SNAPSHOT_MAX_BYTES)
    } finally { source.close() }
}


func productRegistryAllowedControls83(descriptor: OwnedPluginPackageDescriptor, contribution: OwnedPluginContribution, custody!: ?OwnedApplicationRegistryResponse161 = None): Array<String> {
    let count = contribution.allowedControlCount
    if (count == 0) { return [] }
    productRegistryPrepayCells83(descriptor, count, custody: custody)
    Array<String>(count, { index => productRegistryCopyText83(contribution.copyAllowedControl(index), custody: custody) })
}
