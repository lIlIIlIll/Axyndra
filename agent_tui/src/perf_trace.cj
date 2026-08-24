package agent_tui

import core.*
import std.env.*
import std.io.*
import std.time.*

let TUI_PERF_PREFIX = "@@OMP_TUI_PERF@@"
let TUI_GOLDEN_PREFIX = "@@OMP_TUI_GOLDEN@@"
let TUI_STARTUP_ORIGIN = MonoTime.now()

public func tuiStartupStage(stage: String): Unit {
    if (!tuiPerformanceTraceRequested()) {
        return
    }
    let elapsed = max(0, (MonoTime.now() - TUI_STARTUP_ORIGIN).toNanoseconds())
    let line = TUI_PERF_PREFIX + "{\"kind\":\"startup_stage\",\"stage\":\"" + stage +
        "\",\"elapsed_ns\":" + elapsed.toString() + "}\n"
    let output = getStdErr()
    output.write(unsafe { line.rawData() })
    output.flush()
}

func tuiGoldenStage(stage: String, state: String): Unit {
    match (getVariable("AGENT_TUI_GOLDEN_TRACE")) {
        case Some(value) => if (value != "1" && value.toAsciiLower() != "true") {
            return
        }
        case None => return
    }
    let line = TUI_GOLDEN_PREFIX + "{\"stage\":\"" + stage + "\",\"state\":\"" + state + "\"}\n"
    let output = getStdErr()
    output.write(unsafe { line.rawData() })
    output.flush()
}

class TuiPerformanceTrace <: AppTraceSink {
    private let origin = MonoTime.now()
    private let output: OutputStream
    private var sequence: Int64 = 0
    private var eventName = "startup"
    private var queueLength: Int64 = 0
    private var inputNanos: Int64 = 0
    private var dispatchNanos: Int64 = 0
    private var stateNanos: Int64 = 0
    private var layoutNanos: Int64 = 0
    private var renderNanos: Int64 = 0
    private var renderStartedNanos: Int64 = 0
    private var screenPreparationNanos: Int64 = 0
    private var transcriptNanos: Int64 = 0
    private var activityNanos: Int64 = 0
    private var queueTodoNanos: Int64 = 0
    private var composerNanos: Int64 = 0
    private var composerHeaderNanos: Int64 = 0
    private var composerWidgetNanos: Int64 = 0
    private var composerPlaceholderNanos: Int64 = 0
    private var composerChromeNanos: Int64 = 0
    private var composerSubstageStartedNanos: Int64 = 0
    private var composerBackgroundAttempts: Int64 = 0
    private var composerHeaderAttempts: Int64 = 0
    private var composerContentAttempts: Int64 = 0
    private var composerChromeAttempts: Int64 = 0
    private var composerRowsVisited: Int64 = 0
    private var composerRowsPainted: Int64 = 0
    private var composerHeightBefore: Int64 = 0
    private var composerHeightAfter: Int64 = 0
    private var overlayNanos: Int64 = 0
    private var transcriptPaintCalls: Int64 = 0
    private var activityPaintCalls: Int64 = 0
    private var queueTodoPaintCalls: Int64 = 0
    private var composerPaintCalls: Int64 = 0
    private var overlayPaintCalls: Int64 = 0
    private var stageStartedNanos: Int64 = 0
    private var frameOutputBytes: Int64 = 0
    private var frameWriteCalls: Int64 = 0
    private var frameFlushCalls: Int64 = 0
    private let coreMetricsEnabled = tuiCoreMetricsRequested()
    private var transcriptMetricsInitialized = false
    private var previousSyncCountCalls: Int64 = 0
    private var previousMetadataTouches: Int64 = 0
    private var previousHeightIndexResetEntries: Int64 = 0
    private var previousHeightIndexUpdateCalls: Int64 = 0
    private var previousCacheLookups: Int64 = 0
    private var previousCacheHits: Int64 = 0
    private var previousCacheMisses: Int64 = 0
    private var previousLayoutCalls: Int64 = 0
    private var previousDocumentRequests: Int64 = 0
    private var previousDocumentsMaterialized: Int64 = 0
    private var previousWrapInputBytes: Int64 = 0
    private var previousMeasurementInvalidations: Int64 = 0
    private var previousVisibleItems: Int64 = 0
    private var previousItemsVisited: Int64 = 0
    private var previousItemsPainted: Int64 = 0
    private var previousRowsVisited: Int64 = 0
    private var previousRowsPainted: Int64 = 0
    private var previousChangedItems: Int64 = 0
    private var previousItemPaintCellAttempts: Int64 = 0
    private var previousRowPaintCellAttempts: Int64 = 0
    private var previousItemBackgroundCellAttempts: Int64 = 0
    private var previousContentCellAttempts: Int64 = 0
    private var previousLayoutRowsRequested: Int64 = 0
    private var previousCachedRowsUsed: Int64 = 0
    private var previousSelectiveItemInvalidations: Int64 = 0
    private var previousSelectiveOffscreenInvalidations: Int64 = 0
    private var previousFallbackFullViewportPaints: Int64 = 0
    private var frameSyncCountCalls: Int64 = 0
    private var frameMetadataTouches: Int64 = 0
    private var frameHeightIndexResetEntries: Int64 = 0
    private var frameHeightIndexUpdateCalls: Int64 = 0
    private var frameCacheLookups: Int64 = 0
    private var frameCacheHits: Int64 = 0
    private var frameCacheMisses: Int64 = 0
    private var frameLayoutCalls: Int64 = 0
    private var frameDocumentRequests: Int64 = 0
    private var frameDocumentsMaterialized: Int64 = 0
    private var frameWrapInputBytes: Int64 = 0
    private var frameMeasurementInvalidations: Int64 = 0
    private var frameVisibleItems: Int64 = 0
    private var frameItemsVisited: Int64 = 0
    private var frameItemsPainted: Int64 = 0
    private var frameRowsVisited: Int64 = 0
    private var frameRowsPainted: Int64 = 0
    private var frameChangedItems: Int64 = 0
    private var frameItemPaintCellAttempts: Int64 = 0
    private var frameRowPaintCellAttempts: Int64 = 0
    private var frameItemBackgroundCellAttempts: Int64 = 0
    private var frameContentCellAttempts: Int64 = 0
    private var frameLayoutRowsRequested: Int64 = 0
    private var frameCachedRowsUsed: Int64 = 0
    private var frameSelectiveItemInvalidations: Int64 = 0
    private var frameSelectiveOffscreenInvalidations: Int64 = 0
    private var frameFallbackFullViewportPaints: Int64 = 0
    private var frameEmitted = false
    private var frameSchedulingSnapshot = FrameSchedulingSnapshot()
    private var pendingExternalQueueNanos: Int64 = -1
    private var externalQueueNanos: Int64 = -1
    private var burstProofActive = false
    private var burstExpectedTokens: Int64 = 0
    private var burstIntervalMillis: Int64 = 0
    private var burstTokensApplied: Int64 = 0
    private var burstTokensAppliedTotal: Int64 = 0
    private var burstReadyMarkersProcessed: Int64 = 0
    private var burstHeightBefore: Int64 = -1
    private var burstHeightAfter: Int64 = -1
    private var burstBoundsStable = false
    private var burstVisibleMappingStable = false
    private var burstFollowBottom = false
    private var burstPreciseDirtyHit = false
    private var burstExternalAccepted: Int64 = 0
    private var burstExternalFull: Int64 = 0
    private var burstWakeSignals: Int64 = 0
    private var firstLayoutEmitted = false
    private var firstRenderEmitted = false
    private var firstFlushEmitted = false
    private let memoryTraceEnabled = tuiMemoryTraceRequested()
    private var lastMemorySampleNanos: Int64 = -1_000_000_000

    init(output!: OutputStream = getStdErr()) {
        this.output = output
    }

    public func externalDequeued(queueLatencyNanos: Int64): Unit {
        pendingExternalQueueNanos = max(0, queueLatencyNanos)
    }

    public func inputReceived(event: Event, eventQueueLength: Int64): Unit {
        sequence++
        eventName = performanceEventName(event)
        queueLength = max(0, eventQueueLength)
        inputNanos = nowNanos()
        dispatchNanos = 0
        stateNanos = 0
        layoutNanos = 0
        renderNanos = 0
        renderStartedNanos = 0
        frameEmitted = false
        externalQueueNanos = pendingExternalQueueNanos
        pendingExternalQueueNanos = -1
        burstTokensApplied = 0
    }

    func burstProofStarted(expectedTokens: Int64, intervalMillis: Int64): Unit {
        burstProofActive = true
        burstExpectedTokens = max(0, expectedTokens)
        burstIntervalMillis = max(0, intervalMillis)
        burstTokensApplied = 0
        burstTokensAppliedTotal = 0
        burstReadyMarkersProcessed = 0
        burstHeightBefore = -1
        burstHeightAfter = -1
        burstBoundsStable = false
        burstVisibleMappingStable = false
        burstFollowBottom = false
        burstPreciseDirtyHit = false
        burstExternalAccepted = 0
        burstExternalFull = 0
        burstWakeSignals = 0
    }

    func burstProofUpdate(
        tokensApplied: Int64,
        tokensAppliedTotal: Int64,
        readyMarkersProcessed: Int64,
        heightBefore: Int64,
        heightAfter: Int64,
        boundsStable: Bool,
        visibleMappingStable: Bool,
        followBottom: Bool,
        preciseDirtyHit: Bool,
        externalAccepted: Int64,
        externalFull: Int64,
        wakeSignals: Int64
    ): Unit {
        burstTokensApplied = max(0, tokensApplied)
        burstTokensAppliedTotal = max(0, tokensAppliedTotal)
        burstReadyMarkersProcessed = max(0, readyMarkersProcessed)
        burstHeightBefore = heightBefore
        burstHeightAfter = heightAfter
        burstBoundsStable = boundsStable
        burstVisibleMappingStable = visibleMappingStable
        burstFollowBottom = followBottom
        burstPreciseDirtyHit = preciseDirtyHit
        burstExternalAccepted = max(0, externalAccepted)
        burstExternalFull = max(0, externalFull)
        burstWakeSignals = max(0, wakeSignals)
    }

    public func eventDispatchCompleted(): Unit {
        dispatchNanos = nowNanos()
    }

    public func stateUpdateCompleted(): Unit {
        stateNanos = nowNanos()
    }

    public func frameScheduling(snapshot: FrameSchedulingSnapshot): Unit {
        frameSchedulingSnapshot = snapshot
    }

    public func renderStarted(): Unit {
        renderStartedNanos = nowNanos()
        screenPreparationNanos = 0
        transcriptNanos = 0
        activityNanos = 0
        queueTodoNanos = 0
        composerNanos = 0
        composerHeaderNanos = 0
        composerWidgetNanos = 0
        composerPlaceholderNanos = 0
        composerChromeNanos = 0
        composerSubstageStartedNanos = 0
        composerBackgroundAttempts = 0
        composerHeaderAttempts = 0
        composerContentAttempts = 0
        composerChromeAttempts = 0
        composerRowsVisited = 0
        composerRowsPainted = 0
        composerHeightBefore = 0
        composerHeightAfter = 0
        overlayNanos = 0
        transcriptPaintCalls = 0
        activityPaintCalls = 0
        queueTodoPaintCalls = 0
        composerPaintCalls = 0
        overlayPaintCalls = 0
        stageStartedNanos = 0
        frameOutputBytes = 0
        frameWriteCalls = 0
        frameFlushCalls = 0
        frameSyncCountCalls = 0
        frameMetadataTouches = 0
        frameHeightIndexResetEntries = 0
        frameHeightIndexUpdateCalls = 0
        frameCacheLookups = 0
        frameCacheHits = 0
        frameCacheMisses = 0
        frameLayoutCalls = 0
        frameDocumentRequests = 0
        frameDocumentsMaterialized = 0
        frameWrapInputBytes = 0
        frameMeasurementInvalidations = 0
        frameVisibleItems = 0
        frameItemsVisited = 0
        frameItemsPainted = 0
        frameRowsVisited = 0
        frameRowsPainted = 0
        frameChangedItems = 0
        frameItemPaintCellAttempts = 0
        frameRowPaintCellAttempts = 0
        frameItemBackgroundCellAttempts = 0
        frameContentCellAttempts = 0
        frameLayoutRowsRequested = 0
        frameCachedRowsUsed = 0
        frameSelectiveItemInvalidations = 0
        frameSelectiveOffscreenInvalidations = 0
        frameFallbackFullViewportPaints = 0
        frameEmitted = false
    }

    func layoutCompleted(): Unit {
        layoutNanos = nowNanos()
        if (!firstLayoutEmitted) {
            tuiStartupStage("first_layout_completed")
            firstLayoutEmitted = true
        }
    }

    func renderCompleted(): Unit {
        renderNanos = nowNanos()
        if (!firstRenderEmitted) {
            tuiStartupStage("first_render_completed")
            firstRenderEmitted = true
        }
        if (renderStartedNanos > 0 && renderNanos - renderStartedNanos > 100_000_000) {
            eventLoopStall("render", renderNanos - renderStartedNanos)
        }
    }

    func screenPreparationCompleted(): Unit {
        screenPreparationNanos = max(0, nowNanos() - renderStartedNanos)
    }

    func transcriptStarted(): Unit { stageStartedNanos = nowNanos() }
    func transcriptCompleted(): Unit { transcriptNanos += completeStage() }
    func activityStarted(): Unit { stageStartedNanos = nowNanos() }
    func activityCompleted(): Unit { activityNanos += completeStage() }
    func queueTodoStarted(): Unit { stageStartedNanos = nowNanos() }
    func queueTodoCompleted(): Unit { queueTodoNanos += completeStage() }
    func composerStarted(): Unit { stageStartedNanos = nowNanos() }
    func composerCompleted(): Unit { composerNanos += completeStage() }
    func composerMetricsEnabled(): Bool { coreMetricsEnabled }
    func composerHeaderStarted(): Unit {
        if (coreMetricsEnabled) { composerSubstageStartedNanos = nowNanos() }
    }
    func composerHeaderCompleted(): Unit {
        if (coreMetricsEnabled) { composerHeaderNanos += completeComposerSubstage() }
    }
    func composerWidgetStarted(): Unit {
        if (coreMetricsEnabled) { composerSubstageStartedNanos = nowNanos() }
    }
    func composerWidgetCompleted(): Unit {
        if (coreMetricsEnabled) { composerWidgetNanos += completeComposerSubstage() }
    }
    func composerPlaceholderStarted(): Unit {
        if (coreMetricsEnabled) { composerSubstageStartedNanos = nowNanos() }
    }
    func composerPlaceholderCompleted(): Unit {
        if (coreMetricsEnabled) { composerPlaceholderNanos += completeComposerSubstage() }
    }
    func composerChromeStarted(): Unit {
        if (coreMetricsEnabled) { composerSubstageStartedNanos = nowNanos() }
    }
    func composerChromeCompleted(): Unit {
        if (coreMetricsEnabled) { composerChromeNanos += completeComposerSubstage() }
    }
    func composerWork(
        backgroundAttempts: Int64,
        headerAttempts: Int64,
        contentAttempts: Int64,
        chromeAttempts: Int64,
        rowsVisited: Int64,
        rowsPainted: Int64,
        heightBefore: Int64,
        heightAfter: Int64
    ): Unit {
        if (!coreMetricsEnabled) { return }
        composerBackgroundAttempts += max(0, backgroundAttempts)
        composerHeaderAttempts += max(0, headerAttempts)
        composerContentAttempts = if (contentAttempts < 0) {
            -1
        } else if (composerContentAttempts < 0) {
            contentAttempts
        } else {
            composerContentAttempts + contentAttempts
        }
        composerChromeAttempts += max(0, chromeAttempts)
        composerRowsVisited += max(0, rowsVisited)
        composerRowsPainted += max(0, rowsPainted)
        composerHeightBefore = max(0, heightBefore)
        composerHeightAfter = max(0, heightAfter)
    }
    func overlayStarted(): Unit { stageStartedNanos = nowNanos() }
    func overlayCompleted(): Unit { overlayNanos += completeStage() }
    func transcriptPainted(): Unit { transcriptPaintCalls++ }
    func activityPainted(): Unit { activityPaintCalls++ }
    func queueTodoPainted(): Unit { queueTodoPaintCalls++ }
    func composerPainted(): Unit { composerPaintCalls++ }
    func overlayPainted(): Unit { overlayPaintCalls++ }

    func transcriptMetrics(metrics: VirtualTranscriptMetrics): Unit {
        if (!coreMetricsEnabled) { return }
        let reset = !transcriptMetricsInitialized ||
            metrics.syncCountCalls < previousSyncCountCalls ||
            metrics.metadataTouches < previousMetadataTouches ||
            metrics.documentRequests < previousDocumentRequests ||
            metrics.wrapInputBytes < previousWrapInputBytes
        frameSyncCountCalls = metricDelta(metrics.syncCountCalls, previousSyncCountCalls, reset)
        frameMetadataTouches = metricDelta(metrics.metadataTouches, previousMetadataTouches, reset)
        frameHeightIndexResetEntries = metricDelta(
            metrics.heightIndexResetEntries, previousHeightIndexResetEntries, reset
        )
        frameHeightIndexUpdateCalls = metricDelta(
            metrics.heightIndexUpdateCalls, previousHeightIndexUpdateCalls, reset
        )
        frameCacheLookups = metricDelta(metrics.cacheLookups, previousCacheLookups, reset)
        frameCacheHits = metricDelta(metrics.cacheHits, previousCacheHits, reset)
        frameCacheMisses = metricDelta(metrics.cacheMisses, previousCacheMisses, reset)
        frameLayoutCalls = metricDelta(metrics.layoutCalls, previousLayoutCalls, reset)
        frameDocumentRequests = metricDelta(metrics.documentRequests, previousDocumentRequests, reset)
        frameDocumentsMaterialized = metricDelta(
            metrics.documentsMaterialized, previousDocumentsMaterialized, reset
        )
        frameWrapInputBytes = metricDelta(metrics.wrapInputBytes, previousWrapInputBytes, reset)
        frameMeasurementInvalidations = metricDelta(
            metrics.measurementInvalidations, previousMeasurementInvalidations, reset
        )
        frameVisibleItems = metricDelta(metrics.visibleItems, previousVisibleItems, reset)
        frameItemsVisited = metricDelta(metrics.itemsVisited, previousItemsVisited, reset)
        frameItemsPainted = metricDelta(metrics.itemsPainted, previousItemsPainted, reset)
        frameRowsVisited = metricDelta(metrics.rowsVisited, previousRowsVisited, reset)
        frameRowsPainted = metricDelta(metrics.rowsPainted, previousRowsPainted, reset)
        frameChangedItems = metricDelta(metrics.changedItems, previousChangedItems, reset)
        frameItemPaintCellAttempts = metricDelta(
            metrics.itemPaintCellAttempts, previousItemPaintCellAttempts, reset
        )
        frameRowPaintCellAttempts = metricDelta(
            metrics.rowPaintCellAttempts, previousRowPaintCellAttempts, reset
        )
        frameItemBackgroundCellAttempts = metricDelta(
            metrics.itemBackgroundCellAttempts, previousItemBackgroundCellAttempts, reset
        )
        frameContentCellAttempts = metricDelta(
            metrics.contentCellAttempts, previousContentCellAttempts, reset
        )
        frameLayoutRowsRequested = metricDelta(
            metrics.layoutRowsRequested, previousLayoutRowsRequested, reset
        )
        frameCachedRowsUsed = metricDelta(metrics.cachedRowsUsed, previousCachedRowsUsed, reset)
        frameSelectiveItemInvalidations = metricDelta(
            metrics.selectiveItemInvalidations, previousSelectiveItemInvalidations, reset
        )
        frameSelectiveOffscreenInvalidations = metricDelta(
            metrics.selectiveOffscreenInvalidations, previousSelectiveOffscreenInvalidations, reset
        )
        frameFallbackFullViewportPaints = metricDelta(
            metrics.fallbackFullViewportPaints, previousFallbackFullViewportPaints, reset
        )
        previousSyncCountCalls = metrics.syncCountCalls
        previousMetadataTouches = metrics.metadataTouches
        previousHeightIndexResetEntries = metrics.heightIndexResetEntries
        previousHeightIndexUpdateCalls = metrics.heightIndexUpdateCalls
        previousCacheLookups = metrics.cacheLookups
        previousCacheHits = metrics.cacheHits
        previousCacheMisses = metrics.cacheMisses
        previousLayoutCalls = metrics.layoutCalls
        previousDocumentRequests = metrics.documentRequests
        previousDocumentsMaterialized = metrics.documentsMaterialized
        previousWrapInputBytes = metrics.wrapInputBytes
        previousMeasurementInvalidations = metrics.measurementInvalidations
        previousVisibleItems = metrics.visibleItems
        previousItemsVisited = metrics.itemsVisited
        previousItemsPainted = metrics.itemsPainted
        previousRowsVisited = metrics.rowsVisited
        previousRowsPainted = metrics.rowsPainted
        previousChangedItems = metrics.changedItems
        previousItemPaintCellAttempts = metrics.itemPaintCellAttempts
        previousRowPaintCellAttempts = metrics.rowPaintCellAttempts
        previousItemBackgroundCellAttempts = metrics.itemBackgroundCellAttempts
        previousContentCellAttempts = metrics.contentCellAttempts
        previousLayoutRowsRequested = metrics.layoutRowsRequested
        previousCachedRowsUsed = metrics.cachedRowsUsed
        previousSelectiveItemInvalidations = metrics.selectiveItemInvalidations
        previousSelectiveOffscreenInvalidations = metrics.selectiveOffscreenInvalidations
        previousFallbackFullViewportPaints = metrics.fallbackFullViewportPaints
        transcriptMetricsInitialized = true
    }

    // Sample application state at most once per second so the diagnostic
    // trace does not itself become an allocation source during a soak.
    func memorySampleDue(): Bool {
        if (!memoryTraceEnabled) {
            return false
        }
        let current = nowNanos()
        if (current - lastMemorySampleNanos < 1_000_000_000) {
            return false
        }
        lastMemorySampleNanos = current
        true
    }

    func memoryState(payload: String): Unit {
        if (memoryTraceEnabled) {
            emit("{\"kind\":\"memory_state\",\"elapsed_ns\":" + nowNanos().toString() + "," + payload + "}")
        }
    }

    func terminalFlushCompleted(outputBytes: Int64, writeCalls: Int64, flushCalls: Int64): Unit {
        if (frameEmitted || renderStartedNanos == 0) {
            return
        }
        frameOutputBytes += max(0, outputBytes)
        frameWriteCalls += max(0, writeCalls)
        frameFlushCalls += max(0, flushCalls)
        if (!firstFlushEmitted) {
            tuiStartupStage("first_terminal_flush_completed")
            firstFlushEmitted = true
        }
    }

    public func frameCompleted(metrics: RenderMetrics): Unit {
        if (frameEmitted || renderStartedNanos == 0 || renderNanos == 0) { return }
        let flushed = nowNanos()
        let productRenderNanos = max(0, renderNanos - renderStartedNanos)
        let attributedNanos = screenPreparationNanos + transcriptNanos + activityNanos +
            queueTodoNanos + composerNanos + overlayNanos
        let unavailable: Int64 = -1
        emit(
            "{\"kind\":\"operation\",\"seq\":" + sequence.toString() +
                ",\"event\":\"" + eventName + "\",\"input_received_ns\":" + inputNanos.toString() +
                ",\"event_dispatch_completed_ns\":" + dispatchNanos.toString() +
                ",\"state_update_completed_ns\":" + stateNanos.toString() +
                ",\"render_started_ns\":" + renderStartedNanos.toString() +
                ",\"layout_completed_ns\":" + layoutNanos.toString() +
                ",\"render_completed_ns\":" + renderNanos.toString() +
                ",\"terminal_flush_completed_ns\":" + flushed.toString() +
                ",\"external_queue_latency_ns\":" + externalQueueNanos.toString() +
                ",\"screen_preparation_ns\":" + screenPreparationNanos.toString() +
                ",\"transcript_render_ns\":" + transcriptNanos.toString() +
                ",\"activity_render_ns\":" + activityNanos.toString() +
                ",\"queue_todo_render_ns\":" + queueTodoNanos.toString() +
                ",\"composer_render_ns\":" + composerNanos.toString() +
                ",\"composer_header_ns\":" + metricValue(composerHeaderNanos, unavailable).toString() +
                ",\"composer_widget_ns\":" + metricValue(composerWidgetNanos, unavailable).toString() +
                ",\"composer_placeholder_ns\":" +
                    metricValue(composerPlaceholderNanos, unavailable).toString() +
                ",\"composer_chrome_ns\":" + metricValue(composerChromeNanos, unavailable).toString() +
                ",\"composer_background_attempts\":" +
                    metricValue(composerBackgroundAttempts, unavailable).toString() +
                ",\"composer_header_attempts\":" +
                    metricValue(composerHeaderAttempts, unavailable).toString() +
                ",\"composer_content_attempts\":" +
                    metricValue(composerContentAttempts, unavailable).toString() +
                ",\"composer_chrome_attempts\":" +
                    metricValue(composerChromeAttempts, unavailable).toString() +
                ",\"composer_rows_visited\":" +
                    metricValue(composerRowsVisited, unavailable).toString() +
                ",\"composer_rows_painted\":" +
                    metricValue(composerRowsPainted, unavailable).toString() +
                ",\"composer_height_before\":" +
                    metricValue(composerHeightBefore, unavailable).toString() +
                ",\"composer_height_after\":" +
                    metricValue(composerHeightAfter, unavailable).toString() +
                ",\"overlay_render_ns\":" + overlayNanos.toString() +
                ",\"transcript_paint_calls\":" + transcriptPaintCalls.toString() +
                ",\"activity_paint_calls\":" + activityPaintCalls.toString() +
                ",\"queue_todo_paint_calls\":" + queueTodoPaintCalls.toString() +
                ",\"composer_paint_calls\":" + composerPaintCalls.toString() +
                ",\"overlay_paint_calls\":" + overlayPaintCalls.toString() +
                ",\"product_other_ns\":" + max(0, productRenderNanos - attributedNanos).toString() +
                ",\"core_render_ns\":" + metrics.renderNanos.toString() +
                ",\"core_diff_ns\":" + metrics.diffNanos.toString() +
                ",\"core_write_ns\":" + metrics.writeNanos.toString() +
                ",\"core_total_draw_ns\":" + metrics.totalNanos.toString() +
                ",\"frame_schedule_reason\":\"" + frameSchedulingSnapshot.reason + "\"" +
                ",\"frame_requests\":" + frameSchedulingSnapshot.frameRequests.toString() +
                ",\"frames_presented\":" + frameSchedulingSnapshot.framesPresented.toString() +
                ",\"frame_requests_merged\":" +
                    frameSchedulingSnapshot.frameRequestsMerged.toString() +
                ",\"frame_deadline_wakes\":" + frameSchedulingSnapshot.frameDeadlineWakes.toString() +
                ",\"pending_frame_promotions\":" +
                    frameSchedulingSnapshot.pendingFramePromotions.toString() +
                ",\"background_frame_requests\":" +
                    frameSchedulingSnapshot.backgroundFrameRequests.toString() +
                ",\"interactive_frame_requests\":" +
                    frameSchedulingSnapshot.interactiveFrameRequests.toString() +
                ",\"resize_frame_requests\":" + frameSchedulingSnapshot.resizeFrameRequests.toString() +
                ",\"updates_per_frame\":" + frameSchedulingSnapshot.updatesPerFrame.toString() +
                ",\"dirty_rects_before_merge\":" +
                    frameSchedulingSnapshot.dirtyRectsBeforeMerge.toString() +
                ",\"dirty_rects_after_merge\":" +
                    frameSchedulingSnapshot.dirtyRectsAfterMerge.toString() +
                ",\"first_invalidation_to_frame_ms\":" +
                    frameSchedulingSnapshot.firstInvalidationToFrameMillis.toString() +
                ",\"last_update_to_frame_ms\":" +
                    frameSchedulingSnapshot.lastUpdateToFrameMillis.toString() +
                ",\"frame_delay_due_to_coalescing_ms\":" +
                    frameSchedulingSnapshot.frameDelayDueToCoalescingMillis.toString() +
                ",\"frames_avoided\":" + frameSchedulingSnapshot.framesAvoided.toString() +
                ",\"buffer_cell_attempts\":" +
                    (if (coreMetricsEnabled) { metrics.bufferCellAttempts } else { unavailable }).toString() +
                ",\"buffer_cell_writes\":" +
                    (if (coreMetricsEnabled) { metrics.bufferCellWrites } else { unavailable }).toString() +
                ",\"diff_cells\":" + metrics.dirtyCells.toString() +
                ",\"diff_spans\":" + metrics.diffWrites.toString() +
                ",\"ansi_bytes\":" + metrics.ansiBytes.toString() +
                ",\"vt_sync_count_calls\":" + metricValue(frameSyncCountCalls, unavailable).toString() +
                ",\"vt_metadata_touches\":" + metricValue(frameMetadataTouches, unavailable).toString() +
                ",\"vt_height_index_reset_entries\":" +
                    metricValue(frameHeightIndexResetEntries, unavailable).toString() +
                ",\"vt_height_index_update_calls\":" +
                    metricValue(frameHeightIndexUpdateCalls, unavailable).toString() +
                ",\"vt_cache_lookups\":" + metricValue(frameCacheLookups, unavailable).toString() +
                ",\"vt_cache_hits\":" + metricValue(frameCacheHits, unavailable).toString() +
                ",\"vt_cache_misses\":" + metricValue(frameCacheMisses, unavailable).toString() +
                ",\"vt_layout_calls\":" + metricValue(frameLayoutCalls, unavailable).toString() +
                ",\"vt_document_requests\":" + metricValue(frameDocumentRequests, unavailable).toString() +
                ",\"vt_documents_materialized\":" +
                    metricValue(frameDocumentsMaterialized, unavailable).toString() +
                ",\"vt_wrap_input_bytes\":" + metricValue(frameWrapInputBytes, unavailable).toString() +
                ",\"vt_measurement_invalidations\":" +
                    metricValue(frameMeasurementInvalidations, unavailable).toString() +
                ",\"vt_visible_items\":" + metricValue(frameVisibleItems, unavailable).toString() +
                ",\"vt_items_visited\":" + metricValue(frameItemsVisited, unavailable).toString() +
                ",\"vt_items_painted\":" + metricValue(frameItemsPainted, unavailable).toString() +
                ",\"vt_rows_visited\":" + metricValue(frameRowsVisited, unavailable).toString() +
                ",\"vt_rows_painted\":" + metricValue(frameRowsPainted, unavailable).toString() +
                ",\"vt_changed_items\":" + metricValue(frameChangedItems, unavailable).toString() +
                ",\"vt_item_paint_cell_attempts\":" +
                    metricValue(frameItemPaintCellAttempts, unavailable).toString() +
                ",\"vt_row_paint_cell_attempts\":" +
                    metricValue(frameRowPaintCellAttempts, unavailable).toString() +
                ",\"vt_item_background_cell_attempts\":" +
                    metricValue(frameItemBackgroundCellAttempts, unavailable).toString() +
                ",\"vt_content_cell_attempts\":" +
                    metricValue(frameContentCellAttempts, unavailable).toString() +
                ",\"vt_layout_rows_requested\":" +
                    metricValue(frameLayoutRowsRequested, unavailable).toString() +
                ",\"vt_cached_rows_used\":" + metricValue(frameCachedRowsUsed, unavailable).toString() +
                ",\"vt_selective_item_invalidations\":" +
                    metricValue(frameSelectiveItemInvalidations, unavailable).toString() +
                ",\"vt_selective_offscreen_invalidations\":" +
                    metricValue(frameSelectiveOffscreenInvalidations, unavailable).toString() +
                ",\"vt_fallback_full_viewport_paints\":" +
                    metricValue(frameFallbackFullViewportPaints, unavailable).toString() +
                ",\"core_metrics_enabled\":" + coreMetricsEnabled.toString() +
                ",\"output_bytes\":" + frameOutputBytes.toString() +
                ",\"write_calls\":" + frameWriteCalls.toString() +
                ",\"flush_calls\":" + frameFlushCalls.toString() +
                ",\"event_queue_length\":" + queueLength.toString() +
                ",\"burst_proof_active\":" + burstProofActive.toString() +
                ",\"burst_expected_tokens\":" + burstExpectedTokens.toString() +
                ",\"burst_interval_ms\":" + burstIntervalMillis.toString() +
                ",\"burst_tokens_applied\":" + burstTokensApplied.toString() +
                ",\"burst_tokens_applied_total\":" + burstTokensAppliedTotal.toString() +
                ",\"burst_ready_markers_processed\":" + burstReadyMarkersProcessed.toString() +
                ",\"burst_item_height_before\":" + burstHeightBefore.toString() +
                ",\"burst_item_height_after\":" + burstHeightAfter.toString() +
                ",\"burst_bounds_stable\":" + burstBoundsStable.toString() +
                ",\"burst_visible_mapping_stable\":" + burstVisibleMappingStable.toString() +
                ",\"burst_follow_bottom\":" + burstFollowBottom.toString() +
                ",\"burst_precise_dirty_hit\":" + burstPreciseDirtyHit.toString() +
                ",\"burst_external_accepted\":" + burstExternalAccepted.toString() +
                ",\"burst_external_full\":" + burstExternalFull.toString() +
                ",\"burst_wake_signals\":" + burstWakeSignals.toString() + "}"
        )
        frameEmitted = true
    }

    public func eventLoopStall(task: String, durationNanos: Int64): Unit {
        emit(
            "{\"kind\":\"EVENT_LOOP_STALL\",\"seq\":" + sequence.toString() +
                ",\"task\":\"" + task + "\",\"duration_ns\":" + durationNanos.toString() + "}"
        )
    }

    private func nowNanos(): Int64 {
        max(0, (MonoTime.now() - origin).toNanoseconds())
    }

    private func completeStage(): Int64 {
        let completed = nowNanos()
        let elapsed = if (stageStartedNanos > 0) { max(0, completed - stageStartedNanos) } else { 0 }
        stageStartedNanos = 0
        elapsed
    }

    private func completeComposerSubstage(): Int64 {
        let completed = nowNanos()
        let elapsed = if (composerSubstageStartedNanos > 0) {
            max(0, completed - composerSubstageStartedNanos)
        } else {
            0
        }
        composerSubstageStartedNanos = 0
        elapsed
    }

    private func metricDelta(current: Int64, previous: Int64, reset: Bool): Int64 {
        if (reset) { max(0, current) } else { max(0, current - previous) }
    }

    private func metricValue(value: Int64, unavailable: Int64): Int64 {
        if (coreMetricsEnabled) { value } else { unavailable }
    }

    private func emit(payload: String): Unit {
        let line = TUI_PERF_PREFIX + payload + "\n"
        output.write(unsafe { line.rawData() })
        output.flush()
    }
}

class TuiTracingOutput <: OutputStream {
    private let delegate: OutputStream
    private let trace: TuiPerformanceTrace
    private var outputBytes: Int64 = 0
    private var writeCalls: Int64 = 0
    private var flushCalls: Int64 = 0

    init(delegate: OutputStream, trace: TuiPerformanceTrace) {
        this.delegate = delegate
        this.trace = trace
    }

    public func write(buffer: Array<Byte>): Unit {
        outputBytes += buffer.size
        writeCalls++
        delegate.write(buffer)
    }

    public func flush(): Unit {
        delegate.flush()
        flushCalls++
        trace.terminalFlushCompleted(outputBytes, writeCalls, flushCalls)
        outputBytes = 0
        writeCalls = 0
        flushCalls = 0
    }
}

func performanceEventName(event: Event): String {
    match (event) {
        case Event.KeyDown(_) => "key_down"
        case Event.KeyUp(_) => "key_up"
        case Event.Mouse(_) => "mouse"
        case Event.Paste(_) => "paste"
        case Event.Resize(_) => "resize"
        case Event.Tick(_) => "tick"
        case Event.Timer(_) => "timer"
        case Event.AsyncStarted(_) => "async_started"
        case Event.AsyncCompleted(_, _) => "async_completed"
        case Event.AsyncFailed(_, _) => "async_failed"
        case Event.AsyncCancelled(_) => "async_cancelled"
        case Event.Message(_) => "message"
        case Event.Capabilities(_) => "capabilities"
        case _ => "other"
    }
}
