package core

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func appendOnlyRenderMatchesFullCharacterWrap(
    view: VirtualTranscriptView,
    actual: Buffer,
    text: String,
    style: Style,
    wrapWidth: Int64
): Bool {
    let expectedRows = wrapText(text, wrapWidth, WrapMode.Character)
    if (expectedRows.size > actual.area.height ||
        view.totalRows() != expectedRows.size + 1) {
        return false
    }
    let expected = Buffer(actual.area)
    for (row in 0..expectedRows.size) {
        expected.setString(
            actual.area.x,
            actual.area.y + row,
            expectedRows[row],
            style: style
        )
    }
    for (y in actual.area.y..actual.area.bottom) {
        for (x in actual.area.x..actual.area.right) {
            if (actual.getCell(x, y) != expected.getCell(x, y)) {
                return false
            }
        }
    }
    true
}

class CountingTranscriptSource <: VirtualTranscriptSource {
    let count: Int64
    let revisions = ArrayList<Int64>()
    var documentCalls: Int64 = 0

    init(count: Int64) {
        this.count = count
        for (_ in 0..count) { revisions.add(0) }
    }

    public func size(): Int64 { count }
    public func itemId(index: Int64): String { "item-${index}" }
    public func revision(index: Int64): Int64 { revisions[index] }
    public func document(index: Int64, width: Int64, themeKey: String): Document {
        documentCalls++
        Document.plain("${themeKey} item-${index} width-${width}\nbody")
    }

    func stream(index: Int64): Unit { revisions[index]++ }
}

class GrowingTranscriptSource <: VirtualTranscriptSource {
    private var countValue: Int64
    private var generationValue: Int64 = 0
    var documentCalls: Int64 = 0

    init(count: Int64) { countValue = max(0, count) }

    public func size(): Int64 { countValue }
    public func generation(): Int64 { generationValue }
    public func itemId(index: Int64): String { "growing-${generationValue}-${index}" }
    public func revision(_: Int64): Int64 { 0 }
    public func document(index: Int64, _: Int64, _: String): Document {
        documentCalls++
        Document.plain("item-${index} 中文🙂 e\u{301}\nsecond line")
    }

    func grow(amount: Int64): Unit { countValue += max(0, amount) }
    func shrinkTo(count: Int64): Unit { countValue = clamp(count, 0, countValue) }
    func replace(count: Int64): Unit {
        countValue = max(0, count)
        generationValue++
    }
}

class SelectivePaintTranscriptSource <: VirtualTranscriptSource {
    private let texts = ArrayList<String>()
    private let revisions = ArrayList<Int64>()

    init(count: Int64) {
        for (index in 0..count) {
            texts.add("item-${index}")
            revisions.add(0)
        }
    }

    public func size(): Int64 { texts.size }
    public func itemId(index: Int64): String { "selective-${index}" }
    public func revision(index: Int64): Int64 { revisions[index] }
    public func itemAppendOnlyText(index: Int64, width: Int64, _: String): ?VirtualTranscriptAppendOnlyText {
        Some(VirtualTranscriptAppendOnlyText(
            texts[index],
            style: Style.default(),
            wrapWidth: width,
            appendEpoch: 0
        ))
    }
    public func document(_: Int64, _: Int64, _: String): Document { Document.plain("unused") }

    func append(index: Int64, text: String): Unit {
        texts[index] += text
        revisions[index]++
    }

}

@Test
class VirtualTranscriptTests {
    @TestCase
    func itemRevisionDirtyRectPaintsOnlyIntersectingVisibleItem(): Unit {
        let area = Rect(0, 0, 40, 8)
        let source = SelectivePaintTranscriptSource(20)
        let view = VirtualTranscriptView(source, instrumentationEnabled: true)
        let buffer = Buffer(area)
        buffer.beginWorkMetrics(true)
        view.render(area, buffer)
        let visibleBefore = view.lastVisibleRanges.size
        @Expect(visibleBefore >= 3)

        source.append(19, "界")
        let dirty = view.dirtyRectForItemRevision("selective-19")
        @Expect(dirty.isSome())
        let clip = DirtyRects()
        match (dirty) {
            case Some(rect) => clip.add(rect)
            case None => ()
        }
        buffer.setWriteClip(Some(clip))
        let before = view.instrumentationMetrics()
        view.render(area, buffer)
        let after = view.instrumentationMetrics()
        @Expect(after.visibleItems - before.visibleItems, visibleBefore)
        @Expect(after.itemsPainted - before.itemsPainted, 1)
        @Expect(after.rowsPainted - before.rowsPainted, 1)
    }

    @TestCase
    func selectiveItemPaintMatchesFullAndLostDirtyIsDetected(): Unit {
        let area = Rect(0, 0, 32, 8)
        let selectiveSource = SelectivePaintTranscriptSource(20)
        let fullSource = SelectivePaintTranscriptSource(20)
        let selectiveView = VirtualTranscriptView(selectiveSource)
        let fullView = VirtualTranscriptView(fullSource)
        let selectiveBackend = TestBackend(area: area, captureSnapshots: false)
        let fullBackend = TestBackend(area: area, captureSnapshots: false)
        let selective = Terminal(selectiveBackend, renderMode: RenderMode.Diff)
        let full = Terminal(fullBackend, renderMode: RenderMode.Full)
        _ = selective.draw { frame => frame.renderWidget(selectiveView, frame.area) }
        _ = full.draw { frame => frame.renderWidget(fullView, frame.area) }

        selectiveSource.append(19, "界🙂e\u{301}")
        fullSource.append(19, "界🙂e\u{301}")
        let dirty = selectiveView.dirtyRectForItemRevision("selective-19")
        @Expect(dirty.isSome())
        let dirtyRects = DirtyRects()
        match (dirty) {
            case Some(rect) => dirtyRects.add(rect)
            case None => ()
        }
        _ = selective.draw(
            { frame => frame.renderWidget(selectiveView, frame.area) },
            dirtyRects: Some(dirtyRects)
        )
        _ = full.draw { frame => frame.renderWidget(fullView, frame.area) }
        step0RequireBuffersEqual(fullBackend.lastBuffer(), selectiveBackend.lastBuffer(), "vt-selective-wide")

        selectiveSource.append(19, "X")
        fullSource.append(19, "X")
        let deliberatelyWrong = DirtyRects()
        deliberatelyWrong.add(Rect(0, 0, area.width, 1))
        _ = selective.draw(
            { frame => frame.renderWidget(selectiveView, frame.area) },
            dirtyRects: Some(deliberatelyWrong)
        )
        _ = full.draw { frame => frame.renderWidget(fullView, frame.area) }
        @Expect(!step0BuffersEqual(fullBackend.lastBuffer(), selectiveBackend.lastBuffer()))
    }

    @TestCase
    func offscreenTailRevisionNeedsNoPaintAndHeightChangeFallsBack(): Unit {
        let area = Rect(0, 0, 24, 8)
        let source = SelectivePaintTranscriptSource(100)
        let state = VirtualTranscriptState(followBottom: true)
        let view = VirtualTranscriptView(source, state: state, instrumentationEnabled: true)
        view.render(area, Buffer(area))
        @Expect(view.handle(KeyEvent(KeyCode.PageUp)))
        view.render(area, Buffer(area))
        source.append(99, " offscreen tail")
        @Expect(view.dirtyRectForItemRevision("selective-99").isNone())

        @Expect(view.handle(KeyEvent(KeyCode.End)))
        view.render(area, Buffer(area))
        source.append(99, " this forces enough wrapping to change the item height across several rows 中文🙂")
        match (view.dirtyRectForItemRevision("selective-99")) {
            case Some(rect) => @Expect(rect, area)
            case None => @Expect(false)
        }
    }

    @TestCase
    func selectivePaintWorkIsViewportBoundAcrossHistorySizes(): Unit {
        let area = Rect(0, 0, 40, 8)
        for (history in [100, 1000, 10000, 100000]) {
            let source = SelectivePaintTranscriptSource(history)
            let view = VirtualTranscriptView(source, instrumentationEnabled: true)
            let buffer = Buffer(area)
            buffer.beginWorkMetrics(true)
            view.render(area, buffer)
            source.append(history - 1, "x")
            let dirty = view.dirtyRectForItemRevision("selective-${history - 1}")
            let clip = DirtyRects()
            match (dirty) {
                case Some(rect) => clip.add(rect)
                case None => @Expect(false)
            }
            buffer.setWriteClip(Some(clip))
            let before = view.instrumentationMetrics()
            view.render(area, buffer)
            let after = view.instrumentationMetrics()
            @Expect(after.itemsPainted - before.itemsPainted, 1)
            @Expect(after.rowsPainted - before.rowsPainted, 1)
            @Expect(after.metadataTouches - before.metadataTouches <= 64)
            @Expect(after.heightIndexResetEntries - before.heightIndexResetEntries, 0)
        }
    }
    @TestCase
    func heightIndexAppendPreservesPrefixLookupAndUpdates(): Unit {
        let index = TranscriptHeightIndex()
        @Expect(index.append(height: 2) > 0)
        @Expect(index.append(height: 3) > 0)
        @Expect(index.append(height: 1) > 0)
        @Expect(index.total(), 6)
        @Expect(index.prefix(0), 0)
        @Expect(index.prefix(1), 2)
        @Expect(index.prefix(2), 5)
        @Expect(index.itemAt(0), 0)
        @Expect(index.itemAt(1), 0)
        @Expect(index.itemAt(2), 1)
        @Expect(index.itemAt(4), 1)
        @Expect(index.itemAt(5), 2)
        @Expect(index.update(1, 5) > 0)
        @Expect(index.total(), 8)
        @Expect(index.prefix(2), 7)
        @Expect(index.itemAt(6), 1)
        @Expect(index.itemAt(7), 2)
    }

    @TestCase
    func appendGrowthDoesNotResetOrScanHistoricalMetadata(): Unit {
        for (history in [0, 1, 63, 64, 65, 999, 9999, 99999, 100000]) {
            let source = GrowingTranscriptSource(history)
            let view = VirtualTranscriptView(source, instrumentationEnabled: true)
            let before = view.instrumentationMetrics()
            source.grow(1)
            @Expect(view.totalRows(), history + 1)
            let after = view.instrumentationMetrics()
            @Expect(after.metadataTouches - before.metadataTouches, 1)
            @Expect(after.heightIndexResetEntries - before.heightIndexResetEntries, 0)
            @Expect(after.heightIndexGrowOperations - before.heightIndexGrowOperations, 1)
            @Expect(after.heightIndexNodesTouched - before.heightIndexNodesTouched <= 64)
            @Expect(after.heightMetadataEntries, history + 1)
            @Expect(after.heightIndexNodes, history + 1)
            @Expect(after.cacheEntries, history + 1)
        }
    }

    @TestCase
    func batchAndRepeatedAppendWorkScaleWithNewItemsOnly(): Unit {
        let source = GrowingTranscriptSource(10000)
        let view = VirtualTranscriptView(source, instrumentationEnabled: true)
        for (amount in [1, 2, 10, 100]) {
            let before = view.instrumentationMetrics()
            source.grow(amount)
            _ = view.totalRows()
            let after = view.instrumentationMetrics()
            @Expect(after.metadataTouches - before.metadataTouches, amount)
            @Expect(after.heightIndexResetEntries - before.heightIndexResetEntries, 0)
            @Expect(after.heightIndexGrowOperations - before.heightIndexGrowOperations, amount)
            @Expect(after.heightIndexNodesTouched - before.heightIndexNodesTouched <= amount * 64)
        }

        var maximumNodes: Int64 = 0
        let beforeSoak = view.instrumentationMetrics()
        for (_ in 0..10000) {
            let before = view.instrumentationMetrics()
            source.grow(1)
            _ = view.totalRows()
            let after = view.instrumentationMetrics()
            maximumNodes = max(maximumNodes, after.heightIndexNodesTouched - before.heightIndexNodesTouched)
        }
        let afterSoak = view.instrumentationMetrics()
        @Expect(afterSoak.metadataTouches - beforeSoak.metadataTouches, 10000)
        @Expect(afterSoak.heightIndexGrowOperations - beforeSoak.heightIndexGrowOperations, 10000)
        @Expect(afterSoak.heightIndexResetEntries - beforeSoak.heightIndexResetEntries, 0)
        @Expect(maximumNodes <= 64)
    }

    @TestCase
    func shrinkAndReplacementUseExplicitRebuildPath(): Unit {
        let source = GrowingTranscriptSource(1000)
        let view = VirtualTranscriptView(source, instrumentationEnabled: true)
        source.shrinkTo(100)
        let beforeShrink = view.instrumentationMetrics()
        @Expect(view.totalRows(), 100)
        let afterShrink = view.instrumentationMetrics()
        @Expect(afterShrink.heightIndexResetEntries - beforeShrink.heightIndexResetEntries, 100)
        @Expect(afterShrink.heightMetadataEntries, 100)

        source.replace(250)
        let beforeReplacement = view.instrumentationMetrics()
        @Expect(view.totalRows(), 250)
        let afterReplacement = view.instrumentationMetrics()
        @Expect(afterReplacement.heightIndexGrowOperations - beforeReplacement.heightIndexGrowOperations, 150)
        @Expect(afterReplacement.heightIndexResetEntries - beforeReplacement.heightIndexResetEntries, 0)
        @Expect(afterReplacement.heightMetadataEntries, 250)
    }

    @TestCase
    func appendPreservesFollowBottomAndManualAnchor(): Unit {
        let area = Rect(0, 0, 48, 10)
        let bottomSource = GrowingTranscriptSource(100)
        let bottomState = VirtualTranscriptState(followBottom: true)
        let bottomView = VirtualTranscriptView(bottomSource, state: bottomState)
        let bottomBackend = TestBackend(area: area)
        let bottomTerminal = Terminal(bottomBackend, renderMode: RenderMode.Diff)
        _ = bottomTerminal.draw { frame => frame.renderWidget(bottomView, frame.area) }
        bottomSource.grow(1)
        _ = bottomTerminal.draw { frame => frame.renderWidget(bottomView, frame.area) }
        @Expect(bottomState.followBottom)
        @Expect(bottomBackend.snapshot().contains("second line"))

        let manualSource = GrowingTranscriptSource(100)
        let manualState = VirtualTranscriptState(followBottom: true)
        let manualView = VirtualTranscriptView(manualSource, state: manualState)
        let manualBackend = TestBackend(area: area)
        let manualTerminal = Terminal(manualBackend, renderMode: RenderMode.Diff)
        _ = manualTerminal.draw { frame => frame.renderWidget(manualView, frame.area) }
        @Expect(manualView.handle(KeyEvent(KeyCode.PageUp)))
        _ = manualTerminal.draw { frame => frame.renderWidget(manualView, frame.area) }
        let anchor = manualState.anchorId
        let scrollTop = manualState.scrollTop
        manualSource.grow(1)
        _ = manualTerminal.draw { frame => frame.renderWidget(manualView, frame.area) }
        @Expect(!manualState.followBottom)
        @Expect(manualState.anchorId, anchor)
        @Expect(manualState.scrollTop, scrollTop)
    }

    @TestCase
    func appendUnicodeResizeAndThemeMatchFullRendering(): Unit {
        let area = Rect(0, 0, 32, 8)
        let incrementalSource = GrowingTranscriptSource(20)
        let fullSource = GrowingTranscriptSource(20)
        let incrementalView = VirtualTranscriptView(incrementalSource)
        let fullView = VirtualTranscriptView(fullSource)
        let incrementalBackend = TestBackend(area: area, captureSnapshots: false)
        let fullBackend = TestBackend(area: area, captureSnapshots: false)
        let incremental = Terminal(incrementalBackend, renderMode: RenderMode.Diff)
        let full = Terminal(fullBackend, renderMode: RenderMode.Full)
        _ = incremental.draw { frame => frame.renderWidget(incrementalView, frame.area) }
        _ = full.draw { frame => frame.renderWidget(fullView, frame.area) }

        incrementalSource.grow(1)
        fullSource.grow(1)
        _ = incremental.draw { frame => frame.renderWidget(incrementalView, frame.area) }
        _ = full.draw { frame => frame.renderWidget(fullView, frame.area) }
        step0RequireBuffersEqual(fullBackend.lastBuffer(), incrementalBackend.lastBuffer(), "vt-append-wide")

        let resized = Rect(0, 0, 24, 9)
        incrementalBackend.setSize(resized)
        fullBackend.setSize(resized)
        incrementalView.setThemeKey("light")
        fullView.setThemeKey("light")
        _ = incremental.draw { frame => frame.renderWidget(incrementalView, frame.area) }
        _ = full.draw { frame => frame.renderWidget(fullView, frame.area) }
        step0RequireBuffersEqual(fullBackend.lastBuffer(), incrementalBackend.lastBuffer(), "vt-append-resize-theme")
    }

    @TestCase
    func firstRenderMaterializesBoundedTailWindow(): Unit {
        let source = CountingTranscriptSource(10000)
        let state = VirtualTranscriptState()
        let view = VirtualTranscriptView(source, state: state)
        let area = Rect(0, 0, 120, 36)
        let backend = TestBackend(area: area)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(source.documentCalls < 256)
        @Expect(backend.snapshot().contains("item-9999"))
        @Expect(state.followBottom)
    }

    @TestCase
    func defaultRenderingDoesNotEventuallyMaterializeTheWholeSource(): Unit {
        let source = CountingTranscriptSource(1000)
        let view = VirtualTranscriptView(source)
        let backend = TestBackend(area: Rect(0, 0, 80, 20))
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)
        for (_ in 0..150) {
            _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        }
        @Expect(source.documentCalls < 128)
    }

    @TestCase
    func streamingRevisionInvalidatesOnlyChangedCard(): Unit {
        let source = CountingTranscriptSource(10000)
        let state = VirtualTranscriptState()
        let view = VirtualTranscriptView(source, state: state)
        let area = Rect(0, 0, 120, 36)
        let backend = TestBackend(area: area)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        let before = source.documentCalls
        source.stream(9999)
        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(source.documentCalls - before <= 9)
        @Expect(backend.snapshot().contains("item-9999"))
    }

    @TestCase
    func pageAndResizeKeepStableItemAnchor(): Unit {
        let source = CountingTranscriptSource(10000)
        let state = VirtualTranscriptState()
        let view = VirtualTranscriptView(source, state: state)
        let firstArea = Rect(0, 0, 120, 36)
        let backend = TestBackend(area: firstArea)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(view.handle(KeyEvent(KeyCode.PageUp)))
        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        let anchor = state.anchorId
        backend.setSize(Rect(0, 0, 80, 24))
        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(state.anchorId, anchor)
        @Expect(!state.followBottom)

        view.setThemeKey("light")
        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(state.anchorId, anchor)
        @Expect(view.handle(KeyEvent(KeyCode.End)))
        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(backend.snapshot().contains("item-9999"))
    }

    @TestCase
    func widthRevisionWorkIsBoundedByViewportNotHistory(): Unit {
        var touchesAt10k: Int64 = 0
        var touchesAt100k: Int64 = 0
        for (history in [100, 1000, 10000, 100000]) {
            let source = GrowingTranscriptSource(history)
            let state = VirtualTranscriptState(followBottom: true)
            let view = VirtualTranscriptView(
                source,
                state: state,
                instrumentationEnabled: true
            )
            let initial = Rect(0, 0, 120, 24)
            view.render(initial, Buffer(initial))
            let before = view.instrumentationMetrics()
            let resized = Rect(0, 0, 37, 24)
            view.render(resized, Buffer(resized))
            let after = view.instrumentationMetrics()
            let touches = after.metadataTouches - before.metadataTouches
            let remeasured = after.entriesRemeasured - before.entriesRemeasured
            @Expect(after.measurementGenerationBumps - before.measurementGenerationBumps, 1)
            @Expect(after.heightIndexResetEntries - before.heightIndexResetEntries, 0)
            @Expect(after.staleEntriesEncountered - before.staleEntriesEncountered, remeasured)
            @Expect(touches <= 512)
            @Expect(remeasured <= 256)
            @Expect(after.heightIndexUpdateCalls - before.heightIndexUpdateCalls <= 256)
            if (history == 10000) { touchesAt10k = touches }
            if (history == 100000) { touchesAt100k = touches }
        }
        @Expect(touchesAt100k <= touchesAt10k * 2)
    }

    @TestCase
    func resizePreservesManualAnchorAndExactTailAcrossWidthExtremes(): Unit {
        let source = GrowingTranscriptSource(100000)
        let manualState = VirtualTranscriptState(followBottom: true)
        let manualView = VirtualTranscriptView(
            source,
            state: manualState,
            instrumentationEnabled: true
        )
        let initial = Rect(0, 0, 120, 18)
        manualView.render(initial, Buffer(initial))
        @Expect(manualView.handle(KeyEvent(KeyCode.PageUp)))
        manualView.render(initial, Buffer(initial))
        let anchor = manualState.anchorId
        let visibleAnchor = manualView.lastVisibleRanges[0].id

        for (width in [20, 160, 21, 159, 37, 120]) {
            let before = manualView.instrumentationMetrics()
            let area = Rect(0, 0, width, 18)
            manualView.render(area, Buffer(area))
            let after = manualView.instrumentationMetrics()
            @Expect(!manualState.followBottom)
            @Expect(manualState.anchorId, anchor)
            @Expect(manualView.lastVisibleRanges[0].id, visibleAnchor)
            @Expect(after.metadataTouches - before.metadataTouches <= 512)
            @Expect(after.heightIndexResetEntries - before.heightIndexResetEntries, 0)
        }

        let tailState = VirtualTranscriptState(followBottom: true)
        let tailView = VirtualTranscriptView(source, state: tailState)
        let tailBackend = TestBackend(area: initial)
        let tailTerminal = Terminal(tailBackend, renderMode: RenderMode.Full)
        _ = tailTerminal.draw { frame => frame.renderWidget(tailView, frame.area) }
        for (width in [20, 160, 37, 120]) {
            let area = Rect(0, 0, width, 18)
            tailBackend.setSize(area)
            _ = tailTerminal.draw { frame => frame.renderWidget(tailView, frame.area) }
            @Expect(tailState.followBottom)
            @Expect(tailBackend.snapshot().contains("item-99999"))
        }
    }

    @TestCase
    func resizeThenNavigationAndUnicodeRemainLocallyBounded(): Unit {
        let source = GrowingTranscriptSource(100000)
        let state = VirtualTranscriptState(followBottom: true)
        let view = VirtualTranscriptView(source, state: state, instrumentationEnabled: true)
        let initial = Rect(0, 0, 100, 20)
        view.render(initial, Buffer(initial))
        @Expect(view.handle(KeyEvent(KeyCode.PageUp)))
        view.render(initial, Buffer(initial))

        let narrow = Rect(0, 0, 24, 20)
        view.render(narrow, Buffer(narrow))
        let beforeLine = view.instrumentationMetrics()
        @Expect(view.handle(KeyEvent(KeyCode.Up)))
        view.render(narrow, Buffer(narrow))
        let afterLine = view.instrumentationMetrics()
        @Expect(afterLine.metadataTouches - beforeLine.metadataTouches <= 512)

        let beforePage = view.instrumentationMetrics()
        @Expect(view.handle(KeyEvent(KeyCode.PageDown)))
        view.render(narrow, Buffer(narrow))
        let afterPage = view.instrumentationMetrics()
        @Expect(afterPage.metadataTouches - beforePage.metadataTouches <= 512)

        let beforeUnicode = view.instrumentationMetrics()
        view.setUnicode(false)
        view.render(narrow, Buffer(narrow))
        let afterUnicode = view.instrumentationMetrics()
        @Expect(afterUnicode.measurementGenerationBumps - beforeUnicode.measurementGenerationBumps, 1)
        @Expect(afterUnicode.metadataTouches - beforeUnicode.metadataTouches <= 512)
        @Expect(afterUnicode.heightIndexResetEntries - beforeUnicode.heightIndexResetEntries, 0)
    }

    @TestCase
    func rendersUtf8BoundarySamples(): Unit {
        // Shared UTF-8 boundary corpus (mirrored in cj_markdown
        // markdown_test.cj and agent_tui tui.cj headless). Rendering every
        // sample through the real VirtualTranscriptView must not throw and
        // must produce visible rows — with card chrome enabled to exercise
        // the border path over multi-byte titles.
        let samples = [
            "plain ascii body\n\n- item one\n- item two\n\n# Heading\n\n```cj\nmain()\n```\n",
            "Café résumé naïve €50\n\n- édition spéciale\n- piñata ñoño\n",
            "中文标题\n\n- 列表项一\n- 列表项二\n\n## 二级标题\n\n| 列A | 列B |\n| --- | --- |\n| 甲 | 乙 |\n\n这是一段很长的中文内容。\n",
            "🎯 任务列表\n\n- 🎯 任务一\n- [x] ✅ 已完成\n- 🚀 启动\n\n> 引用 🎉\n",
            "家庭 👨👩👧 组合\n\n- 👨👩👧 三个人\n- 组合 🧑🤝🧑 与 🇨🇳\n",
            "🚀 综合样本\n\n# 标题一\n\n- 🎯 中文任务 éé\n- [x] ✅ 完成项\n- 👨👩👧 家庭项\n\n## 二级 **加粗中文**\n\n1. 有序一\n2. 有序二\n\n```\n代码块中文\n```\n\n| 名称 | 状态 |\n| --- | --- |\n| 中文 | ✅ |\n\n很长的一段内容…\n"
        ]
        let source = Utf8BoundarySource(samples)
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        let backend = TestBackend(area: Rect(0, 0, 80, 30))
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)
        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(view.lastVisibleRanges.size > 0)
        let snapshot = backend.snapshot()
        @Expect(snapshot.contains("🎯"))
        // Wide glyphs occupy two cells (WideLead + space tail), so text
        // checks against snapshots must strip the tail spaces first.
        @Expect(snapshot.replace(" ", "").contains("中文"))
    }

    @TestCase
    func cardHeaderReservesRailWidthForStatusSuffix(): Unit {
        let source = TitleWidthTranscriptSource()
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        let area = Rect(0, 0, 30, 8)
        let backend = TestBackend(area: area)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        @Expect(source.lastTitleWidth, 27)
        @Expect(backend.snapshot().contains("running"))
    }

    @TestCase
    func cardChromeFallsBackToAsciiWithoutUnicode(): Unit {
        let source = TitleWidthTranscriptSource()
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        view.setUnicode(false)
        let area = Rect(0, 0, 30, 8)
        let backend = TestBackend(area: area)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        let snapshot = backend.snapshot()
        @Expect(snapshot.contains("+- "))
        @Expect(snapshot.contains("|  "))
    }

    @TestCase
    func compactCardChromeOmitsEmptyFooterRow(): Unit {
        let source = CompactChromeTranscriptSource()
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        let backend = TestBackend(area: Rect(0, 0, 50, 5))
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)

        _ = terminal.draw { frame => frame.renderWidget(view, frame.area) }
        let snapshot = backend.snapshot()
        @Expect(snapshot.contains("╭─ ✓ GitHub · completed"))
        @Expect(!snapshot.contains("╰─"))
        @Expect(!snapshot.contains("│ "))
    }

    @TestCase
    func fullFrameRendersOneContainerWithLabeledSeparatorAndFooter(): Unit {
        let source = FullFrameTranscriptSource()
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        let buffer = Buffer(Rect(0, 0, 32, 8))

        view.render(buffer.area, buffer)

        @Expect(buffer.getCell(0, 0).symbol, "╭")
        @Expect(buffer.getCell(0, 0).style, Style(fg: Color.Indexed(8)))
        @Expect(buffer.getCell(31, 0).symbol, "╮")
        @Expect(buffer.getCell(1, 1).style, Style(fg: Color.Blue))
        @Expect(buffer.getCell(0, 2).symbol, "├")
        @Expect(buffer.getCell(4, 2).symbol, "O")
        @Expect(buffer.getCell(4, 2).style, Style(fg: Color.Yellow))
        @Expect(buffer.getCell(31, 2).symbol, "┤")
        @Expect(buffer.getCell(1, 3).style, Style(fg: Color.Cyan))
        @Expect(buffer.getCell(1, 4).symbol, "〈")
        @Expect(buffer.getCell(1, 4).style, Style(fg: Color.Indexed(8)))
        @Expect(buffer.getCell(0, 5).symbol, "╰")
        @Expect(buffer.getCell(31, 5).symbol, "╯")
    }

    @TestCase
    func runningNoOutputFrameKeepsBothSidesOnOneColumnAcrossResize(): Unit {
        let source = RunningNoOutputTranscriptSource()
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)

        for (width in [80, 120, 160]) {
            let left: Int64 = 7
            let top: Int64 = 1
            let right = left + width - 1
            let buffer = Buffer(Rect(0, 0, width + 14, 10))
            view.render(Rect(left, top, width, 8), buffer)

            @Expect(buffer.getCell(left, top).symbol, "╭")
            @Expect(buffer.getCell(right, top).symbol, "╮")
            @Expect(buffer.getCell(left, top + 1).symbol, "│")
            @Expect(buffer.getCell(right, top + 1).symbol, "│")
            @Expect(buffer.getCell(left, top + 2).symbol, "│")
            @Expect(buffer.getCell(right, top + 2).symbol, "│")
            @Expect(buffer.getCell(left, top + 3).symbol, "╰")
            @Expect(buffer.getCell(right, top + 3).symbol, "╯")
            @Expect(buffer.getCell(left + 2, top + 1).symbol, "$")
            @Expect(buffer.getCell(left + 2, top + 2).symbol, "〈")
            for (y in top..(top + 4)) {
                @Expect(buffer.getCell(left + 1, y).symbol != "│")
            }
        }
    }

    @TestCase
    func streamingOutputAddsSeparatorWithoutChangingOuterColumns(): Unit {
        let source = StreamingFullFrameTranscriptSource()
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        let area = Rect(5, 1, 80, 8)
        let initial = Buffer(Rect(0, 0, 90, 10))

        view.render(area, initial)
        @Expect(initial.getCell(5, 2).symbol, "│")
        @Expect(initial.getCell(84, 2).symbol, "│")
        @Expect(initial.getCell(5, 3).symbol, "│")
        @Expect(initial.getCell(84, 3).symbol, "│")
        @Expect(initial.getCell(5, 4).symbol, "╰")
        @Expect(initial.getCell(84, 4).symbol, "╯")

        source.showOutput()
        let visible = Buffer(Rect(0, 0, 90, 10))
        view.render(area, visible)
        @Expect(visible.getCell(5, 3).symbol, "├")
        @Expect(visible.getCell(84, 3).symbol, "┤")
        @Expect(visible.getCell(5, 4).symbol, "│")
        @Expect(visible.getCell(84, 4).symbol, "│")
        @Expect(visible.getCell(5, 5).symbol, "│")
        @Expect(visible.getCell(84, 5).symbol, "│")
        @Expect(visible.getCell(5, 6).symbol, "╰")
        @Expect(visible.getCell(84, 6).symbol, "╯")
    }

    @TestCase
    func backgroundBlockFillsFullWidthAndReflowsAtNewWidth(): Unit {
        let source = BackgroundTranscriptSource()
        let view = VirtualTranscriptView(source)
        view.setCardChrome(true)
        let first = Buffer(Rect(0, 0, 20, 8))

        view.render(first.area, first)

        @Expect(source.lastWidth, 16)
        @Expect(first.getCell(0, 0).style, Style(bg: Color.Blue))
        @Expect(first.getCell(19, 0).style, Style(bg: Color.Blue))
        @Expect(first.getCell(2, 1).symbol, "这")
        @Expect(first.getCell(19, 2).style, Style(bg: Color.Blue))

        let resized = Buffer(Rect(0, 0, 30, 8))
        view.render(resized.area, resized)
        @Expect(source.lastWidth, 26)
        @Expect(resized.getCell(29, 1).style, Style(bg: Color.Blue))
    }

    @TestCase
    func appendOnlyTextMatchesFullCharacterWrapAfterEveryAppend(): Unit {
        let source = AppendOnlyTranscriptSource("")
        let view = VirtualTranscriptView(source)
        let width: Int64 = 9
        let area = Rect(0, 0, width, 128)
        let chunks = [
            "\n",
            "\n",
            "A",
            "\u{0301}",
            "中文",
            "👩",
            "\u{200D}",
            "💻",
            "\u{1F1FA}",
            "\u{1F1F8}",
            "क",
            "\u{094D}",
            "ष",
            "\u{1B}[31mred",
            "\u{1B}[0m",
            "\n",
            "\n",
            "tail",
            "\n"
        ]
        var expectedIncremental: Int64 = 0
        var first = true

        for (chunk in chunks) {
            source.appendText(chunk)
            let actual = Buffer(area)
            view.render(area, actual)
            @Expect(appendOnlyRenderMatchesFullCharacterWrap(
                view,
                actual,
                source.textValue,
                source.styleValue,
                width
            ))
            if (first) {
                first = false
            } else {
                expectedIncremental++
            }
            let metrics = view.metrics()
            @Expect(metrics.appendOnlyFullLayouts, 1)
            @Expect(metrics.appendOnlyIncrementalLayouts, expectedIncremental)
            @Expect(source.documentCalls, 0)
        }
    }

    @TestCase
    func appendOnlyLongLineRewrapsOnlyTheMutableVisualTail(): Unit {
        let source = AppendOnlyTranscriptSource(repeat("x", 512))
        let view = VirtualTranscriptView(source)
        let width: Int64 = 12
        let area = Rect(0, 0, width, 128)
        let initial = Buffer(area)
        view.render(area, initial)
        @Expect(view.metrics().appendOnlyFullLayouts, 1)
        @Expect(appendOnlyRenderMatchesFullCharacterWrap(
            view,
            initial,
            source.textValue,
            source.styleValue,
            width
        ))

        for (i in 0..64) {
            let before = view.metrics().appendOnlyRewrappedBytes
            source.appendText("y")
            let actual = Buffer(area)
            view.render(area, actual)
            let metrics = view.metrics()
            @Expect(metrics.appendOnlyRewrappedBytes - before <= width + 1)
            @Expect(metrics.appendOnlyFullLayouts, 1)
            @Expect(metrics.appendOnlyIncrementalLayouts, i + 1)
            @Expect(appendOnlyRenderMatchesFullCharacterWrap(
                view,
                actual,
                source.textValue,
                source.styleValue,
                width
            ))
        }
        @Expect(source.documentCalls, 0)
    }

    @TestCase
    func appendOnlyReplacementAndCacheBoundariesForceFullLayout(): Unit {
        let source = AppendOnlyTranscriptSource("abcdefghij")
        let view = VirtualTranscriptView(source)
        let narrow = Rect(0, 0, 8, 32)
        view.render(narrow, Buffer(narrow))
        @Expect(view.metrics().appendOnlyFullLayouts, 1)

        source.appendText("k")
        view.render(narrow, Buffer(narrow))
        @Expect(view.metrics().appendOnlyIncrementalLayouts, 1)

        source.replaceText("replacement")
        view.render(narrow, Buffer(narrow))
        @Expect(view.metrics().appendOnlyFullLayouts, 2)

        let wide = Rect(0, 0, 10, 32)
        view.render(wide, Buffer(wide))
        @Expect(view.metrics().appendOnlyFullLayouts, 3)

        view.setThemeKey("light")
        view.render(wide, Buffer(wide))
        @Expect(view.metrics().appendOnlyFullLayouts, 4)

        source.bumpGeneration()
        view.render(wide, Buffer(wide))
        @Expect(view.metrics().appendOnlyFullLayouts, 5)

        @Expect(view.invalidateItem("append-only"))
        view.render(wide, Buffer(wide))
        @Expect(view.metrics().appendOnlyFullLayouts, 6)

        source.changeStyle(Style(fg: Color.Yellow))
        view.render(wide, Buffer(wide))
        @Expect(view.metrics().appendOnlyFullLayouts, 7)

        source.replaceWithoutEpoch("short")
        let finalBuffer = Buffer(wide)
        view.render(wide, finalBuffer)
        @Expect(view.metrics().appendOnlyFullLayouts, 8)
        @Expect(source.documentCalls, 0)
        @Expect(appendOnlyRenderMatchesFullCharacterWrap(
            view,
            finalBuffer,
            source.textValue,
            source.styleValue,
            10
        ))
    }

    @TestCase
    func appendOnlyMetricsKeepLegacyFourArgumentConstruction(): Unit {
        let metrics = VirtualTranscriptMetrics(1, 2, 3, 4)
        @Expect(metrics.materialized, 1)
        @Expect(metrics.cachedRows, 4)
        @Expect(metrics.appendOnlyFullLayouts, 0)
        @Expect(metrics.appendOnlyIncrementalLayouts, 0)
        @Expect(metrics.appendOnlyRewrappedBytes, 0)
    }
}

class AppendOnlyTranscriptSource <: VirtualTranscriptSource {
    var textValue: String
    var styleValue: Style = Style(fg: Color.Cyan)
    var revisionValue: Int64 = 0
    var epochValue: Int64 = 0
    var generationValue: Int64 = 0
    var documentCalls: Int64 = 0

    init(text: String) {
        textValue = text
    }

    public func size(): Int64 { 1 }
    public func generation(): Int64 { generationValue }
    public func itemId(_: Int64): String { "append-only" }
    public func itemUsesCardChrome(_: Int64): Bool { false }
    public func revision(_: Int64): Int64 { revisionValue }
    public func itemAppendOnlyText(
        _: Int64,
        width: Int64,
        _: String
    ): ?VirtualTranscriptAppendOnlyText {
        Some(VirtualTranscriptAppendOnlyText(
            textValue,
            style: styleValue,
            wrapWidth: width,
            appendEpoch: epochValue
        ))
    }
    public func document(_: Int64, _: Int64, _: String): Document {
        documentCalls++
        Document.plain("unexpected document path")
    }

    func appendText(value: String): Unit {
        textValue += value
        revisionValue++
    }

    func replaceText(value: String): Unit {
        textValue = value
        epochValue++
        revisionValue++
    }

    func replaceWithoutEpoch(value: String): Unit {
        textValue = value
        revisionValue++
    }

    func bumpGeneration(): Unit {
        generationValue++
    }

    func changeStyle(value: Style): Unit {
        styleValue = value
        revisionValue++
    }
}

class FullFrameTranscriptSource <: VirtualTranscriptSource {
    public func size(): Int64 { 1 }
    public func itemId(_: Int64): String { "full-frame" }
    public func revision(_: Int64): Int64 { 0 }
    public func itemFooter(_: Int64): String { "〈Wall: 12ms | Exit: 0〉" }
    public func itemCardTheme(_: Int64): ?TranscriptCardTheme {
        Some(TranscriptCardTheme(
            fullFrame: true,
            bodyIndent: 0,
            borderStyle: Style(fg: Color.Indexed(8)),
            mutedStyle: Style(fg: Color.Indexed(8))
        ))
    }
    public func document(_: Int64, _: Int64, _: String): Document {
        Document([
            DocumentLine(
                DocumentLineKind.Paragraph,
                [
                    RichSpan("$", style: Style(fg: Color.Blue)),
                    RichSpan(" printf ok", style: Style(fg: Color.Green))
                ]
            ),
            DocumentLine(
                DocumentLineKind.HorizontalRule,
                [RichSpan("Output", style: Style(fg: Color.Yellow))]
            ),
            DocumentLine(DocumentLineKind.Paragraph, "ok", style: Style(fg: Color.Cyan))
        ])
    }
}

class RunningNoOutputTranscriptSource <: VirtualTranscriptSource {
    public func size(): Int64 { 1 }
    public func itemId(_: Int64): String { "running-no-output" }
    public func revision(_: Int64): Int64 { 0 }
    public func itemFooter(_: Int64): String { "〈Running · 12 ms〉" }
    public func itemCardTheme(_: Int64): ?TranscriptCardTheme {
        Some(TranscriptCardTheme(
            fullFrame: true,
            bodyIndent: 0,
            borderStyle: Style(fg: Color.Indexed(8)),
            mutedStyle: Style(fg: Color.Indexed(8)),
            contentPadding: Spacing.symmetric(horizontal: 1, vertical: 0)
        ))
    }
    public func document(_: Int64, _: Int64, _: String): Document {
        Document.plain("$ mkdir -p /tmp/cube")
    }
}

class StreamingFullFrameTranscriptSource <: VirtualTranscriptSource {
    var revisionValue: Int64 = 0
    var visible: Bool = false

    public func size(): Int64 { 1 }
    public func itemId(_: Int64): String { "streaming-full-frame" }
    public func revision(_: Int64): Int64 { revisionValue }
    public func itemFooter(_: Int64): String { "〈Running · 0.8 s〉" }
    public func itemCardTheme(_: Int64): ?TranscriptCardTheme {
        Some(TranscriptCardTheme(
            fullFrame: true,
            bodyIndent: 0,
            borderStyle: Style(fg: Color.Indexed(8)),
            mutedStyle: Style(fg: Color.Indexed(8)),
            contentPadding: Spacing.symmetric(horizontal: 1, vertical: 0)
        ))
    }
    public func document(_: Int64, _: Int64, _: String): Document {
        if (!visible) {
            return Document.plain("$ cmake --build build -j16")
        }
        Document([
            DocumentLine(DocumentLineKind.Paragraph, "$ cmake --build build -j16"),
            DocumentLine(DocumentLineKind.HorizontalRule, "Output"),
            DocumentLine(DocumentLineKind.Paragraph, "compiling...")
        ])
    }
    func showOutput(): Unit {
        visible = true
        revisionValue++
    }
}

class BackgroundTranscriptSource <: VirtualTranscriptSource {
    var lastWidth: Int64 = 0

    public func size(): Int64 { 1 }
    public func itemId(_: Int64): String { "background" }
    public func itemUsesCardChrome(_: Int64): Bool { false }
    public func revision(_: Int64): Int64 { 0 }
    public func itemCardTheme(_: Int64): ?TranscriptCardTheme {
        Some(TranscriptCardTheme(
            fillBackground: true,
            contentPadding: Spacing.symmetric(horizontal: 2, vertical: 1),
            borderBackground: Style(bg: Color.Blue)
        ))
    }
    public func document(_: Int64, width: Int64, _: String): Document {
        lastWidth = width
        Document.plain("这些失败原因中哪些是标准库实现导致的")
    }
}

class CompactChromeTranscriptSource <: VirtualTranscriptSource {
    public func size(): Int64 { 1 }
    public func itemId(_: Int64): String { "compact-card" }
    public func itemTitle(_: Int64): String { "✓ GitHub · completed" }
    public func itemUsesCompactCardChrome(_: Int64): Bool { true }
    public func revision(_: Int64): Int64 { 0 }
    public func document(_: Int64, _: Int64, _: String): Document { Document([]) }
}

class Utf8BoundarySource <: VirtualTranscriptSource {
    let samples: Array<String>

    init(samples: Array<String>) {
        this.samples = samples
    }

    public func size(): Int64 { samples.size }
    public func itemId(index: Int64): String { "item-utf8-${index}" }
    public func revision(index: Int64): Int64 { 0 }
    public func document(index: Int64, width: Int64, themeKey: String): Document {
        Document.plain(samples[index])
    }
}

class TitleWidthTranscriptSource <: VirtualTranscriptSource {
    var lastTitleWidth: Int64 = 0

    public func size(): Int64 { 1 }
    public func itemId(index: Int64): String { "title-width-${index}" }
    public func revision(index: Int64): Int64 {
        let _ = index
        0
    }
    public func itemUsesCardChrome(index: Int64): Bool {
        let _ = index
        true
    }
    public func itemTitleForWidth(index: Int64, width: Int64): String {
        let _ = index
        lastTitleWidth = width
        let full = "Run find long-target · running"
        if (width < displayWidth(full)) { "Run … · running" } else { full }
    }
    public func document(index: Int64, width: Int64, themeKey: String): Document {
        let _ = index
        let _ = width
        let _ = themeKey
        Document.plain("body")
    }
}
