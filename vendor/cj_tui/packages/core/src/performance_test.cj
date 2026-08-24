package core

import std.unittest.*
import std.unittest.testmacro.*

class CountingTableRows {
    var calls: Int64 = 0
    var minRow: Int64 = Int64.Max
    var maxRow: Int64 = -1

    func reset(): Unit {
        calls = 0
        minRow = Int64.Max
        maxRow = -1
    }

    func rowAt(index: Int64): Array<String> {
        calls++
        minRow = min(minRow, index)
        maxRow = max(maxRow, index)
        ["row-${index}", "value-${index}"]
    }
}

class BenchTableRows {
    func rowAt(index: Int64): Array<String> {
        ["row-${index}", "value-${index}"]
    }
}

func largePerformanceText(lineCount: Int64): String {
    let text = StringBuilder()
    for (i in 0..lineCount) {
        text.append("line ${i} ascii 中文 e\u{301} 🙂 target-${i}\n")
    }
    text.toString()
}

func runTerminalDiffBench(variant: Int64): RenderMetrics {
    let viewport = Rect(0, 0, 80, 24)
    let backend = TestBackend(area: viewport)
    let terminal = Terminal(backend, renderMode: RenderMode.Diff)
    _ = terminal.draw { frame =>
        frame.canvas().drawText(0, 0, "alpha", Style.default())
        frame.canvas().drawText(0, 1, "stable 中文 🙂", Style.default())
        frame.canvas().drawText(0, 2, "row-2 stable", Style.default())
        frame.canvas().drawText(0, 3, "row-3 stable", Style.default())
    }
    match (variant) {
        case 0 =>
            terminal.draw { frame =>
                frame.canvas().drawText(0, 0, "alpXa", Style.default())
                frame.canvas().drawText(0, 1, "stable 中文 🙂", Style.default())
                frame.canvas().drawText(0, 2, "row-2 stable", Style.default())
                frame.canvas().drawText(0, 3, "row-3 stable", Style.default())
            }
        case 1 =>
            terminal.draw { frame =>
                frame.canvas().drawText(0, 0, "alpha", Style.default())
                frame.canvas().drawText(0, 1, "stable 中文 🙂", Style.default())
                frame.canvas().drawText(0, 2, "row-2 stable with changed row tail", Style.default())
                frame.canvas().drawText(0, 3, "row-3 stable", Style.default())
            }
        case 2 =>
            terminal.draw { frame =>
                frame.canvas().drawText(0, 0, "alpha", Style.default())
                frame.canvas().drawText(0, 1, "stable 文a  ", Style.default())
                frame.canvas().drawText(0, 2, "row-2 stable", Style.default())
                frame.canvas().drawText(0, 3, "row-3 stable", Style.default())
            }
        case _ =>
            terminal.draw { frame =>
                frame.canvas().drawText(0, 0, "alpXa", Style.default())
                frame.canvas().drawText(0, 1, "stable 中文 🙂", Style.default())
                frame.canvas().drawText(0, 2, "row-2 stable changed", Style.default())
                frame.canvas().drawText(0, 3, "row-3 stable changed", Style.default())
            }
    }
}

func runCanvasFillRectBench(size: Int64): Int64 {
    let width = if (size == 0) { Int64(80) } else { Int64(160) }
    let height = if (size == 0) { Int64(24) } else { Int64(48) }
    let buffer = Buffer(Rect(0, 0, width, height))
    let canvas = Canvas(buffer, buffer.area)
    for (_ in 0..20) {
        canvas.fillRect(buffer.area, Style(bg: Color.Black))
        canvas.drawText(0, 0, "ascii table row ----------------", Style.default())
        canvas.drawText(width / 2, height / 2, "界a", Style.default())
    }
    buffer.getCell(width / 2, height / 2).symbol.size
}

func runVirtualTableBench(rowCount: Int64): RenderMetrics {
    let rows = BenchTableRows()
    let table = VirtualTable(
        [TableColumn("Name", width: 12), TableColumn("Value", width: 12)],
        rowCount,
        { index => rows.rowAt(index) }
    )
    let terminal = Terminal(TestBackend(area: Rect(0, 0, 40, 10)), renderMode: RenderMode.Diff)
    _ = terminal.draw { frame => frame.renderWidget(table, frame.area) }
    _ = table.handle(KeyEvent(KeyCode.PageDown), 9)
    _ = terminal.draw { frame => frame.renderWidget(table, frame.area) }
    _ = table.handle(KeyEvent(KeyCode.End), 9)
    terminal.draw { frame => frame.renderWidget(table, frame.area) }
}

func runTextAreaBench(lineCount: Int64): RenderMetrics {
    let viewport = Rect(0, 0, 80, 24)
    let terminal = Terminal(TestBackend(area: viewport), renderMode: RenderMode.Diff)
    let area = TextArea(value: largePerformanceText(lineCount), cursor: 0, lineNumbers: true, markdownEditing: true)
    _ = terminal.draw { frame => frame.renderWidget(area, frame.area) }
    let target = "target-${lineCount / 2}"
    area.cursor = 0
    _ = area.findNext(target)
    _ = terminal.draw { frame => frame.renderWidget(area, frame.area) }
    area.selectionStart = None
    area.selectionEnd = None
    _ = area.handle(KeyEvent(KeyCode.Char(r'X')))
    _ = terminal.draw { frame => frame.renderWidget(area, frame.area) }
    _ = area.handle(KeyEvent(KeyCode.Backspace))
    terminal.draw { frame => frame.renderWidget(area, frame.area) }
}

@Test
class CjTuiPerformanceRegressionTest {
    @TestCase
    func terminalDiffKeepsSmallAsciiUpdateLocal(): Unit {
        let viewport = Rect(0, 0, 20, 4)
        let backend = TestBackend(area: viewport)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        let first = terminal.draw { frame =>
            frame.canvas().drawText(0, 0, "alpha", Style.default())
            frame.canvas().drawText(0, 1, "stable", Style.default())
        }
        @Expect(first.fullRedraw)
        @Expect(first.dirtyCells, viewport.width * viewport.height)

        let changedTextWidth: Int64 = 1
        let dirtyLimit = changedTextWidth
        let writeLimit: Int64 = 1
        let second = terminal.draw { frame =>
            frame.canvas().drawText(0, 0, "alpXa", Style.default())
            frame.canvas().drawText(0, 1, "stable", Style.default())
        }
        @Expect(!second.fullRedraw)
        @Expect(second.dirtyCells <= dirtyLimit)
        @Expect(second.diffWrites <= writeLimit)
        @Expect(backend.lastDiffWrites() <= writeLimit)
        @Expect(backend.snapshot().contains("alpXa"))
    }

    @TestCase
    func terminalDiffKeepsWideCellContinuationLocal(): Unit {
        let viewport = Rect(0, 0, 12, 3)
        let backend = TestBackend(area: viewport)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame =>
            frame.canvas().drawText(0, 0, "界界", Style.default())
            frame.canvas().drawText(0, 1, "stable", Style.default())
        }

        let dirtyLimit = viewport.width
        let writeLimit: Int64 = 3
        let second = terminal.draw { frame =>
            frame.canvas().drawText(0, 0, "界a ", Style.default())
            frame.canvas().drawText(0, 1, "stable", Style.default())
        }
        @Expect(!second.fullRedraw)
        @Expect(second.dirtyCells <= dirtyLimit)
        @Expect(second.diffWrites <= writeLimit)
        @Expect(backend.assertCell(0, 0, "界"))
        @Expect(backend.assertCell(2, 0, "a"))
    }

    @TestCase
    func terminalPartialRenderCopiesOnlyDirtyCells(): Unit {
        let viewport = Rect(0, 0, 20, 4)
        let backend = TestBackend(area: viewport)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame =>
            frame.canvas().drawText(0, 0, "header", Style.default())
            frame.canvas().drawText(0, 1, "value: old", Style.default())
            frame.canvas().drawText(0, 2, "footer", Style.default())
        }

        let dirty = DirtyRects()
        dirty.add(Rect(7, 1, 3, 1))
        let metrics = terminal.draw({ frame =>
            frame.canvas().drawText(7, 1, "new", Style.default())
        }, dirtyRects: Some(dirty))

        @Expect(!metrics.fullRedraw)
        // Partial redraw reserves one boundary cell on each side so a new
        // width-2 grapheme can be written atomically without widening to a row.
        let boundaryAllowance: Int64 = 2
        @Expect(metrics.renderedCells <= dirty.cellCount() + boundaryAllowance)
        @Expect(metrics.copiedCells <= dirty.cellCount() + boundaryAllowance)
        @Expect(metrics.dirtyCells <= dirty.cellCount())
        @Expect(backend.snapshot().contains("header"))
        @Expect(backend.snapshot().contains("value: new"))
        @Expect(backend.snapshot().contains("footer"))
    }

    @TestCase
    func virtualTableProviderReadsOnlyViewportRows(): Unit {
        let rows = CountingTableRows()
        let table = VirtualTable(
            [TableColumn("Name", width: 12), TableColumn("Value", width: 12)],
            1000000,
            { index => rows.rowAt(index) }
        )
        let viewport = Rect(0, 0, 40, 10)
        let visibleRows = viewport.height - 1
        let providerCallLimit = visibleRows
        let backend = TestBackend(area: viewport)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        rows.reset()
        _ = terminal.draw { frame => frame.renderWidget(table, frame.area) }
        @Expect(rows.calls <= providerCallLimit)
        @Expect(rows.minRow, 0)
        @Expect(rows.maxRow, visibleRows - 1)

        @Expect(table.handle(KeyEvent(KeyCode.PageDown), visibleRows))
        rows.reset()
        _ = terminal.draw { frame => frame.renderWidget(table, frame.area) }
        @Expect(rows.calls <= providerCallLimit)
        @Expect(rows.minRow >= 1)
        @Expect(rows.maxRow < 1 + visibleRows)

        @Expect(table.handle(KeyEvent(KeyCode.End), visibleRows))
        rows.reset()
        _ = terminal.draw { frame => frame.renderWidget(table, frame.area) }
        @Expect(rows.calls <= providerCallLimit)
        @Expect(rows.minRow >= 1000000 - visibleRows)
        @Expect(rows.maxRow, 999999)
    }

    @TestCase
    func virtualTableSelectionDirtyRowsOnly(): Unit {
        let rows = CountingTableRows()
        let table = VirtualTable(
            [TableColumn("Name", width: 12), TableColumn("Value", width: 12)],
            1000,
            { index => rows.rowAt(index) },
            selectedRow: Some(0)
        )
        let viewport = Rect(0, 0, 40, 10)
        let visibleRows = viewport.height - 1
        let backend = TestBackend(area: viewport)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame => frame.renderWidget(table, frame.area) }
        match (table.handleWithDirty(KeyEvent(KeyCode.Down), visibleRows, viewport)) {
            case Some(dirty) =>
                @Expect(dirty.rects().size <= 2)
                let metrics = terminal.draw({ frame => frame.renderWidget(table, frame.area) }, dirtyRects: Some(dirty))
                @Expect(!metrics.fullRedraw)
                @Expect(metrics.renderedCells <= viewport.width * 2)
                @Expect(metrics.dirtyRects <= 2)
            case None => @Expect(false)
        }
    }

    @TestCase
    func largeTextAreaEditKeepsDiffLocal(): Unit {
        let lineCount: Int64 = 200
        let viewport = Rect(0, 0, 80, 24)
        let backend = TestBackend(area: viewport)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)
        let area = TextArea(value: largePerformanceText(lineCount), cursor: 0, lineNumbers: true, markdownEditing: true)

        _ = terminal.draw { frame => frame.renderWidget(area, frame.area) }
        @Expect(backend.snapshot().contains("line 0"))

        @Expect(area.handle(KeyEvent(KeyCode.PageDown)))
        @Expect(area.cursor > 0)
        _ = terminal.draw { frame => frame.renderWidget(area, frame.area) }
        @Expect(backend.snapshot().contains("line"))
        @Expect(!backend.snapshot().contains("line 199"))

        @Expect(area.handle(KeyEvent(KeyCode.End, modifiers: KeyModifier(ctrl: true))))
        @Expect(area.cursor, area.value.size)
        area.cursor = 0
        match (area.findNext("target-100")) {
            case Some(index) =>
                @Expect(index >= 0)
                @Expect(area.cursor, index)
            case None => @Expect(false)
        }
        _ = terminal.draw { frame => frame.renderWidget(area, frame.area) }
        @Expect(backend.snapshot().contains("target-100"))

        area.selectionStart = None
        area.selectionEnd = None
        @Expect(area.handle(KeyEvent(KeyCode.Char(r'X'))))
        let edited = terminal.draw { frame => frame.renderWidget(area, frame.area) }
        let affectedRows: Int64 = 3
        let dirtyLimit = viewport.width * affectedRows
        @Expect(!edited.fullRedraw)
        @Expect(edited.dirtyCells <= dirtyLimit)
        @Expect(edited.diffWrites <= affectedRows)
        @Expect(backend.snapshot().contains("Xtarget-100"))

        @Expect(area.handle(KeyEvent(KeyCode.Backspace)))
        let deleted = terminal.draw { frame => frame.renderWidget(area, frame.area) }
        @Expect(!deleted.fullRedraw)
        @Expect(deleted.dirtyCells <= dirtyLimit)
        @Expect(deleted.diffWrites <= affectedRows)
        @Expect(backend.snapshot().contains("target-100"))
    }
}

@Test
class CjTuiPerformanceBench {
    var sink: Int64 = 0

    @Bench[variant in [0, 1, 2, 3]]
    @Configure[warmup: 0, batchSize: 1, minBatches: 1, minDuration: Duration.millisecond]
    func terminalDiffTouchedCellsSlope(variant: Int64): Unit {
        let metrics = runTerminalDiffBench(variant)
        sink += metrics.dirtyCells + metrics.diffWrites
    }

    @Bench[size in [0, 1]]
    @Configure[warmup: 0, batchSize: 1, minBatches: 1, minDuration: Duration.millisecond]
    func canvasFillRectAsciiFastPath(size: Int64): Unit {
        sink += runCanvasFillRectBench(size)
    }

    @Bench[rowCount in [1000, 100000, 1000000]]
    @Configure[warmup: 0, batchSize: 1, minBatches: 1, minDuration: Duration.millisecond]
    func virtualTableViewportProviderSlope(rowCount: Int64): Unit {
        let metrics = runVirtualTableBench(rowCount)
        sink += metrics.dirtyCells + metrics.diffWrites
    }

    @Bench[lineCount in [200, 1000, 2000]]
    @Configure[warmup: 0, batchSize: 1, minBatches: 1, minDuration: Duration.millisecond]
    func textAreaViewportEditSlope(lineCount: Int64): Unit {
        let metrics = runTextAreaBench(lineCount)
        sink += metrics.dirtyCells + metrics.diffWrites
    }
}
