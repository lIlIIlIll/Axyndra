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
    let available = max(3, terminalHeight - 5 - queuedRows - todoRows)
    let comfortable = max(4, min(14, terminalHeight / 3))
    min(available, comfortable)
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
    if (area.width <= 0 || content.height <= 0) {
        return
    }
    let _ = value
    let _ = cursor
    let frameColor = if (working) {
        theme.warning
    } else if (hasQueue) {
        theme.secondary
    } else {
        theme.accent
    }
    let first = if (unicode) { "╰─ " } else { "+- " }
    let continuation = if (unicode) { "│  " } else { "|  " }
    for (row in 0..content.height) {
        canvas.drawText(
            area.x,
            content.y + row,
            if (row == 0) { first } else { continuation },
            Style(fg: frameColor, bg: theme.background)
        )
    }
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
        " • " + inputTokens.toString() + "↑ " + outputTokens.toString() + "↓"
    }
    let taskText = if (task == "") {
        ""
    } else {
        " ───── " + cut(task, 32)
    }
    let left = "─ ◆ " + model + " · " + mode + " · " + compactPath(workspace) +
        " · " + branch + " · " + shortSession(session) + taskText
    let right = tokenText + " · " + status + " ─"
    let filler = width - displayWidth(left) - displayWidth(right)
    if (filler >= 0) {
        let segments = ArrayList<HeaderSegment>()
        segments.add(HeaderSegment("─ ", "border"))
        segments.add(HeaderSegment("◆ " + model, "model", strong: true))
        segments.add(HeaderSegment(" · ", "border"))
        segments.add(HeaderSegment(mode, "mode"))
        segments.add(HeaderSegment(" · ", "border"))
        segments.add(HeaderSegment(compactPath(workspace), "workspace"))
        segments.add(HeaderSegment(" · ", "border"))
        segments.add(HeaderSegment(branch, "branch"))
        segments.add(HeaderSegment(" · ", "border"))
        segments.add(HeaderSegment(shortSession(session), "session"))
        if (taskText != "") {
            segments.add(HeaderSegment(taskText, "task", strong: true))
        }
        segments.add(HeaderSegment(repeatedGlyph("─", filler), "border"))
        if (tokenText != "") {
            segments.add(HeaderSegment(tokenText, "usage"))
        }
        segments.add(HeaderSegment(" · ", "border"))
        segments.add(HeaderSegment(status, "status", strong: true))
        segments.add(HeaderSegment(" ─", "border"))
        return segments.toArray()
    }
    let compactLeft = "─ " + status + " · ◆ " + model + " · " + mode + " · " + compactPath(workspace)
    let compactRight = " ─"
    let compactWidth = displayWidth(compactLeft) + displayWidth(compactRight)
    if (compactWidth <= width) {
        return [
            HeaderSegment("─ ", "border"),
            HeaderSegment(status, "status", strong: true),
            HeaderSegment(" · ◆ ", "border"),
            HeaderSegment(model, "model", strong: true),
            HeaderSegment(" · ", "border"),
            HeaderSegment(mode, "mode"),
            HeaderSegment(" · ", "border"),
            HeaderSegment(compactPath(workspace), "workspace"),
            HeaderSegment(
                repeatedGlyph("─", width - compactWidth),
                "border"
            ),
            HeaderSegment(compactRight, "border")
        ]
    }
    if (width <= 2) {
        return [HeaderSegment(cut("──", width), "border")]
    }
    [
        HeaderSegment(
            cut(compactLeft + compactRight, width),
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
        case "task" => theme.accent
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
