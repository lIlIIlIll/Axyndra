package agent_tui

import core.*

// Installed only from a real already-held copied display owner. Card ids are
// lookup metadata and cannot create payment, Source, or tool capability.
class OwnedTuiDocumentPayment <: RetainedDocumentPayment {
    private let display: OwnedTuiCardDisplay113
    private let occurrence: Int64
    init(display: OwnedTuiCardDisplay113, occurrence!: Int64 = 0) {
        this.display = display; this.occurrence = occurrence }
    public func prepareLayoutCopies(invoice: Int64): Bool {
        display.prepareCardRenderCopies113(1, invoice, occurrence).isOk() }
    public func prepareHistoryCopies(invoice: Int64): Bool {
        display.prepareCardRenderCopies113(2, invoice, occurrence).isOk() }
    public func prepareRasterCopies(invoice: Int64): Bool {
        display.prepareCardRenderCopies113(3, invoice, occurrence).isOk() }
}

func ownedTuiInvoiceAdd(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > Int64.Max - right) { throw Exception("display.invoice_overflow") }
    left + right
}
func ownedTuiInvoiceMultiply(count: Int64, unit: Int64): Int64 {
    if (count < 0 || unit < 0) { throw Exception("display.invoice_overflow") }
    if (unit == 0) { return 0 }
    if (count > Int64.Max / unit) { throw Exception("display.invoice_overflow") }
    count * unit
}
func ownedTuiCardRetainedBytes(card: UiCard): Int64 {
    var bytes = ownedTuiInvoiceAdd(card.id.size, card.title.size)
    bytes = ownedTuiInvoiceAdd(bytes, card.body.size)
    bytes = ownedTuiInvoiceAdd(bytes, card.footer.size)
    bytes = ownedTuiInvoiceAdd(bytes, card.state.size)
    bytes = ownedTuiInvoiceAdd(bytes, card.toolName.size)
    bytes = ownedTuiInvoiceAdd(bytes, card.toolArguments.size)
    bytes = ownedTuiInvoiceAdd(bytes, card.toolCallId.size)
    bytes = ownedTuiInvoiceAdd(bytes, card.toolOutput.size)
    ownedTuiInvoiceAdd(bytes, card.toolResult.size)
}
func ownedTuiDocumentConstructionInvoice(bytes: Int64, oldCopies: Int64): Int64 {
    // Dense command grapheme spans/search matches/read line numbers can create
    // several line/span/array cells per original byte. This also covers the
    // exact existing redactor/parser/concat scratch, not only displayed text.
    ownedTuiInvoiceAdd(ownedTuiInvoiceAdd(65536, oldCopies), ownedTuiInvoiceMultiply(bytes, 2048))
}
func ownedTuiFrameConstructionInvoice(width: Int64, height: Int64, completeCopiedBytes: Int64): Int64 {
    // Old front/back, new Buffer cells, DirtyCellSnapshot arrays/capacity,
    // old/new diff spans, raw history builders, ANSI builders/toString and
    // synchronous output backing coexist. Unicode symbol bytes are counted
    // from the complete actual copied card data, never cells times four.
    let cells = ownedTuiInvoiceMultiply(max(0, width), max(0, height))
    ownedTuiInvoiceAdd(65536, ownedTuiInvoiceAdd(ownedTuiInvoiceMultiply(cells, 4096),
        ownedTuiInvoiceMultiply(completeCopiedBytes, 256)))
}

func ownedTuiDocumentTextBytes(document: Document): Int64 {
    var bytes: Int64 = 0
    for (line in document.lines) {
        bytes = ownedTuiInvoiceAdd(bytes, 64)
        for (span in line.spans) { bytes = ownedTuiInvoiceAdd(bytes, span.text.size) }
    }
    bytes
}

class OwnedTuiDocumentPaymentGroup <: RetainedDocumentPayment {
    private let payments: Array<RetainedDocumentPayment>
    init(payments: Array<RetainedDocumentPayment>) { this.payments = payments }
    private func perPayment(invoice: Int64): Int64 {
        if (invoice < 0 || payments.isEmpty()) { throw Exception("display.invoice_overflow") }
        invoice / payments.size + if (invoice % payments.size == 0) { 0 } else { 1 }
    }
    public func prepareLayoutCopies(invoice: Int64): Bool {
        let share = perPayment(invoice)
        for (payment in payments) { if (!payment.prepareLayoutCopies(share)) { return false } }
        true
    }
    public func prepareHistoryCopies(invoice: Int64): Bool {
        let share = perPayment(invoice)
        for (payment in payments) { if (!payment.prepareHistoryCopies(share)) { return false } }
        true
    }
    public func prepareRasterCopies(invoice: Int64): Bool {
        let share = perPayment(invoice)
        for (payment in payments) { if (!payment.prepareRasterCopies(share)) { return false } }
        true
    }
}
