package core

import std.collection.*
import std.sync.*

// A serial, noncapturing manual renderer over the same actual Terminal and
// command runtime. The enclosing scope owns their complete retirement. This
// exports metrics only, never a Buffer, snapshot, transport ACK or payment.
public class HeadlessManualFrame240 {
    private let terminal: Terminal
    private let backend: TestBackend
    private let scope: HeadlessCapturedFrameScope
    private let commands: ArrayList<Command>
    private let runtime: AsyncRuntime
    private var updateBody: ?((Event) -> UpdateResult)
    private let lock = Mutex()
    private var active = false
    private var returned = false
    init(terminal: Terminal, backend: TestBackend, scope: HeadlessCapturedFrameScope,
        commands: ArrayList<Command>, runtime: AsyncRuntime, update: (Event) -> UpdateResult) {
        this.terminal = terminal; this.backend = backend; this.scope = scope
        this.commands = commands; this.runtime = runtime; updateBody = Some(update)
    }
    private func enter(): Unit {
        lock.lock(); try {
            if (returned || active) { throw Exception("display.manual_frame_unavailable") }
            active = true
        } finally { lock.unlock() }
    }
    private func leave(): Unit { lock.lock(); try { active = false } finally { lock.unlock() } }
    public func draw(render: (Frame) -> Unit, dirtyRects!: ?DirtyRects = None): RenderMetrics {
        enter()
        try {
            var previous = terminal.retainedFrameCopiesInvoice()
            match (backend.lastBuffer()) {
                case Some(buffer) => previous = retainedDisplayAdd(previous, retainedBufferCellInvoice(buffer))
                case None => () }
            scope.prepareDraw(backend.size(), previous)
            terminal.draw(render, dirtyRects: dirtyRects)
        } finally { leave() }
    }
    public func update(event: Event): UpdateResult {
        enter()
        try { updateFrame(event) } finally { leave() }
    }
    private func updateFrame(event: Event): UpdateResult {
        let update = updateBody.getOrThrow()
        let result = update(event)
        if (!App.applyUpdateResult(result, commands) ||
            !App.processCommands(update, commands, asyncRuntime: runtime)) {
            throw Exception("display.manual_frame_exited") }
        result
    }
    // Only the enclosing serial helper may finish this facade. Unknown live
    // actions keep the scope active; merely returning a status cannot retire it.
    func returnBody240(): Unit {
        lock.lock(); try {
            if (active || returned) { throw Exception("display.manual_frame_active") }
            updateBody = None<((Event) -> UpdateResult)>; returned = true
        } finally { lock.unlock() }
    }
}
