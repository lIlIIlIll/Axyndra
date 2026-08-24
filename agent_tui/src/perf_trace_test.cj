package agent_tui

import core.*
import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

class Step05TraceOutput <: OutputStream {
    let bytes = ArrayList<Byte>()

    public func write(value: Array<Byte>): Unit {
        for (byte in value) { bytes.add(byte) }
    }

    public func flush(): Unit {}

    func text(): String { unsafe { String.fromUtf8Unchecked(bytes.toArray()) } }
}

@Test
class Step05PerformanceTraceTest {
    @TestCase
    func completedFrameBindsProductStagesAndCoreMetrics(): Unit {
        let output = Step05TraceOutput()
        let trace = TuiPerformanceTrace(output: output)
        trace.inputReceived(Event.KeyDown(KeyEvent(KeyCode.Char(r'a'))), 2)
        trace.eventDispatchCompleted()
        trace.stateUpdateCompleted()
        trace.renderStarted()
        trace.layoutCompleted()
        trace.screenPreparationCompleted()
        trace.transcriptStarted()
        trace.transcriptPainted()
        trace.transcriptCompleted()
        trace.renderCompleted()
        trace.frameScheduling(FrameSchedulingSnapshot(
            reason: "interactive",
            frameRequests: 4,
            framesPresented: 2,
            frameRequestsMerged: 2,
            pendingFramePromotions: 1,
            updatesPerFrame: 3,
            framesAvoided: 2
        ))
        trace.terminalFlushCompleted(17, 2, 1)
        @Expect(!output.text().contains("\"kind\":\"operation\""))

        trace.frameCompleted(RenderMetrics(
            dirtyCells: 3,
            diffWrites: 2,
            bufferCellAttempts: 9,
            bufferCellWrites: 8,
            renderNanos: 100,
            diffNanos: 20,
            writeNanos: 30,
            totalNanos: 150,
            ansiBytes: 17
        ))
        let line = output.text()
        @Expect(line.contains("\"kind\":\"operation\""))
        @Expect(line.contains("\"transcript_render_ns\":"))
        @Expect(line.contains("\"transcript_paint_calls\":1"))
        @Expect(line.contains("\"composer_paint_calls\":0"))
        @Expect(line.contains("\"composer_header_ns\":-1"))
        @Expect(line.contains("\"composer_widget_ns\":-1"))
        @Expect(line.contains("\"composer_background_attempts\":-1"))
        @Expect(line.contains("\"composer_rows_painted\":-1"))
        @Expect(line.contains("\"core_diff_ns\":20"))
        @Expect(line.contains("\"core_write_ns\":30"))
        @Expect(line.contains("\"frame_schedule_reason\":\"interactive\""))
        @Expect(line.contains("\"frame_requests_merged\":2"))
        @Expect(line.contains("\"updates_per_frame\":3"))
        @Expect(line.contains("\"frames_avoided\":2"))
        @Expect(line.contains("\"diff_cells\":3"))
        @Expect(line.contains("\"ansi_bytes\":17"))
        @Expect(line.contains("\"core_metrics_enabled\":false"))
        @Expect(line.contains("\"buffer_cell_attempts\":-1"))
        @Expect(line.contains("\"output_bytes\":17"))
    }
}
