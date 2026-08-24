package core

import std.unittest.*
import std.unittest.testmacro.*

func documentStyledSpanCellsMatchLegacy(spans: Array<RichSpan>, width: Int64): Bool {
    let origin: Int64 = 2
    let bufferWidth = width + origin + 2
    let expected = Buffer(Rect(0, 0, bufferWidth, 1))
    var cx = origin
    let right = origin + width
    for (span in spans) {
        if (cx >= right) { break }
        let part = graphemePrefix(span.text, right - cx)
        expected.setString(cx, 0, part, style: span.style)
        cx += displayWidth(part)
    }

    let actual = Buffer(Rect(0, 0, bufferWidth, 1))
    let document = Document([
        DocumentLine(DocumentLineKind.Paragraph, spans)
    ])
    DocumentView(document, wrap: WrapMode.NoWrap).render(Rect(origin, 0, width, 1), actual)
    for (x in 0..bufferWidth) {
        if (actual.getCell(x, 0) != expected.getCell(x, 0)) {
            return false
        }
    }
    true
}

@Test
class CjTuiBoundaryExtremeTest {
    @TestCase
    func zeroSizedBuffersIgnoreWritesAndHaveEmptyDiff(): Unit {
        let empty = Buffer(Rect(0, 0, 0, 0))
        empty.setString(0, 0, "ignored")
        @Expect(empty.getCell(0, 0).symbol, " ")
        @Expect(empty.diff(Buffer(Rect(0, 0, 0, 0))).size, 0)
    }

    @TestCase
    func bufferWriteAtRightEdgeTruncatesSafely(): Unit {
        let buffer = Buffer(Rect(0, 0, 3, 1))
        buffer.setString(2, 0, "abc")
        @Expect(buffer.getCell(2, 0).symbol, "a")
        @Expect(buffer.getCell(0, 0).symbol, " ")
    }

    @TestCase
    func bufferWideCharAtRightEdgeDoesNotWriteContinuationOutsideArea(): Unit {
        let buffer = Buffer(Rect(0, 0, 3, 1))
        buffer.setString(2, 0, "界")
        @Expect(buffer.getCell(2, 0).symbol, " ")
        @Expect(buffer.getCell(3, 0).symbol, " ")
    }

    @TestCase
    func bufferWideCharOverwriteClearsOldContinuation(): Unit {
        let buffer = Buffer(Rect(0, 0, 5, 1))
        buffer.setString(0, 0, "界")
        buffer.setString(1, 0, "x")
        @Expect(buffer.getCell(0, 0).symbol, " ")
        @Expect(buffer.getCell(1, 0).symbol, "x")
    }

    @TestCase
    func bufferResizeToSmallerAreaKeepsIntersection(): Unit {
        let buffer = Buffer(Rect(0, 0, 5, 2))
        buffer.setString(1, 1, "xy")
        let resized = buffer.resize(Rect(0, 0, 2, 2))
        @Expect(resized.getCell(1, 1).symbol, "x")
        @Expect(resized.getCell(2, 1).symbol, " ")
    }

    @TestCase
    func bufferDiffAgainstDifferentAreaTreatsEveryCellAsChanged(): Unit {
        let before = Buffer(Rect(0, 0, 1, 1))
        let after = Buffer(Rect(0, 0, 3, 2))
        @Expect(after.diff(before).size, 6)
    }

    @TestCase
    func layoutEmptyConstraintsReturnNoRects(): Unit {
        @Expect(Layout.horizontal([]).split(Rect(0, 0, 10, 1)).size, 0)
        @Expect(Layout.vertical([]).split(Rect(0, 0, 10, 1)).size, 0)
    }

    @TestCase
    func layoutZeroAreaProducesZeroSizedRects(): Unit {
        let chunks = Layout.horizontal([Constraint.Length(3), Constraint.Min(1)]).split(Rect(0, 0, 0, 0))
        @Expect(chunks.size, 2)
        @Expect(chunks[0].width, 0)
        @Expect(chunks[1].height, 0)
    }

    @TestCase
    func layoutHugeGapCannotCreateNegativeWidths(): Unit {
        let chunks = Layout.horizontal([Constraint.Length(3), Constraint.Length(3)]).withGap(100).split(Rect(0, 0, 4, 1))
        @Expect(chunks.size, 2)
        @Expect(chunks[0].width >= 0)
        @Expect(chunks[1].width >= 0)
    }

    @TestCase
    func layoutPercentAndRatioClampInvalidInputs(): Unit {
        let chunks = Layout.horizontal([
            Constraint.Percent(150),
            Constraint.Percent(-10),
            Constraint.Ratio(1, 0),
            Constraint.Ratio(-1, 2)
        ]).split(Rect(0, 0, 20, 1))
        @Expect(chunks.size, 4)
        @Expect(chunks[0].width <= 20)
        @Expect(chunks[1].width, 0)
        @Expect(chunks[2].width, 0)
        @Expect(chunks[3].width, 0)
    }

    @TestCase
    func spacingLargerThanAreaClampsInnerSizeToZero(): Unit {
        let inner = Spacing.all(10).inner(Rect(1, 2, 3, 4))
        @Expect(inner.x, 11)
        @Expect(inner.y, 12)
        @Expect(inner.width, 0)
        @Expect(inner.height, 0)
    }

    @TestCase
    func gridWithEmptyRowsOrColumnsReturnsEmptyShape(): Unit {
        @Expect(Grid([], [Constraint.Length(1)]).split(Rect(0, 0, 3, 3)).size, 0)
        let rows = Grid([Constraint.Length(1)], []).split(Rect(0, 0, 3, 3))
        @Expect(rows.size, 1)
        @Expect(rows[0].size, 0)
    }

    @TestCase
    func flexLayoutWithNoItemsReturnsNoRects(): Unit {
        @Expect(FlexLayout(Direction.Horizontal, []).split(Rect(0, 0, 10, 1)).size, 0)
    }

    @TestCase
    func flexLayoutHugeGapKeepsNonNegativeRects(): Unit {
        let chunks = FlexLayout(Direction.Horizontal, [FlexItem(basis: 2), FlexItem(basis: 2)], gap: 50).split(Rect(0, 0, 5, 1))
        @Expect(chunks.size, 2)
        @Expect(chunks[0].width >= 0)
        @Expect(chunks[1].width >= 0)
    }

    @TestCase
    func layoutCacheReusesUntilInvalidated(): Unit {
        let cache = LayoutCache()
        let first = cache.get(Rect(0, 0, 10, 1), { area => [area] })
        let second = cache.get(Rect(0, 0, 10, 1), { area => [Rect(area.x + 1, area.y, area.width, area.height)] })
        @Expect(first.size, 1)
        @Expect(second.size, 1)
        @Expect(second[0].x, 0)
        cache.invalidate()
        let third = cache.get(Rect(0, 0, 10, 1), { area => [Rect(area.x + 1, area.y, area.width, area.height)] })
        @Expect(third[0].x, 1)
    }

    @TestCase
    func eventParserKeepsPartialUtf8UntilComplete(): Unit {
        let parser = EventParser()
        @Expect(parser.push([0xE7]).size, 0)
        @Expect(parser.push([0x95]).size, 0)
        let events = parser.push([0x8C])
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Char(r'界') => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserKeepsPartialCsiUntilTerminator(): Unit {
        let parser = EventParser()
        @Expect(parser.push([0x1B, b'[']).size, 0)
        let events = parser.push([b'A'])
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.KeyDown(k) => match (k.code) {
                case KeyCode.Up => ()
                case _ => @Expect(false)
            }
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserUnknownMouseSequenceDoesNotCrash(): Unit {
        let events = EventParser().push(unsafe { "\u{1B}[<badM".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.Unknown(bytes) => @Expect(bytes.size > 0)
            case _ => @Expect(false)
        }
    }

    @TestCase
    func eventParserPartialBracketedPasteWaitsForEndMarker(): Unit {
        let parser = EventParser()
        @Expect(parser.push(unsafe { "\u{1B}[200~hello".rawData() }).size, 0)
        let events = parser.push(unsafe { "\u{1B}[201~".rawData() })
        @Expect(events.size, 1)
        match (events[0]) {
            case Event.Paste(text) => @Expect(text, "hello")
            case _ => @Expect(false)
        }
    }

    @TestCase
    func textBufferEmptyNeedlesAreNoops(): Unit {
        let buffer = TextBuffer(text: "abc")
        match (buffer.find("")) {
            case Some(_) => @Expect(false)
            case None => ()
        }
        @Expect(buffer.findAll("").size, 0)
        @Expect(buffer.replaceAll("", "x"), 0)
        @Expect(buffer.text(), "abc")
    }

    @TestCase
    func textBufferClampExtremePositions(): Unit {
        let buffer = TextBuffer(text: "a\nbc")
        @Expect(buffer.clampPosition(TextPosition(99, 99)), TextPosition(1, 2))
        @Expect(buffer.clampPosition(TextPosition(0, 99)), TextPosition(0, 1))
    }

    @TestCase
    func textBufferDeleteAcrossWholeDocumentLeavesSingleEmptyLine(): Unit {
        let buffer = TextBuffer(text: "one\ntwo\nthree")
        _ = buffer.deleteRange(TextRange(TextPosition(0, 0), TextPosition(2, 5)))
        @Expect(buffer.lineCount(), 1)
        @Expect(buffer.text(), "")
    }

    @TestCase
    func textBufferLargeInsertFindAndUndo(): Unit {
        let buffer = TextBuffer(text: "")
        var text = ""
        for (_ in 0..200) { text += "x" }
        _ = buffer.insert(TextPosition(0, 0), text + "END")
        match (buffer.find("END")) {
            case Some(pos) => @Expect(pos.column, 200)
            case None => @Expect(false)
        }
        @Expect(buffer.undo())
        @Expect(buffer.text(), "")
    }

    @TestCase
    func paragraphZeroAreaAndHugeTextDoNotMutateBuffer(): Unit {
        let buffer = Buffer(Rect(0, 0, 4, 1))
        buffer.setString(0, 0, "keep")
        var text = ""
        for (_ in 0..200) { text += "x" }
        Paragraph(text).render(Rect(0, 0, 0, 0), buffer)
        @Expect(buffer.getCell(0, 0).symbol, "k")
    }

    @TestCase
    func paragraphTinyWidthWrapsCjkWithoutOverflow(): Unit {
        let buffer = Buffer(Rect(0, 0, 2, 4))
        Paragraph("界界界").render(buffer.area, buffer)
        @Expect(buffer.getCell(0, 0).symbol, "界")
        @Expect(buffer.getCell(0, 1).symbol, "界")
    }

    @TestCase
    func inputExtremeCursorClampsToRuneBoundary(): Unit {
        let input = Input(value: "a界b", cursor: 999)
        @Expect(input.cursor, "a界b".size)
        @Expect(input.handle(KeyEvent(KeyCode.Left)))
        @Expect(input.cursor < "a界b".size)
    }

    @TestCase
    func inputZeroWidthCursorPositionDoesNotOverflow(): Unit {
        let input = Input(value: "abcdef", cursor: 6)
        let pos = input.cursorPosition(Rect(10, 5, 0, 1))
        @Expect(pos.x, 10)
        @Expect(pos.y, 5)
    }

    @TestCase
    func listStateEmptyTotalClearsSelectionAndOffset(): Unit {
        let state = ListState(selected: Some(10), offset: 7)
        state.move(1, 0, viewportHeight: 3)
        match (state.selected) {
            case Some(_) => @Expect(false)
            case None => ()
        }
        @Expect(state.offset, 0)
    }

    @TestCase
    func listRenderEmptyAndTinyAreaDoesNotCrash(): Unit {
        let buffer = Buffer(Rect(0, 0, 1, 1))
        List([]).render(Rect(0, 0, 1, 1), buffer)
        @Expect(buffer.getCell(0, 0).symbol, " ")
        List(["one"]).render(Rect(0, 0, 0, 0), buffer)
        @Expect(buffer.getCell(0, 0).symbol, " ")
    }

    @TestCase
    func testBackendSnapshotsTrackMultipleFramesAndOutOfRange(): Unit {
        let backend = TestBackend(area: Rect(0, 0, 4, 1))
        let terminal = Terminal(backend)
        terminal.draw { frame => frame.renderWidget(Paragraph("one"), frame.area) }
        terminal.draw { frame => frame.renderWidget(Paragraph("two"), frame.area) }
        @Expect(backend.snapshots().size, 2)
        @Expect(backend.snapshotAt(-1), "")
        @Expect(backend.snapshotAt(99), "")
        @Expect(backend.snapshotAt(0).contains("one"))
        @Expect(backend.snapshotAt(1).contains("two"))
    }

    @TestCase
    func virtualTableLargeRowCountNavigationStaysBounded(): Unit {
        let table = VirtualTable([TableColumn("ID", width: 4)], 10000, { index => ["${index}"] })
        @Expect(table.handle(KeyEvent(KeyCode.End), 5))
        match (table.selectedRow) {
            case Some(row) => @Expect(row, 9999)
            case None => @Expect(false)
        }
        @Expect(table.offset <= 9999)
    }

    @TestCase
    func documentViewEmptyAndTinyWidthAreSafe(): Unit {
        let empty = DocumentView(Document([]))
        @Expect(empty.renderedLineCount(0), 0)
        let buffer = Buffer(Rect(0, 0, 1, 1))
        DocumentView(Document([DocumentLine(DocumentLineKind.Paragraph, "abcdef")])).render(buffer.area, buffer)
        @Expect(!buffer.getCell(0, 0).symbol.isEmpty())
    }

    @TestCase
    func documentViewSinglePassWritePreservesStyledSpanBoundaries(): Unit {
        let red = Style(fg: Color.Red)
        let green = Style(fg: Color.Green)
        let blue = Style(fg: Color.Blue)
        let yellow = Style(fg: Color.Yellow)

        let mixedSpans = [
            RichSpan("ASCII ", style: red),
            RichSpan("e\u{0301}", style: green),
            RichSpan(" \u{1F469}\u{200D}\u{1F4BB} ", style: blue),
            RichSpan("界·", style: yellow)
        ]
        @Expect(documentStyledSpanCellsMatchLegacy(mixedSpans, 14))
        let mixed = Buffer(Rect(0, 0, 18, 1))
        DocumentView(
            Document([DocumentLine(DocumentLineKind.Paragraph, mixedSpans)]),
            wrap: WrapMode.NoWrap
        ).render(Rect(2, 0, 14, 1), mixed)
        @Expect(mixed.getCell(1, 0), Cell())
        @Expect(mixed.getCell(2, 0).symbol, "A")
        @Expect(mixed.getCell(2, 0).style, red)
        @Expect(mixed.getCell(8, 0).symbol, "e\u{0301}")
        @Expect(mixed.getCell(8, 0).style, green)
        @Expect(
            mixed.getCell(10, 0),
            Cell("\u{1F469}\u{200D}\u{1F4BB}", style: blue, kind: CellKind.WideLead)
        )
        @Expect(mixed.getCell(11, 0), Cell("", style: blue, kind: CellKind.WideCont))
        @Expect(mixed.getCell(13, 0), Cell("界", style: yellow, kind: CellKind.WideLead))
        @Expect(mixed.getCell(14, 0), Cell("", style: yellow, kind: CellKind.WideCont))
        @Expect(mixed.getCell(15, 0).symbol, "·")
        @Expect(mixed.getCell(15, 0).style, yellow)
        @Expect(mixed.getCell(16, 0), Cell())

        let splitSpans = [
            RichSpan("e", style: red),
            RichSpan("\u{0301}X", style: green),
            RichSpan("\u{1F469}", style: blue),
            RichSpan("\u{200D}\u{1F4BB}Z", style: yellow)
        ]
        @Expect(documentStyledSpanCellsMatchLegacy(splitSpans, 8))
        let split = Buffer(Rect(0, 0, 12, 1))
        DocumentView(
            Document([DocumentLine(DocumentLineKind.Paragraph, splitSpans)]),
            wrap: WrapMode.NoWrap
        ).render(Rect(2, 0, 8, 1), split)
        @Expect(split.getCell(2, 0).symbol, "e")
        @Expect(split.getCell(2, 0).style, red)
        @Expect(split.getCell(3, 0).symbol, "X")
        @Expect(split.getCell(3, 0).style, green)
        @Expect(split.getCell(4, 0), Cell("\u{1F469}", style: blue, kind: CellKind.WideLead))
        @Expect(split.getCell(5, 0), Cell("", style: blue, kind: CellKind.WideCont))
        @Expect(split.getCell(6, 0), Cell("\u{200D}", style: yellow))
        @Expect(split.getCell(7, 0), Cell("\u{1F4BB}", style: yellow, kind: CellKind.WideLead))
        @Expect(split.getCell(8, 0), Cell("", style: yellow, kind: CellKind.WideCont))
        @Expect(split.getCell(9, 0), Cell("Z", style: yellow))

        let edgeSpans = [
            RichSpan("1234567", style: red),
            RichSpan("界", style: green),
            RichSpan("Z", style: blue)
        ]
        @Expect(documentStyledSpanCellsMatchLegacy(edgeSpans, 8))
        let edge = Buffer(Rect(0, 0, 8, 1))
        DocumentView(
            Document([DocumentLine(DocumentLineKind.Paragraph, edgeSpans)]),
            wrap: WrapMode.NoWrap
        ).render(edge.area, edge)
        @Expect(edge.getCell(7, 0).symbol, "Z")
        @Expect(edge.getCell(7, 0).style, blue)

        let narrowBuffer = Buffer(Rect(0, 0, 1, 1))
        DocumentView(
            Document([DocumentLine(DocumentLineKind.Paragraph, [
                RichSpan("界", style: green),
                RichSpan("Z", style: blue)
            ])]),
            wrap: WrapMode.NoWrap
        ).render(Rect(0, 0, 2, 1), narrowBuffer)
        @Expect(narrowBuffer.getCell(0, 0), Cell())

        let escapeSpans = [
            RichSpan("\u{1B}[31mred", style: red),
            RichSpan("Z", style: green)
        ]
        @Expect(documentStyledSpanCellsMatchLegacy(escapeSpans, 8))
        let escape = Buffer(Rect(0, 0, 8, 1))
        DocumentView(
            Document([DocumentLine(DocumentLineKind.Paragraph, escapeSpans)]),
            wrap: WrapMode.NoWrap
        ).render(escape.area, escape)
        @Expect(escape.getCell(0, 0).symbol, "[")
        @Expect(escape.getCell(0, 0).style, red)
        @Expect(escape.getCell(6, 0).symbol, "d")
        @Expect(escape.getCell(7, 0).symbol, "Z")
        @Expect(escape.getCell(7, 0).style, green)
    }

    @TestCase
    func graphemeClustersKeepCombiningAndEmojiSequencesTogether(): Unit {
        let accent = "e\u{0301}"
        @Expect(graphemeClusters(accent).size, 1)
        @Expect(displayWidth(accent), 1)
        @Expect(truncate(accent + "x", 1), accent)

        let family = "\u{1F469}\u{200D}\u{1F4BB}"
        @Expect(graphemeClusters(family).size, 1)
        @Expect(displayWidth(family), 2)
        @Expect(nextGraphemeOffset(family + "!", 0), family.size)
    }

    @TestCase
    func textBufferDeletesWholeGraphemeClusters(): Unit {
        let accent = "e\u{0301}"
        let buffer = TextBuffer(text: accent + "x")
        let pos = buffer.deleteBackward(TextPosition(0, accent.size))
        @Expect(pos, TextPosition(0, 0))
        @Expect(buffer.text(), "x")

        let emoji = "\u{1F469}\u{200D}\u{1F4BB}"
        let emojiBuffer = TextBuffer(text: emoji + "!")
        _ = emojiBuffer.deleteForward(TextPosition(0, 0))
        @Expect(emojiBuffer.text(), "!")
    }

    @TestCase
    func bufferExposesExplicitWideCellKinds(): Unit {
        let buffer = Buffer(Rect(0, 0, 4, 1))
        buffer.setString(0, 0, "界a")
        match (buffer.getCell(0, 0).kind) {
            case CellKind.WideLead => ()
            case _ => @Expect(false)
        }
        match (buffer.getCell(1, 0).kind) {
            case CellKind.WideCont => ()
            case _ => @Expect(false)
        }
        match (buffer.getCell(2, 0).kind) {
            case CellKind.Normal => ()
            case _ => @Expect(false)
        }
    }

    @TestCase
    func asciiFastPathClearsWideCellContinuations(): Unit {
        let buffer = Buffer(Rect(0, 0, 4, 1))
        buffer.setString(0, 0, "界界")
        buffer.setString(1, 0, "abc")
        @Expect(buffer.getCell(0, 0).symbol, " ")
        @Expect(buffer.getCell(1, 0).symbol, "a")
        @Expect(buffer.getCell(2, 0).symbol, "b")
        @Expect(buffer.getCell(3, 0).symbol, "c")
        match (buffer.getCell(1, 0).kind) {
            case CellKind.Normal => ()
            case _ => @Expect(false)
        }
    }

    @TestCase
    func fillRectClearsWideCellContinuationsWithoutStringPath(): Unit {
        let buffer = Buffer(Rect(0, 0, 4, 1))
        buffer.setString(0, 0, "界a")
        buffer.fillRect(Rect(1, 0, 2, 1), style: Style(bg: Color.Blue))
        @Expect(buffer.getCell(0, 0).symbol, " ")
        @Expect(buffer.getCell(1, 0).symbol, " ")
        @Expect(buffer.getCell(2, 0).symbol, " ")
        match (buffer.getCell(1, 0).kind) {
            case CellKind.Normal => ()
            case _ => @Expect(false)
        }
    }

    @TestCase
    func ambiguousWidthIsConfigurableAndDefaultsNarrow(): Unit {
        @Expect(displayWidth("·"), 1)
        @Expect(displayWidth("·", options: TextWidthOptions(ambiguousWidth: AmbiguousWidth.Wide)), 2)
    }

    @TestCase
    func markdownDecorationsSurviveEmojiListMarkers(): Unit {
        // Regression: the task-marker decoration compared
        // line[markerEnd..markerEnd+3] on UTF-8 bytes; a 4-byte emoji right
        // after the list marker split a rune and threw. Now byte-compares.
        let spans = markdownDecorations("- 🎯 任务一\n- [x] ✅ 已完成\n")
        @Expect(spans.size > 0)
    }
}
