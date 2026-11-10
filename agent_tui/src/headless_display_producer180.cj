package agent_tui

import core.*

// Concrete final headless producer. Its renderer/result helper and exact
// stdout writer must return before this Screen can clear any copied data.
class HeadlessDisplayProducer180 {
    private let screen: AgentScreen
    private let output = DirectStdOutDisplayOutput.open()
    private let capturedFrames: HeadlessCapturedFrameScope
    private var wholeHelperReturned = false
    private var outputRetired: ?RetiredDirectStdOutDisplayReferences = None
    private init(screen: AgentScreen) {
        this.screen = screen; capturedFrames = HeadlessCapturedFrameScope(screen)
    }
    static func run(screen: AgentScreen, events: ExternalPort<Event>, captured!: Bool = false): Int64 {
        let actual = HeadlessDisplayProducer180(screen)
        screen.bindHeadlessDisplayProducer180(actual)
        let result = try {
            if (captured) { actual.runWholeCapturedHelper180() } else { actual.runWholePerformanceHelper180() }
        }
            finally { events.close() }
        // No HeadlessRunResult, Buffer, snapshot, render/update closure or
        // metrics-line String from the original helper remains in this frame.
        actual.wholeHelperReturned = true
        actual.retireAfterWholeHelper180()
        result
    }
    private func runWholeCapturedHelper180(): Int64 { runHeadless(screen, producer180: Some(this)) }
    func runCaptured180(script: HeadlessScript, render: (Frame) -> Unit, update: (Event) -> UpdateResult,
        options!: HeadlessRunOptions = HeadlessRunOptions()): HeadlessRunResult {
        AppTestRunner.runWithCaptureCustody(script, render, update, capturedFrames, options: options)
    }
    func runManual240(body: (HeadlessManualFrame240) -> Int64): Int64 {
        capturedFrames.withManualFrame240<Int64>({ event => screen.update(event) }, body)
    }
    private func runWholePerformanceHelper180(): Int64 {
        runHeadlessPerformance(screen, producer180: Some(this))
    }
    func writeLine180(text: String): Unit {
        if (wholeHelperReturned) { throw Exception("display.headless_producer_closed") }
        output.write((text + "\n").toArray())
    }
    func acknowledges180(actual: AgentScreen): Bool {
        if (!refEq(actual, screen) || !wholeHelperReturned) { return false }
        match (outputRetired) {
            case Some(retired) => retired.physicallyFlushed() && retired.acknowledges(output)
            case None => false }
    }
    private func retireAfterWholeHelper180(): Unit {
        capturedFrames.retireInternalFrames()
        outputRetired = RetiredDirectStdOutDisplayReferences.retire(output)
        match (RetiredOwnedTuiScreenReferences.retireHeadless180(screen, this)) {
            case Some(retired) => screen.retireCopiedRegistry(retired)
            case None => throw Exception("display.headless_producer_retirement_pending") }
    }
}

func writeHeadlessPerformanceLine180(producer: ?HeadlessDisplayProducer180, text: String): Unit {
    match (producer) {
        case Some(actual) => actual.writeLine180(text)
        case None => println(text) }
}
