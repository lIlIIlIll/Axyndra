package core

import std.collection.*

public enum CellKind {
    | Normal
    | WideLead
    | WideCont
}

public struct Cell <: Equatable<Cell> {
    public var symbol: String = " "
    public var style: Style = Style.default()
    public var kind: CellKind = CellKind.Normal

    public init() {}

    public init(symbol: String, style!: Style = Style.default(), kind!: CellKind = CellKind.Normal) {
        this.symbol = symbol
        this.style = style
        this.kind = kind
    }

    public operator func ==(other: Cell): Bool {
        symbol == other.symbol && style == other.style && sameCellKind(kind, other.kind)
    }
}

public class Buffer {
    public let area: Rect
    private let cells: Array<Cell>
    private let media = ArrayList<MediaPlacement>()
    private var writeClip: ?DirtyRects = None
    // Step-0 diagnostics are opt-in and reset for each render closure. These
    // counters never participate in clipping, layout, or cell equality.
    private var workMetricsEnabled: Bool = false
    private var cellAttemptsValue: Int64 = 0
    private var cellWritesValue: Int64 = 0

    public init(area: Rect) {
        this.area = area
        this.cells = Array<Cell>(area.width * area.height, repeat: Cell())
    }

    public func clear(style!: Style = Style.default()): Unit {
        let blank = Cell(" ", style: style)
        for (i in 0..cells.size) {
            cells[i] = blank
        }
    }

    func reset(style!: Style = Style.default()): Unit {
        writeClip = None
        clear(style: style)
        while (media.size > 0) {
            media.remove(at: 0)
        }
    }

    func setWriteClip(clip: ?DirtyRects): Unit {
        writeClip = clip
    }

    func beginWorkMetrics(enabled: Bool): Unit {
        workMetricsEnabled = enabled
        cellAttemptsValue = 0
        cellWritesValue = 0
    }

    func cellAttempts(): Int64 { cellAttemptsValue }

    func cellWrites(): Int64 { cellWritesValue }

    // Package-internal paint pruning hook. Widgets may use the Terminal's
    // existing physical write clip to skip whole derived paint units; this
    // does not create or widen damage and is never a correctness fallback.
    func intersectsWriteClip(area: Rect): Bool {
        match (writeClip) {
            case Some(clip) => clip.intersects(area)
            case None => true
        }
    }

    func clearDirty(rects: DirtyRects, style!: Style = Style.default()): Unit {
        let blank = Cell(" ", style: style)
        for (rect in rects.rects()) {
            let target = intersect(area, rect)
            for (y in target.y..target.bottom) {
                for (x in target.x..target.right) {
                    setCellRaw(x, y, blank)
                }
            }
        }
    }

    public func indexOf(x: Int64, y: Int64): ?Int64 {
        if (x < area.x || y < area.y || x >= area.right || y >= area.bottom) {
            return None
        }
        return (y - area.y) * area.width + (x - area.x)
    }

    public func setCell(x: Int64, y: Int64, cell: Cell): Unit {
        if (workMetricsEnabled) { cellAttemptsValue++ }
        if (!isWritable(x, y)) { return }
        if (let Some(index) <- indexOf(x, y)) {
            if (isWideContinuation(cells[index]) && x > area.x) {
                setCellRaw(x - 1, y, Cell(" ", style: cells[index].style))
            }
            if (!isWideContinuation(cell) && x + 1 < area.right && isWideContinuation(getCell(x + 1, y))) {
                setCellRaw(x + 1, y, Cell(" "))
            }
            cells[index] = cell
            if (workMetricsEnabled) { cellWritesValue++ }
        }
    }

    private func setCellRaw(x: Int64, y: Int64, cell: Cell): Unit {
        if (workMetricsEnabled) { cellAttemptsValue++ }
        if (!isWritable(x, y)) { return }
        if (let Some(index) <- indexOf(x, y)) {
            cells[index] = cell
            if (workMetricsEnabled) { cellWritesValue++ }
        }
    }

    public func getCell(x: Int64, y: Int64): Cell {
        if (let Some(index) <- indexOf(x, y)) {
            return cells[index]
        }
        Cell()
    }

    public func fill(area: Rect, cell: Cell): Unit {
        let target = intersect(this.area, area)
        if (target.width <= 0 || target.height <= 0) { return }
        match (writeClip) {
            case Some(clip) =>
                for (rect in clip.rects()) {
                    let clipped = intersect(target, rect)
                    fillUnclipped(clipped, cell)
                }
                return
            case None => ()
        }
        fillUnclipped(target, cell)
    }

    private func fillUnclipped(target: Rect, cell: Cell): Unit {
        if (target.width <= 0 || target.height <= 0) { return }
        if (!isSingleWidthNormal(cell)) {
            for (y in target.y..target.bottom) {
                for (x in target.x..target.right) {
                    setCell(x, y, cell)
                }
            }
            return
        }
        let boundaryBlank = Cell(" ", style: cell.style)
        for (y in target.y..target.bottom) {
            if (target.x > this.area.x && isWideContinuation(getCell(target.x, y))) {
                setCellRaw(target.x - 1, y, boundaryBlank)
            }
            if (target.right < this.area.right && isWideContinuation(getCell(target.right, y))) {
                setCellRaw(target.right, y, boundaryBlank)
            }
            for (x in target.x..target.right) {
                setCellRaw(x, y, cell)
            }
        }
    }

    public func fill(area: Rect, style!: Style = Style.default()): Unit {
        let blank = Cell(" ", style: style)
        fill(area, blank)
    }

    public func fillRect(x: Int64, y: Int64, width: Int64, height: Int64, style!: Style = Style.default()): Unit {
        fill(Rect(x, y, width, height), style: style)
    }

    public func fillLine(y: Int64, x: Int64, width: Int64, cell: Cell): Unit {
        if (width <= 0) { return }
        fill(Rect(x, y, width, 1), cell)
    }

    public func fillLine(y: Int64, x: Int64, width: Int64, style!: Style = Style.default()): Unit {
        fillLine(y, x, width, Cell(" ", style: style))
    }

    public func hline(x: Int64, y: Int64, width: Int64, symbol: String, style: Style): Unit {
        if (width <= 0 || symbol == "") { return }
        let target = intersect(this.area, Rect(x, y, width, 1))
        if (target.width <= 0) { return }
        if (symbol == " ") {
            fillLine(target.y, target.x, target.width, style: style)
            return
        }

        let symbolWidth = graphemeDisplayWidth(symbol)
        if (symbolWidth <= 0) { return }
        if (symbolWidth == 1) {
            for (cx in target.x..target.right) {
                setCell(cx, target.y, Cell(symbol, style: style))
            }
            return
        }

        var cx = target.x
        while (cx + symbolWidth <= target.right) {
            setString(cx, target.y, symbol, style: style)
            cx += symbolWidth
        }
    }

    public func hline(x: Int64, y: Int64, width: Int64, style!: Style = Style.default()): Unit {
        hline(x, y, width, "-", style)
    }

    public func vline(x: Int64, y: Int64, height: Int64, symbol: String, style: Style): Unit {
        if (height <= 0 || symbol == "") { return }
        let target = intersect(this.area, Rect(x, y, 1, height))
        if (target.height <= 0) { return }
        if (symbol == " ") {
            fill(target, style: style)
            return
        }

        let symbolWidth = graphemeDisplayWidth(symbol)
        if (symbolWidth <= 0) { return }
        if (symbolWidth == 1) {
            for (cy in target.y..target.bottom) {
                setCell(target.x, cy, Cell(symbol, style: style))
            }
            return
        }

        if (target.x + symbolWidth > this.area.right) { return }
        for (cy in target.y..target.bottom) {
            setString(target.x, cy, symbol, style: style)
        }
    }

    public func vline(x: Int64, y: Int64, height: Int64, style!: Style = Style.default()): Unit {
        vline(x, y, height, "|", style)
    }

    public func writeAsciiSpan(x: Int64, y: Int64, text: String, style!: Style = Style.default()): Bool {
        let bytes = unsafe { text.rawData() }
        if (!isPrintableAscii(bytes)) {
            return false
        }
        writeAsciiSpanUnchecked(x, y, text, style: style)
        true
    }

    public func writeAsciiSpanUnchecked(x: Int64, y: Int64, text: String, style!: Style = Style.default()): Unit {
        let bytes = unsafe { text.rawData() }
        setAsciiString(x, y, bytes, style)
    }

    func fillRect(area: Rect, style!: Style = Style.default()): Unit {
        fill(area, style: style)
    }

    public func setString(x: Int64, y: Int64, text: String, style!: Style = Style.default()): Unit {
        let _ = writeString(x, y, text, 0, false, style)
    }

    func writeStringClipped(
        x: Int64,
        y: Int64,
        text: String,
        maxWidth!: Int64,
        style!: Style = Style.default()
    ): Int64 {
        writeString(x, y, text, maxWidth, true, style)
    }

    private func writeString(
        x: Int64,
        y: Int64,
        text: String,
        maxWidth: Int64,
        bounded: Bool,
        style: Style
    ): Int64 {
        if (text.isEmpty() || (bounded && maxWidth <= 0) || (!bounded && x >= area.right)) {
            return 0
        }
        let bytes = unsafe { text.rawData() }
        if (isPrintableAscii(bytes)) {
            let count = if (bounded) { min(bytes.size, maxWidth) } else { bytes.size }
            setAsciiRange(x, y, bytes, 0, count, style)
            return count
        }

        var cx = x
        var consumed: Int64 = 0
        var offset: Int64 = 0
        while (offset < bytes.size &&
               ((bounded && consumed < maxWidth) || (!bounded && cx < area.right))) {
            // Unicode UI chrome commonly prefixes an otherwise ASCII line
            // (for example `╭─ ✓ Run cargo test`).  Running the full
            // grapheme-break state machine for every trailing ASCII byte is
            // needlessly expensive while scrolling.  Flush printable ASCII
            // runs in bulk, retaining the last byte before a Unicode code
            // point so an ASCII base plus a combining mark still forms one
            // grapheme cluster.
            if (bytes[offset] >= 0x20u8 && bytes[offset] < 0x7Fu8) {
                var runEnd = offset + 1
                while (runEnd < bytes.size &&
                       bytes[runEnd] >= 0x20u8 && bytes[runEnd] < 0x7Fu8) {
                    runEnd++
                }
                let safeEnd = if (runEnd < bytes.size) {
                    max(offset, runEnd - 1)
                } else {
                    runEnd
                }
                if (safeEnd > offset) {
                    let available = safeEnd - offset
                    let asciiCount = if (bounded) {
                        min(available, maxWidth - consumed)
                    } else {
                        available
                    }
                    let asciiEnd = offset + asciiCount
                    setAsciiRange(cx, y, bytes, offset, asciiEnd, style)
                    consumed += asciiCount
                    cx = advanceCoordinate(cx, asciiCount)
                    offset = asciiEnd
                    continue
                }
            }
            let next = nextGraphemeOffset(text, offset)
            let symbol = text[offset..next]
            let width = graphemeDisplayWidth(symbol)
            if (width > 0) {
                if (bounded && width > maxWidth - consumed) {
                    break
                }
                let fitsPhysical = cx < area.right && (width != 2 || cx + 1 < area.right)
                if (!bounded && width == 2 && !fitsPhysical) {
                    break
                }
                let writableGroup = isWritable(cx, y) && (width != 2 || isWritable(cx + 1, y))
                if (fitsPhysical && writableGroup) {
                    setCell(cx, y, Cell(symbol, style: style, kind: if (width == 2) { CellKind.WideLead } else { CellKind.Normal }))
                    if (width == 2) {
                        setCellRaw(cx + 1, y, Cell("", style: style, kind: CellKind.WideCont))
                    }
                }
                consumed += width
                cx = advanceCoordinate(cx, width)
            }
            offset = next
        }
        consumed
    }

    private func advanceCoordinate(value: Int64, amount: Int64): Int64 {
        if (amount > 0 && value > Int64.Max - amount) { return Int64.Max }
        value + amount
    }

    private func setAsciiString(x: Int64, y: Int64, bytes: Array<UInt8>, style: Style): Unit {
        setAsciiRange(x, y, bytes, 0, bytes.size, style)
    }

    private func setAsciiRange(
        x: Int64,
        y: Int64,
        bytes: Array<UInt8>,
        start: Int64,
        end: Int64,
        style: Style
    ): Unit {
        var cx = x
        var offset = start
        while (offset < end && cx < area.right) {
            setCell(cx, y, Cell(asciiByteToString(bytes[offset]), style: style))
            cx++
            offset++
        }
    }

    public func resize(area: Rect): Buffer {
        let next = Buffer(area)
        let right = min(this.area.right, area.right)
        let bottom = min(this.area.bottom, area.bottom)
        for (y in area.y..bottom) {
            for (x in area.x..right) {
                next.setCell(x, y, getCell(x, y))
            }
        }
        next
    }

    public func copy(): Buffer {
        let next = Buffer(area)
        for (y in area.y..area.bottom) {
            for (x in area.x..area.right) {
                next.setCell(x, y, getCell(x, y))
            }
        }
        for (placement in media) {
            next.addMedia(placement)
        }
        next
    }

    // Copy a rectangular cell region without re-running grapheme and wide-cell
    // normalization for every destination cell.  Both buffers already contain
    // normalized terminal cells; clipping is resolved once per row.
    public func blitFrom(source: Buffer, sourceArea: Rect, targetX: Int64, targetY: Int64): Unit {
        blitCells(source, sourceArea, targetX, targetY, true)
    }

    // Fast path for a caller that has already constrained the destination to
    // the frame's active dirty rectangle.
    public func blitFromUnchecked(source: Buffer, sourceArea: Rect, targetX: Int64, targetY: Int64): Unit {
        blitCells(source, sourceArea, targetX, targetY, false)
    }

    private func blitCells(source: Buffer, sourceArea: Rect, targetX: Int64, targetY: Int64, respectClip: Bool): Unit {
        let sourceClip = intersect(source.area, sourceArea)
        if (sourceClip.width <= 0 || sourceClip.height <= 0) { return }
        if (!respectClip && targetX >= area.x && targetY >= area.y &&
            targetX + sourceClip.width <= area.right && targetY + sourceClip.height <= area.bottom) {
            for (row in 0..sourceClip.height) {
                let sourceIndex = (sourceClip.y + row - source.area.y) * source.area.width +
                    (sourceClip.x - source.area.x)
                let destinationIndex = (targetY + row - area.y) * area.width + (targetX - area.x)
                source.cells.copyTo(cells, sourceIndex, destinationIndex, sourceClip.width)
            }
            return
        }
        for (row in 0..sourceClip.height) {
            let destinationY = targetY + row
            if (destinationY < area.y || destinationY >= area.bottom) { continue }
            for (column in 0..sourceClip.width) {
                let destinationX = targetX + column
                if (destinationX < area.x || destinationX >= area.right ||
                    (respectClip && !isWritable(destinationX, destinationY))) {
                    continue
                }
                let sourceIndex = (sourceClip.y + row - source.area.y) * source.area.width +
                    (sourceClip.x + column - source.area.x)
                let destinationIndex = (destinationY - area.y) * area.width + (destinationX - area.x)
                cells[destinationIndex] = source.cells[sourceIndex]
            }
        }
    }

    public func diff(previous: Buffer): Array<DrawOp> {
        let ops = ArrayList<DrawOp>()
        for (y in area.y..area.bottom) {
            for (x in area.x..area.right) {
                let cell = getCell(x, y)
                if (previous.area != area || previous.getCell(x, y) != cell) {
                    ops.add(DrawOp(x, y, cell))
                }
            }
        }
        ops.toArray()
    }

    public func addMedia(placement: MediaPlacement): Unit {
        media.add(placement)
    }

    public func mediaPlacements(): Array<MediaPlacement> {
        media.toArray()
    }

    private func isWritable(x: Int64, y: Int64): Bool {
        match (writeClip) {
            case Some(clip) => clip.intersectsCell(x, y)
            case None => true
        }
    }
}

func sameCellKind(left: CellKind, right: CellKind): Bool {
    match (left) {
        case CellKind.Normal =>
            match (right) {
                case CellKind.Normal => true
                case _ => false
            }
        case CellKind.WideLead =>
            match (right) {
                case CellKind.WideLead => true
                case _ => false
            }
        case CellKind.WideCont =>
            match (right) {
                case CellKind.WideCont => true
                case _ => false
            }
    }
}

func isWideContinuation(cell: Cell): Bool {
    match (cell.kind) {
        case CellKind.WideCont => true
        case _ => cell.symbol == ""
    }
}

func isSingleWidthNormal(cell: Cell): Bool {
    match (cell.kind) {
        case CellKind.Normal => cell.symbol != "" && graphemeDisplayWidth(cell.symbol) == 1
        case _ => false
    }
}

func isPrintableAscii(bytes: Array<UInt8>): Bool {
    for (byte in bytes) {
        if (byte < 0x20 || byte > 0x7E) {
            return false
        }
    }
    true
}

func asciiByteToString(byte: UInt8): String {
    unsafe { String.fromUtf8Unchecked([byte]) }
}

public struct DrawOp {
    public let x: Int64
    public let y: Int64
    public let cell: Cell

    public init(x: Int64, y: Int64, cell: Cell) {
        this.x = x
        this.y = y
        this.cell = cell
    }
}
