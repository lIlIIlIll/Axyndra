package core

import std.collection.*

// Owns actual runner internals, never the caller's exported result. Closing
// this serial fixture scope proves no snapshot/Buffer consumer return, transport ACK or bank
// refund. A concrete product producer must separately prove those lifetimes.
public class HeadlessCapturedFrameScope {
    private let provider: TerminalFrameProvider
    private var first: ?HeadlessCapturedFrame = None
    private var active: Int64 = 0
    private var retainedInvoice: Int64 = 65536
    private var closing = false
    private var closed = false
    public init(provider: TerminalFrameProvider) { this.provider = provider }
    func prepareEntry(size: Rect): Unit {
        if (closing || closed) { throw Exception("display.headless_capture_scope_closed") }
        if (provider.headlessCapturedDataRequiresPayment()) {
            let next = retainedDisplayAdd(retainedInvoice, 65536)
            if (!provider.prepareRetainedFrameCopies(size, next)) { throw Exception("display.raster_payment_required") }
            retainedInvoice = next
        }
    }
    func register(terminal: Terminal, backend: TestBackend, commands: ArrayList<Command>, runtime: AsyncRuntime): HeadlessCapturedFrame {
        let frame = HeadlessCapturedFrame(terminal, backend, commands, runtime, first)
        first = Some(frame); active++
        frame
    }
    // Actual manual loops retain their original dirty rectangles and metrics.
    // No unused snapshot archive is constructed. Commands use this exact
    // runtime; backend, callable and Terminal fields retire with this scope.
    public func withManualFrame240<T>(update: (Event) -> UpdateResult,
        body: (HeadlessManualFrame240) -> T, area!: Rect = Rect(0, 0, 100, 28)): T {
        prepareEntry(area)
        let backend = TestBackend(area: area, captureSnapshots: false)
        let terminal = Terminal(backend, renderMode: RenderMode.Diff)
        let commands = ArrayList<Command>()
        let runtime = AsyncRuntime()
        let frame = register(terminal, backend, commands, runtime)
        let manual = HeadlessManualFrame240(terminal, backend, this, commands, runtime, update)
        var failed = false
        try { body(manual) }
        catch (error: Exception) { failed = true; throw error }
        finally {
            if (failed) {
                // Keep the original failure. An unreturned facade leaves the
                // scope active, so later cleanup cannot manufacture a receipt.
                try { manual.returnBody240(); frameReturned(frame) } catch (_: Exception) { () }
            } else { manual.returnBody240(); frameReturned(frame) }
        }
    }
    func frameReturned(frame: HeadlessCapturedFrame): Unit {
        if (frame.returned || active < 1) { throw Exception("display.headless_capture_frame_mismatch") }
        frame.returned = true; active--
    }
    func prepareDraw(size: Rect, current: Int64): Unit {
        if (closing || closed || active < 1) { throw Exception("display.headless_capture_frame_missing") }
        if (!provider.prepareRetainedFrameCopies(size, retainedDisplayAdd(retainedInvoice, current))) {
            throw Exception("display.raster_payment_required") }
    }
    func prepareCapture(buffer: Buffer, options: HeadlessRunOptions, current: Int64): Unit {
        // Before a copied display exists, the concrete Screen has no retained
        // display payer. Its existing caller/fixture data obligations remain;
        // that history cannot become a later Native document's invoice. This
        // branch never lowers an earlier real retainedInvoice or issues ACK.
        if (!provider.headlessCapturedDataRequiresPayment()) { return }
        var added:Int64=4096
        if (options.captureBuffers) { added=retainedDisplayAdd(added,retainedBufferCellInvoice(buffer)) }
        if (options.captureSnapshots) {
            var bytes=max(0,buffer.area.height-1)
            for(y in buffer.area.y..buffer.area.bottom){
                for(x in buffer.area.x..buffer.area.right){
                    bytes=retainedDisplayAdd(bytes,max(1,buffer.getCell(x,y).symbol.size))
                }
            }
            // One retained TestBackend snapshot and one result snapshot. Full
            // UTF8/row/builder/array working backing uses the existing16x text
            // allowance, separately from the one actual Buffer cell copy.
            added=retainedDisplayAdd(added,retainedDisplayMultiply(bytes,32))
            added=retainedDisplayAdd(added,retainedDisplayMultiply(max(1,buffer.area.height),2048))
        }
        let next=retainedDisplayAdd(retainedInvoice,added)
        if (!provider.prepareRetainedFrameCopies(buffer.area,retainedDisplayAdd(next,current))) {
            throw Exception("display.raster_payment_required") }
        retainedInvoice=next
    }
    public func retireInternalFrames(): Unit {
        if (closed) { return }
        if (active != 0) { throw Exception("display.headless_capture_frame_active") }
        closing = true
        if (first.isNone()) { closed = true; return }
        provider.beginRetainedDisplayProducerClosing()
        while (first.isSome()) {
            let frame = first.getOrThrow()
            frame.commands.clear()
            provider.noteAsyncTaskReferencesRetired(RetiredAsyncTaskReferences.retire(frame.runtime))
            frame.backend.clearRetainedHeadlessReferences()
            match (RetiredInternalDisplayFrameReferences.retire(frame.terminal)) {
                case Some(retired) => provider.noteInternalDisplayFrameReferencesRetired(retired)
                case None => throw Exception("display.headless_terminal_retirement_pending") }
            first = frame.next; frame.next = None
        }
        closed = true
    }
}

class HeadlessCapturedFrame {
    let terminal: Terminal
    let backend: TestBackend
    let commands: ArrayList<Command>
    let runtime: AsyncRuntime
    var next: ?HeadlessCapturedFrame
    var returned = false
    init(terminal: Terminal, backend: TestBackend, commands: ArrayList<Command>, runtime: AsyncRuntime,
        next: ?HeadlessCapturedFrame) {
        this.terminal = terminal; this.backend = backend; this.commands = commands
        this.runtime = runtime; this.next = next
    }
}
