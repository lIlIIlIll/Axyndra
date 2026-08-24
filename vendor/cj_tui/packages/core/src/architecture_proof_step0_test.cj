package core

import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

func step0BuffersEqual(left: ?Buffer, right: ?Buffer): Bool {
    match ((left, right)) {
        case (Some(expected), Some(actual)) =>
            if (expected.area != actual.area) { return false }
            for (y in expected.area.y..expected.area.bottom) {
                for (x in expected.area.x..expected.area.right) {
                    if (expected.getCell(x, y) != actual.getCell(x, y)) {
                        return false
                    }
                }
            }
            true
        case (None, None) => true
        case _ => false
    }
}

func step0RequireBuffersEqual(left: ?Buffer, right: ?Buffer, stage: String): Unit {
    match ((left, right)) {
        case (Some(expected), Some(actual)) =>
            if (expected.area != actual.area) {
                throw Exception("incremental/full area mismatch at ${stage}")
            }
            for (y in expected.area.y..expected.area.bottom) {
                for (x in expected.area.x..expected.area.right) {
                    let expectedCell = expected.getCell(x, y)
                    let actualCell = actual.getCell(x, y)
                    if (expectedCell != actualCell) {
                        throw Exception("incremental/full cell mismatch at ${stage} (${x},${y})")
                    }
                }
            }
        case (None, None) => ()
        case _ => throw Exception("incremental/full buffer presence mismatch at ${stage}")
    }
}

func step0RenderFixture(frame: Frame, lines: Array<String>, accent: Style): Unit {
    var row: Int64 = 0
    while (row < lines.size && row < frame.area.height) {
        frame.canvas().drawText(0, row, lines[row], if (row == 1) { accent } else { Style.default() })
        row++
    }
}

class Step2CWideFixture {
    let name: String
    let before: String
    let after: String
    let dirty: Array<Rect>

    init(name: String, before: String, after: String, dirty: Array<Rect>) {
        this.name = name
        this.before = before
        this.after = after
        this.dirty = dirty
    }
}

func step2CDrawRow(frame: Frame, text: String): Unit {
    frame.canvas().drawText(0, 0, text, Style.default())
}

func step2CDrawSlots(frame: Frame, slots: Array<String>, styles: Array<Style>): Unit {
    for (index in 0..slots.size) {
        frame.canvas().drawText(index * 2, 0, slots[index], styles[index])
    }
}

func step2CDirty(rects: Array<Rect>): DirtyRects {
    let dirty = DirtyRects()
    dirty.addAll(rects)
    dirty
}

class Step0OracleState {
    let lines = ArrayList<String>()
    var scroll: Int64 = 0
    var modal: Bool = false
    var style: Style = Style.default()

    init() {
        lines.add("first")
        lines.add("stream")
    }
}

func step0RenderState(frame: Frame, state: Step0OracleState): Unit {
    frame.fill(frame.area, Style.default())
    var row: Int64 = 0
    while (row < frame.area.height && state.scroll + row < state.lines.size) {
        frame.canvas().drawText(0, row, state.lines[state.scroll + row], state.style)
        row++
    }
    if (state.modal) {
        let modal = Rect(2, 1, max(1, frame.area.width - 4), min(3, frame.area.height - 1))
        frame.fill(modal, Style(bg: Color.Indexed(8)))
        frame.canvas().drawText(modal.x + 1, modal.y, "modal 中文", Style(fg: Color.Yellow, bg: Color.Indexed(8)))
    }
}

class Step0TranscriptSource <: VirtualTranscriptSource {
    var count: Int64
    var lastText: String = "tail"
    var lastRevision: Int64 = 0

    init(count: Int64) { this.count = count }

    public func size(): Int64 { count }
    public func itemId(index: Int64): String { "step0-${index}" }
    public func revision(index: Int64): Int64 {
        if (index == count - 1) { lastRevision } else { 0 }
    }
    public func document(index: Int64, _: Int64, _: String): Document {
        Document.plain(if (index == count - 1) { lastText } else { "historical item ${index}" })
    }

    func replaceTail(value: String): Unit {
        lastText = value
        lastRevision++
    }

    func append(): Unit { count++ }
}

class Step0CountingOutput <: OutputStream {
    let bytes = ArrayList<Byte>()

    public func write(value: Array<Byte>): Unit {
        for (byte in value) { bytes.add(byte) }
    }

    public func flush(): Unit {}
}

@Test
class ArchitectureProofStep0Test {
    @TestCase
    func partialDirtyWideBoundariesMatchFullRendering(): Unit {
        let fixtures = [
            Step2CWideFixture("fully-inside", "A中BCDE", "A界BCDE", [Rect(1, 0, 2, 1)]),
            Step2CWideFixture("lead-only", "A中BCDE", "A界BCDE", [Rect(1, 0, 1, 1)]),
            Step2CWideFixture("continuation-only", "A中BCDE", "A界BCDE", [Rect(2, 0, 1, 1)]),
            Step2CWideFixture("before-wide", "A中BCDE", "Z中BCDE", [Rect(0, 0, 1, 1)]),
            Step2CWideFixture("after-wide", "A中BCDE", "A中ZCDE", [Rect(3, 0, 1, 1)]),
            Step2CWideFixture("wide-to-narrow", "A中BCDE", "AxyBCDE", [Rect(1, 0, 1, 1)]),
            Step2CWideFixture("narrow-to-wide", "AxyBCDE", "A中BCDE", [Rect(2, 0, 1, 1)]),
            Step2CWideFixture("erase-wide", "A中BCDE", "A  BCDE", [Rect(2, 0, 1, 1)]),
            Step2CWideFixture("adjacent-wide", "中界ABCD", "中🙂ABCD", [Rect(2, 0, 1, 1)]),
            Step2CWideFixture("wide-at-zero", "中ABCDEF", "界ABCDEF", [Rect(0, 0, 1, 1)]),
            Step2CWideFixture("wide-at-right-edge", "ABCDEF中", "ABCDEF界", [Rect(7, 0, 1, 1)]),
            Step2CWideFixture("disjoint-near-wide", "A中BCDE", "Z中ZCDE", [Rect(0, 0, 1, 1), Rect(3, 0, 1, 1)]),
            Step2CWideFixture("overlapping", "A中BCDE", "A界BCDE", [Rect(1, 0, 2, 1), Rect(2, 0, 2, 1)]),
            Step2CWideFixture("emoji", "A🙂BCDE", "A🧭BCDE", [Rect(2, 0, 1, 1)]),
            Step2CWideFixture("combining-adjacent", "e\u{301}中ABCD", "o\u{302}中ABCD", [Rect(0, 0, 1, 1)]),
            Step2CWideFixture("variation-selector", "A✈\u{FE0F}BCDE", "A✈\u{FE0F}ZCDE", [Rect(2, 0, 1, 1)])
        ]
        let area = Rect(0, 0, 12, 2)
        for (fixture in fixtures) {
            let partialBackend = TestBackend(area: area, captureSnapshots: false)
            let fullBackend = TestBackend(area: area, captureSnapshots: false)
            let partial = Terminal(partialBackend, renderMode: RenderMode.Diff)
            let full = Terminal(fullBackend, renderMode: RenderMode.Full)
            _ = partial.draw { frame => step2CDrawRow(frame, fixture.before) }
            _ = full.draw { frame => step2CDrawRow(frame, fixture.before) }
            let dirty = step2CDirty(fixture.dirty)
            let metrics = partial.draw(
                { frame => step2CDrawRow(frame, fixture.after) },
                dirtyRects: Some(dirty)
            )
            _ = full.draw { frame => step2CDrawRow(frame, fixture.after) }
            step0RequireBuffersEqual(
                fullBackend.lastBuffer(),
                partialBackend.lastBuffer(),
                "wide-boundary-${fixture.name}"
            )
            @Expect(!metrics.fullRedraw)
            @Expect(metrics.renderedCells < area.width * area.height)
            @Expect(metrics.renderedCells <= dirty.cellCount() + fixture.dirty.size * 4)
        }
    }

    @TestCase
    func deterministicPartialDirtyWideSequencesMatchFullRendering(): Unit {
        let area = Rect(0, 0, 20, 2)
        let partialBackend = TestBackend(area: area, captureSnapshots: false)
        let fullBackend = TestBackend(area: area, captureSnapshots: false)
        let partial = Terminal(partialBackend, renderMode: RenderMode.Diff)
        let full = Terminal(fullBackend, renderMode: RenderMode.Full)
        let corpus = ["ab", "中", "🙂", "e\u{301}x", "界", "👩\u{200D}💻", "✈\u{FE0F}"]
        let slots = Array<String>(8, repeat: "ab")
        let styles = Array<Style>(8, repeat: Style.default())
        let cyan = Style(fg: Color.Cyan, bg: Color.Indexed(8))
        _ = partial.draw { frame => step2CDrawSlots(frame, slots, styles) }
        _ = full.draw { frame => step2CDrawSlots(frame, slots, styles) }

        var seed: Int64 = 0x2C2026
        for (step in 0..128) {
            seed = (seed * 48271 + 17) % 2147483647
            let slot = seed % slots.size
            seed = (seed * 48271 + 17) % 2147483647
            if (seed % 4 == 0) {
                styles[slot] = if (styles[slot] == Style.default()) { cyan } else { Style.default() }
            } else {
                slots[slot] = corpus[seed % corpus.size]
            }
            seed = (seed * 48271 + 17) % 2147483647
            let dirtyMode = seed % 3
            let x = slot * 2 + if (dirtyMode == 1) { 1 } else { 0 }
            let width: Int64 = if (dirtyMode == 2) { 2 } else { 1 }
            let dirty = DirtyRects()
            dirty.add(Rect(x, 0, width, 1))
            if (step % 5 == 0) {
                dirty.add(Rect((slot + 3) % slots.size * 2, 0, 1, 1))
            }
            if (step % 7 == 0) {
                dirty.add(Rect(max(0, x - 1), 0, 2, 1))
            }
            let metrics = partial.draw(
                { frame => step2CDrawSlots(frame, slots, styles) },
                dirtyRects: Some(dirty)
            )
            _ = full.draw { frame => step2CDrawSlots(frame, slots, styles) }
            step0RequireBuffersEqual(
                fullBackend.lastBuffer(),
                partialBackend.lastBuffer(),
                "wide-random-${step}"
            )
            @Expect(!metrics.fullRedraw)
            @Expect(metrics.renderedCells < area.width * area.height)
            @Expect(metrics.renderedCells <= dirty.cellCount() + dirty.rects().size * 4)
        }
    }

    @TestCase
    func differentialOraclePreservesCellStyleAndWideContinuation(): Unit {
        let area = Rect(0, 0, 24, 5)
        let diffBackend = TestBackend(area: area, captureSnapshots: false)
        let fullBackend = TestBackend(area: area, captureSnapshots: false)
        let diff = Terminal(diffBackend, renderMode: RenderMode.Diff)
        let full = Terminal(fullBackend, renderMode: RenderMode.Full)
        let initial = ["ASCII", "中文🙂", "e\u{301} wide界", "old bounds"]
        let changed = ["ASCII", "中文🧭", "e\u{301} wide界", "new"]
        let accent = Style(fg: Color.Cyan, bg: Color.Indexed(8))

        _ = diff.draw { frame => step0RenderFixture(frame, initial, accent) }
        _ = full.draw { frame => step0RenderFixture(frame, initial, accent) }
        let dirty = DirtyRects()
        dirty.add(Rect(0, 1, area.width, 3))
        _ = diff.draw({ frame => step0RenderFixture(frame, changed, accent) }, dirtyRects: Some(dirty))
        _ = full.draw { frame => step0RenderFixture(frame, changed, accent) }

        @Expect(step0BuffersEqual(fullBackend.lastBuffer(), diffBackend.lastBuffer()))
        @Expect(diffBackend.assertCell(6, 2, "界", style: Style.default()))
        @Expect(diffBackend.assertCell(7, 2, "", style: Style.default()))
    }

    @TestCase
    func differentialOracleDetectsLostInvalidation(): Unit {
        let area = Rect(0, 0, 12, 2)
        let diffBackend = TestBackend(area: area, captureSnapshots: false)
        let fullBackend = TestBackend(area: area, captureSnapshots: false)
        let diff = Terminal(diffBackend, renderMode: RenderMode.Diff)
        let full = Terminal(fullBackend, renderMode: RenderMode.Full)
        _ = diff.draw { frame => frame.canvas().drawText(0, 0, "stable old", Style.default()) }
        _ = full.draw { frame => frame.canvas().drawText(0, 0, "stable old", Style.default()) }
        let deliberatelyWrong = DirtyRects()
        deliberatelyWrong.add(Rect(0, 0, 1, 1))
        _ = diff.draw({ frame => frame.canvas().drawText(0, 0, "stable NEW", Style.default()) }, dirtyRects: Some(deliberatelyWrong))
        _ = full.draw { frame => frame.canvas().drawText(0, 0, "stable NEW", Style.default()) }
        @Expect(!step0BuffersEqual(fullBackend.lastBuffer(), diffBackend.lastBuffer()))
    }

    @TestCase
    func differentialOracleCoversStreamingScrollResizeModalAndTheme(): Unit {
        let initialArea = Rect(0, 0, 20, 5)
        let diffBackend = TestBackend(area: initialArea, captureSnapshots: false)
        let fullBackend = TestBackend(area: initialArea, captureSnapshots: false)
        let diff = Terminal(diffBackend, renderMode: RenderMode.Diff)
        let full = Terminal(fullBackend, renderMode: RenderMode.Full)
        let state = Step0OracleState()
        let drawFull = { =>
            _ = full.draw { frame => step0RenderState(frame, state) }
        }
        let expectEqual = { stage: String =>
            step0RequireBuffersEqual(fullBackend.lastBuffer(), diffBackend.lastBuffer(), stage)
        }

        _ = diff.draw { frame => step0RenderState(frame, state) }
        drawFull(); expectEqual("initial")

        // Streaming token without a height change, then a wrap/line crossing.
        state.lines[1] = "stream token"
        let streamDirty = DirtyRects(); streamDirty.add(Rect(0, 1, initialArea.width, 1))
        _ = diff.draw({ frame => step0RenderState(frame, state) }, dirtyRects: Some(streamDirty))
        drawFull(); expectEqual("stream-without-wrap")
        state.lines.add("wrapped continuation 界")
        let wrapDirty = DirtyRects(); wrapDirty.add(Rect(0, 1, initialArea.width, 2))
        _ = diff.draw({ frame => step0RenderState(frame, state) }, dirtyRects: Some(wrapDirty))
        drawFull(); expectEqual("stream-wrap")

        // Manual scrolling and returning to follow-bottom legitimately repaint
        // the viewport because every visible row can move.
        state.scroll = 1
        let viewportDirty = DirtyRects(); viewportDirty.add(initialArea)
        _ = diff.draw({ frame => step0RenderState(frame, state) }, dirtyRects: Some(viewportDirty))
        drawFull(); expectEqual("manual-scroll")
        state.lines.add("new bottom")
        state.scroll = max(0, state.lines.size - initialArea.height)
        _ = diff.draw({ frame => step0RenderState(frame, state) }, dirtyRects: Some(viewportDirty))
        drawFull(); expectEqual("follow-bottom")

        // Resize forces both terminals to establish a new full surface.
        let resized = Rect(0, 0, 24, 6)
        diffBackend.setSize(resized); fullBackend.setSize(resized)
        _ = diff.draw { frame => step0RenderState(frame, state) }
        drawFull(); expectEqual("resize")

        // Opening and closing an overlay must restore the covered base cells.
        state.modal = true
        // Invalidate complete affected rows so wide-cell guard columns are
        // restored by the same incremental paint.
        let overlayDirty = DirtyRects(); overlayDirty.add(Rect(0, 1, resized.width, 3))
        _ = diff.draw({ frame => step0RenderState(frame, state) }, dirtyRects: Some(overlayDirty))
        drawFull(); expectEqual("modal-open")
        state.modal = false
        _ = diff.draw({ frame => step0RenderState(frame, state) }, dirtyRects: Some(overlayDirty))
        drawFull(); expectEqual("modal-close")

        state.style = Style(fg: Color.Magenta, bg: Color.Indexed(8))
        let themeDirty = DirtyRects(); themeDirty.add(resized)
        _ = diff.draw({ frame => step0RenderState(frame, state) }, dirtyRects: Some(themeDirty))
        drawFull(); expectEqual("theme")
    }

    @TestCase
    func renderInstrumentationIsOptInAndDoesNotChangeBuffer(): Unit {
        let area = Rect(0, 0, 20, 3)
        let offBackend = TestBackend(area: area, captureSnapshots: false)
        let onBackend = TestBackend(area: area, captureSnapshots: false)
        let off = Terminal(offBackend, instrumentationEnabled: false)
        let on = Terminal(onBackend, instrumentationEnabled: true)
        let draw = { frame: Frame =>
            frame.fill(frame.area, Style(bg: Color.Indexed(8)))
            frame.canvas().drawText(1, 1, "中文 metrics", Style(fg: Color.Cyan))
        }
        let offMetrics = off.draw(draw)
        let onMetrics = on.draw(draw)
        @Expect(step0BuffersEqual(offBackend.lastBuffer(), onBackend.lastBuffer()))
        @Expect(offMetrics.bufferCellAttempts, 0)
        @Expect(offMetrics.bufferCellWrites, 0)
        @Expect(onMetrics.bufferCellAttempts > 0)
        @Expect(onMetrics.bufferCellWrites > 0)
        @Expect(onMetrics.diffCells, onMetrics.dirtyCells)
        @Expect(onMetrics.diffSpans, onMetrics.diffWrites)
        @Expect(onMetrics.totalNanos >= onMetrics.renderNanos)
        @Expect(onMetrics.ansiBytes, -1)
    }

    @TestCase
    func ansiInstrumentationReportsEncodedTransportBytes(): Unit {
        let output = Step0CountingOutput()
        let terminal = Terminal(
            AnsiBackend(output: output, fallbackArea: Rect(0, 0, 12, 2)),
            instrumentationEnabled: true
        )
        let metrics = terminal.draw { frame =>
            frame.canvas().drawText(0, 0, "中文 ansi", Style(fg: Color.Cyan))
        }
        @Expect(metrics.ansiBytes > 0)
        @Expect(metrics.ansiBytes, output.bytes.size)
    }

    @TestCase
    func virtualTranscriptMetricsExposeCacheWrapAndMetadataWork(): Unit {
        let source = Step0TranscriptSource(100)
        let state = VirtualTranscriptState(followBottom: true)
        let view = VirtualTranscriptView(source, state: state, instrumentationEnabled: true)
        let area = Rect(0, 0, 32, 8)
        let buffer = Buffer(area)

        view.render(area, buffer)
        view.render(area, buffer)
        source.replaceTail("tail crosses enough words to require wrapping at this width")
        view.render(area, buffer)
        source.append()
        _ = view.totalRows()
        view.render(Rect(0, 0, 24, 8), Buffer(Rect(0, 0, 24, 8)))

        let metrics = view.metrics()
        @Expect(metrics.syncCountCalls > 0)
        @Expect(metrics.cacheLookups > 0)
        @Expect(metrics.cacheHits > 0)
        @Expect(metrics.cacheMisses > 0)
        @Expect(metrics.cacheLookups, metrics.cacheHits + metrics.cacheMisses)
        @Expect(metrics.documentRequests, metrics.documentsMaterialized)
        @Expect(metrics.layoutCalls >= metrics.documentsMaterialized)
        @Expect(metrics.wrapInputBytes > 0)
        @Expect(metrics.metadataTouches >= 100)
        @Expect(metrics.heightIndexResetEntries, 0)
        @Expect(metrics.heightIndexGrowOperations >= 101)
        @Expect(metrics.heightIndexNodesTouched > 0)
        @Expect(metrics.heightMetadataEntries, 101)
        @Expect(metrics.heightIndexNodes, 101)
        @Expect(metrics.measurementInvalidations > 0)

        let instrumentation = view.instrumentationMetrics()
        @Expect(instrumentation.measuredEntries, -1)
        @Expect(instrumentation.cachedRows, -1)
        @Expect(instrumentation.cacheEntries, metrics.cacheEntries)
        @Expect(instrumentation.metadataTouches, metrics.metadataTouches)
        @Expect(instrumentation.documentsMaterialized, metrics.documentsMaterialized)
        @Expect(instrumentation.wrapInputBytes, metrics.wrapInputBytes)
    }
}
