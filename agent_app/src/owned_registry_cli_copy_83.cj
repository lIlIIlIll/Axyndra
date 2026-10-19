package agent_app

import agent_domain.*
import agent_product.*
import std.sync.*
import yjson.*
import yjson_support.*

// These are DATA payments for copied maintenance/presentation values. They
// confer no registration, Source, effect, approval or I/O authority. Existing
// public response/history strings have no retirement contract, so their real
// copied backing remains paid rather than being refunded when a frame returns.
class AppRegistryEscapedCopyNode83 {
    private let payment: LogicalJsonOwnerReservation
    private let errors: ?OwnedRegistryErrorList
    private let previous: ?AppRegistryEscapedCopyNode83
    init(payment: LogicalJsonOwnerReservation, previous: ?AppRegistryEscapedCopyNode83, errors: ?OwnedRegistryErrorList) {
        this.payment = payment; this.previous = previous; this.errors = errors
    }
}

class AppRegistryEscapedCopyDebt83 {
    private let lock = Mutex()
    private var head: ?AppRegistryEscapedCopyNode83 = None<AppRegistryEscapedCopyNode83>
    func adopt(payment: LogicalJsonOwnerReservation, errors!: ?OwnedRegistryErrorList = None): Unit {
        lock.lock()
        try { head = Some(AppRegistryEscapedCopyNode83(payment, head, errors)) }
        finally { lock.unlock() }
    }
}

// No budget is created here. Every node below is prepaid from the actual
// incoming Registry byte loan in the original process aggregate.
let appRegistryEscapedCopies83 = AppRegistryEscapedCopyDebt83()

func appRegistryCopyInvoice83(bytes: Int64, extra: Int64): Int64 {
    if (bytes < 0 || extra < 0 || extra > 134217728 - 8192 ||
        bytes > (134217728 - 8192 - extra) / 64) {
        throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")
    }
    // Incoming bytes are already paid. This adds the actual copied byte
    // Array, UTF-8 String backing/validation scratch, returned aliases, and
    // the linked payment holder. Extra is for a caller's simultaneous cells.
    bytes * 64 + extra + 8192
}

func appRegistryCopyText83(result: PluginRegistryResult<OwnedRegistryUtf8>, extra!: Int64 = 0): String {
    let bytes = match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) =>
            throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")
    }
    try {
        let size = bytes.byteCount
        let payment = bytes.deriveCopiedDataPayment(appRegistryCopyInvoice83(size, extra))
        // Adopt before allocating or decoding any copied bytes. A failed copy
        // keeps this debt; no finally block pretends an escaped value retired.
        appRegistryEscapedCopies83.adopt(payment)
        let copied = Array<UInt8>(size, { index => bytes.byteAt(index) })
        String.fromUtf8(copied)
    } finally { bytes.close() }
}

func appRegistryErrorText83(error: PluginRegistryOwnedError, field: PluginRegistryErrorText): String {
    let message = match (error.staticReason) {
        case PluginRegistryStaticReason.MetadataCapacity => "registry metadata cannot fit the original shared capacity"
        case PluginRegistryStaticReason.ExecutionNotCurrent => "installed execution pin is not current"
        case PluginRegistryStaticReason.InstalledRecordAbsent => "installed record is absent"
        case PluginRegistryStaticReason.ComponentAliasInvalid => "initial context configuration or its exact installed binding is unavailable"
        case PluginRegistryStaticReason.None => return appRegistryCopyText83(error.copyText(field))
    }
    match (field) { case PluginRegistryErrorText.Message => message; case PluginRegistryErrorText.Source => ""; case PluginRegistryErrorText.Field => "" }
}

func appRegistryRecords83(list: OwnedPluginRecordList): Array<ProductPluginRecord> {
    try {
        let size = list.size
        if (size == 0) { return [] }
        if (size > (134217728 - 8192) / 256) { throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity") }
        let payment = list.deriveCopiedDataPayment(size * 256 + 8192)
        appRegistryEscapedCopies83.adopt(payment)
        Array<ProductPluginRecord>(size, { index => list.take(index) })
    } finally { list.close() }
}
