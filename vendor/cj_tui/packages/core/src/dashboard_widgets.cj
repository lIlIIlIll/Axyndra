package core

import std.collection.*

public class MetricCard <: Widget {
    private let title: String
    private let value: String
    private let detail: String
    private let trend: String
    private let style: Style
    private let valueStyle: Style

    public init(
        title: String,
        value: String,
        detail!: String = "",
        trend!: String = "",
        style!: Style = Style.default(),
        valueStyle!: Style = Style(fg: Color.Cyan, modifier: Modifier.strong())
    ) {
        this.title = title
        this.value = value
        this.detail = detail
        this.trend = trend
        this.style = style
        this.valueStyle = valueStyle
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        buffer.setString(area.x, area.y, truncate(title, area.width), style: style)
        if (area.height > 1) {
            buffer.setString(area.x, area.y + 1, truncate(value, area.width), style: valueStyle)
        }
        if (area.height > 2 && !detail.isEmpty()) {
            buffer.setString(area.x, area.y + 2, truncate(detail, area.width), style: style)
        }
        if (area.height > 3 && !trend.isEmpty()) {
            buffer.setString(area.x, area.y + 3, truncate(trend, area.width), style: style)
        }
    }
}

public class Meter <: Widget {
    private let label: String
    private let value: Int64
    private let total: Int64
    private let style: Style
    private let fillStyle: Style

    public init(label: String, value: Int64, total!: Int64 = 100, style!: Style = Style(fg: Color.Indexed(8)), fillStyle!: Style = Style(fg: Color.Green)) {
        this.label = label
        this.value = max(0, value)
        this.total = max(1, total)
        this.style = style
        this.fillStyle = fillStyle
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        let labelWidth = min(area.width, max(0, displayWidthFast(label) + 1))
        if (labelWidth > 0) {
            buffer.setString(area.x, area.y, truncate(label, labelWidth), style: style)
        }
        let bar = Rect(area.x + labelWidth, area.y, max(0, area.width - labelWidth), 1)
        ProgressBar(value, total: total, style: style, fillStyle: fillStyle, labelMode: ProgressBarLabelMode.Percent).render(bar, buffer)
    }
}

public class LegendItem {
    public let label: String
    public let symbol: String
    public let style: Style

    public init(label: String, symbol!: String = "#", style!: Style = Style(fg: Color.Cyan)) {
        this.label = label
        this.symbol = symbol
        this.style = style
    }
}

public class Legend <: Widget {
    private let items: Array<LegendItem>
    private let gap: String

    public init(items: Array<LegendItem>, gap!: String = "  ") {
        this.items = items
        this.gap = gap
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        var x = area.x
        for (item in items) {
            let text = item.symbol + " " + item.label
            if (x >= area.right) { return }
            buffer.setString(x, area.y, truncate(text, area.right - x), style: item.style)
            x += displayWidthFast(text) + gap.size
            if (x < area.right) {
                buffer.setString(x - gap.size, area.y, gap, style: Style.default())
            }
        }
    }
}

public class TimeSeriesChart <: Widget {
    private let values: Array<Int64>
    private let maxValue: Int64
    private let style: Style

    public init(values: Array<Int64>, maxValue!: Int64 = 0, style!: Style = Style(fg: Color.Cyan)) {
        this.values = values
        this.maxValue = max(0, maxValue)
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0 || values.size == 0) { return }
        let maxV = max(1, if (maxValue > 0) { maxValue } else { maxArray(values) })
        let count = min(area.width, values.size)
        for (i in 0..count) {
            let height = max(1, values[i] * area.height / maxV)
            for (dy in 0..height) {
                buffer.setString(area.x + i, area.bottom - 1 - dy, "#", style: style)
            }
        }
    }
}

public class HeaderBar <: Widget {
    private let title: String
    private let left: String
    private let right: String
    private let style: Style

    public init(title: String, left!: String = "", right!: String = "", style!: Style = Style(fg: Color.White, modifier: Modifier.strong())) {
        this.title = title
        this.left = left
        this.right = right
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        renderBar(area, buffer, left, title, right, style)
    }
}

public class FooterBar <: Widget {
    private let left: String
    private let center: String
    private let right: String
    private let style: Style

    public init(left!: String = "", center!: String = "", right!: String = "", style!: Style = Style(fg: Color.Indexed(8))) {
        this.left = left
        this.center = center
        this.right = right
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        renderBar(area, buffer, left, center, right, style)
    }
}

public class EmptyState <: Widget {
    private let title: String
    private let detail: String
    private let style: Style

    public init(title!: String = "No data", detail!: String = "", style!: Style = Style(fg: Color.Indexed(8))) {
        this.title = title
        this.detail = detail
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        renderCenteredLines(area, buffer, [title, detail], style)
    }
}

public class ErrorBox <: Widget {
    private let message: String
    private let detail: String

    public init(message: String, detail!: String = "") {
        this.message = message
        this.detail = detail
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        let block = Block(BlockOptions(title: "Error", borderKind: BorderKind.Ascii, borderStyle: Style(fg: Color.Red), titleStyle: Style(fg: Color.Red)))
        let inner = block.renderInner(area, buffer)
        renderCenteredLines(inner, buffer, [message, detail], Style(fg: Color.Red))
    }
}

public class LoadingOverlay <: Widget {
    private let label: String
    private let frame: Int64

    public init(label!: String = "Loading", frame!: Int64 = 0) {
        this.label = label
        this.frame = max(0, frame)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        Spinner(label: label, frame: frame).render(centeredViewport(area, min(area.width, label.size + 4), 1), buffer)
    }
}

public class Skeleton <: Widget {
    private let rows: Int64
    private let style: Style

    public init(rows!: Int64 = 3, style!: Style = Style(fg: Color.Indexed(8))) {
        this.rows = max(0, rows)
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        let count = min(rows, area.height)
        for (row in 0..count) {
            let width = max(1, area.width - row % 3)
            buffer.setString(area.x, area.y + row, repeat("-", min(area.width, width)), style: style)
        }
    }
}

public class InlineAlert <: Widget {
    private let message: String
    private let state: StyleState

    public init(message: String, state!: StyleState = StyleState.Accent) {
        this.message = message
        this.state = state
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        let style = match (state) {
            case StyleState.Error => Style(fg: Color.Red)
            case StyleState.Disabled => Style(fg: Color.Indexed(8))
            case StyleState.Selected => Style(fg: Color.Green)
            case StyleState.Focused => Style(fg: Color.Cyan)
            case StyleState.Accent => Style(fg: Color.Yellow)
            case StyleState.Normal => Style.default()
        }
        buffer.setString(area.x, area.y, truncate(message, area.width), style: style)
    }
}

func renderBar(area: Rect, buffer: Buffer, left: String, center: String, right: String, style: Style): Unit {
    if (area.width <= 0 || area.height <= 0) { return }
    buffer.fillLine(area.y, area.x, area.width, style: style)
    if (!left.isEmpty()) {
        buffer.setString(area.x, area.y, truncate(left, area.width), style: style)
    }
    if (!center.isEmpty()) {
        let text = truncate(center, area.width)
        buffer.setString(alignedX(area, displayWidthFast(text), TextAlign.Center), area.y, text, style: style)
    }
    if (!right.isEmpty()) {
        let text = truncate(right, area.width)
        buffer.setString(area.right - displayWidthFast(text), area.y, text, style: style)
    }
}

func renderCenteredLines(area: Rect, buffer: Buffer, lines: Array<String>, style: Style): Unit {
    if (area.width <= 0 || area.height <= 0) { return }
    let count = min(lines.size, area.height)
    let startY = area.y + max(0, (area.height - count) / 2)
    for (i in 0..count) {
        if (lines[i].isEmpty()) { continue }
        let text = truncate(lines[i], area.width)
        buffer.setString(alignedX(Rect(area.x, startY + i, area.width, 1), displayWidthFast(text), TextAlign.Center), startY + i, text, style: style)
    }
}
