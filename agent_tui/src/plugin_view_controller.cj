package agent_tui

import agent_domain.*
import agent_sdk.*
import core.*
import std.collection.*
import yjson.*
import yjson_support.*

enum PluginViewTransition {
    None
    | Close(String)
    | Action(String, String, String, TuiPluginViewFields)
    | Confirm(String, String, String, Bool)
}

private func pluginViewText(value: AgentValue, name: String): String {
    match (value.field(name)) { case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }; case None => "" }
}

// Generic presentation only: nodes and local Command actions are declared by
// the installed plugin. Business intent, security approval and execution live
// in the Host; neither labels nor widget positions select a business decision.
class PluginViewController {
    private var document: ?TuiPluginViewDocument = None
    private var metadata: ?AgentValue = None
    private var model: ?AgentValue = None
    private var confirmation: ?AgentValue = None
    private let fields = HashMap<String, String>()
    private var editor: ?TextArea = None
    private var editing = false
    private var editorNode = ""
    private var focus: Int64 = -1
    private var actionIndex: Int64 = 0
    private var scroll: Int64 = 0
    private var pending = false
    private var confirmYes = false
    private var status = "ready"
    private var renderFailed = false
    private var fieldBytes: Int64 = 0
    private var previewText = ""
    private var previewOffsets: Array<Int64> = []
    private var surfaceArea = Rect(0, 0, 0, 0)
    private var bodyArea = Rect(0, 0, 0, 0)
    private var uiBytes: Int64 = 0

    func isActive(): Bool { document.isSome() }
    func hasPending(): Bool { pending }
    func viewId(): String { match (metadata) { case Some(value) => pluginViewText(value, "view_id"); case None => "" } }
    func statusText(): String { status }
    func noteHostStatus(value: String): Unit {
        status = if (isPluginViewPlainText(value)) { value } else { "Host: unrenderable status; inspect raw evidence" }
    }
    private func editArea(): TextArea { editor.getOrThrow() }
    private func currentModel(): AgentValue { model.getOrThrow() }
    private func nodes(): UnifiedJsonItems { currentModel().field("nodes").getOrThrow().items }
    private func actions(): UnifiedJsonItems { currentModel().field("actions").getOrThrow().items }

    func open(actual: TuiPluginViewDocument): Unit {
        close()
        document = Some(actual)
        try {
            let primary = actual.primaryContent()
            if (!isPluginViewPlainText(primary)) { throw IllegalArgumentException("view.source_unrenderable") }
            // Decoder/model, editor lines and a later complete input snapshot
            // have overlapping lifetimes. No bank is created by this renderer.
            uiBytes = 2097152 + primary.size * 24 + actual.modelJson().size * 16
            actual.reserveUiBytes(uiBytes)
            let decodedMetadata = decodeAgentValue(actual.metadataJson(), maxBytes: 4096).value().getOrThrow()
            for (name in ["view_id", "revision", "namespace", "name", "generation", "package_digest"]) {
                if (!isPluginViewPlainText(pluginViewText(decodedMetadata, name))) {
                    throw IllegalArgumentException("view.metadata_unrenderable") }
            }
            if (pluginViewText(decodedMetadata, "view_id") == "") { throw IllegalArgumentException("view.interactive_binding_missing") }
            let decodedModel = decodeAgentValue(actual.modelJson(), maxBytes: PLUGIN_VIEW_MAX_BYTES).value().getOrThrow()
            match (validatePluginViewDocument(decodedModel)) {
                case SdkResult.Err(error) => throw IllegalArgumentException(error.code + ": " + error.message)
                case SdkResult.Ok(_) => () }
            metadata = Some(decodedMetadata); model = Some(decodedModel)
            for (node in nodes()) {
                let kind = pluginViewText(node, "kind"); let id = pluginViewText(node, "id")
                if (kind == "input" || kind == "document") {
                    let source = pluginViewText(node, "source")
                    if (source != "" && source != "primary") { throw IllegalArgumentException("view.source_unsupported") }
                }
                if (kind == "input") {
                    fields[id] = if (pluginViewText(node, "source") == "primary") { primary } else { pluginViewText(node, "text") }
                } else if (kind == "list" || kind == "table") { fields[id] = pluginViewText(node, "selected_id") }
                match (fields.get(id)) { case Some(value) => fieldBytes += value.size; case None => () }
            }
            status = "Host: query completed · plugin input is not execution permission"
            focus = if (actions().isEmpty() && !nodes().isEmpty()) { 0 } else { -1 }
        } catch (error: Exception) {
            close()
            throw error
        }
    }
    func confirm(raw: String): Unit {
        if (!isActive()) { throw IllegalStateException("view.confirmation_without_view") }
        let value = decodeAgentValue(raw, maxBytes: 4096).value().getOrThrow()
        if (pluginViewText(value, "schema") != "axyndra.view-confirmation/v1" ||
            pluginViewText(value, "view_id") != viewId() || pluginViewText(value, "revision") != "2" ||
            pluginViewText(value, "request_digest") == "" || !isPluginViewPlainText(pluginViewText(value, "description"))) {
            throw IllegalArgumentException("view.confirmation_mismatch") }
        clearPreview()
        confirmation = Some(value); confirmYes = false; pending = false
        status = "Host business confirmation · No selected · not a Tool permission grant"
    }
    private func clearPresentationHelper(): Unit {
        editor = None; editorNode = ""; editing = false
        fields.clear(); metadata = None; model = None; confirmation = None
        focus = -1; actionIndex = 0; scroll = 0; pending = false; confirmYes = false
        renderFailed = false
        clearPreview(); fieldBytes = 0
        bodyArea = Rect(0, 0, 0, 0); surfaceArea = Rect(0, 0, 0, 0); uiBytes = 0
    }
    func close(): Unit {
        let actual = document
        clearPresentationHelper()
        document = None
        match (actual) { case Some(value) => value.close(); case None => () }
        status = "ready"
    }
    func tryRetireRetainedReferences(): Bool { close(); true }
    func completeTurn(): Unit { pending = false }
    func failTurn(message: String): Unit {
        pending = false
        status = "Host request failed · " + if (isPluginViewPlainText(message)) { message } else { "unrenderable error; inspect raw evidence" }
    }
    func cancelPending(): Unit { pending = false; status = "Host request cancelled" }
    private func nodeText(node: AgentValue): String {
        match (pluginViewText(node, "kind")) {
            case "input" => fields[pluginViewText(node, "id")]
            case "document" => document.getOrThrow().primaryContent()
            case _ => pluginViewText(node, "text") }
    }
    private func editorLimit(): Int64 {
        let node = nodes()[focus]
        if (pluginViewText(node, "source") == "primary") { 4194304 } else { 16384 }
    }
    private func stageEditor(): Unit {
        if (editing) {
            fields[editorNode] = editArea().value; fieldBytes += editArea().value.size
            editing = false; editorNode = ""; editor = None
            clearPreview()
        }
    }
    private func beginEditor(node: AgentValue): Unit {
        let id = pluginViewText(node, "id"); let value = fields[id]
        document.getOrThrow().reserveUiBytes(uiBytes + (fieldBytes - value.size) * 8)
        // The active editor replaces, rather than hides, the staged value.
        // Discard the complete widget on return so its line/undo caches cannot
        // retain a previous large source after the presentation is retired.
        let _ = fields.remove(id); fieldBytes -= value.size; clearPreview()
        editorNode = id
        editor = Some(TextArea(value: value, cursor: 0, block: Some(Block(title: pluginViewText(node, "label"))),
            lineNumbers: false, markdownEditing: false))
        editing = true
        status = "Input · Ctrl+S stages locally · Esc returns · business action still required"
    }
    func paste(text: String): Unit {
        if (!editing || pending || confirmation.isSome()) { return }
        let multiline = nodes()[focus].field("multiline").getOrThrow().boolValue
        if (!isPluginViewPlainText(text) || editArea().value.size + text.size > editorLimit() || (!multiline && text.contains("\n"))) {
            status = "Host: input rejected; source or terminal-control bound exceeded"; return }
        try {
            reserveEditor(editArea().value.size + text.size)
            let _ = editArea().paste(text)
            editArea().clearHistory()
        } catch (_: Exception) { status = "Host: input DATA capacity exhausted; edit preserved" }
    }
    private func reserveEditor(nextBytes: Int64): Unit {
        let primaryBytes = document.getOrThrow().primaryContent().size
        let modelBytes = document.getOrThrow().modelJson().size
        // Source, current edit and previous visible-line cache overlap. Form
        // editors do not retain unbounded whole-document undo versions.
        document.getOrThrow().reserveUiBytes(2097152 + primaryBytes * 8 + modelBytes * 16 + fieldBytes * 8 + nextBytes * 16)
    }
    private func captureFields(): TuiPluginViewFields {
        document.getOrThrow().captureFields({ =>
            let values = ArrayList<TuiPluginViewField>()
            for (node in nodes() where ["input", "list", "table"].contains(pluginViewText(node, "kind"))) {
                let id = pluginViewText(node, "id"); values.add(TuiPluginViewField(id, fields[id])) }
            values.toArray()
        })
    }
    func updateKey(key: KeyEvent): PluginViewTransition {
        if (!isActive()) { return PluginViewTransition.None }
        match (key.code) { case KeyCode.CtrlC => return PluginViewTransition.Close(viewId()); case _ => () }
        if (renderFailed || pending) {
            return match (key.code) {
                case KeyCode.Esc => PluginViewTransition.Close(viewId())
                case _ => PluginViewTransition.None }
        }
        match (confirmation) {
            case Some(value) =>
                match (key.code) {
                    case KeyCode.Esc => pending = true; return PluginViewTransition.Confirm(viewId(), "2", pluginViewText(value, "request_digest"), false)
                    case KeyCode.Tab | KeyCode.BackTab | KeyCode.Left | KeyCode.Right => confirmYes = !confirmYes
                    case KeyCode.Enter => pending = true; return PluginViewTransition.Confirm(viewId(), "2", pluginViewText(value, "request_digest"), confirmYes)
                    case _ => () }
                return PluginViewTransition.None
            case None => () }
        if (editing) {
            let finish = match (key.code) {
                case KeyCode.Esc | KeyCode.Tab | KeyCode.BackTab => true
                case KeyCode.Char(r's') => key.modifiers.ctrl
                case _ => false }
            if (finish) {
                stageEditor(); status = "Input staged locally; choose a declared action to submit"; return PluginViewTransition.None }
            let before = editArea().value
            let multiline = nodes()[focus].field("multiline").getOrThrow().boolValue
            match (key.code) {
                case KeyCode.Enter => if (!multiline) { stageEditor(); return PluginViewTransition.None }
                case _ => () }
            match (key.code) {
                case KeyCode.Char(value) => if (!isPluginViewPlainText(value.toString())) { return PluginViewTransition.None }
                case _ => () }
            try {
                reserveEditor(before.size + 4)
                let _ = editArea().handle(key)
                if (editArea().value.size > editorLimit()) {
                    editArea().setValue(before); status = "Host: input rejected; declared bound exceeded" }
                editArea().clearHistory()
            } catch (_: Exception) { editArea().setValue(before); status = "Host: input DATA capacity exhausted; edit preserved" }
            return PluginViewTransition.None
        }
        match (key.code) {
            case KeyCode.Esc => return PluginViewTransition.Close(viewId())
            case KeyCode.Tab | KeyCode.BackTab =>
                let count = nodes().size + 1
                let reverse = key.modifiers.shift || match (key.code) { case KeyCode.BackTab => true; case _ => false }
                let index = focus + 1
                focus = (index + if (reverse) { count - 1 } else { 1 }) % count - 1
                clearPreview()
            case KeyCode.Up => navigate(-1)
            case KeyCode.Down => navigate(1)
            case KeyCode.PageUp => scroll = max(0, scroll - max(1, bodyArea.height))
            case KeyCode.PageDown => scroll += max(1, bodyArea.height)
            case KeyCode.Home => scroll = 0
            case KeyCode.End => scroll = 4194304
            case KeyCode.Enter =>
                if (focus == -1 && !actions().isEmpty()) {
                    let action = actions()[actionIndex]
                    let captured = captureFields(); pending = true
                    return PluginViewTransition.Action(viewId(), pluginViewText(metadata.getOrThrow(), "revision"), pluginViewText(action, "id"), captured)
                } else if (focus >= 0 && pluginViewText(nodes()[focus], "kind") == "input") { beginEditor(nodes()[focus]) }
            case _ => () }
        PluginViewTransition.None
    }
    private func navigate(delta: Int64): Unit {
        if (focus == -1) { actionIndex = max(0, min(actions().size - 1, actionIndex + delta)); return }
        let node = nodes()[focus]; let kind = pluginViewText(node, "kind")
        if (kind == "list" || kind == "table") {
            let rows = node.field(if (kind == "list") { "items" } else { "rows" }).getOrThrow().items
            if (rows.isEmpty()) { return }
            let id = pluginViewText(node, "id"); var selected: Int64 = -1
            for (i in 0..rows.size where pluginViewText(rows[i], "id") == fields[id]) { selected = i }
            let next = max(0, min(rows.size - 1, selected + delta))
            let value = pluginViewText(rows[next], "id"); fieldBytes += value.size - fields[id].size; fields[id] = value
        } else { scroll = max(0, scroll + delta) }
    }
    // Read-only panes never split or lay out the entire large Host source.
    // Clip visible rows at UTF-8 boundaries; full input/raw evidence is intact.
    private func renderPlain(frame: Frame, area: Rect, text: String, theme: ProductTheme): Unit {
        if (previewOffsets.isEmpty()) {
            var count: Int64 = 1
            for (index in 0..text.size where text[index] == b'\n') { count++ }
            try {
                document.getOrThrow().reserveUiBytes(2097152 + document.getOrThrow().primaryContent().size * 8 +
                    document.getOrThrow().modelJson().size * 16 + fieldBytes * 8 + count * 16)
            } catch (_: Exception) {
                renderFailed = true; status = "Host: View preview DATA capacity exhausted · Esc closes; raw source is unchanged"
                return
            }
            previewText = text
            previewOffsets = Array<Int64>(count, repeat: 0)
            var row: Int64 = 1
            for (index in 0..text.size where text[index] == b'\n') { previewOffsets[row] = index + 1; row++ }
        }
        scroll = min(scroll, max(0, previewOffsets.size - 1))
        let visible = min(area.height, previewOffsets.size - scroll)
        for (row in 0..visible) {
            let line = scroll + row; let start = previewOffsets[line]
            let limit = if (line + 1 < previewOffsets.size) { previewOffsets[line + 1] - 1 } else { previewText.size }
            var end = min(limit, start + max(1, area.width) * 4)
            while (end < limit && end > start && (previewText[end] & 192) == 128) { end-- }
            frame.canvas().drawText(area.x, area.y + row, cut(previewText[start..end], area.width),
                Style(fg: theme.text, bg: theme.background))
        }
    }
    private func clearPreview(): Unit { previewText = ""; previewOffsets = []; scroll = 0 }
    func updateMouse(mouse: MouseEvent): PluginViewTransition {
        if (!isActive() || pending || renderFailed) { return PluginViewTransition.None }
        if (editing) {
            let _ = editArea().handleMouse(mouse, bodyArea)
            return PluginViewTransition.None
        }
        match ((mouse.kind, mouse.button)) {
            case (MouseKind.Scroll, MouseButton.WheelUp) => if (confirmation.isNone()) { navigate(-3) }
            case (MouseKind.Scroll, MouseButton.WheelDown) => if (confirmation.isNone()) { navigate(3) }
            case (MouseKind.Down, MouseButton.Left) =>
            if (confirmation.isSome() && mouse.y == surfaceArea.bottom - 4) { confirmYes = mouse.x < surfaceArea.x + 9 }
            else if (confirmation.isNone() && mouse.y >= surfaceArea.bottom - 5 && mouse.y < surfaceArea.bottom - 2 &&
                !actions().isEmpty()) {
                actionIndex = min(actions().size - 1, max(0, actionIndex - 1) + mouse.y - (surfaceArea.bottom - 5))
                focus = -1; clearPreview()
            } else if (focus >= 0 && pluginViewText(nodes()[focus], "kind") == "input" &&
                mouse.x >= bodyArea.x && mouse.x < bodyArea.right && mouse.y >= bodyArea.y && mouse.y < bodyArea.bottom) {
                beginEditor(nodes()[focus])
            }
            case _ => ()
        }
        PluginViewTransition.None
    }
    func render(frame: Frame, theme: ProductTheme, terminalUnicode: Bool, area!: ?Rect = None): Unit {
        let _ = terminalUnicode
        if (!isActive()) { return }
        let surface = area ?? frame.area
        surfaceArea = surface
        let canvas = frame.canvas(); let meta = metadata.getOrThrow(); let data = currentModel()
        let header = "HOST View · " + pluginViewText(meta, "namespace") + "." + pluginViewText(meta, "name") +
            " · generation " + pluginViewText(meta, "generation")
        canvas.drawText(surface.x, surface.y, cut(header, surface.width), Style(fg: theme.accent, bg: theme.background))
        canvas.drawText(surface.x, surface.y + 1, cut("Package " + pluginViewText(meta, "package_digest"), surface.width), Style(fg: theme.muted, bg: theme.background))
        canvas.drawText(surface.x, surface.y + 2, cut("PLUGIN: " + pluginViewText(data, "title") + " · status " + pluginViewText(data, "status"), surface.width), Style(fg: theme.text, bg: theme.background))
        bodyArea = Rect(surface.x, surface.y + 4, surface.width, max(1, surface.height - 10))
        match (confirmation) {
            case Some(value) =>
                canvas.drawText(bodyArea.x, bodyArea.y, "HOST BUSINESS CONFIRMATION", Style(fg: theme.warning, bg: theme.background))
                renderPlain(frame, Rect(bodyArea.x, bodyArea.y + 2, bodyArea.width, max(1, bodyArea.height - 3)), pluginViewText(value, "description"), theme)
                canvas.drawText(surface.x, surface.bottom - 4, if (confirmYes) { "[ YES ]    No" } else { "  Yes    [ NO ]" }, Style(fg: theme.accent, bg: theme.background))
            case None =>
                if (editing) {
                    frame.renderWidget(editArea(), bodyArea); frame.setCursor(editArea().cursorPosition(bodyArea))
                } else if (focus >= 0) {
                    let node = nodes()[focus]; let kind = pluginViewText(node, "kind")
                    canvas.drawText(surface.x, surface.y + 3, cut("Node " + (focus + 1).toString() + "/" + nodes().size.toString() + " · " + pluginViewText(node, "id") + " · " + kind + " · " + pluginViewText(node, "label"), surface.width), Style(fg: theme.secondary, bg: theme.background))
                    if (kind == "list" || kind == "table") { renderSelection(frame, bodyArea, node, theme) }
                    else { renderPlain(frame, bodyArea, nodeText(node), theme) }
                } else { renderPlain(frame, bodyArea, pluginViewText(data, "summary"), theme) }
                if (!actions().isEmpty()) {
                    let first = max(0, actionIndex - 1)
                    for (offset in 0..3 where first + offset < actions().size) {
                        let i = first + offset
                        canvas.drawText(surface.x, surface.bottom - 5 + offset, cut((if (focus == -1 && i == actionIndex) { "> " } else { "  " }) + pluginViewText(actions()[i], "label"), surface.width), Style(fg: if (focus == -1 && i == actionIndex) { theme.accent } else { theme.text }, bg: theme.background))
                    }
                }
        }
        canvas.drawText(surface.x, surface.bottom - 2, cut(status, surface.width), Style(fg: theme.muted, bg: theme.background))
        canvas.drawText(surface.x, surface.bottom - 1, cut(if (confirmation.isSome()) { "Tab/Left/Right choose · Enter confirms selected choice · Esc declines" } else if (editing) { "Ctrl+S stage input · Esc return · no business control yet" } else { "Tab nodes/actions · arrows navigate · Enter edit/submit · Esc close" }, surface.width), Style(fg: theme.muted, bg: theme.background))
    }
    private func renderSelection(frame: Frame, area: Rect, node: AgentValue, theme: ProductTheme): Unit {
        let table = pluginViewText(node, "kind") == "table"
        let rows = node.field(if (table) { "rows" } else { "items" }).getOrThrow().items
        var selected: Int64 = -1
        for (i in 0..rows.size where pluginViewText(rows[i], "id") == fields[pluginViewText(node, "id")]) { selected = i }
        let first = max(0, selected - area.height + 2); var y = area.y
        if (table) {
            let names = node.field("columns").getOrThrow().items
            let titles = Array<String>(names.size, { i => names[i].text })
            frame.canvas().drawText(area.x, y, cut(String.join(titles, delimiter: " | "), area.width), Style(fg: theme.secondary, bg: theme.background)); y++
        }
        for (i in first..rows.size where y < area.bottom) {
            let row = rows[i]
            let text = if (table) {
                let cells = row.field("cells").getOrThrow().items
                String.join(Array<String>(cells.size, { j => cells[j].text }), delimiter: " | ")
            } else { pluginViewText(row, "text") }
            frame.canvas().drawText(area.x, y, cut((if (i == selected) { "> " } else { "  " }) + text, area.width), Style(fg: if (i == selected) { theme.accent } else { theme.text }, bg: theme.background)); y++
        }
    }
}
