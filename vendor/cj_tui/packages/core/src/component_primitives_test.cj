package core

import std.unittest.*
import std.unittest.testmacro.*

class PrimitiveCountingRows {
    var calls: Int64 = 0

    func rowAt(index: Int64): Array<String> {
        calls++
        ["row-${index}", "value-${index}"]
    }
}

@Test
class CjTuiComponentPrimitivesTest {
    @TestCase
    func transcriptCardsShareStatusBodyAndChoiceChrome(): Unit {
        let item = TranscriptItem(
            "approval-1",
            kind: TranscriptItemKind.Event,
            title: "Permission · edit",
            body: Document.plain("MEDIUM RISK · workspace.write\nTarget  README.md"),
            status: TranscriptItemStatus.Awaiting,
            stateLabel: "awaiting approval",
            options: [
                TranscriptCardOption("Allow once", selected: true),
                TranscriptCardOption("Reject")
            ],
            footer: "←/→ choose · Enter confirm"
        )
        let document = transcriptCardDocument(item)
        @Expect(document.lines.size, 6)
        @Expect(document.lines[0].spans[0].text, "? ")
        @Expect(document.lines[0].spans[1].text, "Permission · edit")
        @Expect(document.lines[0].spans[2].text, " · awaiting approval")
        @Expect(document.lines[1].spans[0].text, "  ")
        @Expect(document.lines[3].spans[0].text, "  › Allow once")
        @Expect(document.lines[5].spans[0].text, "  ←/→ choose · Enter confirm")

        let collapsed = transcriptCardDocument(TranscriptItem(
            "tool-1",
            title: "Tool · bash",
            body: Document.plain("$ pwd"),
            status: TranscriptItemStatus.Running,
            collapsed: true
        ))
        @Expect(collapsed.lines.size, 1)
        @Expect(collapsed.lines[0].spans[0].text, "◐ ")
        @Expect(collapsed.lines[0].spans[3].text, "  ▸")

        let timedOut = transcriptCardDocument(TranscriptItem(
            "shell-timeout",
            title: "Run command",
            status: TranscriptItemStatus.TimedOut
        ))
        let expired = transcriptCardDocument(TranscriptItem(
            "approval-expired",
            title: "Approval",
            status: TranscriptItemStatus.Expired
        ))
        @Expect(timedOut.lines[0].spans[0].text, "⌛ ")
        @Expect(timedOut.lines[0].spans[2].text, " · timed out")
        @Expect(expired.lines[0].spans[2].text, " · expired")
    }

    @TestCase
    func blockPanelRenderInnerStylesAndAlignsTitle(): Unit {
        let buffer = Buffer(Rect(0, 0, 20, 5))
        let block = Block(BlockOptions(
            title: "Info",
            borderKind: BorderKind.Rounded,
            titleAlign: TitleAlign.Center,
            padding: Spacing.all(1),
            backgroundStyle: Style(bg: Color.Blue),
            borderStyle: Style(fg: Color.Cyan),
            titleStyle: Style(fg: Color.Yellow),
            state: BoxState.Focused
        ))
        let inner = block.renderInner(buffer.area, buffer)
        @Expect(inner, Rect(2, 2, 16, 1))
        @Expect(buffer.getCell(0, 0).symbol, "╭")
        @Expect(buffer.getCell(8, 0).symbol, "I")
        @Expect(buffer.getCell(2, 2).style, Style(bg: Color.Blue))

        let panelBuffer = Buffer(Rect(0, 0, 12, 3))
        Panel(BlockOptions(title: "P"), child: Some(Paragraph("body"))).render(panelBuffer.area, panelBuffer)
        @Expect(panelBuffer.getCell(1, 1).symbol, "b")
    }

    @TestCase
    func bufferAndCanvasFillPrimitivesPreserveWideCells(): Unit {
        let buffer = Buffer(Rect(0, 0, 8, 3))
        buffer.setString(0, 0, "界a")
        buffer.fillLine(0, 1, 3, style: Style(bg: Color.Red))
        @Expect(buffer.getCell(0, 0).symbol, " ")
        @Expect(buffer.getCell(1, 0).symbol, " ")
        @Expect(buffer.writeAsciiSpan(0, 1, "abc", style: Style(fg: Color.Green)))
        buffer.writeAsciiSpanUnchecked(3, 1, "xy", style: Style(fg: Color.Cyan))
        @Expect(buffer.getCell(3, 1).symbol, "x")
        @Expect(!buffer.writeAsciiSpan(0, 2, "a界", style: Style.default()))
        buffer.hline(-1, 1, 3, "*", Style(fg: Color.Yellow))
        buffer.setString(6, 0, "界")
        buffer.vline(6, 0, 2, "|", Style(fg: Color.Cyan))
        @Expect(buffer.getCell(0, 1).symbol, "*")
        @Expect(buffer.getCell(1, 1).symbol, "*")
        @Expect(buffer.getCell(6, 0).symbol, "|")
        @Expect(buffer.getCell(7, 0).symbol, " ")

        let canvas = Canvas(buffer, buffer.area)
        canvas.fillRect(2, 2, 2, 1, Style(bg: Color.Blue))
        canvas.hline(0, 2, 4, "-", Style(fg: Color.Yellow))
        canvas.vline(5, 0, 3, "|", Style(fg: Color.Cyan))
        canvas.render(Paragraph("ok"), Rect(1, 0, 2, 1))
        @Expect(buffer.getCell(3, 2).symbol, "-")
        @Expect(buffer.getCell(5, 1).symbol, "|")
        @Expect(buffer.getCell(1, 0).symbol, "o")

        let dirty = DirtyRects()
        dirty.add(Rect(1, 1, 2, 1))
        @Expect(dirty.intersectsCell(1, 1))
        @Expect(!dirty.intersectsCell(3, 1))
        @Expect(dirty.intersectsRect(2, 1, 3, 1))
        @Expect(!dirty.intersectsRect(3, 1, 2, 1))

        let backend = TestBackend(area: Rect(0, 0, 4, 2))
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)
        _ = terminal.draw { frame =>
            frame.fillRect(0, 0, 4, 1, Style(bg: Color.Green))
            @Expect(frame.isDirtyCell(0, 0))
        }
    }

    @TestCase
    func containersRenderNestedWidgetsAndScrollableUsesState(): Unit {
        let buffer = Buffer(Rect(0, 0, 20, 8))
        let top = Paragraph("top")
        let bottom = Paragraph("bottom")
        VBox([top, bottom], gap: 1).render(Rect(0, 0, 10, 5), buffer)
        @Expect(buffer.getCell(0, 0).symbol, "t")
        @Expect(buffer.getCell(0, 3).symbol, "b")

        HBox([Paragraph("L"), Paragraph("R")], gap: 1).render(Rect(0, 5, 7, 1), buffer)
        @Expect(buffer.getCell(0, 5).symbol, "L")
        @Expect(buffer.getCell(4, 5).symbol, "R")

        let scroll = ScrollState(offset: 1)
        Scrollable(["zero", "one", "two"], state: scroll).render(Rect(10, 0, 6, 2), buffer)
        @Expect(buffer.getCell(10, 0).symbol, "o")
        @Expect(buffer.getCell(15, 0).symbol, "|")
    }

    @TestCase
    func stateModelsAndVirtualTableExposeViewportFriendlyBehavior(): Unit {
        let selection = SelectionModel(mode: SelectionMode.Multiple)
        selection.select(2)
        selection.toggle(4)
        @Expect(selection.isSelected(2))
        @Expect(selection.isSelected(4))

        let scroll = ScrollState()
        scroll.ensureVisible(20, 100, 5)
        @Expect(scroll.offset, 16)

        let sort = SortState()
        sort.toggle(1)
        @Expect(sort.descending, false)
        sort.toggle(1)
        @Expect(sort.descending)

        let filter = FilterState(query: "row")
        @Expect(filter.matches("row-1"))

        let rows = PrimitiveCountingRows()
        let table = VirtualTable([TableColumn("Name", width: 8)], 1000000, { index => rows.rowAt(index) }, selectionModel: Some(selection))
        table.render(Rect(0, 0, 12, 4), Buffer(Rect(0, 0, 12, 4)))
        @Expect(rows.calls <= 3)
    }

    @TestCase
    func dashboardStatusAndThemeResolverRenderPublicStates(): Unit {
        let buffer = Buffer(Rect(0, 0, 40, 10))
        MetricCard("CPU", "42%", detail: "user").render(Rect(0, 0, 10, 4), buffer)
        Meter("RAM", 50).render(Rect(0, 4, 18, 1), buffer)
        Legend([LegendItem("rx"), LegendItem("tx", symbol: "*", style: Style(fg: Color.Green))]).render(Rect(0, 5, 20, 1), buffer)
        TimeSeriesChart([1, 2, 3], maxValue: 3).render(Rect(20, 0, 3, 3), buffer)
        HeaderBar("Title", left: "L", right: "R").render(Rect(0, 6, 20, 1), buffer)
        FooterBar(left: "ready").render(Rect(0, 7, 20, 1), buffer)
        EmptyState(title: "Empty").render(Rect(20, 3, 10, 3), buffer)
        InlineAlert("Warn").render(Rect(0, 8, 10, 1), buffer)

        @Expect(buffer.getCell(0, 0).symbol, "C")
        @Expect(buffer.getCell(0, 4).symbol, "R")
        @Expect(buffer.getCell(20, 2).symbol, "#")
        @Expect(buffer.getCell(0, 6).symbol, "L")
        @Expect(buffer.getCell(0, 8).symbol, "W")

    }
}
