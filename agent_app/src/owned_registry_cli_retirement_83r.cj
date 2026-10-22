package agent_app

import agent_domain.*
import agent_product.*
import std.collection.*
import std.env.*
import std.sync.*
import yjson_support.*

// This carrier serves synchronous metadata-printing CLI entrypoints.
// The complete private printing frame returns an exit status; no copied text,
// byte array, error or callback is returned to an observer or response history.
private class AppRegistryCliPrintCopy83r {
    private let header: LogicalJsonOwnerReservation
    private var payments: ?ArrayList<LogicalJsonOwnerReservation> = Some(ArrayList<LogicalJsonOwnerReservation>())
    private var owners: ?ArrayList<OwnedRegistryUtf8> = Some(ArrayList<OwnedRegistryUtf8>())
    private var bytes: ?ArrayList<Array<UInt8>> = Some(ArrayList<Array<UInt8>>())
    private var texts: ?ArrayList<String> = Some(ArrayList<String>())
    init(header: LogicalJsonOwnerReservation) { this.header = header }

    func copyText(result: PluginRegistryResult<OwnedRegistryUtf8>): String {
        let raw = match (result) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                error.close()
                throw LogicalJsonPayloadError("CLI metadata copy is unavailable")
        }
        owners.getOrThrow().add(raw)
        let payment = raw.deriveCopiedDataPayment(appRegistryCopyInvoice83(raw.byteCount, 0))
        payments.getOrThrow().add(payment)
        let value = Array<UInt8>(raw.byteCount, repeat: 0u8)
        bytes.getOrThrow().add(value)
        for (index in 0..raw.byteCount) { value[index] = raw.byteAt(index) }
        let text = String.fromUtf8(value)
        texts.getOrThrow().add(text)
        text
    }
    func closeAfterPrintingFrameReturned(): Unit {
        // The real String/AgentError/concatenation/println lexical frame has
        // returned. Drop the actual containers, including backing capacity.
        texts = None; bytes = None
        closeReturnedOwners()
        closeReturnedPayments()
        // Handle containers survive only in the two paid helper frames. Both
        // have returned before the last wrapper/header payment can retire.
        header.close()
    }
    private func closeReturnedOwners(): Unit {
        let held = owners
        owners = None
        match (held) {
            case Some(values) => for (value in values) { value.close() }
            case None => ()
        }
    }
    private func closeReturnedPayments(): Unit {
        let held = payments
        payments = None
        match (held) {
            case Some(values) => for (value in values) { value.close() }
            case None => ()
        }
    }
}

private func appRegistryCliPrintRecordFrame83r(actual: AppRegistryCliPrintCopy83r,
    record: ProductPluginRecord, action: String, io!: CliIo180 = consoleCliIo180): Bool {
    try {
        appWriteRegistryLineChecked181(action + " " + actual.copyText(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "@" +
            actual.copyText(record.descriptor.copyText(PluginDescriptorText.Version)) + " (" + pluginCliScope(record.scope) + ", " +
            (if (record.enabled) { "enabled" } else { "disabled" }) + ").", io: io)
        io.flush()
        true
    } catch (_: Exception) { false }
}

func appRegistryCliPrintRecord83r(record: ProductPluginRecord, action: String, io!: CliIo180 = consoleCliIo180): Int64 {
    try {
        let header = record.descriptor.deriveCopiedDataPayment(65536)
        let actual = AppRegistryCliPrintCopy83r(header)
        let printed = appRegistryCliPrintRecordFrame83r(actual, record, action, io: io)
        if (printed) { actual.closeAfterPrintingFrameReturned() }
        else { appRegistryCliHoldIncompletePrint158(actual) }
        if (printed) { 0 } else { appRegistryCliPrintCapacity83r(io: io) }
    } catch (_: LogicalJsonPayloadError) { appRegistryCliPrintCapacity83r(io: io) }
    finally { record.close() }
}

private func appRegistryCliPrintErrorFrame83r(actual: AppRegistryCliPrintCopy83r,
    error: PluginRegistryOwnedError, raw: OwnedRegistryUtf8, io!: CliIo180 = consoleCliIo180): Bool {
    try {
        appWriteRegistryLineChecked181("error[" + error.code + "]: " +
            actual.copyText(PluginRegistryResult.Ok(raw)), io: io)
        io.flush()
        true
    } catch (_: Exception) { false }
}

func appRegistryCliPrintError83r(error: PluginRegistryOwnedError, io!: CliIo180 = consoleCliIo180): Int64 {
    match (error.staticReason) {
        case PluginRegistryStaticReason.NoStaticReason => ()
        case _ =>
            printError(AgentError(AgentErrorKind.InvalidInput, error.code,
                appRegistryErrorText83(error, PluginRegistryErrorText.Message)), io: io)
            return 1
    }
    let raw = match (error.copyText(PluginRegistryErrorText.Message)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(failure) => failure.close(); return appRegistryCliPrintCapacity83r(io: io)
    }
    try {
        let header = raw.deriveCopiedDataPayment(65536)
        let actual = AppRegistryCliPrintCopy83r(header)
        let printed = appRegistryCliPrintErrorFrame83r(actual, error, raw, io: io)
        if (printed) { actual.closeAfterPrintingFrameReturned() }
        else { appRegistryCliHoldIncompletePrint158(actual) }
        if (printed) { 1 } else { appRegistryCliPrintCapacity83r(io: io) }
    } catch (_: LogicalJsonPayloadError) { appRegistryCliPrintCapacity83r(io: io) }
    finally { raw.close() }
    // The incoming doctor error may be borrowed from its actual owned list.
    // This text-printing consumer retires only its independent copied data.
}

private func appRegistryCliPrintCapacity83r(io!: CliIo180 = consoleCliIo180): Int64 {
    printError(AgentError(AgentErrorKind.InvalidInput, "plugin.registry_metadata_capacity",
        "registry metadata cannot fit the original shared capacity"), io: io)
    1
}


// The incoming list and every independent UTF-8 loan remain owned until the
// complete rendering/write/flush frame returns. The function returns only an
// exit status; no JSON value, record view, copied String or byte Array escapes.
private func appRegistryCliRecordValue158(actual: AppRegistryCliPrintCopy83r,
    record: ProductPluginRecord): AgentValue {
    objectValue([
        ValueField("id", textValue(actual.copyText(record.descriptor.copyText(PluginDescriptorText.Id)))),
        ValueField("namespace", textValue(actual.copyText(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("version", textValue(actual.copyText(record.descriptor.copyText(PluginDescriptorText.Version)))),
        ValueField("enabled", boolValue(record.enabled)),
        ValueField("scope", textValue(pluginCliScope(record.scope))),
        ValueField("content_digest", textValue(actual.copyText(record.copyText(PluginRecordText.ContentLock)))),
        ValueField("source_kind", textValue(match (record.sourceKind) {
            case PluginSourceKind.Local => "local"
            case PluginSourceKind.Git => "git"
            case PluginSourceKind.Npm => "npm"
        })),
        ValueField("locator", textValue(actual.copyText(record.copyText(PluginRecordText.Locator))))
    ])
}

private func appRegistryCliPrintListFrame158(actual: AppRegistryCliPrintCopy83r,
    records: OwnedPluginRecordList, json: Bool, io!: CliIo180 = consoleCliIo180): Bool {
    try {
        if (json) {
            let values = ArrayList<AgentValue>()
            for (index in 0..records.size) {
                values.add(appRegistryCliRecordValue158(actual, records.at(index)))
            }
            appWriteRegistryLineChecked181(stringifyUnifiedJson(listValue(values.toArray())), io: io)
        } else {
            appWriteRegistryLineChecked181("Plugins:", io: io)
            if (records.isEmpty()) { appWriteRegistryLineChecked181("No plugins are imported.", io: io) }
            for (index in 0..records.size) {
                let record = records.at(index)
                appWriteRegistryLineChecked181((if (record.enabled) { "[on] " } else { "[off] " }) +
                    actual.copyText(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "@" +
                    actual.copyText(record.descriptor.copyText(PluginDescriptorText.Version)) + " · " +
                    pluginCliScope(record.scope) + " · " + actual.copyText(record.copyText(PluginRecordText.ContentLock)), io: io)
            }
        }
        io.flush()
        true
    } catch (_: Exception) { false }
}

func appRegistryCliPrintList158(records: OwnedPluginRecordList, json: Bool, io!: CliIo180 = consoleCliIo180): Int64 {
    try {
        let count = records.size
        if (count < 0 || count > (134217728 - 65536) / 8192) {
            return appRegistryCliPrintCapacity83r(io: io)
        }
        // Pay the actual carrier containers, 8-field record DOM/entry arrays,
        // list DOM and simultaneous renderer cells before any such allocation.
        // Each copied text separately prepays its full 64*N byte/UTF-8/writer
        // peak, including escaping, using that very Registry owner's bank.
        let header = records.deriveCopiedDataPayment(65536 + count * 8192)
        let actual = AppRegistryCliPrintCopy83r(header)
        let printed = appRegistryCliPrintListFrame158(actual, records, json, io: io)
        if (printed) { actual.closeAfterPrintingFrameReturned() }
        else { appRegistryCliHoldIncompletePrint158(actual) }
        if (printed) { 0 } else { appRegistryCliPrintCapacity83r(io: io) }
    } catch (_: LogicalJsonPayloadError) { appRegistryCliPrintCapacity83r(io: io) }
    finally { records.close() }
}

// A failed/partial output is never a consumption acknowledgement. Its real
// copied Strings, arrays and payments remain retained under the original paid
// carrier. This synchronous maintenance command exits with an error; no normal
// successful path appends here. A live process cannot claim Root retirement
// while any incomplete output remains. No timeout/GC/frame-return refunds it.
private class AppRegistryCliIncompletePrint158 {
    private let actual: AppRegistryCliPrintCopy83r
    private let previous: ?AppRegistryCliIncompletePrint158
    init(actual: AppRegistryCliPrintCopy83r, previous: ?AppRegistryCliIncompletePrint158) {
        this.actual = actual; this.previous = previous
    }
}
private let appRegistryCliIncompletePrintLock158 = Mutex()
private var appRegistryCliIncompletePrintHead158: ?AppRegistryCliIncompletePrint158 = None
private func appRegistryCliHoldIncompletePrint158(actual: AppRegistryCliPrintCopy83r): Unit {
    // The original 65536-byte header was reserved before the carrier and also
    // covers this failure-holder node. No fresh reservation or pool is made.
    appRegistryCliIncompletePrintLock158.lock()
    try {
        appRegistryCliIncompletePrintHead158 = Some(AppRegistryCliIncompletePrint158(actual,
            appRegistryCliIncompletePrintHead158))
    } finally { appRegistryCliIncompletePrintLock158.unlock() }
}

