package core

import std.collection.*

public enum ProgressBarDirection {
    | Horizontal
    | Vertical
}

public enum ProgressBarLabelMode {
    | Hidden
    | Percent
    | Value
    | Ratio
    | Text(String)
}

public class ProgressBarSymbols {
    public let filled: String
    public let empty: String
    public let head: String
    public let indeterminate: String

    public init(filled!: String = "#", empty!: String = "-", head!: String = "#", indeterminate!: String = "#") {
        this.filled = filled
        this.empty = empty
        this.head = head
        this.indeterminate = indeterminate
    }
}

public class ProgressBarSegment {
    public let value: Int64
    public let style: Style
    public let symbol: String

    public init(value: Int64, style!: Style = Style(fg: Color.Cyan), symbol!: String = "#") {
        this.value = max(0, value)
        this.style = style
        this.symbol = symbol
    }
}

public class ProgressBar <: Widget {
    private let value: Int64
    private let total: Int64
    private let label: String
    private let style: Style
    private let fillStyle: Style
    private let theme: ?Theme
    private let direction: ProgressBarDirection
    private let labelMode: ProgressBarLabelMode
    private let labelStyle: Style
    private let symbols: ProgressBarSymbols
    private let segments: Array<ProgressBarSegment>
    private let indeterminate: Bool
    private let phase: Int64

    public init(
        value: Int64,
        total!: Int64 = 100,
        label!: String = "",
        style!: Style = Style(fg: Color.Indexed(8)),
        fillStyle!: Style = Style(fg: Color.Cyan),
        theme!: ?Theme = None,
        direction!: ProgressBarDirection = ProgressBarDirection.Horizontal,
        labelMode!: ProgressBarLabelMode = ProgressBarLabelMode.Hidden,
        labelStyle!: Style = Style(fg: Color.White),
        symbols!: ProgressBarSymbols = ProgressBarSymbols(),
        segments!: Array<ProgressBarSegment> = [],
        indeterminate!: Bool = false,
        phase!: Int64 = 0
    ) {
        this.value = max(0, value)
        this.total = max(1, total)
        this.label = label
        this.style = style
        this.fillStyle = fillStyle
        this.theme = theme
        this.direction = direction
        this.labelMode = labelMode
        this.labelStyle = labelStyle
        this.symbols = symbols
        this.segments = segments
        this.indeterminate = indeterminate
        this.phase = max(0, phase)
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        match (direction) {
            case ProgressBarDirection.Horizontal => renderHorizontal(area, buffer)
            case ProgressBarDirection.Vertical => renderVertical(area, buffer)
        }
    }

    private func renderHorizontal(area: Rect, buffer: Buffer): Unit {
        buffer.setString(area.x, area.y, repeat(symbols.empty, area.width), style: themedNormal(style, theme))
        if (indeterminate) {
            renderHorizontalIndeterminate(area, buffer)
        } else if (segments.size > 0) {
            renderHorizontalSegments(area, buffer)
        } else {
            let filled = clamp(value, 0, total) * area.width / total
            if (filled > 0) {
                buffer.setString(area.x, area.y, repeat(symbols.filled, filled), style: themedAccent(fillStyle, theme))
                if (filled < area.width && !symbols.head.isEmpty()) {
                    buffer.setString(area.x + filled - 1, area.y, symbols.head, style: themedAccent(fillStyle, theme))
                }
            }
        }
        renderHorizontalLabel(area, buffer)
    }

    private func renderHorizontalIndeterminate(area: Rect, buffer: Buffer): Unit {
        let window = max(1, area.width / 3)
        let span = area.width + window
        let start = phase % span
        for (i in 0..window) {
            let x = area.x + start - window + i
            if (x >= area.x && x < area.right) {
                buffer.setString(x, area.y, symbols.indeterminate, style: themedAccent(fillStyle, theme))
            }
        }
    }

    private func renderHorizontalSegments(area: Rect, buffer: Buffer): Unit {
        var x = area.x
        var used = 0
        for (segment in segments) {
            if (x >= area.right) { break }
            let width = segment.value * area.width / total
            let clipped = min(area.right - x, max(0, width))
            if (clipped > 0) {
                buffer.setString(x, area.y, repeat(segment.symbol, clipped), style: themedAccent(segment.style, theme))
                x += clipped
                used += clipped
            }
        }
        if (used == 0 && value > 0) {
            let filled = max(1, clamp(value, 0, total) * area.width / total)
            buffer.setString(area.x, area.y, repeat(symbols.filled, min(area.width, filled)), style: themedAccent(fillStyle, theme))
        }
    }

    private func renderVertical(area: Rect, buffer: Buffer): Unit {
        for (row in 0..area.height) {
            buffer.setString(area.x, area.y + row, repeat(symbols.empty, area.width), style: themedNormal(style, theme))
        }
        if (indeterminate) {
            let window = max(1, area.height / 3)
            let span = area.height + window
            let start = phase % span
            for (i in 0..window) {
                let y = area.bottom - 1 - start + i
                if (y >= area.y && y < area.bottom) {
                    buffer.setString(area.x, y, repeat(symbols.indeterminate, area.width), style: themedAccent(fillStyle, theme))
                }
            }
        } else {
            let filled = clamp(value, 0, total) * area.height / total
            for (row in 0..filled) {
                let y = area.bottom - 1 - row
                buffer.setString(area.x, y, repeat(symbols.filled, area.width), style: themedAccent(fillStyle, theme))
            }
        }
        renderVerticalLabel(area, buffer)
    }

    private func renderHorizontalLabel(area: Rect, buffer: Buffer): Unit {
        let text = progressLabel()
        if (!text.isEmpty()) {
            let clipped = truncate(text, area.width)
            let x = alignedX(area, displayWidth(clipped), TextAlign.Center)
            buffer.setString(x, area.y, clipped, style: themedFocused(labelStyle, theme))
        }
    }

    private func renderVerticalLabel(area: Rect, buffer: Buffer): Unit {
        let text = progressLabel()
        if (!text.isEmpty()) {
            let clipped = truncate(text, area.width)
            let y = area.y + area.height / 2
            let x = alignedX(Rect(area.x, y, area.width, 1), displayWidth(clipped), TextAlign.Center)
            buffer.setString(x, y, clipped, style: themedFocused(labelStyle, theme))
        }
    }

    private func progressLabel(): String {
        if (!label.isEmpty()) { return label }
        match (labelMode) {
            case ProgressBarLabelMode.Hidden => ""
            case ProgressBarLabelMode.Percent => "${clamp(value, 0, total) * 100 / total}%"
            case ProgressBarLabelMode.Value => "${clamp(value, 0, total)}"
            case ProgressBarLabelMode.Ratio => "${clamp(value, 0, total)}/${total}"
            case ProgressBarLabelMode.Text(text) => text
        }
    }
}

public class Sparkline <: Widget {
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
        let maxV = if (maxValue > 0) { maxValue } else { maxArray(values) }
        let bars = [" ", ".", "-", "=", "#"]
        let count = min(area.width, values.size)
        for (i in 0..count) {
            let level = if (maxV <= 0) { 0 } else { clamp(values[i] * (bars.size - 1) / maxV, 0, bars.size - 1) }
            buffer.setString(area.x + i, area.y, bars[level], style: style)
        }
    }
}

public class Gauge <: Widget {
    private let value: Int64
    private let total: Int64
    private let label: String
    private let style: Style
    private let fillStyle: Style

    public init(
        value: Int64,
        total!: Int64 = 100,
        label!: String = "",
        style!: Style = Style(fg: Color.Indexed(8)),
        fillStyle!: Style = Style(fg: Color.Green)
    ) {
        this.value = max(0, value)
        this.total = max(1, total)
        this.label = label
        this.style = style
        this.fillStyle = fillStyle
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        ProgressBar(value, total: total, label: label, style: style, fillStyle: fillStyle).render(area, buffer)
    }
}

public class Chart <: Widget {
    private let values: Array<Int64>
    private let block: ?Block
    private let style: Style

    public init(values: Array<Int64>, block!: ?Block = None, style!: Style = Style(fg: Color.Cyan)) {
        this.values = values
        this.block = block
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0 || values.size == 0) { return }
        let maxV = max(1, maxArray(values))
        let count = min(target.width, values.size)
        for (i in 0..count) {
            let height = max(1, values[i] * target.height / maxV)
            for (dy in 0..height) {
                buffer.setString(target.x + i, target.bottom - 1 - dy, "#", style: style)
            }
        }
    }
}

public class LogView <: Widget {
    private let lines: Array<String>
    public var offset: Int64
    private let block: ?Block
    private let style: Style

    public init(lines: Array<String>, offset!: Int64 = -1, block!: ?Block = None, style!: Style = Style.default()) {
        this.lines = lines
        this.offset = offset
        this.block = block
        this.style = style
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        let start = if (offset < 0) { max(0, lines.size - target.height) } else { clamp(offset, 0, max(0, lines.size - target.height)) }
        for (row in 0..min(target.height, lines.size - start)) {
            buffer.setString(target.x, target.y + row, truncate(lines[start + row], target.width), style: style)
        }
    }
}
