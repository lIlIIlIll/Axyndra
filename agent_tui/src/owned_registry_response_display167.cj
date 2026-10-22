package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import std.sync.Mutex

// A Root-only carrier stores its actual serializer owner at construction. The
// terminal-side constructor leaves it absent; a remote or caller-supplied
// producer identity cannot manufacture the physical Screen retirement path.
public interface OwnedTuiSerializerLifetime180 {
    func rootSerializerReferencesRetired180(actualProducer: Object): Bool
}
// DATA copied from the real maintenance response. No tool event, Source,
// execution capability or new allocation bank is created by this carrier.
public class OwnedTuiRegistryResponseDisplay167 <: OwnedTuiCardDisplay113 {
    private let lock = Mutex()
    private let producer: Object
    private let serializerLifetime180: ?OwnedTuiSerializerLifetime180
    private var allocation: ?LogicalJsonCopiedDisplayAllocation
    private var renderer: ?LogicalJsonCopiedDisplayAllocation = None
    private let peaks = Array<Int64>(20, repeat: 0)
    private let projectionInvoice: Int64
    private var queuePeak: Int64 = 0
    private var cardId = ""
    private var retired = false

    public init(producer: Object, allocation: LogicalJsonCopiedDisplayAllocation, invoice: Int64,
        serializerLifetime180!: ?OwnedTuiSerializerLifetime180 = None) {
        this.producer = producer; this.allocation = Some(allocation); this.projectionInvoice = invoice
        this.serializerLifetime180 = serializerLifetime180
    }
    public func prepareQueueAndScreenCopies167(invoice: Int64): Result<Unit> {
        lock.lock()
        try {
            if (retired || invoice < 0) { return ownedTuiDisplayError("display.registry_unavailable") }
            let wanted = max(queuePeak, invoice)
            var total = ownedTuiInvoiceAdd(projectionInvoice, wanted)
            for (value in peaks) { total = ownedTuiInvoiceAdd(total, value) }
            match (allocation.getOrThrow().ensureCopiedDisplayRetainedPeak(total)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => queuePeak = wanted; Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    public func noteUiCardIdentity167(value: String): Unit {
        lock.lock(); try { cardId = value } finally { lock.unlock() }
    }
    public func matchesUiCard(value: String): Bool {
        lock.lock(); try { cardId != "" && cardId == value } finally { lock.unlock() }
    }
    public func prepareCardRenderCopies113(component: Int64, invoice: Int64, occurrence: Int64): Result<Unit> {
        lock.lock()
        try {
            if (retired || invoice < 0 || component < 0 || component > 4 || occurrence < 0 || occurrence > 3) {
                return ownedTuiDisplayError("display.registry_unavailable") }
            if (renderer.isNone()) {
                match (allocation.getOrThrow().retainCopiedDisplayAllocation()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(value) => renderer = Some(value) }
            }
            let index = component * 4 + occurrence
            let candidate = max(peaks[index], ownedTuiInvoiceMultiply(invoice, 2))
            var total = ownedTuiInvoiceAdd(projectionInvoice, queuePeak)
            for (i in 0..peaks.size) {
                total = ownedTuiInvoiceAdd(total, if (i == index) { candidate } else { peaks[i] }) }
            match (allocation.getOrThrow().ensureCopiedDisplayRetainedPeak(total)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => peaks[index] = candidate; Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    public func closeAfterWholeScreenRetirement167(actual: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (!actual.acknowledgesRegistryProducer167(producer)) {
            return ownedTuiDisplayError("display.registry_screen_retirement_unknown") }
        lock.lock()
        try {
            if (retired) { return Result<Unit>.Ok(()) }
            // Actual mailbox/card/document/cache/history/raster fields and
            // output/helper frames already ended in the bound Screen receipt.
            clearLookupDataFrame167()
            match (renderer) {
                case Some(value) => match (value.closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => renderer = None }
                case None => () }
            match (allocation.getOrThrow().closeAfterCopiedDisplayRetirement()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => allocation = None; retired = true; Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    // Only non-UI serializer copies use this path. Any actual card identity
    // or renderer share still requires its real bound Screen receipt.
    public func closeAfterUnprojectedSerialization180(actualProducer: Object): Result<Unit> {
        if (!refEq(actualProducer, producer)) { return ownedTuiDisplayError("display.registry_producer_mismatch") }
        match (serializerLifetime180) {
            case Some(actual) => if (!actual.rootSerializerReferencesRetired180(actualProducer)) {
                return ownedTuiDisplayError("display.serializer_retirement_unknown") }
            case None => return ownedTuiDisplayError("display.registry_screen_retirement_required") }
        lock.lock()
        try {
            if (retired) { return Result<Unit>.Ok(()) }
            if (cardId != "" || renderer.isSome()) { return ownedTuiDisplayError("display.registry_screen_retirement_required") }
            match (allocation.getOrThrow().closeAfterCopiedDisplayRetirement()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => allocation = None; retired = true; Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    private func clearLookupDataFrame167(): Unit { cardId = "" }
}
