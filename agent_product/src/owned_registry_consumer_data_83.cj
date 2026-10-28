package agent_product

import agent_domain.*
import agent_plugin_registry.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// These are DATA payments for copied maintenance/presentation values. They
// confer no registration, Source, effect, approval or I/O authority. A copied
// String has no retirement contract of its own, so its real backing stays paid
// for the lifetime of the Product that produced it rather than being refunded
// when the builder frame returns: the actual owner is that Product. This is
// bank accounting only; retiring a payment never invalidates a returned value.
//
// Without an owner lifetime each Product permanently retained a full 16 MiB
// floor per import cycle, so a second canonical run inside the same process
// was refused with `policy.query_limit` (measured: 16/32/48 MiB after 1/2/3
// cycles). Retiring on close is what removes that refusal.
class ProductRegistryEscapedCopyNode83 {
    private let payment: LogicalJsonOwnerReservation
    private let errors: ?OwnedRegistryErrorList
    private let previous: ?ProductRegistryEscapedCopyNode83
    init(payment: LogicalJsonOwnerReservation, previous: ?ProductRegistryEscapedCopyNode83, errors: ?OwnedRegistryErrorList) {
        this.payment = payment; this.previous = previous; this.errors = errors
    }
    // Only the copied-DATA payment is retired here. A linked error list was
    // handed to a caller and keeps its own close contract; closing it here
    // would be a second close of an owner this debt never handed out.
    func retirePayment(): Unit { payment.close() }
    func previousNode(): ?ProductRegistryEscapedCopyNode83 { previous }
}

class ProductRegistryEscapedCopyDebt83 {
    private let lock = Mutex()
    private var head: ?ProductRegistryEscapedCopyNode83 = None<ProductRegistryEscapedCopyNode83>
    private var products: Int64 = 0
    func adopt(payment: LogicalJsonOwnerReservation, errors!: ?OwnedRegistryErrorList = None): Unit {
        lock.lock()
        try { head = Some(ProductRegistryEscapedCopyNode83(payment, head, errors)) }
        finally { lock.unlock() }
    }
    // Records ownership only. No charge, floor, SUM rule or refund timing
    // changes; this just names who can still reach a copied value.
    func beginProduct(): Unit { lock.lock(); try { products += 1 } finally { lock.unlock() } }
    // Called once per Product, only after every frame/callback that could read
    // a copied value has returned. Nodes retire when the LAST live Product
    // closes, so one Product's copy stays paid while another could still read
    // it: this can over-retain a floor but never under-counts. A copy adopted
    // after the last Product closed keeps its charge.
    func endProduct(): Unit {
        lock.lock()
        var retire = false
        try {
            if (products > 0) {
                products -= 1
                if (products == 0 && head.isSome()) { retire = true }
            }
        } finally { lock.unlock() }
        if (!retire) { return }
        lock.lock()
        let first = try { let value = head; head = None<ProductRegistryEscapedCopyNode83>; value }
            finally { lock.unlock() }
        var node = first
        while (true) {
            match (node) {
                case Some(actual) => let next = actual.previousNode(); actual.retirePayment(); node = next
                case None => return }
        }
    }
}

// No budget is created here. Every node below is prepaid from the actual
// incoming Registry byte loan in the original process aggregate.
let productRegistryEscapedCopies83 = ProductRegistryEscapedCopyDebt83()

// A cutover collection is private DATA, not a public Raw response. Its sole
// consumers are synchronous Product visitors; no Array/String view escapes.
// The incoming Registry loan pays the holder and every cell before allocation.
class ProductMountedPluginInstances83 {
    private let payment: LogicalJsonOwnerReservation
    private var records: ?ArrayList<ProductPluginRecord>
    private var closed = false
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = payment
        this.records = Some(ArrayList<ProductPluginRecord>())
    }
    func capture(list: OwnedPluginRecordList, selected: (ProductPluginRecord) -> Bool): Unit {
        for (index in 0..list.size) {
            let record = list.take(index)
            if (selected(record)) { records.getOrThrow().add(record) } else { record.close() }
        }
    }
    func visit(action: (ProductPluginRecord) -> PluginRegistryResult<Unit>): PluginRegistryResult<Unit> {
        for (record in records.getOrThrow()) {
            match (action(record)) { case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error); case PluginRegistryResult.Ok(_) => () }
        }
        PluginRegistryResult.Ok(())
    }
    private func retirePrivateCells(): Unit {
        let original = records
        records = None<ArrayList<ProductPluginRecord>>
        match (original) {
            case Some(values) => for (record in values) { record.close() }; values.clear()
            case None => ()
        }
    }
    func close(): Unit {
        if (closed) { return }
        // Both private visitors returned. Host pins and Hook generations own
        // independent data; these taken views never leave the collection.
        // Clear their actual backings before the collection payment retires.
        retirePrivateCells()
        closed = true
        payment.close()
    }
}

func productRegistryMountedInstances83(list: OwnedPluginRecordList, selected: (ProductPluginRecord) -> Bool): ProductMountedPluginInstances83 {
    try {
        let size = list.size
        if (size > (134217728 - 8192) / 256) { throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity") }
        let payment = list.deriveCopiedDataPayment(size * 256 + 8192)
        let captured = ProductMountedPluginInstances83(payment)
        try { captured.capture(list, selected); captured }
        catch (error: Exception) { captured.close(); throw error }
    } finally { list.close() }
}

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
        case PluginRegistryStaticReason.NoStaticReason => return productRegistryCopyText83(error.copyText(field), custody: custody)
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

// Only Product's two synchronous managed-import callers use this holder. The
// three namespace consumers perform paid lookups or a fenced rollback; they
// return independently paid Record/Error handles, never this private String.
class ProductImportNamespace83 <: OwnedRegistryResponseRetirement161 {
    private var custody: ?OwnedApplicationRegistryResponse161
    private var namespace: ?String = None<String>
    private var ownedOutcomeCaptured = false
    private var importFrameReturned = false
    private var unknown = false
    init(custody: OwnedApplicationRegistryResponse161) { this.custody = Some(custody) }
    func copyNamespace(descriptor: OwnedPluginPackageDescriptor): Unit {
        namespace = Some(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace),
            custody: custody))
    }
    private func invokeNamespaceFrame(
        action: (String) -> PluginRegistryResult<ProductPluginRecord>
    ): PluginRegistryResult<ProductPluginRecord> {
        action(namespace.getOrThrow())
    }
    func invokeImport(
        action: (String) -> PluginRegistryResult<ProductPluginRecord>
    ): PluginRegistryResult<ProductPluginRecord> {
        let result = invokeNamespaceFrame(action)
        ownedOutcomeCaptured = true
        result
    }
    func holdUnknown(): Unit {
        if (unknown) { return }
        unknown = true
        match (custody) { case Some(value) => productRegistryHoldUnknownResponse161(value); case None => () }
    }
    private func clearNamespaceFrame(): Unit { namespace = None<String> }
    func retireAfterImportFrameReturned(): Unit {
        if (!ownedOutcomeCaptured || unknown) { holdUnknown(); return }
        // The caller invokes this only after invokeImport and the entire real
        // import/activation/rollback frame returned its independently paid result.
        importFrameReturned = true
        clearNamespaceFrame()
        let actual = custody.getOrThrow()
        actual.markProducerReturned161()
        if (actual.closeAfterActualCopiedResponse161(this)) {
            custody = None<OwnedApplicationRegistryResponse161>
        } else { holdUnknown() }
    }
    public func copiedReferencesRetired(): Bool {
        ownedOutcomeCaptured && importFrameReturned && namespace.isNone() && !unknown
    }
}
// Only private Axyndra Native lifecycle frames consume these copies. Their
// fixed errors, mount(record) result and unmount Unit do not contain them. An
// opaque signature verifier may retain its manifest, so its loan stays paid.
class ProductNativeLifecycleCopies83 <: OwnedRegistryResponseRetirement161 {
    private var custody: ?OwnedApplicationRegistryResponse161
    private var texts: ?ArrayList<String> = Some(ArrayList<String>())
    private var arrays: ?ArrayList<Array<String>> = None<ArrayList<Array<String>>>
    private var nativeFrameReturned = false
    private var unknown = false
    init(custody: OwnedApplicationRegistryResponse161) { this.custody = Some(custody) }
    func text(value: PluginRegistryResult<OwnedRegistryUtf8>): String {
        let copied = productRegistryCopyText83(value, custody: custody)
        texts.getOrThrow().add(copied)
        copied
    }
    func capabilities(descriptor: OwnedPluginPackageDescriptor): Array<String> {
        let copied = productRegistryCapabilities83(descriptor, custody: custody)
        if (arrays.isNone()) { arrays = Some(ArrayList<Array<String>>()) }
        arrays.getOrThrow().add(copied)
        copied
    }
    func holdUnknown(): Unit {
        if (unknown) { return }
        unknown = true
        match (custody) { case Some(value) => productRegistryHoldUnknownResponse161(value); case None => () }
    }
    private func clearPrivateBackingsFrame(): Unit {
        let oldTexts = texts
        let oldArrays = arrays
        texts = None<ArrayList<String>>
        arrays = None<ArrayList<Array<String>>>
        match (oldTexts) { case Some(values) => values.clear(); case None => () }
        match (oldArrays) { case Some(values) => values.clear(); case None => () }
    }
    func retireAfterNativeFrameReturned(): Unit {
        if (unknown) { holdUnknown(); return }
        // Called only after the entire concrete activation/deactivation helper
        // has returned without exporting these copies. Host/Catalog data and
        // cleanup workers have independent owners; this is not their ACK.
        nativeFrameReturned = true
        clearPrivateBackingsFrame()
        let actual = custody.getOrThrow()
        actual.markProducerReturned161()
        if (actual.closeAfterActualCopiedResponse161(this)) {
            custody = None<OwnedApplicationRegistryResponse161>
        } else { holdUnknown() }
    }
    public func copiedReferencesRetired(): Bool {
        nativeFrameReturned && texts.isNone() && arrays.isNone() && !unknown
    }
}
func productRegistryNativeLifecycleCopies83(
    descriptor: OwnedPluginPackageDescriptor,
    copiedCells!: Int64 = 11
): ProductNativeLifecycleCopies83 {
    let peak = 65536
    let custody = OwnedApplicationRegistryResponse161(descriptor.deriveCopiedDataPayment(peak), peak)
    try {
        // At most nine scalar-copy cells plus two capability-array cells, or
        // eight scalar-copy cells plus three arrays on the verifier path.
        // Deactivation has exactly three namespace-copy cells.
        custody.prepayCollection161(copiedCells)
        // The descriptor/record belong to the caller; only new private copies
        // are adopted. Closing this holder cannot close that borrowed input.
        ProductNativeLifecycleCopies83(custody)
    } catch (error: Exception) { productRegistryHoldUnknownResponse161(custody); throw error }
}

func productRegistryImportNamespace83(descriptor: OwnedPluginPackageDescriptor): ProductImportNamespace83 {
    // This existing-bank header pays the holder and custody cells before they
    // allocate. copyText83 still pays its full unchanged byte/copy invoice before
    // allocating the Array or String. Neither payment is an authority grant.
    let peak = 65536
    let custody = OwnedApplicationRegistryResponse161(descriptor.deriveCopiedDataPayment(peak), peak)
    try {
        custody.keepDescriptor161(descriptor)
        let owner = ProductImportNamespace83(custody)
        owner.copyNamespace(descriptor)
        owner
    } catch (error: Exception) { productRegistryHoldUnknownResponse161(custody); throw error }
}

