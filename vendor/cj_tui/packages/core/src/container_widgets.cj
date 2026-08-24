package core

import std.collection.*

public class VBox <: Widget {
    private let children: Array<Widget>
    private let gap: Int64
    private let padding: Spacing

    public init(children: Array<Widget>, gap!: Int64 = 0, padding!: Spacing = Spacing.zero()) {
        this.children = children
        this.gap = max(0, gap)
        this.padding = padding
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        let inner = padding.inner(area)
        if (children.size == 0 || inner.width <= 0 || inner.height <= 0) { return }
        let totalGap = gap * max(0, children.size - 1)
        let childHeight = max(0, (inner.height - totalGap) / children.size)
        var y = inner.y
        for (i in 0..children.size) {
            let remaining = inner.bottom - y
            let height = if (i == children.size - 1) { remaining } else { min(childHeight, remaining) }
            children[i].render(Rect(inner.x, y, inner.width, height), buffer)
            y += height + gap
            if (y >= inner.bottom) { return }
        }
    }
}

public class HBox <: Widget {
    private let children: Array<Widget>
    private let gap: Int64
    private let padding: Spacing

    public init(children: Array<Widget>, gap!: Int64 = 0, padding!: Spacing = Spacing.zero()) {
        this.children = children
        this.gap = max(0, gap)
        this.padding = padding
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        let inner = padding.inner(area)
        if (children.size == 0 || inner.width <= 0 || inner.height <= 0) { return }
        let totalGap = gap * max(0, children.size - 1)
        let childWidth = max(0, (inner.width - totalGap) / children.size)
        var x = inner.x
        for (i in 0..children.size) {
            let remaining = inner.right - x
            let width = if (i == children.size - 1) { remaining } else { min(childWidth, remaining) }
            children[i].render(Rect(x, inner.y, width, inner.height), buffer)
            x += width + gap
            if (x >= inner.right) { return }
        }
    }
}

public class Stack <: Widget {
    private let children: Array<Widget>

    public init(children: Array<Widget>) {
        this.children = children
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        for (child in children) {
            child.render(area, buffer)
        }
    }
}

public class Overlay <: Widget {
    private let base: Widget
    private let overlays: Array<Widget>

    public init(base: Widget, overlays!: Array<Widget> = []) {
        this.base = base
        this.overlays = overlays
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        base.render(area, buffer)
        for (overlay in overlays) {
            overlay.render(area, buffer)
        }
    }
}

public class Padding <: Widget {
    private let child: Widget
    private let spacing: Spacing

    public init(child: Widget, spacing: Spacing) {
        this.child = child
        this.spacing = spacing
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        child.render(spacing.inner(area), buffer)
    }
}

public class Margin <: Widget {
    private let child: Widget
    private let spacing: Spacing

    public init(child: Widget, spacing: Spacing) {
        this.child = child
        this.spacing = spacing
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        child.render(spacing.inner(area), buffer)
    }
}

public class Centered <: Widget {
    private let child: Widget
    private let width: Int64
    private let height: Int64

    public init(child: Widget, width: Int64, height: Int64) {
        this.child = child
        this.width = max(1, width)
        this.height = max(1, height)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        child.render(centeredViewport(area, width, height), buffer)
    }
}

public class Dock <: Widget {
    private let top: ?Widget
    private let bottom: ?Widget
    private let left: ?Widget
    private let right: ?Widget
    private let center: ?Widget
    private let topHeight: Int64
    private let bottomHeight: Int64
    private let leftWidth: Int64
    private let rightWidth: Int64

    public init(
        top!: ?Widget = None,
        bottom!: ?Widget = None,
        left!: ?Widget = None,
        right!: ?Widget = None,
        center!: ?Widget = None,
        topHeight!: Int64 = 1,
        bottomHeight!: Int64 = 1,
        leftWidth!: Int64 = 16,
        rightWidth!: Int64 = 16
    ) {
        this.top = top
        this.bottom = bottom
        this.left = left
        this.right = right
        this.center = center
        this.topHeight = max(0, topHeight)
        this.bottomHeight = max(0, bottomHeight)
        this.leftWidth = max(0, leftWidth)
        this.rightWidth = max(0, rightWidth)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var inner = area
        match (top) {
            case Some(widget) =>
                let h = min(inner.height, topHeight)
                widget.render(Rect(inner.x, inner.y, inner.width, h), buffer)
                inner = Rect(inner.x, inner.y + h, inner.width, inner.height - h)
            case None => ()
        }
        match (bottom) {
            case Some(widget) =>
                let h = min(inner.height, bottomHeight)
                widget.render(Rect(inner.x, inner.bottom - h, inner.width, h), buffer)
                inner = Rect(inner.x, inner.y, inner.width, inner.height - h)
            case None => ()
        }
        match (left) {
            case Some(widget) =>
                let w = min(inner.width, leftWidth)
                widget.render(Rect(inner.x, inner.y, w, inner.height), buffer)
                inner = Rect(inner.x + w, inner.y, inner.width - w, inner.height)
            case None => ()
        }
        match (right) {
            case Some(widget) =>
                let w = min(inner.width, rightWidth)
                widget.render(Rect(inner.right - w, inner.y, w, inner.height), buffer)
                inner = Rect(inner.x, inner.y, inner.width - w, inner.height)
            case None => ()
        }
        match (center) {
            case Some(widget) => widget.render(inner, buffer)
            case None => ()
        }
    }
}

public class Scrollable <: Widget {
    private let lines: Array<String>
    private let state: ScrollState
    private let style: Style
    private let scrollbarStyle: Style

    public init(lines: Array<String>, state!: ScrollState = ScrollState(), style!: Style = Style.default(), scrollbarStyle!: Style = Style(fg: Color.Indexed(8))) {
        this.lines = lines
        this.state = state
        this.style = style
        this.scrollbarStyle = scrollbarStyle
    }

    public func handle(key: KeyEvent, viewportHeight: Int64): Bool {
        state.handle(key, lines.size, viewportHeight)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        let content = if (lines.size > area.height) { Rect(area.x, area.y, max(0, area.width - 1), area.height) } else { area }
        for (row in 0..content.height) {
            let index = state.offset + row
            if (index >= lines.size) { break }
            buffer.setString(content.x, content.y + row, truncate(lines[index], content.width), style: style)
        }
        if (lines.size > area.height && area.width > 1) {
            Scrollbar(lines.size, offset: state.offset, viewport: area.height, style: scrollbarStyle).render(area, buffer)
        }
    }
}
