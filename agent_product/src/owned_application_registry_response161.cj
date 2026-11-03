package agent_product

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import agent_plugin_registry.*
import std.collection.*
import std.sync.*

// A DATA carrier for the original maintenance command. The actual Registry
// loan is acquired by ApplicationSession before this carrier or parsing exists.
// Neither this carrier nor its consumer receipts confer execution authority.
public interface OwnedRegistryResponseRetirement161 {
    func copiedReferencesRetired(): Bool
}

public class OwnedApplicationRegistryResponse161 {
    private let lock = Mutex()
    private var header: ?LogicalJsonOwnerReservation
    private var headerPeak: Int64
    private var payments: ?ArrayList<LogicalJsonOwnerReservation> = Some(ArrayList<LogicalJsonOwnerReservation>())
    private var records: ?ArrayList<ProductPluginRecord> = Some(ArrayList<ProductPluginRecord>())
    private var descriptors: ?ArrayList<OwnedPluginPackageDescriptor> = Some(ArrayList<OwnedPluginPackageDescriptor>())
    private var errors: ?ArrayList<PluginRegistryOwnedError> = Some(ArrayList<PluginRegistryOwnedError>())
    private var errorLists: ?ArrayList<OwnedRegistryErrorList> = Some(ArrayList<OwnedRegistryErrorList>())
    private var textLists: ?ArrayList<OwnedRegistryTextList> = Some(ArrayList<OwnedRegistryTextList>())
    private var response: ?Result<ApplicationResponse> = None
    private var producerReturned = false
    private var borrowers: Int64 = 0
    private var closing = false
    private var closed = false

    init(header: LogicalJsonOwnerReservation, peak: Int64) {
        this.header = Some(header); this.headerPeak = peak
    }
    private func requireBuilding161(): Unit {
        if (producerReturned || closing || closed) {
            throw LogicalJsonPayloadError("registry response producer has retired")
        }
    }
    private func fundHeaders161(extra: Int64): Unit {
        if (extra < 0 || headerPeak > 134217728 - extra) {
            throw LogicalJsonPayloadError("registry response cannot fit the original shared capacity")
        }
        let wanted = headerPeak + extra
        header.getOrThrow().ensureRetainedPeak(wanted)
        headerPeak = wanted
    }
    func prepayCollection161(count: Int64, copiedBytes!: Int64 = 0): Unit {
        lock.lock()
        try {
            requireBuilding161()
            if (count < 0 || count > (134217728 - 8192) / 256 ||
                copiedBytes < 0 || copiedBytes > (134217728 - 8192 - count * 256) / 64) {
                throw LogicalJsonPayloadError("registry response cannot fit the original shared capacity")
            }
            fundHeaders161(count * 256 + copiedBytes * 64 + 8192)
        } finally { lock.unlock() }
    }
    func adoptPayment161(payment: LogicalJsonOwnerReservation): Unit {
        lock.lock()
        try {
            requireBuilding161(); fundHeaders161(512)
            payments.getOrThrow().add(payment)
        } finally { lock.unlock() }
    }
    func keepRecord161(record: ProductPluginRecord): Unit {
        lock.lock()
        try { requireBuilding161(); fundHeaders161(512); records.getOrThrow().add(record) }
        finally { lock.unlock() }
    }
    func keepDescriptor161(descriptor: OwnedPluginPackageDescriptor): Unit {
        lock.lock()
        try { requireBuilding161(); fundHeaders161(512); descriptors.getOrThrow().add(descriptor) }
        finally { lock.unlock() }
    }
    func keepError161(error: PluginRegistryOwnedError): Unit {
        lock.lock()
        try { requireBuilding161(); fundHeaders161(512); errors.getOrThrow().add(error) }
        finally { lock.unlock() }
    }
    func keepErrorList161(list: OwnedRegistryErrorList): Unit {
        lock.lock()
        try { requireBuilding161(); fundHeaders161(512); errorLists.getOrThrow().add(list) }
        finally { lock.unlock() }
    }
    func keepTextList161(list: OwnedRegistryTextList): Unit {
        lock.lock()
        try { requireBuilding161(); fundHeaders161(512); textLists.getOrThrow().add(list) }
        finally { lock.unlock() }
    }
    func installResponse161(result: Result<ApplicationResponse>): Unit {
        lock.lock()
        try { requireBuilding161(); response = Some(result) }
        finally { lock.unlock() }
    }
    // Called after the whole private parsing/business builder has returned.
    func markProducerReturned161(): Unit {
        lock.lock()
        try { requireBuilding161(); producerReturned = true }
        finally { lock.unlock() }
    }
    // Only scalar status leaves the actual CLI printing helper. A callback
    // returning is not a retirement receipt; this carrier stays paid until
    // the concrete consumer supplies its separate real-reference receipt.
    public func borrowForCli161(consume: (Result<ApplicationResponse>) -> (Bool, Int64)): (Bool, Int64) {
        lock.lock()
        try {
            if (!producerReturned || closing || closed || borrowers == Int64.Max) {
                throw LogicalJsonPayloadError("registry response is not available to its consumer")
            }
            borrowers++
        } finally { lock.unlock() }
        try { invokeConsumerFrame161(consume) }
        finally { lock.lock(); try { borrowers-- } finally { lock.unlock() } }
    }
    private func invokeConsumerFrame161(consume: (Result<ApplicationResponse>) -> (Bool, Int64)): (Bool, Int64) {
        consume(response.getOrThrow())
    }
    // The caller's actual layout/encoding cells must be paid before copying.
    public func prepayConsumerCopies161(invoice: Int64): Unit {
        lock.lock()
        try {
            if (!producerReturned || closing || closed || invoice < 0) {
                throw LogicalJsonPayloadError("registry response copy is unavailable")
            }
            fundHeaders161(invoice)
        } finally { lock.unlock() }
    }
    public func copiedResponseCopyInvoice161(json: Bool): Int64 {
        lock.lock()
        try {
            if (!producerReturned || closing || closed) {
                throw LogicalJsonPayloadError("registry response is unavailable")
            }
            match (response.getOrThrow()) {
                case Result.Ok(value) =>
                    // Local maintenance has no approval or Run snapshot. The
                    // original JSON formatter prints only its fixed result
                    // fields; it does not encode the diagnostic text.
                    if (json) { return 65536 }
                    checkedConsumerCopyInvoice161(value.text.size)
                case Result.Err(error) =>
                    if (error.code.size > 134217728 - error.message.size) {
                        throw LogicalJsonPayloadError("registry response cannot fit the original shared capacity")
                    }
                    checkedConsumerCopyInvoice161(error.code.size + error.message.size)
            }
        } finally { lock.unlock() }
    }
    // Only the actual TUI registration may keep raw response aliases; its
    // exact bound native Screen receipt is required for later retirement.
    public func borrowForTui167(consume: (Result<ApplicationResponse>) -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (!producerReturned || closing || closed || borrowers == Int64.Max) {
                throw LogicalJsonPayloadError("registry response is not available to its consumer") }
            borrowers++
        } finally { lock.unlock() }
        try { invokeTuiConsumerFrame167(consume) }
        finally { lock.lock(); try { borrowers-- } finally { lock.unlock() } }
    }
    private func invokeTuiConsumerFrame167(consume: (Result<ApplicationResponse>) -> Result<Unit>): Result<Unit> {
        consume(response.getOrThrow())
    }
    public func acquireTuiCopiedDisplay167(invoice: Int64): Result<LogicalJsonCopiedDisplayAllocation> {
        lock.lock()
        try {
            if (!producerReturned || closing || closed) {
                throw LogicalJsonPayloadError("registry response copy is unavailable") }
            header.getOrThrow().acquireCopiedDisplayAllocation(invoice)
        } finally { lock.unlock() }
    }
    public func copiedTuiResponseInvoice167(): Int64 {
        lock.lock()
        try {
            if (!producerReturned || closing || closed) {
                throw LogicalJsonPayloadError("registry response is unavailable") }
            match (response.getOrThrow()) {
                case Result.Ok(value) => checkedConsumerCopyInvoice161(value.text.size)
                case Result.Err(error) =>
                    var bytes = error.code.size
                    if (bytes > 134217728 - error.message.size - 16) {
                        throw LogicalJsonPayloadError("registry response cannot fit the original shared capacity") }
                    bytes += error.message.size + 16
                    // The existing describe formatter copies every original
                    // name/value. Count them before its String concatenation.
                    for (item in error.fields) {
                        if (item.name.size > 134217728 - item.value.size - 8 ||
                            bytes > 134217728 - item.name.size - item.value.size - 8) {
                            throw LogicalJsonPayloadError("registry response cannot fit the original shared capacity") }
                        bytes += item.name.size + item.value.size + 8 }
                    checkedConsumerCopyInvoice161(bytes)
            }
        } finally { lock.unlock() }
    }
    private func checkedConsumerCopyInvoice161(bytes: Int64): Int64 {
        // Use the original Registry copied-data envelope: UTF-8/validation,
        // simultaneous String/DOM/quoted JSON/println copies and paid cells.
        // This is a derived invoice in the same 128 MiB bank, not a new cap.
        if (bytes < 0 || bytes > (134217728 - 65536) / 64) {
            throw LogicalJsonPayloadError("registry response cannot fit the original shared capacity")
        }
        bytes * 64 + 65536
    }
    private func clearResponseAndOriginalOwnersFrame161(): Unit {
        response = None<Result<ApplicationResponse>>
        match (textLists) { case Some(values) => for (value in values) { value.close() }; values.clear(); textLists = None; case None => () }
        match (errorLists) { case Some(values) => for (value in values) { value.close() }; values.clear(); errorLists = None; case None => () }
        match (errors) { case Some(values) => for (value in values) { value.close() }; values.clear(); errors = None; case None => () }
        match (descriptors) { case Some(values) => for (value in values) { value.close() }; values.clear(); descriptors = None; case None => () }
        match (records) { case Some(values) => for (value in values) { value.close() }; values.clear(); records = None; case None => () }
    }
    private func closeCopiedPaymentsFrame161(): Unit {
        match (payments) { case Some(values) => for (value in values) { value.close() }; values.clear(); payments = None; case None => () }
    }
    public func closeAfterActualCopiedResponse161(retirement: OwnedRegistryResponseRetirement161): Bool {
        if (!retirement.copiedReferencesRetired()) { return false }
        lock.lock()
        try {
            if (closed) { return true }
            if (!producerReturned || borrowers != 0 || closing) { return false }
            closing = true
            // Each helper returns before the next kind of actual owner closes.
            clearResponseAndOriginalOwnersFrame161()
            closeCopiedPaymentsFrame161()
            match (header) { case Some(value) => header = None; value.close(); case None => () }
            closed = true
            true
        } finally { lock.unlock() }
    }
    // Only ApplicationSession's unsupported-route path uses this operation,
    // after its private builder returned false without publishing any response.
    func closeUnpublishedAfterBuilderReturned161(): Unit {
        lock.lock()
        try {
            if (!producerReturned || response.isSome() || borrowers != 0 || closing || closed) {
                throw LogicalJsonPayloadError("registry response has published references")
            }
            closing = true
            clearResponseAndOriginalOwnersFrame161(); closeCopiedPaymentsFrame161()
            match (header) { case Some(value) => header = None; value.close(); case None => () }
            closed = true
        } finally { lock.unlock() }
    }
}

func productRegistryAdoptCopied161(payment: LogicalJsonOwnerReservation,
    custody!: ?OwnedApplicationRegistryResponse161 = None,
    errors!: ?OwnedRegistryErrorList = None): Unit {
    match (custody) {
        case Some(scope) =>
            try {
                match (errors) { case Some(value) => scope.keepErrorList161(value); case None => () }
                scope.adoptPayment161(payment)
            } catch (error: Exception) {
                // No dependent copied allocation has started when adoption
                // fails. The source and response header still pay their cells.
                payment.close(); throw error
            }
        case None => productRegistryEscapedCopies83.adopt(payment, errors: errors)
    }
}

func productRegistryKeepRecord161(record: ProductPluginRecord, custody: ?OwnedApplicationRegistryResponse161): ProductPluginRecord {
    match (custody) {
        case Some(scope) =>
            try { scope.keepRecord161(record) }
            catch (error: LogicalJsonPayloadError) { record.close(); throw error }
        case None => ()
    }; record
}
func productRegistryKeepDescriptor161(descriptor: OwnedPluginPackageDescriptor, custody: ?OwnedApplicationRegistryResponse161): Unit {
    match (custody) {
        case Some(scope) =>
            try { scope.keepDescriptor161(descriptor) }
            catch (failure: LogicalJsonPayloadError) { descriptor.close(); throw failure }
        case None => ()
    }
}
func productRegistryKeepError161(error: PluginRegistryOwnedError, custody: ?OwnedApplicationRegistryResponse161): Unit {
    match (custody) {
        case Some(scope) =>
            try { scope.keepError161(error) }
            catch (failure: LogicalJsonPayloadError) { error.close(); throw failure }
        case None => ()
    }
}
func productRegistryKeepTextList161(list: OwnedRegistryTextList, custody: ?OwnedApplicationRegistryResponse161): Unit {
    match (custody) {
        case Some(scope) =>
            try { scope.keepTextList161(list) }
            catch (failure: LogicalJsonPayloadError) { list.close(); throw failure }
        case None => ()
    }
}

func productRegistryKeepErrorList161(list: OwnedRegistryErrorList, custody: ?OwnedApplicationRegistryResponse161): Unit {
    match (custody) {
        case Some(scope) =>
            try { scope.keepErrorList161(list) }
            catch (failure: LogicalJsonPayloadError) { list.close(); throw failure }
        case None => ()
    }
}
// The pre-filter borrows bytes and returns only a scalar. The original router
// performs all parsing, including quoted command tokens, after real payment.
func productRegistryStartsWithSlash161(input: String): Bool {
    let data = unsafe { input.rawData() }
    var index: Int64 = 0
    while (index < data.size && (data[index] == b' ' ||
        (data[index] >= 9u8 && data[index] <= 13u8))) { index++ }
    index < data.size && data[index] == b'/'
}

func productRegistryKeepOwnedError161(error: PluginRegistryOwnedError, custody: ?OwnedApplicationRegistryResponse161): PluginRegistryOwnedError {
    productRegistryKeepError161(error, custody); error
}
class ProductRegistryUnknownResponseNode161 {
    private let response: OwnedApplicationRegistryResponse161
    private let previous: ?ProductRegistryUnknownResponseNode161
    init(response: OwnedApplicationRegistryResponse161, previous: ?ProductRegistryUnknownResponseNode161) { this.response = response; this.previous = previous }
}
class ProductRegistryUnknownResponses161 {
    private let lock = Mutex()
    private var head: ?ProductRegistryUnknownResponseNode161 = None
    func hold(response: OwnedApplicationRegistryResponse161): Unit { lock.lock(); try { head = Some(ProductRegistryUnknownResponseNode161(response, head)) } finally { lock.unlock() } }
}
let productRegistryUnknownResponses161 = ProductRegistryUnknownResponses161()
func productRegistryHoldUnknownResponse161(response: OwnedApplicationRegistryResponse161): Unit { productRegistryUnknownResponses161.hold(response) }
