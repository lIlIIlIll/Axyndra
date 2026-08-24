package core

import std.collection.*

class TextAreaSnapshot {
    let value: String
    let cursor: Int64
    let scroll: Int64
    let selectionStart: ?Int64
    let selectionEnd: ?Int64
    let extraCarets: Array<TextAreaCaret>

    init(value: String, cursor: Int64, scroll: Int64, selectionStart: ?Int64, selectionEnd: ?Int64, extraCarets: Array<TextAreaCaret>) {
        this.value = value
        this.cursor = cursor
        this.scroll = scroll
        this.selectionStart = selectionStart
        this.selectionEnd = selectionEnd
        this.extraCarets = extraCarets
    }
}

class TextAreaEdit {
    let start: Int64
    let end: Int64
    let text: String

    init(start: Int64, end: Int64, text: String) {
        this.start = start
        this.end = max(start, end)
        this.text = text
    }
}

public class TextAreaCaret {
    public let offset: Int64
    public let anchor: ?Int64

    public init(offset: Int64, anchor!: ?Int64 = None) {
        this.offset = max(0, offset)
        this.anchor = anchor
    }
}

public class TextCompletionRequest {
    public let requestId: String
    public let revision: Int64
    public let value: String
    public let cursor: Int64
    public let prefixStart: Int64
    public let prefixEnd: Int64
    public let prefix: String
    public let line: Int64
    public let column: Int64

    public init(requestId: String, revision: Int64, value: String, cursor: Int64, prefixStart: Int64, prefixEnd: Int64, prefix: String, line: Int64, column: Int64) {
        this.requestId = requestId
        this.revision = revision
        this.value = value
        this.cursor = cursor
        this.prefixStart = prefixStart
        this.prefixEnd = prefixEnd
        this.prefix = prefix
        this.line = line
        this.column = column
    }
}

public class TextCompletionItem {
    public let label: String
    public let insertText: String
    public let detail: String

    public init(label: String, insertText!: String = "", detail!: String = "") {
        this.label = label
        this.insertText = if (insertText.isEmpty()) { label } else { insertText }
        this.detail = detail
    }
}

public class TextCompletionResult {
    public let requestId: String
    public let revision: Int64
    public let replaceStart: Int64
    public let replaceEnd: Int64
    public let items: Array<TextCompletionItem>

    public init(requestId: String, revision: Int64, replaceStart: Int64, replaceEnd: Int64, items: Array<TextCompletionItem>) {
        this.requestId = requestId
        this.revision = revision
        this.replaceStart = max(0, replaceStart)
        this.replaceEnd = max(this.replaceStart, replaceEnd)
        this.items = items
    }
}

public class TextDecoration {
    public let start: Int64
    public let end: Int64
    public let style: Style

    public init(start: Int64, end: Int64, style: Style) {
        this.start = max(0, start)
        this.end = max(this.start, end)
        this.style = style
    }
}

public type HighlightSpan = TextDecoration

public class LineHighlight {
    public let line: Int64
    public let spans: Array<TextDecoration>

    public init(line: Int64, spans: Array<TextDecoration>) {
        this.line = max(0, line)
        this.spans = spans
    }
}

public class MarkdownHighlightCache {
    private var cachedText: String = ""
    private var cachedSpans: Array<TextDecoration> = []
    private var cachedLines: Array<LineHighlight> = []
    private var recomputes: Int64 = 0

    public init() {}

    public func highlights(text: String): Array<TextDecoration> {
        if (text == cachedText) { return cachedSpans }
        cachedText = text
        cachedSpans = markdownDecorations(text)
        cachedLines = markdownLineHighlights(text)
        recomputes++
        cachedSpans
    }

    public func lineHighlights(text: String): Array<LineHighlight> {
        if (text != cachedText) { _ = highlights(text) }
        cachedLines
    }

    public func visibleHighlights(text: String, firstLine!: Int64 = 0, lineCount!: Int64 = 40): Array<TextDecoration> {
        let lines = lineHighlights(text)
        let offsets = lineStartOffsets(text)
        let out = ArrayList<TextDecoration>()
        let startLine = clamp(firstLine, 0, max(0, lines.size - 1))
        let endLine = min(lines.size, startLine + max(0, lineCount))
        for (lineIndex in startLine..endLine) {
            let lineOffset = offsets[lineIndex]
            for (span in lines[lineIndex].spans) {
                out.add(TextDecoration(lineOffset + span.start, lineOffset + span.end, span.style))
            }
        }
        out.toArray()
    }

    public func recomputeCount(): Int64 {
        recomputes
    }

    public func invalidate(): Unit {
        cachedText = ""
        cachedSpans = []
        cachedLines = []
    }
}

public class TextArea <: Widget {
    public var value: String
    public var cursor: Int64
    public var scroll: Int64
    public var selectionStart: ?Int64 = None
    public var selectionEnd: ?Int64 = None
    private let block: ?Block
    private let style: Style
    private let selectedStyle: Style
    private let placeholder: String
    private let placeholderStyle: Style
    private let lineNumbers: Bool
    private let lineNumberStyle: Style
    private let foldState: ?DocumentViewState
    public var readOnly: Bool
    public var markdownEditing: Bool
    private var decorations: Array<TextDecoration>
    private let undoStack = ArrayList<TextAreaSnapshot>()
    private let redoStack = ArrayList<TextAreaSnapshot>()
    private var extraCarets: Array<TextAreaCaret> = []
    private var dragAnchor: ?Int64 = None
    private var revision: Int64 = 0
    private var completionRequestId: String = ""
    private var completionRevision: Int64 = -1
    private var completionReplaceStart: Int64 = 0
    private var completionReplaceEnd: Int64 = 0
    private var completionItems: Array<TextCompletionItem> = []
    private var completionIndex: Int64 = 0
    private var completionOpen: Bool = false
    private var cachedLineRevision: Int64 = -1
    private var cachedLineTextSize: Int64 = -1
    private var cachedLineFirstByte: UInt8 = 0u8
    private var cachedLineLastByte: UInt8 = 0u8
    private var cachedLines: Array<String> = []
    private var cachedLineOffsets: Array<Int64> = []
    private var cachedVisibleLines: Array<Int64> = []
    private var cachedLineRebuilds: Int64 = 0

    public init(
        value!: String = "",
        cursor!: Int64 = 0,
        scroll!: Int64 = 0,
        block!: ?Block = None,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White),
        placeholder!: String = "",
        placeholderStyle!: Style = Style(fg: Color.Indexed(8)),
        lineNumbers!: Bool = false,
        lineNumberStyle!: Style = Style(fg: Color.Indexed(8)),
        foldState!: ?DocumentViewState = None,
        readOnly!: Bool = false,
        markdownEditing!: Bool = false,
        decorations!: Array<TextDecoration> = []
    ) {
        this.value = value
        this.cursor = clampToRuneBoundary(value, cursor)
        this.scroll = max(0, scroll)
        this.block = block
        this.style = style
        this.selectedStyle = selectedStyle
        this.placeholder = placeholder
        this.placeholderStyle = placeholderStyle
        this.lineNumbers = lineNumbers
        this.lineNumberStyle = lineNumberStyle
        this.foldState = foldState
        this.readOnly = readOnly
        this.markdownEditing = markdownEditing
        this.decorations = decorations
    }

    public func handle(key: KeyEvent): Bool {
        if (completionOpen && handleCompletionKey(key)) { return true }
        match (key.code) {
            case Char(r) =>
                if (key.modifiers.ctrl && r == r'a') {
                    cursor = lineStartForOffset(cursor)
                    clearSelection()
                    true
                } else if (key.modifiers.ctrl && r == r'b') {
                    cursor = previousRuneOffset(value, cursor)
                    clearSelection()
                    true
                } else if (key.modifiers.ctrl && r == r'e') {
                    cursor = lineEnd(value, cursor)
                    clearSelection()
                    true
                } else if (key.modifiers.ctrl && r == r'f') {
                    cursor = nextRuneOffset(value, cursor)
                    clearSelection()
                    true
                } else if (key.modifiers.ctrl && r == r'k') {
                    if (readOnly) { false } else { deleteToLineEnd(); true }
                } else if (key.modifiers.ctrl && r == r'u') {
                    if (readOnly) { false } else { deleteToLineStart(); true }
                } else if (key.modifiers.ctrl && r == r'w') {
                    if (readOnly) { false } else { deletePreviousWord(); true }
                } else if (key.modifiers.ctrl && r == r'z') {
                    _ = undo()
                    true
                } else if (key.modifiers.ctrl && r == r'y') {
                    _ = redo()
                    true
                } else if (key.modifiers.ctrl) {
                    false
                } else if (!readOnly) {
                    replaceSelectionOrInsert(runeToString(r))
                    true
                } else {
                    false
                }
            case Enter =>
                if (readOnly) { false } else {
                    if (markdownEditing && finishEmptyMarkdownListItem()) {
                        true
                    } else {
                        replaceSelectionOrInsert(if (markdownEditing) { markdownEnterText() } else { "\n" })
                        true
                    }
                }
            case Backspace =>
                if (readOnly) { return false }
                if (hasSelection()) { deleteSelection() } else { backspace() }
                true
            case Delete =>
                if (readOnly) { return false }
                if (hasSelection()) { deleteSelection() } else { deleteForward() }
                true
            case Tab =>
                if (readOnly) { false } else { indentSelectedLines(); true }
            case BackTab =>
                if (readOnly) { false } else { outdentSelectedLines(); true }
            case Left =>
                cursor = if (key.modifiers.ctrl) { previousWordOffset(value, cursor) } else { previousRuneOffset(value, cursor) }
                clearSelection()
                true
            case Right =>
                cursor = if (key.modifiers.ctrl) { nextWordOffset(value, cursor) } else { nextRuneOffset(value, cursor) }
                clearSelection()
                true
            case Up =>
                moveVertical(-1)
                clearSelection()
                true
            case Down =>
                moveVertical(1)
                clearSelection()
                true
            case PageUp =>
                moveVertical(-5)
                clearSelection()
                true
            case PageDown =>
                moveVertical(5)
                clearSelection()
                true
            case Home =>
                cursor = if (key.modifiers.ctrl) { 0 } else { lineStartForOffset(cursor) }
                clearSelection()
                true
            case End =>
                cursor = if (key.modifiers.ctrl) { value.size } else { lineEnd(value, cursor) }
                clearSelection()
                true
            case _ => false
        }
    }

    public func handleWithDirty(key: KeyEvent, area: Rect): ?DirtyRects {
        let beforeScroll = scroll
        let beforeCursor = cursor
        let beforeValueSize = value.size
        if (!handle(key)) { return None }
        let dirty = DirtyRects()
        let pageMove = match (key.code) {
            case KeyCode.PageUp | KeyCode.PageDown => true
            case _ => false
        }
        if (beforeScroll != scroll || value.size != beforeValueSize || pageMove) {
            dirty.add(area)
            return Some(dirty)
        }
        let row = visibleRowForOffset(beforeCursor)
        if (row >= 0 && row < area.height) {
            dirty.add(Rect(area.x, area.y + row, area.width, 1))
        } else {
            dirty.add(area)
        }
        Some(dirty)
    }

    public func handleVimNavigation(key: KeyEvent): Bool {
        match (key.code) {
            case Char(r'h') => handle(KeyEvent(KeyCode.Left, modifiers: key.modifiers))
            case Char(r'j') => handle(KeyEvent(KeyCode.Down, modifiers: key.modifiers))
            case Char(r'k') => handle(KeyEvent(KeyCode.Up, modifiers: key.modifiers))
            case Char(r'l') => handle(KeyEvent(KeyCode.Right, modifiers: key.modifiers))
            case Char(r'w') =>
                moveWordRight()
                true
            case Char(r'b') =>
                moveWordLeft()
                true
            case Char(r'0') => handle(KeyEvent(KeyCode.Home, modifiers: key.modifiers))
            case Char(r'$') => handle(KeyEvent(KeyCode.End, modifiers: key.modifiers))
            case Char(r'G') => handle(KeyEvent(KeyCode.End, modifiers: KeyModifier(ctrl: true)))
            case _ => false
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        let lines = linesForRender()
        let gutter = if (lineNumbers) { min(6, max(3, decimalDigits(lines.size) + 1)) } else { 0 }
        let textTarget = Rect(target.x + gutter, target.y, max(0, target.width - gutter), target.height)
        if (value.isEmpty() && !placeholder.isEmpty()) {
            buffer.setString(textTarget.x, textTarget.y, truncate(placeholder, textTarget.width), style: placeholderStyle)
            return
        }
        let visible = visibleLineIndexes()
        ensureCursorVisible(textTarget.height)
        for (row in 0..textTarget.height) {
            let visibleIndex = row + scroll
            if (visibleIndex >= visible.size) { return }
            let lineIndex = visible[visibleIndex]
            if (lineNumbers) {
                buffer.setString(target.x, target.y + row, truncate("${lineIndex + 1} ", gutter), style: lineNumberStyle)
            }
            renderLine(textTarget.x, textTarget.y + row, textTarget.width, lineIndex, lines[lineIndex], buffer)
            if (lineHasFoldMarker(lineIndex)) {
                buffer.setString(max(textTarget.x, min(textTarget.x + textTarget.width - 3, textTarget.x + displayWidth(lines[lineIndex]) + 1)), textTarget.y + row, "...", style: lineNumberStyle)
            }
        }
        renderCompletion(textTarget, buffer)
    }

    public func cursorPosition(area: Rect): Position {
        var target = area
        if (let Some(b) <- block) {
            target = b.inner(area)
        }
        let gutter = if (lineNumbers) { min(6, max(3, decimalDigits(lineCount()) + 1)) } else { 0 }
        let textTarget = Rect(target.x + gutter, target.y, max(0, target.width - gutter), target.height)
        ensureCursorVisible(textTarget.height)
        let row = visibleRowForLine(lineForOffset(cursor))
        let col = displayWidth(value[lineStartForOffset(cursor)..cursor])
        Position(textTarget.x + min(col, textTarget.width), textTarget.y + clamp(row - scroll, 0, max(0, textTarget.height - 1)))
    }

    public func cursorPositions(area: Rect): Array<Position> {
        let out = ArrayList<Position>()
        out.add(cursorPosition(area))
        let oldCursor = cursor
        let oldStart = selectionStart
        let oldEnd = selectionEnd
        for (caret in extraCarets) {
            cursor = clampToRuneBoundary(value, caret.offset)
            selectionStart = None
            selectionEnd = None
            out.add(cursorPosition(area))
        }
        cursor = oldCursor
        selectionStart = oldStart
        selectionEnd = oldEnd
        out.toArray()
    }

    public func select(start: Int64, end: Int64): Unit {
        selectionStart = Some(clampToRuneBoundary(value, start))
        selectionEnd = Some(clampToRuneBoundary(value, end))
    }

    public func clearSelection(): Unit {
        selectionStart = None
        selectionEnd = None
    }

    public func hasSelection(): Bool {
        match ((selectionStart, selectionEnd)) {
            case (Some(a), Some(b)) => a != b
            case _ => false
        }
    }

    public func selectedText(): String {
        match (selectionBounds()) {
            case Some((start, end)) => value[start..end]
            case None => ""
        }
    }

    public func selectedRange(): ?(Int64, Int64) {
        selectionBounds()
    }

    public func carets(): Array<TextAreaCaret> {
        let out = ArrayList<TextAreaCaret>()
        out.add(primaryCaret())
        for (caret in extraCarets) { out.add(caret) }
        out.toArray()
    }

    public func setCarets(carets: Array<TextAreaCaret>): Unit {
        if (carets.size == 0) {
            cursor = clampToRuneBoundary(value, cursor)
            clearSelection()
            extraCarets = []
            return
        }
        applyPrimaryCaret(carets[0])
        let extras = ArrayList<TextAreaCaret>()
        for (i in 1..carets.size) {
            extras.add(normalizedCaret(carets[i]))
        }
        extraCarets = extras.toArray()
    }

    public func addCaret(caret: TextAreaCaret): Unit {
        let extras = ArrayList<TextAreaCaret>()
        for (item in extraCarets) { extras.add(item) }
        extras.add(normalizedCaret(caret))
        extraCarets = extras.toArray()
    }

    public func clearExtraCarets(): Unit {
        extraCarets = []
    }

    public func selectedTexts(): Array<String> {
        let out = ArrayList<String>()
        for (caret in carets()) {
            match (caretRange(caret)) {
                case Some((start, end)) => out.add(value[start..end])
                case None => ()
            }
        }
        out.toArray()
    }

    public func copySelectionTo(clipboard: Clipboard): Bool {
        if (!hasSelection()) { return false }
        clipboard.setText(selectedText())
        true
    }

    public func cutSelectionTo(clipboard: Clipboard): Bool {
        if (!copySelectionTo(clipboard)) { return false }
        deleteSelection()
        true
    }

    public func pasteFrom(clipboard: Clipboard): Unit {
        paste(clipboard.getText())
    }

    public func deleteSelection(): Unit {
        if (readOnly) { return }
        if (!hasSelection()) { return }
        pushUndoSnapshot()
        deleteSelectionRaw()
        markEdited()
        clearRedo()
    }

    public func paste(text: String): Unit {
        if (readOnly) { return }
        replaceSelectionOrInsert(text)
    }

    public func setDecorations(decorations: Array<TextDecoration>): Unit {
        this.decorations = decorations
    }

    public func setValue(value: String, cursor!: Int64 = -1): Unit {
        this.value = value
        this.cursor = if (cursor < 0) { value.size } else { clampToRuneBoundary(value, cursor) }
        scroll = 0
        clearSelection()
        clearExtraCarets()
        markEdited()
        clearHistory()
    }

    public func editRevision(): Int64 {
        revision
    }

    public func handleMouse(mouse: MouseEvent, area: Rect): Bool {
        match (mouse.button) {
            case MouseButton.Left => ()
            case _ => return false
        }
        match (mouse.kind) {
            case MouseKind.Down =>
                match (offsetForMouse(mouse, area)) {
                    case Some(offset) =>
                        cursor = offset
                        clearSelection()
                        clearExtraCarets()
                        dragAnchor = Some(offset)
                        true
                    case None => false
                }
            case MouseKind.Drag =>
                match (offsetForMouse(mouse, area)) {
                    case Some(offset) =>
                        let anchor = match (dragAnchor) {
                            case Some(value) => value
                            case None => cursor
                        }
                        cursor = offset
                        select(anchor, offset)
                        true
                    case None => false
                }
            case MouseKind.Up =>
                dragAnchor = None
                true
            case _ => false
        }
    }

    public func beginCompletion(requestId: String): TextCompletionRequest {
        let start = completionPrefixStart(value, cursor)
        let line = lineForOffset(cursor)
        let column = displayWidth(value[lineStartForOffset(cursor)..cursor])
        completionRequestId = requestId
        completionRevision = revision
        completionReplaceStart = start
        completionReplaceEnd = cursor
        TextCompletionRequest(requestId, revision, value, cursor, start, cursor, value[start..cursor], line, column)
    }

    public func completionCommand(requestId: String, provider: (TextCompletionRequest) -> TextCompletionResult): Command {
        let request = beginCompletion(requestId)
        Command.AsyncTask(requestId, { => Event.TextCompletion(requestId, provider(request)) })
    }

    public func handleCompletionEvent(event: Event): Bool {
        match (event) {
            case Event.TextCompletion(_, result) => applyCompletionResult(result)
            case Event.AsyncCompleted(_, inner) =>
                match (inner) {
                    case Event.TextCompletion(_, result) => applyCompletionResult(result)
                    case _ => false
                }
            case _ => false
        }
    }

    public func completionVisible(): Bool {
        completionOpen
    }

    public func cancelCompletion(): Bool {
        if (!completionOpen) { return false }
        completionOpen = false
        completionItems = []
        completionIndex = 0
        true
    }

    public func completionRows(maximum!: Int64 = 5): Int64 {
        if (!completionOpen) { return 0 }
        min(max(0, maximum), completionItems.size)
    }

    public func renderCompletionOverlay(area: Rect, buffer: Buffer): Unit {
        renderCompletion(area, buffer)
    }

    public func clearHistory(): Unit {
        while (undoStack.size > 0) { undoStack.remove(at: 0) }
        clearRedo()
    }

    public func undo(): Bool {
        if (undoStack.size == 0) { return false }
        redoStack.add(snapshot())
        let previous = undoStack[undoStack.size - 1]
        undoStack.remove(at: undoStack.size - 1)
        restoreSnapshot(previous)
        true
    }

    public func redo(): Bool {
        if (redoStack.size == 0) { return false }
        undoStack.add(snapshot())
        let next = redoStack[redoStack.size - 1]
        redoStack.remove(at: redoStack.size - 1)
        restoreSnapshot(next)
        true
    }

    private func deleteSelectionRaw(): Unit {
        match (selectionBounds()) {
            case Some((start, end)) =>
                value = value[..start] + value[end..]
                cursor = start
                clearSelection()
            case None => ()
        }
    }

    public func findNext(needle: String): ?Int64 {
        let idx = stringIndexOf(value, needle, cursor)
        if (idx >= 0) {
            cursor = idx
            select(idx, idx + needle.size)
            return Some(idx)
        }
        None
    }

    public func findPrevious(needle: String): ?Int64 {
        let idx = stringLastIndexOf(value, needle, cursor)
        if (idx >= 0) {
            cursor = idx
            select(idx, idx + needle.size)
            return Some(idx)
        }
        None
    }

    public func moveWordLeft(): Unit {
        cursor = previousWordOffset(value, cursor)
        clearSelection()
    }

    public func moveWordRight(): Unit {
        cursor = nextWordOffset(value, cursor)
        clearSelection()
    }

    private func insert(text: String): Unit {
        value = value[..cursor] + text + value[cursor..]
        cursor += text.size
    }

    private func replaceSelectionOrInsert(text: String): Unit {
        if (extraCarets.size > 0) {
            applyCaretsEdit(text)
            return
        }
        pushUndoSnapshot()
        if (hasSelection()) {
            deleteSelectionRaw()
        }
        insert(text)
        markEdited()
        clearRedo()
    }

    private func backspace(): Unit {
        if (extraCarets.size > 0) {
            applyCaretsBackspace()
            return
        }
        if (cursor <= 0) { return }
        pushUndoSnapshot()
        let prev = previousRuneOffset(value, cursor)
        value = value[..prev] + value[cursor..]
        cursor = prev
        markEdited()
        clearRedo()
    }

    private func deleteForward(): Unit {
        if (extraCarets.size > 0) {
            applyCaretsDeleteForward()
            return
        }
        if (cursor >= value.size) { return }
        pushUndoSnapshot()
        let next = nextRuneOffset(value, cursor)
        value = value[..cursor] + value[next..]
        markEdited()
        clearRedo()
    }

    private func deleteToLineStart(): Unit {
        if (hasSelection()) {
            deleteSelection()
            return
        }
        deleteRange(lineStartForOffset(cursor), cursor)
    }

    private func deleteToLineEnd(): Unit {
        if (hasSelection()) {
            deleteSelection()
            return
        }
        deleteRange(cursor, lineEnd(value, cursor))
    }

    private func deletePreviousWord(): Unit {
        if (hasSelection()) {
            deleteSelection()
            return
        }
        deleteRange(previousWordOffset(value, cursor), cursor)
    }

    private func deleteRange(start: Int64, end: Int64): Unit {
        let from = clampToRuneBoundary(value, min(start, end))
        let to = clampToRuneBoundary(value, max(start, end))
        if (from == to) { return }
        pushUndoSnapshot()
        value = value[..from] + value[to..]
        cursor = from
        clearSelection()
        clearExtraCarets()
        markEdited()
        clearRedo()
    }

    private func snapshot(): TextAreaSnapshot {
        TextAreaSnapshot(value, cursor, scroll, selectionStart, selectionEnd, extraCarets)
    }

    private func pushUndoSnapshot(): Unit {
        undoStack.add(snapshot())
    }

    private func restoreSnapshot(item: TextAreaSnapshot): Unit {
        value = item.value
        cursor = clampToRuneBoundary(value, item.cursor)
        scroll = max(0, item.scroll)
        selectionStart = item.selectionStart
        selectionEnd = item.selectionEnd
        extraCarets = item.extraCarets
        invalidateLineCache()
    }

    private func clearRedo(): Unit {
        while (redoStack.size > 0) { redoStack.remove(at: 0) }
    }

    private func moveVertical(delta: Int64): Unit {
        let line = lineForOffset(cursor)
        let col = displayWidth(value[lineStartForOffset(cursor)..cursor])
        let visible = visibleLineIndexes()
        let row = visibleRowForLine(line)
        let targetVisible = clamp(row + delta, 0, max(0, visible.size - 1))
        let targetLine = if (visible.size == 0) { 0 } else { visible[targetVisible] }
        cursor = offsetAtLineColumn(value, targetLine, col)
    }

    private func ensureCursorVisible(height: Int64): Unit {
        let line = visibleRowForLine(lineForOffset(cursor))
        if (line < scroll) {
            scroll = line
        } else if (height > 0 && line >= scroll + height) {
            scroll = line - height + 1
        }
    }

    private func selectionBounds(): ?(Int64, Int64) {
        match ((selectionStart, selectionEnd)) {
            case (Some(a), Some(b)) =>
                if (a == b) { None } else if (a < b) { Some((a, b)) } else { Some((b, a)) }
            case _ => None
        }
    }

    private func primaryCaret(): TextAreaCaret {
        match ((selectionStart, selectionEnd)) {
            case (Some(anchor), Some(end)) =>
                if (anchor == end) { TextAreaCaret(cursor) } else { TextAreaCaret(cursor, anchor: Some(anchor)) }
            case _ => TextAreaCaret(cursor)
        }
    }

    private func normalizedCaret(caret: TextAreaCaret): TextAreaCaret {
        TextAreaCaret(clampToRuneBoundary(value, caret.offset), anchor: match (caret.anchor) {
            case Some(anchor) => Some(clampToRuneBoundary(value, anchor))
            case None => None
        })
    }

    private func applyPrimaryCaret(caret: TextAreaCaret): Unit {
        let normalized = normalizedCaret(caret)
        cursor = normalized.offset
        match (normalized.anchor) {
            case Some(anchor) => select(anchor, normalized.offset)
            case None => clearSelection()
        }
    }

    private func caretRange(caret: TextAreaCaret): ?(Int64, Int64) {
        let normalized = normalizedCaret(caret)
        match (normalized.anchor) {
            case Some(anchor) =>
                if (anchor == normalized.offset) {
                    None
                } else if (anchor < normalized.offset) {
                    Some((anchor, normalized.offset))
                } else {
                    Some((normalized.offset, anchor))
                }
            case None => None
        }
    }

    private func markEdited(): Unit {
        revision++
        invalidateLineCache()
        completionOpen = false
        completionItems = []
    }

    private func applyCaretsEdit(text: String): Unit {
        let edits = ArrayList<TextAreaEdit>()
        let nextCarets = ArrayList<TextAreaCaret>()
        for (caret in carets()) {
            match (caretRange(caret)) {
                case Some((start, end)) =>
                    edits.add(TextAreaEdit(start, end, text))
                    nextCarets.add(TextAreaCaret(start))
                case None =>
                    let offset = clampToRuneBoundary(value, caret.offset)
                    edits.add(TextAreaEdit(offset, offset, text))
                    nextCarets.add(TextAreaCaret(offset))
            }
        }
        applyEdits(edits.toArray(), nextCarets.toArray())
    }

    private func applyCaretsBackspace(): Unit {
        let edits = ArrayList<TextAreaEdit>()
        let nextCarets = ArrayList<TextAreaCaret>()
        for (caret in carets()) {
            match (caretRange(caret)) {
                case Some((start, end)) =>
                    edits.add(TextAreaEdit(start, end, ""))
                    nextCarets.add(TextAreaCaret(start))
                case None =>
                    let offset = clampToRuneBoundary(value, caret.offset)
                    if (offset > 0) {
                        let prev = previousRuneOffset(value, offset)
                        edits.add(TextAreaEdit(prev, offset, ""))
                        nextCarets.add(TextAreaCaret(prev))
                    } else {
                        nextCarets.add(TextAreaCaret(offset))
                    }
            }
        }
        applyEdits(edits.toArray(), nextCarets.toArray())
    }

    private func applyCaretsDeleteForward(): Unit {
        let edits = ArrayList<TextAreaEdit>()
        let nextCarets = ArrayList<TextAreaCaret>()
        for (caret in carets()) {
            match (caretRange(caret)) {
                case Some((start, end)) =>
                    edits.add(TextAreaEdit(start, end, ""))
                    nextCarets.add(TextAreaCaret(start))
                case None =>
                    let offset = clampToRuneBoundary(value, caret.offset)
                    if (offset < value.size) {
                        let next = nextRuneOffset(value, offset)
                        edits.add(TextAreaEdit(offset, next, ""))
                    }
                    nextCarets.add(TextAreaCaret(offset))
            }
        }
        applyEdits(edits.toArray(), nextCarets.toArray())
    }

    private func applyEdits(items: Array<TextAreaEdit>, nextCarets: Array<TextAreaCaret>): Unit {
        if (items.size == 0) { return }
        pushUndoSnapshot()
        var nextValue = value
        let sorted = sortEditsDescending(items)
        var rightStart = value.size + 1
        for (edit in sorted) {
            if (edit.end > rightStart) { continue }
            nextValue = nextValue[..edit.start] + edit.text + nextValue[edit.end..]
            rightStart = edit.start
        }
        value = nextValue
        setCarets(transformCaretsAfterEdits(nextCarets, sorted))
        markEdited()
        clearRedo()
    }

    private func transformCaretsAfterEdits(carets: Array<TextAreaCaret>, edits: Array<TextAreaEdit>): Array<TextAreaCaret> {
        let out = ArrayList<TextAreaCaret>()
        for (caret in carets) {
            out.add(TextAreaCaret(transformOffsetAfterEdits(caret.offset, edits), anchor: match (caret.anchor) {
                case Some(anchor) => Some(transformOffsetAfterEdits(anchor, edits))
                case None => None
            }))
        }
        out.toArray()
    }

    private func transformOffsetAfterEdits(offset: Int64, edits: Array<TextAreaEdit>): Int64 {
        var next = offset
        for (edit in edits) {
            if (edit.start < offset || (edit.start == offset && edit.start == edit.end)) {
                next += edit.text.size - (edit.end - edit.start)
            }
        }
        max(0, next)
    }

    private func sortEditsDescending(items: Array<TextAreaEdit>): Array<TextAreaEdit> {
        let out = ArrayList<TextAreaEdit>()
        for (item in items) {
            var inserted = false
            for (i in 0..out.size) {
                if (item.start > out[i].start) {
                    out.add(item, at: i)
                    inserted = true
                    break
                }
            }
            if (!inserted) { out.add(item) }
        }
        out.toArray()
    }

    private func mergeRangesAscending(items: Array<TextAreaEdit>): Array<TextAreaEdit> {
        let sorted = ArrayList<TextAreaEdit>()
        for (item in items) {
            var inserted = false
            for (i in 0..sorted.size) {
                if (item.start < sorted[i].start) {
                    sorted.add(item, at: i)
                    inserted = true
                    break
                }
            }
            if (!inserted) { sorted.add(item) }
        }
        let merged = ArrayList<TextAreaEdit>()
        for (item in sorted) {
            if (merged.size == 0) {
                merged.add(item)
            } else {
                let last = merged[merged.size - 1]
                if (item.start <= last.end) {
                    merged.remove(at: merged.size - 1)
                    merged.add(TextAreaEdit(last.start, max(last.end, item.end), ""))
                } else {
                    merged.add(item)
                }
            }
        }
        merged.toArray()
    }

    private func invalidateLineCache(): Unit {
        cachedLineRevision = -1
        cachedVisibleLines = []
    }

    private func ensureLineCache(): Unit {
        if (!lineCacheStale()) { return }
        cachedLines = splitLines(value)
        cachedLineOffsets = lineStartOffsets(value)
        cachedVisibleLines = []
        cachedLineRebuilds++
        cachedLineRevision = revision
        cachedLineTextSize = value.size
        cachedLineFirstByte = if (value.size > 0) { value[0] } else { 0u8 }
        cachedLineLastByte = if (value.size > 0) { value[value.size - 1] } else { 0u8 }
    }

    private func lineCacheStale(): Bool {
        if (cachedLineRevision != revision || cachedLineTextSize != value.size || cachedLines.size == 0 || cachedLineOffsets.size == 0) {
            return true
        }
        let first = if (value.size > 0) { value[0] } else { 0u8 }
        let last = if (value.size > 0) { value[value.size - 1] } else { 0u8 }
        first != cachedLineFirstByte || last != cachedLineLastByte
    }

    private func linesForRender(): Array<String> {
        ensureLineCache()
        cachedLines
    }

    private func lineOffsetsForRender(): Array<Int64> {
        ensureLineCache()
        cachedLineOffsets
    }

    private func lineCount(): Int64 {
        linesForRender().size
    }

    private func lineForOffset(offset: Int64): Int64 {
        let target = clampToRuneBoundary(value, offset)
        let offsets = lineOffsetsForRender()
        var line: Int64 = 0
        for (i in 0..offsets.size) {
            if (offsets[i] <= target) { line = i } else { return line }
        }
        line
    }

    private func lineStartForOffset(offset: Int64): Int64 {
        let line = lineForOffset(offset)
        let offsets = lineOffsetsForRender()
        if (line >= 0 && line < offsets.size) { offsets[line] } else { 0 }
    }

    public func lineCacheRebuildCount(): Int64 {
        cachedLineRebuilds
    }

    private func visibleLineIndexes(): Array<Int64> {
        ensureLineCache()
        if (cachedVisibleLines.size > 0) { return cachedVisibleLines }
        let lines = cachedLines
        let offsets = cachedLineOffsets
        let out = ArrayList<Int64>()
        for (i in 0..lines.size) {
            if (!lineOffsetHidden(offsets[i])) { out.add(i) }
        }
        if (out.size == 0) { out.add(0) }
        cachedVisibleLines = out.toArray()
        cachedVisibleLines
    }

    private func lineOffsetHidden(offset: Int64): Bool {
        match (foldState) {
            case Some(state) =>
                for (range in state.folds()) {
                    if (range.startOffset < offset && offset <= range.endOffset) { return true }
                }
                false
            case None => false
        }
    }

    private func lineHasFoldMarker(lineIndex: Int64): Bool {
        let offsets = lineOffsetsForRender()
        if (lineIndex < 0 || lineIndex >= offsets.size) { return false }
        let offset = offsets[lineIndex]
        match (foldState) {
            case Some(state) =>
                for (range in state.folds()) {
                    if (range.startOffset <= offset && offset <= range.endOffset) { return true }
                }
                false
            case None => false
        }
    }

    private func visibleRowForLine(line: Int64): Int64 {
        let visible = visibleLineIndexes()
        var fallback: Int64 = 0
        for (i in 0..visible.size) {
            if (visible[i] <= line) { fallback = i }
            if (visible[i] == line) { return i }
        }
        fallback
    }

    private func visibleRowForOffset(offset: Int64): Int64 {
        let offsets = lineOffsetsForRender()
        var line: Int64 = 0
        for (i in 0..offsets.size) {
            if (offsets[i] <= offset) { line = i }
        }
        visibleRowForLine(line) - scroll
    }

    private func offsetForMouse(mouse: MouseEvent, area: Rect): ?Int64 {
        var target = area
        if (let Some(b) <- block) { target = b.inner(area) }
        if (target.width <= 0 || target.height <= 0) { return None }
        let lines = linesForRender()
        let gutter = if (lineNumbers) { min(6, max(3, decimalDigits(lines.size) + 1)) } else { 0 }
        if (mouse.y < target.y || mouse.y >= target.y + target.height) { return None }
        let visible = visibleLineIndexes()
        let visibleIndex = scroll + mouse.y - target.y
        if (visibleIndex < 0 || visibleIndex >= visible.size) { return None }
        let lineIndex = visible[visibleIndex]
        if (lineNumbers && mouse.x < target.x + gutter) {
            return Some(offsetAtLineColumn(value, lineIndex, 0))
        }
        let textX = target.x + gutter
        let column = max(0, mouse.x - textX)
        Some(offsetAtLineColumn(value, lineIndex, column))
    }

    private func applyCompletionResult(result: TextCompletionResult): Bool {
        if (result.requestId != completionRequestId || result.revision != revision) { return false }
        completionItems = result.items
        completionReplaceStart = clampToRuneBoundary(value, result.replaceStart)
        completionReplaceEnd = clampToRuneBoundary(value, result.replaceEnd)
        completionIndex = 0
        completionOpen = result.items.size > 0
        completionOpen
    }

    private func handleCompletionKey(key: KeyEvent): Bool {
        match (key.code) {
            case KeyCode.Up =>
                completionIndex = max(0, completionIndex - 1)
                true
            case KeyCode.Down =>
                completionIndex = min(max(0, completionItems.size - 1), completionIndex + 1)
                true
            case KeyCode.Esc =>
                completionOpen = false
                true
            case KeyCode.Enter =>
                acceptCompletion()
                true
            case KeyCode.Tab =>
                acceptCompletion()
                true
            case _ => false
        }
    }

    private func acceptCompletion(): Unit {
        if (!completionOpen || completionItems.size == 0) { return }
        let item = completionItems[completionIndex]
        pushUndoSnapshot()
        let start = clamp(completionReplaceStart, 0, value.size)
        let end = clamp(completionReplaceEnd, start, value.size)
        value = value[..start] + item.insertText + value[end..]
        cursor = start + item.insertText.size
        clearSelection()
        clearExtraCarets()
        markEdited()
        clearRedo()
    }

    private func renderCompletion(area: Rect, buffer: Buffer): Unit {
        if (!completionOpen || completionItems.size == 0 || area.width <= 0 || area.height <= 0) { return }
        let pos = cursorPosition(Rect(area.x, area.y, area.width, area.height))
        let startY = min(area.y + area.height - 1, pos.y + 1)
        let maxRows = min(5, area.y + area.height - startY)
        let visibleRows = min(maxRows, completionItems.size)
        var itemStart = max(0, completionIndex - visibleRows / 2)
        if (itemStart + visibleRows > completionItems.size) {
            itemStart = max(0, completionItems.size - visibleRows)
        }
        for (row in 0..visibleRows) {
            let itemIndex = itemStart + row
            let item = completionItems[itemIndex]
            let prefix = if (itemIndex == completionIndex) { "> " } else { "  " }
            let text = if (item.detail.isEmpty()) { prefix + item.label } else { prefix + item.label + " " + item.detail }
            let popupStyle = if (itemIndex == completionIndex) { selectedStyle } else { Style(fg: Color.Cyan) }
            buffer.setString(pos.x, startY + row, truncate(text, max(0, area.x + area.width - pos.x)), style: popupStyle)
        }
    }

    private func renderLine(x: Int64, y: Int64, width: Int64, lineIndex: Int64, line: String, buffer: Buffer): Unit {
        let lineStartOffset = offsetAtLineColumn(value, lineIndex, 0)
        let styled = lineDecorations(line, lineStartOffset)
        let ranges = selectionRangesForLine(lineStartOffset, line.size)
        if (ranges.size == 0) {
            renderDecoratedLine(buffer, x, y, width, styled)
            return
        }
        var offset: Int64 = 0
        var cx = x
        for (range in ranges) {
            if (range.start > offset) {
                let segment = sliceRichSpans(styled, offset, range.start, None)
                renderDecoratedLine(buffer, cx, y, max(0, width - (cx - x)), segment)
                cx += displayWidth(line[offset..range.start])
            }
            let selected = sliceRichSpans(styled, range.start, range.end, Some(selectedStyle))
            renderDecoratedLine(buffer, cx, y, max(0, width - (cx - x)), selected)
            cx += displayWidth(line[range.start..range.end])
            offset = range.end
        }
        if (offset < line.size) {
            renderDecoratedLine(buffer, cx, y, max(0, width - (cx - x)), sliceRichSpans(styled, offset, line.size, None))
        }
    }

    private func selectionRangesForLine(lineStartOffset: Int64, lineSize: Int64): Array<TextAreaEdit> {
        let ranges = ArrayList<TextAreaEdit>()
        for (caret in carets()) {
            match (caretRange(caret)) {
                case Some((selStart, selEnd)) =>
                    let start = clamp(selStart - lineStartOffset, 0, lineSize)
                    let end = clamp(selEnd - lineStartOffset, 0, lineSize)
                    if (end > 0 && start < lineSize && start < end) {
                        ranges.add(TextAreaEdit(start, end, ""))
                    }
                case None => ()
            }
        }
        mergeRangesAscending(ranges.toArray())
    }

    private func lineDecorations(line: String, lineStartOffset: Int64): Array<RichSpan> {
        if (line.isEmpty()) { return [RichSpan("", style: style)] }
        let lineMarkers = decorationsForLine(lineStartOffset, line.size)
        let markers = if (markdownEditing && decorations.size == 0) { markdownLineDecorations(line, lineStartOffset) } else { lineMarkers }
        let spans = ArrayList<RichSpan>()
        var offset: Int64 = 0
        var currentText = ""
        var currentStyle = style
        var hasCurrent = false
        while (offset < line.size) {
            let next = nextRuneOffset(line, offset)
            var nextStyle = style
            let absStart = lineStartOffset + offset
            let absEnd = lineStartOffset + next
            for (decoration in markers) {
                if (decoration.end > absStart && decoration.start < absEnd) {
                    nextStyle = nextStyle.patch(decoration.style)
                }
            }
            let text = line[offset..next]
            if (!hasCurrent) {
                currentText = text
                currentStyle = nextStyle
                hasCurrent = true
            } else if (nextStyle == currentStyle) {
                currentText += text
            } else {
                spans.add(RichSpan(currentText, style: currentStyle))
                currentText = text
                currentStyle = nextStyle
            }
            offset = next
        }
        if (hasCurrent) { spans.add(RichSpan(currentText, style: currentStyle)) }
        spans.toArray()
    }

    private func decorationsForLine(lineStartOffset: Int64, lineSize: Int64): Array<TextDecoration> {
        let out = ArrayList<TextDecoration>()
        let lineEnd = lineStartOffset + lineSize
        for (decoration in decorations) {
            if (decoration.end > lineStartOffset && decoration.start < lineEnd) {
                out.add(decoration)
            }
        }
        out.toArray()
    }

    private func markdownLineDecorations(line: String, lineStartOffset: Int64): Array<TextDecoration> {
        markdownDecorationsForLine(line, lineStartOffset)
    }

    private func markdownEnterText(): String {
        let start = lineStartForOffset(cursor)
        let end = lineEnd(value, cursor)
        let line = value[start..end]
        let indent = line[..leadingSpacesLocal(line)]
        let markerEnd = markdownListMarkerEnd(line)
        if (markerEnd > 0) {
            let marker = continuationMarker(line)
            if (trimAsciiSpacesLocal(line[markerEnd..]).isEmpty()) {
                return "\n" + indent
            }
            return "\n" + indent + marker
        }
        if (trimAsciiSpacesLocal(line).startsWith(">")) {
            return "\n" + indent + "> "
        }
        "\n" + indent
    }

    private func finishEmptyMarkdownListItem(): Bool {
        let start = lineStartForOffset(cursor)
        let end = lineEnd(value, cursor)
        let line = value[start..end]
        let markerEnd = markdownListMarkerEnd(line)
        if (markerEnd <= 0 || !trimAsciiSpacesLocal(line[markerEnd..]).isEmpty()) { return false }
        let indent = line[..leadingSpacesLocal(line)]
        pushUndoSnapshot()
        value = value[..start] + indent + value[end..]
        cursor = start + indent.size
        clearSelection()
        clearRedo()
        true
    }

    private func indentCurrentLine(): Unit {
        let start = lineStartForOffset(cursor)
        cursor = start
        select(start, start)
        paste("  ")
    }

    private func outdentCurrentLine(): Unit {
        let start = lineStartForOffset(cursor)
        let remove = if (start + 2 <= value.size && value[start..start + 2] == "  ") { 2 } else if (start < value.size && value[start] == b' ') { 1 } else { 0 }
        if (remove <= 0) { return }
        cursor = start
        select(start, start + remove)
        paste("")
    }

    private func indentSelectedLines(): Unit {
        match (selectionBounds()) {
            case Some((start, end)) => replaceLineRangeIndent(start, end, true)
            case None => indentCurrentLine()
        }
    }

    private func outdentSelectedLines(): Unit {
        match (selectionBounds()) {
            case Some((start, end)) => replaceLineRangeIndent(start, end, false)
            case None => outdentCurrentLine()
        }
    }

    private func replaceLineRangeIndent(start: Int64, end: Int64, indent: Bool): Unit {
        let rangeStart = lineStart(value, start)
        let rangeEnd = lineEnd(value, end)
        let lines = splitLines(value[rangeStart..rangeEnd])
        var next = ""
        for (i in 0..lines.size) {
            if (i > 0) { next += "\n" }
            if (indent) {
                next += "  " + lines[i]
            } else if (lines[i].startsWith("  ")) {
                next += lines[i][2..]
            } else if (lines[i].startsWith(" ")) {
                next += lines[i][1..]
            } else {
                next += lines[i]
            }
        }
        cursor = rangeStart
        select(rangeStart, rangeEnd)
        paste(next)
        select(rangeStart, rangeStart + next.size)
    }
}

func renderDecoratedLine(buffer: Buffer, x: Int64, y: Int64, width: Int64, spans: Array<RichSpan>): Unit {
    var cx = x
    let right = x + width
    for (span in spans) {
        if (cx >= right) { return }
        let part = truncate(span.text, right - cx)
        buffer.setString(cx, y, part, style: span.style)
        cx += displayWidth(part)
    }
}

func sliceRichSpans(spans: Array<RichSpan>, start: Int64, end: Int64, patch: ?Style): Array<RichSpan> {
    let out = ArrayList<RichSpan>()
    var offset: Int64 = 0
    for (span in spans) {
        let spanStart = offset
        let spanEnd = offset + span.text.size
        if (spanEnd > start && spanStart < end) {
            let localStart = clamp(start - spanStart, 0, span.text.size)
            let localEnd = clamp(end - spanStart, localStart, span.text.size)
            let nextStyle = match (patch) {
                case Some(style) => span.style.patch(style)
                case None => span.style
            }
            out.add(RichSpan(span.text[localStart..localEnd], style: nextStyle, linkUrl: span.linkUrl, sourceRange: span.sourceRange))
        }
        offset = spanEnd
    }
    out.toArray()
}

func leadingSpacesLocal(text: String): Int64 {
    var i: Int64 = 0
    while (i < text.size && (text[i] == b' ' || text[i] == b'\t')) { i++ }
    i
}

func trimAsciiSpacesLocal(text: String): String {
    var start: Int64 = 0
    var end = text.size
    while (start < end && (text[start] == b' ' || text[start] == b'\t')) { start++ }
    while (end > start && (text[end - 1] == b' ' || text[end - 1] == b'\t')) { end-- }
    text[start..end]
}

func markdownListMarkerEnd(line: String): Int64 {
    let start = leadingSpacesLocal(line)
    if (start + 2 <= line.size && (line[start] == b'-' || line[start] == b'*' || line[start] == b'+') && line[start + 1] == b' ') {
        return start + 2
    }
    var i = start
    while (i < line.size && line[i] >= b'0' && line[i] <= b'9') { i++ }
    if (i > start && i + 1 < line.size && line[i] == b'.' && line[i + 1] == b' ') {
        return i + 2
    }
    0
}

func continuationMarker(line: String): String {
    let start = leadingSpacesLocal(line)
    let end = markdownListMarkerEnd(line)
    if (end <= start) { return "" }
    if (line[start] >= b'0' && line[start] <= b'9') {
        var number: Int64 = 0
        var i = start
        while (i < line.size && line[i] >= b'0' && line[i] <= b'9') {
            number = number * 10 + Int64(line[i] - b'0')
            i++
        }
        return "${number + 1}. "
    }
    let marker = line[start..end]
    if (hasTaskMarkerAfterListMarker(line, end)) {
        return marker + "[ ] "
    }
    marker
}

func hasTaskMarkerAfterListMarker(line: String, offset: Int64): Bool {
    offset + 4 <= line.size &&
        line[offset] == b'[' &&
        (line[offset + 1] == b' ' || line[offset + 1] == b'x' || line[offset + 1] == b'X') &&
        line[offset + 2] == b']' &&
        line[offset + 3] == b' '
}

func addInlineMarkerDecorations(out: ArrayList<TextDecoration>, line: String, lineStartOffset: Int64, marker: String, style: Style): Unit {
    var start = findStringFromLocal(line, marker, 0)
    while (start >= 0) {
        let end = findStringFromLocal(line, marker, start + marker.size)
        if (end < 0) { return }
        out.add(TextDecoration(lineStartOffset + start, lineStartOffset + end + marker.size, style))
        start = findStringFromLocal(line, marker, end + marker.size)
    }
}

func findStringFromLocal(text: String, needle: String, start: Int64): Int64 {
    var i = start
    while (i + needle.size <= text.size) {
        if (matchesAsciiNeedleAt(text, needle, i)) { return i }
        i++
    }
    -1
}

func matchesAsciiNeedleAt(text: String, needle: String, offset: Int64): Bool {
    if (offset < 0 || offset + needle.size > text.size) { return false }
    for (i in 0..needle.size) {
        if (text[offset + i] != needle[i]) { return false }
    }
    true
}

public func markdownDecorations(text: String): Array<TextDecoration> {
    let out = ArrayList<TextDecoration>()
    let lines = splitLines(text)
    var offset: Int64 = 0
    var inFence = false
    for (lineIndex in 0..lines.size) {
        let line = lines[lineIndex]
        let trimmed = leadingSpacesLocal(line)
        if (line[trimmed..].startsWith("```") || line[trimmed..].startsWith("~~~")) {
            out.add(TextDecoration(offset + trimmed, offset + line.size, Style(fg: Color.Magenta)))
            inFence = !inFence
        } else if (inFence) {
            out.add(TextDecoration(offset, offset + line.size, Style(fg: Color.Magenta)))
        } else {
            for (decoration in markdownDecorationsForLine(line, offset)) {
                out.add(decoration)
            }
        }
        offset += line.size + 1
    }
    out.toArray()
}

public func markdownLineHighlights(text: String): Array<LineHighlight> {
    let out = ArrayList<LineHighlight>()
    let lines = splitLines(text)
    var inFence = false
    for (lineIndex in 0..lines.size) {
        let line = lines[lineIndex]
        let trimmed = leadingSpacesLocal(line)
        let spans = ArrayList<TextDecoration>()
        if (line[trimmed..].startsWith("```") || line[trimmed..].startsWith("~~~")) {
            spans.add(TextDecoration(trimmed, line.size, Style(fg: Color.Magenta)))
            inFence = !inFence
        } else if (inFence) {
            spans.add(TextDecoration(0, line.size, Style(fg: Color.Magenta)))
        } else {
            for (decoration in markdownDecorationsForLine(line, 0)) {
                spans.add(decoration)
            }
        }
        out.add(LineHighlight(lineIndex, spans.toArray()))
    }
    out.toArray()
}

func lineStartOffsets(text: String): Array<Int64> {
    let offsets = ArrayList<Int64>()
    offsets.add(0)
    var i: Int64 = 0
    while (i < text.size) {
        if (text[i] == b'\n') { offsets.add(i + 1) }
        i++
    }
    offsets.toArray()
}

func completionPrefixStart(text: String, cursor: Int64): Int64 {
    var pos = clampToRuneBoundary(text, cursor)
    while (pos > 0) {
        let prev = previousRuneOffset(text, pos)
        if (!isCompletionWordByte(text[prev])) { return pos }
        pos = prev
    }
    pos
}

func isCompletionWordByte(ch: Byte): Bool {
    (ch >= b'a' && ch <= b'z') ||
        (ch >= b'A' && ch <= b'Z') ||
        (ch >= b'0' && ch <= b'9') ||
        ch == b'_'
}

func markdownDecorationsForLine(line: String, lineStartOffset: Int64): Array<TextDecoration> {
    let out = ArrayList<TextDecoration>()
    let trimmedStart = leadingSpacesLocal(line)
    if (trimmedStart < line.size && line[trimmedStart] == b'#') {
        out.add(TextDecoration(lineStartOffset + trimmedStart, lineStartOffset + line.size, Style(fg: Color.Yellow, modifier: Modifier.strong())))
        return out.toArray()
    }
    if (trimmedStart < line.size && line[trimmedStart] == b'>') {
        out.add(TextDecoration(lineStartOffset + trimmedStart, lineStartOffset + line.size, Style(fg: Color.Green)))
    }
    if (line.contains("|")) {
        out.add(TextDecoration(lineStartOffset, lineStartOffset + line.size, Style(fg: Color.Cyan)))
    }
    let markerEnd = markdownListMarkerEnd(line)
    if (markerEnd > 0) {
        let markerStyle = Style(fg: Color.Cyan)
        out.add(TextDecoration(lineStartOffset + trimmedStart, lineStartOffset + markerEnd, markerStyle))
        if (matchesAsciiNeedleAt(line, "[ ]", markerEnd) ||
            matchesAsciiNeedleAt(line, "[x]", markerEnd) ||
            matchesAsciiNeedleAt(line, "[X]", markerEnd)) {
            out.add(TextDecoration(lineStartOffset + markerEnd, lineStartOffset + markerEnd + 3, Style(fg: Color.Yellow)))
        }
    }
    addInlineMarkerDecorations(out, line, lineStartOffset, "**", Style(fg: Color.White, modifier: Modifier.strong()))
    addInlineMarkerDecorations(out, line, lineStartOffset, "*", Style(fg: Color.White, modifier: italicModifier()))
    addInlineMarkerDecorations(out, line, lineStartOffset, "~~", Style(fg: Color.Indexed(8)))
    addInlineMarkerDecorations(out, line, lineStartOffset, "`", Style(fg: Color.Magenta))
    addLinkDecorations(out, line, lineStartOffset)
    addInlineMarkerDecorations(out, line, lineStartOffset, "***", Style(fg: Color.White, modifier: strongItalicModifier()))
    out.toArray()
}

func addLinkDecorations(out: ArrayList<TextDecoration>, line: String, lineStartOffset: Int64): Unit {
    var start = findStringFromLocal(line, "[", 0)
    while (start >= 0) {
        let close = findStringFromLocal(line, "](", start + 1)
        if (close < 0) { return }
        let end = findStringFromLocal(line, ")", close + 2)
        if (end < 0) { return }
        out.add(TextDecoration(lineStartOffset + start, lineStartOffset + end + 1, Style(fg: Color.Blue)))
        start = findStringFromLocal(line, "[", end + 1)
    }
}

func italicModifier(): Modifier {
    var modifier = Modifier.none()
    modifier.italic = true
    modifier
}

func strongItalicModifier(): Modifier {
    var modifier = Modifier.strong()
    modifier.italic = true
    modifier
}

public class MarkdownEditorBehavior {
    private let highlighter = MarkdownHighlightCache()

    public init() {}

    public func applyHighlights(area: TextArea): Unit {
        area.setDecorations(highlighter.highlights(area.value))
    }

    public func invalidate(): Unit {
        highlighter.invalidate()
    }

    public func handle(area: TextArea, key: KeyEvent): Bool {
        area.markdownEditing = true
        match (key.code) {
            case KeyCode.Enter =>
                handleMarkdownEnter(area)
            case KeyCode.Tab | KeyCode.BackTab =>
                area.handle(key)
            case KeyCode.Char(r'*') =>
                if (area.hasSelection()) { return wrapSelection(area, "*", "*") }
                if (previousByteIs(area, b'*')) { return closeRepeatedMarker(area, "**") }
                area.handle(key)
            case KeyCode.Char(r'`') =>
                if (area.hasSelection()) { return wrapSelection(area, "`", "`") }
                insertPair(area, "`", "`")
            case KeyCode.Char(r'[') =>
                if (area.hasSelection()) { return wrapSelectionAsLink(area) }
                insertPair(area, "[", "]")
            case KeyCode.Char(r'(') =>
                if (area.hasSelection()) { return wrapSelection(area, "(", ")") }
                insertPair(area, "(", ")")
            case KeyCode.Char(r'~') =>
                if (area.hasSelection()) { return wrapSelection(area, "~~", "~~") }
                if (previousByteIs(area, b'~')) { return closeRepeatedMarker(area, "~~") }
                area.handle(key)
            case KeyCode.Char(r']') =>
                skipClosingDelimiter(area, "]")
            case KeyCode.Char(r')') =>
                skipClosingDelimiter(area, ")")
            case _ => area.handle(key)
        }
    }

    public func toggleBold(area: TextArea): Bool {
        wrapSelectionOrWord(area, "**", "**")
    }

    public func toggleItalic(area: TextArea): Bool {
        wrapSelectionOrWord(area, "*", "*")
    }

    public func toggleCode(area: TextArea): Bool {
        wrapSelectionOrWord(area, "`", "`")
    }

    public func insertLink(area: TextArea, url!: String = "https://example.com"): Bool {
        if (area.hasSelection()) {
            wrapSelection(area, "[", "](${url})")
        } else {
            area.paste("[text](${url})")
            true
        }
    }

    public func insertImage(area: TextArea, url!: String = "image.png", alt!: String = "alt"): Bool {
        if (area.hasSelection()) {
            match (area.selectedRange()) {
                case Some((start, end)) =>
                    let text = area.value[start..end]
                    area.paste("![" + text + "](${url})")
                    area.cursor = start + text.size + 4 + url.size
                    area.clearSelection()
                    true
                case None => false
            }
        } else {
            area.paste("![" + alt + "](${url})")
            true
        }
    }

    public func insertReferenceLink(area: TextArea, id!: String = "ref"): Bool {
        if (area.hasSelection()) {
            wrapSelection(area, "[", "][${id}]")
        } else {
            area.paste("[text][${id}]")
            true
        }
    }

    public func insertReferenceDefinition(area: TextArea, id!: String = "ref", url!: String = "https://example.com", title!: String = ""): Bool {
        let suffix = if (title.isEmpty()) { "" } else { " \"${title}\"" }
        area.paste("[${id}]: ${url}${suffix}\n")
        true
    }

    public func insertFrontmatter(area: TextArea, title!: String = "Untitled"): Bool {
        let oldCursor = area.cursor
        let prefix = "---\ntitle: ${title}\n---\n\n"
        area.cursor = 0
        area.select(0, 0)
        area.paste(prefix)
        area.cursor = oldCursor + prefix.size
        true
    }

    public func insertTable(area: TextArea): Bool {
        area.paste("| Name | Value |\n| --- | --- |\n| item | value |\n")
        true
    }

    public func insertCodeFence(area: TextArea, language!: String = ""): Bool {
        area.paste("```" + language + "\n\n```\n")
        true
    }
}

public class MarkdownTextEditor <: Widget {
    public let area: TextArea
    public let behavior: MarkdownEditorBehavior

    public init(value!: String = "", block!: ?Block = None, lineNumbers!: Bool = true) {
        area = TextArea(value: value, block: block, lineNumbers: lineNumbers, markdownEditing: true)
        behavior = MarkdownEditorBehavior()
    }

    public func handle(key: KeyEvent): Bool {
        behavior.handle(area, key)
    }

    public func render(areaRect: Rect, buffer: Buffer): Unit {
        behavior.applyHighlights(area)
        area.render(areaRect, buffer)
    }
}
