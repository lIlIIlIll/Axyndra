package core

import std.collection.*

// An immutable snapshot for sources whose plain-text body only grows within
// one append epoch.  The source still owns revision/generation changes; the
// view owns grapheme-aware wrapping and may retain already-stable visual rows.
public struct VirtualTranscriptAppendOnlyText {
    public let text: String
    public let style: Style
    public let wrapWidth: Int64
    public let appendEpoch: Int64

    public init(
        text: String,
        style!: Style,
        wrapWidth!: Int64,
        appendEpoch!: Int64
    ) {
        this.text = text
        this.style = style
        this.wrapWidth = wrapWidth
        this.appendEpoch = appendEpoch
    }
}

// A product supplies already-themed, single-card documents. The core owns
// viewport selection, measurement and cache invalidation only.
public interface VirtualTranscriptSource {
    func size(): Int64
    // Hosts that replace a whole snapshot while retaining item ids/revisions
    // must bump this generation so cached rows cannot cross source lifetimes.
    func generation(): Int64 { 0 }
    func itemId(index: Int64): String
    func itemTitle(_: Int64): String { "" }
    // Hosts may keep ordinary conversation rows as plain transcript text
    // while giving structured events the left event rail.  The default keeps
    // the historical card behaviour for existing cjtui clients.
    func itemUsesCardChrome(_: Int64): Bool { true }
    // The title is measured/rendered with the live terminal width so a host
    // can preserve the useful tail of a path or command before truncation.
    func itemTitleForWidth(index: Int64, width: Int64): String {
        let _ = width
        itemTitle(index)
    }
    func itemFooter(_: Int64): String { "" }
    // A structured event with no visible body or footer may use only the
    // title rail. This avoids spending a second terminal row on an empty
    // `╰─` while preserving the normal two-ended rail for meaningful
    // summaries and expanded content.
    func itemUsesCompactCardChrome(_: Int64): Bool { false }
    func revision(index: Int64): Int64
    // Plain append-only bodies can bypass Document/DocumentView completely.
    // Existing sources keep the historical document path through this
    // default.  appendEpoch must change whenever text is replaced rather than
    // appended.
    func itemAppendOnlyText(
        _: Int64,
        _: Int64,
        _: String
    ): ?VirtualTranscriptAppendOnlyText { None }
    func document(index: Int64, width: Int64, themeKey: String): Document
    // Per-entry border theme; falls back to the view-wide card theme when
    // None, so hosts can color borders by card kind.
    func itemCardTheme(_: Int64): ?TranscriptCardTheme { None }
}

public class VirtualTranscriptState {
    public var scrollTop: Int64
    public var followBottom: Bool
    public var anchorId: String
    public var anchorRow: Int64

    public init(
        scrollTop!: Int64 = 0,
        followBottom!: Bool = true,
        anchorId!: String = "",
        anchorRow!: Int64 = 0
    ) {
        this.scrollTop = max(0, scrollTop)
        this.followBottom = followBottom
        this.anchorId = anchorId
        this.anchorRow = max(0, anchorRow)
    }

    public func scrollBy(delta: Int64, totalRows: Int64, viewportRows: Int64): Unit {
        let maximum = max(0, totalRows - max(1, viewportRows))
        scrollTop = clamp(scrollTop + delta, 0, maximum)
        followBottom = scrollTop >= maximum
    }

    public func home(): Unit {
        scrollTop = 0
        followBottom = false
        anchorId = ""
        anchorRow = 0
    }

    public func end(totalRows: Int64, viewportRows: Int64): Unit {
        scrollTop = max(0, totalRows - max(1, viewportRows))
        followBottom = true
    }
}

class VirtualTranscriptCacheEntry {
    var id: String = ""
    var revision: Int64 = -1
    var sourceGeneration: Int64 = -1
    var width: Int64 = -1
    var themeKey: String = ""
    var document: Document = Document([])
    var rows: Array<StyledLine> = []
    var measured: Bool = false
    // A cached layout is exact only for the view-local measurement
    // generation that produced it. Older heights remain useful estimates;
    // width/theme/Unicode changes never walk all retained entries.
    var measuredGeneration: Int64 = -1
    var height: Int64 = 1
    var chrome: Bool = false
    var compactChrome: Bool = false
    var fullFrame: Bool = false
    var fillBackground: Bool = false
    var contentPadding: Spacing = Spacing.zero()
    var footerRow: Bool = false
    var appendOnlyText: Bool = false
    var appendEpoch: Int64 = -1
    var appendTextSize: Int64 = 0
    var appendTailStart: Int64 = 0
    var appendStableRows: Int64 = 0
    var appendStyle: Style = Style.default()
    var appendWrapWidth: Int64 = -1
}

class TranscriptHeightIndex {
    private var countValue: Int64 = 0
    private var totalValue: Int64 = 0
    private let tree = ArrayList<Int64>()
    private let values = ArrayList<Int64>()

    init() { reset(0) }

    func reset(count: Int64): Unit {
        countValue = max(0, count)
        totalValue = countValue
        tree.clear()
        values.clear()
        tree.add(0)
        var index: Int64 = 1
        while (index <= countValue) {
            values.add(1)
            tree.add(lowBit(index))
            index++
        }
    }

    // Append one estimated height without rebuilding historical metadata.
    // Returns the number of Fenwick nodes read while constructing the new
    // node, for stable architecture-proof attribution.
    func append(height!: Int64 = 1): Int64 {
        let normalized = max(1, height)
        let fenwickIndex = countValue + 1
        let rangeStart = fenwickIndex - lowBit(fenwickIndex)
        var previousRangeSum: Int64 = 0
        var nodesTouched: Int64 = 0
        var cursor = countValue
        while (cursor > 0) {
            previousRangeSum += tree[cursor]
            nodesTouched++
            cursor -= lowBit(cursor)
        }
        cursor = rangeStart
        while (cursor > 0) {
            previousRangeSum -= tree[cursor]
            nodesTouched++
            cursor -= lowBit(cursor)
        }
        values.add(normalized)
        tree.add(previousRangeSum + normalized)
        countValue++
        totalValue += normalized
        nodesTouched + 1
    }

    // Shrink is deliberately a rebuild path. Session replacement/shrink is
    // not the append hot path, and retaining the surviving exact heights is
    // more important than complicating the index with a second structure.
    func truncate(count: Int64): Int64 {
        let retained = clamp(count, 0, countValue)
        while (values.size > retained) { values.remove(at: values.size - 1) }
        countValue = retained
        totalValue = 0
        tree.clear()
        tree.add(0)
        for (value in values) {
            tree.add(value)
            totalValue += value
        }
        var index: Int64 = 1
        while (index <= countValue) {
            let parent = index + lowBit(index)
            if (parent <= countValue) { tree[parent] += tree[index] }
            index++
        }
        retained
    }

    func count(): Int64 { countValue }
    func nodeCount(): Int64 { max(0, tree.size - 1) }

    func value(index: Int64): Int64 {
        if (index < 0 || index >= countValue) { 0 } else { values[index] }
    }

    func update(index: Int64, height: Int64): Int64 {
        if (index < 0 || index >= countValue) { return 0 }
        let normalized = max(1, height)
        if (values[index] == normalized) { return 0 }
        let difference = normalized - values[index]
        values[index] = normalized
        totalValue += difference
        var node = index + 1
        var nodesTouched: Int64 = 0
        while (node <= countValue) {
            tree[node] += difference
            nodesTouched++
            node += lowBit(node)
        }
        nodesTouched
    }

    func total(): Int64 { totalValue }

    func prefix(exclusive: Int64): Int64 {
        var node = clamp(exclusive, 0, countValue)
        var result: Int64 = 0
        while (node > 0) {
            result += tree[node]
            node -= lowBit(node)
        }
        result
    }

    func itemAt(row: Int64): Int64 {
        if (countValue == 0) { return -1 }
        var remaining = clamp(row, 0, max(0, total() - 1))
        var index: Int64 = 0
        var bit: Int64 = 1
        while (bit * 2 <= countValue) { bit *= 2 }
        while (bit > 0) {
            let candidate = index + bit
            if (candidate <= countValue && tree[candidate] <= remaining) {
                index = candidate
                remaining -= tree[candidate]
            }
            bit /= 2
        }
        min(countValue - 1, index)
    }

    private func lowBit(value: Int64): Int64 { value & (0 - value) }
}

public class VisibleRange {
    public let id: String
    public let top: Int64
    public let bottom: Int64

    public init(id: String, top: Int64, bottom: Int64) {
        this.id = id
        this.top = top
        this.bottom = bottom
    }
}

// A narrow, read-only diagnostics contract for profiling hosts. Keeping the
// counters in one snapshot avoids growing the view API for every new probe.
public class VirtualTranscriptMetrics {
    public let materialized: Int64
    public let cacheEntries: Int64
    public let measuredEntries: Int64
    public let cachedRows: Int64
    public let appendOnlyFullLayouts: Int64
    public let appendOnlyIncrementalLayouts: Int64
    public let appendOnlyRewrappedBytes: Int64
    public let syncCountCalls: Int64
    public let metadataTouches: Int64
    public let heightIndexResetEntries: Int64
    public let heightIndexUpdateCalls: Int64
    public let heightIndexNodesTouched: Int64
    public let heightIndexGrowOperations: Int64
    public let heightMetadataEntries: Int64
    public let heightIndexNodes: Int64
    public let cacheLookups: Int64
    public let cacheHits: Int64
    public let cacheMisses: Int64
    public let layoutCalls: Int64
    public let documentRequests: Int64
    public let documentsMaterialized: Int64
    public let wrapInputBytes: Int64
    public let measurementInvalidations: Int64
    public let measurementGenerationBumps: Int64
    public let staleEntriesEncountered: Int64
    public let entriesRemeasured: Int64
    public let estimateCorrections: Int64
    public let anchorCorrections: Int64
    // Paint attribution is cumulative and instrumentation-only. "Visited"
    // counts work entering the viewport paint loop; "painted" counts work
    // that emitted at least one visible row. Cell-attempt counters are deltas
    // from Buffer's existing Step-0 counter, never an independent cell probe.
    public let visibleItems: Int64
    public let itemsVisited: Int64
    public let itemsPainted: Int64
    public let rowsVisited: Int64
    public let rowsPainted: Int64
    public let changedItems: Int64
    public let itemPaintCellAttempts: Int64
    public let rowPaintCellAttempts: Int64
    public let itemBackgroundCellAttempts: Int64
    public let contentCellAttempts: Int64
    public let layoutRowsRequested: Int64
    public let cachedRowsUsed: Int64
    public let selectiveItemInvalidations: Int64
    public let selectiveOffscreenInvalidations: Int64
    public let fallbackFullViewportPaints: Int64

    public init(
        materialized: Int64,
        cacheEntries: Int64,
        measuredEntries: Int64,
        cachedRows: Int64,
        appendOnlyFullLayouts!: Int64 = 0,
        appendOnlyIncrementalLayouts!: Int64 = 0,
        appendOnlyRewrappedBytes!: Int64 = 0,
        syncCountCalls!: Int64 = 0,
        metadataTouches!: Int64 = 0,
        heightIndexResetEntries!: Int64 = 0,
        heightIndexUpdateCalls!: Int64 = 0,
        heightIndexNodesTouched!: Int64 = 0,
        heightIndexGrowOperations!: Int64 = 0,
        heightMetadataEntries!: Int64 = 0,
        heightIndexNodes!: Int64 = 0,
        cacheLookups!: Int64 = 0,
        cacheHits!: Int64 = 0,
        cacheMisses!: Int64 = 0,
        layoutCalls!: Int64 = 0,
        documentRequests!: Int64 = 0,
        documentsMaterialized!: Int64 = 0,
        wrapInputBytes!: Int64 = 0,
        measurementInvalidations!: Int64 = 0,
        measurementGenerationBumps!: Int64 = 0,
        staleEntriesEncountered!: Int64 = 0,
        entriesRemeasured!: Int64 = 0,
        estimateCorrections!: Int64 = 0,
        anchorCorrections!: Int64 = 0,
        visibleItems!: Int64 = 0,
        itemsVisited!: Int64 = 0,
        itemsPainted!: Int64 = 0,
        rowsVisited!: Int64 = 0,
        rowsPainted!: Int64 = 0,
        changedItems!: Int64 = 0,
        itemPaintCellAttempts!: Int64 = 0,
        rowPaintCellAttempts!: Int64 = 0,
        itemBackgroundCellAttempts!: Int64 = 0,
        contentCellAttempts!: Int64 = 0,
        layoutRowsRequested!: Int64 = 0,
        cachedRowsUsed!: Int64 = 0,
        selectiveItemInvalidations!: Int64 = 0,
        selectiveOffscreenInvalidations!: Int64 = 0,
        fallbackFullViewportPaints!: Int64 = 0
    ) {
        this.materialized = materialized
        this.cacheEntries = cacheEntries
        this.measuredEntries = measuredEntries
        this.cachedRows = cachedRows
        this.appendOnlyFullLayouts = appendOnlyFullLayouts
        this.appendOnlyIncrementalLayouts = appendOnlyIncrementalLayouts
        this.appendOnlyRewrappedBytes = appendOnlyRewrappedBytes
        this.syncCountCalls = syncCountCalls
        this.metadataTouches = metadataTouches
        this.heightIndexResetEntries = heightIndexResetEntries
        this.heightIndexUpdateCalls = heightIndexUpdateCalls
        this.heightIndexNodesTouched = heightIndexNodesTouched
        this.heightIndexGrowOperations = heightIndexGrowOperations
        this.heightMetadataEntries = heightMetadataEntries
        this.heightIndexNodes = heightIndexNodes
        this.cacheLookups = cacheLookups
        this.cacheHits = cacheHits
        this.cacheMisses = cacheMisses
        this.layoutCalls = layoutCalls
        this.documentRequests = documentRequests
        this.documentsMaterialized = documentsMaterialized
        this.wrapInputBytes = wrapInputBytes
        this.measurementInvalidations = measurementInvalidations
        this.measurementGenerationBumps = measurementGenerationBumps
        this.staleEntriesEncountered = staleEntriesEncountered
        this.entriesRemeasured = entriesRemeasured
        this.estimateCorrections = estimateCorrections
        this.anchorCorrections = anchorCorrections
        this.visibleItems = visibleItems
        this.itemsVisited = itemsVisited
        this.itemsPainted = itemsPainted
        this.rowsVisited = rowsVisited
        this.rowsPainted = rowsPainted
        this.changedItems = changedItems
        this.itemPaintCellAttempts = itemPaintCellAttempts
        this.rowPaintCellAttempts = rowPaintCellAttempts
        this.itemBackgroundCellAttempts = itemBackgroundCellAttempts
        this.contentCellAttempts = contentCellAttempts
        this.layoutRowsRequested = layoutRowsRequested
        this.cachedRowsUsed = cachedRowsUsed
        this.selectiveItemInvalidations = selectiveItemInvalidations
        this.selectiveOffscreenInvalidations = selectiveOffscreenInvalidations
        this.fallbackFullViewportPaints = fallbackFullViewportPaints
    }
}

public class VirtualTranscriptView <: Widget {
    private let source: VirtualTranscriptSource
    public let state: VirtualTranscriptState
    private let entries = ArrayList<VirtualTranscriptCacheEntry>()
    private let heights = TranscriptHeightIndex()
    private var width: Int64 = -1
    private var viewportRows: Int64 = 1
    private var themeKey: String
    private var backgroundCursor: Int64 = -1
    private let overscanViewports: Int64
    private let backgroundBatch: Int64
    private var materializedCountValue: Int64 = 0
    private var appendOnlyFullLayoutsValue: Int64 = 0
    private var appendOnlyIncrementalLayoutsValue: Int64 = 0
    private var appendOnlyRewrappedBytesValue: Int64 = 0
    private let instrumentationEnabled: Bool
    private var syncCountCallsValue: Int64 = 0
    private var metadataTouchesValue: Int64 = 0
    private var heightIndexResetEntriesValue: Int64 = 0
    private var heightIndexUpdateCallsValue: Int64 = 0
    private var heightIndexNodesTouchedValue: Int64 = 0
    private var heightIndexGrowOperationsValue: Int64 = 0
    private var cacheLookupsValue: Int64 = 0
    private var cacheHitsValue: Int64 = 0
    private var cacheMissesValue: Int64 = 0
    private var layoutCallsValue: Int64 = 0
    private var documentRequestsValue: Int64 = 0
    private var documentsMaterializedValue: Int64 = 0
    private var wrapInputBytesValue: Int64 = 0
    private var measurementInvalidationsValue: Int64 = 0
    private var measurementGeneration: Int64 = 0
    private var measurementGenerationBumpsValue: Int64 = 0
    private var staleEntriesEncounteredValue: Int64 = 0
    private var entriesRemeasuredValue: Int64 = 0
    private var estimateCorrectionsValue: Int64 = 0
    private var anchorCorrectionsValue: Int64 = 0
    private var visibleItemsValue: Int64 = 0
    private var itemsVisitedValue: Int64 = 0
    private var itemsPaintedValue: Int64 = 0
    private var rowsVisitedValue: Int64 = 0
    private var rowsPaintedValue: Int64 = 0
    private var changedItemsValue: Int64 = 0
    private var itemPaintCellAttemptsValue: Int64 = 0
    private var rowPaintCellAttemptsValue: Int64 = 0
    private var itemBackgroundCellAttemptsValue: Int64 = 0
    private var contentCellAttemptsValue: Int64 = 0
    private var layoutRowsRequestedValue: Int64 = 0
    private var cachedRowsUsedValue: Int64 = 0
    private var selectiveItemInvalidationsValue: Int64 = 0
    private var selectiveOffscreenInvalidationsValue: Int64 = 0
    private var fallbackFullViewportPaintsValue: Int64 = 0
    private var lastRenderArea = Rect(0, 0, 0, 0)
    private var cardChrome: Bool = false
    private var unicode: Bool = true
    private var cardTheme: TranscriptCardTheme = TranscriptCardTheme()
    // Screen ranges of items rendered by the last render() call, in
    // transcript order: (itemId, topRow, bottomRow). Used by hosts for
    // hit-testing (e.g. clicking a collapsed tool card to expand it).
    public let lastVisibleRanges = ArrayList<VisibleRange>()
    private let lastVisibleIndices = ArrayList<Int64>()

    public init(
        source: VirtualTranscriptSource,
        state!: VirtualTranscriptState = VirtualTranscriptState(),
        themeKey!: String = "default",
        overscanViewports!: Int64 = 2,
        backgroundBatch!: Int64 = 0,
        instrumentationEnabled!: Bool = false
    ) {
        this.source = source
        this.state = state
        this.themeKey = themeKey
        this.overscanViewports = max(0, overscanViewports)
        this.backgroundBatch = max(0, backgroundBatch)
        this.instrumentationEnabled = instrumentationEnabled
        syncCount()
    }

    public func setThemeKey(value: String): Unit {
        if (themeKey == value) { return }
        themeKey = value
        invalidateAllMeasurements()
    }

    public func setCardChrome(enabled: Bool): Unit {
        if (cardChrome == enabled) { return }
        cardChrome = enabled
        invalidateAllMeasurements()
    }

    // Hosts can switch the event rail to the portable ASCII form when the
    // terminal capability probe says Unicode is unavailable.
    public func setUnicode(enabled: Bool): Unit {
        if (unicode == enabled) { return }
        unicode = enabled
        invalidateAllMeasurements()
    }

    public func setCardTheme(theme: TranscriptCardTheme): Unit {
        cardTheme = theme
    }

    public func invalidateItem(id: String): Bool {
        for (index in 0..entries.size) {
            if (entries[index].id == id) {
                entries[index].measured = false
                entries[index].measuredGeneration = -1
                entries[index].revision = -1
                entries[index].height = 1
                let nodes = heights.update(index, 1)
                if (instrumentationEnabled) { heightIndexNodesTouchedValue += nodes }
                return true
            }
        }
        false
    }

    public func totalRows(): Int64 {
        syncCount()
        heights.total()
    }

    public func materializedCount(): Int64 { materializedCountValue }

    public func metrics(): VirtualTranscriptMetrics {
        var count: Int64 = 0
        var rows: Int64 = 0
        for (entry in entries where entry.measured && entry.measuredGeneration == measurementGeneration) { count++ }
        for (entry in entries where entry.measured) { rows += entry.rows.size }
        VirtualTranscriptMetrics(
            materializedCountValue,
            entries.size,
            count,
            rows,
            appendOnlyFullLayouts: appendOnlyFullLayoutsValue,
            appendOnlyIncrementalLayouts: appendOnlyIncrementalLayoutsValue,
            appendOnlyRewrappedBytes: appendOnlyRewrappedBytesValue,
            syncCountCalls: syncCountCallsValue,
            metadataTouches: metadataTouchesValue,
            heightIndexResetEntries: heightIndexResetEntriesValue,
            heightIndexUpdateCalls: heightIndexUpdateCallsValue,
            heightIndexNodesTouched: heightIndexNodesTouchedValue,
            heightIndexGrowOperations: heightIndexGrowOperationsValue,
            heightMetadataEntries: heights.count(),
            heightIndexNodes: heights.nodeCount(),
            cacheLookups: cacheLookupsValue,
            cacheHits: cacheHitsValue,
            cacheMisses: cacheMissesValue,
            layoutCalls: layoutCallsValue,
            documentRequests: documentRequestsValue,
            documentsMaterialized: documentsMaterializedValue,
            wrapInputBytes: wrapInputBytesValue,
            measurementInvalidations: measurementInvalidationsValue,
            measurementGenerationBumps: measurementGenerationBumpsValue,
            staleEntriesEncountered: staleEntriesEncounteredValue,
            entriesRemeasured: entriesRemeasuredValue,
            estimateCorrections: estimateCorrectionsValue,
            anchorCorrections: anchorCorrectionsValue,
            visibleItems: visibleItemsValue,
            itemsVisited: itemsVisitedValue,
            itemsPainted: itemsPaintedValue,
            rowsVisited: rowsVisitedValue,
            rowsPainted: rowsPaintedValue,
            changedItems: changedItemsValue,
            itemPaintCellAttempts: itemPaintCellAttemptsValue,
            rowPaintCellAttempts: rowPaintCellAttemptsValue,
            itemBackgroundCellAttempts: itemBackgroundCellAttemptsValue,
            contentCellAttempts: contentCellAttemptsValue,
            layoutRowsRequested: layoutRowsRequestedValue,
            cachedRowsUsed: cachedRowsUsedValue,
            selectiveItemInvalidations: selectiveItemInvalidationsValue,
            selectiveOffscreenInvalidations: selectiveOffscreenInvalidationsValue,
            fallbackFullViewportPaints: fallbackFullViewportPaintsValue
        )
    }

    // O(1) diagnostic snapshot for frame-level attribution. Unlike metrics(),
    // this intentionally does not scan every retained entry to count measured
    // rows. Consumers should use only the instrumentation work counters and
    // cache entry count from this snapshot; measuredEntries/cachedRows are -1.
    public func instrumentationMetrics(): VirtualTranscriptMetrics {
        VirtualTranscriptMetrics(
            materializedCountValue,
            entries.size,
            -1,
            -1,
            appendOnlyFullLayouts: appendOnlyFullLayoutsValue,
            appendOnlyIncrementalLayouts: appendOnlyIncrementalLayoutsValue,
            appendOnlyRewrappedBytes: appendOnlyRewrappedBytesValue,
            syncCountCalls: syncCountCallsValue,
            metadataTouches: metadataTouchesValue,
            heightIndexResetEntries: heightIndexResetEntriesValue,
            heightIndexUpdateCalls: heightIndexUpdateCallsValue,
            heightIndexNodesTouched: heightIndexNodesTouchedValue,
            heightIndexGrowOperations: heightIndexGrowOperationsValue,
            heightMetadataEntries: heights.count(),
            heightIndexNodes: heights.nodeCount(),
            cacheLookups: cacheLookupsValue,
            cacheHits: cacheHitsValue,
            cacheMisses: cacheMissesValue,
            layoutCalls: layoutCallsValue,
            documentRequests: documentRequestsValue,
            documentsMaterialized: documentsMaterializedValue,
            wrapInputBytes: wrapInputBytesValue,
            measurementInvalidations: measurementInvalidationsValue,
            measurementGenerationBumps: measurementGenerationBumpsValue,
            staleEntriesEncountered: staleEntriesEncounteredValue,
            entriesRemeasured: entriesRemeasuredValue,
            estimateCorrections: estimateCorrectionsValue,
            anchorCorrections: anchorCorrectionsValue,
            visibleItems: visibleItemsValue,
            itemsVisited: itemsVisitedValue,
            itemsPainted: itemsPaintedValue,
            rowsVisited: rowsVisitedValue,
            rowsPainted: rowsPaintedValue,
            changedItems: changedItemsValue,
            itemPaintCellAttempts: itemPaintCellAttemptsValue,
            rowPaintCellAttempts: rowPaintCellAttemptsValue,
            itemBackgroundCellAttempts: itemBackgroundCellAttemptsValue,
            contentCellAttempts: contentCellAttemptsValue,
            layoutRowsRequested: layoutRowsRequestedValue,
            cachedRowsUsed: cachedRowsUsedValue,
            selectiveItemInvalidations: selectiveItemInvalidationsValue,
            selectiveOffscreenInvalidations: selectiveOffscreenInvalidationsValue,
            fallbackFullViewportPaints: fallbackFullViewportPaintsValue
        )
    }

    // Returns the smallest safe physical dirty rect for a revision change to
    // one existing source item. The caller guarantees item order/count did not
    // change. Offscreen changes need no paint. A height change conservatively
    // falls back to the whole viewport because following items may move.
    public func dirtyRectForItemRevision(id: String): ?Rect {
        if (lastRenderArea.width <= 0 || lastRenderArea.height <= 0) { return None }
        var visible: Int64 = 0
        for (range in lastVisibleRanges) {
            let index = if (visible < lastVisibleIndices.size) { lastVisibleIndices[visible] } else { -1 }
            visible++
            if (range.id != id || index < 0 || index >= entries.size) { continue }
            let oldHeight = entries[index].height
            let entry = materialize(index, lastRenderArea.width)
            if (entry.height != oldHeight) {
                if (instrumentationEnabled) { fallbackFullViewportPaintsValue++ }
                return Some(lastRenderArea)
            }
            if (instrumentationEnabled) { selectiveItemInvalidationsValue++ }
            return Some(Rect(
                lastRenderArea.x,
                range.top,
                lastRenderArea.width,
                max(0, range.bottom - range.top)
            ))
        }
        if (instrumentationEnabled) { selectiveOffscreenInvalidationsValue++ }
        None
    }

    public func handle(key: KeyEvent): Bool {
        let page = max(1, viewportRows)
        match (key.code) {
            case KeyCode.Up => prepareNavigation(); state.scrollBy(-1, heights.total(), page); true
            case KeyCode.Down => prepareNavigation(); state.scrollBy(1, heights.total(), page); true
            case KeyCode.PageUp => prepareNavigation(); state.scrollBy(-page, heights.total(), page); true
            case KeyCode.PageDown => prepareNavigation(); state.scrollBy(page, heights.total(), page); true
            case KeyCode.Home => state.home(); true
            case KeyCode.End => state.end(heights.total(), page); true
            case _ => false
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        lastRenderArea = area
        syncCount()
        viewportRows = max(1, area.height)
        var anchorIndex = heights.itemAt(state.scrollTop)
        // Capture the viewport identity and row against the old generation
        // before its absolute prefix becomes an estimate at the new width.
        if (!state.followBottom && (state.anchorId == "" || width != area.width)) {
            captureAnchor(anchorIndex)
        }
        configureWidth(area.width)
        if (entries.isEmpty()) {
            lastVisibleRanges.clear()
            lastVisibleIndices.clear()
            return
        }

        materializedCountValue = 0
        measureBackground()
        if (state.followBottom) {
            measureTailWindow(area.height)
            state.scrollTop = max(0, heights.total() - area.height)
            anchorIndex = heights.itemAt(state.scrollTop)
        } else {
            // Make the stable anchor exact first. materializeWindow can then
            // use a corrected local coordinate even when a large width change
            // made all offscreen prefix heights estimates.
            let _ = materialize(anchorIndex, area.width)
            restoreAnchor(anchorIndex)
        }
        materializeWindow(area.height)
        // Nearby stale entries before the anchor may have changed its prefix.
        // Reapply the same item+row anchor after those bounded corrections.
        restoreAnchor(anchorIndex)
        if (state.followBottom) {
            state.scrollTop = max(0, heights.total() - area.height)
        } else {
            state.scrollTop = clamp(
                state.scrollTop,
                0,
                max(0, heights.total() - area.height)
            )
        }

        var index = heights.itemAt(state.scrollTop)
        if (index < 0) { return }
        lastVisibleRanges.clear()
        lastVisibleIndices.clear()
        var itemTop = heights.prefix(index)
        var y = area.y
        var skip = max(0, state.scrollTop - itemTop)
        while (index < entries.size && y < area.bottom) {
            if (instrumentationEnabled) { itemsVisitedValue++ }
            let entry = materialize(index, area.width)
            let documentHeight = max(1, entry.height - 1)
            if (skip < documentHeight) {
                let available = min(
                    area.bottom - y,
                    documentHeight - skip
                )
                var row = skip
                var out: Int64 = 0
                var itemBackgroundAttempts: Int64 = 0
                let itemRect = Rect(area.x, y, area.width, available)
                if (instrumentationEnabled) { visibleItemsValue++ }
                if (buffer.intersectsWriteClip(itemRect)) {
                  let itemAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                  if (instrumentationEnabled) {
                    itemsPaintedValue++
                    rowsVisitedValue += available
                    cachedRowsUsedValue += available
                  }
                  let entryTheme = match (source.itemCardTheme(index)) {
                      case Some(value) => value
                      case None => cardTheme
                  }
                  if (entry.fullFrame) {
                    let totalRows = framedRowCount(entry)
                    let footer = source.itemFooter(index)
                    // Resolve the outer frame once for the whole card.  Body,
                    // footer, empty-output and separator rows must all reuse
                    // these absolute columns; content padding is strictly an
                    // interior concern.
                    let geometry = FullFrameGeometry(
                        area.x,
                        area.width,
                        entry.contentPadding
                    )
                    let backgroundAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                    buffer.fillRect(
                        Rect(area.x, y, area.width, available),
                        style: entryTheme.borderBackground
                    )
                    if (instrumentationEnabled) {
                        itemBackgroundAttempts = buffer.cellAttempts() - backgroundAttemptsBefore
                        itemBackgroundCellAttemptsValue += itemBackgroundAttempts
                    }
                    while (row < totalRows && out < available) {
                        let rowAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                        renderFullFrameRow(
                            buffer,
                            y + out,
                            row,
                            entry,
                            footer,
                            entryTheme,
                            unicode,
                            geometry
                        )
                        row++
                        out++
                        if (instrumentationEnabled) {
                            rowsPaintedValue++
                            rowPaintCellAttemptsValue += buffer.cellAttempts() - rowAttemptsBefore
                        }
                    }
                  } else if (entry.chrome) {
                    let totalRows = if (entry.compactChrome) { 1 } else { entry.rows.size + 2 }
                    let backgroundAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                    buffer.fillRect(
                        Rect(area.x, y, area.width, available),
                        style: entryTheme.borderBackground
                    )
                    if (instrumentationEnabled) {
                        itemBackgroundAttempts = buffer.cellAttempts() - backgroundAttemptsBefore
                        itemBackgroundCellAttemptsValue += itemBackgroundAttempts
                    }
                    let bodyRail = if (unicode) { "│ " } else { "|  " }
                    while (row < totalRows && out < available) {
                        let rowAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                        if (row == 0) {
                            // Left event-rail header: no right frame, no
                            // fill to the edge (OMP style).
                            // The rail itself consumes three cells (`╭─ ` or
                            // `+- `).  Reserve them before asking the host
                            // to fit the title; otherwise the final
                            // `running`, duration, or result suffix is
                            // clipped by the outer truncate call.
                            let titleRail = if (unicode) { "╭─ " } else { "+- " }
                            let title = source.itemTitleForWidth(
                                index,
                                max(1, area.width - displayWidth(titleRail))
                            )
                            buffer.setString(
                                area.x,
                                y + out,
                                truncate(titleRail + title, area.width),
                                style: entryTheme.topTitleStyle
                            )
                        } else if (row == totalRows - 1) {
                            let footer = source.itemFooter(index)
                            buffer.setString(
                                area.x,
                                y + out,
                                truncate((if (unicode) { "╰─ " } else { "+- " }) + footer, area.width),
                                style: entryTheme.borderStyle
                            )
                        } else {
                            buffer.setString(area.x, y + out, bodyRail, style: entryTheme.borderStyle)
                            renderStyledLine(buffer, area.x + (if (unicode) { 2 } else { 3 }), y + out, entry.rows[row - 1], area.width - (if (unicode) { 2 } else { 3 }))
                        }
                        row++
                        out++
                        if (instrumentationEnabled) {
                            rowsPaintedValue++
                            rowPaintCellAttemptsValue += buffer.cellAttempts() - rowAttemptsBefore
                        }
                    }
                  } else if (entry.fillBackground) {
                    let backgroundAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                    buffer.fillRect(
                        Rect(area.x, y, area.width, available),
                        style: entryTheme.borderBackground
                    )
                    if (instrumentationEnabled) {
                        itemBackgroundAttempts = buffer.cellAttempts() - backgroundAttemptsBefore
                        itemBackgroundCellAttemptsValue += itemBackgroundAttempts
                    }
                    let contentStart = entry.contentPadding.top
                    let contentEnd = contentStart + entry.rows.size
                    while (row < max(1, entry.height - 1) && out < available) {
                        let rowAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                        if (row >= contentStart && row < contentEnd) {
                            renderStyledLine(
                                buffer,
                                area.x + entry.contentPadding.left,
                                y + out,
                                entry.rows[row - contentStart],
                                max(1, area.width - entry.contentPadding.left - entry.contentPadding.right)
                            )
                        }
                        row++
                        out++
                        if (instrumentationEnabled) {
                            rowsPaintedValue++
                            rowPaintCellAttemptsValue += buffer.cellAttempts() - rowAttemptsBefore
                        }
                    }
                  } else {
                    while (row < entry.rows.size && out < available) {
                        let rowAttemptsBefore = if (instrumentationEnabled) { buffer.cellAttempts() } else { 0 }
                        renderStyledLine(buffer, area.x, y + out, entry.rows[row], area.width)
                        row++
                        out++
                        if (instrumentationEnabled) {
                            rowsPaintedValue++
                            rowPaintCellAttemptsValue += buffer.cellAttempts() - rowAttemptsBefore
                        }
                    }
                  }
                  if (instrumentationEnabled) {
                    let itemAttempts = buffer.cellAttempts() - itemAttemptsBefore
                    itemPaintCellAttemptsValue += itemAttempts
                    contentCellAttemptsValue += itemAttempts - itemBackgroundAttempts
                  }
                }
                lastVisibleRanges.add(VisibleRange(
                    entry.id,
                    y,
                    y + available
                ))
                lastVisibleIndices.add(index)
                y += available
            }
            if (y < area.bottom && skip <= documentHeight) { y++ }
            skip = 0
            index++
        }
    }

    private func syncCount(): Unit {
        if (instrumentationEnabled) { syncCountCallsValue++ }
        let count = max(0, source.size())
        if (count == entries.size) { return }
        let previousCount = entries.size
        while (entries.size < count) {
            entries.add(VirtualTranscriptCacheEntry())
            let nodes = heights.append()
            if (instrumentationEnabled) {
                metadataTouchesValue++
                heightIndexNodesTouchedValue += nodes
                heightIndexGrowOperationsValue++
            }
        }
        while (entries.size > count) {
            entries.remove(at: entries.size - 1)
        }
        if (count < previousCount) {
            let rebuilt = heights.truncate(count)
            if (instrumentationEnabled) {
                metadataTouchesValue += rebuilt
                heightIndexResetEntriesValue += rebuilt
                heightIndexNodesTouchedValue += rebuilt
            }
        }
        backgroundCursor = count - 1
    }

    private func configureWidth(nextWidth: Int64): Unit {
        if (width == nextWidth) { return }
        width = nextWidth
        invalidateAllMeasurements()
    }

    private func invalidateAllMeasurements(): Unit {
        if (instrumentationEnabled) {
            measurementInvalidationsValue++
            measurementGenerationBumpsValue++
        }
        measurementGeneration++
        backgroundCursor = entries.size - 1
    }

    private func captureAnchor(index: Int64): Unit {
        if (index < 0 || index >= entries.size) { return }
        state.anchorId = source.itemId(index)
        state.anchorRow = max(0, state.scrollTop - heights.prefix(index))
    }

    private func prepareNavigation(): Unit {
        state.anchorId = ""
        state.anchorRow = 0
    }

    private func restoreAnchor(fallbackIndex: Int64): Unit {
        if (state.followBottom || state.anchorId == "") { return }
        var index = fallbackIndex
        if (index < 0 || index >= entries.size ||
            source.itemId(index) != state.anchorId) {
            index = findItem(state.anchorId)
        }
        if (index >= 0) {
            let corrected = heights.prefix(index) + min(
                state.anchorRow,
                max(0, heights.value(index) - 1)
            )
            if (instrumentationEnabled && corrected != state.scrollTop) {
                anchorCorrectionsValue++
            }
            state.scrollTop = corrected
        }
    }

    private func findItem(id: String): Int64 {
        for (index in 0..entries.size) {
            if (source.itemId(index) == id) { return index }
        }
        -1
    }

    private func measureBackground(): Unit {
        var remaining = backgroundBatch
        while (remaining > 0 && backgroundCursor >= 0) {
            let _ = materialize(backgroundCursor, width)
            backgroundCursor--
            remaining--
        }
    }

    private func measureTailWindow(height: Int64): Unit {
        let target = max(1, height * (overscanViewports + 1))
        var measuredRows: Int64 = 0
        var index = entries.size - 1
        while (index >= 0 && measuredRows < target) {
            let entry = materialize(index, width)
            measuredRows += entry.height
            index--
        }
    }

    private func materializeWindow(height: Int64): Unit {
        let overscan = max(0, height * overscanViewports)
        let from = max(0, state.scrollTop - overscan)
        let to = min(heights.total(), state.scrollTop + height + overscan)
        var index = heights.itemAt(from)
        if (index < 0) { return }
        while (index < entries.size && heights.prefix(index) < to) {
            let _ = materialize(index, width)
            index++
        }
    }

    private func materialize(
        index: Int64,
        itemWidth: Int64
    ): VirtualTranscriptCacheEntry {
        let entry = entries[index]
        if (instrumentationEnabled) {
            cacheLookupsValue++
            metadataTouchesValue++
        }
        let id = source.itemId(index)
        let revision = source.revision(index)
        let sourceGeneration = source.generation()
        let currentMeasurement = entry.measured &&
            entry.measuredGeneration == measurementGeneration
        let staleMeasurement = entry.measured && !currentMeasurement
        let sameLayoutIdentity = currentMeasurement && entry.id == id &&
            entry.width == itemWidth && entry.themeKey == themeKey &&
            entry.sourceGeneration == sourceGeneration
        if (!currentMeasurement || entry.id != id ||
            entry.revision != revision || entry.width != itemWidth ||
            entry.themeKey != themeKey ||
            entry.sourceGeneration != sourceGeneration) {
            let estimatedHeight = entry.height
            if (instrumentationEnabled && entry.measured &&
                (entry.id != id || entry.revision != revision)) {
                changedItemsValue++
            }
            if (instrumentationEnabled) {
                cacheMissesValue++
                entriesRemeasuredValue++
                if (staleMeasurement) { staleEntriesEncounteredValue++ }
            }
            entry.id = id
            entry.revision = revision
            entry.sourceGeneration = sourceGeneration
            entry.width = itemWidth
            entry.themeKey = themeKey
            let usesChrome = cardChrome && source.itemUsesCardChrome(index)
            let entryTheme = match (source.itemCardTheme(index)) {
                case Some(value) => value
                case None => cardTheme
            }
            entry.chrome = usesChrome
            entry.compactChrome = usesChrome && source.itemUsesCompactCardChrome(index)
            entry.fullFrame = usesChrome && entryTheme.fullFrame
            entry.fillBackground = !usesChrome && entryTheme.fillBackground
            entry.contentPadding = entryTheme.contentPadding
            entry.footerRow = entry.fullFrame && source.itemFooter(index) != ""
            let chromeColumns = if (entry.fullFrame) {
                2
            } else if (usesChrome) {
                2
            } else {
                0
            }
            let contentWidth = max(
                1,
                itemWidth - chromeColumns - entry.contentPadding.left - entry.contentPadding.right
            )
            match (source.itemAppendOnlyText(index, contentWidth, themeKey)) {
                case Some(snapshot) =>
                    let appendWrapWidth = max(1, snapshot.wrapWidth)
                    let incremental = sameLayoutIdentity &&
                        entry.appendOnlyText &&
                        entry.appendEpoch == snapshot.appendEpoch &&
                        entry.appendStyle == snapshot.style &&
                        entry.appendWrapWidth == appendWrapWidth &&
                        snapshot.text.size >= entry.appendTextSize &&
                        entry.appendTailStart >= 0 &&
                        entry.appendTailStart <= entry.appendTextSize
                    let segment = if (incremental) {
                        snapshot.text[entry.appendTailStart..]
                    } else {
                        snapshot.text
                    }
                    if (instrumentationEnabled) {
                        layoutCallsValue++
                        wrapInputBytesValue += segment.size
                    }
                    let wrapped = wrapText(segment, appendWrapWidth, WrapMode.Character)
                    let nextRows = ArrayList<StyledLine>()
                    if (incremental) {
                        for (row in 0..min(entry.appendStableRows, entry.rows.size)) {
                            nextRows.add(entry.rows[row])
                        }
                    }
                    for (line in wrapped) {
                        nextRows.add(StyledLine([RichSpan(line, style: snapshot.style)]))
                    }
                    entry.document = Document([])
                    entry.rows = nextRows.toArray()
                    if (instrumentationEnabled) { layoutRowsRequestedValue += max(1, entry.rows.size) }
                    entry.appendOnlyText = true
                    entry.appendEpoch = snapshot.appendEpoch
                    entry.appendTextSize = snapshot.text.size
                    entry.appendStableRows = max(0, entry.rows.size - 1)
                    entry.appendStyle = snapshot.style
                    entry.appendWrapWidth = appendWrapWidth
                    entry.appendTailStart = if (snapshot.text.endsWith("\n")) {
                        snapshot.text.size
                    } else {
                        snapshot.text.size - wrapped[wrapped.size - 1].size
                    }
                    appendOnlyRewrappedBytesValue += segment.size
                    if (incremental) {
                        appendOnlyIncrementalLayoutsValue++
                    } else {
                        appendOnlyFullLayoutsValue++
                    }
                case None =>
                    entry.appendOnlyText = false
                    entry.appendEpoch = -1
                    entry.appendTextSize = 0
                    entry.appendTailStart = 0
                    entry.appendStableRows = 0
                    entry.appendStyle = Style.default()
                    entry.appendWrapWidth = -1
                    if (instrumentationEnabled) { documentRequestsValue++ }
                    entry.document = source.document(index, contentWidth, themeKey)
                    if (instrumentationEnabled) {
                        documentsMaterializedValue++
                        layoutCallsValue++
                        wrapInputBytesValue += documentInputBytes(entry.document)
                    }
                    entry.rows = DocumentView(entry.document).layoutRows(contentWidth)
                    if (instrumentationEnabled) { layoutRowsRequestedValue += max(1, entry.rows.size) }
            }
            if (entry.fullFrame) {
                entry.height = framedRowCount(entry) + 1
            } else if (usesChrome) {
                entry.height = if (entry.compactChrome) { 2 } else { max(1, entry.rows.size) + 3 }
            } else if (entry.fillBackground) {
                entry.height = entry.contentPadding.top + max(1, entry.rows.size) + entry.contentPadding.bottom + 1
            } else {
                entry.height = max(1, entry.rows.size) + 1
            }
            entry.measured = true
            entry.measuredGeneration = measurementGeneration
            let nodes = heights.update(index, entry.height)
            if (instrumentationEnabled) {
                heightIndexNodesTouchedValue += nodes
                heightIndexUpdateCallsValue++
                if (entry.height != estimatedHeight) { estimateCorrectionsValue++ }
            }
            materializedCountValue++
        } else {
            if (instrumentationEnabled) { cacheHitsValue++ }
        }
        entry
    }
}

// Counts the UTF-8 input handed to Document layout. This deliberately runs
// only when Step-0 instrumentation is enabled and does not inspect derived
// wrapped rows.
func documentInputBytes(document: Document): Int64 {
    var total: Int64 = 0
    for (line in document.lines) {
        for (span in line.spans) { total += span.text.size }
    }
    total
}

func framedRowCount(entry: VirtualTranscriptCacheEntry): Int64 {
    2 + entry.contentPadding.top + entry.rows.size + entry.contentPadding.bottom + if (entry.footerRow) { 1 } else { 0 }
}

class FullFrameGeometry {
    let leftBorderX: Int64
    let rightBorderX: Int64
    let contentX: Int64
    let contentWidth: Int64
    let cardWidth: Int64

    init(x: Int64, width: Int64, padding: Spacing) {
        cardWidth = max(0, width)
        leftBorderX = x
        rightBorderX = x + max(0, cardWidth - 1)
        contentX = x + 1 + padding.left
        contentWidth = max(
            0,
            cardWidth - 2 - padding.left - padding.right
        )
    }
}

func renderFullFrameRow(
    buffer: Buffer,
    y: Int64,
    row: Int64,
    entry: VirtualTranscriptCacheEntry,
    footer: String,
    theme: TranscriptCardTheme,
    unicode: Bool,
    geometry: FullFrameGeometry
): Unit {
    let x = geometry.leftBorderX
    let width = geometry.cardWidth
    if (width <= 0) { return }
    let horizontal = if (unicode) { "─" } else { "-" }
    let topLeft = if (unicode) { "╭" } else { "+" }
    let topRight = if (unicode) { "╮" } else { "+" }
    let bottomLeft = if (unicode) { "╰" } else { "+" }
    let bottomRight = if (unicode) { "╯" } else { "+" }
    let vertical = if (unicode) { "│" } else { "|" }
    let separatorLeft = if (unicode) { "├" } else { "+" }
    let separatorRight = if (unicode) { "┤" } else { "+" }
    let totalRows = framedRowCount(entry)
    if (row == 0) {
        renderFrameRule(buffer, x, y, width, topLeft, topRight, horizontal, theme.borderStyle)
        return
    }
    if (row == totalRows - 1) {
        renderFrameRule(buffer, x, y, width, bottomLeft, bottomRight, horizontal, theme.borderStyle)
        return
    }
    if (width == 1) {
        buffer.setString(geometry.leftBorderX, y, vertical, style: theme.borderStyle)
        return
    }
    let contentStart = 1 + entry.contentPadding.top
    let contentEnd = contentStart + entry.rows.size
    if (row >= contentStart && row < contentEnd) {
        let line = entry.rows[row - contentStart]
        if (line.horizontalRule) {
            renderFrameRule(buffer, x, y, width, separatorLeft, separatorRight, horizontal, theme.borderStyle)
            renderFrameRuleLabel(buffer, x, y, width, line.ruleLabel, theme.borderStyle)
            return
        } else {
            if (geometry.contentWidth > 0) {
                renderStyledLine(
                    buffer,
                    geometry.contentX,
                    y,
                    line,
                    geometry.contentWidth
                )
            }
        }
    } else if (entry.footerRow && row == totalRows - 2 && geometry.contentWidth > 0) {
        buffer.setString(
            geometry.contentX,
            y,
            truncate(footer, geometry.contentWidth),
            style: theme.mutedStyle
        )
    }
    // Draw the outer sides last so neither styled content, a footer update,
    // nor an empty-output row can erase or shift the frame columns.
    buffer.setString(geometry.leftBorderX, y, vertical, style: theme.borderStyle)
    buffer.setString(geometry.rightBorderX, y, vertical, style: theme.borderStyle)
}

func renderFrameRule(
    buffer: Buffer,
    x: Int64,
    y: Int64,
    width: Int64,
    left: String,
    right: String,
    horizontal: String,
    style: Style
): Unit {
    if (width <= 0) { return }
    if (width == 1) {
        buffer.setString(x, y, left, style: style)
        return
    }
    buffer.setString(x, y, left + repeat(horizontal, max(0, width - 2)) + right, style: style)
}

func renderFrameRuleLabel(
    buffer: Buffer,
    x: Int64,
    y: Int64,
    width: Int64,
    label: Array<RichSpan>,
    borderStyle: Style
): Unit {
    let textWidth = displayWidth(spansText(label))
    if (textWidth <= 0 || width < 7) { return }
    let available = max(1, width - 6)
    buffer.setString(x + 3, y, " ", style: borderStyle)
    let rendered = StyledLine(label)
    renderStyledLine(buffer, x + 4, y, rendered, available)
    let shown = min(textWidth, available)
    if (x + 4 + shown < x + width - 1) {
        buffer.setString(x + 4 + shown, y, " ", style: borderStyle)
    }
}
