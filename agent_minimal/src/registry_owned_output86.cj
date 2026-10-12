package agent_minimal

import agent_domain.*
import agent_plugin_registry.*
import yjson.*
import yjson_support.*
import std.collection.*

// Only this synchronous CLI frame sees copied text/DOM. Every allocation is
// prepaid from the original Registry custody before it is constructed. No
// parsed String/Array/DOM or callback leaves the frame for a caller to retain.
private class MinimalRegistryOutput86 {
    private let header: LogicalJsonOwnerReservation
    private var payments: ?ArrayList<LogicalJsonOwnerReservation> = Some(ArrayList<LogicalJsonOwnerReservation>())
    private var owners: ?ArrayList<OwnedRegistryUtf8> = Some(ArrayList<OwnedRegistryUtf8>())
    private var bytes: ?ArrayList<Array<UInt8>> = Some(ArrayList<Array<UInt8>>())
    private var texts: ?ArrayList<String> = Some(ArrayList<String>())
    private var documents: ?ArrayList<AgentValue> = Some(ArrayList<AgentValue>())
    private var output: ?String = None
    init(header: LogicalJsonOwnerReservation) { this.header = header }

    func copyText(raw: OwnedRegistryUtf8): String {
        owners.getOrThrow().add(raw)
        // Numeric observation creates no copied document data. The SUM pays
        // byte/String/parser/constructor/output copies and every wire node.
        let payment = raw.deriveCopiedDataPayment(minimalRegistryCopyInvoice86(raw))
        payments.getOrThrow().add(payment)
        let value = Array<UInt8>(raw.byteCount, repeat: 0u8)
        bytes.getOrThrow().add(value)
        for (index in 0..raw.byteCount) { value[index] = raw.byteAt(index) }
        let source = String.fromUtf8(value)
        texts.getOrThrow().add(source)
        source
    }
    func copyJson(raw: OwnedRegistryUtf8): AgentValue {
        let source = copyText(raw)
        let document = parseUnifiedJson(source, maxBytes: LOGICAL_JSON_HARD_BYTES)
        documents.getOrThrow().add(document)
        document
    }
    func printValue(value: AgentValue): Unit {
        documents.getOrThrow().add(value)
        output = Some(stringifyUnifiedJson(value))
        println(output.getOrThrow())
    }
    // Called only after the complete typed frame below has RETURNED, including
    // its anonymous bounded exception catch. None drops each actual container,
    // including its backing capacity. Written stdout bytes do not expose
    // aliases to these private Cangjie String/Array/DOM objects.
    func closeAfterFrameReturned(): Unit {
        output = None
        documents = None; texts = None; bytes = None
        closeReturnedOwners()
        closeReturnedPayments()
        // The detached owner/payment container helper frames have RETURNED.
        // The prepaid header covers their handles/cells until this point.
        header.close()
    }
    private func closeReturnedOwners(): Unit {
        let held = owners
        owners = None
        match (held) {
            case Some(values) => for (owner in values) { owner.close() }
            case None => ()
        }
    }
    private func closeReturnedPayments(): Unit {
        let held = payments
        payments = None
        match (held) {
            case Some(values) => for (payment in values) { payment.close() }
            case None => ()
        }
    }
}

private func minimalRegistryAdd86(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > 134217728 - right) {
        throw LogicalJsonPayloadError("CLI metadata copy exceeds the original aggregate")
    }
    left + right
}

private func minimalRegistryCopyInvoice86(raw: OwnedRegistryUtf8): Int64 {
    var total: Int64 = 65536
    var quoted = false; var escaped = false
    for (index in 0..raw.byteCount) {
        let byte = raw.byteAt(index)
        total = minimalRegistryAdd86(total, 32)
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == b'\\') { escaped = true }
            else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') {
            quoted = true; total = minimalRegistryAdd86(total, 2048)
        } else if (byte == b'{' || byte == b'[' || byte == b':' || byte == b',') {
            total = minimalRegistryAdd86(total, 2048)
        }
    }
    // Text copies need not be JSON. A complete byte observation is the bound;
    // an unfinished quote can only increase the charge, never bypass it.
    total
}

private func minimalRegistryStaticMessage86(reason: PluginRegistryStaticReason): String {
    match (reason) {
        case PluginRegistryStaticReason.MetadataCapacity => "registry metadata cannot fit the original shared capacity"
        case PluginRegistryStaticReason.ExecutionNotCurrent => "installed execution pin is not current"
        case PluginRegistryStaticReason.InstalledRecordAbsent => "installed record is absent"
        case PluginRegistryStaticReason.ComponentAliasInvalid => "initial context configuration or its exact installed binding is unavailable"
        case PluginRegistryStaticReason.None => throw IllegalArgumentException("a dynamic error needs its owned copy")
    }
}

private func minimalRegistryDynamicError86(error: PluginRegistryOwnedError): Bool {
    match (error.staticReason) { case PluginRegistryStaticReason.None => true; case _ => false }
}

private func minimalRegistryCopy86(result: PluginRegistryResult<OwnedRegistryUtf8>): OwnedRegistryUtf8 {
    match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => error.close(); throw LogicalJsonPayloadError("CLI metadata copy is unavailable")
    }
}

private func minimalRegistryRecordValue86(value: AgentValue): AgentValue {
    objectValue([
        ValueField("id", value.field("id").getOrThrow()), ValueField("namespace", value.field("namespace").getOrThrow()),
        ValueField("version", value.field("version").getOrThrow()), ValueField("root", value.field("root").getOrThrow()),
        ValueField("content_digest", value.field("content_digest").getOrThrow()), ValueField("scope", value.field("scope").getOrThrow()),
        ValueField("enabled", value.field("enabled").getOrThrow()), ValueField("explicitly_disabled", value.field("explicitly_disabled").getOrThrow()),
        ValueField("source_kind", value.field("source_kind").getOrThrow()), ValueField("locator", value.field("locator").getOrThrow()),
        ValueField("version_lock", value.field("version_lock").getOrThrow()), ValueField("revision_lock", value.field("revision").getOrThrow())])
}

private func minimalRegistryRecordFrame86(actual: MinimalRegistryOutput86, record: ProductPluginRecord): Bool {
    try {
        let value = actual.copyJson(minimalRegistryCopy86(record.copyJson()))
        actual.printValue(objectValue([ValueField("ok", boolValue(true)),
            ValueField("record", minimalRegistryRecordValue86(value))]))
        true
    } catch (_: Exception) { false }
}

func minimalRegistryRecordResult86(result: PluginRegistryResult<ProductPluginRecord>): Int64 {
    match (result) {
        case PluginRegistryResult.Err(error) => minimalRegistryError86(error)
        case PluginRegistryResult.Ok(record) =>
            try {
                let header = record.descriptor.deriveCopiedDataPayment(65536)
                let actual = MinimalRegistryOutput86(header)
                let printed = minimalRegistryRecordFrame86(actual, record)
                actual.closeAfterFrameReturned()
                if (printed) { 0 } else { minimalRegistryCapacity86() }
            } catch (_: LogicalJsonPayloadError) { minimalRegistryCapacity86() }
            finally { record.close() }
    }
}

private func minimalRegistryRecordsFrame86(actual: MinimalRegistryOutput86, records: OwnedPluginRecordList): Bool {
    try {
        let values = ArrayList<AgentValue>()
        for (index in 0..records.size) {
            let record = records.at(index)
            let value = actual.copyJson(minimalRegistryCopy86(record.copyJson()))
            values.add(minimalRegistryRecordValue86(value))
        }
        actual.printValue(objectValue([ValueField("ok", boolValue(true)), ValueField("records", listValue(values.toArray()))]))
        true
    } catch (_: Exception) { false }
}

func minimalRegistryRecords86(records: OwnedPluginRecordList): Int64 {
    try {
        if (records.isEmpty()) { println("{\"ok\":true,\"records\":[]}"); return 0 }
        let header = records.deriveCopiedDataPayment(minimalRegistryAdd86(65536, records.size * 8192))
        let actual = MinimalRegistryOutput86(header)
        let printed = minimalRegistryRecordsFrame86(actual, records)
        actual.closeAfterFrameReturned()
        if (printed) { 0 } else { minimalRegistryCapacity86() }
    } catch (_: LogicalJsonPayloadError) { minimalRegistryCapacity86() }
    finally { records.close() }
}

private func minimalRegistryDescriptorFrame86(actual: MinimalRegistryOutput86, descriptor: OwnedPluginPackageDescriptor): Bool {
    try {
        let value = actual.copyJson(minimalRegistryCopy86(descriptor.copyCompleteJson()))
        actual.printValue(objectValue([ValueField("ok", boolValue(true)),
            ValueField("namespace", value.field("namespace").getOrThrow()), ValueField("version", value.field("version").getOrThrow()),
            ValueField("content_digest", value.field("content_digest").getOrThrow())]))
        true
    } catch (_: Exception) { false }
}

func minimalRegistryDescriptor86(descriptor: OwnedPluginPackageDescriptor): Int64 {
    try {
        let header = descriptor.deriveCopiedDataPayment(65536)
        let actual = MinimalRegistryOutput86(header)
        let printed = minimalRegistryDescriptorFrame86(actual, descriptor)
        actual.closeAfterFrameReturned()
        if (printed) { 0 } else { minimalRegistryCapacity86() }
    } catch (_: LogicalJsonPayloadError) { minimalRegistryCapacity86() }
    finally { descriptor.close() }
}

private func minimalRegistryDeletedFrame86(actual: MinimalRegistryOutput86, raw: OwnedRegistryUtf8): Bool {
    try {
        let value = actual.copyJson(raw)
        actual.printValue(objectValue([ValueField("ok", boolValue(true)), ValueField("deleted", value)]))
        true
    } catch (_: Exception) { false }
}

func minimalRegistryDeleted86(paths: OwnedRegistryTextList): Int64 {
    try {
        if (paths.isEmpty()) { println("{\"ok\":true,\"deleted\":[]}"); return 0 }
        let raw = match (paths.copyJson()) {
            case PluginRegistryResult.Err(error) => return minimalRegistryError86(error)
            case PluginRegistryResult.Ok(value) => value }
        try {
            let header = raw.deriveCopiedDataPayment(65536)
            let actual = MinimalRegistryOutput86(header)
            let printed = minimalRegistryDeletedFrame86(actual, raw)
            actual.closeAfterFrameReturned()
            if (printed) { 0 } else { minimalRegistryCapacity86() }
        } catch (_: LogicalJsonPayloadError) { minimalRegistryCapacity86() }
        finally { raw.close() }
    } finally { paths.close() }
}

private func minimalRegistryErrorFrame86(actual: MinimalRegistryOutput86, error: PluginRegistryOwnedError,
    raw: OwnedRegistryUtf8): Bool {
    try {
        let message = actual.copyText(raw)
        actual.printValue(objectValue([ValueField("ok", boolValue(false)),
            ValueField("code", textValue(error.code)), ValueField("message", textValue(message))]))
        true
    } catch (_: Exception) { false }
}

func minimalRegistryError86(error: PluginRegistryOwnedError): Int64 {
    try {
        if (!minimalRegistryDynamicError86(error)) {
            return minimalError(error.code, minimalRegistryStaticMessage86(error.staticReason))
        }
        let raw = match (error.copyText(PluginRegistryErrorText.Message)) {
            case PluginRegistryResult.Err(failure) => failure.close(); return minimalRegistryCapacity86()
            case PluginRegistryResult.Ok(value) => value }
        try {
            let header = raw.deriveCopiedDataPayment(65536)
            let actual = MinimalRegistryOutput86(header)
            let printed = minimalRegistryErrorFrame86(actual, error, raw)
            actual.closeAfterFrameReturned()
            if (!printed) { return minimalRegistryCapacity86() }
            2
        } catch (_: LogicalJsonPayloadError) { minimalRegistryCapacity86() }
        finally { raw.close() }
    } finally { error.close() }
}

private func minimalRegistryDiagnosticsFrame86(actual: MinimalRegistryOutput86, errors: OwnedRegistryErrorList): Bool {
    try {
        let values = ArrayList<AgentValue>()
        for (index in 0..errors.size) {
            let error = errors.at(index)
            let message = if (minimalRegistryDynamicError86(error)) {
                actual.copyText(minimalRegistryCopy86(error.copyText(PluginRegistryErrorText.Message)))
            } else { minimalRegistryStaticMessage86(error.staticReason) }
            values.add(objectValue([ValueField("code", textValue(error.code)), ValueField("message", textValue(message))]))
        }
        actual.printValue(objectValue([ValueField("ok", boolValue(errors.isEmpty())),
            ValueField("diagnostics", listValue(values.toArray()))]))
        true
    } catch (_: Exception) { false }
}

func minimalRegistryDiagnostics86(errors: OwnedRegistryErrorList): Int64 {
    try {
        if (errors.isEmpty()) { println("{\"ok\":true,\"diagnostics\":[]}"); return 0 }
        let header = errors.deriveCopiedDataPayment(minimalRegistryAdd86(65536, errors.size * 8192))
        let actual = MinimalRegistryOutput86(header)
        let printed = minimalRegistryDiagnosticsFrame86(actual, errors)
        actual.closeAfterFrameReturned()
        if (printed) { 2 } else { minimalRegistryCapacity86() }
    } catch (_: LogicalJsonPayloadError) { minimalRegistryCapacity86() }
    finally { errors.close() }
}

private func minimalRegistryCapacity86(): Int64 {
    minimalError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity")
}
