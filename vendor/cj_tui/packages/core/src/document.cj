package core

import std.collection.*

public class RichSpan {
    public let text: String
    public let style: Style
    public let linkUrl: ?String
    public let sourceRange: ?String

    public init(text: String, style!: Style = Style.default(), linkUrl!: ?String = None, sourceRange!: ?String = None) {
        this.text = text
        this.style = style
        this.linkUrl = linkUrl
        this.sourceRange = sourceRange
    }
}

public enum DocumentLineKind {
    | Paragraph
    | Heading(Int64)
    | ListItem(Bool)
    | Quote
    | CodeBlock
    | TableRow
    | TableHeader
    | HorizontalRule
    | TaskListItem(Bool)
    | Image
    | Diagnostic
    | Html
    | Strikethrough
    | CodeFenceInfo(String)
    | Blank
}

public class DocumentLine {
    public let kind: DocumentLineKind
    public let spans: Array<RichSpan>
    public let quoteDepth: Int64
    public let media: ?MediaSource
    public let mediaFit: MediaFit
    public let mediaHeight: Int64

    public init(
        kind: DocumentLineKind,
        spans: Array<RichSpan>,
        quoteDepth!: Int64 = 0,
        media!: ?MediaSource = None,
        mediaFit!: MediaFit = MediaFit.Contain,
        mediaHeight!: Int64 = 6
    ) {
        this.kind = kind
        this.spans = spans
        this.quoteDepth = max(0, quoteDepth)
        this.media = media
        this.mediaFit = mediaFit
        this.mediaHeight = max(1, mediaHeight)
    }

    public init(
        kind: DocumentLineKind,
        text: String,
        style!: Style = Style.default(),
        quoteDepth!: Int64 = 0,
        media!: ?MediaSource = None,
        mediaFit!: MediaFit = MediaFit.Contain,
        mediaHeight!: Int64 = 6
    ) {
        this.kind = kind
        this.spans = [RichSpan(text, style: style)]
        this.quoteDepth = max(0, quoteDepth)
        this.media = media
        this.mediaFit = mediaFit
        this.mediaHeight = max(1, mediaHeight)
    }

    public static func image(source: MediaSource, alt!: String = "", style!: Style = Style(fg: Color.Cyan), mediaHeight!: Int64 = 6): DocumentLine {
        let label = if (alt.isEmpty()) { mediaFallbackText(source) } else { alt }
        DocumentLine(DocumentLineKind.Image, [RichSpan(label, style: style, linkUrl: Some(source.uri))], media: Some(source), mediaHeight: mediaHeight)
    }
}

public class Document {
    public let lines: Array<DocumentLine>

    public init(lines: Array<DocumentLine>) {
        this.lines = lines
    }

    public static func plain(text: String, style!: Style = Style.default()): Document {
        let lines = ArrayList<DocumentLine>()
        for (line in splitLines(text)) {
            lines.add(DocumentLine(DocumentLineKind.Paragraph, line, style: style))
        }
        Document(lines.toArray())
    }
}

public struct DocumentTheme {
    public let paragraph: Style
    public let heading: Style
    public let heading1: Style
    public let heading2: Style
    public let heading3: Style
    public let heading4: Style
    public let heading5: Style
    public let heading6: Style
    public let list: Style
    public let quoteStyle: Style
    public let code: Style
    public let table: Style
    public let link: Style
    public let emphasis: Style
    public let strong: Style
    public let inlineCode: Style
    public let image: Style
    public let diagnostic: Style
    public let html: Style
    public let strikethrough: Style
    public let tableHeader: Style

    public init(
        paragraph!: Style = Style.default(),
        heading!: Style = Style(fg: Color.Yellow, modifier: Modifier.strong()),
        heading1!: ?Style = None,
        heading2!: ?Style = None,
        heading3!: ?Style = None,
        heading4!: ?Style = None,
        heading5!: ?Style = None,
        heading6!: ?Style = None,
        list!: Style = Style(fg: Color.Cyan),
        quoteStyle!: Style = Style(fg: Color.Green),
        code!: Style = Style(fg: Color.Magenta),
        table!: Style = Style(fg: Color.Cyan),
        link!: Style = Style(fg: Color.Blue),
        emphasis!: Style = Style(fg: Color.White, modifier: italicModifier()),
        strong!: Style = Style(fg: Color.White, modifier: Modifier.strong()),
        inlineCode!: Style = Style(fg: Color.Magenta),
        image!: Style = Style(fg: Color.Cyan),
        diagnostic!: Style = Style(fg: Color.Red),
        html!: Style = Style(fg: Color.Indexed(8)),
        strikethrough!: Style = Style(fg: Color.Indexed(8)),
        tableHeader!: Style = Style(fg: Color.Yellow, modifier: Modifier.strong())
    ) {
        this.paragraph = paragraph
        this.heading = heading
        this.heading1 = match (heading1) {
            case Some(style) => style
            case None => heading
        }
        this.heading2 = match (heading2) {
            case Some(style) => style
            case None => Style(fg: Color.Cyan, modifier: Modifier.strong())
        }
        this.heading3 = match (heading3) {
            case Some(style) => style
            case None => Style(fg: Color.White, modifier: Modifier.strong())
        }
        this.heading4 = match (heading4) {
            case Some(style) => style
            case None => Style(fg: Color.Magenta, modifier: Modifier.strong())
        }
        this.heading5 = match (heading5) {
            case Some(style) => style
            case None => Style(fg: Color.White, modifier: italicModifier())
        }
        this.heading6 = match (heading6) {
            case Some(style) => style
            case None => Style(fg: Color.Indexed(8), modifier: italicModifier())
        }
        this.list = list
        this.quoteStyle = quoteStyle
        this.code = code
        this.table = table
        this.link = link
        this.emphasis = emphasis
        this.strong = strong
        this.inlineCode = inlineCode
        this.image = image
        this.diagnostic = diagnostic
        this.html = html
        this.strikethrough = strikethrough
        this.tableHeader = tableHeader
    }

    public func headingStyle(level: Int64): Style {
        match (level) {
            case 1 => heading1
            case 2 => heading2
            case 3 => heading3
            case 4 => heading4
            case 5 => heading5
            case 6 => heading6
            case _ => heading
        }
    }
}

public type MarkdownTheme = DocumentTheme
public type MarkdownDocument = Document

public class DocumentHighlight {
    public let query: String
    public let style: Style

    public init(query: String, style!: Style = Style(bg: Color.Yellow)) {
        this.query = query
        this.style = style
    }
}

public class DocumentFoldRange {
    public let startOffset: Int64
    public let endOffset: Int64

    public init(startOffset: Int64, endOffset: Int64) {
        this.startOffset = max(0, startOffset)
        this.endOffset = max(this.startOffset, endOffset)
    }

    public func contains(offset: Int64): Bool {
        startOffset <= offset && offset <= endOffset
    }
}

public class DocumentViewState {
    public var scroll: Int64
    public var cursorSourceOffset: ?Int64
    public var selectedLinkIndex: Int64
    public var searchMatchIndex: Int64
    private let foldedRanges = ArrayList<DocumentFoldRange>()

    public init(scroll!: Int64 = 0, cursorSourceOffset!: ?Int64 = None, selectedLinkIndex!: Int64 = 0, searchMatchIndex!: Int64 = 0) {
        this.scroll = max(0, scroll)
        this.cursorSourceOffset = cursorSourceOffset
        this.selectedLinkIndex = max(0, selectedLinkIndex)
        this.searchMatchIndex = max(0, searchMatchIndex)
    }

    public func folds(): Array<DocumentFoldRange> {
        foldedRanges.toArray()
    }

    public func clearFolds(): Unit {
        while (foldedRanges.size > 0) { foldedRanges.remove(at: 0) }
    }

    public func isFolded(startOffset: Int64, endOffset: Int64): Bool {
        for (range in foldedRanges) {
            if (range.startOffset == startOffset && range.endOffset == endOffset) { return true }
        }
        false
    }

    public func setFolded(startOffset: Int64, endOffset: Int64, folded: Bool): Unit {
        let start = max(0, startOffset)
        let end = max(start, endOffset)
        for (i in 0..foldedRanges.size) {
            let range = foldedRanges[i]
            if (range.startOffset == start && range.endOffset == end) {
                if (!folded) { foldedRanges.remove(at: i) }
                return
            }
        }
        if (folded) { foldedRanges.add(DocumentFoldRange(start, end)) }
    }

    public func toggleFold(startOffset: Int64, endOffset: Int64): Bool {
        let folded = !isFolded(startOffset, endOffset)
        setFolded(startOffset, endOffset, folded)
        folded
    }
}

public class DocumentView <: Widget {
    private let document: Document
    private let block: ?Block
    private let theme: DocumentTheme
    private let scroll: Int64
    private let wrap: WrapMode
    private let highlights: Array<DocumentHighlight>
    private let state: ?DocumentViewState
    private let currentSourceStyle: Style
    private let cacheLayout: Bool
    private var cachedWidth: Int64 = -1
    private var cachedRows: Array<StyledLine> = []

    public init(
        document: Document,
        block!: ?Block = None,
        style!: Style = Style.default(),
        headingStyle!: Style = Style(fg: Color.Yellow, modifier: Modifier.strong()),
        theme!: ?DocumentTheme = None,
        scroll!: Int64 = 0,
        wrap!: WrapMode = WrapMode.Word,
        highlights!: Array<DocumentHighlight> = [],
        state!: ?DocumentViewState = None,
        currentSourceStyle!: Style = Style(bg: Color.Indexed(8)),
        cacheLayout!: Bool = false
    ) {
        this.document = document
        this.block = block
        this.theme = match (theme) {
            case Some(t) => t
            case None => DocumentTheme(paragraph: style, heading: headingStyle)
        }
        this.scroll = max(0, scroll)
        this.wrap = wrap
        this.highlights = highlights
        this.state = state
        this.currentSourceStyle = currentSourceStyle
        this.cacheLayout = cacheLayout
    }

    public func renderedLineCount(width: Int64): Int64 {
        renderRows(document, width).size
    }

    public func sourceOffsetForRenderedLine(width: Int64, renderedLine: Int64): ?Int64 {
        let rows = renderRows(document, width)
        if (renderedLine < 0 || renderedLine >= rows.size) { return None }
        for (span in rows[renderedLine].spans) {
            match (span.sourceRange) {
                case Some(value) => return parseSourceOffset(value)
                case None => ()
            }
        }
        None
    }

    public func sourceOffsetAtRenderedLine(width: Int64, renderedLine: Int64): ?Int64 {
        sourceOffsetForRenderedLine(width, renderedLine)
    }

    public func sourceOffsetsForRenderedLines(width: Int64): Array<Int64> {
        let rows = renderRows(document, width)
        let offsets = ArrayList<Int64>()
        var last: Int64 = 0
        for (row in rows) {
            match (sourceOffsetFromRow(row)) {
                case Some(offset) =>
                    last = offset
                    offsets.add(offset)
                case None => offsets.add(last)
            }
        }
        offsets.toArray()
    }

    public func renderedLineForSourceOffset(width: Int64, sourceOffset: Int64): Int64 {
        let rows = renderRows(document, width)
        var fallback: Int64 = 0
        for (i in 0..rows.size) {
            for (span in rows[i].spans) {
                match (span.sourceRange) {
                    case Some(value) =>
                        let start = parseSourceOffset(value)
                        let end = parseSourceEndOffset(value)
                        match ((start, end)) {
                            case (Some(s), Some(e)) =>
                                if (s <= sourceOffset) { fallback = i }
                                if (s <= sourceOffset && sourceOffset <= e) { return i }
                            case _ => ()
                        }
                    case None => ()
                }
            }
        }
        fallback
    }

    public func linkAtRenderedLine(width: Int64, renderedLine: Int64): ?String {
        let rows = renderRows(document, width)
        if (renderedLine < 0 || renderedLine >= rows.size) { return None }
        for (span in rows[renderedLine].spans) {
            match (span.linkUrl) {
                case Some(url) => return Some(url)
                case None => ()
            }
        }
        None
    }

    public func handleKey(key: KeyEvent, width: Int64, viewportHeight: Int64): Bool {
        match (state) {
            case Some(s) =>
                let total = max(0, renderedLineCount(width))
                match (key.code) {
                    case KeyCode.Down =>
                        s.scroll = min(max(0, total - viewportHeight), s.scroll + 1)
                        true
                    case KeyCode.Up =>
                        s.scroll = max(0, s.scroll - 1)
                        true
                    case KeyCode.PageDown =>
                        s.scroll = min(max(0, total - viewportHeight), s.scroll + max(1, viewportHeight))
                        true
                    case KeyCode.PageUp =>
                        s.scroll = max(0, s.scroll - max(1, viewportHeight))
                        true
                    case KeyCode.Enter =>
                        match (sourceOffsetForRenderedLine(width, s.scroll)) {
                            case Some(offset) => s.cursorSourceOffset = Some(offset)
                            case None => ()
                        }
                        true
                    case _ => false
                }
            case None => false
        }
    }

    public func handleMouse(mouse: MouseEvent, area: Rect): ?Int64 {
        let row = mouse.y - area.y + currentScroll()
        sourceOffsetForRenderedLine(area.width, row)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        let renderScroll = currentScroll()
        let rows = renderRowsWindow(document, target.width, renderScroll, target.height)
        var row: Int64 = 0
        while (row < target.height && row < rows.size) {
            let item = rows[row]
            renderStyledLine(buffer, target.x, target.y + row, item, target.width)
            row++
        }
    }

    func layoutRows(width: Int64): Array<StyledLine> {
        renderRows(document, width)
    }

    private func renderRows(document: Document, width: Int64): Array<StyledLine> {
        if (cacheLayout && cachedWidth == width) { return cachedRows }
        let rows = ArrayList<StyledLine>()
        for (line in document.lines) {
            appendLineRows(rows, line, width)
        }
        let result = rows.toArray()
        if (cacheLayout) {
            cachedWidth = width
            cachedRows = result
        }
        result
    }

    private func renderRowsWindow(document: Document, width: Int64, start: Int64, count: Int64): Array<StyledLine> {
        if (cacheLayout) {
            let all = renderRows(document, width)
            let from = min(all.size, max(0, start))
            let to = min(all.size, from + max(0, count))
            return all[from..to]
        }
        let rows = ArrayList<StyledLine>()
        if (count <= 0) { return rows.toArray() }
        let from = max(0, start)
        let to = from + count
        var rowIndex: Int64 = 0
        for (line in document.lines) {
            let lineRows = ArrayList<StyledLine>()
            appendLineRows(lineRows, line, width)
            for (item in lineRows) {
                if (rowIndex >= to) { return rows.toArray() }
                if (rowIndex >= from) { rows.add(item) }
                rowIndex++
            }
        }
        rows.toArray()
    }

    private func appendLineRows(rows: ArrayList<StyledLine>, line: DocumentLine, width: Int64): Unit {
        if (isLineFolded(line)) { return }
        match (line.kind) {
            case DocumentLineKind.Blank =>
                rows.add(StyledLine(quotePrefixedSpans(line, theme.quoteStyle, [RichSpan("", style: theme.paragraph)])))
            case DocumentLineKind.Heading(level) =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, prefixedSpans(headingMarker(level), themedSpans(line.spans, theme.headingStyle(level)), theme.headingStyle(level))), width)
            case DocumentLineKind.ListItem(ordered) =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, prefixedSpans(if (ordered) { "1. " } else { "* " }, themedSpans(line.spans, theme.list), theme.list)), width)
            case DocumentLineKind.TaskListItem(checked) =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, prefixedSpans(if (checked) { "[x] " } else { "[ ] " }, themedSpans(line.spans, theme.list), theme.list)), width)
            case DocumentLineKind.Quote =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, themedSpans(line.spans, theme.quoteStyle)), width)
            case DocumentLineKind.CodeBlock =>
                rows.add(StyledLine(quotePrefixedSpans(line, theme.quoteStyle, applyCurrentSourceHighlight(applyHighlights(themedSpans(line.spans, theme.code), highlights), currentCursorSource(), currentSourceStyle))))
            case DocumentLineKind.TableRow =>
                rows.add(StyledLine(quotePrefixedSpans(line, theme.quoteStyle, applyCurrentSourceHighlight(applyHighlights(themedSpans(line.spans, theme.table), highlights), currentCursorSource(), currentSourceStyle))))
            case DocumentLineKind.TableHeader =>
                rows.add(StyledLine(quotePrefixedSpans(line, theme.quoteStyle, applyCurrentSourceHighlight(applyHighlights(themedSpans(line.spans, theme.tableHeader), highlights), currentCursorSource(), currentSourceStyle))))
            case DocumentLineKind.HorizontalRule =>
                rows.add(StyledLine(
                    quotePrefixedSpans(line, theme.quoteStyle, [RichSpan(repeat("-", width), style: theme.table)]),
                    horizontalRule: true,
                    ruleLabel: themedSpans(line.spans, theme.table)
                ))
            case DocumentLineKind.Image =>
                match (line.media) {
                    case Some(source) =>
                        rows.add(StyledLine(
                            quotePrefixedSpans(line, theme.quoteStyle, prefixedSpans("! ", themedSpans(line.spans, theme.image), theme.image)),
                            media: Some(source),
                            mediaFit: line.mediaFit,
                            mediaHeight: line.mediaHeight
                        ))
                        for (_ in 1..line.mediaHeight) {
                            rows.add(StyledLine([RichSpan("", style: theme.image)]))
                        }
                    case None =>
                        addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, prefixedSpans("! ", themedSpans(line.spans, theme.image), theme.image)), width)
                }
            case DocumentLineKind.Diagnostic =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, prefixedSpans("! ", themedSpans(line.spans, theme.diagnostic), theme.diagnostic)), width)
            case DocumentLineKind.Html =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, themedSpans(line.spans, theme.html)), width)
            case DocumentLineKind.Strikethrough =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, themedSpans(line.spans, theme.strikethrough)), width)
            case DocumentLineKind.CodeFenceInfo(_) =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, themedSpans(line.spans, theme.inlineCode)), width)
            case DocumentLineKind.Paragraph =>
                addWrappedSpans(rows, quotePrefixedSpans(line, theme.quoteStyle, themedSpans(line.spans, theme.paragraph)), width)
        }
        }

    private func sourceOffsetFromRow(row: StyledLine): ?Int64 {
        for (span in row.spans) {
            match (span.sourceRange) {
                case Some(value) => return parseSourceOffset(value)
                case None => ()
            }
        }
        None
    }

    private func addWrappedSpans(rows: ArrayList<StyledLine>, spans: Array<RichSpan>, width: Int64): Unit {
        let highlighted = applyCurrentSourceHighlight(applyHighlights(spans, highlights), currentCursorSource(), currentSourceStyle)
        let text = spansText(highlighted)
        let noWrap = match (wrap) {
            case WrapMode.NoWrap => true
            case _ => false
        }
        if (displayWidth(text) <= width || noWrap) {
            rows.add(StyledLine(highlighted))
            return
        }
        let wrapped = match (wrap) {
            case WrapMode.Word => wrapRichSpansByWord(highlighted, width)
            case _ => wrapRichSpans(highlighted, width)
        }
        for (line in wrapped) {
            rows.add(line)
        }
    }

    private func currentScroll(): Int64 {
        match (state) {
            case Some(s) => max(0, s.scroll)
            case None => scroll
        }
    }

    private func currentCursorSource(): ?Int64 {
        match (state) {
            case Some(s) => s.cursorSourceOffset
            case None => None
        }
    }

    private func isLineFolded(line: DocumentLine): Bool {
        let start = lineStartOffset(line)
        match (start) {
            case Some(offset) =>
                match (state) {
                    case Some(s) =>
                        for (range in s.folds()) {
                            if (range.startOffset < offset && offset <= range.endOffset) { return true }
                        }
                    case None => ()
                }
            case None => ()
        }
        false
    }
}

public class MarkdownView <: Widget {
    private let view: DocumentView

    public init(
        text: String,
        block!: ?Block = None,
        style!: Style = Style.default(),
        headingStyle!: Style = Style(fg: Color.Yellow, modifier: Modifier.strong()),
        theme!: ?DocumentTheme = None,
        scroll!: Int64 = 0,
        wrap!: WrapMode = WrapMode.Word
    ) {
        this.view = DocumentView(Document.plain(text, style: style), block: block, style: style, headingStyle: headingStyle, theme: theme, scroll: scroll, wrap: wrap)
    }

    public init(
        document: Document,
        block!: ?Block = None,
        style!: Style = Style.default(),
        headingStyle!: Style = Style(fg: Color.Yellow, modifier: Modifier.strong()),
        theme!: ?DocumentTheme = None,
        scroll!: Int64 = 0,
        wrap!: WrapMode = WrapMode.Word
    ) {
        this.view = DocumentView(document, block: block, style: style, headingStyle: headingStyle, theme: theme, scroll: scroll, wrap: wrap)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        view.render(area, buffer)
    }
}

class StyledLine {
    let spans: Array<RichSpan>
    let media: ?MediaSource
    let mediaFit: MediaFit
    let mediaHeight: Int64
    let horizontalRule: Bool
    let ruleLabel: Array<RichSpan>

    init(
        spans: Array<RichSpan>,
        media!: ?MediaSource = None,
        mediaFit!: MediaFit = MediaFit.Contain,
        mediaHeight!: Int64 = 0,
        horizontalRule!: Bool = false,
        ruleLabel!: Array<RichSpan> = []
    ) {
        this.spans = spans
        this.media = media
        this.mediaFit = mediaFit
        this.mediaHeight = max(0, mediaHeight)
        this.horizontalRule = horizontalRule
        this.ruleLabel = ruleLabel
    }
}

func renderStyledLine(buffer: Buffer, x: Int64, y: Int64, line: StyledLine, width: Int64): Unit {
    var cx = x
    let right = x + width
    for (span in line.spans) {
        if (cx >= right) { return }
        cx += buffer.writeStringClipped(
            cx,
            y,
            span.text,
            maxWidth: right - cx,
            style: span.style
        )
    }
    match (line.media) {
        case Some(source) =>
            let area = Rect(x, y, width, max(1, line.mediaHeight))
            buffer.addMedia(MediaPlacement("document:${source.id}:${x}:${y}", source, area, fit: line.mediaFit))
        case None => ()
    }
}

func spansText(spans: Array<RichSpan>): String {
    let parts = ArrayList<String>()
    for (span in spans) {
        parts.add(span.text)
    }
    join(parts.toArray(), "")
}

func themedSpans(spans: Array<RichSpan>, fallback: Style): Array<RichSpan> {
    if (spans.size == 0) { return [RichSpan("", style: fallback)] }
    let out = ArrayList<RichSpan>()
    for (span in spans) {
        out.add(RichSpan(span.text, style: if (span.style == Style.default()) { fallback } else { span.style }, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
    }
    out.toArray()
}

func prefixedSpans(prefix: String, spans: Array<RichSpan>, style: Style): Array<RichSpan> {
    let out = ArrayList<RichSpan>()
    out.add(RichSpan(prefix, style: style))
    for (span in spans) {
        out.add(span)
    }
    out.toArray()
}

func quotePrefixedSpans(line: DocumentLine, quoteStyle: Style, spans: Array<RichSpan>): Array<RichSpan> {
    var depth = line.quoteDepth
    match (line.kind) {
        case DocumentLineKind.Quote =>
            if (depth == 0) { depth = 1 }
        case _ => ()
    }
    if (depth <= 0) { return spans }
    prefixedSpans(repeat("| ", depth), spans, quoteStyle)
}

func headingMarker(level: Int64): String {
    repeat("#", clamp(level, 1, 6)) + " "
}

func parseSourceOffset(value: String): ?Int64 {
    var out: Int64 = 0
    var seen = false
    for (i in 0..value.size) {
        let b = value[i]
        if (b >= b'0' && b <= b'9') {
            out = out * 10 + Int64(b - b'0')
            seen = true
        } else {
            break
        }
    }
    if (seen) { Some(out) } else { None }
}

func parseSourceEndOffset(value: String): ?Int64 {
    let sep = findByteFromLocal(value, b':', 0)
    if (sep < 0 || sep + 1 >= value.size) { return None }
    parseSourceOffset(value[sep + 1..])
}

func findByteFromLocal(text: String, value: Byte, start: Int64): Int64 {
    var i = start
    while (i < text.size) {
        if (text[i] == value) { return i }
        i++
    }
    -1
}

func applyHighlights(spans: Array<RichSpan>, highlights: Array<DocumentHighlight>): Array<RichSpan> {
    if (highlights.size == 0) { return spans }
    var current = spans
    for (highlight in highlights) {
        if (highlight.query.isEmpty()) { continue }
        current = applyHighlight(current, highlight.query, highlight.style)
    }
    current
}

func applyHighlight(spans: Array<RichSpan>, query: String, style: Style): Array<RichSpan> {
    let out = ArrayList<RichSpan>()
    for (span in spans) {
        var offset: Int64 = 0
        while (offset < span.text.size) {
            let idx = stringIndexOf(span.text, query, offset)
            if (idx < 0) {
                out.add(RichSpan(span.text[offset..], style: span.style, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
                offset = span.text.size
            } else {
                if (idx > offset) {
                    out.add(RichSpan(span.text[offset..idx], style: span.style, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
                }
                out.add(RichSpan(span.text[idx..idx + query.size], style: span.style.patch(style), linkUrl: span.linkUrl, sourceRange: span.sourceRange))
                offset = idx + max(1, query.size)
            }
        }
    }
    out.toArray()
}

func applyCurrentSourceHighlight(spans: Array<RichSpan>, sourceOffset: ?Int64, style: Style): Array<RichSpan> {
    match (sourceOffset) {
        case Some(offset) =>
            let out = ArrayList<RichSpan>()
            for (span in spans) {
                if (spanContainsSource(span, offset)) {
                    out.add(RichSpan(span.text, style: span.style.patch(style), linkUrl: span.linkUrl, sourceRange: span.sourceRange))
                } else {
                    out.add(span)
                }
            }
            out.toArray()
        case None => spans
    }
}

func spanContainsSource(span: RichSpan, offset: Int64): Bool {
    match (span.sourceRange) {
        case Some(value) =>
            match ((parseSourceOffset(value), parseSourceEndOffset(value))) {
                case (Some(start), Some(end)) => start <= offset && offset <= end
                case _ => false
            }
        case None => false
    }
}

func lineStartOffset(line: DocumentLine): ?Int64 {
    for (span in line.spans) {
        match (span.sourceRange) {
            case Some(value) => return parseSourceOffset(value)
            case None => ()
        }
    }
    None
}

func wrapRichSpans(spans: Array<RichSpan>, width: Int64): Array<StyledLine> {
    let rows = ArrayList<StyledLine>()
    if (width <= 0) { return rows.toArray() }
    var current = ArrayList<RichSpan>()
    var currentWidth: Int64 = 0
    for (span in spans) {
        let bytes = unsafe { span.text.rawData() }
        var offset: Int64 = 0
        while (offset < bytes.size) {
            let (r, len) = Rune.fromUtf8(bytes, offset)
            let part = runeToString(r)
            let w = displayWidth(r)
            if (w > 0 && currentWidth > 0 && currentWidth + w > width) {
                rows.add(StyledLine(current.toArray()))
                current = ArrayList<RichSpan>()
                currentWidth = 0
            }
            current.add(RichSpan(part, style: span.style, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
            currentWidth += w
            offset += len
        }
    }
    if (current.size > 0 || rows.size == 0) {
        rows.add(StyledLine(current.toArray()))
    }
    rows.toArray()
}

func wrapRichSpansByWord(spans: Array<RichSpan>, width: Int64): Array<StyledLine> {
    let rows = ArrayList<StyledLine>()
    if (width <= 0) { return rows.toArray() }
    var current = ArrayList<RichSpan>()
    var currentWidth: Int64 = 0
    for (span in spans) {
        let chunks = wordChunks(span.text)
        for (chunk in chunks) {
            let w = displayWidth(chunk)
            if (w > width) {
                if (current.size > 0) {
                    rows.add(StyledLine(current.toArray()))
                    current = ArrayList<RichSpan>()
                    currentWidth = 0
                }
                for (line in wrapRichSpans([RichSpan(chunk, style: span.style, linkUrl: span.linkUrl, sourceRange: span.sourceRange)], width)) {
                    rows.add(line)
                }
            } else if (currentWidth > 0 && currentWidth + w > width) {
                rows.add(StyledLine(trimTrailingSpaceSpans(current.toArray())))
                current = ArrayList<RichSpan>()
                currentWidth = 0
                if (!isOnlySpaces(chunk)) {
                    current.add(RichSpan(trimLeadingSpaces(chunk), style: span.style, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
                    currentWidth += displayWidth(trimLeadingSpaces(chunk))
                }
            } else {
                current.add(RichSpan(chunk, style: span.style, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
                currentWidth += w
            }
        }
    }
    if (current.size > 0 || rows.size == 0) {
        rows.add(StyledLine(trimTrailingSpaceSpans(current.toArray())))
    }
    rows.toArray()
}

func wordChunks(text: String): Array<String> {
    let chunks = ArrayList<String>()
    var start: Int64 = 0
    var inSpace = false
    var i: Int64 = 0
    while (i < text.size) {
        let space = text[i] == b' ' || text[i] == b'\t'
        if (i == 0) {
            inSpace = space
        } else if (space != inSpace) {
            chunks.add(text[start..i])
            start = i
            inSpace = space
        }
        i++
    }
    if (start < text.size) {
        chunks.add(text[start..])
    }
    chunks.toArray()
}

func isOnlySpaces(text: String): Bool {
    if (text.isEmpty()) { return false }
    for (i in 0..text.size) {
        if (!(text[i] == b' ' || text[i] == b'\t')) { return false }
    }
    true
}

func trimLeadingSpaces(text: String): String {
    var start: Int64 = 0
    while (start < text.size && (text[start] == b' ' || text[start] == b'\t')) { start++ }
    text[start..]
}

func trimTrailingSpaceSpans(spans: Array<RichSpan>): Array<RichSpan> {
    if (spans.size == 0) { return spans }
    let out = ArrayList<RichSpan>()
    for (span in spans) { out.add(span) }
    while (out.size > 0 && isOnlySpaces(out[out.size - 1].text)) {
        out.remove(at: out.size - 1)
    }
    if (out.size == 0) { return spans }
    let last = out[out.size - 1]
    let trimmed = trimTrailingSpaces(last.text)
    out[out.size - 1] = RichSpan(trimmed, style: last.style, linkUrl: last.linkUrl, sourceRange: last.sourceRange)
    out.toArray()
}

func trimTrailingSpaces(text: String): String {
    var end = text.size
    while (end > 0 && (text[end - 1] == b' ' || text[end - 1] == b'\t')) { end-- }
    text[..end]
}
