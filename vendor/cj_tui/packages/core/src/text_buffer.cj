package core

import std.collection.*

public interface Clipboard {
    func getText(): String
    func setText(text: String): Unit
}

public class MemoryClipboard <: Clipboard {
    private var textValue: String = ""

    public init(text!: String = "") {
        this.textValue = text
    }

    public func getText(): String {
        textValue
    }

    public func setText(text: String): Unit {
        textValue = text
    }
}

public struct TextPosition <: Equatable<TextPosition> {
    public let line: Int64
    public let column: Int64

    public init(line: Int64, column: Int64) {
        this.line = max(0, line)
        this.column = max(0, column)
    }

    public operator func ==(other: TextPosition): Bool {
        line == other.line && column == other.column
    }
}

public struct TextRange {
    public let start: TextPosition
    public let end: TextPosition

    public init(start: TextPosition, end: TextPosition) {
        if (compareTextPosition(start, end) <= 0) {
            this.start = start
            this.end = end
        } else {
            this.start = end
            this.end = start
        }
    }

    public func isEmpty(): Bool {
        start == end
    }
}

public class TextBuffer {
    private let lines = ArrayList<String>()
    private let undoStack = ArrayList<String>()
    private let redoStack = ArrayList<String>()
    private var grouping: Bool = false
    private var groupSnapshot: ?String = None

    public init(text!: String = "") {
        setText(text)
    }

    public func setText(text: String): Unit {
        while (lines.size > 0) { lines.remove(at: 0) }
        for (line in splitLines(text)) {
            lines.add(line)
        }
        if (lines.size == 0) { lines.add("") }
    }

    public func text(): String {
        join(lines.toArray(), "\n")
    }

    public func lineCount(): Int64 {
        lines.size
    }

    public func line(index: Int64): String {
        if (index < 0 || index >= lines.size) { return "" }
        lines[index]
    }

    public func insert(position: TextPosition, text: String): TextPosition {
        snapshot()
        let pos = insertRaw(clampPosition(position), text)
        clearRedo()
        pos
    }

    public func replace(range: TextRange, text: String): TextPosition {
        snapshot()
        let start = deleteRangeRaw(range)
        let pos = insertRaw(start, text)
        clearRedo()
        pos
    }

    public func deleteRange(range: TextRange): TextPosition {
        snapshot()
        let pos = deleteRangeRaw(range)
        clearRedo()
        pos
    }

    public func slice(range: TextRange): String {
        let r = normalizedRange(range)
        if (r.isEmpty()) { return "" }
        if (r.start.line == r.end.line) {
            let line = lines[r.start.line]
            return line[r.start.column..r.end.column]
        }
        let out = ArrayList<String>()
        out.add(lines[r.start.line][r.start.column..])
        var line = r.start.line + 1
        while (line < r.end.line) {
            out.add(lines[line])
            line++
        }
        out.add(lines[r.end.line][..r.end.column])
        join(out.toArray(), "\n")
    }

    public func wordLeft(position: TextPosition): TextPosition {
        let offset = absoluteOffset(clampPosition(position))
        TextPositionFromOffset(previousWordOffset(text(), offset))
    }

    public func wordRight(position: TextPosition): TextPosition {
        let offset = absoluteOffset(clampPosition(position))
        TextPositionFromOffset(nextWordOffset(text(), offset))
    }

    public func findPrevious(needle: String, start!: TextPosition = TextPosition(Int64.Max, Int64.Max)): ?TextPosition {
        if (needle.isEmpty()) { return None }
        let endOffset = min(absoluteOffset(clampPosition(start)), text().size)
        let idx = stringLastIndexOf(text(), needle, endOffset)
        if (idx < 0) { return None }
        Some(TextPositionFromOffset(idx))
    }

    public func findAll(needle: String): Array<TextRange> {
        let ranges = ArrayList<TextRange>()
        if (needle.isEmpty()) { return [] }
        let source = text()
        var offset: Int64 = 0
        while (offset <= source.size) {
            let idx = stringIndexOf(source, needle, offset)
            if (idx < 0) { break }
            ranges.add(TextRange(TextPositionFromOffset(idx), TextPositionFromOffset(idx + needle.size)))
            offset = idx + max(1, needle.size)
        }
        ranges.toArray()
    }

    public func replaceAll(needle: String, replacement: String): Int64 {
        if (needle.isEmpty()) { return 0 }
        let source = text()
        var offset: Int64 = 0
        var count: Int64 = 0
        var out = ""
        while (offset <= source.size) {
            let idx = stringIndexOf(source, needle, offset)
            if (idx < 0) {
                out += source[offset..]
                break
            }
            out += source[offset..idx] + replacement
            offset = idx + needle.size
            count++
        }
        if (count > 0) {
            snapshot()
            setText(out)
            clearRedo()
        }
        count
    }

    public func beginUndoGroup(): Unit {
        if (!grouping) {
            grouping = true
            groupSnapshot = Some(text())
        }
    }

    public func endUndoGroup(): Unit {
        if (!grouping) { return }
        match (groupSnapshot) {
            case Some(before) =>
                if (before != text()) {
                    undoStack.add(before)
                    clearRedo()
                }
            case None => ()
        }
        grouping = false
        groupSnapshot = None
    }

    public func positionToOffset(position: TextPosition): Int64 {
        absoluteOffset(clampPosition(position))
    }

    public func offsetToPosition(offset: Int64): TextPosition {
        TextPositionFromOffset(offset)
    }

    private func insertRaw(position: TextPosition, text: String): TextPosition {
        var pos = position
        for (r in unsafe { text.rawData() }) {
            _ = r
        }
        let bytes = unsafe { text.rawData() }
        var offset: Int64 = 0
        while (offset < bytes.size) {
            let (r, len) = Rune.fromUtf8(bytes, offset)
            if (r == r'\n') {
                pos = newline(pos)
            } else {
                let current = lines[pos.line]
                lines[pos.line] = current[..pos.column] + runeToString(r) + current[pos.column..]
                pos = TextPosition(pos.line, pos.column + len)
            }
            offset += len
        }
        pos
    }

    public func deleteBackward(position: TextPosition): TextPosition {
        snapshot()
        let pos = clampPosition(position)
        if (pos.line == 0 && pos.column == 0) { return pos }
        clearRedo()
        if (pos.column > 0) {
            let current = lines[pos.line]
            let prev = previousRuneOffset(current, pos.column)
            lines[pos.line] = current[..prev] + current[pos.column..]
            return TextPosition(pos.line, prev)
        }
        let previous = lines[pos.line - 1]
        let current = lines[pos.line]
        let nextColumn = previous.size
        lines[pos.line - 1] = previous + current
        lines.remove(at: pos.line)
        TextPosition(pos.line - 1, nextColumn)
    }

    public func deleteForward(position: TextPosition): TextPosition {
        snapshot()
        let pos = clampPosition(position)
        let current = lines[pos.line]
        if (pos.column < current.size) {
            let next = nextRuneOffset(current, pos.column)
            lines[pos.line] = current[..pos.column] + current[next..]
        } else if (pos.line + 1 < lines.size) {
            lines[pos.line] = current + lines[pos.line + 1]
            lines.remove(at: pos.line + 1)
        }
        clearRedo()
        pos
    }

    public func undo(): Bool {
        if (undoStack.size == 0) { return false }
        redoStack.add(text())
        let previous = undoStack[undoStack.size - 1]
        undoStack.remove(at: undoStack.size - 1)
        setText(previous)
        true
    }

    public func redo(): Bool {
        if (redoStack.size == 0) { return false }
        undoStack.add(text())
        let next = redoStack[redoStack.size - 1]
        redoStack.remove(at: redoStack.size - 1)
        setText(next)
        true
    }

    public func find(needle: String, start!: TextPosition = TextPosition(0, 0)): ?TextPosition {
        if (needle.isEmpty()) { return None }
        var lineIndex = clamp(start.line, 0, max(0, lines.size - 1))
        while (lineIndex < lines.size) {
            let begin = if (lineIndex == start.line) { start.column } else { 0 }
            let idx = stringIndexOf(lines[lineIndex], needle, begin)
            if (idx >= 0) { return Some(TextPosition(lineIndex, idx)) }
            lineIndex++
        }
        None
    }

    public func clampPosition(position: TextPosition): TextPosition {
        let line = clamp(position.line, 0, max(0, lines.size - 1))
        TextPosition(line, clampToRuneBoundary(lines[line], position.column))
    }

    private func newline(position: TextPosition): TextPosition {
        let current = lines[position.line]
        let before = current[..position.column]
        let after = current[position.column..]
        lines[position.line] = before
        lines.add(after)
        var i = lines.size - 1
        while (i > position.line + 1) {
            lines[i] = lines[i - 1]
            i--
        }
        lines[position.line + 1] = after
        TextPosition(position.line + 1, 0)
    }

    private func deleteRangeRaw(range: TextRange): TextPosition {
        let r = normalizedRange(range)
        if (r.isEmpty()) { return r.start }
        if (r.start.line == r.end.line) {
            let line = lines[r.start.line]
            lines[r.start.line] = line[..r.start.column] + line[r.end.column..]
            return r.start
        }
        let first = lines[r.start.line][..r.start.column]
        let last = lines[r.end.line][r.end.column..]
        lines[r.start.line] = first + last
        var remaining = r.end.line - r.start.line
        while (remaining > 0 && r.start.line + 1 < lines.size) {
            lines.remove(at: r.start.line + 1)
            remaining--
        }
        r.start
    }

    private func normalizedRange(range: TextRange): TextRange {
        TextRange(clampPosition(range.start), clampPosition(range.end))
    }

    private func absoluteOffset(position: TextPosition): Int64 {
        var offset: Int64 = 0
        var line: Int64 = 0
        while (line < position.line && line < lines.size) {
            offset += lines[line].size + 1
            line++
        }
        offset + position.column
    }

    private func TextPositionFromOffset(offset: Int64): TextPosition {
        var rest = clamp(offset, 0, text().size)
        for (line in 0..lines.size) {
            if (rest <= lines[line].size) {
                return TextPosition(line, clampToRuneBoundary(lines[line], rest))
            }
            rest -= lines[line].size + 1
        }
        TextPosition(lines.size - 1, lines[lines.size - 1].size)
    }

    private func snapshot(): Unit {
        if (grouping) {
            match (groupSnapshot) {
                case Some(_) => ()
                case None => groupSnapshot = Some(text())
            }
        } else {
            undoStack.add(text())
        }
    }

    private func clearRedo(): Unit {
        while (redoStack.size > 0) { redoStack.remove(at: 0) }
    }
}

func compareTextPosition(a: TextPosition, b: TextPosition): Int64 {
    if (a.line < b.line) { return -1 }
    if (a.line > b.line) { return 1 }
    if (a.column < b.column) { return -1 }
    if (a.column > b.column) { return 1 }
    0
}

func stringIndexOf(text: String, needle: String, start: Int64): Int64 {
    let hay = unsafe { text.rawData() }
    let ned = unsafe { needle.rawData() }
    if (ned.size == 0) { return start }
    var i = clamp(start, 0, text.size)
    while (i + ned.size <= hay.size) {
        var ok = true
        for (j in 0..ned.size) {
            if (hay[i + j] != ned[j]) { ok = false }
        }
        if (ok) { return i }
        i++
    }
    -1
}

func stringLastIndexOf(text: String, needle: String, end: Int64): Int64 {
    let hay = unsafe { text.rawData() }
    let ned = unsafe { needle.rawData() }
    if (ned.size == 0) { return end }
    var i = min(clamp(end, 0, text.size), text.size - ned.size)
    while (i >= 0) {
        var ok = true
        for (j in 0..ned.size) {
            if (hay[i + j] != ned[j]) { ok = false }
        }
        if (ok) { return i }
        i--
    }
    -1
}

func previousWordOffset(text: String, offset: Int64): Int64 {
    var pos = previousRuneOffset(text, offset)
    while (pos > 0 && isAsciiSpace(runeAt(text, pos))) {
        pos = previousRuneOffset(text, pos)
    }
    while (pos > 0) {
        let prev = previousRuneOffset(text, pos)
        if (isAsciiSpace(runeAt(text, prev))) { return pos }
        pos = prev
    }
    0
}

func nextWordOffset(text: String, offset: Int64): Int64 {
    var pos = nextRuneOffset(text, offset)
    while (pos < text.size && !isAsciiSpace(runeAt(text, pos))) {
        pos = nextRuneOffset(text, pos)
    }
    while (pos < text.size && isAsciiSpace(runeAt(text, pos))) {
        pos = nextRuneOffset(text, pos)
    }
    pos
}

func runeAt(text: String, offset: Int64): Rune {
    if (text.isEmpty()) { return r'\0' }
    let target = clampToRuneBoundary(text, offset)
    let bytes = unsafe { text.rawData() }
    let (r, _) = Rune.fromUtf8(bytes, target)
    r
}

func isAsciiSpace(r: Rune): Bool {
    r == r' ' || r == r'\t' || r == r'\n' || r == r'\r'
}
