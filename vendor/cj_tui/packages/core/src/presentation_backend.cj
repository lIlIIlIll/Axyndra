package core

import std.collection.*

// The primary surface is appended to the terminal's native scrollback. A
// fullscreen surface owns the alternate screen only for the duration of that
// surface.
public enum PresentationMode {
    | Primary
    | Fullscreen
}

public enum HistoryBatchKind {
    | Append
    | Replay
}

// A bounded, immutable unit of native scrollback output. The provider retains
// ownership of formatting; the presenter only controls when this unit is
// emitted and acknowledged.
public class HistoryBatch {
    public let id: Int64
    public let kind: HistoryBatchKind
    public let startRow: Int64
    private let values: Array<String>

    public init(
        id: Int64,
        kind: HistoryBatchKind,
        lines: Array<String>,
        startRow!: Int64 = 0
    ) {
        this.id = max(0, id)
        this.kind = kind
        this.startRow = max(0, startRow)
        let copied = ArrayList<String>()
        for (line in lines) {
            copied.add(line)
        }
        this.values = copied.toArray()
    }

    public func lineCount(): Int64 {
        values.size
    }

    public func line(index: Int64): String {
        if (index < 0 || index >= values.size) {
            return ""
        }
        values[index]
    }

    public func lines(): Array<String> {
        let copied = ArrayList<String>()
        for (line in values) {
            copied.add(line)
        }
        copied.toArray()
    }
}

public struct PresentationFrame {
    public let mode: PresentationMode
    public let terminalSize: Rect
    public let viewport: Rect
    public let history: ?HistoryBatch
    public let followUp: Bool
    public let generation: Int64

    public init(
        mode: PresentationMode,
        terminalSize: Rect,
        viewport!: Rect,
        history!: ?HistoryBatch = None,
        generation!: Int64 = 0,
        followUp!: Bool = false
    ) {
        this.mode = mode
        this.terminalSize = terminalSize
        this.viewport = viewport
        this.history = history
        this.generation = max(0, generation)
        this.followUp = followUp
    }
}

// Product code supplies semantic history and the live viewport through this
// single contract. renderHistory is called from inside Terminal.draw before
// the mutable viewport is flushed, so a failed write cannot be acknowledged.
public interface TerminalFrameProvider {
    func prepareFrame(size: Rect): PresentationFrame
    func renderViewport(frame: Frame): Unit
    func renderHistory(batchId: Int64, startRow: Int64, frame: Frame): Unit
    func acknowledgeHistory(id: Int64): Unit
    func requestReplay(): Unit
}

// Write a prepared batch through the frame's transport while retaining one
// terminal flush for the complete history-plus-viewport presentation.
public func renderHistoryBatch(
    batch: HistoryBatch,
    startRow: Int64,
    frame: Frame
): Unit {
    var row = clamp(startRow, 0, batch.lineCount())
    while (row < batch.lineCount()) {
        frame.writeRaw(batch.line(row))
        frame.writeRaw("\r\n")
        row++
    }
}

// Backend decorator used by App's prepared-only presentation path. It keeps
// ordinary Backend consumers unchanged while exposing the active surface mode
// and the raw history transport needed by TerminalFrameProvider.
public class PresentationBackend <: Backend {
    private let delegate: Backend
    private var session: ?TerminalSession = None
    private var activeModeValue = PresentationMode.Primary
    private var pendingFramePrefix = ""

    public init(delegate: Backend) {
        this.delegate = delegate
    }

    public func bind(session: TerminalSession): Unit {
        this.session = Some(session)
    }

    public func activeMode(): PresentationMode {
        activeModeValue
    }

    public func sync(mode: PresentationMode): Bool {
        let changed = match ((mode, activeModeValue)) {
            case (PresentationMode.Primary, PresentationMode.Primary) => false
            case (PresentationMode.Fullscreen, PresentationMode.Fullscreen) => false
            case _ => true
        }
        match (session) {
            case Some(current) =>
                match (mode) {
                    case PresentationMode.Fullscreen => current.enterFullscreen()
                    case PresentationMode.Primary => current.leaveFullscreen()
                }
            case None =>
                match ((mode, activeModeValue)) {
                    case (PresentationMode.Fullscreen, PresentationMode.Primary) =>
                        delegate.enterAlternateScreen()
                        delegate.enableMouse()
                    case (PresentationMode.Primary, PresentationMode.Fullscreen) =>
                        delegate.disableMouse()
                        delegate.leaveAlternateScreen()
                    case _ => ()
                }
        }
        activeModeValue = mode
        changed
    }

    public func resetMode(): Unit {
        activeModeValue = PresentationMode.Primary
    }

    public func clearScrollback(): Unit {
        pendingFramePrefix += "\u{1B}[3J"
    }

    private func takeFramePrefix(prefix: String): String {
        let combined = pendingFramePrefix + prefix
        pendingFramePrefix = ""
        combined
    }

    public func writeHistory(batch: HistoryBatch, startRow: Int64): Unit {
        match (activeModeValue) {
            case PresentationMode.Fullscreen => return
            case PresentationMode.Primary => ()
        }
        var row = clamp(startRow, 0, batch.lineCount())
        while (row < batch.lineCount()) {
            delegate.write(batch.line(row))
            delegate.write("\r\n")
            row++
        }
    }

    public func clear(): Unit { delegate.clear() }
    public func moveTo(x: Int64, y: Int64): Unit { delegate.moveTo(x, y) }
    public func enterAlternateScreen(): Unit { delegate.enterAlternateScreen() }
    public func leaveAlternateScreen(): Unit { delegate.leaveAlternateScreen() }
    public func hideCursor(): Unit { delegate.hideCursor() }
    public func showCursor(): Unit { delegate.showCursor() }
    public func enableMouse(): Unit { delegate.enableMouse() }
    public func disableMouse(): Unit { delegate.disableMouse() }
    public func enableBracketedPaste(): Unit { delegate.enableBracketedPaste() }
    public func disableBracketedPaste(): Unit { delegate.disableBracketedPaste() }
    public func size(): Rect { delegate.size() }
    public func drawWithPrefix(prefix: String, buffer: Buffer): Unit {
        delegate.drawWithPrefix(takeFramePrefix(prefix), buffer)
    }
    public func drawFrame(
        prefix: String,
        buffer: Buffer,
        cursor: ?Position,
        cursorWasVisible: Bool
    ): Unit {
        delegate.drawFrame(
            takeFramePrefix(prefix),
            buffer,
            cursor,
            cursorWasVisible
        )
    }
    public func draw(buffer: Buffer): Unit { delegate.drawWithPrefix(takeFramePrefix(""), buffer) }
    public func drawDiff(next: Buffer, plan: RenderDiffPlan): Unit { delegate.drawDiff(next, plan) }
    public func drawMedia(ops: Array<MediaOp>): Unit { delegate.drawMedia(ops) }
    public func write(text: String): Unit { delegate.write(text) }
    public func flush(): Unit { delegate.flush() }
    public func setInstrumentationEnabled(enabled: Bool): Unit { delegate.setInstrumentationEnabled(enabled) }
    public func diagnosticByteCount(): Int64 { delegate.diagnosticByteCount() }
}
