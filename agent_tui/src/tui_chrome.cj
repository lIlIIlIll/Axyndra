package agent_tui

import core.*
import std.collection.*

func workingIndicator(elapsedMillis: Int64): String {
    match ((elapsedMillis / 80) % 8) {
        case 0 => "⠋"
        case 1 => "⠙"
        case 2 => "⠹"
        case 3 => "⠸"
        case 4 => "⠼"
        case 5 => "⠴"
        case 6 => "⠦"
        case _ => "⠇"
    }
}

func composerMaximumHeight(
    terminalHeight: Int64,
    queuedRows!: Int64 = 0,
    todoRows!: Int64 = 0
): Int64 {
    min(8, max(1, terminalHeight - 6 - queuedRows - todoRows))
}

func composerFooterHint(width: Int64, working: Bool, hasQueue: Bool): String {
    if (width <= 0) {
        return ""
    }
    var showEdit = hasQueue
    var showNewline = !working
    var showFollowUp = working
    while (true) {
        let parts = ArrayList<String>()
        parts.add(if (working) { "Enter steer" } else { "Enter send" })
        if (showNewline) {
            parts.add("Shift+Enter newline")
        }
        if (showFollowUp) {
            parts.add("Ctrl+Enter follow-up")
        }
        if (showEdit) {
            parts.add("Alt+↑ edit")
        }
        var value = ""
        for (part in parts) {
            if (value != "") { value += " · " }
            value += part
        }
        if (displayWidth(value) <= width) {
            return value
        }
        if (showEdit) {
            showEdit = false
        } else if (showNewline) {
            showNewline = false
        } else if (showFollowUp) {
            showFollowUp = false
        } else {
            return cut(value, width)
        }
    }
    ""
}

func drawComposerFrame(
    canvas: Canvas,
    area: Rect,
    content: Rect,
    value: String,
    cursor: Int64,
    working: Bool,
    hasQueue: Bool,
    unicode: Bool,
    theme: ProductTheme
): Unit {
    if (area.width <= 0 || area.height < 2) {
        return
    }
    let frameColor = if (working) {
        theme.warning
    } else if (hasQueue) {
        theme.secondary
    } else {
        theme.accent
    }
    let left = if (unicode) { "│" } else { "|" }
    let right = left
    let thumb = if (unicode) { "█" } else { "#" }
    let width = max(1, content.width)
    let totalRows = max(1, wrapText(value, width, WrapMode.Character).size)
    let boundedCursor = if (cursor < 0) {
        0
    } else if (cursor > value.size) {
        value.size
    } else {
        cursor
    }
    let cursorRows = max(1, wrapText(value[..boundedCursor], width, WrapMode.Character).size)
    let cursorRow = cursorRows - 1
    let scroll = max(0, cursorRow - content.height + 1)
    let maximumScroll = max(0, totalRows - content.height)
    let thumbHeight = if (maximumScroll > 0) {
        max(1, content.height * content.height / totalRows)
    } else {
        0
    }
    let thumbStart = if (maximumScroll > 0 && content.height > thumbHeight) {
        min(content.height - thumbHeight, scroll * (content.height - thumbHeight) / maximumScroll)
    } else {
        0
    }
    for (row in 0..content.height) {
        canvas.drawText(area.x, content.y + row, left, Style(fg: frameColor, bg: theme.background))
        let rightGlyph = if (thumbHeight > 0 && row >= thumbStart && row < thumbStart + thumbHeight) {
            thumb
        } else {
            right
        }
        canvas.drawText(
            area.right - 1,
            content.y + row,
            rightGlyph,
            Style(fg: if (rightGlyph == thumb) { theme.secondary } else { frameColor }, bg: theme.background)
        )
    }
    let bottomLeft = if (unicode) { "╰" } else { "+" }
    let bottomRight = if (unicode) { "╯" } else { "+" }
    let horizontal = if (unicode) { "─" } else { "-" }
    let insideWidth = max(0, area.width - 2)
    let hint = composerFooterHint(max(0, insideWidth - 2), working, hasQueue)
    let prefix = if (hint == "") { "" } else { horizontal + " " + hint + " " }
    let inside = prefix + repeatedGlyph(horizontal, max(0, insideWidth - displayWidth(prefix)))
    canvas.drawText(
        area.x,
        area.bottom - 1,
        bottomLeft + inside + bottomRight,
        Style(fg: frameColor, bg: theme.background)
    )
}

class HeaderSegment {
    let text: String
    let role: String
    let strong: Bool

    init(text: String, role: String, strong!: Bool = false) {
        this.text = text
        this.role = role
        this.strong = strong
    }
}

func tuiHeaderSegments(
    width: Int64,
    model: String,
    thinking: String,
    workMode: String,
    workspace: String,
    branch: String,
    session: String,
    task: String,
    inputTokens: Int64,
    outputTokens: Int64,
    status: String
): Array<HeaderSegment> {
    if (width <= 0) {
        return []
    }
    let mode = if (workMode == "none") {
        thinking
    } else {
        thinking + "/" + workMode
    }
    let tokenText = if (inputTokens == 0 && outputTokens == 0) {
        ""
    } else {
        " \u{E0B3} " + inputTokens.toString() + "↑ " + outputTokens.toString() + "↓"
    }
    let taskText = if (task == "") {
        ""
    } else {
        " ───── " + cut(task, 32)
    }
    let left = "╭── ◆ " + model + " · \u{F0AA5} " + mode + " \u{E0B1} \u{F115} " + compactPath(workspace) +
        " \u{E0B1} \u{F126} " + branch + " \u{E0B1} \u{F0051} " + shortSession(session) + taskText
    let right = tokenText + " \u{E0B3} " + status + " ──╮"
    let filler = width - displayWidth(left) - displayWidth(right)
    if (filler >= 0) {
        let segments = ArrayList<HeaderSegment>()
        segments.add(HeaderSegment("╭── ", "border"))
        segments.add(HeaderSegment("◆ " + model, "model", strong: true))
        segments.add(HeaderSegment(" · ", "border"))
        segments.add(HeaderSegment("\u{F0AA5} " + mode, "mode"))
        segments.add(HeaderSegment(" \u{E0B1} ", "border"))
        segments.add(
            HeaderSegment(
                "\u{F115} " + compactPath(workspace),
                "workspace"
            )
        )
        segments.add(HeaderSegment(" \u{E0B1} ", "border"))
        segments.add(HeaderSegment("\u{F126} " + branch, "branch"))
        segments.add(HeaderSegment(" \u{E0B1} ", "border"))
        segments.add(
            HeaderSegment(
                "\u{F0051} " + shortSession(session),
                "session"
            )
        )
        if (taskText != "") {
            segments.add(HeaderSegment(taskText, "task", strong: true))
        }
        segments.add(HeaderSegment(repeatedGlyph("─", filler), "border"))
        if (tokenText != "") {
            segments.add(HeaderSegment(tokenText, "usage"))
        }
        segments.add(HeaderSegment(" \u{E0B3} ", "border"))
        segments.add(HeaderSegment(status, "status", strong: true))
        segments.add(HeaderSegment(" ──╮", "border"))
        return segments.toArray()
    }
    let compactLeft = "╭─ " + status + " \u{E0B1} ◆ " + model + " · " + mode + " \u{E0B1} " + compactPath(workspace)
    let compactRight = " ─╮"
    let compactWidth = displayWidth(compactLeft) + displayWidth(compactRight)
    if (compactWidth <= width) {
        return [
            HeaderSegment("╭─ ", "border"),
            HeaderSegment(status, "status", strong: true),
            HeaderSegment(" \u{E0B1} ", "border"),
            HeaderSegment("◆ " + model, "model", strong: true),
            HeaderSegment(" · ", "border"),
            HeaderSegment(mode, "mode"),
            HeaderSegment(" \u{E0B1} ", "border"),
            HeaderSegment(compactPath(workspace), "workspace"),
            HeaderSegment(
                repeatedGlyph("─", width - compactWidth),
                "border"
            ),
            HeaderSegment(compactRight, "border")
        ]
    }
    if (width <= 2) {
        return [HeaderSegment(cut("╭╮", width), "border")]
    }
    [
        HeaderSegment(
            cut(compactLeft + compactRight, width - 1) + "╮",
            "border"
        )
    ]
}

func drawTuiHeader(
    canvas: Canvas,
    x: Int64,
    y: Int64,
    width: Int64,
    model: String,
    thinking: String,
    workMode: String,
    workspace: String,
    branch: String,
    session: String,
    task: String,
    inputTokens: Int64,
    outputTokens: Int64,
    status: String,
    theme: ProductTheme
): Unit {
    var cursor = x
    let right = x + width
    for (segment in tuiHeaderSegments(
        width,
        model,
        thinking,
        workMode,
        workspace,
        branch,
        session,
        task,
        inputTokens,
        outputTokens,
        status
    )) {
        if (cursor >= right) {
            return
        }
        let text = cut(segment.text, right - cursor)
        canvas.drawText(
            cursor,
            y,
            text,
            Style(
                fg: headerSegmentColor(theme, segment.role, status),
                bg: theme.background,
                modifier: if (segment.strong) {
                    Modifier.strong()
                } else {
                    Modifier.none()
                }
            )
        )
        cursor += displayWidth(text)
    }
}

func headerSegmentColor(
    theme: ProductTheme,
    role: String,
    status: String
): Color {
    match (role) {
        case "border" => theme.accent
        case "model" => theme.accent
        case "mode" => theme.secondary
        case "workspace" => theme.secondary
        case "branch" => theme.warning
        case "session" => theme.success
        case "task" => theme.text
        case "usage" => theme.muted
        case "status" => statusHeaderColor(theme, status)
        case _ => theme.muted
    }
}

func statusHeaderColor(theme: ProductTheme, status: String): Color {
    let value = status.toAsciiLower()
    if (value == "ready" || value.contains("completed")) {
        return theme.success
    }
    if (value.contains("error") || value.contains("failed")) {
        return theme.danger
    }
    if (value.contains("cancel") || value.contains("reject") || value.contains("working") || value.contains("waiting")) {
        return theme.warning
    }
    theme.secondary
}

func shortSession(value: String): String {
    let runes = value.toRuneArray()
    if (runes.size <= 8) {
        return value
    }
    String(runes[(runes.size - 8)..])
}

func drawBox(
    canvas: Canvas,
    area: Rect,
    color: Color
): Unit {
    if (area.width < 2 || area.height < 2) {
        return
    }
    let horizontal = repeatedGlyph("─", max(0, area.width - 2))
    canvas.drawText(
        area.x,
        area.y,
        "╭" + horizontal + "╮",
        Style(fg: color, bg: Color.Black)
    )
    canvas.drawText(
        area.x,
        area.bottom - 1,
        "╰" + horizontal + "╯",
        Style(fg: color, bg: Color.Black)
    )
    for (y in (area.y + 1)..(area.bottom - 1)) {
        canvas.drawText(
            area.x,
            y,
            "│",
            Style(fg: color, bg: Color.Black)
        )
        canvas.drawText(
            area.right - 1,
            y,
            "│",
            Style(fg: color, bg: Color.Black)
        )
    }
}

func repeatedGlyph(value: String, count: Int64): String {
    var output = ""
    for (_ in 0..max(0, count)) {
        output += value
    }
    output
}

func userMessageDocumentLine(
    text: String,
    width: Int64,
    theme: ProductTheme
): DocumentLine {
    let _ = width
    let content = "  " + text
    DocumentLine(
        DocumentLineKind.Paragraph,
        content,
        style: Style(
            fg: theme.userMessageText,
            bg: theme.userMessageBg
        )
    )
}

func compactPath(value: String): String {
    let runes = value.toRuneArray()
    if (runes.size <= 34) {
        return value
    }
    "…" + String(runes[(runes.size - 33)..])
}
