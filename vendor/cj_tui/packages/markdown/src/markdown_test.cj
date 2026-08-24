package markdown

import cj_markdown.{parseMarkdown}
import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MarkdownExtensionTest {
    @TestCase
    func parsesMarkdownIntoDocumentLines(): Unit {
        let doc = Markdown.parse("# Title\n\n- item\n> note\n```cj\nmain\n```\n| a | b |\n| --- | --- |\n| c | d |")
        @Expect(doc.lines.size, 7)
        match (doc.lines[0].kind) {
            case DocumentLineKind.Heading(level) => @Expect(level, 1)
            case _ => @Expect(false)
        }
        match (doc.lines[2].kind) {
            case DocumentLineKind.ListItem(false) => ()
            case _ => @Expect(false)
        }
        match (doc.lines[5].kind) {
            case DocumentLineKind.TableHeader => ()
            case _ => @Expect(false)
        }
        @Expect(doc.lines[5].spans[0].text, "a | b")
        @Expect(doc.lines[6].spans[0].text, "c | d")
    }

    @TestCase
    func rendersChineseMarkdownTable(): Unit {
        let doc = Markdown.parse(
            "| 姓名 | 角色 | 状态 |\n| --- | --- | --- |\n| 张三 | 开发者 | 正常 |\n| 李四 | 测试员 | 休假 |")
        @Expect(doc.lines.size, 3)
        match (doc.lines[0].kind) {
            case DocumentLineKind.TableHeader => ()
            case _ => @Expect(false)
        }
        match (doc.lines[1].kind) {
            case DocumentLineKind.TableRow => ()
            case _ => @Expect(false)
        }
        @Expect(doc.lines[0].spans[0].text.startsWith("姓名 | 角色"))
        @Expect(doc.lines[1].spans[0].text.startsWith("张三 | 开发者"))
        @Expect(doc.lines[2].spans[0].text.startsWith("李四 | 测试员"))
    }

    @TestCase
    func preservesMarkdownHardBreaksAsDocumentRows(): Unit {
        let doc = Markdown.parse("/help — Show help  \n/setup — Configure providers")
        @Expect(doc.lines.size, 2)
        @Expect(doc.lines[0].spans[0].text, "/help — Show help")
        @Expect(doc.lines[1].spans[0].text, "/setup — Configure providers")
    }

    @TestCase
    func optionallyPreservesMarkdownSoftBreaksAsDocumentRows(): Unit {
        let defaultDoc = Markdown.parse("first line\nsecond line")
        @Expect(defaultDoc.lines.size, 1)
        @Expect(defaultDoc.lines[0].spans[1].text, " ")

        let preserved = Markdown.parse(
            "first line\nsecond line",
            preserveSoftBreaks: true
        )
        @Expect(preserved.lines.size, 2)
        @Expect(preserved.lines[0].spans[0].text, "first line")
        @Expect(preserved.lines[1].spans[0].text, "second line")
    }

    @TestCase
    func rendersParsedDocumentWithMarkdownView(): Unit {
        let buffer = Buffer(Rect(0, 0, 20, 4))
        DocumentView(Markdown.parse("# Title\n[link](https://example.com)\n**strong**")).render(Rect(0, 0, 20, 3),
            buffer)
        @Expect(buffer.getCell(0, 0).symbol, "#")
        @Expect(buffer.getCell(2, 0).symbol, "T")
        @Expect(buffer.getCell(0, 1).symbol, "l")
        @Expect(buffer.getCell(0, 1).style, Style(fg: Color.Blue))
        @Expect(buffer.getCell(5, 1).symbol, "s")
        @Expect(buffer.getCell(5, 1).style, Style(fg: Color.White, modifier: Modifier.strong()))
    }

    @TestCase
    func mapsHeadingLevelsToPreviewStyles(): Unit {
        let doc = Markdown.parse("# One\n## Two\n### Three")
        let buffer = Buffer(Rect(0, 0, 20, 3))
        DocumentView(doc).render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).style, DocumentTheme().headingStyle(1))
        @Expect(buffer.getCell(0, 1).style, DocumentTheme().headingStyle(2))
        @Expect(buffer.getCell(0, 2).style, DocumentTheme().headingStyle(3))
        @Expect(buffer.getCell(2, 0).style, buffer.getCell(0, 0).style)
        @Expect(buffer.getCell(3, 1).style, buffer.getCell(0, 1).style)
        @Expect(buffer.getCell(4, 2).style, buffer.getCell(0, 2).style)
        @Expect(buffer.getCell(0, 0).symbol, "#")
        @Expect(buffer.getCell(0, 1).symbol, "#")
        @Expect(buffer.getCell(1, 1).symbol, "#")
        @Expect(buffer.getCell(0, 2).symbol, "#")
        @Expect(buffer.getCell(2, 2).symbol, "#")
    }

    @TestCase
    func mapsExtendedMarkdownNodes(): Unit {
        let doc = Markdown.parse("- [x] done\n---\n\n![alt](img.png)\n\n<div>x</div>\n```cj\nopen")
        var task = false
        var rule = false
        var image = false
        var html = false
        var diagnostic = false
        for (line in doc.lines) {
            match (line.kind) {
                case DocumentLineKind.TaskListItem(true) => task = true
                case DocumentLineKind.HorizontalRule => rule = true
                case DocumentLineKind.Image => image = true
                case DocumentLineKind.Html => html = true
                case DocumentLineKind.Diagnostic => diagnostic = true
                case _ => ()
            }
        }
        @Expect(task)
        @Expect(rule)
        @Expect(image)
        @Expect(html)
        @Expect(diagnostic)
    }

    @TestCase
    func mapsStrikethroughAndSourceOffsets(): Unit {
        let doc = Markdown.parse("A ~~gone~~")
        @Expect(doc.lines[0].spans[1].style, DocumentTheme().strikethrough)
        match (doc.lines[0].spans[1].sourceRange) {
            case Some(value) => @Expect(value.contains(":"))
            case None => @Expect(false)
        }
    }

    @TestCase
    func rendersNestedEmphasisStyles(): Unit {
        let doc = Markdown.parse("***both***")
        var modifier = Modifier.strong()
        modifier.italic = true
        @Expect(doc.lines[0].spans[0].text, "both")
        @Expect(doc.lines[0].spans[0].style, Style(fg: Color.White, modifier: modifier))
    }

    @TestCase
    func rendersNestedListItemsFromAstChildren(): Unit {
        let doc = Markdown.parse("- parent\n  - child")
        @Expect(doc.lines.size, 2)
        @Expect(doc.lines[1].spans[0].text, "  ")
        match (doc.lines[1].kind) {
            case DocumentLineKind.ListItem(false) => ()
            case _ => @Expect(false)
        }
    }

    @TestCase
    func buildsOutlineAndPreviewIndex(): Unit {
        let ast = parseMarkdown("# A\n\n## B\n\ntext")
        let outline = markdownOutline(ast)
        @Expect(outline.size, 1)
        @Expect(outline[0].title, "A")
        @Expect(outline[0].children.size, 1)
        @Expect(outline[0].children[0].title, "B")
        let doc = markdownAstToDocument(ast)
        let index = markdownPreviewIndex(doc, 20)
        @Expect(index.renderedLineCount() > 0)
        @Expect(index.renderedLineForSourceOffset(outline[0].children[0].sourceOffset) >= 0)
        match (index.sourceOffsetForRenderedLine(0)) {
            case Some(offset) => @Expect(offset, 2)
            case None => @Expect(false)
        }
    }

    @TestCase
    func adapterPreservesTableAlignmentEscapesDiagnosticsAndWrappedOffsets(): Unit {
        let tableDoc = Markdown.parse("| name | score |\n| :--- | ---: |\n| a\\|b | 9 |\n| 中文 | 12 |")
        @Expect(tableDoc.lines.size, 3)
        @Expect(tableDoc.lines[0].spans[0].text, "name | score")
        @Expect(tableDoc.lines[1].spans[0].text, "a|b  |     9")
        @Expect(tableDoc.lines[2].spans[0].text, "中文 |    12")
        match (tableDoc.lines[1].kind) {
            case DocumentLineKind.TableRow => ()
            case _ => @Expect(false)
        }

        let diagnosticDoc = Markdown.parse("```cj\nopen")
        var foundDiagnostic = false
        for (line in diagnosticDoc.lines) {
            match (line.kind) {
                case DocumentLineKind.Diagnostic =>
                    foundDiagnostic = true
                    @Expect(line.spans[0].text.startsWith("warning: "))
                    match (line.spans[0].sourceRange) {
                        case Some(range) => @Expect(range.contains(":"))
                        case None => @Expect(false)
                    }
                case _ => ()
            }
        }
        @Expect(foundDiagnostic)

        let wrappedDoc = Markdown.parse("# Heading\n\nabcdef ghijkl")
        let index = markdownPreviewIndex(wrappedDoc, 8)
        @Expect(index.renderedLineCount() >= 3)
        match (index.sourceOffsetForRenderedLine(0)) {
            case Some(offset) => @Expect(offset >= 0)
            case None => @Expect(false)
        }
        @Expect(index.renderedLineForSourceOffset(10) >= 0)
    }

    @TestCase
    func rendersFocusedMarkdownPreviewCases(): Unit {
        let doc = Markdown.parse(
            "# Title\n\n- item\n\n```cj\nmain\n```\n\n| 名 | 值 |\n| --- | --- |\n| 张三 | 正常 |\n\n[link](https://example.com) **strong** *em* ~~old~~ `code`")
        var hasLink = false
        var hasStrong = false
        var hasItalic = false
        var hasStrike = false
        var hasInlineCode = false
        for (line in doc.lines) {
            for (span in line.spans) {
                match (span.linkUrl) {
                    case Some(_) => hasLink = true
                    case None => ()
                }
                if (span.style == DocumentTheme().strong) {
                    hasStrong = true
                }
                if (span.style == DocumentTheme().emphasis) {
                    hasItalic = true
                }
                if (span.style == DocumentTheme().strikethrough) {
                    hasStrike = true
                }
                if (span.style == DocumentTheme().inlineCode) {
                    hasInlineCode = true
                }
            }
        }
        @Expect(hasLink)
        @Expect(hasStrong)
        @Expect(hasItalic)
        @Expect(hasStrike)
        @Expect(hasInlineCode)

        let buffer = Buffer(Rect(0, 0, 80, 24))
        DocumentView(doc).render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "#")
        @Expect(buffer.getCell(2, 0).symbol, "T")
        @Expect(renderedRow(buffer, 0, 16).startsWith("# Title"))
        @Expect(buffer.getCell(0, 0).style, DocumentTheme().headingStyle(1))

        let listBuffer = Buffer(Rect(0, 0, 80, 4))
        DocumentView(doc, scroll: firstLineIndexContaining(doc, "item")).render(listBuffer.area, listBuffer)
        @Expect(renderedRow(listBuffer, 0, 16).startsWith("* item"))
        @Expect(listBuffer.getCell(0, 0).style, DocumentTheme().list)

        let codeBuffer = Buffer(Rect(0, 0, 80, 4))
        DocumentView(doc, scroll: firstLineIndexContaining(doc, "main")).render(codeBuffer.area, codeBuffer)
        @Expect(renderedRow(codeBuffer, 0, 16).startsWith("main"))
        @Expect(codeBuffer.getCell(0, 0).style, DocumentTheme().code)

        let tableBuffer = Buffer(Rect(0, 0, 80, 4))
        DocumentView(doc, scroll: firstTableHeaderLine(doc)).render(tableBuffer.area, tableBuffer)
        @Expect(renderedRow(tableBuffer, 0, 16).startsWith("名   | 值"))
        @Expect(renderedRow(tableBuffer, 1, 16).contains("张三"))
        @Expect(renderedRow(tableBuffer, 1, 16).contains("正常"))
        @Expect(tableBuffer.getCell(0, 0).style, DocumentTheme().tableHeader)
        @Expect(tableBuffer.getCell(0, 1).style, DocumentTheme().table)
    }

    @TestCase
    func rendersNestedBlockQuotesWithDepth(): Unit {
        let doc = Markdown.parse("> one\n> > two\n> > > three")
        @Expect(doc.lines.size, 3)
        @Expect(doc.lines[0].quoteDepth, 1)
        @Expect(doc.lines[1].quoteDepth, 2)
        @Expect(doc.lines[2].quoteDepth, 3)

        let buffer = Buffer(Rect(0, 0, 40, 3))
        DocumentView(doc).render(buffer.area, buffer)
        @Expect(renderedRow(buffer, 0, 12).startsWith("| one"))
        @Expect(renderedRow(buffer, 1, 12).startsWith("| | two"))
        @Expect(renderedRow(buffer, 2, 14).startsWith("| | | three"))
        @Expect(buffer.getCell(0, 0).style, DocumentTheme().quoteStyle)
        @Expect(buffer.getCell(2, 1).style, DocumentTheme().quoteStyle)
        @Expect(buffer.getCell(4, 2).style, DocumentTheme().quoteStyle)
    }

    @TestCase
    func rendersBlockElementsInsideQuotes(): Unit {
        let doc = Markdown.parse("> - item\n> ```cj\n> let x = 1\n> ```")
        @Expect(doc.lines.size, 2)
        @Expect(doc.lines[0].quoteDepth, 1)
        @Expect(doc.lines[1].quoteDepth, 1)
        match (doc.lines[0].kind) {
            case DocumentLineKind.ListItem(false) => ()
            case _ => @Expect(false)
        }
        match (doc.lines[1].kind) {
            case DocumentLineKind.CodeBlock => ()
            case _ => @Expect(false)
        }

        let buffer = Buffer(Rect(0, 0, 40, 2))
        DocumentView(doc).render(buffer.area, buffer)
        @Expect(renderedRow(buffer, 0, 16).startsWith("| * item"))
        @Expect(renderedRow(buffer, 1, 16).startsWith("| let x = 1"))
        @Expect(buffer.getCell(0, 0).style, DocumentTheme().quoteStyle)
        @Expect(buffer.getCell(2, 0).style, DocumentTheme().list)
        @Expect(buffer.getCell(2, 1).style, DocumentTheme().code)

        let index = markdownPreviewIndex(doc, 24)
        @Expect(index.renderedLineCount() >= doc.lines.size)
        match (index.sourceOffsetForRenderedLine(0)) {
            case Some(offset) => @Expect(offset >= 0)
            case None => @Expect(false)
        }
    }

    @TestCase
    func rendersFencedCodeBlockInsideListItem(): Unit {
        let doc = Markdown.parse(
            "1. 第一项\n\n   ```go\n   func main() {\n       fmt.Println(\"Hello\")\n   }\n   ```\n\n2. 第二项")
        @Expect(doc.lines.size, 5)
        match (doc.lines[0].kind) {
            case DocumentLineKind.ListItem(true) => @Expect(doc.lines[0].spans[0].text, "第一项")
            case _ => @Expect(false)
        }
        match (doc.lines[1].kind) {
            case DocumentLineKind.CodeBlock => @Expect(doc.lines[1].spans[0].text, "func main() {")
            case _ => @Expect(false)
        }
        @Expect(doc.lines[2].spans[0].text.startsWith("    fmt.Println"))
        match (doc.lines[4].kind) {
            case DocumentLineKind.ListItem(true) => @Expect(doc.lines[4].spans[0].text, "第二项")
            case _ => @Expect(false)
        }

        let buffer = Buffer(Rect(0, 0, 40, 5))
        DocumentView(doc).render(buffer.area, buffer)
        @Expect(renderedRow(buffer, 0, 16).startsWith("1. 第一项"))
        @Expect(renderedRow(buffer, 1, 16).startsWith("func main()"))
        @Expect(buffer.getCell(0, 1).style, DocumentTheme().code)
        @Expect(renderedRow(buffer, 4, 16).startsWith("1. 第二项"))
    }

    @TestCase
    func quotedChildrenDoNotResetPreviewSourceOffsets(): Unit {
        let text = "# Top\n\nintro\n\n> quote\n> - item"
        let doc = Markdown.parse(text)
        let index = markdownPreviewIndex(doc, 40)
        @Expect(index.renderedLineForSourceOffset(0), 0)
        match (index.sourceOffsetForRenderedLine(4)) {
            case Some(offset) => @Expect(offset > 0)
            case None => @Expect(false)
        }
    }

    @TestCase
    func previewSyncCanMoveUpInsideQuotedBlocks(): Unit {
        let text = "# Top\n\nbefore\n\n> first\n> - second\n> > third\n\nafter"
        let doc = Markdown.parse(text)
        let index = markdownPreviewIndex(doc, 40)
        let firstOffset = byteIndex(text, "first")
        let secondOffset = byteIndex(text, "second")
        let thirdOffset = byteIndex(text, "third")
        @Expect(firstOffset > 0)
        @Expect(secondOffset > firstOffset)
        @Expect(thirdOffset > secondOffset)

        let firstLine = index.renderedLineForSourceOffset(firstOffset)
        let secondLine = index.renderedLineForSourceOffset(secondOffset)
        let thirdLine = index.renderedLineForSourceOffset(thirdOffset)
        @Expect(firstLine < secondLine)
        @Expect(secondLine < thirdLine)
        @Expect(index.renderedLineForSourceOffset(firstOffset), firstLine)
    }
}

func renderedRow(buffer: Buffer, y: Int64, width: Int64): String {
    let builder = StringBuilder()
    for (x in 0..width) {
        builder.append(buffer.getCell(x, y).symbol)
    }
    builder.toString()
}

func firstLineIndexContaining(doc: Document, needle: String): Int64 {
    for (i in 0..doc.lines.size) {
        if (lineText(doc.lines[i]).contains(needle)) {
            return i
        }
    }
    0
}

func firstTableHeaderLine(doc: Document): Int64 {
    for (i in 0..doc.lines.size) {
        match (doc.lines[i].kind) {
            case DocumentLineKind.TableHeader => return i
            case _ => ()
        }
    }
    0
}

func lineText(line: DocumentLine): String {
    let builder = StringBuilder()
    for (span in line.spans) {
        builder.append(span.text)
    }
    builder.toString()
}

func byteIndex(text: String, needle: String): Int64 {
    if (needle.isEmpty()) {
        return 0
    }
    var i: Int64 = 0
    while (i + needle.size <= text.size) {
        var ok = true
        for (j in 0..needle.size) {
            if (text[i + j] != needle[j]) {
                ok = false
            }
        }
        if (ok) {
            return i
        }
        i++
    }
    -1
}
