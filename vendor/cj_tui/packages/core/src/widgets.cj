package core

import std.collection.*

public enum BorderKind {
    | Ascii
    | Unicode
    | Rounded
    | NoBorder
}

public enum TitleAlign {
    | Left
    | Center
    | Right
}

public enum BoxState {
    | Normal
    | Focused
    | Active
    | Error
    | Disabled
}

public class BorderSet {
    public let horizontal: String
    public let vertical: String
    public let topLeft: String
    public let topRight: String
    public let bottomLeft: String
    public let bottomRight: String

    public init(
        horizontal!: String = "-",
        vertical!: String = "|",
        topLeft!: String = "+",
        topRight!: String = "+",
        bottomLeft!: String = "+",
        bottomRight!: String = "+"
    ) {
        this.horizontal = horizontal
        this.vertical = vertical
        this.topLeft = topLeft
        this.topRight = topRight
        this.bottomLeft = bottomLeft
        this.bottomRight = bottomRight
    }

    public static func ascii(): BorderSet {
        BorderSet()
    }

    public static func unicode(): BorderSet {
        BorderSet(horizontal: "─", vertical: "│", topLeft: "┌", topRight: "┐", bottomLeft: "└", bottomRight: "┘")
    }

    public static func rounded(): BorderSet {
        BorderSet(horizontal: "─", vertical: "│", topLeft: "╭", topRight: "╮", bottomLeft: "╰", bottomRight: "╯")
    }
}

public class BlockOptions {
    public let title: String
    public let borderKind: BorderKind
    public let border: BorderSet
    public let titleAlign: TitleAlign
    public let padding: Spacing
    public let margin: Spacing
    public let backgroundStyle: Style
    public let borderStyle: Style
    public let contentStyle: Style
    public let titleStyle: Style
    public let state: BoxState
    public let asciiFallback: Bool
    public let theme: ?Theme

    public init(
        title!: String = "",
        borderKind!: BorderKind = BorderKind.Ascii,
        border!: BorderSet = BorderSet.ascii(),
        titleAlign!: TitleAlign = TitleAlign.Left,
        padding!: Spacing = Spacing.zero(),
        margin!: Spacing = Spacing.zero(),
        backgroundStyle!: Style = Style.default(),
        borderStyle!: Style = Style.default(),
        contentStyle!: Style = Style.default(),
        titleStyle!: Style = Style.default(),
        state!: BoxState = BoxState.Normal,
        asciiFallback!: Bool = false,
        theme!: ?Theme = None
    ) {
        this.title = title
        this.borderKind = borderKind
        this.border = border
        this.titleAlign = titleAlign
        this.padding = padding
        this.margin = margin
        this.backgroundStyle = backgroundStyle
        this.borderStyle = borderStyle
        this.contentStyle = contentStyle
        this.titleStyle = titleStyle
        this.state = state
        this.asciiFallback = asciiFallback
        this.theme = theme
    }
}

public class Block <: Widget {
    private let options: BlockOptions

    public init(title!: String = "", style!: Style = Style.default()) {
        this.options = BlockOptions(title: title, borderStyle: style, titleStyle: style)
    }

    public init(options: BlockOptions) {
        this.options = options
    }

    public func inner(area: Rect): Rect {
        contentArea(frameArea(area))
    }

    public func renderInner(area: Rect, buffer: Buffer): Rect {
        let frame = frameArea(area)
        if (frame.width <= 0 || frame.height <= 0) { return Rect(frame.x, frame.y, 0, 0) }
        let background = resolveBoxStyle(options.backgroundStyle)
        if (background != Style.default()) {
            buffer.fill(frame, style: background)
        }
        if (!isBorderNone(options.borderKind)) {
            renderBorder(frame, buffer)
            renderTitle(frame, buffer)
        }
        let content = contentArea(frame)
        if (content.width > 0 && content.height > 0 && options.contentStyle != Style.default()) {
            buffer.fill(content, style: resolveBoxStyle(options.contentStyle))
        }
        content
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        _ = renderInner(area, buffer)
    }

    private func frameArea(area: Rect): Rect {
        options.margin.inner(area)
    }

    private func contentArea(frame: Rect): Rect {
        let borderInset = if (isBorderNone(options.borderKind)) { Int64(0) } else { Int64(1) }
        options.padding.inner(Rect(
            frame.x + borderInset,
            frame.y + borderInset,
            frame.width - borderInset * 2,
            frame.height - borderInset * 2
        ))
    }

    private func renderBorder(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        let border = resolvedBorder()
        let style = resolveBoxStyle(options.borderStyle)
        if (area.height == 1) {
            buffer.setString(area.x, area.y, repeat(border.horizontal, area.width), style: style)
            return
        }
        buffer.setString(area.x, area.y, repeat(border.horizontal, area.width), style: style)
        buffer.setString(area.x, area.bottom - 1, repeat(border.horizontal, area.width), style: style)
        if (area.width > 1) {
            for (y in area.y + 1..area.bottom - 1) {
                buffer.setString(area.x, y, border.vertical, style: style)
                buffer.setString(area.right - 1, y, border.vertical, style: style)
            }
            buffer.setString(area.x, area.y, border.topLeft, style: style)
            buffer.setString(area.right - 1, area.y, border.topRight, style: style)
            buffer.setString(area.x, area.bottom - 1, border.bottomLeft, style: style)
            buffer.setString(area.right - 1, area.bottom - 1, border.bottomRight, style: style)
        }
    }

    private func renderTitle(area: Rect, buffer: Buffer): Unit {
        if (options.title.isEmpty() || area.width <= 4) { return }
        let text = truncate(options.title, max(0, area.width - 4))
        let width = displayWidthFast(text)
        let x = match (options.titleAlign) {
            case TitleAlign.Left => area.x + 2
            case TitleAlign.Center => area.x + max(1, (area.width - width) / 2)
            case TitleAlign.Right => area.right - width - 2
        }
        buffer.setString(max(area.x + 1, min(x, area.right - width - 1)), area.y, text, style: resolveBoxStyle(options.titleStyle))
    }

    private func resolvedBorder(): BorderSet {
        if (options.asciiFallback) { return BorderSet.ascii() }
        match (options.borderKind) {
            case BorderKind.Ascii => BorderSet.ascii()
            case BorderKind.Unicode => BorderSet.unicode()
            case BorderKind.Rounded => BorderSet.rounded()
            case BorderKind.NoBorder => BorderSet.ascii()
        }
    }

    private func resolveBoxStyle(style: Style): Style {
        let base = match (options.state) {
            case BoxState.Normal => themedNormal(style, options.theme)
            case BoxState.Focused => themedFocused(style, options.theme)
            case BoxState.Active => themedSelected(style, options.theme)
            case BoxState.Error => themedError(style, options.theme)
            case BoxState.Disabled => themedDisabled(style, options.theme)
        }
        base
    }
}

public class Panel <: Widget {
    private let block: Block
    private let child: ?Widget

    public init(block!: Block = Block(), child!: ?Widget = None) {
        this.block = block
        this.child = child
    }

    public init(options: BlockOptions, child!: ?Widget = None) {
        this.block = Block(options)
        this.child = child
    }

    public func renderInner(area: Rect, buffer: Buffer): Rect {
        let inner = block.renderInner(area, buffer)
        match (child) {
            case Some(w) => w.render(inner, buffer)
            case None => ()
        }
        inner
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        _ = renderInner(area, buffer)
    }
}

public class Paragraph <: Widget {
    private let text: String
    private let block: ?Block
    private let style: Style
    private let scroll: Int64
    private let wrap: WrapMode
    private let align: TextAlign

    public init(
        text: String,
        block!: ?Block = None,
        style!: Style = Style.default(),
        scroll!: Int64 = 0,
        wrap!: WrapMode = WrapMode.Character,
        align!: TextAlign = TextAlign.Left
    ) {
        this.text = text
        this.block = block
        this.style = style
        this.scroll = max(0, scroll)
        this.wrap = wrap
        this.align = align
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        let lines = wrapText(text, target.width, wrap)
        var row: Int64 = 0
        while (row < target.height && row + scroll < lines.size) {
            let line = lines[row + scroll]
            let x = alignedX(target, displayWidth(line), align)
            buffer.setString(x, target.y + row, truncate(line, target.width), style: style)
            row++
        }
    }
}

public class List <: Widget {
    private let items: Array<String>
    private let selected: ?Int64
    private let offset: Int64
    private let state: ?ListState
    private let block: ?Block
    private let style: Style
    private let selectedStyle: Style

    public init(
        items: Array<String>,
        selected!: ?Int64 = None,
        offset!: Int64 = 0,
        state!: ?ListState = None,
        block!: ?Block = None,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White)
    ) {
        this.items = items
        this.selected = selected
        this.offset = max(0, offset)
        this.state = state
        this.block = block
        this.style = style
        this.selectedStyle = selectedStyle
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        let rows = min(target.height, items.size)
        let renderOffset = match (state) {
            case Some(s) => max(0, s.offset)
            case None => offset
        }
        let renderSelected = match (state) {
            case Some(s) => s.selected
            case None => selected
        }
        for (i in 0..rows) {
            let itemIndex = i + renderOffset
            if (itemIndex >= items.size) { return }
            let active = match (renderSelected) {
                case Some(v) => v == itemIndex
                case None => false
            }
            let prefix = if (active) { "> " } else { "  " }
            let rowStyle = if (active) { selectedStyle } else { style }
            buffer.setString(target.x, target.y + i, prefix + items[itemIndex], style: rowStyle)
        }
    }
}

public class ListState {
    public var selected: ?Int64
    public var offset: Int64

    public init(selected!: ?Int64 = None, offset!: Int64 = 0) {
        this.selected = selected
        this.offset = max(0, offset)
    }

    public func select(index: ?Int64): Unit {
        selected = index
    }

    public func next(total: Int64): Unit {
        if (total <= 0) {
            selected = None
            offset = 0
            return
        }
        let current = match (selected) {
            case Some(v) => v
            case None => -1
        }
        selected = Some(min(total - 1, current + 1))
    }

    public func move(delta: Int64, total: Int64, viewportHeight!: Int64 = 0): Unit {
        if (total <= 0) {
            selected = None
            offset = 0
            return
        }
        let current = match (selected) {
            case Some(v) => v
            case None => if (delta >= 0) { -1 } else { total }
        }
        selected = Some(clamp(current + delta, 0, total - 1))
        if (viewportHeight > 0) {
            scrollToVisible(total, viewportHeight)
        }
    }

    public func moveWithDirty(delta: Int64, total: Int64, viewportHeight: Int64, area: Rect): DirtyRects {
        let beforeSelected = selected
        let beforeOffset = offset
        move(delta, total, viewportHeight: viewportHeight)
        let dirty = DirtyRects()
        if (beforeOffset != offset) {
            dirty.add(area)
            return dirty
        }
        addListRowDirty(dirty, area, beforeSelected, offset)
        addListRowDirty(dirty, area, selected, offset)
        dirty
    }

    public func previous(total: Int64): Unit {
        if (total <= 0) {
            selected = None
            offset = 0
            return
        }
        let current = match (selected) {
            case Some(v) => v
            case None => total
        }
        selected = Some(max(0, current - 1))
    }

    public func scrollToVisible(total: Int64, viewportHeight: Int64): Unit {
        if (total <= 0 || viewportHeight <= 0) {
            offset = 0
            return
        }
        let current = match (selected) {
            case Some(v) => clamp(v, 0, total - 1)
            case None => 0
        }
        if (current < offset) {
            offset = current
        } else if (current >= offset + viewportHeight) {
            offset = current - viewportHeight + 1
        }
        offset = clamp(offset, 0, max(0, total - viewportHeight))
    }
}

public class Table <: Widget {
    private let headers: Array<String>
    private let rows: Array<Array<String>>
    private let widths: Array<Int64>
    private let state: ?TableState
    private let block: ?Block
    private let style: Style
    private let headerStyle: Style
    private let selectedStyle: Style

    public init(
        headers: Array<String>,
        rows: Array<Array<String>>,
        widths!: Array<Int64> = [],
        state!: ?TableState = None,
        block!: ?Block = None,
        style!: Style = Style.default(),
        headerStyle!: Style = Style(fg: Color.Yellow, modifier: Modifier.strong()),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White)
    ) {
        this.headers = headers
        this.rows = rows
        this.widths = widths
        this.state = state
        this.block = block
        this.style = style
        this.headerStyle = headerStyle
        this.selectedStyle = selectedStyle
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        let colWidths = resolvedWidths(target.width)
        renderRow(target.x, target.y, headers, colWidths, headerStyle, buffer)
        if (target.height > 1) {
            buffer.setString(target.x, target.y + 1, repeat("-", target.width), style: headerStyle)
        }
        let rowLimit = min(rows.size, max(0, target.height - 2))
        let renderOffset = match (state) {
            case Some(s) => max(0, s.offset)
            case None => 0
        }
        let renderSelected: ?Int64 = match (state) {
            case Some(s) => s.selectedRow
            case None => None
        }
        for (i in 0..rowLimit) {
            let rowIndex = i + renderOffset
            if (rowIndex >= rows.size) { return }
            let active = match (renderSelected) {
                case Some(v) => v == rowIndex
                case None => false
            }
            let rowStyle = if (active) { selectedStyle } else { style }
            renderRow(target.x, target.y + 2 + i, rows[rowIndex], colWidths, rowStyle, buffer)
        }
    }

    private func resolvedWidths(total: Int64): Array<Int64> {
        if (widths.size > 0) {
            return widths
        }
        let cols = max(1, headers.size)
        let width = max(1, total / cols)
        Array<Int64>(cols, repeat: width)
    }

    private static func renderRow(
        x: Int64,
        y: Int64,
        cols: Array<String>,
        widths: Array<Int64>,
        style: Style,
        buffer: Buffer
    ): Unit {
        var cx = x
        let limit = min(cols.size, widths.size)
        for (i in 0..limit) {
            buffer.setString(cx, y, truncate(cols[i], widths[i]), style: style)
            cx += widths[i] + 1
        }
    }
}

public class TableState {
    public var selectedRow: ?Int64
    public var offset: Int64

    public init(selectedRow!: ?Int64 = None, offset!: Int64 = 0) {
        this.selectedRow = selectedRow
        this.offset = max(0, offset)
    }

    public func select(index: ?Int64): Unit {
        selectedRow = index
    }

    public func next(total: Int64): Unit {
        if (total <= 0) {
            selectedRow = None
            offset = 0
            return
        }
        let current = match (selectedRow) {
            case Some(v) => v
            case None => -1
        }
        selectedRow = Some(min(total - 1, current + 1))
    }

    public func move(delta: Int64, total: Int64, viewportHeight!: Int64 = 0): Unit {
        if (total <= 0) {
            selectedRow = None
            offset = 0
            return
        }
        let current = match (selectedRow) {
            case Some(v) => v
            case None => if (delta >= 0) { -1 } else { total }
        }
        selectedRow = Some(clamp(current + delta, 0, total - 1))
        if (viewportHeight > 0) {
            scrollToVisible(total, viewportHeight)
        }
    }

    public func previous(total: Int64): Unit {
        if (total <= 0) {
            selectedRow = None
            offset = 0
            return
        }
        let current = match (selectedRow) {
            case Some(v) => v
            case None => total
        }
        selectedRow = Some(max(0, current - 1))
    }

    public func scrollToVisible(total: Int64, viewportHeight: Int64): Unit {
        if (total <= 0 || viewportHeight <= 0) {
            offset = 0
            return
        }
        let current = match (selectedRow) {
            case Some(v) => clamp(v, 0, total - 1)
            case None => 0
        }
        if (current < offset) {
            offset = current
        } else if (current >= offset + viewportHeight) {
            offset = current - viewportHeight + 1
        }
        offset = clamp(offset, 0, max(0, total - viewportHeight))
    }
}

public class Scrollbar <: Widget {
    private let total: Int64
    private let offset: Int64
    private let viewport: Int64
    private let style: Style
    private let thumbStyle: Style

    public init(
        total: Int64,
        offset!: Int64 = 0,
        viewport!: Int64 = 0,
        style!: Style = Style(fg: Color.Indexed(8)),
        thumbStyle!: Style = Style(fg: Color.White)
    ) {
        this.total = max(0, total)
        this.offset = max(0, offset)
        this.viewport = max(0, viewport)
        this.style = style
        this.thumbStyle = thumbStyle
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0 || total <= viewport || viewport <= 0) {
            return
        }
        let x = area.right - 1
        for (y in area.y..area.bottom) {
            buffer.setString(x, y, "|", style: style)
        }
        let thumbHeight = max(1, area.height * viewport / total)
        let maxOffset = max(1, total - viewport)
        let maxThumbTop = max(0, area.height - thumbHeight)
        let thumbTop = area.y + min(maxThumbTop, offset * maxThumbTop / maxOffset)
        for (y in thumbTop..min(area.bottom, thumbTop + thumbHeight)) {
            buffer.setString(x, y, "#", style: thumbStyle)
        }
    }
}

public class Input <: Widget {
    public var value: String
    public var cursor: Int64
    private var viewportOffset: Int64 = 0
    private let block: ?Block
    private let style: Style
    private let placeholder: String
    private let placeholderStyle: Style

    public init(
        value!: String = "",
        cursor!: Int64 = 0,
        block!: ?Block = None,
        style!: Style = Style.default(),
        placeholder!: String = "",
        placeholderStyle!: Style = Style(fg: Color.Indexed(8))
    ) {
        this.value = value
        this.cursor = clampToRuneBoundary(value, cursor)
        this.block = block
        this.style = style
        this.placeholder = placeholder
        this.placeholderStyle = placeholderStyle
    }

    public func handle(key: KeyEvent): Bool {
        match (key.code) {
            case Char(r) =>
                insert(runeToString(r))
                true
            case Backspace =>
                backspace()
                true
            case Delete =>
                deleteForward()
                true
            case Left =>
                cursor = previousRuneOffset(value, cursor)
                true
            case Right =>
                cursor = nextRuneOffset(value, cursor)
                true
            case Home =>
                cursor = 0
                true
            case End =>
                cursor = value.size
                true
            case _ => false
        }
    }

    public func handleWithDirty(key: KeyEvent, area: Rect): ?DirtyRects {
        let beforeViewport = viewportOffset
        let beforeEmpty = value.isEmpty()
        if (!handle(key)) { return None }
        let dirty = DirtyRects()
        if (beforeViewport != viewportOffset || beforeEmpty != value.isEmpty()) {
            dirty.add(area)
        } else {
            dirty.add(Rect(area.x, area.y, area.width, min(Int64(1), area.height)))
        }
        Some(dirty)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        if (value.isEmpty() && !placeholder.isEmpty()) {
            buffer.setString(target.x, target.y, truncate(placeholder, target.width), style: placeholderStyle)
            return
        }
        ensureCursorVisible(target.width)
        buffer.setString(target.x, target.y, truncate(value[viewportOffset..], target.width), style: style)
    }

    public func cursorPosition(area: Rect): Position {
        var target = area
        if (let Some(b) <- block) {
            target = b.inner(area)
        }
        ensureCursorVisible(target.width)
        Position(target.x + min(displayWidth(value[viewportOffset..cursor]), target.width), target.y)
    }

    public func setValue(value: String, cursor!: Int64 = -1): Unit {
        this.value = value
        this.cursor = if (cursor < 0) { value.size } else { clampToRuneBoundary(value, cursor) }
        viewportOffset = 0
    }

    public func clear(): Unit {
        value = ""
        cursor = 0
        viewportOffset = 0
    }

    public func moveToStart(): Unit {
        cursor = 0
        viewportOffset = 0
    }

    public func moveToEnd(): Unit {
        cursor = value.size
    }

    private func insert(text: String): Unit {
        value = value[..cursor] + text + value[cursor..]
        cursor += text.size
    }

    private func backspace(): Unit {
        if (cursor <= 0) { return }
        let prev = previousRuneOffset(value, cursor)
        value = value[..prev] + value[cursor..]
        cursor = prev
    }

    private func deleteForward(): Unit {
        if (cursor >= value.size) { return }
        let next = nextRuneOffset(value, cursor)
        value = value[..cursor] + value[next..]
    }

    private func ensureCursorVisible(width: Int64): Unit {
        cursor = clampToRuneBoundary(value, cursor)
        viewportOffset = clampToRuneBoundary(value, viewportOffset)
        if (width <= 0 || value.isEmpty()) {
            viewportOffset = 0
            return
        }
        if (cursor < viewportOffset) {
            viewportOffset = cursor
        }
        while (displayWidth(value[viewportOffset..cursor]) > width && viewportOffset < cursor) {
            viewportOffset = nextRuneOffset(value, viewportOffset)
        }
        if (viewportOffset > value.size) {
            viewportOffset = value.size
        }
    }
}

func addListRowDirty(dirty: DirtyRects, area: Rect, selected: ?Int64, offset: Int64): Unit {
    match (selected) {
        case Some(index) =>
            let row = index - offset
            if (row >= 0 && row < area.height) {
                dirty.add(Rect(area.x, area.y + row, area.width, 1))
            }
        case None => ()
    }
}

public class FileDialog <: Widget {
    public let picker: FilePicker
    private let title: String
    public init(path!: String = ".", extension!: String = "", title!: String = "Files") {
        picker = FilePicker(path: path, extension: extension)
        this.title = title
    }
    public func selectedPath(): ?String { picker.selectedPath() }
    public func handle(key: KeyEvent, viewportHeight: Int64): Bool { picker.handle(key, viewportHeight) }
    public func render(area: Rect, buffer: Buffer): Unit {
        picker.render(area, buffer)
        Block(title: title).render(area, buffer)
    }
}
