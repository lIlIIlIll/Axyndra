package core

import std.collection.*
import std.env.*
import std.io.*
import std.time.*

const STDIN_FILENO: Int32 = 0
const STDOUT_FILENO: Int32 = 1
const TCSAFLUSH: Int32 = 2
const TIOCGWINSZ: UInt64 = 0x5413
const MACOS_TIOCGWINSZ: UInt64 = 0x40087468
const TUI_SIGHUP: Int32 = 1
const TUI_SIGINT: Int32 = 2
const TUI_SIGQUIT: Int32 = 3
const TUI_SIGTERM: Int32 = 15

const TERMIOS_SIZE: Int64 = 60
const TERMIOS_CC_OFFSET: Int64 = 17
const VTIME: Int64 = 5
const VMIN: Int64 = 6

const BRKINT: UInt32 = 0x0002u32
const ICRNL: UInt32 = 0x0100u32
const INPCK: UInt32 = 0x0010u32
const ISTRIP: UInt32 = 0x0020u32
const IXON: UInt32 = 0x0400u32
const OPOST: UInt32 = 0x0001u32
const CS8: UInt32 = 0x0030u32
const ECHO: UInt32 = 0x0008u32
const ICANON: UInt32 = 0x0002u32
const IEXTEN: UInt32 = 0x8000u32
const ISIG: UInt32 = 0x0001u32

@FastNative
@When[os == "Linux"]
foreign func tcgetattr(fd: Int32, termios: CPointer<Unit>): Int32

@FastNative
@When[os == "macOS"]
foreign func tcgetattr(fd: Int32, termios: CPointer<Unit>): Int32

@FastNative
@When[os == "Linux"]
foreign func tcsetattr(fd: Int32, optionalActions: Int32, termios: CPointer<Unit>): Int32

@FastNative
@When[os == "macOS"]
foreign func tcsetattr(fd: Int32, optionalActions: Int32, termios: CPointer<Unit>): Int32

@FastNative
@When[os == "Linux"]
foreign func ioctl(fd: Int32, request: UInt64, argp: CPointer<Unit>): Int32

@FastNative
@When[os == "macOS"]
foreign func ioctl(fd: Int32, request: UInt64, argp: CPointer<Unit>): Int32

@FastNative
@When[os == "Linux"]
foreign func isatty(fd: Int32): Int32

@FastNative
@When[os == "macOS"]
foreign func isatty(fd: Int32): Int32

@FastNative
@When[os == "macOS"]
foreign func cfmakeraw(termios: CPointer<Unit>): Unit

@FastNative
@When[os == "Windows"]
foreign func GetStdHandle(nStdHandle: Int32): CPointer<Unit>

@FastNative
@When[os == "Windows"]
foreign func GetConsoleMode(handle: CPointer<Unit>, mode: CPointer<UInt32>): Int32

@FastNative
@When[os == "Windows"]
foreign func SetConsoleMode(handle: CPointer<Unit>, mode: UInt32): Int32

@FastNative
@When[os == "Windows"]
foreign func GetConsoleScreenBufferInfo(handle: CPointer<Unit>, info: CPointer<Unit>): Int32

@FastNative
foreign func signal(signum: Int32, handler: CFunc<(Int32) -> Unit>): CFunc<(Int32) -> Unit>

@FastNative
foreign func _exit(status: Int32): Unit

@When[os == "Windows"]
let STD_INPUT_HANDLE: Int32 = -10
@When[os == "Windows"]
let STD_OUTPUT_HANDLE: Int32 = -11
@When[os == "Windows"]
let ENABLE_PROCESSED_INPUT: UInt32 = 0x0001u32
@When[os == "Windows"]
let ENABLE_LINE_INPUT: UInt32 = 0x0002u32
@When[os == "Windows"]
let ENABLE_ECHO_INPUT: UInt32 = 0x0004u32
@When[os == "Windows"]
let ENABLE_WINDOW_INPUT: UInt32 = 0x0008u32
@When[os == "Windows"]
let ENABLE_QUICK_EDIT_MODE: UInt32 = 0x0040u32
@When[os == "Windows"]
let ENABLE_EXTENDED_FLAGS: UInt32 = 0x0080u32
@When[os == "Windows"]
let ENABLE_VIRTUAL_TERMINAL_INPUT: UInt32 = 0x0200u32
@When[os == "Windows"]
let ENABLE_PROCESSED_OUTPUT: UInt32 = 0x0001u32
@When[os == "Windows"]
let ENABLE_VIRTUAL_TERMINAL_PROCESSING: UInt32 = 0x0004u32
@When[os == "Windows"]
let DISABLE_NEWLINE_AUTO_RETURN: UInt32 = 0x0008u32
@When[os == "Windows"]
let CONSOLE_SCREEN_BUFFER_INFO_BYTES: Int64 = 22

public interface Backend {
    func clear(): Unit
    func moveTo(x: Int64, y: Int64): Unit
    func enterAlternateScreen(): Unit
    func leaveAlternateScreen(): Unit
    func hideCursor(): Unit
    func showCursor(): Unit
    func enableMouse(): Unit
    func disableMouse(): Unit
    func enableBracketedPaste(): Unit
    func disableBracketedPaste(): Unit
    func size(): Rect
    func draw(buffer: Buffer): Unit
    func drawDiff(next: Buffer, plan: RenderDiffPlan): Unit
    func drawMedia(ops: Array<MediaOp>): Unit
    func write(text: String): Unit
    func flush(): Unit
    // Optional Step-0 transport attribution. Backends that cannot expose a
    // byte count retain -1, which means unavailable rather than zero.
    func setInstrumentationEnabled(_: Bool): Unit {}
    func diagnosticByteCount(): Int64 { -1 }
}

public struct RenderDiffSpan {
    public let x: Int64
    public let y: Int64
    public let text: String
    public let style: Style

    public init(x: Int64, y: Int64, text: String, style: Style) {
        this.x = x
        this.y = y
        this.text = text
        this.style = style
    }
}

public struct RenderDiffPlan {
    public let dirtyCells: Int64
    public let spans: Array<RenderDiffSpan>

    public init(dirtyCells: Int64, spans: Array<RenderDiffSpan>) {
        this.dirtyCells = max(0, dirtyCells)
        this.spans = spans
    }
}

public class Frame {
    public let area: Rect
    private let buffer: Buffer
    private let dirty: ?DirtyRects
    private var cursor: ?Position = None

    public init(area: Rect, buffer: Buffer, dirty!: ?DirtyRects = None) {
        this.area = area
        this.buffer = buffer
        this.dirty = dirty
    }

    public func renderWidget(widget: Widget, area: Rect): Unit {
        if (!isDirty(area)) { return }
        widget.render(area, buffer)
    }

    public func canvas(area!: Rect = this.area): Canvas {
        Canvas(buffer, area)
    }

    public func fill(area: Rect, style: Style): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        buffer.fill(area, style: style)
    }

    public func fillRect(x: Int64, y: Int64, width: Int64, height: Int64, style: Style): Unit {
        if (width <= 0 || height <= 0) { return }
        buffer.fillRect(x, y, width, height, style: style)
    }

    public func isDirty(area: Rect): Bool {
        match (dirty) {
            case Some(rects) => rects.intersects(area)
            case None => true
        }
    }

    public func isDirtyCell(x: Int64, y: Int64): Bool {
        match (dirty) {
            case Some(rects) => rects.intersectsCell(x, y)
            case None => true
        }
    }

    public func dirtyRects(): Array<Rect> {
        match (dirty) {
            case Some(rects) => rects.rects()
            case None => [area]
        }
    }

    public func addMedia(placement: MediaPlacement): Unit {
        buffer.addMedia(placement)
    }

    public func setCursor(position: Position): Unit {
        cursor = Some(position)
    }

    public func getCursor(): ?Position {
        cursor
    }
}

public enum RenderMode {
    | Diff
    | Full
}

public class Terminal {
    private let backend: Backend
    private let renderMode: RenderMode
    private let instrumentationEnabled: Bool
    private var front: ?Buffer = None
    private var back: ?Buffer = None
    private var previousMedia: Array<MediaPlacement> = []
    private var cursorVisible: Bool = false

    public init(
        backend: Backend,
        renderMode!: RenderMode = RenderMode.Diff,
        instrumentationEnabled!: Bool = false
    ) {
        this.backend = backend
        this.renderMode = renderMode
        this.instrumentationEnabled = instrumentationEnabled
        backend.setInstrumentationEnabled(instrumentationEnabled)
    }

    public func draw(render: (Frame) -> Unit): RenderMetrics {
        draw(render, dirtyRects: None)
    }

    public func draw(render: (Frame) -> Unit, dirtyRects!: ?DirtyRects): RenderMetrics {
        let area = backend.size()
        if (!frontMatches(area)) {
            front = None
            back = None
        }
        let requestedDirty = effectiveDirtyRects(area, dirtyRects)
        let diffMode = match (renderMode) {
            case RenderMode.Diff => true
            case RenderMode.Full => false
        }
        let effectiveDirty = match (front) {
            case Some(previous) =>
                if (diffMode && !requestedDirty.covers(area)) {
                    wideSafeDirtyRects(area, requestedDirty, previous)
                } else {
                    requestedDirty
                }
            case None => requestedDirty
        }
        let partialRender = diffMode && !effectiveDirty.isEmpty() && !effectiveDirty.covers(area) && frontMatches(area) && hasFront()
        var previousDirty: ?DirtyCellSnapshot = None
        var copiedCells: Int64 = 0
        let buffer = if (partialRender) {
            match (front) {
                case Some(current) =>
                    let snapshot = DirtyCellSnapshot(current, effectiveDirty)
                    copiedCells = snapshot.cellCount()
                    previousDirty = Some(snapshot)
                    current.clearDirty(effectiveDirty)
                    current.setWriteClip(Some(effectiveDirty))
                    current
                case None =>
                    let fresh = acquireBackBuffer(area)
                    fresh.reset()
                    copiedCells = area.width * area.height
                    fresh
            }
        } else {
            let fresh = acquireBackBuffer(area)
            fresh.reset()
            copiedCells = area.width * area.height
            fresh
        }
        let frameDirty: ?DirtyRects = if (partialRender) { Some(effectiveDirty) } else { None }
        let frame = Frame(area, buffer, dirty: frameDirty)
        buffer.beginWorkMetrics(instrumentationEnabled)
        let totalStart = MonoTime.now()
        let renderStart = MonoTime.now()
        render(frame)
        buffer.setWriteClip(None)
        let renderDuration = MonoTime.now() - renderStart
        let renderNanos = renderDuration.toNanoseconds()
        let renderMillis = durationMillis(renderDuration)
        let drawStart = MonoTime.now()
        let byteCountBefore = backend.diagnosticByteCount()
        var diffNanos: Int64 = 0
        var dirtyCells = area.width * area.height
        var diffWrites: Int64 = if (area.height > 0) { area.height } else { 0 }
        var fullRedraw = true
        match (renderMode) {
            case RenderMode.Full =>
                backend.draw(buffer)
            case RenderMode.Diff =>
                if (partialRender) {
                    match (previousDirty) {
                        case Some(prev) =>
                            let diffStart = MonoTime.now()
                            let plan = renderDiffPlan(prev, buffer, dirtyRects: Some(effectiveDirty))
                            diffNanos += (MonoTime.now() - diffStart).toNanoseconds()
                            dirtyCells = plan.dirtyCells
                            diffWrites = plan.spans.size
                            fullRedraw = false
                            backend.drawDiff(buffer, plan)
                        case None => backend.draw(buffer)
                    }
                } else {
                    match (front) {
                        case Some(prev) =>
                            let diffStart = MonoTime.now()
                            let plan = renderDiffPlan(prev, buffer)
                            diffNanos += (MonoTime.now() - diffStart).toNanoseconds()
                            dirtyCells = plan.dirtyCells
                            diffWrites = plan.spans.size
                            fullRedraw = false
                            backend.drawDiff(buffer, plan)
                        case None => backend.draw(buffer)
                    }
                }
        }
        let media = buffer.mediaPlacements()
        let mediaOps = diffMediaPlacements(previousMedia, media)
        backend.drawMedia(mediaOps)
        match (frame.getCursor()) {
            case Some(cursor) =>
                if (!cursorVisible) {
                    backend.showCursor()
                }
                cursorVisible = true
                backend.moveTo(cursor.x, cursor.y)
                backend.flush()
            case None =>
                if (cursorVisible) {
                    backend.hideCursor()
                    backend.flush()
                }
                cursorVisible = false
        }
        let drawDuration = MonoTime.now() - drawStart
        let drawNanos = drawDuration.toNanoseconds()
        let drawMillis = durationMillis(drawDuration)
        if (partialRender) {
            front = Some(buffer)
        } else {
            let oldFront = front
            front = Some(buffer)
            back = oldFront
        }
        previousMedia = media
        let byteCountAfter = backend.diagnosticByteCount()
        let ansiBytes = if (byteCountBefore >= 0 && byteCountAfter >= byteCountBefore) {
            byteCountAfter - byteCountBefore
        } else {
            -1
        }
        RenderMetrics(
            size: area,
            dirtyCells: dirtyCells,
            diffWrites: diffWrites,
            mediaOps: mediaOps.size,
            fullRedraw: fullRedraw,
            renderMillis: renderMillis,
            drawMillis: drawMillis,
            totalMillis: renderMillis + drawMillis,
            renderedCells: if (partialRender) { effectiveDirty.cellCount() } else { area.width * area.height },
            dirtyRects: if (partialRender) { effectiveDirty.rects().size } else { if (area.width > 0 && area.height > 0) { Int64(1) } else { Int64(0) } },
            copiedCells: copiedCells,
            bufferCellAttempts: buffer.cellAttempts(),
            bufferCellWrites: buffer.cellWrites(),
            diffNanos: diffNanos,
            writeNanos: max(0, drawNanos - diffNanos),
            renderNanos: renderNanos,
            totalNanos: (MonoTime.now() - totalStart).toNanoseconds(),
            ansiBytes: ansiBytes
        )
    }

    public func clear(): Unit {
        backend.drawMedia(diffMediaPlacements(previousMedia, []))
        backend.clear()
        front = None
        back = None
        previousMedia = []
    }

    private func frontMatches(area: Rect): Bool {
        match (front) {
            case Some(buffer) => buffer.area == area
            case None => true
        }
    }

    private func hasFront(): Bool {
        match (front) {
            case Some(_) => true
            case None => false
        }
    }

    private func acquireBackBuffer(area: Rect): Buffer {
        match (back) {
            case Some(buffer) =>
                if (buffer.area == area) {
                    buffer.reset()
                    buffer
                } else {
                    Buffer(area)
                }
            case None => Buffer(area)
        }
    }

    private func effectiveDirtyRects(area: Rect, dirtyRects: ?DirtyRects): DirtyRects {
        match (dirtyRects) {
            case Some(rects) =>
                let out = DirtyRects()
                for (rect in rects.rects()) {
                    out.add(intersect(area, rect))
                }
                if (out.isEmpty()) { DirtyRects.full(area) } else { out }
            case None => DirtyRects.full(area)
        }
    }

    // Partial redraw has one correctness boundary for clearing, rendering, and
    // diffing. A one-cell guard permits a newly rendered width-2 grapheme to
    // cross either requested edge. The old front buffer then closes either
    // outer edge over an existing lead/continuation pair. Work is proportional
    // to dirty rows and their boundary neighborhood, never the whole surface.
    private func wideSafeDirtyRects(area: Rect, requested: DirtyRects, previous: Buffer): DirtyRects {
        let out = DirtyRects()
        for (rect in requested.rects()) {
            let target = intersect(area, rect)
            for (y in target.y..target.bottom) {
                var left = max(area.x, target.x - 1)
                var right = min(area.right, target.right + 1)
                if (left > area.x && isWideContinuation(previous.getCell(left, y))) {
                    left--
                }
                if (right < area.right && isWideContinuation(previous.getCell(right, y))) {
                    right++
                }
                out.add(Rect(left, y, right - left, 1))
            }
        }
        out
    }
}

class DirtyCellSnapshot {
    let area: Rect
    private let rectsValue: Array<Rect>
    private let cells: Array<Cell>

    init(previous: Buffer, dirtyRects: DirtyRects) {
        area = previous.area
        let rects = ArrayList<Rect>()
        let copied = ArrayList<Cell>()
        for (rect in dirtyRects.rects()) {
            let target = intersect(previous.area, rect)
            if (target.width <= 0 || target.height <= 0) { continue }
            rects.add(target)
            for (y in target.y..target.bottom) {
                for (x in target.x..target.right) {
                    copied.add(previous.getCell(x, y))
                }
            }
        }
        rectsValue = rects.toArray()
        cells = copied.toArray()
    }

    func cellCount(): Int64 {
        cells.size
    }

    func getCell(x: Int64, y: Int64): Cell {
        var offset: Int64 = 0
        for (rect in rectsValue) {
            let count = rect.width * rect.height
            if (x >= rect.x && x < rect.right && y >= rect.y && y < rect.bottom) {
                return cells[offset + (y - rect.y) * rect.width + (x - rect.x)]
            }
            offset += count
        }
        Cell()
    }
}

func renderDiffPlan(previous: Buffer, next: Buffer, dirtyRects!: ?DirtyRects = None): RenderDiffPlan {
    renderDiffPlanWithPrevious({ x, y => previous.getCell(x, y) }, previous.area, next, dirtyRects: dirtyRects)
}

func renderDiffPlan(previous: DirtyCellSnapshot, next: Buffer, dirtyRects!: ?DirtyRects = None): RenderDiffPlan {
    renderDiffPlanWithPrevious({ x, y => previous.getCell(x, y) }, previous.area, next, dirtyRects: dirtyRects)
}

func renderDiffPlanWithPrevious(previousCell: (Int64, Int64) -> Cell, previousArea: Rect, next: Buffer, dirtyRects!: ?DirtyRects = None): RenderDiffPlan {
    let spans = ArrayList<RenderDiffSpan>()
    var dirtyCells: Int64 = 0
    let scanRects = match (dirtyRects) {
        case Some(rects) => rects.rects()
        case None => [next.area]
    }
    for (scan in scanRects) {
        let target = intersect(next.area, scan)
    for (y in next.area.y..next.area.bottom) {
        if (y < target.y || y >= target.bottom) { continue }
        var x = next.area.x
        if (target.width > 0) { x = target.x }
        while (x < target.right) {
            let cell = next.getCell(x, y)
            if (previousArea == next.area && previousCell(x, y) == cell) {
                x++
                continue
            }
            let start = x
            let style = cell.style
            let text = StringBuilder()
            text.append(cell.symbol)
            dirtyCells++
            x++
            while (x < target.right) {
                let nextCell = next.getCell(x, y)
                if (previousArea == next.area && previousCell(x, y) == nextCell) { break }
                if (nextCell.style != style) { break }
                text.append(nextCell.symbol)
                dirtyCells++
                x++
            }
            spans.add(RenderDiffSpan(start, y, text.toString(), style))
        }
    }
    }
    RenderDiffPlan(dirtyCells, spans.toArray())
}

public enum KeyboardProtocolMode {
    | Basic
    | ModifyOtherKeys
    | Kitty
    | Auto
}

public enum TerminalProbeMode {
    | Disabled
    | EnvOnly
    | Active
}

public struct KeyboardOptions {
    public let mode: KeyboardProtocolMode
    public let probe: TerminalProbeMode
    public let probeBudgetMillis: Int64
    public let escDelayMillis: Int64
    public let repeatHeldMillis: Int64

    public init(
        mode!: KeyboardProtocolMode = KeyboardProtocolMode.Basic,
        probe!: TerminalProbeMode = TerminalProbeMode.Disabled,
        probeBudgetMillis!: Int64 = 100,
        escDelayMillis!: Int64 = 25,
        repeatHeldMillis!: Int64 = 120
    ) {
        this.mode = mode
        this.probe = probe
        this.probeBudgetMillis = clamp(probeBudgetMillis, 0, 100)
        this.escDelayMillis = max(0, escDelayMillis)
        this.repeatHeldMillis = max(1, repeatHeldMillis)
    }
}

public struct TerminalProbeResult {
    public let capabilities: TerminalCapabilities
    public let consumedBytes: Array<Byte>
    public let budgetMillis: Int64
    public let elapsedMillis: Int64

    public init(capabilities: TerminalCapabilities, consumedBytes!: Array<Byte>, budgetMillis!: Int64, elapsedMillis!: Int64) {
        this.capabilities = capabilities
        this.consumedBytes = consumedBytes
        this.budgetMillis = clamp(budgetMillis, 0, 100)
        this.elapsedMillis = max(0, elapsedMillis)
    }
}

public class TerminalProbe {
    public static func run(
        backend: Backend,
        inputSource: InputSource,
        base!: TerminalCapabilities = TerminalCapabilities.detect(backend: backend),
        budgetMillis!: Int64 = 100
    ): TerminalProbeResult {
        let budget = clamp(budgetMillis, 0, 100)
        let started = MonoTime.now()
        backend.write("${ESC}[?u")
        backend.flush()
        let consumed = ArrayList<Byte>()
        var elapsed: Int64 = 0
        while (elapsed <= budget) {
            let chunk = inputSource.readAvailable(256)
            if (chunk.size == 0) { break }
            for (b in chunk) { consumed.add(b) }
            elapsed = durationMillis(MonoTime.now() - started)
        }
        let bytes = consumed.toArray()
        TerminalProbeResult(
            probedCapabilities(base, bytes),
            consumedBytes: bytes,
            budgetMillis: budget,
            elapsedMillis: min(durationMillis(MonoTime.now() - started), budget)
        )
    }
}

public class TerminalSession {
    private let backend: Backend
    private let driver: TerminalDriver
    private let probeInputSource: InputSource
    private let rawMode: Bool
    private let alternateScreen: Bool
    private let mouse: Bool
    private let mouseMove: Bool
    private let focusEvents: Bool
    private let bracketedPaste: Bool
    private let hideCursor: Bool
    private let keyboard: KeyboardOptions
    private var active: Bool = false
    private var rawActive: Bool = false
    private var alternateActive: Bool = false
    private var cursorHidden: Bool = false
    private var mouseActive: Bool = false
    private var mouseMoveActive: Bool = false
    private var focusActive: Bool = false
    private var pasteActive: Bool = false
    private var keyboardActive: Bool = false
    private var lastProbe: ?TerminalProbeResult = None

    public prop rawModeEnabled: Bool { get() { rawActive } }

    public init(
        backend: Backend,
        driver!: TerminalDriver = defaultTerminalDriver(),
        probeInputSource!: InputSource = StdinInputSource(),
        rawMode!: Bool = true,
        alternateScreen!: Bool = true,
        mouse!: Bool = false,
        mouseMove!: Bool = false,
        focusEvents!: Bool = false,
        bracketedPaste!: Bool = true,
        hideCursor!: Bool = true,
        keyboard!: KeyboardOptions = KeyboardOptions()
    ) {
        this.backend = backend
        this.driver = driver
        this.probeInputSource = probeInputSource
        this.rawMode = rawMode
        this.alternateScreen = alternateScreen
        this.mouse = mouse
        this.mouseMove = mouseMove
        this.focusEvents = focusEvents
        this.bracketedPaste = bracketedPaste
        this.hideCursor = hideCursor
        this.keyboard = keyboard
    }

    public func probeResult(): ?TerminalProbeResult {
        lastProbe
    }

    public func start(): Bool {
        if (active) { return true }
        try {
            if (alternateScreen) { backend.enterAlternateScreen(); alternateActive = true }
            if (hideCursor) { backend.hideCursor(); cursorHidden = true }
            if (mouse) { backend.enableMouse(); mouseActive = true }
            if (mouseMove) { backend.write("${ESC}[?1003h${ESC}[?1006h"); mouseMoveActive = true }
            if (focusEvents) { backend.write("${ESC}[?1004h"); focusActive = true }
            if (bracketedPaste) { backend.enableBracketedPaste(); pasteActive = true }
            let rawOk = if (rawMode) { driver.enterRawMode() } else { true }
            rawActive = rawMode && rawOk
            if (rawMode && !rawOk) {
                let cleanupFailure = cleanupStartedModes()
                if (cleanupFailure != "") {
                    throw Exception("terminal raw mode failed; terminal rollback failed: ${cleanupFailure}")
                }
                return false
            }
            enableKeyboardProtocol()
            keyboardActive = true
            active = true
            TerminalSignalGuard.activate(
                raw: rawActive,
                alternateScreen: alternateActive,
                mouse: mouseActive,
                mouseMove: mouseMoveActive,
                focusEvents: focusActive,
                bracketedPaste: pasteActive,
                hideCursor: cursorHidden,
                keyboard: keyboard
            )
            atExit { this.stop() }
            rawOk
        } catch (setup: Exception) {
            let cleanupFailure = cleanupStartedModes()
            if (cleanupFailure != "") {
                throw Exception("terminal setup failed: ${setup.message}; terminal rollback failed: ${cleanupFailure}")
            }
            throw setup
        }
    }

    public func stop(): Unit {
        if (!active) { return }
        let cleanupFailure = cleanupStartedModes()
        if (cleanupFailure != "") {
            throw Exception(cleanupFailure)
        }
    }

    public func run(action: () -> Unit): Unit {
        start()
        try {
            action()
            stop()
        } catch (primary: Exception) {
            try {
                stop()
            } catch (restore: Exception) {
                throw Exception("terminal session failed: ${primary.message}; terminal restore failed: ${restore.message}")
            }
            throw primary
        }
    }

    private func cleanupStartedModes(): String {
        var failures = ""
        if (keyboardActive) {
            try { disableKeyboardProtocol() } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            keyboardActive = false
        }
        if (rawActive) {
            try { driver.restore() } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            rawActive = false
        }
        if (pasteActive) {
            try { backend.disableBracketedPaste() } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            pasteActive = false
        }
        if (focusActive) {
            try { backend.write("${ESC}[?1004l") } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            focusActive = false
        }
        if (mouseMoveActive) {
            try { backend.write("${ESC}[?1003l${ESC}[?1006l") } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            mouseMoveActive = false
        }
        if (mouseActive) {
            try { backend.disableMouse() } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            mouseActive = false
        }
        if (cursorHidden) {
            try { backend.showCursor() } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            cursorHidden = false
        }
        if (alternateActive) {
            try { backend.leaveAlternateScreen() } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
            alternateActive = false
        }
        try { backend.flush() } catch (error: Exception) { failures = appendCleanupFailure(failures, error) }
        active = false
        TerminalSignalGuard.deactivate()
        failures
    }

    private func enableKeyboardProtocol(): Unit {
        match (keyboard.mode) {
            case KeyboardProtocolMode.Basic => ()
            case KeyboardProtocolMode.ModifyOtherKeys =>
                backend.write("${ESC}[>4;2m")
            case KeyboardProtocolMode.Kitty =>
                backend.write("${ESC}[>1u")
            case KeyboardProtocolMode.Auto =>
                match (keyboard.probe) {
                    case TerminalProbeMode.Disabled => ()
                    case TerminalProbeMode.EnvOnly => ()
                    case TerminalProbeMode.Active =>
                        lastProbe = Some(TerminalProbe.run(
                            backend,
                            probeInputSource,
                            base: driver.capabilities(backend),
                            budgetMillis: keyboard.probeBudgetMillis
                        ))
                        backend.write("${ESC}[>1u${ESC}[>4;2m")
                }
        }
    }

    private func disableKeyboardProtocol(): Unit {
        match (keyboard.mode) {
            case KeyboardProtocolMode.Basic => ()
            case KeyboardProtocolMode.ModifyOtherKeys => backend.write("${ESC}[>4;0m")
            case KeyboardProtocolMode.Kitty => backend.write("${ESC}[<1u")
            case KeyboardProtocolMode.Auto =>
                match (keyboard.probe) {
                    case TerminalProbeMode.Active => backend.write("${ESC}[<1u${ESC}[>4;0m")
                    case _ => ()
                }
        }
    }
}

func appendCleanupFailure(current: String, error: Exception): String {
    if (current == "") {
        "terminal restore failed: " + error.message
    } else {
        current + "; " + error.message
    }
}

@C
func tuiTerminalSignalHandler(signum: Int32): Unit {
    TerminalSignalGuard.restoreFromSignal(signum)
}

@When[os == "Linux"]
func restoreNativeRawMode(): Unit {
    TerminalMode.restore()
}

@When[os == "macOS"]
func restoreNativeRawMode(): Unit {
    MacOSTerminalMode.restore()
}

@When[os == "Windows"]
func restoreNativeRawMode(): Unit {
    WindowsConsoleMode.restore()
}

@When[os != "Windows"]
func writeAnsiToStdout(text: String): Unit {
    unsafe {
        let bytes = text.rawData()
        let handle = acquireArrayRawData(bytes)
        _ = write(STDOUT_FILENO, CPointer<Unit>(handle.pointer), UIntNative(bytes.size))
        releaseArrayRawData(handle)
    }
}

@When[os == "Windows"]
func writeAnsiToStdout(text: String): Unit {
    if (text.isEmpty()) { return }
}

class TerminalSignalGuard {
    private static var installed: Bool = false
    private static var active: Bool = false
    private static var restoring: Bool = false
    private static var previousInt: ?CFunc<(Int32) -> Unit> = None
    private static var previousTerm: ?CFunc<(Int32) -> Unit> = None
    private static var previousHup: ?CFunc<(Int32) -> Unit> = None
    private static var previousQuit: ?CFunc<(Int32) -> Unit> = None
    private static var raw: Bool = false
    private static var alternateScreen: Bool = false
    private static var mouse: Bool = false
    private static var mouseMove: Bool = false
    private static var focusEvents: Bool = false
    private static var bracketedPaste: Bool = false
    private static var hideCursor: Bool = false
    private static var keyboard: KeyboardOptions = KeyboardOptions()

    static func activate(
        raw!: Bool,
        alternateScreen!: Bool,
        mouse!: Bool,
        mouseMove!: Bool,
        focusEvents!: Bool,
        bracketedPaste!: Bool,
        hideCursor!: Bool,
        keyboard!: KeyboardOptions
    ): Unit {
        TerminalSignalGuard.raw = raw
        TerminalSignalGuard.alternateScreen = alternateScreen
        TerminalSignalGuard.mouse = mouse
        TerminalSignalGuard.mouseMove = mouseMove
        TerminalSignalGuard.focusEvents = focusEvents
        TerminalSignalGuard.bracketedPaste = bracketedPaste
        TerminalSignalGuard.hideCursor = hideCursor
        TerminalSignalGuard.keyboard = keyboard
        active = true
        restoring = false
        ensureInstalled()
    }

    static func deactivate(): Unit {
        active = false
        restoring = false
        restoreHandlers()
        raw = false
        alternateScreen = false
        mouse = false
        mouseMove = false
        focusEvents = false
        bracketedPaste = false
        hideCursor = false
        keyboard = KeyboardOptions()
    }

    static func restoreFromSignal(signum: Int32): Unit {
        if (active && !restoring) {
            restoring = true
            restoreAnsiModes()
            if (raw) { restoreNativeRawMode() }
            active = false
        }
        unsafe { _exit(128 + signum) }
    }

    private static func ensureInstalled(): Unit {
        if (installed) { return }
        unsafe {
            previousInt = Some(signal(TUI_SIGINT, tuiTerminalSignalHandler))
            previousTerm = Some(signal(TUI_SIGTERM, tuiTerminalSignalHandler))
            previousHup = Some(signal(TUI_SIGHUP, tuiTerminalSignalHandler))
            previousQuit = Some(signal(TUI_SIGQUIT, tuiTerminalSignalHandler))
        }
        installed = true
    }

    private static func restoreHandlers(): Unit {
        if (!installed) { return }
        unsafe {
            match (previousInt) {
                case Some(handler) => _ = signal(TUI_SIGINT, handler)
                case None => ()
            }
            match (previousTerm) {
                case Some(handler) => _ = signal(TUI_SIGTERM, handler)
                case None => ()
            }
            match (previousHup) {
                case Some(handler) => _ = signal(TUI_SIGHUP, handler)
                case None => ()
            }
            match (previousQuit) {
                case Some(handler) => _ = signal(TUI_SIGQUIT, handler)
                case None => ()
            }
        }
        previousInt = None
        previousTerm = None
        previousHup = None
        previousQuit = None
        installed = false
    }

    private static func restoreAnsiModes(): Unit {
        writeAnsi(disableKeyboardProtocolSequence())
        if (bracketedPaste) { writeAnsi("${ESC}[?2004l") }
        if (focusEvents) { writeAnsi("${ESC}[?1004l") }
        if (mouseMove) { writeAnsi("${ESC}[?1003l${ESC}[?1006l") }
        if (mouse) { writeAnsi("${ESC}[?1006l${ESC}[?1000l") }
        if (hideCursor) { writeAnsi("${ESC}[?25h") }
        if (alternateScreen) { writeAnsi("${ESC}[?1049l") }
    }

    private static func disableKeyboardProtocolSequence(): String {
        match (keyboard.mode) {
            case KeyboardProtocolMode.Basic => ""
            case KeyboardProtocolMode.ModifyOtherKeys => "${ESC}[>4;0m"
            case KeyboardProtocolMode.Kitty => "${ESC}[<1u"
            case KeyboardProtocolMode.Auto =>
                match (keyboard.probe) {
                    case TerminalProbeMode.Active => "${ESC}[<1u${ESC}[>4;0m"
                    case _ => ""
                }
        }
    }

    private static func writeAnsi(text: String): Unit {
        if (text.isEmpty()) { return }
        writeAnsiToStdout(text)
    }
}

public interface TerminalDriver {
    func name(): String
    func enterRawMode(): Bool
    func restore(): Unit
    func size(): ?Rect
    func capabilities(backend: Backend): TerminalCapabilities
}

@When[os == "Linux"]
public class LinuxTerminalDriver <: TerminalDriver {
    public init() {}

    public func name(): String { "linux-glibc" }
    public func enterRawMode(): Bool { TerminalMode.enterRawMode() }
    public func restore(): Unit { TerminalMode.restore() }
    public func size(): ?Rect { TerminalMode.size() }
    public func capabilities(backend: Backend): TerminalCapabilities {
        TerminalCapabilities.detect(backend: backend, driverName: name())
    }
}

public class FallbackTerminalDriver <: TerminalDriver {
    private let area: Rect
    public init(area!: Rect = Rect(0, 0, 80, 24)) {
        this.area = area
    }

    public func name(): String { "fallback" }
    public func enterRawMode(): Bool { false }
    public func restore(): Unit {}
    public func size(): ?Rect { Some(area) }
    public func capabilities(backend: Backend): TerminalCapabilities {
        TerminalCapabilities(
            size: backend.size(),
            trueColor: false,
            mouse: false,
            bracketedPaste: false,
            alternateScreen: false,
            unicode: true,
            driverName: name()
        )
    }
}

@When[os != "macOS"]
public class MacOSTerminalDriver <: TerminalDriver {
    private let fallback: FallbackTerminalDriver

    public init(area!: Rect = Rect(0, 0, 80, 24)) {
        fallback = FallbackTerminalDriver(area: area)
    }

    public func name(): String { "macos-fallback" }
    public func enterRawMode(): Bool { false }
    public func restore(): Unit {}
    public func size(): ?Rect { fallback.size() }
    public func capabilities(backend: Backend): TerminalCapabilities {
        TerminalCapabilities(
            size: backend.size(),
            trueColor: false,
            mouse: false,
            bracketedPaste: false,
            alternateScreen: false,
            unicode: true,
            driverName: name()
        )
    }
}

@When[os == "macOS"]
public class MacOSTerminalDriver <: TerminalDriver {
    public init(area!: Rect = Rect(0, 0, 80, 24)) {
        if (area.width < 0) { return }
    }

    public func name(): String { "macos-termios" }
    public func enterRawMode(): Bool { MacOSTerminalMode.enterRawMode() }
    public func restore(): Unit { MacOSTerminalMode.restore() }
    public func size(): ?Rect { MacOSTerminalMode.size() }
    public func capabilities(backend: Backend): TerminalCapabilities {
        TerminalCapabilities.detect(backend: backend, driverName: name())
    }
}

@When[os != "Windows"]
public class WindowsTerminalDriver <: TerminalDriver {
    private let fallback: FallbackTerminalDriver

    public init(area!: Rect = Rect(0, 0, 80, 24)) {
        fallback = FallbackTerminalDriver(area: area)
    }

    public func name(): String { "windows-fallback" }
    public func enterRawMode(): Bool { false }
    public func restore(): Unit {}
    public func size(): ?Rect { fallback.size() }
    public func capabilities(backend: Backend): TerminalCapabilities {
        TerminalCapabilities(
            size: backend.size(),
            trueColor: false,
            mouse: false,
            bracketedPaste: false,
            alternateScreen: false,
            unicode: true,
            driverName: name()
        )
    }
}

@When[os == "Windows"]
public class WindowsTerminalDriver <: TerminalDriver {
    public init(area!: Rect = Rect(0, 0, 80, 24)) {
        if (area.width < 0) { return }
    }

    public func name(): String { "windows-vt" }
    public func enterRawMode(): Bool { WindowsConsoleMode.enterRawMode() }
    public func restore(): Unit { WindowsConsoleMode.restore() }
    public func size(): ?Rect { WindowsConsoleMode.size() }
    public func capabilities(backend: Backend): TerminalCapabilities {
        TerminalCapabilities.detect(backend: backend, driverName: name())
    }
}

@When[os == "Linux"]
public func defaultTerminalDriver(): TerminalDriver {
    LinuxTerminalDriver()
}

@When[os == "macOS"]
public func defaultTerminalDriver(): TerminalDriver {
    MacOSTerminalDriver()
}

@When[os == "Windows"]
public func defaultTerminalDriver(): TerminalDriver {
    WindowsTerminalDriver()
}

public class AnsiBackend <: Backend {
    private let output: OutputStream
    private let driver: TerminalDriver
    private let fallbackArea: Rect
    private var instrumentationEnabled: Bool = false
    private var diagnosticBytesValue: Int64 = 0

    public init(output!: OutputStream = getStdOut(), driver!: TerminalDriver = defaultTerminalDriver(), fallbackArea!: Rect = Rect(0, 0, 80, 24)) {
        this.output = output
        this.driver = driver
        this.fallbackArea = fallbackArea
    }

    public func clear(): Unit {
        write("${ESC}[2J${ESC}[H")
    }

    public func moveTo(x: Int64, y: Int64): Unit {
        write("${ESC}[${y + 1};${x + 1}H")
    }

    public func enterAlternateScreen(): Unit { write("${ESC}[?1049h") }
    public func leaveAlternateScreen(): Unit { write("${ESC}[?1049l") }
    public func hideCursor(): Unit { write("${ESC}[?25l") }
    public func showCursor(): Unit { write("${ESC}[?25h") }
    public func enableMouse(): Unit { write("${ESC}[?1000h${ESC}[?1006h") }
    public func disableMouse(): Unit { write("${ESC}[?1006l${ESC}[?1000l") }
    public func enableBracketedPaste(): Unit { write("${ESC}[?2004h") }
    public func disableBracketedPaste(): Unit { write("${ESC}[?2004l") }

    public func size(): Rect {
        match (driver.size()) {
            case Some(area) => area
            case None => fallbackArea
        }
    }

    public func draw(buffer: Buffer): Unit {
        let batch = StringBuilder()
        var current = Style.default()
        for (y in buffer.area.y..buffer.area.bottom) {
            batch.append("${ESC}[${y + 1};${buffer.area.x + 1}H")
            for (x in buffer.area.x..buffer.area.right) {
                let cell = buffer.getCell(x, y)
                if (cell.style != current) {
                    batch.append(styleToAnsi(cell.style))
                    current = cell.style
                }
                batch.append(cell.symbol)
            }
        }
        batch.append(styleToAnsi(Style.default()))
        write(batch.toString())
        flush()
    }

    public func drawDiff(next: Buffer, plan: RenderDiffPlan): Unit {
        if (next.area.width == 0 || next.area.height == 0) {
            write(styleToAnsi(Style.default()))
            flush()
            return
        }
        let batch = StringBuilder()
        var current = Style.default()
        for (span in plan.spans) {
            batch.append("${ESC}[${span.y + 1};${span.x + 1}H")
            if (span.style != current) {
                batch.append(styleToAnsi(span.style))
                current = span.style
            }
            batch.append(span.text)
        }
        batch.append(styleToAnsi(Style.default()))
        write(batch.toString())
        flush()
    }

    public func drawMedia(ops: Array<MediaOp>): Unit {
        for (op in ops) {
            match (op.kind) {
                case MediaOpKind.Clear => clearMediaArea(op.placement.area)
                case MediaOpKind.Draw => drawMediaPlacement(op.placement)
            }
        }
        if (ops.size > 0) { flush() }
    }

    public func write(text: String): Unit {
        let data = unsafe { text.rawData() }
        if (instrumentationEnabled) { diagnosticBytesValue += data.size }
        output.write(data)
    }

    public func setInstrumentationEnabled(enabled: Bool): Unit {
        instrumentationEnabled = enabled
    }

    public func diagnosticByteCount(): Int64 {
        if (instrumentationEnabled) { diagnosticBytesValue } else { -1 }
    }

    public func flush(): Unit {
        output.flush()
    }

    private func clearMediaArea(area: Rect): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        for (y in area.y..area.bottom) {
            moveTo(area.x, y)
            write(repeat(" ", area.width))
        }
    }

    private func drawMediaPlacement(placement: MediaPlacement): Unit {
        if (placement.area.width <= 0 || placement.area.height <= 0) { return }
        moveTo(placement.area.x, placement.area.y)
        match (placement.frame.protocol) {
            case MediaProtocol.Kitty =>
                let widthPixels = max(1, placement.frame.widthPixels)
                let heightPixels = max(1, placement.frame.heightPixels)
                write("${ESC}_Ga=T,f=32,i=${mediaTerminalId(placement.id)},s=${widthPixels},v=${heightPixels},c=${placement.area.width},r=${placement.area.height};${placement.frame.payload}${ESC}\\")
            case MediaProtocol.Sixel =>
                write("${ESC}Pq${placement.frame.payload}${ESC}\\")
            case MediaProtocol.Text =>
                write(truncate(placement.frame.payload, placement.area.width))
        }
    }
}

public class TestBackend <: Backend {
    private var area: Rect
    private let bytes = ArrayList<Byte>()
    private var latest: ?Buffer = None
    private let frames = ArrayList<String>()
    private let mediaFrames = ArrayList<Array<MediaOp>>()
    // Snapshotting every frame is useful for golden tests, but it is not
    // part of rendering itself.  Headless performance runs can keep the
    // live buffer while avoiding a full terminal-sized String allocation.
    private let captureSnapshots: Bool
    private var latestDiffOps: Int64 = 0
    private var latestDiffWrites: Int64 = 0

    public init(
        area!: Rect = Rect(0, 0, 80, 24),
        captureSnapshots!: Bool = true
    ) {
        this.area = area
        this.captureSnapshots = captureSnapshots
    }

    public func clear(): Unit {
        write("${ESC}[2J${ESC}[H")
    }

    public func moveTo(x: Int64, y: Int64): Unit {
        write("${ESC}[${y + 1};${x + 1}H")
    }

    public func enterAlternateScreen(): Unit { write("${ESC}[?1049h") }
    public func leaveAlternateScreen(): Unit { write("${ESC}[?1049l") }
    public func hideCursor(): Unit { write("${ESC}[?25l") }
    public func showCursor(): Unit { write("${ESC}[?25h") }
    public func enableMouse(): Unit { write("${ESC}[?1000h${ESC}[?1006h") }
    public func disableMouse(): Unit { write("${ESC}[?1006l${ESC}[?1000l") }
    public func enableBracketedPaste(): Unit { write("${ESC}[?2004h") }
    public func disableBracketedPaste(): Unit { write("${ESC}[?2004l") }

    public func size(): Rect {
        area
    }

    public func setSize(area: Rect): Unit {
        this.area = area
    }

    public func draw(buffer: Buffer): Unit {
        latest = Some(buffer)
        latestDiffOps = buffer.area.width * buffer.area.height
        latestDiffWrites = if (buffer.area.height > 0) { buffer.area.height } else { 0 }
        if (captureSnapshots) {
            frames.add(bufferSnapshot(buffer))
        }
        write("<draw>")
    }

    public func drawDiff(next: Buffer, plan: RenderDiffPlan): Unit {
        latest = Some(next)
        latestDiffOps = plan.dirtyCells
        latestDiffWrites = plan.spans.size
        if (captureSnapshots) {
            frames.add(bufferSnapshot(next))
        }
        write("<diff:${latestDiffOps}:${latestDiffWrites}>")
    }

    public func drawMedia(ops: Array<MediaOp>): Unit {
        mediaFrames.add(ops)
        if (ops.size > 0) {
            write("<media:${ops.size}>")
        }
    }

    public func write(text: String): Unit {
        for (b in unsafe { text.rawData() }) {
            bytes.add(b)
        }
    }

    public func flush(): Unit {}

    public func output(): String {
        unsafe { String.fromUtf8Unchecked(bytes.toArray()) }
    }

    public func clearOutput(): Unit {
        while (bytes.size > 0) {
            bytes.remove(at: 0)
        }
    }

    public func lastBuffer(): ?Buffer {
        latest
    }

    public func lastDiffOps(): Int64 {
        latestDiffOps
    }

    public func lastDiffWrites(): Int64 {
        latestDiffWrites
    }

    public func lastMediaOps(): Array<MediaOp> {
        if (mediaFrames.size == 0) { return [] }
        mediaFrames[mediaFrames.size - 1]
    }

    public func mediaFrameCount(): Int64 {
        mediaFrames.size
    }

    public func snapshot(): String {
        match (latest) {
            case Some(buffer) => bufferSnapshot(buffer)
            case None => ""
        }
    }

    public func snapshots(): Array<String> {
        frames.toArray()
    }

    public func snapshotAt(index: Int64): String {
        if (index < 0 || index >= frames.size) { return "" }
        frames[index]
    }

    public func assertCell(x: Int64, y: Int64, symbol: String, style!: Style = Style.default()): Bool {
        match (latest) {
            case Some(buffer) =>
                let cell = buffer.getCell(x, y)
                cell.symbol == symbol && cell.style == style
            case None => false
        }
    }

    public func assertSnapshot(expected: String): Bool {
        snapshot() == expected
    }

    public func assertSnapshotAt(index: Int64, expected: String): Bool {
        snapshotAt(index) == expected
    }

    public func assertLastMediaOpCount(expected: Int64): Bool {
        lastMediaOps().size == expected
    }
}

func mediaTerminalId(id: String): Int64 {
    var value: Int64 = 17
    for (b in unsafe { id.rawData() }) {
        value = (value * 131 + Int64(b)) % 2147483647
    }
    max(1, value)
}

public struct TerminalCapabilities {
    public let size: Rect
    public let trueColor: Bool
    public let colorLevel: Int64
    public let mouse: Bool
    public let mouseMove: Bool
    public let focusEvents: Bool
    public let bracketedPaste: Bool
    public let alternateScreen: Bool
    public let unicode: Bool
    public let kittyGraphics: Bool
    public let sixel: Bool
    public let osc8: Bool
    public let keyboardProtocol: KeyProtocol
    public let keyUp: Bool
    public let keyRepeat: Bool
    public let recommendedFps: Int64
    public let cellWidthPixels: Int64
    public let cellHeightPixels: Int64
    public let driverName: String

    public init(
        size!: Rect = Rect(0, 0, 80, 24),
        trueColor!: Bool = true,
        colorLevel!: Int64 = 24,
        mouse!: Bool = true,
        mouseMove!: Bool = true,
        focusEvents!: Bool = true,
        bracketedPaste!: Bool = true,
        alternateScreen!: Bool = true,
        unicode!: Bool = true,
        kittyGraphics!: Bool = false,
        sixel!: Bool = false,
        osc8!: Bool = true,
        keyboardProtocol!: KeyProtocol = KeyProtocol.Basic,
        keyUp!: Bool = false,
        keyRepeat!: Bool = true,
        recommendedFps!: Int64 = 30,
        cellWidthPixels!: Int64 = 8,
        cellHeightPixels!: Int64 = 16,
        driverName!: String = "linux-glibc"
    ) {
        this.size = size
        this.trueColor = trueColor
        this.colorLevel = if (trueColor) { max(24, colorLevel) } else { max(1, colorLevel) }
        this.mouse = mouse
        this.mouseMove = mouseMove
        this.focusEvents = focusEvents
        this.bracketedPaste = bracketedPaste
        this.alternateScreen = alternateScreen
        this.unicode = unicode
        this.kittyGraphics = kittyGraphics
        this.sixel = sixel
        this.osc8 = osc8
        this.keyboardProtocol = keyboardProtocol
        this.keyUp = keyUp
        this.keyRepeat = keyRepeat
        this.recommendedFps = max(1, recommendedFps)
        this.cellWidthPixels = max(1, cellWidthPixels)
        this.cellHeightPixels = max(1, cellHeightPixels)
        this.driverName = driverName
    }

    public static func detect(backend!: Backend = AnsiBackend(), driverName!: String = "linux-glibc"): TerminalCapabilities {
        let term = match (getVariable("TERM")) {
            case Some(value) => value
            case None => ""
        }
        let colorTerm = match (getVariable("COLORTERM")) {
            case Some(value) => value
            case None => ""
        }
        let trueColor = colorTerm.contains("truecolor") || colorTerm.contains("24bit")
        let dumb = term == "dumb"
        let termProgram = match (getVariable("TERM_PROGRAM")) {
            case Some(value) => value
            case None => ""
        }
        let kitty = term.contains("kitty") ||
            termProgram.contains("WezTerm") || termProgram.contains("wezterm") ||
            termProgram.contains("Ghostty") || termProgram.contains("ghostty")
        let multiplexed = term.contains("screen") || term.contains("tmux")
        let sixel = term.contains("sixel") || term.contains("mlterm")
        let enhancedKeyboard = !dumb && !multiplexed && kitty
        TerminalCapabilities(
            size: backend.size(),
            trueColor: trueColor,
            colorLevel: if (trueColor) { 24 } else if (term.contains("256color")) { 256 } else { 16 },
            mouse: !dumb,
            mouseMove: !dumb,
            focusEvents: !dumb,
            bracketedPaste: !dumb,
            alternateScreen: !dumb,
            unicode: true,
            kittyGraphics: !dumb && !multiplexed && kitty,
            sixel: !dumb && !multiplexed && sixel,
            osc8: !dumb,
            keyboardProtocol: if (enhancedKeyboard) { KeyProtocol.Kitty } else { KeyProtocol.Basic },
            keyUp: enhancedKeyboard,
            keyRepeat: true,
            recommendedFps: if (kitty) { 60 } else { 30 },
            driverName: driverName
        )
    }
}

func probedCapabilities(base: TerminalCapabilities, bytes: Array<Byte>): TerminalCapabilities {
    let text = unsafe { String.fromUtf8Unchecked(bytes) }
    let kittyKeyboard = text.contains("${ESC}[?") && text.contains("u")
    TerminalCapabilities(
        size: base.size,
        trueColor: base.trueColor,
        colorLevel: base.colorLevel,
        mouse: base.mouse,
        mouseMove: base.mouseMove,
        focusEvents: base.focusEvents,
        bracketedPaste: base.bracketedPaste,
        alternateScreen: base.alternateScreen,
        unicode: base.unicode,
        kittyGraphics: base.kittyGraphics,
        sixel: base.sixel,
        osc8: base.osc8,
        keyboardProtocol: if (kittyKeyboard) { KeyProtocol.Kitty } else { base.keyboardProtocol },
        keyUp: base.keyUp || kittyKeyboard,
        keyRepeat: base.keyRepeat,
        recommendedFps: base.recommendedFps,
        cellWidthPixels: base.cellWidthPixels,
        cellHeightPixels: base.cellHeightPixels,
        driverName: base.driverName
    )
}

public struct RenderMetrics {
    public let size: Rect
    public let dirtyCells: Int64
    public let diffWrites: Int64
    public let mediaOps: Int64
    public let fullRedraw: Bool
    public let renderMillis: Int64
    public let drawMillis: Int64
    public let totalMillis: Int64
    public let renderedCells: Int64
    public let dirtyRects: Int64
    public let copiedCells: Int64
    public let bufferCellAttempts: Int64
    public let bufferCellWrites: Int64
    public let diffCells: Int64
    public let diffSpans: Int64
    public let renderNanos: Int64
    public let diffNanos: Int64
    public let writeNanos: Int64
    public let totalNanos: Int64
    public let ansiBytes: Int64

    public init(
        size!: Rect = Rect(0, 0, 0, 0),
        dirtyCells!: Int64 = 0,
        diffWrites!: Int64 = 0,
        mediaOps!: Int64 = 0,
        fullRedraw!: Bool = false,
        renderMillis!: Int64 = 0,
        drawMillis!: Int64 = 0,
        totalMillis!: Int64 = 0,
        renderedCells!: Int64 = 0,
        dirtyRects!: Int64 = 0,
        copiedCells!: Int64 = 0,
        bufferCellAttempts!: Int64 = 0,
        bufferCellWrites!: Int64 = 0,
        renderNanos!: Int64 = 0,
        diffNanos!: Int64 = 0,
        writeNanos!: Int64 = 0,
        totalNanos!: Int64 = 0,
        ansiBytes!: Int64 = -1
    ) {
        this.size = size
        this.dirtyCells = max(0, dirtyCells)
        this.diffWrites = max(0, diffWrites)
        this.mediaOps = max(0, mediaOps)
        this.fullRedraw = fullRedraw
        this.renderMillis = max(0, renderMillis)
        this.drawMillis = max(0, drawMillis)
        this.totalMillis = max(0, totalMillis)
        this.renderedCells = max(0, renderedCells)
        this.dirtyRects = max(0, dirtyRects)
        this.copiedCells = max(0, copiedCells)
        this.bufferCellAttempts = max(0, bufferCellAttempts)
        this.bufferCellWrites = max(0, bufferCellWrites)
        this.diffCells = max(0, dirtyCells)
        this.diffSpans = max(0, diffWrites)
        this.renderNanos = max(0, renderNanos)
        this.diffNanos = max(0, diffNanos)
        this.writeNanos = max(0, writeNanos)
        this.totalNanos = max(0, totalNanos)
        this.ansiBytes = if (ansiBytes < 0) { -1 } else { ansiBytes }
    }
}

public class DebugOverlay <: Widget {
    private let metrics: AppMetrics
    private let style: Style

    public init(metrics: AppMetrics, style!: Style = Style(fg: Color.Black, bg: Color.Yellow)) {
        this.metrics = metrics
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        let frame = metrics.lastFrame()
        let text = match (frame) {
            case Some(m) => "fps=${m.fps} render=${m.renderMillis}ms draw=${m.drawMillis}ms dirty=${m.dirtyCells} writes=${m.diffWrites} queue=${m.eventQueueLength} size=${m.terminalSize.width}x${m.terminalSize.height} dropped=${m.droppedTicks}"
            case None => "fps=0 render=0ms draw=0ms dirty=0 writes=0 queue=0 size=${area.width}x${area.height} dropped=0"
        }
        buffer.setString(area.x, area.y, truncate(text, area.width), style: style)
    }
}

func bufferSnapshot(buffer: Buffer): String {
    let lines = ArrayList<String>()
    for (y in buffer.area.y..buffer.area.bottom) {
        let line = StringBuilder()
        for (x in buffer.area.x..buffer.area.right) {
            let symbol = buffer.getCell(x, y).symbol
            line.append(if (symbol.isEmpty()) { " " } else { symbol })
        }
        lines.add(line.toString())
    }
    join(lines.toArray(), "\n")
}

@When[os == "Linux"]
public class TerminalMode {
    private static var saved: ?Array<UInt8> = None
    private static var active: Bool = false
    private static var depth: Int64 = 0
    private static var lastErrorValue: ?String = None

    public static func lastError(): ?String {
        lastErrorValue
    }

    public static func enterRawMode(): Bool {
        if (active) {
            depth++
            lastErrorValue = None
            return true
        }
        if (unsafe { isatty(STDIN_FILENO) } == 0) {
            lastErrorValue = Some("stdin is not a tty")
            return false
        }
        let original = Array<UInt8>(TERMIOS_SIZE, repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(original)
            let rc = tcgetattr(STDIN_FILENO, CPointer<Unit>(handle.pointer))
            releaseArrayRawData(handle)
            if (rc != 0) {
                lastErrorValue = Some("tcgetattr failed")
                return false
            }
        }
        var raw = Array<UInt8>(TERMIOS_SIZE, repeat: 0)
        original.copyTo(raw, 0, 0, original.size)
        makeRaw(raw)
        unsafe {
            let handle = acquireArrayRawData(raw)
            let rc = tcsetattr(STDIN_FILENO, TCSAFLUSH, CPointer<Unit>(handle.pointer))
            releaseArrayRawData(handle)
            if (rc != 0) {
                lastErrorValue = Some("tcsetattr failed")
                return false
            }
        }
        saved = original
        active = true
        depth = 1
        lastErrorValue = None
        atExit { TerminalMode.restore() }
        true
    }

    public static func restore(): Unit {
        if (!active) { return }
        if (depth > 1) {
            depth--
            return
        }
        if (let Some(termios) <- saved) {
            unsafe {
                let handle = acquireArrayRawData(termios)
                _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, CPointer<Unit>(handle.pointer))
                releaseArrayRawData(handle)
            }
        }
        active = false
        depth = 0
        saved = None
    }

    public static func size(): ?Rect {
        if (unsafe { isatty(STDOUT_FILENO) } == 0) {
            return None
        }
        let winsize = Array<UInt8>(8, repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(winsize)
            let rc = ioctl(STDOUT_FILENO, TIOCGWINSZ, CPointer<Unit>(handle.pointer))
            releaseArrayRawData(handle)
            if (rc != 0) { return None }
        }
        let rows = readUInt16(winsize, 0)
        let cols = readUInt16(winsize, 2)
        if (rows == 0 || cols == 0) {
            return None
        }
        Some(Rect(0, 0, Int64(cols), Int64(rows)))
    }

    private static func makeRaw(termios: Array<UInt8>): Unit {
        var iflag = readUInt32(termios, 0)
        var oflag = readUInt32(termios, 4)
        var cflag = readUInt32(termios, 8)
        var lflag = readUInt32(termios, 12)
        iflag = iflag & ((BRKINT | ICRNL | INPCK | ISTRIP | IXON) ^ 0xFFFF_FFFFu32)
        oflag = oflag & (OPOST ^ 0xFFFF_FFFFu32)
        cflag = cflag | CS8
        lflag = lflag & ((ECHO | ICANON | IEXTEN | ISIG) ^ 0xFFFF_FFFFu32)
        writeUInt32(termios, 0, iflag)
        writeUInt32(termios, 4, oflag)
        writeUInt32(termios, 8, cflag)
        writeUInt32(termios, 12, lflag)
        termios[TERMIOS_CC_OFFSET + VMIN] = 0
        termios[TERMIOS_CC_OFFSET + VTIME] = 0
    }
}

@When[os == "macOS"]
public class MacOSTerminalMode {
    private static var saved: ?Array<UInt8> = None
    private static var active: Bool = false
    private static var depth: Int64 = 0
    private static var lastErrorValue: ?String = None
    private static let TERMIOS_BUFFER_SIZE: Int64 = 128

    public static func lastError(): ?String {
        lastErrorValue
    }

    public static func enterRawMode(): Bool {
        if (active) {
            depth++
            lastErrorValue = None
            return true
        }
        if (unsafe { isatty(STDIN_FILENO) } == 0) {
            lastErrorValue = Some("stdin is not a tty")
            return false
        }
        let original = Array<UInt8>(TERMIOS_BUFFER_SIZE, repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(original)
            let rc = tcgetattr(STDIN_FILENO, CPointer<Unit>(handle.pointer))
            releaseArrayRawData(handle)
            if (rc != 0) {
                lastErrorValue = Some("tcgetattr failed")
                return false
            }
        }
        var raw = Array<UInt8>(TERMIOS_BUFFER_SIZE, repeat: 0)
        original.copyTo(raw, 0, 0, original.size)
        unsafe {
            let handle = acquireArrayRawData(raw)
            cfmakeraw(CPointer<Unit>(handle.pointer))
            let rc = tcsetattr(STDIN_FILENO, TCSAFLUSH, CPointer<Unit>(handle.pointer))
            releaseArrayRawData(handle)
            if (rc != 0) {
                lastErrorValue = Some("tcsetattr failed")
                return false
            }
        }
        saved = original
        active = true
        depth = 1
        lastErrorValue = None
        atExit { MacOSTerminalMode.restore() }
        true
    }

    public static func restore(): Unit {
        if (!active) { return }
        if (depth > 1) {
            depth--
            return
        }
        if (let Some(termios) <- saved) {
            unsafe {
                let handle = acquireArrayRawData(termios)
                _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, CPointer<Unit>(handle.pointer))
                releaseArrayRawData(handle)
            }
        }
        active = false
        depth = 0
        saved = None
    }

    public static func size(): ?Rect {
        if (unsafe { isatty(STDOUT_FILENO) } == 0) {
            return None
        }
        let winsize = Array<UInt8>(8, repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(winsize)
            let rc = ioctl(STDOUT_FILENO, MACOS_TIOCGWINSZ, CPointer<Unit>(handle.pointer))
            releaseArrayRawData(handle)
            if (rc != 0) { return None }
        }
        let rows = readUInt16(winsize, 0)
        let cols = readUInt16(winsize, 2)
        if (rows == 0 || cols == 0) {
            return None
        }
        Some(Rect(0, 0, Int64(cols), Int64(rows)))
    }
}

@When[os == "Windows"]
public class WindowsConsoleMode {
    private static var savedInputMode: ?UInt32 = None
    private static var savedOutputMode: ?UInt32 = None
    private static var active: Bool = false
    private static var depth: Int64 = 0
    private static var lastErrorValue: ?String = None

    public static func lastError(): ?String {
        lastErrorValue
    }

    public static func enterRawMode(): Bool {
        if (active) {
            depth++
            lastErrorValue = None
            return true
        }
        let input = inputHandle()
        let output = outputHandle()
        match (readConsoleMode(input)) {
            case Some(inputMode) =>
                match (readConsoleMode(output)) {
                    case Some(outputMode) =>
                        let rawInput = windowsRawInputMode(inputMode)
                        let vtOutput = windowsVtOutputMode(outputMode)
                        if (unsafe { SetConsoleMode(input, rawInput) } == 0) {
                            lastErrorValue = Some("SetConsoleMode input failed")
                            return false
                        }
                        if (unsafe { SetConsoleMode(output, vtOutput) } == 0) {
                            _ = unsafe { SetConsoleMode(input, inputMode) }
                            lastErrorValue = Some("SetConsoleMode output failed")
                            return false
                        }
                        savedInputMode = Some(inputMode)
                        savedOutputMode = Some(outputMode)
                        active = true
                        depth = 1
                        lastErrorValue = None
                        atExit { WindowsConsoleMode.restore() }
                        true
                    case None =>
                        lastErrorValue = Some("GetConsoleMode output failed")
                        false
                }
            case None =>
                lastErrorValue = Some("GetConsoleMode input failed")
                false
        }
    }

    public static func restore(): Unit {
        if (!active) { return }
        if (depth > 1) {
            depth--
            return
        }
        if (let Some(mode) <- savedInputMode) {
            _ = unsafe { SetConsoleMode(inputHandle(), mode) }
        }
        if (let Some(mode) <- savedOutputMode) {
            _ = unsafe { SetConsoleMode(outputHandle(), mode) }
        }
        active = false
        depth = 0
        savedInputMode = None
        savedOutputMode = None
    }

    public static func size(): ?Rect {
        let output = outputHandle()
        let info = Array<UInt8>(CONSOLE_SCREEN_BUFFER_INFO_BYTES, repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(info)
            let rc = GetConsoleScreenBufferInfo(output, CPointer<Unit>(handle.pointer))
            releaseArrayRawData(handle)
            if (rc == 0) { return None }
        }
        let left = Int64(readUInt16(info, 10))
        let top = Int64(readUInt16(info, 12))
        let right = Int64(readUInt16(info, 14))
        let bottom = Int64(readUInt16(info, 16))
        if (right < left || bottom < top) { return None }
        let width = right - left + 1
        let height = bottom - top + 1
        if (width <= 0 || height <= 0) { return None }
        Some(Rect(0, 0, width, height))
    }

    private static func inputHandle(): CPointer<Unit> {
        unsafe { GetStdHandle(STD_INPUT_HANDLE) }
    }

    private static func outputHandle(): CPointer<Unit> {
        unsafe { GetStdHandle(STD_OUTPUT_HANDLE) }
    }

    private static func readConsoleMode(handle: CPointer<Unit>): ?UInt32 {
        let mode = Array<UInt32>(1, repeat: 0u32)
        unsafe {
            let raw = acquireArrayRawData(mode)
            let rc = GetConsoleMode(handle, CPointer<UInt32>(raw.pointer))
            releaseArrayRawData(raw)
            if (rc == 0) { return None }
        }
        Some(mode[0])
    }

    private static func windowsRawInputMode(mode: UInt32): UInt32 {
        var raw = mode
        raw = raw & ((ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_QUICK_EDIT_MODE) ^ 0xFFFF_FFFFu32)
        raw = raw | ENABLE_PROCESSED_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS | ENABLE_VIRTUAL_TERMINAL_INPUT
        raw
    }

    private static func windowsVtOutputMode(mode: UInt32): UInt32 {
        mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN
    }
}
