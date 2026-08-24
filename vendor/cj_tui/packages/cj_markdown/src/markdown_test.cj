package cj_markdown

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MarkdownParserTest {
    private var rngState: Int64 = 20260804

    private func nextRandom(): Int64 {
        rngState = (rngState * 1103515245 + 12345) % 2147483647
        rngState
    }
    @TestCase
    func parsesBlockKindsAndMetadata(): Unit {
        let doc = parseMarkdown("# Title ###\n\n- item\n  1. ordered\n> quote\n```cj\nmain\n```\n| a | b |\n| :--- | ---: |\n| c | d |")
        @Expect(doc.blocks.size, 6)
        match (doc.blocks[0].kind) {
            case MarkdownBlockKind.Heading(level) => @Expect(level, 1)
            case _ => @Expect(false)
        }
        @Expect(doc.blocks[0].text, "Title")
        match (doc.blocks[2].kind) {
            case MarkdownBlockKind.List =>
                @Expect(doc.blocks[2].children.size, 1)
                match (doc.blocks[2].children[0].kind) {
                    case MarkdownBlockKind.ListItem(false, level) => @Expect(level, 0)
                    case _ => @Expect(false)
                }
                @Expect(doc.blocks[2].children[0].children.size, 1)
                match (doc.blocks[2].children[0].children[0].kind) {
                    case MarkdownBlockKind.ListItem(true, level) => @Expect(level, 1)
                    case _ => @Expect(false)
                }
            case _ => @Expect(false)
        }
        match (doc.blocks[4].kind) {
            case MarkdownBlockKind.CodeBlock(language) => @Expect(language, "cj")
            case _ => @Expect(false)
        }
        @Expect(doc.blocks[4].text, "main")
        match (doc.blocks[5].table) {
            case Some(table) =>
                @Expect(table.header.cells[0].text, "a")
                @Expect(table.rows[0].cells[1].text, "d")
                match (table.alignments[0]) {
                    case MarkdownTableAlign.Left => ()
                    case _ => @Expect(false)
                }
                match (table.alignments[1]) {
                    case MarkdownTableAlign.Right => ()
                    case _ => @Expect(false)
                }
            case None => @Expect(false)
        }
    }

    @TestCase
    func parsesSourceRangesTaskListAndDiagnostics(): Unit {
        let doc = parseMarkdown("# A\n- [x] done\n---\n```cj\nopen")
        match (doc.blocks[0].range) {
            case Some(range) =>
                @Expect(range.start.line, 0)
                @Expect(range.start.offset, 0)
            case None => @Expect(false)
        }
        match (doc.blocks[1].children[0].kind) {
            case MarkdownBlockKind.TaskListItem(true, level) => @Expect(level, 0)
            case _ => @Expect(false)
        }
        match (doc.blocks[2].kind) {
            case MarkdownBlockKind.HorizontalRule => ()
            case _ => @Expect(false)
        }
        @Expect(doc.diagnostics.size, 1)
    }

    @TestCase
    func parsesSetextHtmlStrikethroughAndInlineChildren(): Unit {
        let doc = parseMarkdown("Title\n===\n\n<div>x</div>\n\nA ~~gone~~ and **[link](url)**")
        match (doc.blocks[0].kind) {
            case MarkdownBlockKind.Heading(level) => @Expect(level, 1)
            case _ => @Expect(false)
        }
        match (doc.blocks[2].kind) {
            case MarkdownBlockKind.HtmlBlock => @Expect(doc.blocks[2].text, "<div>x</div>")
            case _ => @Expect(false)
        }
        let inlines = doc.blocks[4].inlines
        match (inlines[1].kind) {
            case MarkdownInlineKind.Strikethrough => @Expect(inlines[1].text, "gone")
            case _ => @Expect(false)
        }
        match (inlines[3].kind) {
            case MarkdownInlineKind.Strong =>
                @Expect(inlines[3].children.size, 1)
                match (inlines[3].children[0].kind) {
                    case MarkdownInlineKind.Link(url, _) => @Expect(url, "url")
                    case _ => @Expect(false)
                }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func mergesParagraphLinesAndQuotes(): Unit {
        let doc = parseMarkdown("first line\nsecond line\n\n> a\n> - b")
        @Expect(doc.blocks.size, 3)
        @Expect(doc.blocks[0].text, "first line second line")
        @Expect(doc.blocks[2].text, "a - b")
        @Expect(doc.blocks[2].children.size > 0)
    }

    @TestCase
    func parsesInlineMarkersReferencesAutolinksAndEscapes(): Unit {
        let doc = parseMarkdown("[id]: https://example.com \"t\"\nplain [link][id] ![alt][id] <https://cangjie-lang.cn> `code` **strong** *em* \\*")
        let inlines = doc.blocks[1].inlines
        @Expect(inlines.size, 13)
        match (inlines[1].kind) {
            case MarkdownInlineKind.Link(url, title) =>
                @Expect(url, "https://example.com")
                @Expect(title, "t")
            case _ => @Expect(false)
        }
        match (inlines[3].kind) {
            case MarkdownInlineKind.Image(url) => @Expect(url, "https://example.com")
            case _ => @Expect(false)
        }
        match (inlines[5].kind) {
            case MarkdownInlineKind.Link(url, _) => @Expect(url, "https://cangjie-lang.cn")
            case _ => @Expect(false)
        }
        match (inlines[7].kind) {
            case MarkdownInlineKind.Code => @Expect(inlines[7].text, "code")
            case _ => @Expect(false)
        }
        match (inlines[9].kind) {
            case MarkdownInlineKind.Strong => @Expect(inlines[9].text, "strong")
            case _ => @Expect(false)
        }
        match (inlines[12].kind) {
            case MarkdownInlineKind.Text => @Expect(inlines[12].text, " *")
            case _ => @Expect(false)
        }
        match (inlines[1].range) {
            case Some(range) =>
                @Expect(range.start.offset > 0)
                @Expect(range.start.column < range.start.offset)
            case None => @Expect(false)
        }
    }

    @TestCase
    func preservesParagraphLineSourcesAndAdditionalInlineForms(): Unit {
        let doc = parseMarkdown("[shortcut]: https://example.com\nfirst **line**\nsecond [shortcut] ``code ` span``")
        @Expect(doc.blocks[1].text, "first **line** second [shortcut] ``code ` span``")
        let inlines = doc.blocks[1].inlines
        var sawBreak = false
        var sawShortcut = false
        var sawCode = false
        for (inline in inlines) {
            match (inline.kind) {
                case MarkdownInlineKind.SoftBreak =>
                    sawBreak = true
                    match (inline.range) {
                        case Some(range) => @Expect(range.end.line, 2)
                        case None => @Expect(false)
                    }
                case MarkdownInlineKind.Link(url, _) =>
                    if (url == "https://example.com") { sawShortcut = true }
                case MarkdownInlineKind.Code =>
                    if (inline.text == "code ` span") { sawCode = true }
                case _ => ()
            }
        }
        @Expect(sawBreak)
        @Expect(sawShortcut)
        @Expect(sawCode)
    }

    @TestCase
    func parsesEscapedPipeTableCells(): Unit {
        let doc = parseMarkdown("| a\\|b | c |\n| --- | --- |\n| x | y |")
        match (doc.blocks[0].table) {
            case Some(table) =>
                @Expect(table.header.cells.size, 2)
                @Expect(table.header.cells[0].text, "a|b")
            case None => @Expect(false)
        }
    }

    @TestCase
    func parsesChineseTableAndInlineText(): Unit {
        let doc = parseMarkdown("| 姓名 | 角色 | 状态 |\n| --- | --- | --- |\n| 张三 | 开发者 | 正常 |\n| 李四 | 测试员 | 休假 |")
        @Expect(doc.diagnostics.size, 0)
        match (doc.blocks[0].kind) {
            case MarkdownBlockKind.Table => ()
            case _ => @Expect(false)
        }
        match (doc.blocks[0].table) {
            case Some(table) =>
                @Expect(table.header.cells.size, 3)
                @Expect(table.header.cells[0].text, "姓名")
                @Expect(table.header.cells[1].text, "角色")
                @Expect(table.header.cells[2].text, "状态")
                @Expect(table.rows.size, 2)
                @Expect(table.rows[0].cells[0].text, "张三")
                @Expect(table.rows[0].cells[1].text, "开发者")
                @Expect(table.rows[0].cells[2].text, "正常")
                @Expect(table.rows[1].cells[0].text, "李四")
                @Expect(table.rows[1].cells[1].text, "测试员")
                @Expect(table.rows[1].cells[2].text, "休假")
            case None => @Expect(false)
        }

        let inlineDoc = parseMarkdown("中文 **加粗** 和 [链接](url)")
        @Expect(inlineDoc.blocks.size, 1)
        let inlines = inlineDoc.blocks[0].inlines
        @Expect(inlines[0].text, "中文 ")
        match (inlines[1].kind) {
            case MarkdownInlineKind.Strong => @Expect(inlines[1].text, "加粗")
            case _ => @Expect(false)
        }
        match (inlines[3].kind) {
            case MarkdownInlineKind.Link(url, _) => @Expect(url, "url")
            case _ => @Expect(false)
        }
    }

    @TestCase
    func coversCommonMarkAndGfmInlineRegressions(): Unit {
        let doc = parseMarkdown("***both*** `**code**` [**strong link**](url)\n\n- [ ] todo\n- [x] done\n\n<https://example.com>\n\n| a | b |\n| --- | --- |\n| ~~gone~~ | ok |")
        let first = doc.blocks[0].inlines
        match (first[0].kind) {
            case MarkdownInlineKind.Strong =>
                @Expect(first[0].text, "both")
                @Expect(first[0].children.size, 1)
                match (first[0].children[0].kind) {
                    case MarkdownInlineKind.Emphasis => @Expect(first[0].children[0].text, "both")
                    case _ => @Expect(false)
                }
            case _ => @Expect(false)
        }
        match (first[2].kind) {
            case MarkdownInlineKind.Code => @Expect(first[2].text, "**code**")
            case _ => @Expect(false)
        }
        match (first[4].kind) {
            case MarkdownInlineKind.Link(url, _) =>
                @Expect(url, "url")
                @Expect(first[4].children.size, 1)
                match (first[4].children[0].kind) {
                    case MarkdownInlineKind.Strong => @Expect(first[4].children[0].text, "strong link")
                    case _ => @Expect(false)
                }
            case _ => @Expect(false)
        }
        match (doc.blocks[2].children[0].kind) {
            case MarkdownBlockKind.TaskListItem(false, _) => ()
            case _ => @Expect(false)
        }
        match (doc.blocks[2].children[1].kind) {
            case MarkdownBlockKind.TaskListItem(true, _) => ()
            case _ => @Expect(false)
        }
        match (doc.blocks[4].inlines[0].kind) {
            case MarkdownInlineKind.Link(url, _) => @Expect(url, "https://example.com")
            case _ => @Expect(false)
        }
        match (doc.blocks[6].table) {
            case Some(table) =>
                @Expect(table.rows[0].cells[0].text, "~~gone~~")
                match (table.rows[0].cells[0].inlines[0].kind) {
                    case MarkdownInlineKind.Strikethrough => @Expect(table.rows[0].cells[0].inlines[0].text, "gone")
                    case _ => @Expect(false)
                }
            case None => @Expect(false)
        }
    }

    @TestCase
    func parsesChineseListItemsRuneSafe(): Unit {
        // Regression: the task-marker check sliced the line with a character
        // index on UTF-8 bytes; a multi-byte character right after the list
        // marker split a rune and threw IllegalArgumentException. Parsing
        // must succeed and keep the full text.
        let doc = parseMarkdown("- 🎯 中文任务\n- [x] ✅ 已完成\n12. 有序中文项")
        var sawUnchecked = false
        var sawChecked = false
        var sawOrdered = false
        for (block in doc.blocks) {
            match (block.kind) {
                case MarkdownBlockKind.List =>
                    for (child in block.children) {
                        match (child.kind) {
                            case MarkdownBlockKind.TaskListItem(checked, _) =>
                                sawChecked = checked
                                @Expect(child.text, "✅ 已完成")
                            case MarkdownBlockKind.ListItem(ordered, _) =>
                                if (ordered) { sawOrdered = true }
                                if (child.text == "🎯 中文任务") { sawUnchecked = true }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
        @Expect(sawUnchecked)
        @Expect(sawChecked)
        @Expect(sawOrdered)
    }

    @TestCase
    func nestsListItemsAndIndentedBlockQuotes(): Unit {
        let doc = parseMarkdown("- parent\n  - child\n    - grandchild")
        match (doc.blocks[0].kind) {
            case MarkdownBlockKind.List =>
                @Expect(doc.blocks[0].children.size, 1)
                let parent = doc.blocks[0].children[0]
                @Expect(parent.children.size, 1)
                match (parent.children[0].kind) {
                    case MarkdownBlockKind.ListItem(false, level) => @Expect(level, 1)
                    case _ => @Expect(false)
                }
                @Expect(parent.children[0].children.size, 1)
            case _ => @Expect(false)
        }
        let quotedDoc = parseMarkdown("  > quote")
        match (quotedDoc.blocks[0].kind) {
            case MarkdownBlockKind.Quote => @Expect(quotedDoc.blocks[0].text, "quote")
            case _ => @Expect(false)
        }
    }

    @TestCase
    func parsesIndentedCodeAndListContinuation(): Unit {
        let doc = parseMarkdown("    let x = 1\n    x\n\n- item\n  continuation")
        match (doc.blocks[0].kind) {
            case MarkdownBlockKind.CodeBlock(language) =>
                @Expect(language, "")
                @Expect(doc.blocks[0].text, "let x = 1\nx")
            case _ => @Expect(false)
        }
        match (doc.blocks[2].kind) {
            case MarkdownBlockKind.List =>
                @Expect(doc.blocks[2].children[0].text, "item continuation")
            case _ => @Expect(false)
        }
    }

    @TestCase
    func parsesFencedCodeBlockInsideListItem(): Unit {
        let doc = parseMarkdown("1. 第一项\n\n   ```go\n   func main() {\n       fmt.Println(\"Hello\")\n   }\n   ```\n\n2. 第二项")
        match (doc.blocks[0].kind) {
            case MarkdownBlockKind.List =>
                @Expect(doc.blocks[0].children.size, 2)
                let first = doc.blocks[0].children[0]
                @Expect(first.text, "第一项")
                @Expect(first.children.size, 1)
                match (first.children[0].kind) {
                    case MarkdownBlockKind.CodeBlock(language) =>
                        @Expect(language, "go")
                        @Expect(first.children[0].text.contains("func main()"))
                        @Expect(first.children[0].text.contains("    fmt.Println"))
                    case _ => @Expect(false)
                }
                @Expect(doc.blocks[0].children[1].text, "第二项")
            case _ => @Expect(false)
        }
    }

    @TestCase
    func parsesUtf8BoundarySamples(): Unit {
        // Shared UTF-8 boundary corpus (mirrored in cj_tui core lib_test.cj
        // and agent_tui tui.cj headless): every parse must succeed (no
        // split-rune exceptions) and keep the sample's marker text.
        let samples = [
            ("ascii", "plain ascii body\n\n- item one\n- item two\n\n# Heading\n\n```cj\nmain()\n```\n", "item one"),
            ("two-byte", "Café résumé naïve €50\n\n- édition spéciale\n- piñata ñoño\n", "édition spéciale"),
            ("three-byte", "中文标题\n\n- 列表项一\n- 列表项二\n\n## 二级标题\n\n| 列A | 列B |\n| --- | --- |\n| 甲 | 乙 |\n\n这是一段很长的中文内容。\n", "列表项一"),
            ("four-byte", "🎯 任务列表\n\n- 🎯 任务一\n- [x] ✅ 已完成\n- 🚀 启动\n\n> 引用 🎉\n", "任务一"),
            ("zwj", "家庭 👨👩👧 组合\n\n- 👨👩👧 三个人\n- 组合 🧑🤝🧑 与 🇨🇳\n", "👨👩👧 三个人"),
            ("mixed-long", "🚀 综合样本\n\n# 标题一\n\n- 🎯 中文任务 éé\n- [x] ✅ 完成项\n- 👨👩👧 家庭项\n\n## 二级 **加粗中文**\n\n1. 有序一\n2. 有序二\n\n```\n代码块中文\n```\n\n| 名称 | 状态 |\n| --- | --- |\n| 中文 | ✅ |\n\n很长的一段内容…\n", "中文任务 éé")
        ]
        for (sample in samples) {
            let doc = parseMarkdown(sample[1])
            @Expect(doc.blocks.size > 0)
            var sawMarker = false
            for (block in doc.blocks) {
                if (collectBlockText(block).contains(sample[2])) {
                    sawMarker = true
                }
            }
            if (!sawMarker) {
                println("utf8 sample marker missing: " + sample[0])
            }
            @Expect(sawMarker)
        }
    }

    private func collectBlockText(block: MarkdownBlock): String {
        var out = block.text
        for (child in block.children) {
            out += collectBlockText(child)
        }
        out
    }

    @TestCase
    func fuzzesUtf8MarkdownDeterministically(): Unit {
        // Fixed-seed pseudo-random markdown over a mixed ASCII / 2-byte /
        // 3-byte / 4-byte / ZWJ character table. Parsing must never throw;
        // failures print the sample index and its text for reproduction.
        let chars = [
            "a", "b", "c", "d", "e", "1", "2", "3", " ", " ",
            "-", "*", "#", ">", "|", "`", "[", "]", "(", ")",
            "_", "~", ".", "+", "\n", "é", "ñ", "€", "中", "文",
            "任", "务", "🎯", "✅", "🚀", "👨👩👧"
        ]
        for (sampleNo in 0..120) {
            var text = ""
            let lines = 3 + (nextRandom() % 8)
            for (l in 0..lines) {
                let count = 2 + (nextRandom() % 24)
                for (c in 0..count) {
                    text += chars[Int64(nextRandom() % chars.size)]
                }
                if (l + 1 < lines) { text += "\n" }
            }
            var ok = false
            try {
                let doc = parseMarkdown(text)
                ok = true
            } catch (_: Exception) {
                println("utf8 fuzz sample " + sampleNo.toString() + " threw")
            }
            if (!ok) {
                println("---- sample text ----\n" + text)
                @Expect(false)
            }
        }
    }
}
