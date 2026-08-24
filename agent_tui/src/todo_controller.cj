package agent_tui

import core.*
import std.collection.*

enum TodoEffect {
    SaveMarkdown(String)
}

class TodoTransition {
    let update: UpdateResult
    let effect: ?TodoEffect
    let status: ?String
    let layoutChanged: Bool

    init(
        update: UpdateResult,
        effect!: ?TodoEffect = None,
        status!: ?String = None,
        layoutChanged!: Bool = false
    ) {
        this.update = update
        this.effect = effect
        this.status = status
        this.layoutChanged = layoutChanged
    }
}

class TodoProbeState {
    let markdown: String
    let editorValue: String
    let editorCursor: Int64
    let editing: Bool
    let editorArea: Rect

    init(markdown: String, editorValue: String, editorCursor: Int64, editing: Bool, editorArea: Rect) {
        this.markdown = markdown
        this.editorValue = editorValue
        this.editorCursor = editorCursor
        this.editing = editing
        this.editorArea = editorArea
    }
}

class TodoStripItem {
    let marker: String
    let content: String

    init(marker: String, content: String) {
        this.marker = marker
        this.content = content
    }
}

func parseTodoItems(markdown: String): Array<TodoStripItem> {
    let items = ArrayList<TodoStripItem>()
    for (rawLine in markdown.split("\n")) {
        let line = rawLine.trimAscii()
        if (line.size < 6 ||
            (line[0] != b'-' && line[0] != b'*' && line[0] != b'+') ||
            line[1] != b' ' || line[2] != b'[' || line[4] != b']' ||
            line[5] != b' ') {
            continue
        }
        let marker = line[3..4]
        if (marker != " " && marker != "x" && marker != "X" && marker != "/" && marker != ">" && marker != "-" &&
            marker != "~" && marker != "!") {
            continue
        }
        var content = line[6..].trimAscii()
        if (marker == "!" && content.endsWith("-->")) {
            match (content.lastIndexOf("<!-- blocker:")) {
                case Some(start) => content = content[..start].trimAscii()
                case None => ()
            }
        }
        if (content != "") {
            items.add(TodoStripItem(marker, content))
        }
    }
    items.toArray()
}

func visibleTodoItems(
    items: Array<TodoStripItem>,
    maximum: Int64
): Array<TodoStripItem> {
    if (maximum <= 0) {
        return []
    }
    if (items.size <= maximum) {
        return items
    }
    let visible = ArrayList<TodoStripItem>()
    for (markers in [["/", ">", "!"], [" "], ["x", "X", "-", "~"]]) {
        for (item in items) {
            if (visible.size >= maximum) {
                return visible.toArray()
            }
            if (markers.contains(item.marker)) {
                visible.add(item)
            }
        }
    }
    visible.toArray()
}

func todoRowCount(
    itemCount: Int64,
    terminalWidth: Int64,
    terminalHeight: Int64,
    queuedRows: Int64
): Int64 {
    if (itemCount <= 0) {
        return 0
    }
    let preferred = if (terminalWidth < 72) { 2 } else { 5 }
    // Preserve three transcript rows, the activity row, and the composer's
    // one content row plus its two frame rows on constrained terminals.
    let available = max(0, terminalHeight - 7 - queuedRows)
    min(itemCount, min(preferred, available))
}

class TodoController {
    private let todoEditor = TextArea(
        block: Some(Block(title: "Todo Markdown")),
        lineNumbers: true,
        markdownEditing: true
    )
    private var todoMarkdownCache = ""
    private var todoStripItems: Array<TodoStripItem> = []
    private var todoCompletedCount: Int64 = 0
    private var editingTodos = false
    private var todoEditorArea = Rect(0, 0, 0, 0)

    func isEditing(): Bool {
        editingTodos
    }

    func captureProbeState(): TodoProbeState {
        TodoProbeState(
            todoMarkdownCache,
            todoEditor.value,
            todoEditor.cursor,
            editingTodos,
            todoEditorArea
        )
    }

    func restoreProbeState(state: TodoProbeState): Unit {
        todoMarkdownCache = state.markdown
        todoStripItems = parseTodoItems(state.markdown)
        todoCompletedCount = countCompleted(todoStripItems)
        todoEditor.setValue(state.editorValue, cursor: state.editorCursor)
        editingTodos = state.editing
        todoEditorArea = state.editorArea
    }

    func suspendEditorForProbe(): Bool {
        let previous = editingTodos
        editingTodos = false
        previous
    }

    func restoreEditorForProbe(previous: Bool): Unit {
        editingTodos = previous
    }

    func applySnapshot(result: TuiTodoLoadResult): TodoTransition {
        if (!result.loaded || result.markdown == todoMarkdownCache) {
            return TodoTransition(UpdateResult.unchanged())
        }
        let previousItemCount = todoStripItems.size
        todoMarkdownCache = result.markdown
        todoStripItems = parseTodoItems(result.markdown)
        todoCompletedCount = countCompleted(todoStripItems)
        TodoTransition(
            UpdateResult.next(),
            layoutChanged: previousItemCount != todoStripItems.size
        )
    }

    func open(result: TuiTodoLoadResult): TodoTransition {
        if (!result.loaded) {
            return TodoTransition(
                UpdateResult.next(),
                status: Some(result.message)
            )
        }
        let snapshot = applySnapshot(result)
        todoEditor.setValue(result.markdown)
        editingTodos = true
        TodoTransition(
            UpdateResult.next(),
            status: Some("todo editor · Ctrl+S save · Esc cancel"),
            layoutChanged: snapshot.layoutChanged
        )
    }

    func acceptSave(result: TuiTodoSaveResult): TodoTransition {
        editingTodos = !result.saved
        TodoTransition(
            UpdateResult.next(),
            status: Some(result.message)
        )
    }

    func updateKey(key: KeyEvent): TodoTransition {
        if (!editingTodos) {
            return TodoTransition(UpdateResult.unchanged())
        }
        match (key.code) {
            case KeyCode.Esc =>
                editingTodos = false
                TodoTransition(
                    UpdateResult.next(),
                    status: Some("todo edit cancelled")
                )
            case KeyCode.Char(r's') =>
                if (key.modifiers.ctrl) {
                    let value = todoEditor.value
                    editingTodos = false
                    return TodoTransition(
                        UpdateResult.next(),
                        effect: Some(TodoEffect.SaveMarkdown(value)),
                        status: Some("saving todo")
                    )
                }
                let changed = todoEditor.handle(key)
                TodoTransition(if (changed) { UpdateResult.next() } else { UpdateResult.unchanged() })
            case _ =>
                let changed = todoEditor.handle(key)
                TodoTransition(if (changed) { UpdateResult.next() } else { UpdateResult.unchanged() })
        }
    }

    func paste(text: String): TodoTransition {
        if (!editingTodos) {
            return TodoTransition(UpdateResult.unchanged())
        }
        todoEditor.paste(text)
        TodoTransition(UpdateResult.next())
    }

    func updateMouse(mouse: MouseEvent): TodoTransition {
        if (!editingTodos || !todoPointInRect(mouse.x, mouse.y, todoEditorArea)) {
            return TodoTransition(UpdateResult.unchanged())
        }
        let changed = todoEditor.handleMouse(mouse, todoEditorArea)
        TodoTransition(if (changed) { UpdateResult.next() } else { UpdateResult.unchanged() })
    }

    func stripRowCount(
        terminalWidth: Int64,
        terminalHeight: Int64,
        queuedRows: Int64
    ): Int64 {
        todoRowCount(todoStripItems.size, terminalWidth, terminalHeight, queuedRows)
    }

    func renderStrip(
        canvas: Canvas,
        area: Rect,
        theme: ProductTheme
    ): Unit {
        if (area.width <= 0 || area.height <= 0 || todoStripItems.isEmpty()) {
            return
        }
        let visible = visibleTodoItems(todoStripItems, area.height)
        for (index in 0..visible.size) {
            let item = visible[index]
            let prefix = if (index == 0) {
                "Todo " + todoCompletedCount.toString() + "/" + todoStripItems.size.toString() + " · "
            } else {
                "     "
            }
            let marker = "[" + item.marker + "] "
            let hidden = todoStripItems.size - visible.size
            let suffix = if (index == visible.size - 1 && hidden > 0) {
                " · +" + hidden.toString()
            } else {
                ""
            }
            let contentWidth = max(
                0,
                area.width - 4 - displayWidth(prefix) - displayWidth(marker)
            )
            let content = cut(item.content + suffix, contentWidth)
            let y = area.y + index
            canvas.drawText(
                area.x + 2,
                y,
                prefix,
                Style(
                    fg: if (index == 0) { theme.accent } else { theme.secondary },
                    bg: theme.background,
                    modifier: if (index == 0) { Modifier.strong() } else { Modifier.none() }
                )
            )
            let itemColor = match (item.marker) {
                case "x" | "X" => theme.success
                case "/" | ">" => theme.warning
                case "!" => theme.danger
                case "-" | "~" => theme.muted
                case _ => theme.accent
            }
            canvas.drawText(
                area.x + 2 + displayWidth(prefix),
                y,
                marker,
                Style(fg: itemColor, bg: theme.background)
            )
            canvas.drawText(
                area.x + 2 + displayWidth(prefix) + displayWidth(marker),
                y,
                content,
                Style(fg: itemColor, bg: theme.background)
            )
        }
    }

    func renderEditor(frame: Frame, theme: ProductTheme): Unit {
        if (!editingTodos) {
            todoEditorArea = Rect(0, 0, 0, 0)
            return
        }
        let canvas = frame.canvas()
        let editorInsetX = if (frame.area.width > 4) { 2 } else { 0 }
        let editorInsetY = if (frame.area.height > 5) { 2 } else { 0 }
        todoEditorArea = Rect(
            frame.area.x + editorInsetX,
            frame.area.y + editorInsetY,
            max(1, frame.area.width - editorInsetX * 2),
            max(1, frame.area.height - editorInsetY - 2)
        )
        canvas.fillRect(todoEditorArea, Style(bg: Color.Rgb(28, 31, 39)))
        frame.renderWidget(todoEditor, todoEditorArea)
        canvas.drawText(
            todoEditorArea.x,
            min(frame.area.bottom - 1, todoEditorArea.bottom),
            cut(
                " Ctrl+S save · Esc cancel · markers: " + "[ ] [/] [x] [-] [!]",
                todoEditorArea.width
            ),
            Style(fg: theme.accent, bg: theme.background)
        )
        frame.setCursor(todoEditor.cursorPosition(todoEditorArea))
    }

    private func countCompleted(items: Array<TodoStripItem>): Int64 {
        var completed: Int64 = 0
        for (item in items where item.marker == "x" || item.marker == "X") {
            completed++
        }
        completed
    }

    private func todoPointInRect(x: Int64, y: Int64, area: Rect): Bool {
        area.width > 0 && area.height > 0 && x >= area.x && x < area.right && y >= area.y && y < area.bottom
    }
}
