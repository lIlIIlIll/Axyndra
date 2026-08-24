package core

public class Tabs <: Widget {
    private let titles: Array<String>
    public var selected: Int64
    private let style: Style
    private let selectedStyle: Style

    public init(
        titles: Array<String>,
        selected!: Int64 = 0,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White)
    ) {
        this.titles = titles
        this.selected = clamp(selected, 0, max(0, titles.size - 1))
        this.style = style
        this.selectedStyle = selectedStyle
    }

    public func handle(key: KeyEvent): Bool {
        match (key.code) {
            case KeyCode.Left =>
                selected = max(0, selected - 1)
                true
            case KeyCode.Right =>
                selected = min(max(0, titles.size - 1), selected + 1)
                true
            case _ => false
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        var x = area.x
        for (i in 0..titles.size) {
            if (x >= area.right) { return }
            let text = " " + titles[i] + " "
            let active = i == selected
            buffer.setString(x, area.y, truncate(text, area.right - x), style: if (active) { selectedStyle } else { style })
            x += displayWidth(text)
        }
    }
}

public class StatusBarProgress {
    public let value: Int64
    public let total: Int64
    public let width: Int64
    public let label: String
    public let labelMode: ProgressBarLabelMode
    public let style: Style
    public let fillStyle: Style
    public let labelStyle: Style
    public let symbols: ProgressBarSymbols

    public init(
        value: Int64,
        total!: Int64 = 100,
        width!: Int64 = 18,
        label!: String = "",
        labelMode!: ProgressBarLabelMode = ProgressBarLabelMode.Percent,
        style!: Style = Style(fg: Color.Indexed(8), bg: Color.White),
        fillStyle!: Style = Style(fg: Color.Cyan, bg: Color.White),
        labelStyle!: Style = Style(fg: Color.Black, bg: Color.White),
        symbols!: ProgressBarSymbols = ProgressBarSymbols(filled: "=", empty: "-", head: ">", indeterminate: ">")
    ) {
        this.value = max(0, value)
        this.total = max(1, total)
        this.width = max(0, width)
        this.label = label
        this.labelMode = labelMode
        this.style = style
        this.fillStyle = fillStyle
        this.labelStyle = labelStyle
        this.symbols = symbols
    }
}

public class StatusBar <: Widget {
    private let left: String
    private let right: String
    private let style: Style
    private let progress: ?StatusBarProgress

    public init(
        left!: String = "",
        right!: String = "",
        style!: Style = Style(fg: Color.Black, bg: Color.White),
        progress!: ?StatusBarProgress = None
    ) {
        this.left = left
        this.right = right
        this.style = style
        this.progress = progress
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        buffer.setString(area.x, area.y, repeat(" ", area.width), style: style)

        let rightText = truncate(right, area.width)
        let rightWidth = displayWidth(rightText)
        let rightX = area.right - rightWidth
        var leftLimit = if (rightWidth > 0) { max(0, rightX - area.x - 1) } else { area.width }
        match (progress) {
            case Some(p) =>
                let gap = if (rightWidth > 0) { 1 } else { 0 }
                let available = max(0, rightX - area.x - gap - 1)
                let progressWidth = min(p.width, available)
                if (progressWidth >= 6) {
                    let progressX = rightX - gap - progressWidth
                    ProgressBar(
                        p.value,
                        total: p.total,
                        label: p.label,
                        style: p.style,
                        fillStyle: p.fillStyle,
                        labelMode: p.labelMode,
                        labelStyle: p.labelStyle,
                        symbols: p.symbols
                    ).render(Rect(progressX, area.y, progressWidth, 1), buffer)
                    leftLimit = max(0, progressX - area.x - 1)
                }
            case None => ()
        }
        buffer.setString(area.x, area.y, truncate(left, leftLimit), style: style)
        if (rightWidth > 0) {
            buffer.setString(rightX, area.y, rightText, style: style)
        }
    }
}

public class Viewport <: Widget {
    private let lines: Array<String>
    public var offset: Int64
    private let block: ?Block
    private let style: Style

    public init(lines: Array<String>, offset!: Int64 = 0, block!: ?Block = None, style!: Style = Style.default()) {
        this.lines = lines
        this.offset = max(0, offset)
        this.block = block
        this.style = style
    }

    public func handle(key: KeyEvent, viewportHeight: Int64): Bool {
        match (key.code) {
            case KeyCode.Up => scroll(-1, viewportHeight); true
            case KeyCode.Down => scroll(1, viewportHeight); true
            case KeyCode.PageUp => scroll(-viewportHeight, viewportHeight); true
            case KeyCode.PageDown => scroll(viewportHeight, viewportHeight); true
            case KeyCode.Home => offset = 0; true
            case KeyCode.End => offset = max(0, lines.size - viewportHeight); true
            case _ => false
        }
    }

    public func scroll(delta: Int64, viewportHeight: Int64): Unit {
        offset = clamp(offset + delta, 0, max(0, lines.size - max(0, viewportHeight)))
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        for (row in 0..target.height) {
            let index = offset + row
            if (index >= lines.size) { return }
            buffer.setString(target.x, target.y + row, truncate(lines[index], target.width), style: style)
        }
    }
}
