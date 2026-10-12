package core

import std.unittest.*
import std.unittest.testmacro.*

class RecordedRetainedDocumentPayment <: RetainedDocumentPayment {
    var allow = true
    var layouts: Int64 = 0
    var layoutInvoice: Int64 = 0
    public func prepareLayoutCopies(invoice: Int64): Bool {
        layouts++; layoutInvoice = invoice; allow }
    public func prepareHistoryCopies(_: Int64): Bool { allow }
    public func prepareRasterCopies(_: Int64): Bool { allow }
}
class GuardedTranscriptCopiesSource <: VirtualTranscriptSource {
    let payment = RecordedRetainedDocumentPayment()
    var allowDocument = true
    var documents: Int64 = 0
    var revisionValue: Int64 = 0
    public func size(): Int64 { 1 }
    public func itemId(_: Int64): String { "copied" }
    public func revision(_: Int64): Int64 { revisionValue }
    public func prepareItemRetainedCopies(_: Int64, _: Int64, invoice: Int64): Bool {
        invoice > 0 && allowDocument }
    public func document(_: Int64, _: Int64, _: String): Document {
        documents++
        Document([DocumentLine(DocumentLineKind.Paragraph, "complete 中文 e\u{301} text")], retainedPayment: Some(payment)) }
}

@Test
class RetainedDisplayPaymentTests {
    @TestCase
    func ActualDocumentLayoutRefusalLeavesPaidOldRowsAndHorizontalRuleWidthIsCharged(): Unit {
        let payment = RecordedRetainedDocumentPayment()
        let document = Document([DocumentLine(DocumentLineKind.Paragraph, "中文e\u{301}abcdefgh"),
            DocumentLine(DocumentLineKind.HorizontalRule, "Output")], retainedPayment: Some(payment))
        let view = DocumentView(document, cacheLayout: true)
        let oldRows = view.layoutRows(8)
        @Expect(payment.layouts, 1)
        let small = payment.layoutInvoice
        payment.allow = false
        var failed = false
        try { let _ = view.layoutRows(65536) } catch (_: Exception) { failed = true }
        @Expect(failed, true)
        @Expect(payment.layoutInvoice > small + 65536, true)
        @Expect(view.layoutRows(8).size, oldRows.size)
        @Expect(view.layoutRows(8)[0].spans[0].text, oldRows[0].spans[0].text)
        @Expect(payment.layouts, 2)
    }
    @TestCase
    func ActualVirtualCacheRefusesBeforeSourceDocumentAndRetriesWithoutDroppingTheOldCompleteDocument(): Unit {
        let source = GuardedTranscriptCopiesSource()
        let view = VirtualTranscriptView(source, backgroundBatch: 0)
        let buffer = Buffer(Rect(0, 0, 24, 8))
        view.render(buffer.area, buffer)
        @Expect(source.documents, 1)
        source.revisionValue++; source.allowDocument = false
        var failed = false
        try { view.render(buffer.area, buffer) } catch (_: Exception) { failed = true }
        @Expect(failed, true); @Expect(source.documents, 1)
        source.allowDocument = true
        view.render(buffer.area, buffer)
        @Expect(source.documents, 2)
        @Expect(buffer.getCell(0, 0).symbol, "c")
    }
}
