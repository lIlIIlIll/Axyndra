package markdown

import cj_markdown.{MarkdownBlock, MarkdownBlockKind, MarkdownDocument, MarkdownDiagnosticSeverity, MarkdownInline, 
    MarkdownInlineKind, MarkdownTable, MarkdownTableAlign, MarkdownTableRow, SourceRange, parseMarkdown}
import core.{Document, DocumentLine, DocumentLineKind, DocumentTheme, DocumentView, MediaKind, MediaSource, RichSpan, 
    Style, displayWidth}
import std.collection.*

public class Markdown {
    public static func parse(
        text: String,
        theme!: DocumentTheme = DocumentTheme(),
        preserveSoftBreaks!: Bool = false
    ): Document {
        markdownDocument(text, theme: theme, preserveSoftBreaks: preserveSoftBreaks)
    }
}

public func markdownDocument(
    text: String,
    theme!: DocumentTheme = DocumentTheme(),
    preserveSoftBreaks!: Bool = false
): Document {
    markdownAstToDocument(parseMarkdown(text), theme: theme, preserveSoftBreaks: preserveSoftBreaks)
}

public func markdownAstToDocument(
    ast: MarkdownDocument,
    theme!: DocumentTheme = DocumentTheme(),
    preserveSoftBreaks!: Bool = false
): Document {
    let lines = ArrayList<DocumentLine>()
    for (block in ast.blocks) {
        appendBlock(lines, block, theme, quoteDepth: 0, preserveSoftBreaks: preserveSoftBreaks)
    }
    for (diagnostic in ast.diagnostics) {
        lines.add(
            DocumentLine(
                DocumentLineKind.Diagnostic,
                [RichSpan(diagnosticMessage(diagnostic.severity) + diagnostic.message, style: theme.diagnostic,
                    sourceRange: Some(rangeText(diagnostic.range)))]
            )
        )
    }
    Document(lines.toArray())
}

public class OutlineNode {
    public let level: Int64
    public let title: String
    public let sourceOffset: Int64
    public let children: Array<OutlineNode>

    public init(level: Int64, title: String, sourceOffset: Int64, children!: Array<OutlineNode> = []) {
        this.level = level
        this.title = title
        this.sourceOffset = max(0, sourceOffset)
        this.children = children
    }
}

public class MarkdownPreviewIndex {
    private let sourceOffsets: Array<Int64>

    public init(sourceOffsets: Array<Int64>) {
        this.sourceOffsets = sourceOffsets
    }

    public func renderedLineCount(): Int64 {
        sourceOffsets.size
    }

    public func sourceOffsetForRenderedLine(line: Int64): ?Int64 {
        if (line < 0 || line >= sourceOffsets.size) {
            return None
        }
        Some(sourceOffsets[line])
    }

    public func renderedLineForSourceOffset(offset: Int64): Int64 {
        var best: Int64 = 0
        for (i in 0..sourceOffsets.size) {
            if (sourceOffsets[i] <= offset) {
                best = i
            }
        }
        best
    }
}

public func markdownOutline(ast: MarkdownDocument): Array<OutlineNode> {
    let flat = ArrayList<OutlineNode>()
    collectOutlineNodes(ast.blocks, flat)
    nestOutline(flat.toArray())
}

public func markdownPreviewIndex(document: Document, width: Int64): MarkdownPreviewIndex {
    MarkdownPreviewIndex(DocumentView(document).sourceOffsetsForRenderedLines(width))
}

func appendBlock(
    lines: ArrayList<DocumentLine>,
    block: MarkdownBlock,
    theme: DocumentTheme,
    quoteDepth!: Int64 = 0,
    preserveSoftBreaks!: Bool = false
): Unit {
    match (block.kind) {
        case MarkdownBlockKind.Blank => lines.add(DocumentLine(DocumentLineKind.Blank, "", quoteDepth: quoteDepth))
        case MarkdownBlockKind.Heading(level) => lines.add(
            DocumentLine(DocumentLineKind.Heading(level),
                inlineSpans(block.inlines, theme, theme.headingStyle(level), fallbackText: block.text,
                    source: block.range), quoteDepth: quoteDepth))
        case MarkdownBlockKind.List => for (child in block.children) {
            appendBlock(lines, child, theme, quoteDepth: quoteDepth, preserveSoftBreaks: preserveSoftBreaks)
        }
        case MarkdownBlockKind.ListItem(ordered, level) =>
            lines.add(
                DocumentLine(DocumentLineKind.ListItem(ordered),
                    indentedSpans(level,
                        inlineSpans(block.inlines, theme, theme.list, fallbackText: block.text, source: block.range),
                        theme.list), quoteDepth: quoteDepth))
            appendChildren(lines, block.children, theme, quoteDepth: quoteDepth, preserveSoftBreaks: preserveSoftBreaks)
        case MarkdownBlockKind.TaskListItem(checked, level) =>
            lines.add(
                DocumentLine(DocumentLineKind.TaskListItem(checked),
                    indentedSpans(level,
                        inlineSpans(block.inlines, theme, theme.list, fallbackText: block.text, source: block.range),
                        theme.list), quoteDepth: quoteDepth))
            appendChildren(lines, block.children, theme, quoteDepth: quoteDepth, preserveSoftBreaks: preserveSoftBreaks)
        case MarkdownBlockKind.Quote =>
            if (block.children.size > 0) {
                appendChildren(lines, block.children, theme, quoteDepth: quoteDepth + 1,
                    preserveSoftBreaks: preserveSoftBreaks)
            } else {
                lines.add(
                    DocumentLine(DocumentLineKind.Quote,
                        inlineSpans(block.inlines, theme, theme.quoteStyle, fallbackText: block.text,
                            source: block.range), quoteDepth: quoteDepth + 1))
            }
        case MarkdownBlockKind.CodeBlock(_) => for (line in splitDocumentLines(block.text)) {
            lines.add(DocumentLine(DocumentLineKind.CodeBlock, line, style: theme.code, quoteDepth: quoteDepth))
        }
        case MarkdownBlockKind.Table => match (block.table) {
            case Some(table) => appendTable(lines, table, theme, quoteDepth: quoteDepth)
            case None => lines.add(
                DocumentLine(DocumentLineKind.TableRow, block.text, style: theme.table, quoteDepth: quoteDepth))
        }
        case MarkdownBlockKind.HorizontalRule => lines.add(
            DocumentLine(DocumentLineKind.HorizontalRule, "", style: theme.table, quoteDepth: quoteDepth))
        case MarkdownBlockKind.HtmlBlock => lines.add(
            DocumentLine(DocumentLineKind.Html, block.text, style: theme.html, quoteDepth: quoteDepth))
        case MarkdownBlockKind.ReferenceDefinition(_, _, _) => ()
        case MarkdownBlockKind.Paragraph =>
            if (isSingleImage(block.inlines)) {
                lines.add(
                    DocumentLine(
                        DocumentLineKind.Image,
                        inlineSpans(block.inlines, theme, theme.image, fallbackText: block.text, source: block.range),
                        quoteDepth: quoteDepth,
                        media: singleImageSource(block.inlines),
                        mediaHeight: 6
                    )
                )
            } else {
                appendParagraphLines(lines, block, theme, quoteDepth, preserveSoftBreaks)
            }
    }
}

func appendParagraphLines(
    lines: ArrayList<DocumentLine>,
    block: MarkdownBlock,
    theme: DocumentTheme,
    quoteDepth: Int64,
    preserveSoftBreaks: Bool
): Unit {
    let spans = ArrayList<RichSpan>()
    var sawHardBreak = false
    for (item in block.inlines) {
        match (item.kind) {
            case MarkdownInlineKind.HardBreak =>
                lines.add(DocumentLine(DocumentLineKind.Paragraph, spans.toArray(), quoteDepth: quoteDepth))
                spans.clear()
                sawHardBreak = true
            case MarkdownInlineKind.SoftBreak =>
                if (preserveSoftBreaks) {
                    lines.add(DocumentLine(DocumentLineKind.Paragraph, spans.toArray(), quoteDepth: quoteDepth))
                    spans.clear()
                    sawHardBreak = true
                } else {
                    for (span in inlineSpans([item], theme, theme.paragraph)) {
                        spans.add(span)
                    }
                }
            case _ => for (span in inlineSpans([item], theme, theme.paragraph)) {
                spans.add(span)
            }
        }
    }
    if (spans.size > 0 || sawHardBreak) {
        lines.add(DocumentLine(DocumentLineKind.Paragraph, spans.toArray(), quoteDepth: quoteDepth))
    } else {
        lines.add(
            DocumentLine(
                DocumentLineKind.Paragraph,
                inlineSpans(block.inlines, theme, theme.paragraph, fallbackText: block.text, source: block.range),
                quoteDepth: quoteDepth
            )
        )
    }
}

func appendChildren(
    lines: ArrayList<DocumentLine>,
    children: Array<MarkdownBlock>,
    theme: DocumentTheme,
    quoteDepth!: Int64 = 0,
    preserveSoftBreaks!: Bool = false
): Unit {
    for (child in children) {
        appendBlock(lines, child, theme, quoteDepth: quoteDepth, preserveSoftBreaks: preserveSoftBreaks)
    }
}

func collectOutlineNodes(blocks: Array<MarkdownBlock>, out: ArrayList<OutlineNode>): Unit {
    for (block in blocks) {
        match (block.kind) {
            case MarkdownBlockKind.Heading(level) => out.add(OutlineNode(level, block.text, sourceStart(block.range)))
            case _ => ()
        }
        if (block.children.size > 0) {
            collectOutlineNodes(block.children, out)
        }
    }
}

func nestOutline(flat: Array<OutlineNode>): Array<OutlineNode> {
    if (flat.size == 0) {
        return []
    }
    let (nodes, _) = nestOutlineAt(flat, 0, flat[0].level)
    nodes
}

func nestOutlineAt(flat: Array<OutlineNode>, start: Int64, level: Int64): (Array<OutlineNode>, Int64) {
    let out = ArrayList<OutlineNode>()
    var i = start
    while (i < flat.size) {
        if (flat[i].level < level) {
            break
        } else if (flat[i].level > level) {
            if (out.size == 0) {
                out.add(flat[i])
                i++
            } else {
                let (children, next) = nestOutlineAt(flat, i, flat[i].level)
                let last = out[out.size - 1]
                out[out.size - 1] = OutlineNode(last.level, last.title, last.sourceOffset,
                    children: mergeOutline(last.children, children))
                i = next
            }
        } else {
            out.add(flat[i])
            i++
        }
    }
    (out.toArray(), i)
}

func mergeOutline(first: Array<OutlineNode>, second: Array<OutlineNode>): Array<OutlineNode> {
    let out = ArrayList<OutlineNode>()
    for (node in first) {
        out.add(node)
    }
    for (node in second) {
        out.add(node)
    }
    out.toArray()
}

func sourceStart(range: ?SourceRange): Int64 {
    match (range) {
        case Some(r) => r.start.offset
        case None => 0
    }
}

func isSingleImage(inlines: Array<MarkdownInline>): Bool {
    if (inlines.size != 1) {
        return false
    }
    match (inlines[0].kind) {
        case MarkdownInlineKind.Image(_) => true
        case _ => false
    }
}

func singleImageSource(inlines: Array<MarkdownInline>): ?MediaSource {
    if (inlines.size != 1) {
        return None
    }
    let item = inlines[0]
    match (item.kind) {
        case MarkdownInlineKind.Image(url) => Some(
            MediaSource("markdown:${url}", url, kind: MediaKind.Image, alt: item.text))
        case _ => None
    }
}

func inlineSpans(inlines: Array<MarkdownInline>, theme: DocumentTheme, fallback: Style, fallbackText!: String = "",
    source!: ?SourceRange = None): Array<RichSpan> {
    if (inlines.size == 0) {
        return [RichSpan(fallbackText, style: fallback, sourceRange: rangeOptionText(source))]
    }
    let spans = ArrayList<RichSpan>()
    for (item in inlines) {
        let sourceRange = rangeOptionText(item.range)
        match (item.kind) {
            case MarkdownInlineKind.Text => spans.add(RichSpan(item.text, style: fallback, sourceRange: sourceRange))
            case MarkdownInlineKind.Emphasis => addInlineChildrenOrText(spans, item, theme, theme.emphasis, fallback,
                sourceRange)
            case MarkdownInlineKind.Strong => addInlineChildrenOrText(spans, item, theme, theme.strong, fallback,
                sourceRange)
            case MarkdownInlineKind.Strikethrough => addInlineChildrenOrText(spans, item, theme, theme.strikethrough,
                fallback, sourceRange)
            case MarkdownInlineKind.Code => spans.add(
                RichSpan(item.text, style: theme.inlineCode, sourceRange: sourceRange))
            case MarkdownInlineKind.Link(url, _) =>
                if (item.children.size > 0) {
                    let nested = inlineSpans(item.children, theme, theme.link)
                    for (span in nested) {
                        spans.add(
                            RichSpan(span.text, style: span.style, linkUrl: Some(url), sourceRange: span.sourceRange))
                    }
                } else {
                    spans.add(RichSpan(item.text, style: theme.link, linkUrl: Some(url), sourceRange: sourceRange))
                }
            case MarkdownInlineKind.Image(url) => spans.add(
                RichSpan(if (item.text.isEmpty()) {
                    url
                } else {
                    item.text + " " + url
                }, style: theme.image, linkUrl: Some(url), sourceRange: sourceRange))
            case MarkdownInlineKind.HtmlInline => spans.add(
                RichSpan(item.text, style: theme.html, sourceRange: sourceRange))
            case MarkdownInlineKind.SoftBreak => spans.add(RichSpan(" ", style: fallback, sourceRange: sourceRange))
            case MarkdownInlineKind.HardBreak => spans.add(RichSpan(" ", style: fallback, sourceRange: sourceRange))
        }
    }
    spans.toArray()
}

func addInlineChildrenOrText(out: ArrayList<RichSpan>, item: MarkdownInline, theme: DocumentTheme, style: Style,
    fallback: Style, sourceRange: ?String): Unit {
    if (item.children.size == 0) {
        out.add(RichSpan(item.text, style: style, sourceRange: sourceRange))
        return
    }
    let nested = inlineSpans(item.children, theme, style)
    for (span in nested) {
        out.add(
            RichSpan(span.text, style: if (span.style == fallback) {
                style
            } else {
                mergeInlineStyles(style, span.style)
            }, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
    }
}

func mergeInlineStyles(outer: Style, inner: Style): Style {
    var merged = outer.patch(inner)
    var modifier = merged.modifier
    modifier.bold = outer.modifier.bold || inner.modifier.bold
    modifier.italic = outer.modifier.italic || inner.modifier.italic
    modifier.underline = outer.modifier.underline || inner.modifier.underline
    modifier.reversed = outer.modifier.reversed || inner.modifier.reversed
    merged.modifier = modifier
    merged
}

func appendTable(lines: ArrayList<DocumentLine>, table: MarkdownTable, theme: DocumentTheme, quoteDepth!: Int64 = 0): Unit {
    let widths = tableWidths(table)
    lines.add(
        DocumentLine(DocumentLineKind.TableHeader, alignedTableRow(table.header, widths, table.alignments),
            style: theme.tableHeader, quoteDepth: quoteDepth))
    for (row in table.rows) {
        lines.add(
            DocumentLine(DocumentLineKind.TableRow, alignedTableRow(row, widths, table.alignments), style: theme.table,
                quoteDepth: quoteDepth))
    }
}

func tableWidths(table: MarkdownTable): Array<Int64> {
    let widths = ArrayList<Int64>()
    for (cell in table.header.cells) {
        widths.add(displayWidth(cell.text))
    }
    for (row in table.rows) {
        for (i in 0..row.cells.size) {
            if (i >= widths.size) {
                widths.add(displayWidth(row.cells[i].text))
            } else {
                widths[i] = max(widths[i], displayWidth(row.cells[i].text))
            }
        }
    }
    widths.toArray()
}

func alignedTableRow(row: MarkdownTableRow, widths: Array<Int64>, aligns: Array<MarkdownTableAlign>): String {
    let cells = ArrayList<String>()
    for (i in 0..row.cells.size) {
        let width = if (i < widths.size) {
            widths[i]
        } else {
            displayWidth(row.cells[i].text)
        }
        let align = if (i < aligns.size) {
            aligns[i]
        } else {
            MarkdownTableAlign.None
        }
        cells.add(alignText(row.cells[i].text, width, align))
    }
    joinDocument(cells.toArray(), " | ")
}

func alignText(text: String, width: Int64, align: MarkdownTableAlign): String {
    let extra = max(0, width - displayWidth(text))
    match (align) {
        case MarkdownTableAlign.Right => repeatSpaces(extra) + text
        case MarkdownTableAlign.Center =>
            let left = extra / 2
            repeatSpaces(left) + text + repeatSpaces(extra - left)
        case _ => text + repeatSpaces(extra)
    }
}

func indentedSpans(level: Int64, spans: Array<RichSpan>, style: Style): Array<RichSpan> {
    if (level <= 0) {
        return spans
    }
    let out = ArrayList<RichSpan>()
    out.add(RichSpan(repeatSpaces(level * 2), style: style))
    for (span in spans) {
        out.add(span)
    }
    out.toArray()
}

func diagnosticMessage(severity: MarkdownDiagnosticSeverity): String {
    match (severity) {
        case MarkdownDiagnosticSeverity.Warning => "warning: "
        case MarkdownDiagnosticSeverity.Error => "error: "
    }
}

func rangeOptionText(range: ?SourceRange): ?String {
    match (range) {
        case Some(r) => Some(rangeText(r))
        case None => None
    }
}

func rangeText(range: SourceRange): String {
    "${range.start.offset}:${range.end.offset}"
}

func splitDocumentLines(text: String): Array<String> {
    let lines = ArrayList<String>()
    var start: Int64 = 0
    var i: Int64 = 0
    while (i < text.size) {
        if (text[i] == b'\n') {
            lines.add(text[start..i])
            start = i + 1
        }
        i++
    }
    if (start <= text.size) {
        lines.add(text[start..])
    }
    lines.toArray()
}

func repeatSpaces(count: Int64): String {
    var out = ""
    for (_ in 0..count) {
        out += " "
    }
    out
}

func joinDocument(parts: Array<String>, sep: String): String {
    var out = ""
    for (i in 0..parts.size) {
        if (i > 0) {
            out += sep
        }
        out += parts[i]
    }
    out
}
