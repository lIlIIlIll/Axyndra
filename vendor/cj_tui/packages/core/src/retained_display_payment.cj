package core

// Pure copied display data. The product supplies an already-held payment;
// this contract conveys no source, tool, process, or effect capability.
public interface RetainedDocumentPayment {
    func prepareLayoutCopies(invoice: Int64): Bool
    func prepareHistoryCopies(invoice: Int64): Bool
    func prepareRasterCopies(invoice: Int64): Bool
}

func retainedDisplayAdd(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > Int64.Max - right) {
        throw Exception("display.invoice_overflow") }
    left + right
}
func retainedDisplayMultiply(count: Int64, unit: Int64): Int64 {
    if (count < 0 || unit < 0) { throw Exception("display.invoice_overflow") }
    if (unit == 0) { return 0 }
    if (count > Int64.Max / unit) {
        throw Exception("display.invoice_overflow") }
    count * unit
}

// Scalar backing is counted in full, with generous separate String/array
// copies. Every line/span/array control cell is invoiced independently.
// This traversal never materializes a fields, scalar, or rows snapshot.
func retainedDocumentInvoice(document: Document): Int64 {
    var total: Int64 = 4096
    for (line in document.lines) {
        total = retainedDisplayAdd(total, 1024)
        for (span in line.spans) {
            var bytes = span.text.size
            match (span.linkUrl) { case Some(value) => bytes = retainedDisplayAdd(bytes, value.size); case None => () }
            match (span.sourceRange) { case Some(value) => bytes = retainedDisplayAdd(bytes, value.size); case None => () }
            total = retainedDisplayAdd(total, retainedDisplayAdd(512, retainedDisplayMultiply(bytes, 16)))
        }
    }
    total
}
func retainedStyledRowsInvoice(rows: Array<StyledLine>): Int64 {
    var total: Int64 = 4096
    for (row in rows) {
        total = retainedDisplayAdd(total, 1024)
        for (span in row.spans) {
            var bytes = span.text.size
            match (span.linkUrl) { case Some(value) => bytes = retainedDisplayAdd(bytes, value.size); case None => () }
            match (span.sourceRange) { case Some(value) => bytes = retainedDisplayAdd(bytes, value.size); case None => () }
            total = retainedDisplayAdd(total, retainedDisplayAdd(512, retainedDisplayMultiply(bytes, 16)))
        }
        for (span in row.ruleLabel) {
            total = retainedDisplayAdd(total, retainedDisplayAdd(512, retainedDisplayMultiply(span.text.size, 16)))
        }
    }
    total
}

// Word/character wrapping can retain one new RichSpan and one row per UTF-8
// byte, together with their ArrayList capacities, toArray snapshots, words,
// Rune Strings, concatenation backing, and old cached rows. Do not infer a
// four-byte bound for a Buffer cell: combining graphemes may be much larger.
func retainedDocumentLayoutInvoice(document: Document, width: Int64, oldRows: Int64): Int64 {
    var total = retainedDisplayAdd(65536, oldRows)
    total = retainedDisplayAdd(total, retainedDocumentInvoice(document))
    for (line in document.lines) {
        var bytes: Int64 = 16
        bytes = retainedDisplayAdd(bytes, retainedDisplayMultiply(line.quoteDepth, 2))
        for (span in line.spans) { bytes = retainedDisplayAdd(bytes, span.text.size) }
        total = retainedDisplayAdd(total, retainedDisplayAdd(4096, retainedDisplayMultiply(bytes, 2048)))
        match (line.kind) {
            case DocumentLineKind.HorizontalRule =>
                total = retainedDisplayAdd(total, retainedDisplayMultiply(max(1, width), 32))
            case DocumentLineKind.Image =>
                total = retainedDisplayAdd(total, retainedDisplayMultiply(line.mediaHeight, 2048))
            case _ => () }
    }
    total
}

func prepareDocumentLayoutPayment(document: Document, width: Int64, oldRows: Array<StyledLine>): Unit {
    match (document.retainedPayment) {
        case Some(payment) =>
            let invoice = retainedDocumentLayoutInvoice(document, width, retainedStyledRowsInvoice(oldRows))
            if (!payment.prepareLayoutCopies(invoice)) { throw Exception("display.layout_payment_required") }
        case None => () }
}

// Count the actual existing cell array and complete scalar backing without
// materializing a cells/media snapshot. Combining graphemes have no fixed
// byte bound; the indexed Cell symbol is counted in full.
public func retainedBufferCellInvoice(buffer: Buffer): Int64 {
    let cells = retainedDisplayMultiply(max(0, buffer.area.width), max(0, buffer.area.height))
    var total = retainedDisplayAdd(4096, retainedDisplayMultiply(cells, 1024))
    for (y in buffer.area.y..buffer.area.bottom) {
        for (x in buffer.area.x..buffer.area.right) {
            total = retainedDisplayAdd(total, retainedDisplayMultiply(buffer.getCell(x, y).symbol.size, 16)) }
    }
    total
}

// Two real raster cell arrays, temporary old/new rows and repeated clipped
// paints, plus full scalar backing; no substring is treated as a tiny owner.
public func retainedDocumentRasterInvoice(document: Document, width: Int64, height: Int64): Int64 {
    let cells = retainedDisplayMultiply(max(0, width), max(1, height))
    retainedDisplayAdd(retainedDocumentLayoutInvoice(document, max(1, width), 0),
        retainedDisplayAdd(65536, retainedDisplayMultiply(cells, 1024)))
}
