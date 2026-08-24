package core

import std.collection.*

public class MenuItem {
    public let label: String
    public let action: String
    public let enabled: Bool

    public init(label: String, action!: String = "", enabled!: Bool = true) {
        this.label = label
        this.action = if (action.isEmpty()) { label } else { action }
        this.enabled = enabled
    }
}

public class Menu <: Widget {
    private let title: String
    private let items: Array<MenuItem>
    public var selected: Int64
    private let block: ?Block
    private let style: Style
    private let selectedStyle: Style
    private let disabledStyle: Style

    public init(
        title: String,
        items: Array<MenuItem>,
        selected!: Int64 = 0,
        block!: ?Block = None,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White),
        disabledStyle!: Style = Style(fg: Color.Indexed(8))
    ) {
        this.title = title
        this.items = items
        this.selected = clamp(selected, 0, max(0, items.size - 1))
        this.block = block
        this.style = style
        this.selectedStyle = selectedStyle
        this.disabledStyle = disabledStyle
    }

    public func handle(key: KeyEvent): ?String {
        if (items.size == 0) { return None }
        match (key.code) {
            case KeyCode.Up =>
                selected = max(0, selected - 1)
                None
            case KeyCode.Down =>
                selected = min(items.size - 1, selected + 1)
                None
            case KeyCode.Home =>
                selected = 0
                None
            case KeyCode.End =>
                selected = items.size - 1
                None
            case KeyCode.Enter | KeyCode.Char(r' ') =>
                let item = items[selected]
                if (item.enabled) { Some(item.action) } else { None }
            case _ => None
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        } else if (!title.isEmpty()) {
            buffer.setString(area.x, area.y, truncate(title, area.width), style: style)
            target = Rect(area.x, area.y + 1, area.width, max(0, area.height - 1))
        }
        for (row in 0..min(target.height, items.size)) {
            let item = items[row]
            let rowStyle = if (!item.enabled) {
                disabledStyle
            } else if (row == selected) {
                selectedStyle
            } else {
                style
            }
            buffer.setString(target.x, target.y + row, truncate(item.label, target.width), style: rowStyle)
        }
    }
}

public class MenuBar <: Widget {
    private let menus: Array<String>
    public var selected: Int64
    private let style: Style
    private let selectedStyle: Style

    public init(
        menus: Array<String>,
        selected!: Int64 = 0,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White)
    ) {
        this.menus = menus
        this.selected = clamp(selected, 0, max(0, menus.size - 1))
        this.style = style
        this.selectedStyle = selectedStyle
    }

    public func handle(key: KeyEvent): Bool {
        if (menus.size == 0) { return false }
        match (key.code) {
            case KeyCode.Left =>
                selected = max(0, selected - 1)
                true
            case KeyCode.Right =>
                selected = min(menus.size - 1, selected + 1)
                true
            case KeyCode.Home =>
                selected = 0
                true
            case KeyCode.End =>
                selected = menus.size - 1
                true
            case _ => false
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        var x = area.x
        for (i in 0..menus.size) {
            if (x >= area.right) { return }
            let label = " " + menus[i] + " "
            let rowStyle = if (i == selected) { selectedStyle } else { style }
            buffer.setString(x, area.y, truncate(label, area.right - x), style: rowStyle)
            x += displayWidth(label)
        }
    }
}

public class CommandPalette <: Widget {
    private let items: Array<MenuItem>
    public var query: String
    public var selected: Int64
    private let block: ?Block
    private let style: Style
    private let selectedStyle: Style

    public init(
        items: Array<MenuItem>,
        query!: String = "",
        selected!: Int64 = 0,
        block!: ?Block = Some(Block(title: "Command")),
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White)
    ) {
        this.items = items
        this.query = query
        this.selected = max(0, selected)
        this.block = block
        this.style = style
        this.selectedStyle = selectedStyle
        clampSelection()
    }

    public func handle(key: KeyEvent): ?String {
        match (key.code) {
            case KeyCode.Char(r) =>
                query += runeToString(r)
                selected = 0
                None
            case KeyCode.Backspace =>
                if (!query.isEmpty()) { query = query[..previousRuneOffset(query, query.size)] }
                selected = 0
                None
            case KeyCode.Up =>
                selected = max(0, selected - 1)
                None
            case KeyCode.Down =>
                selected = min(max(0, filtered().size - 1), selected + 1)
                None
            case KeyCode.Enter =>
                let rows = filtered()
                if (selected >= 0 && selected < rows.size && rows[selected].enabled) {
                    Some(rows[selected].action)
                } else {
                    None
                }
            case _ => None
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        buffer.setString(target.x, target.y, truncate("> " + query, target.width), style: style)
        let rows = filtered()
        for (row in 0..min(max(0, target.height - 1), rows.size)) {
            let item = rows[row]
            buffer.setString(
                target.x,
                target.y + 1 + row,
                truncate(item.label, target.width),
                style: if (row == selected) { selectedStyle } else { style }
            )
        }
    }

    private func clampSelection(): Unit {
        selected = clamp(selected, 0, max(0, filtered().size - 1))
    }

    private func filtered(): Array<MenuItem> {
        if (query.isEmpty()) { return items }
        let rows = ArrayList<MenuItem>()
        for (item in items) {
            if (item.label.contains(query) || item.action.contains(query)) {
                rows.add(item)
            }
        }
        rows.toArray()
    }
}

public class Toast {
    public let message: String
    public let ttl: Int64
    public let style: Style

    public init(message: String, ttl!: Int64 = 3, style!: Style = Style(fg: Color.Black, bg: Color.Yellow)) {
        this.message = message
        this.ttl = max(0, ttl)
        this.style = style
    }
}

public class ToastManager <: Widget {
    private let toasts = ArrayList<Toast>()

    public init(toasts!: Array<Toast> = []) {
        for (toast in toasts) {
            this.toasts.add(toast)
        }
    }

    public func push(toast: Toast): Unit {
        toasts.add(toast)
    }

    public func count(): Int64 {
        toasts.size
    }

    public func tick(): Unit {
        let kept = ArrayList<Toast>()
        for (toast in toasts) {
            if (toast.ttl > 1) {
                kept.add(Toast(toast.message, ttl: toast.ttl - 1, style: toast.style))
            }
        }
        while (toasts.size > 0) { toasts.remove(at: 0) }
        for (toast in kept) { toasts.add(toast) }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        let rows = min(area.height, toasts.size)
        for (i in 0..rows) {
            let toast = toasts[toasts.size - rows + i]
            buffer.setString(area.x, area.y + i, truncate(toast.message, area.width), style: toast.style)
        }
    }
}

public class Spinner <: Widget {
    private let label: String
    private let frame: Int64
    private let style: Style

    public init(label!: String = "", frame!: Int64 = 0, style!: Style = Style(fg: Color.Cyan)) {
        this.label = label
        this.frame = max(0, frame)
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        let frames = ["|", "/", "-", "\\"]
        let text = frames[frame % frames.size] + if (label.isEmpty()) { "" } else { " " + label }
        buffer.setString(area.x, area.y, truncate(text, area.width), style: style)
    }
}

public class Dialog <: Widget {
    private let title: String
    private let body: String
    private let buttons: Array<String>
    public var selected: Int64
    private let width: Int64
    private let height: Int64
    private let style: Style
    private let selectedStyle: Style

    public init(
        title!: String = "",
        body!: String = "",
        buttons!: Array<String> = ["OK"],
        selected!: Int64 = 0,
        width!: Int64 = 40,
        height!: Int64 = 7,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White)
    ) {
        this.title = title
        this.body = body
        this.buttons = buttons
        this.selected = clamp(selected, 0, max(0, buttons.size - 1))
        this.width = max(4, width)
        this.height = max(4, height)
        this.style = style
        this.selectedStyle = selectedStyle
    }

    public func handle(key: KeyEvent): ?String {
        match (key.code) {
            case KeyCode.Left =>
                selected = max(0, selected - 1)
                None
            case KeyCode.Right =>
                selected = min(max(0, buttons.size - 1), selected + 1)
                None
            case KeyCode.Enter =>
                if (buttons.size > 0) { Some(buttons[selected]) } else { None }
            case _ => None
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        let actualWidth = min(width, area.width)
        let actualHeight = min(height, area.height)
        if (actualWidth <= 0 || actualHeight <= 0) { return }
        let x = area.x + max(0, (area.width - actualWidth) / 2)
        let y = area.y + max(0, (area.height - actualHeight) / 2)
        let dialogArea = Rect(x, y, actualWidth, actualHeight)
        let block = Block(title: title, style: style)
        block.render(dialogArea, buffer)
        let inner = block.inner(dialogArea)
        Paragraph(body, wrap: WrapMode.Word, style: style).render(Rect(inner.x, inner.y, inner.width, max(0, inner.height - 1)), buffer)
        var bx = inner.x
        let by = dialogArea.bottom - 2
        for (i in 0..buttons.size) {
            if (bx >= inner.right) { return }
            let label = "[" + buttons[i] + "]"
            buffer.setString(bx, by, truncate(label, inner.right - bx), style: if (i == selected) { selectedStyle } else { style })
            bx += displayWidth(label) + 1
        }
    }
}

public class ConfirmDialog <: Widget {
    private let message: String
    public var confirmed: Bool = false
    public init(message: String) { this.message = message }
    public func handle(key: KeyEvent): ?Bool {
        match (key.code) {
            case KeyCode.Char(r'y') | KeyCode.Enter => confirmed = true; Some(true)
            case KeyCode.Char(r'n') | KeyCode.Esc => confirmed = false; Some(false)
            case _ => None
        }
    }
    public func render(area: Rect, buffer: Buffer): Unit {
        Dialog(title: "Confirm", body: message, buttons: ["No", "Yes"], selected: if (confirmed) { 1 } else { 0 }).render(area, buffer)
    }
}
