package cj_markdown

import std.collection.*

public struct SourcePos <: Equatable<SourcePos> {
    public let line: Int64
    public let column: Int64
    public let offset: Int64
    public init(line: Int64, column: Int64, offset: Int64) {
        this.line = line
        this.column = column
        this.offset = offset
    }
    public operator func ==(other: SourcePos): Bool {
        line == other.line && column == other.column && offset == other.offset
    }
}

public struct SourceRange <: Equatable<SourceRange> {
    public let start: SourcePos
    public let end: SourcePos
    public init(start: SourcePos, end: SourcePos) {
        this.start = start
        this.end = end
    }
    public operator func ==(other: SourceRange): Bool {
        start == other.start && end == other.end
    }
}

public enum MarkdownDiagnosticSeverity {
    | Warning
    | Error
}

public class MarkdownDiagnostic {
    public let severity: MarkdownDiagnosticSeverity
    public let message: String
    public let range: SourceRange

    public init(severity: MarkdownDiagnosticSeverity, message: String, range: SourceRange) {
        this.severity = severity
        this.message = message
        this.range = range
    }
}

public enum MarkdownBlockKind {
    | Paragraph
    | Heading(Int64)
    | List
    | ListItem(Bool, Int64)
    | TaskListItem(Bool, Int64)
    | Quote
    | CodeBlock(String)
    | Table
    | HorizontalRule
    | HtmlBlock
    | ReferenceDefinition(String, String, String)
    | Blank
}

public enum MarkdownInlineKind {
    | Text
    | Emphasis
    | Strong
    | Strikethrough
    | Code
    | Link(String, String)
    | Image(String)
    | HtmlInline
    | SoftBreak
    | HardBreak
}

public enum MarkdownTableAlign {
    | Left
    | Center
    | Right
    | None
}

public class MarkdownInline {
    public let kind: MarkdownInlineKind
    public let text: String
    public let children: Array<MarkdownInline>
    public let range: ?SourceRange

    public init(kind: MarkdownInlineKind, text: String, children!: Array<MarkdownInline> = [],
        range!: ?SourceRange = None) {
        this.kind = kind
        this.text = text
        this.children = children
        this.range = range
    }
}

public class MarkdownTableCell {
    public let text: String
    public let inlines: Array<MarkdownInline>

    public init(text: String, inlines!: Array<MarkdownInline> = []) {
        this.text = text
        this.inlines = if (inlines.size == 0) {
            parseInline(text)
        } else {
            inlines
        }
    }
}

public class MarkdownTableRow {
    public let cells: Array<MarkdownTableCell>

    public init(cells: Array<MarkdownTableCell>) {
        this.cells = cells
    }
}

public class MarkdownTable {
    public let header: MarkdownTableRow
    public let alignments: Array<MarkdownTableAlign>
    public let rows: Array<MarkdownTableRow>

    public init(header: MarkdownTableRow, alignments: Array<MarkdownTableAlign>, rows!: Array<MarkdownTableRow> = []) {
        this.header = header
        this.alignments = alignments
        this.rows = rows
    }
}

public class MarkdownBlock {
    public let kind: MarkdownBlockKind
    public let text: String
    public let inlines: Array<MarkdownInline>
    public let table: ?MarkdownTable
    public let children: Array<MarkdownBlock>
    public let range: ?SourceRange

    public init(
        kind: MarkdownBlockKind,
        text: String,
        inlines!: Array<MarkdownInline> = [],
        table!: ?MarkdownTable = None,
        children!: Array<MarkdownBlock> = [],
        range!: ?SourceRange = None
    ) {
        this.kind = kind
        this.text = text
        this.inlines = inlines
        this.table = table
        this.children = children
        this.range = range
    }
}

public class MarkdownDocument {
    public let blocks: Array<MarkdownBlock>
    public let diagnostics: Array<MarkdownDiagnostic>

    public init(blocks: Array<MarkdownBlock>, diagnostics!: Array<MarkdownDiagnostic> = []) {
        this.blocks = blocks
        this.diagnostics = diagnostics
    }
}

public struct MarkdownParserOptions {
    public let mergeParagraphs: Bool
    public let enableHtml: Bool
    public let enableStrikethrough: Bool

    public init(mergeParagraphs!: Bool = true, enableHtml!: Bool = true, enableStrikethrough!: Bool = true) {
        this.mergeParagraphs = mergeParagraphs
        this.enableHtml = enableHtml
        this.enableStrikethrough = enableStrikethrough
    }
}

class LineInfo {
    let text: String
    let line: Int64
    let offset: Int64
    init(text: String, line: Int64, offset: Int64) {
        this.text = text
        this.line = line
        this.offset = offset
    }

    func pos(column: Int64): SourcePos {
        SourcePos(line, column, offset + column)
    }

    func range(startColumn!: Int64 = 0, endColumn!: Int64 = -1): SourceRange {
        let end = if (endColumn < 0) {
            text.size
        } else {
            endColumn
        }
        SourceRange(pos(startColumn), pos(end))
    }
}

class LinkReference {
    let id: String
    let url: String
    let title: String
    init(id: String, url: String, title: String) {
        this.id = id
        this.url = url
        this.title = title
    }
}

public class MarkdownParser {
    private let options: MarkdownParserOptions
    private var diagnostics = ArrayList<MarkdownDiagnostic>()
    private var references = ArrayList<LinkReference>()

    public init(options!: MarkdownParserOptions = MarkdownParserOptions()) {
        this.options = options
    }

    public func parse(text: String): MarkdownDocument {
        diagnostics = ArrayList<MarkdownDiagnostic>()
        references = ArrayList<LinkReference>()
        let lines = markdownLines(text)
        collectReferences(lines)
        let blocks = parseBlocks(lines)
        MarkdownDocument(blocks, diagnostics: diagnostics.toArray())
    }

    private func parseBlocks(lines: Array<LineInfo>): Array<MarkdownBlock> {
        let blocks = ArrayList<MarkdownBlock>()
        var i: Int64 = 0
        while (i < lines.size) {
            let line = lines[i]
            if (line.text.isEmpty()) {
                blocks.add(MarkdownBlock(MarkdownBlockKind.Blank, "", range: Some(line.range())))
                i++
            } else if (isReferenceDefinition(line.text)) {
                let block = parseReferenceDefinition(line)
                blocks.add(block)
                i++
            } else if (isFenceStart(line.text)) {
                let (block, next) = parseFencedCode(lines, i)
                blocks.add(block)
                i = next
            } else if (isSetextHeadingStart(lines, i)) {
                blocks.add(parseSetextHeading(lines[i], lines[i + 1]))
                i += 2
            } else if (isHeading(line.text)) {
                blocks.add(parseHeading(line))
                i++
            } else if (options.enableHtml && isHtmlBlock(line.text)) {
                let (block, next) = parseHtmlBlock(lines, i)
                blocks.add(block)
                i = next
            } else if (isHorizontalRule(line.text)) {
                blocks.add(MarkdownBlock(MarkdownBlockKind.HorizontalRule, line.text, range: Some(line.range())))
                i++
            } else if (isQuoteLine(line.text)) {
                let (block, next) = parseQuote(lines, i)
                blocks.add(block)
                i = next
            } else if (isUnorderedList(line.text) || isOrderedMarkdownList(line.text)) {
                let (block, next) = parseList(lines, i)
                blocks.add(block)
                i = next
            } else if (isIndentedCodeStart(line.text)) {
                let (block, next) = parseIndentedCode(lines, i)
                blocks.add(block)
                i = next
            } else if (isTableStart(lines, i)) {
                let (block, next) = parseTable(lines, i)
                blocks.add(block)
                i = next
            } else {
                let (block, next) = parseParagraph(lines, i)
                blocks.add(block)
                i = next
            }
        }
        blocks.toArray()
    }

    private func parseHeading(line: LineInfo): MarkdownBlock {
        let level = markdownHeadingLevel(line.text)
        let contentStart = skipSpaces(line.text, level)
        let content = stripClosingHeading(line.text[contentStart..])
        MarkdownBlock(
            MarkdownBlockKind.Heading(level),
            content,
            inlines: parseInlineWithContext(content, line.line, contentStart, line.offset + contentStart,
                references.toArray(), options.enableHtml, options.enableStrikethrough),
            range: Some(line.range())
        )
    }

    private func parseSetextHeading(textLine: LineInfo, markerLine: LineInfo): MarkdownBlock {
        let marker = trimMarkdownCell(markerLine.text)
        let level: Int64 = if (marker.startsWith("=")) {
            1
        } else {
            2
        }
        MarkdownBlock(
            MarkdownBlockKind.Heading(level),
            textLine.text,
            inlines: parseInlineWithContext(textLine.text, textLine.line, 0, textLine.offset, references.toArray(),
                options.enableHtml, options.enableStrikethrough),
            range: Some(SourceRange(textLine.pos(0), markerLine.pos(markerLine.text.size)))
        )
    }

    private func parseParagraph(lines: Array<LineInfo>, start: Int64): (MarkdownBlock, Int64) {
        let parts = ArrayList<String>()
        let paragraphLines = ArrayList<LineInfo>()
        let first = lines[start]
        var last = first
        var i = start
        while (i < lines.size && !lines[i].text.isEmpty() && !isFenceStart(lines[i].text) && !isHeading(lines[i].text) &&
                !isSetextHeadingStart(lines, i) && !isHorizontalRule(lines[i].text) && !isQuoteLine(lines[i].text) &&
                !isUnorderedList(lines[i].text) && !isOrderedMarkdownList(lines[i].text) && !isTableStart(lines, i) &&
                !isReferenceDefinition(lines[i].text)) {
            parts.add(lines[i].text)
            paragraphLines.add(lines[i])
            last = lines[i]
            i++
            if (!options.mergeParagraphs) {
                break
            }
        }
        let text = joinMarkdown(parts.toArray(), " ")
        let range = SourceRange(first.pos(0), last.pos(last.text.size))
        (MarkdownBlock(MarkdownBlockKind.Paragraph, text, inlines: parseParagraphInlines(paragraphLines.toArray()),
                range: Some(range)), i)
    }

    private func parseParagraphInlines(lines: Array<LineInfo>): Array<MarkdownInline> {
        if (lines.size == 0) {
            return []
        }
        if (lines.size == 1) {
            return parseInlineWithContext(lines[0].text, lines[0].line, 0, lines[0].offset, references.toArray(),
                options.enableHtml, options.enableStrikethrough)
        }
        let out = ArrayList<MarkdownInline>()
        for (idx in 0..lines.size) {
            if (idx > 0) {
                let previous = lines[idx - 1]
                let kind = if (hasMarkdownHardBreak(previous.text)) {
                    MarkdownInlineKind.HardBreak
                } else {
                    MarkdownInlineKind.SoftBreak
                }
                out.add(
                    MarkdownInline(kind, "",
                        range: Some(SourceRange(previous.pos(previous.text.size), lines[idx].pos(0)))))
            }
            let text = if (hasMarkdownHardBreak(lines[idx].text)) {
                stripMarkdownHardBreak(lines[idx].text)
            } else {
                lines[idx].text
            }
            for (inline in parseInlineWithContext(text, lines[idx].line, 0, lines[idx].offset, references.toArray(),
                options.enableHtml, options.enableStrikethrough)) {
                out.add(inline)
            }
        }
        out.toArray()
    }

    private func parseHtmlBlock(lines: Array<LineInfo>, start: Int64): (MarkdownBlock, Int64) {
        let parts = ArrayList<String>()
        let first = lines[start]
        var last = first
        var i = start
        while (i < lines.size && !lines[i].text.isEmpty()) {
            parts.add(lines[i].text)
            last = lines[i]
            i++
            if (lines[i - 1].text.contains(">")) {
                break
            }
        }
        (MarkdownBlock(MarkdownBlockKind.HtmlBlock, joinMarkdown(parts.toArray(), "\n"),
                range: Some(SourceRange(first.pos(0), last.pos(last.text.size)))), i)
    }

    private func parseFencedCode(lines: Array<LineInfo>, start: Int64): (MarkdownBlock, Int64) {
        let first = lines[start]
        let fence = fenceMarker(first.text)
        let info = trimMarkdownLeading(first.text[fence.size..])
        let language = firstWord(info)
        let code = ArrayList<String>()
        var i = start + 1
        while (i < lines.size) {
            if (lines[i].text.startsWith(fence)) {
                let range = SourceRange(first.pos(0), lines[i].pos(lines[i].text.size))
                return (MarkdownBlock(MarkdownBlockKind.CodeBlock(language), joinMarkdown(code.toArray(), "\n"),
                        range: Some(range)), i + 1)
            }
            code.add(lines[i].text)
            i++
        }
        diagnostics.add(
            MarkdownDiagnostic(MarkdownDiagnosticSeverity.Warning, "Unclosed fenced code block", first.range()))
        let end = if (lines.size > start + 1) {
            lines[lines.size - 1].pos(lines[lines.size - 1].text.size)
        } else {
            first.pos(first.text.size)
        }
        (MarkdownBlock(MarkdownBlockKind.CodeBlock(language), joinMarkdown(code.toArray(), "\n"),
                range: Some(SourceRange(first.pos(0), end))), i)
    }

    private func parseIndentedCode(lines: Array<LineInfo>, start: Int64): (MarkdownBlock, Int64) {
        let parts = ArrayList<String>()
        let first = lines[start]
        var last = first
        var i = start
        while (i < lines.size && isIndentedCodeStart(lines[i].text)) {
            parts.add(lines[i].text[4..])
            last = lines[i]
            i++
        }
        (MarkdownBlock(MarkdownBlockKind.CodeBlock(""), joinMarkdown(parts.toArray(), "\n"),
                range: Some(SourceRange(first.pos(0), last.pos(last.text.size)))), i)
    }

    private func parseQuote(lines: Array<LineInfo>, start: Int64): (MarkdownBlock, Int64) {
        let parts = ArrayList<String>()
        let innerLines = ArrayList<LineInfo>()
        let first = lines[start]
        var last = first
        var i = start
        while (i < lines.size && isQuoteLine(lines[i].text)) {
            let quoteStart = quoteMarkerOffset(lines[i].text)
            let contentStart = quoteContentOffset(lines[i].text, quoteStart)
            let content = lines[i].text[contentStart..]
            parts.add(content)
            innerLines.add(LineInfo(content, lines[i].line, lines[i].offset + contentStart))
            last = lines[i]
            i++
        }
        let inner = parseBlocks(innerLines.toArray())
        let display = joinMarkdown(parts.toArray(), " ")
        (MarkdownBlock(
                MarkdownBlockKind.Quote,
                display,
                inlines: parseInlineWithContext(display, first.line, 1, first.offset + 1, references.toArray(),
                    options.enableHtml, options.enableStrikethrough),
                children: inner,
                range: Some(SourceRange(first.pos(0), last.pos(last.text.size)))
            ), i)
    }

    private func parseList(lines: Array<LineInfo>, start: Int64): (MarkdownBlock, Int64) {
        let items = ArrayList<MarkdownBlock>()
        let first = lines[start]
        var last = first
        var i = start
        while (i < lines.size && (isUnorderedList(lines[i].text) || isOrderedMarkdownList(lines[i].text))) {
            var item = parseListItem(lines[i])
            last = lines[i]
            i++
            while (i < lines.size && canContinueListItem(lines, i)) {
                if (lines[i].text.isEmpty()) {
                    last = lines[i]
                    i++
                    continue
                }
                if (isIndentedChildBlockStart(lines[i].text)) {
                    let (children, next, childLast) = parseIndentedChildBlocks(lines, i)
                    item = withChildren(item, mergeBlocks(item.children, children))
                    last = childLast
                    i = next
                } else {
                    item = appendListContinuation(item, lines[i])
                    last = lines[i]
                    i++
                }
            }
            while (i + 1 < lines.size && lines[i].text.isEmpty() && (isUnorderedList(lines[i + 1].text) ||
                    isOrderedMarkdownList(lines[i + 1].text))) {
                last = lines[i]
                i++
            }
            items.add(item)
        }
        (MarkdownBlock(MarkdownBlockKind.List, "", children: nestListItems(items.toArray()),
                range: Some(SourceRange(first.pos(0), last.pos(last.text.size)))), i)
    }

    private func parseListItem(line: LineInfo): MarkdownBlock {
        let level = indentationLevel(line.text)
        let trimmedStart = leadingWidth(line.text)
        let trimmed = line.text[trimmedStart..]
        let ordered = isOrderedMarkdownList(trimmed)
        var idx = if (ordered) {
            orderedMarkdownContentOffset(trimmed)
        } else {
            2
        }
        var kind = MarkdownBlockKind.ListItem(ordered, level)
        let (isTask, isChecked) = taskMarkerAt(trimmed, idx)
        if (isTask) {
            kind = if (isChecked) {
                MarkdownBlockKind.TaskListItem(true, level)
            } else {
                MarkdownBlockKind.TaskListItem(false, level)
            }
            idx += 4
        }
        idx = skipSpaces(trimmed, idx)
        let content = trimmed[idx..]
        MarkdownBlock(kind, content,
            inlines: parseInlineWithContext(content, line.line, trimmedStart + idx, line.offset + trimmedStart + idx,
                references.toArray(), options.enableHtml, options.enableStrikethrough), range: Some(line.range()))
    }

    private func appendListContinuation(block: MarkdownBlock, line: LineInfo): MarkdownBlock {
        let text = trimMarkdownLeading(line.text)
        let nextText = if (block.text.isEmpty()) {
            text
        } else {
            block.text + " " + text
        }
        let start = match (block.range) {
            case Some(range) => range.start
            case None => line.pos(0)
        }
        MarkdownBlock(
            block.kind,
            nextText,
            inlines: parseInlineWithContext(nextText, start.line, start.column, start.offset, references.toArray(),
                options.enableHtml, options.enableStrikethrough),
            table: block.table,
            children: block.children,
            range: Some(SourceRange(start, line.pos(line.text.size)))
        )
    }

    private func parseIndentedChildBlocks(lines: Array<LineInfo>, start: Int64): (Array<MarkdownBlock>, Int64, LineInfo) {
        let baseIndent = leadingWidth(lines[start].text)
        let normalized = ArrayList<LineInfo>()
        var last = lines[start]
        var i = start
        while (i < lines.size) {
            if (lines[i].text.isEmpty()) {
                if (i + 1 >= lines.size || leadingWidth(lines[i + 1].text) < baseIndent) {
                    break
                }
                normalized.add(LineInfo("", lines[i].line, lines[i].offset))
                last = lines[i]
                i++
                continue
            }
            if (leadingWidth(lines[i].text) < baseIndent) {
                break
            }
            normalized.add(LineInfo(lines[i].text[baseIndent..], lines[i].line, lines[i].offset + baseIndent))
            last = lines[i]
            i++
        }
        (parseBlocks(normalized.toArray()), i, last)
    }

    private func parseTable(lines: Array<LineInfo>, start: Int64): (MarkdownBlock, Int64) {
        let header = MarkdownTableRow(tableCells(lines[start]))
        let alignments = tableAlignments(lines[start + 1].text)
        let rows = ArrayList<MarkdownTableRow>()
        var i = start + 2
        var last = lines[start + 1]
        while (i < lines.size && isMarkdownTableRow(lines[i].text)) {
            if (splitTableLine(lines[i].text).size != header.cells.size) {
                diagnostics.add(
                    MarkdownDiagnostic(MarkdownDiagnosticSeverity.Warning, "Table row has different cell count",
                        lines[i].range()))
            }
            rows.add(MarkdownTableRow(tableCells(lines[i])))
            last = lines[i]
            i++
        }
        if (alignments.size != header.cells.size) {
            diagnostics.add(
                MarkdownDiagnostic(MarkdownDiagnosticSeverity.Warning, "Table separator has different cell count",
                    lines[start + 1].range()))
        }
        let table = MarkdownTable(header, alignments, rows: rows.toArray())
        (MarkdownBlock(MarkdownBlockKind.Table, lines[start].text, table: Some(table),
                range: Some(SourceRange(lines[start].pos(0), last.pos(last.text.size)))), i)
    }

    private func tableCells(line: LineInfo): Array<MarkdownTableCell> {
        let cells = ArrayList<MarkdownTableCell>()
        for (cell in splitTableLine(line.text)) {
            cells.add(
                MarkdownTableCell(cell,
                    inlines: parseInlineWithContext(cell, line.line, 0, line.offset, references.toArray(),
                        options.enableHtml, options.enableStrikethrough)))
        }
        cells.toArray()
    }

    private func collectReferences(lines: Array<LineInfo>): Unit {
        for (line in lines) {
            if (isReferenceDefinition(line.text)) {
                let (_, id, url, title) = referenceParts(line.text)
                references.add(LinkReference(id, url, title))
            }
        }
    }

    private func parseReferenceDefinition(line: LineInfo): MarkdownBlock {
        let (_, id, url, title) = referenceParts(line.text)
        MarkdownBlock(MarkdownBlockKind.ReferenceDefinition(id, url, title), line.text, range: Some(line.range()))
    }
}

public func parseMarkdown(text: String): MarkdownDocument {
    MarkdownParser().parse(text)
}

public func parseMarkdownWithOptions(text: String, options: MarkdownParserOptions): MarkdownDocument {
    MarkdownParser(options: options).parse(text)
}

public func parseInline(text: String): Array<MarkdownInline> {
    parseInlineWithContext(text, 0, 0, 0, [], true, true)
}

func parseInlineWithContext(text: String, line: Int64, baseColumn: Int64, baseOffset: Int64, refs: Array<LinkReference>,
    enableHtml: Bool, enableStrikethrough: Bool): Array<MarkdownInline> {
    let out = ArrayList<MarkdownInline>()
    var plain = ""
    var plainStart: Int64 = 0
    var i: Int64 = 0
    while (i < text.size) {
        if (plain.isEmpty()) {
            plainStart = i
        }
        if (text[i] == b'\\' && i + 1 < text.size) {
            let next = nextRuneOffset(text, i + 1)
            plain += text[i + 1..next]
            i = next
            continue
        }
        if (startsWithAt(text, "![", i)) {
            let parsed = parseInlineImage(text, i, line, baseColumn, baseOffset, refs)
            if (let Some(item) <- parsed) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                out.add(item)
                i = rangeEndOffset(item.range, i + 1) - baseOffset
                continue
            }
        }
        if (startsWithAt(text, "[", i)) {
            let parsed = parseInlineLink(text, i, line, baseColumn, baseOffset, refs, enableHtml, enableStrikethrough)
            if (let Some(item) <- parsed) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                out.add(item)
                i = rangeEndOffset(item.range, i + 1) - baseOffset
                continue
            }
        }
        if (startsWithAt(text, "<", i)) {
            let parsed = parseAutoLink(text, i, line, baseColumn, baseOffset)
            if (let Some(item) <- parsed) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                out.add(item)
                i = rangeEndOffset(item.range, i + 1) - baseOffset
                continue
            }
            if (enableHtml) {
                let htmlEnd = findByteFrom(text, b'>', i + 1)
                if (htmlEnd >= 0) {
                    flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                    plain = ""
                    out.add(
                        MarkdownInline(MarkdownInlineKind.HtmlInline, text[i..htmlEnd + 1],
                            range: Some(inlineRange(line, baseColumn, baseOffset, i, htmlEnd + 1))))
                    i = htmlEnd + 1
                    continue
                }
            }
        }
        if (startsWithAt(text, "`", i)) {
            let marker = codeSpanMarker(text, i)
            let end = findStringFrom(text, marker, i + marker.size)
            if (end >= 0) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                out.add(
                    MarkdownInline(MarkdownInlineKind.Code, text[i + marker.size..end],
                        range: Some(inlineRange(line, baseColumn, baseOffset, i, end + marker.size))))
                i = end + marker.size
                continue
            }
        }
        if (enableStrikethrough && startsWithAt(text, "~~", i)) {
            let end = findStringFrom(text, "~~", i + 2)
            if (end >= 0) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                let inner = text[i + 2..end]
                out.add(
                    MarkdownInline(
                        MarkdownInlineKind.Strikethrough,
                        inner,
                        children: parseInlineWithContext(inner, line, baseColumn + i + 2, baseOffset + i + 2, refs,
                            enableHtml, enableStrikethrough),
                        range: Some(inlineRange(line, baseColumn, baseOffset, i, end + 2))
                    )
                )
                i = end + 2
                continue
            }
        }
        if (startsWithAt(text, "***", i) || startsWithAt(text, "___", i)) {
            let marker = text[i..i + 3]
            let end = findStringFrom(text, marker, i + 3)
            if (end >= 0) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                let inner = text[i + 3..end]
                out.add(
                    MarkdownInline(
                        MarkdownInlineKind.Strong,
                        inner,
                        children: [
                            MarkdownInline(
                                MarkdownInlineKind.Emphasis,
                                inner,
                                children: parseInlineWithContext(inner, line, baseColumn + i + 3, baseOffset + i + 3,
                                    refs, enableHtml, enableStrikethrough),
                                range: Some(inlineRange(line, baseColumn, baseOffset, i + 3, end))
                            )
                        ],
                        range: Some(inlineRange(line, baseColumn, baseOffset, i, end + 3))
                    )
                )
                i = end + 3
                continue
            }
        }
        if (startsWithAt(text, "**", i) || startsWithAt(text, "__", i)) {
            let marker = text[i..i + 2]
            let end = findStringFrom(text, marker, i + 2)
            if (end >= 0) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                let inner = text[i + 2..end]
                out.add(
                    MarkdownInline(
                        MarkdownInlineKind.Strong,
                        inner,
                        children: parseInlineWithContext(inner, line, baseColumn + i + 2, baseOffset + i + 2, refs,
                            enableHtml, enableStrikethrough),
                        range: Some(inlineRange(line, baseColumn, baseOffset, i, end + 2))
                    )
                )
                i = end + 2
                continue
            }
        }
        if (startsWithAt(text, "*", i) || startsWithAt(text, "_", i)) {
            let marker = text[i..i + 1]
            let end = findStringFrom(text, marker, i + 1)
            if (end >= 0) {
                flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
                plain = ""
                let inner = text[i + 1..end]
                out.add(
                    MarkdownInline(
                        MarkdownInlineKind.Emphasis,
                        inner,
                        children: parseInlineWithContext(inner, line, baseColumn + i + 1, baseOffset + i + 1, refs,
                            enableHtml, enableStrikethrough),
                        range: Some(inlineRange(line, baseColumn, baseOffset, i, end + 1))
                    )
                )
                i = end + 1
                continue
            }
        }
        if (startsWithAt(text, "  \n", i)) {
            flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, i)
            plain = ""
            out.add(
                MarkdownInline(MarkdownInlineKind.HardBreak, "",
                    range: Some(inlineRange(line, baseColumn, baseOffset, i, i + 3))))
            i += 3
            continue
        }
        let next = nextRuneOffset(text, i)
        plain += text[i..next]
        i = next
    }
    flushPlain(out, plain, line, baseColumn, baseOffset, plainStart, text.size)
    out.toArray()
}

func parseInlineLink(text: String, start: Int64, line: Int64, baseColumn: Int64, baseOffset: Int64,
    refs: Array<LinkReference>, enableHtml: Bool, enableStrikethrough: Bool): ?MarkdownInline {
    let close = findByteFrom(text, b']', start + 1)
    if (close < 0) {
        return None
    }
    if (close + 1 < text.size && text[close + 1] == b'(') {
        let urlEnd = findByteFrom(text, b')', close + 2)
        if (urlEnd >= 0) {
            let (url, title) = splitLinkTarget(text[close + 2..urlEnd])
            let inner = text[start + 1..close]
            return Some(
                MarkdownInline(MarkdownInlineKind.Link(url, title), inner,
                    children: parseInlineWithContext(inner, line, baseColumn + start + 1, baseOffset + start + 1, refs,
                        enableHtml, enableStrikethrough),
                    range: Some(inlineRange(line, baseColumn, baseOffset, start, urlEnd + 1))))
        }
    }
    if (close + 1 < text.size && text[close + 1] == b'[') {
        let refEnd = findByteFrom(text, b']', close + 2)
        if (refEnd >= 0) {
            let id = text[close + 2..refEnd]
            match (lookupReference(refs, if (id.isEmpty()) {
                text[start + 1..close]
            } else {
                id
            })) {
                case Some(ref) =>
                    let inner = text[start + 1..close]
                    return Some(
                        MarkdownInline(MarkdownInlineKind.Link(ref.url, ref.title), inner,
                            children: parseInlineWithContext(inner, line, baseColumn + start + 1, baseOffset + start + 1,
                                refs, enableHtml, enableStrikethrough),
                            range: Some(inlineRange(line, baseColumn, baseOffset, start, refEnd + 1))))
                case None => ()
            }
        }
    }
    match (lookupReference(refs, text[start + 1..close])) {
        case Some(ref) =>
            let inner = text[start + 1..close]
            return Some(
                MarkdownInline(MarkdownInlineKind.Link(ref.url, ref.title), inner,
                    children: parseInlineWithContext(inner, line, baseColumn + start + 1, baseOffset + start + 1, refs,
                        enableHtml, enableStrikethrough),
                    range: Some(inlineRange(line, baseColumn, baseOffset, start, close + 1))))
        case None => ()
    }
    None
}

func parseInlineImage(text: String, start: Int64, line: Int64, baseColumn: Int64, baseOffset: Int64,
    refs: Array<LinkReference>): ?MarkdownInline {
    let close = findByteFrom(text, b']', start + 2)
    if (close < 0) {
        return None
    }
    if (close + 1 < text.size && text[close + 1] == b'(') {
        let urlEnd = findByteFrom(text, b')', close + 2)
        if (urlEnd >= 0) {
            let (url, _) = splitLinkTarget(text[close + 2..urlEnd])
            return Some(
                MarkdownInline(MarkdownInlineKind.Image(url), text[start + 2..close],
                    range: Some(inlineRange(line, baseColumn, baseOffset, start, urlEnd + 1))))
        }
    }
    if (close + 1 < text.size && text[close + 1] == b'[') {
        let refEnd = findByteFrom(text, b']', close + 2)
        if (refEnd >= 0) {
            let id = text[close + 2..refEnd]
            match (lookupReference(refs, if (id.isEmpty()) {
                text[start + 2..close]
            } else {
                id
            })) {
                case Some(ref) => return Some(
                    MarkdownInline(MarkdownInlineKind.Image(ref.url), text[start + 2..close],
                        range: Some(inlineRange(line, baseColumn, baseOffset, start, refEnd + 1))))
                case None => ()
            }
        }
    }
    None
}

func parseAutoLink(text: String, start: Int64, line: Int64, baseColumn: Int64, baseOffset: Int64): ?MarkdownInline {
    let end = findByteFrom(text, b'>', start + 1)
    if (end < 0) {
        return None
    }
    let body = text[start + 1..end]
    if (body.startsWith("http://") || body.startsWith("https://") || body.contains("@")) {
        return Some(
            MarkdownInline(MarkdownInlineKind.Link(body, ""), body,
                range: Some(inlineRange(line, baseColumn, baseOffset, start, end + 1))))
    }
    None
}

func inlineRange(line: Int64, baseColumn: Int64, baseOffset: Int64, start: Int64, end: Int64): SourceRange {
    SourceRange(SourcePos(line, baseColumn + start, baseOffset + start), SourcePos(line, baseColumn + end,
        baseOffset + end))
}

func rangeEndOffset(range: ?SourceRange, fallback: Int64): Int64 {
    match (range) {
        case Some(r) => r.end.offset
        case None => fallback
    }
}

func tableAlignments(line: String): Array<MarkdownTableAlign> {
    let aligns = ArrayList<MarkdownTableAlign>()
    for (cell in splitTableLine(line)) {
        let left = cell.startsWith(":")
        let right = cell.endsWith(":")
        if (left && right) {
            aligns.add(MarkdownTableAlign.Center)
        } else if (right) {
            aligns.add(MarkdownTableAlign.Right)
        } else if (left) {
            aligns.add(MarkdownTableAlign.Left)
        } else {
            aligns.add(MarkdownTableAlign.None)
        }
    }
    aligns.toArray()
}

func isTableStart(lines: Array<LineInfo>, index: Int64): Bool {
    index + 1 < lines.size && isMarkdownTableRow(lines[index].text) && isTableSeparator(lines[index + 1].text)
}

func isSetextHeadingStart(lines: Array<LineInfo>, index: Int64): Bool {
    if (index + 1 >= lines.size) {
        return false
    }
    if (lines[index].text.isEmpty() || lines[index].text.contains("|")) {
        return false
    }
    if (isHeading(lines[index].text) || isUnorderedList(lines[index].text) || isOrderedMarkdownList(lines[index].text) ||
        lines[index].text.startsWith(">") || isFenceStart(lines[index].text)) {
        return false
    }
    let marker = trimMarkdownCell(lines[index + 1].text)
    if (marker.size < 3) {
        return false
    }
    let c = marker[0]
    if (!(c == b'=' || c == b'-')) {
        return false
    }
    var i: Int64 = 0
    while (i < marker.size) {
        if (marker[i] != c) {
            return false
        }
        i++
    }
    true
}

func isTableSeparator(line: String): Bool {
    if (!isMarkdownTableRow(line)) {
        return false
    }
    for (cell in splitTableLine(line)) {
        let stripped = stripColons(cell)
        if (stripped.size < 3) {
            return false
        }
        var i: Int64 = 0
        while (i < stripped.size) {
            if (stripped[i] != b'-') {
                return false
            }
            i++
        }
    }
    true
}

func splitTableLine(line: String): Array<String> {
    let cells = ArrayList<String>()
    var start: Int64 = if (line.startsWith("|")) {
        1
    } else {
        0
    }
    let endLimit: Int64 = if (line.endsWith("|")) {
        line.size - 1
    } else {
        line.size
    }
    var i = start
    while (i <= endLimit) {
        if (i == endLimit || (line[i] == b'|' && !isEscaped(line, i))) {
            cells.add(unescapeTableCell(trimMarkdownCell(line[start..i])))
            start = i + 1
        }
        i++
    }
    cells.toArray()
}

func markdownLines(text: String): Array<LineInfo> {
    let lines = ArrayList<LineInfo>()
    var start: Int64 = 0
    var lineNo: Int64 = 0
    var i: Int64 = 0
    while (i < text.size) {
        if (text[i] == b'\n') {
            lines.add(LineInfo(stripTrailingCarriage(text[start..i]), lineNo, start))
            start = i + 1
            lineNo++
        }
        i++
    }
    if (start <= text.size) {
        lines.add(LineInfo(stripTrailingCarriage(text[start..]), lineNo, start))
    }
    lines.toArray()
}

func isReferenceDefinition(line: String): Bool {
    line.startsWith("[") && line.contains("]:")
}

func isHtmlBlock(line: String): Bool {
    let text = trimMarkdownLeading(line)
    text.startsWith("<") && text.contains(">") && !text.startsWith("<http://") && !text.startsWith("<https://")
}

func referenceParts(line: String): (Bool, String, String, String) {
    let close = findStringFrom(line, "]:", 1)
    if (close < 0) {
        return (false, "", "", "")
    }
    let id = line[1..close]
    let rest = trimMarkdownLeading(line[close + 2..])
    let (url, title) = splitLinkTarget(rest)
    (true, id, url, title)
}

func lookupReference(refs: Array<LinkReference>, id: String): ?LinkReference {
    for (ref in refs) {
        if (lowerAscii(ref.id) == lowerAscii(id)) {
            return Some(ref)
        }
    }
    None
}

func isHeading(line: String): Bool {
    if (!line.startsWith("#")) {
        return false
    }
    let level = markdownHeadingLevel(line)
    level > 0 && level <= 6 && (level == line.size || line[level] == b' ')
}

func markdownHeadingLevel(line: String): Int64 {
    var level: Int64 = 0
    while (level < line.size && level < 6 && line[level] == b'#') {
        level++
    }
    level
}

func isHorizontalRule(line: String): Bool {
    let text = trimMarkdownCell(line)
    if (text.size < 3) {
        return false
    }
    let c = text[0]
    if (!(c == b'-' || c == b'*' || c == b'_')) {
        return false
    }
    var i: Int64 = 0
    var count: Int64 = 0
    while (i < text.size) {
        if (text[i] == c) {
            count++
        } else if (text[i] != b' ') {
            return false
        }
        i++
    }
    count >= 3
}

func isUnorderedList(line: String): Bool {
    let text = trimMarkdownLeading(line)
    text.size >= 2 && (text.startsWith("- ") || text.startsWith("* ") || text.startsWith("+ "))
}

func isOrderedMarkdownList(line: String): Bool {
    let text = trimMarkdownLeading(line)
    var i: Int64 = 0
    while (i < text.size && text[i] >= b'0' && text[i] <= b'9') {
        i++
    }
    i > 0 && i + 1 < text.size && text[i] == b'.' && text[i + 1] == b' '
}

func isIndentedCodeStart(line: String): Bool {
    line.size >= 4 && startsWithAt(line, "    ", 0) && !isUnorderedList(line) && !isOrderedMarkdownList(line)
}

func isListContinuation(line: String): Bool {
    if (line.isEmpty()) {
        return false
    }
    if (isUnorderedList(line) || isOrderedMarkdownList(line) || isQuoteLine(line) || isFenceStart(line) || isHeading(
        line) || isHorizontalRule(line)) {
        return false
    }
    leadingWidth(line) >= 2
}

func canContinueListItem(lines: Array<LineInfo>, index: Int64): Bool {
    if (index < 0 || index >= lines.size) {
        return false
    }
    if (lines[index].text.isEmpty()) {
        if (index + 1 >= lines.size) {
            return false
        }
        return canContinueListItem(lines, index + 1)
    }
    leadingWidth(lines[index].text) >= 2 && (isListContinuation(lines[index].text) || isIndentedChildBlockStart(
        lines[index].text))
}

func isIndentedChildBlockStart(line: String): Bool {
    let text = trimMarkdownLeading(line)
    isFenceStart(text) || isQuoteLine(text) || isHeading(text) || isHorizontalRule(text) || isIndentedCodeStart(line)
}

func isQuoteLine(line: String): Bool {
    trimMarkdownLeading(line).startsWith(">")
}

func quoteMarkerOffset(line: String): Int64 {
    let leading = leadingWidth(line)
    if (leading < line.size && line[leading] == b'>') {
        leading
    } else {
        0
    }
}

func quoteContentOffset(line: String, quoteStart: Int64): Int64 {
    var offset = min(line.size, quoteStart + 1)
    while (offset < line.size && (line[offset] == b' ' || line[offset] == b'\t')) {
        offset++
    }
    offset
}

func itemLevel(block: MarkdownBlock): Int64 {
    match (block.kind) {
        case MarkdownBlockKind.ListItem(_, level) => level
        case MarkdownBlockKind.TaskListItem(_, level) => level
        case _ => 0
    }
}

func withChildren(block: MarkdownBlock, children: Array<MarkdownBlock>): MarkdownBlock {
    MarkdownBlock(block.kind, block.text, inlines: block.inlines, table: block.table, children: children,
        range: block.range)
}

func mergeBlocks(first: Array<MarkdownBlock>, second: Array<MarkdownBlock>): Array<MarkdownBlock> {
    let out = ArrayList<MarkdownBlock>()
    for (block in first) {
        out.add(block)
    }
    for (block in second) {
        out.add(block)
    }
    out.toArray()
}

func nestListItems(items: Array<MarkdownBlock>): Array<MarkdownBlock> {
    if (items.size == 0) {
        return []
    }
    let (nested, _) = nestListItemsAt(items, 0, itemLevel(items[0]))
    nested
}

func nestListItemsAt(items: Array<MarkdownBlock>, start: Int64, level: Int64): (Array<MarkdownBlock>, Int64) {
    let out = ArrayList<MarkdownBlock>()
    var i = start
    while (i < items.size) {
        let currentLevel = itemLevel(items[i])
        if (currentLevel < level) {
            break
        } else if (currentLevel > level) {
            if (out.size == 0) {
                out.add(items[i])
                i++
            } else {
                let (children, next) = nestListItemsAt(items, i, currentLevel)
                let last = out[out.size - 1]
                out[out.size - 1] = withChildren(last, mergeBlocks(last.children, children))
                i = next
            }
        } else {
            out.add(items[i])
            i++
        }
    }
    (out.toArray(), i)
}

func orderedMarkdownContentOffset(line: String): Int64 {
    let text = trimMarkdownLeading(line)
    var i: Int64 = 0
    while (i < text.size && text[i] >= b'0' && text[i] <= b'9') {
        i++
    }
    min(text.size, i + 2)
}

func isFenceStart(line: String): Bool {
    line.startsWith("```") || line.startsWith("~~~")
}

func fenceMarker(line: String): String {
    if (line.startsWith("~~~")) {
        "~~~"
    } else {
        "```"
    }
}

func isMarkdownTableRow(line: String): Bool {
    line.contains("|") && !line.isEmpty()
}

func stripClosingHeading(text: String): String {
    var end = text.size
    while (end > 0 && text[end - 1] == b' ') {
        end--
    }
    var hashStart = end
    while (hashStart > 0 && text[hashStart - 1] == b'#') {
        hashStart--
    }
    if (hashStart > 0 && hashStart < end && text[hashStart - 1] == b' ') {
        return text[..hashStart - 1]
    }
    text[..end]
}

func stripColons(text: String): String {
    var start: Int64 = 0
    var end = text.size
    if (start < end && text[start] == b':') {
        start++
    }
    if (end > start && text[end - 1] == b':') {
        end--
    }
    text[start..end]
}

func stripTrailingCarriage(text: String): String {
    if (text.endsWith("\r")) {
        text[..text.size - 1]
    } else {
        text
    }
}

func hasMarkdownHardBreak(text: String): Bool {
    text.size >= 2 && text[text.size - 1] == b' ' && text[text.size - 2] == b' '
}

func stripMarkdownHardBreak(text: String): String {
    var end = text.size
    while (end > 0 && text[end - 1] == b' ') {
        end--
    }
    text[..end]
}

func trimMarkdownLeading(text: String): String {
    let start = leadingWidth(text)
    text[start..]
}

func leadingWidth(text: String): Int64 {
    var start: Int64 = 0
    while (start < text.size && (text[start] == b' ' || text[start] == b'\t')) {
        start++
    }
    start
}

func skipSpaces(text: String, start: Int64): Int64 {
    var i = start
    while (i < text.size && (text[i] == b' ' || text[i] == b'\t')) {
        i++
    }
    i
}

func indentationLevel(line: String): Int64 {
    var spaces: Int64 = 0
    var i: Int64 = 0
    while (i < line.size && (line[i] == b' ' || line[i] == b'\t')) {
        spaces += if (line[i] == b'\t') {
            4
        } else {
            1
        }
        i++
    }
    spaces / 2
}

func trimMarkdownCell(text: String): String {
    var start: Int64 = 0
    var end = text.size
    while (start < end && (text[start] == b' ' || text[start] == b'\t')) {
        start++
    }
    while (end > start && (text[end - 1] == b' ' || text[end - 1] == b'\t')) {
        end--
    }
    text[start..end]
}

func firstWord(text: String): String {
    var i: Int64 = 0
    while (i < text.size && text[i] != b' ' && text[i] != b'\t') {
        i++
    }
    text[..i]
}

func splitLinkTarget(target: String): (String, String) {
    let quoteIndex = findByteFrom(target, b'"', 0)
    if (quoteIndex < 0) {
        return (target, "")
    }
    let end = findByteFrom(target, b'"', quoteIndex + 1)
    if (end < 0) {
        return (target, "")
    }
    (trimMarkdownCell(target[..quoteIndex]), target[quoteIndex + 1..end])
}

func flushPlain(out: ArrayList<MarkdownInline>, text: String, line: Int64, baseColumn: Int64, baseOffset: Int64,
    start: Int64, end: Int64): Unit {
    if (!text.isEmpty()) {
        out.add(
            MarkdownInline(MarkdownInlineKind.Text, text, range: Some(inlineRange(line, baseColumn, baseOffset, start,
                end))))
    }
}

func findByteFrom(text: String, value: Byte, start: Int64): Int64 {
    var i = start
    while (i < text.size) {
        if (text[i] == value) {
            return i
        }
        i++
    }
    -1
}

func findStringFrom(text: String, needle: String, start: Int64): Int64 {
    var i = start
    while (i + needle.size <= text.size) {
        if (startsWithAt(text, needle, i)) {
            return i
        }
        i++
    }
    -1
}

func codeSpanMarker(text: String, start: Int64): String {
    var i = start
    var marker = ""
    while (i < text.size && text[i] == b'`') {
        marker += "`"
        i++
    }
    marker
}

func isEscaped(text: String, index: Int64): Bool {
    if (index <= 0) {
        return false
    }
    var slashCount: Int64 = 0
    var i = index - 1
    while (i >= 0 && text[i] == b'\\') {
        slashCount++
        i--
    }
    slashCount % 2 == 1
}

func unescapeTableCell(text: String): String {
    var out = ""
    var i: Int64 = 0
    while (i < text.size) {
        if (text[i] == b'\\' && i + 1 < text.size && text[i + 1] == b'|') {
            out += "|"
            i += 2
        } else {
            let next = nextRuneOffset(text, i)
            out += text[i..next]
            i = next
        }
    }
    out
}

func startsWithAt(text: String, needle: String, offset: Int64): Bool {
    if (offset + needle.size > text.size) {
        return false
    }
    for (i in 0..needle.size) {
        if (text[offset + i] != needle[i]) {
            return false
        }
    }
    true
}

func lowerAscii(text: String): String {
    var out = ""
    var i: Int64 = 0
    while (i < text.size) {
        let b = text[i]
        if (b >= b'A' && b <= b'Z') {
            out += String.fromUtf8([b + 32])
            i++
        } else {
            let next = nextRuneOffset(text, i)
            out += text[i..next]
            i = next
        }
    }
    out
}

func nextRuneOffset(text: String, offset: Int64): Int64 {
    if (offset >= text.size) {
        return text.size
    }
    let first = text[offset]
    let width: Int64 = if ((first & 0b1000_0000) == 0) {
        1
    } else if ((first & 0b1110_0000) == 0b1100_0000) {
        2
    } else if ((first & 0b1111_0000) == 0b1110_0000) {
        3
    } else if ((first & 0b1111_1000) == 0b1111_0000) {
        4
    } else {
        1
    }
    min(text.size, offset + width)
}

// Back up from a possibly mid-rune byte offset to the rune's first byte.
func clampRuneStart(text: String, offset: Int64): Int64 {
    var pos = min(max(0, offset), text.size)
    while (pos > 0 && (text[pos] & 0b1100_0000) == 0b1000_0000) {
        pos--
    }
    pos
}

// Extract exactly one rune at (possibly mid-rune) byte offset; "" when out
// of bounds. Never constructs a String from a split UTF-8 sequence.
func runeSlice(text: String, offset: Int64): String {
    if (offset < 0 || offset >= text.size) {
        return ""
    }
    let start = clampRuneStart(text, offset)
    text[start..nextRuneOffset(text, start)]
}

// Check whether a task-list marker ("[ ]" unchecked / "[x]" checked)
// starts at byte offset. Rune-safe: the offset may sit at a multi-byte
// character, so fixed-length byte slicing is never used.
func taskMarkerAt(text: String, offset: Int64): (Bool, Bool) {
    let first = runeSlice(text, offset)
    if (first != "[") {
        return (false, false)
    }
    let second = runeSlice(text, nextRuneOffset(text, clampRuneStart(text, offset)))
    if (second == " ") {
        let third = runeSlice(text, nextRuneOffset(text, nextRuneOffset(text, clampRuneStart(text, offset))))
        if (third == "]") {
            return (true, false)
        }
        return (false, false)
    }
    if (second == "x" || second == "X") {
        let third = runeSlice(text, nextRuneOffset(text, nextRuneOffset(text, clampRuneStart(text, offset))))
        if (third == "]") {
            return (true, true)
        }
        return (false, false)
    }
    (false, false)
}

func joinMarkdown(parts: Array<String>, sep: String): String {
    var out = ""
    for (i in 0..parts.size) {
        if (i > 0) {
            out += sep
        }
        out += parts[i]
    }
    out
}
