package agent_tui

import core.*
import markdown.*
import std.collection.*
import std.time.*

func approvalCardBody(
    tool: String,
    capability: String,
    resource: String,
    risk: String,
    reason: String,
    preview: String
): String {
    let approval = ApprovalPresentation(
        tool,
        capability,
        resource,
        risk,
        preview
    )
    // Permission cards are the one place where truncating the command could
    // hide the risk the user is being asked to accept.  The transcript
    // viewport wraps this value by terminal width, but never shortens it.
    let summary = approvalDisplayPreview(approval)
    risk.toAsciiUpper() + " RISK · " + capability + if (resource == "" || preview.contains("Path    ")) {
        ""
    } else {
        "\nTarget  " + resource
    } + if (reason == "") {
        ""
    } else {
        "\nReason  " + reason
    } + if (summary == "" || summary == resource) {
        ""
    } else {
        "\n\n" + if (tool == "write") {
            summary
        } else {
            approvalPreviewPrefix(tool) + summary
        }
    }
}

func approvalOperationTitle(tool: String, preview: String): String {
    match (tool.toAsciiLower()) {
        case "write" => "Write file"
        case "edit" | "apply_patch" => "Edit file"
        case "bash" | "bash_readonly" =>
            if (preview.toAsciiLower().contains("git push --force") || preview.toAsciiLower().contains("git push -f")) {
                "Force push"
            } else {
                "Run command"
            }
        case "read" => "Read file"
        case "http" | "fetch" | "web_fetch" => "HTTP request"
        case _ => humanizeToolName(tool)
    }
}

func humanizeToolName(tool: String): String {
    if (tool == "") {
        return "Tool request"
    }
    var value = tool.replace("_", " ")
    if (value.size > 0 && value[0] >= b'a' && value[0] <= b'z') {
        value = String.fromUtf8([(value[0] - 32)]) + value[1..]
    }
    value
}

func approvalDisplayPreview(approval: ApprovalPresentation): String {
    let reviewMarker = "\n\nAI Reviewer\n"
    let reviewAt = approval.preview.indexOf(reviewMarker)
    match (reviewAt) {
        case Some(index) =>
            let base = approvalDisplayPreview(
                ApprovalPresentation(
                    approval.tool,
                    approval.capability,
                    approval.resource,
                    approval.risk,
                    approval.preview[..index]
                )
            )
            return base + reviewMarker + approval.preview[index + reviewMarker.size..]
        case None => ()
    }
    let prefix = "{\"command\":\""
    if (approval.tool == "bash" && approval.preview.startsWith(prefix) && approval.preview.endsWith("\"}")) {
        return approval
            .preview[prefix
                .size..(approval
                .preview
                .size - 2)]
            .replace("\\\"", "\"")
            .replace("\\n", " ")
            .replace("\\\\", "\\")
    }
    if (approval.tool == "write" && approval.preview.contains("Path    ")) {
        return approval.preview
    }
    if (approval.resource != "") {
        return approval.resource
    }
    approval.preview
}

func approvalPreviewPrefix(tool: String): String {
    if (tool == "bash") {
        "$ "
    } else {
        tool + "  "
    }
}

func modalTitle(kind: TuiModalKind): String {
    match (kind) {
        case TuiModalKind.Setup => "Provider setup"
        case TuiModalKind.Model => "Select model"
        case TuiModalKind.Theme => "Select theme"
        case TuiModalKind.Session => "Select session"
        case TuiModalKind.Tree => "Session tree"
        case TuiModalKind.Agent => "Select subagent"
        case TuiModalKind.Extensions => "Extensions"
        case TuiModalKind.Branch => "Create branch from message"
        case TuiModalKind.Settings => "Settings"
        case TuiModalKind.Reset => "Confirm archive/reset"
        case TuiModalKind.Document => "Details"
    }
}

// Agent overlays use the same compact left event rail as transcript cards.
// They intentionally avoid a generic four-sided framed panel: selectors,
// confirmations, and structured documents are terminal interactions rather
// than dashboard panels.
func renderAgentOverlay(
    frame: Frame,
    host: Rect,
    title: String,
    body: Document,
    scroll: Int64,
    footer: String,
    theme: ProductTheme,
    unicode: Bool,
    document!: Bool = false,
    itemCount!: Int64 = 0,
    documentCache!: ?DocumentWindowCache = None,
    documentKey!: String = ""
): Unit {
    if (host.width <= 0 || host.height <= 0) {
        return
    }
    let area = agentOverlayArea(host, document: document, itemCount: itemCount)
    let canvas = frame.canvas()
    canvas.fillRect(area, Style(bg: theme.background))
    let top = if (unicode) {
        "╭─ "
    } else {
        "+- "
    }
    let rail = if (unicode) {
        "│ "
    } else {
        "| "
    }
    let bottom = if (unicode) {
        "╰─ "
    } else {
        "+- "
    }
    canvas.drawText(
        area.x,
        area.y,
        top,
        Style(fg: theme.muted, bg: theme.background)
    )
    canvas.drawText(
        area.x + 3,
        area.y,
        cut(title, max(1, area.width - 3)),
        Style(
            fg: theme.accent,
            bg: theme.background,
            modifier: Modifier.strong()
        )
    )
    for (y in (area.y + 1)..(area.bottom - 1)) {
        canvas.drawText(
            area.x,
            y,
            rail,
            Style(fg: theme.muted, bg: theme.background)
        )
    }
    let bodyArea = Rect(
        area.x + 2,
        area.y + 1,
        max(1, area.width - 2),
        max(0, area.height - 2)
    )
    match (documentCache) {
        case Some(cache) => frame.renderWidget(CachedDocumentViewport(cache, body, documentKey, scroll), bodyArea)
        case None => frame.renderWidget(DocumentView(body, scroll: scroll), bodyArea)
    }
    canvas.drawText(
        area.x,
        area.bottom - 1,
        bottom,
        Style(fg: theme.muted, bg: theme.background)
    )
    canvas.drawText(
        area.x + 3,
        area.bottom - 1,
        cut(footer, max(1, area.width - 3)),
        Style(fg: theme.muted, bg: theme.background)
    )
}

func agentOverlayArea(host: Rect, document!: Bool, itemCount!: Int64): Rect {
    let desiredWidth = if (document) {
        84
    } else {
        64
    }
    let desiredHeight = if (document) {
        max(10, host.height - 2)
    } else {
        min(16, max(5, itemCount + 2))
    }
    centeredViewport(
        host,
        min(desiredWidth, max(20, host.width - 2)),
        min(desiredHeight, max(3, host.height - 2))
    )
}

func subagentStatusGlyph(status: String): String {
    match (status) {
        case "running" | "active" => "◆"
        case "completed" | "idle" | "ready" => "✓"
        case "failed" | "cancelled" => "✗"
        case "blocked" => "!"
        case _ => "◇"
    }
}

func subagentStatusSummary(items: Array<TuiSubagentInfo>): String {
    var running: Int64 = 0
    var completed: Int64 = 0
    var other: Int64 = 0
    for (item in items) {
        if (item.status == "running") {
            running += 1
        } else if (item.status == "completed" || item.status == "idle") {
            completed += 1
        } else {
            other += 1
        }
    }
    let parts = ArrayList<String>()
    if (running > 0) {
        parts.add(running.toString() + " running")
    }
    if (completed > 0) {
        parts.add(completed.toString() + " completed")
    }
    if (other > 0) {
        parts.add(other.toString() + " other")
    }
    var result = ""
    for (part in parts) {
        if (result != "") {
            result += " · "
        }
        result += part
    }
    result
}

func extensionLabels(extensions: Array<TuiExtensionInfo>): Array<String> {
    let values = ArrayList<String>()
    for (extension in extensions) {
        var label = (if (extension.enabled) {
            "[on] "
        } else {
            "[off] "
        }) + extension.id + " · " + extension.source
        if (!extension.tools.isEmpty()) {
            label += " · " + extension.tools.size.toString() + " tool(s)"
        }
        values.add(label)
    }
    values.toArray()
}

func treeLabels(nodes: Array<TuiSessionNode>): Array<String> {
    let values = ArrayList<String>()
    for (node in nodes) {
        var depth: Int64 = 0
        var parent = node.parentId
        var guard: Int64 = 0
        while (parent != "" && guard < nodes.size) {
            depth += 1
            guard += 1
            var next = ""
            for (candidate in nodes where candidate.id == parent) {
                next = candidate.parentId
            }
            parent = next
        }
        var prefix = if (node.current) {
            "* "
        } else {
            "  "
        }
        for (_ in 0..depth) {
            prefix += "  "
        }
        values.add(prefix + node.label())
    }
    values.toArray()
}

func sessionLabels(nodes: Array<TuiSessionNode>, all: Array<TuiSessionNode>): Array<String> {
    let values = ArrayList<String>()
    for (node in nodes) {
        var prefix = if (node.current) {
            "● "
        } else {
            "  "
        }
        for (_ in 0..sessionDepth(node, all)) {
            prefix += "  "
        }
        if (node.archived) {
            prefix += "[archived] "
        }
        values.add(prefix + node.label())
    }
    values.toArray()
}

func sessionDepth(node: TuiSessionNode, nodes: Array<TuiSessionNode>): Int64 {
    var depth: Int64 = 0
    var parent = node.parentId
    var guard: Int64 = 0
    while (parent != "" && guard < nodes.size) {
        depth += 1
        guard += 1
        var next = ""
        for (candidate in nodes where candidate.id == parent) {
            next = candidate.parentId
        }
        parent = next
    }
    depth
}

func sessionSearchText(node: TuiSessionNode): String {
    (node.name + " " + node.summary + " " + node.id).toAsciiLower()
}

func dropLastSessionRune(value: String): String {
    let runes = value.toRuneArray()
    if (runes.isEmpty()) {
        return ""
    }
    String(runes[..(runes.size - 1)])
}

func sessionSelectorFooter(mode: String, archived: Bool, filter: String): String {
    match (mode) {
        case "search" => "/ " + if (filter == "") {
            "type to search · Esc cancel"
        } else {
            filter + " · Esc clear"
        }
        case "rename" => "Rename: type a name · Enter save · Esc cancel"
        case "confirm_archive" => "Archive selected session? · Enter confirm · Esc cancel"
        case "confirm_restore" => "Restore selected session? · Enter confirm · Esc cancel"
        case _ => "↑↓/j/k select · Enter open · / search · r rename · a archive · A " + if (archived) {
            "hide archived · u restore"
        } else {
            "show archived"
        }
    }
}

func sessionModalDocument(
    nodes: Array<TuiSessionNode>,
    all: Array<TuiSessionNode>,
    selected: Int64,
    theme: ProductTheme,
    width: Int64,
    mode: String,
    input: String
): Document {
    let lines = ArrayList<DocumentLine>()
    if (nodes.isEmpty()) {
        lines.add(DocumentLine(DocumentLineKind.Paragraph, "No matching sessions.", style: Style(fg: theme.muted)))
        return Document(lines.toArray())
    }
    let active = nodes[min(selected, nodes.size - 1)]
    let details = sessionDetailLines(active, mode, input)
    let twoPane = width >= 80
    let listWidth = if (twoPane) {
        min(46, width * 46 / 100)
    } else {
        width
    }
    let windowSize: Int64 = if (twoPane) {
        14
    } else {
        9
    }
    var start = max(0, selected - windowSize / 2)
    if (start + windowSize > nodes.size) {
        start = max(0, nodes.size - windowSize)
    }
    let end = min(nodes.size, start + windowSize)
    var detailIndex: Int64 = 0
    if (start > 0) {
        lines.add(
            DocumentLine(DocumentLineKind.Paragraph, "  … " + start.toString() + " newer sessions …",
                style: Style(fg: theme.muted)))
    }
    for (index in start..end) {
        let node = nodes[index]
        var label = (if (index == selected) {
            "› "
        } else {
            "  "
        }) + (if (node.current) {
            "● "
        } else {
            "  "
        })
        for (_ in 0..sessionDepth(node, all)) {
            label += "  "
        }
        if (node.archived) {
            label += "[archived] "
        }
        label += node.label()
        let leftStyle = if (index == selected) {
            Style(fg: theme.accent, modifier: Modifier.strong())
        } else {
            Style(fg: if (node.archived) {
                theme.muted
            } else {
                theme.text
            })
        }
        if (twoPane) {
            let right = if (detailIndex < details.size) {
                details[detailIndex]
            } else {
                ""
            }
            detailIndex += 1
            lines.add(
                DocumentLine(
                    DocumentLineKind.Paragraph,
                    [
                        RichSpan(padSessionColumn(cut(label, listWidth - 2), listWidth), style: leftStyle),
                        RichSpan("│ " + right, style: Style(fg: if (right.startsWith("Summary")) {
                            theme.text
                        } else {
                            theme.muted
                        }))
                    ]
                )
            )
        } else {
            lines.add(DocumentLine(DocumentLineKind.Paragraph, label, style: leftStyle))
        }
    }
    if (twoPane) {
        while (detailIndex < details.size) {
            let right = details[detailIndex]
            detailIndex += 1
            lines.add(
                DocumentLine(
                    DocumentLineKind.Paragraph,
                    [
                        RichSpan(padSessionColumn("", listWidth), style: Style(fg: theme.text)),
                        RichSpan("│ " + right, style: Style(fg: theme.muted))
                    ]
                )
            )
        }
    }
    if (end < nodes.size) {
        lines.add(
            DocumentLine(DocumentLineKind.Paragraph, "  … " + (nodes.size - end).toString() + " older sessions …",
                style: Style(fg: theme.muted)))
    }
    if (!twoPane) {
        lines.add(DocumentLine(DocumentLineKind.Blank, ""))
        for (detail in details) {
            lines.add(
                DocumentLine(DocumentLineKind.Paragraph, detail,
                    style: Style(fg: if (detail.startsWith("Summary")) {
                        theme.text
                    } else {
                        theme.muted
                    })))
        }
    }
    Document(lines.toArray())
}

func sessionDetailLines(node: TuiSessionNode, mode: String, input: String): Array<String> {
    let values = ArrayList<String>()
    values.add("Summary  " + node.summary)
    values.add("ID       " + node.id)
    values.add("Updated  " + sessionAge(node.updatedAt))
    values.add("Parent   " + if (node.parentId == "") {
        "—"
    } else {
        node.parentId
    })
    values.add("Model    " + if (node.model == "") {
        "default"
    } else {
        node.model
    })
    values.add("Mode     " + if (node.workMode == "") {
        "normal"
    } else {
        node.workMode
    })
    values.add("State    " + if (node.archived) {
        "archived"
    } else if (node.current) {
        "current"
    } else {
        "active"
    })
    if (mode == "rename") {
        values.add("Name     " + input)
    }
    if (mode == "confirm_archive") {
        values.add("Action   Move this session and its runs to the archive")
    }
    if (mode == "confirm_restore") {
        values.add("Action   Restore this session and its runs")
    }
    values.toArray()
}

func sessionAge(updatedAt: Int64): String {
    if (updatedAt <= 0) {
        return "unknown"
    }
    let age = max(0, DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() - updatedAt)
    if (age < 60000) {
        return "just now"
    }
    if (age < 3600000) {
        return (age / 60000).toString() + "m ago"
    }
    if (age < 86400000) {
        return (age / 3600000).toString() + "h ago"
    }
    (age / 86400000).toString() + "d ago"
}

func padSessionColumn(value: String, width: Int64): String {
    var result = value
    var remaining = max(0, width - displayWidth(value))
    while (remaining > 0) {
        result += " "
        remaining -= 1
    }
    result
}

func themeNames(
    custom: Array<TuiThemeDefinition>,
    current: String
): Array<String> {
    let values = ArrayList<String>()
    values.add(current + " (current)")
    for (name in ["axyndra", "dark", "light", "mono"] where name != current) {
        values.add(name)
    }
    for (theme in custom where theme.name != current) {
        values.add(theme.name)
    }
    values.toArray()
}

func themeNameFromLabel(value: String): String {
    value.removeSuffix(" (current)")
}

func planReviewDocument(
    body: String,
    selected: Int64,
    theme: ProductTheme
): Document {
    let prefix = "Latest plan:\n\n"
    let plan = if (body.startsWith(prefix)) {
        body[prefix.size..]
    } else {
        body
    }
    let lines = ArrayList<DocumentLine>()
    for (line in markdownDocument(
        plan,
        theme: productMarkdownTheme(theme)
    ).lines) {
        lines.add(line)
    }
    if (!lines.isEmpty()) {
        lines.add(DocumentLine(DocumentLineKind.Blank, ""))
    }
    lines.add(
        DocumentLine(
            DocumentLineKind.Paragraph,
            "Review action",
            style: Style(fg: theme.muted, modifier: Modifier.strong())
        )
    )
    let options = [
        ("Approve and execute", "Exit plan mode and execute this plan."),
        ("Keep planning", "Continue refining without executing."),
        ("Reject", "Reject this version and request a revision.")
    ]
    for (index in 0..options.size) {
        let active = index == selected
        let (label, description) = options[index]
        lines.add(
            DocumentLine(
                DocumentLineKind.Paragraph,
                (if (active) {
                    "› "
                } else {
                    "  "
                }) + (index + 1).toString() + ". " + label,
                style: if (active) {
                    Style(fg: theme.accent, modifier: Modifier.strong())
                } else {
                    Style(fg: theme.text)
                }
            )
        )
        lines.add(
            DocumentLine(
                DocumentLineKind.Paragraph,
                "     " + description,
                style: Style(fg: theme.muted)
            )
        )
    }
    lines.add(DocumentLine(DocumentLineKind.Blank, ""))
    lines.add(
        DocumentLine(
            DocumentLineKind.Paragraph,
            "Optional feedback can be typed in the composer below.",
            style: Style(fg: theme.secondary)
        )
    )
    Document(lines.toArray())
}

func stripPlanReviewLabel(value: String): String {
    let prefix = "Latest plan:\n\n"
    if (value.startsWith(prefix)) {
        value[prefix.size..]
    } else {
        value
    }
}

func planReviewPointInRect(x: Int64, y: Int64, area: Rect): Bool {
    area.width > 0 && area.height > 0 && x >= area.x && x < area.right && y >= area.y && y < area.bottom
}

func planReviewSections(document: Document): Array<PlanReviewSection> {
    let sections = ArrayList<PlanReviewSection>()
    for (line in document.lines) {
        match (line.kind) {
            case DocumentLineKind.Heading(level) =>
                let title = documentLineText(line).trimAscii()
                if (title != "") {
                    var sourceOffset: Int64 = 0
                    for (span in line.spans) {
                        match (span.sourceRange) {
                            case Some(value) =>
                                sourceOffset = planReviewSourceOffset(value)
                                break
                            case None => ()
                        }
                    }
                    sections.add(PlanReviewSection(title, level, sourceOffset))
                }
            case _ => ()
        }
    }
    sections.toArray()
}

func planReviewSourceOffset(value: String): Int64 {
    var out: Int64 = 0
    var parsed = false
    for (index in 0..value.size) {
        let byte = value[index]
        if (byte == b':') {
            break
        }
        if (byte < b'0' || byte > b'9') {
            return 0
        }
        parsed = true
        out = out * 10 + Int64(byte - b'0')
    }
    if (parsed) { out } else { 0 }
}

func planReviewLineContextAtOffset(value: String, sourceOffset: Int64): String {
    let lines = stripPlanReviewLabel(value).split("\n")
    if (lines.isEmpty()) {
        return ""
    }
    var offset: Int64 = 0
    for (line in lines) {
        let end = offset + line.size
        if (sourceOffset <= end) {
            let trimmed = line.trimAscii()
            return if (trimmed == "") {
                "(blank line)"
            } else {
                cut(trimmed, 100)
            }
        }
        offset = end + 1
    }
    let last = lines[lines.size - 1].trimAscii()
    if (last == "") {
        "(blank line)"
    } else {
        cut(last, 100)
    }
}

func planReviewActionLabels(): Array<String> {
    [
        "Approve and execute · fresh context",
        "Approve and compact context",
        "Approve and keep context",
        "Refine plan"
    ]
}

func planReviewFocusStatus(focus: PlanReviewFocus): String {
    match (focus) {
        case PlanReviewFocus.Toc => "plan review · sections"
        case PlanReviewFocus.Body => "plan review · document"
        case PlanReviewFocus.Actions => "plan review · actions"
    }
}

func planReviewHelp(focus: PlanReviewFocus): String {
    match (focus) {
        case PlanReviewFocus.Toc =>
            "↑↓ section · Enter open · a annotate · d remove · u undo · Tab regions · Esc cancel"
        case PlanReviewFocus.Body =>
            "↑↓ scroll · PgUp/PgDn · a annotate · Tab regions · c copy · e edit · Esc cancel"
        case PlanReviewFocus.Actions =>
            "↑↓ select · Enter confirm · Tab regions · c copy · e edit · Esc cancel"
    }
}

func drawPlanReviewBottomBorder(
    canvas: Canvas,
    area: Rect,
    footer: String,
    theme: ProductTheme,
    horizontal: String,
    bottomLeft: String,
    bottomRight: String
): Unit {
    canvas.drawText(
        area.x,
        area.bottom - 1,
        bottomLeft + repeatedGlyph(horizontal, max(0, area.width - 2)) + bottomRight,
        Style(fg: theme.muted, bg: theme.background)
    )
    canvas.drawText(
        area.x + 2,
        area.bottom - 1,
        cut(footer, max(1, area.width - 4)),
        Style(fg: theme.muted, bg: theme.background)
    )
}

func modalBody(items: Array<String>, selected: Int64, theme: ProductTheme): Document {
    var lines = ArrayList<DocumentLine>()
    for (index in 0..items.size) {
        let active = index == selected
        lines.add(
            DocumentLine(
                DocumentLineKind.Paragraph,
                (if (active) {
                    "› "
                } else {
                    "  "
                }) + items[index],
                style: if (active) {
                    Style(fg: theme.accent, modifier: Modifier.strong())
                } else {
                    Style(fg: theme.text)
                }
            )
        )
    }
    Document(lines.toArray())
}

func askProgress(
    request: TuiAskRequest,
    questionIndex: Int64
): String {
    let count = request.questions.size
    "ask question " + (questionIndex + 1).toString() + "/" + count.toString() +
        " · ↑/↓ select · Enter answer · Tab edit Other · N note · C chat · Esc cancel"
}

func askTitle(
    request: TuiAskRequest,
    questionIndex: Int64
): String {
    if (request.questions.isEmpty()) {
        return "Ask"
    }
    let question = request.questions[questionIndex]
    if (question.header.trimAscii() != "") {
        "Ask · " + question.header
    } else {
        "Ask"
    }
}

func askChoiceCount(
    request: TuiAskRequest,
    questionIndex: Int64
): Int64 {
    if (request.questions.isEmpty()) {
        return 0
    }
    let question = request.questions[questionIndex]
    question.options.size + if (question.multi) {
        3
    } else {
        2
    }
}

func askBody(
    request: TuiAskRequest,
    questionIndex: Int64,
    cursor: Int64,
    selected: Array<String>,
    customInput: ?String,
    note: ?String,
    editingCustom!: Bool = false
): String {
    if (request.questions.isEmpty()) {
        return "No questions"
    }
    let safeIndex = max(
        0,
        min(questionIndex, request.questions.size - 1)
    )
    let question = request.questions[safeIndex]
    var body = question.question + " (" + (safeIndex + 1).toString() + "/" + request.questions.size.toString() + ")"
    for (index in 0..question.options.size) {
        let option = question.options[index]
        body += "\n" + if (index == cursor) {
            "› "
        } else {
            "  "
        }
        body += if (askContains(selected, option.label)) {
            "[x] "
        } else {
            "[ ] "
        }
        body += option.label
        match (question.recommended) {
            case Some(value) =>
                if (value == index && !option.label.endsWith(" (Recommended)")) {
                    body += " (Recommended)"
                }
            case None => ()
        }
        if (option.description.trimAscii() != "") {
            body += "\n      " + option.description
        }
        if (option.preview.trimAscii() != "") {
            body += "\n      preview: " + option.preview
        }
    }
    let otherIndex = question.options.size
    body += "\n" + if (cursor == otherIndex) {
        "› "
    } else {
        "  "
    }
    if (editingCustom) {
        body += "Other: "
    } else {
        body += "Other (type your own)"
        match (customInput) {
            case Some(value) => body += ": " + value.replace("\n", " ")
            case None => ()
        }
    }
    if (question.multi) {
        body += "\n" + if (cursor == otherIndex + 1) {
            "› "
        } else {
            "  "
        } + "Done selecting"
    }
    let chatIndex = otherIndex + if (question.multi) {
        2
    } else {
        1
    }
    body += "\n" + if (cursor == chatIndex) {
        "› "
    } else {
        "  "
    }
    body += "Chat about this"
    if (!editingCustom) {
        match (note) {
            case Some(value) => body += "\n\nNote: " + value.replace("\n", " ")
            case None => ()
        }
    }
    body
}

func askContains(values: Array<String>, target: String): Bool {
    for (value in values where value == target) {
        return true
    }
    false
}

func askOptionIndex(
    question: TuiAskQuestion,
    label: String
): Int64 {
    for (index in 0..question.options.size) {
        if (question.options[index].label == label) {
            return index
        }
    }
    0
}

func rejectReason(prompt: String): String {
    if (prompt.size <= 7) {
        return ""
    }
    prompt[7..].trimAscii()
}
