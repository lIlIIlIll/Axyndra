package core

import std.unittest.*
import std.unittest.testmacro.*

@Test
class CanvasContractTest {
    @TestCase
    func canvasConstructionAppliesTranslationClipAndBufferBounds(): Unit {
        let buffer = Buffer(Rect(0, 0, 6, 3))
        let red = Style(bg: Color.Red)
        Canvas(buffer, Rect(1, 0, 4, 3), translateX: 2, translateY: 1)
            .fillRect(Rect(-1, -1, 4, 2), red)
        @Expect(buffer.getCell(0, 0), Cell())
        @Expect(buffer.getCell(1, 0), Cell(" ", style: red))
        @Expect(buffer.getCell(4, 1), Cell(" ", style: red))
        @Expect(buffer.getCell(5, 1), Cell())

        let blue = Style(bg: Color.Blue)
        Canvas(buffer, Rect(-2, -2, 10, 8), translateX: -2, translateY: -1)
            .fillRect(Rect(2, 1, 1, 1), blue)
        @Expect(buffer.getCell(0, 0), Cell(" ", style: blue))
    }

    @TestCase
    func canvasFillRectOverloadsShareEmptyAndBoundsSemantics(): Unit {
        let area = Rect(0, 0, 5, 2)
        let first = Buffer(area)
        let second = Buffer(area)
        let style = Style(bg: Color.Magenta)
        Canvas(first, Rect(1, 0, 3, 2)).fillRect(Rect(-2, 0, 6, 1), style)
        Canvas(second, Rect(1, 0, 3, 2)).fillRect(-2, 0, 6, 1, style)
        Canvas(first, area).fillRect(0, 1, 0, 1, style)
        Canvas(first, area).fillRect(0, 1, -3, 1, style)
        Canvas(first, area).fillRect(20, 20, 2, 2, style)
        for (y in area.y..area.bottom) {
            for (x in area.x..area.right) {
                @Expect(first.getCell(x, y), second.getCell(x, y))
            }
        }
    }

    @TestCase
    func canvasFillRectRepairsWideCellOverwrites(): Unit {
        let buffer = Buffer(Rect(0, 0, 5, 2))
        buffer.setString(1, 0, "界")
        buffer.setString(1, 1, "界")
        let style = Style(bg: Color.Cyan)
        Canvas(buffer, buffer.area).fillRect(1, 0, 1, 1, style)
        Canvas(buffer, buffer.area).fillRect(2, 1, 1, 1, style)
        @Expect(buffer.getCell(1, 0), Cell(" ", style: style))
        @Expect(buffer.getCell(2, 0), Cell(" ", style: style))
        @Expect(buffer.getCell(1, 1), Cell(" ", style: style))
        @Expect(buffer.getCell(2, 1), Cell(" ", style: style))
    }

    @TestCase
    func canvasDrawTextAppliesAsciiTranslationAndClipping(): Unit {
        let buffer = Buffer(Rect(0, 0, 6, 2))
        let style = Style(fg: Color.Green)
        let canvas = Canvas(buffer, Rect(1, 0, 3, 2), translateX: 1, translateY: 1)
        canvas.drawText(-2, -1, "abcd", style)
        @Expect(buffer.getCell(0, 0), Cell())
        @Expect(buffer.getCell(1, 0), Cell("c", style: style))
        @Expect(buffer.getCell(2, 0), Cell("d", style: style))
        @Expect(buffer.getCell(3, 0), Cell())
    }

    @TestCase
    func canvasDrawTextClipsWholeGraphemesAndPreservesWideCells(): Unit {
        let left = Buffer(Rect(0, 0, 5, 1))
        let style = Style(fg: Color.Yellow)
        Canvas(left, Rect(1, 0, 3, 1)).drawText(0, 0, "界a", style)
        @Expect(left.getCell(1, 0), Cell())
        @Expect(left.getCell(2, 0), Cell("a", style: style))

        let right = Buffer(Rect(0, 0, 3, 1))
        Canvas(right, Rect(0, 0, 1, 1)).drawText(0, 0, "界", style)
        @Expect(right.getCell(0, 0), Cell())

        let full = Buffer(Rect(0, 0, 4, 1))
        Canvas(full, Rect(0, 0, 4, 1)).drawText(0, 0, "界e\u{0301}", style)
        @Expect(full.getCell(0, 0), Cell("界", style: style, kind: CellKind.WideLead))
        @Expect(full.getCell(1, 0), Cell("", style: style, kind: CellKind.WideCont))
        @Expect(full.getCell(2, 0), Cell("e\u{0301}", style: style))

        let overwritten = Buffer(Rect(0, 0, 4, 1))
        overwritten.setString(1, 0, "界")
        Canvas(overwritten, overwritten.area).drawText(2, 0, "x", style)
        @Expect(overwritten.getCell(1, 0), Cell())
        @Expect(overwritten.getCell(2, 0), Cell("x", style: style))
    }

    @TestCase
    func frameCanvasWritesTheCurrentFrameBuffer(): Unit {
        let buffer = Buffer(Rect(0, 0, 5, 2))
        let frame = Frame(buffer.area, buffer)
        let style = Style(fg: Color.Red)
        let canvas = frame.canvas(area: Rect(1, 0, 3, 2))
        canvas.fillRect(1, 0, 2, 1, Style(bg: Color.Blue))
        canvas.drawText(1, 1, "ok", style)
        @Expect(buffer.getCell(1, 0).style, Style(bg: Color.Blue))
        @Expect(buffer.getCell(1, 1), Cell("o", style: style))
        @Expect(buffer.getCell(2, 1), Cell("k", style: style))
    }
}
