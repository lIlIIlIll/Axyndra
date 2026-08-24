package agent_tui

import core.*
import std.collection.*
import std.time.*

class TranscriptLine {
    let text: String

    init(text: String) {
        this.text = text
    }
}

func transcriptLines(
    items: Array<UiCard>,
    width: Int64
): Array<TranscriptLine> {
    let lines = ArrayList<TranscriptLine>()
    for (item in items) {
        if (isApprovalRejectionToolCard(item)) {
            continue
        }
        if (item.kind == UiCardKind.Reasoning && item.collapsed && item.state != "streaming" && item.state != "running") {
            continue
        }
        if (!lines.isEmpty()) {
            lines.add(TranscriptLine(""))
        }
        if (item.kind == UiCardKind.User || item.kind == UiCardKind.Assistant || item.kind == UiCardKind.Reasoning) {
            for (line in wrapText(item.body, max(1, width - 2), WrapMode.Character)) {
                lines.add(TranscriptLine("  " + line))
            }
            continue
        }
        let document = transcriptCardDocument(productTranscriptItem(item, width))
        for (line in document.lines) {
            lines.add(TranscriptLine(cut(documentLineText(line), width)))
        }
    }
    lines.toArray()
}

func documentLineText(line: DocumentLine): String {
    var text = ""
    for (span in line.spans) {
        text += span.text
    }
    text
}

func productTranscriptItem(
    item: UiCard,
    width: Int64,
    activityFrame!: Int64 = 0,
    theme!: ProductTheme = activeProductTheme(),
    approvalSelected!: Int64 = -1
): TranscriptItem {
    let options: Array<TranscriptCardOption> = if (approvalSelected >= 0) {
        [
            TranscriptCardOption("Allow once", selected: approvalSelected == 0),
            TranscriptCardOption(
                "Allow similar commands this session",
                selected: approvalSelected == 1
            ),
            TranscriptCardOption("Reject", selected: approvalSelected == 2)
        ]
    } else {
        []
    }
    TranscriptItem(
        item.id,
        kind: productTranscriptKind(item.kind),
        title: item.title,
        body: agentCardBodyDocument(item, width, theme),
        status: productTranscriptStatus(item),
        collapsed: item.collapsed || (item.kind == UiCardKind.Approval && !approvalCardIsWaiting(item.state)),
        duration: productCardDuration(item),
        stateLabel: readableCardState(item.state),
        activityFrame: activityFrame,
        options: options,
        footer: if (approvalSelected < 0) {
            ""
        } else if (approvalSelected == 2) {
            "←/→ choose · type reason below · Enter reject"
        } else {
            "←/→ choose · Enter confirm"
        }
    )
}

func productTranscriptKind(kind: UiCardKind): TranscriptItemKind {
    match (kind) {
        case UiCardKind.Error => TranscriptItemKind.Error
        case UiCardKind.Tool | UiCardKind.Approval => TranscriptItemKind.Event
        case UiCardKind.Steer => TranscriptItemKind.Progress
        case _ => TranscriptItemKind.Detail
    }
}

func productTranscriptStatus(item: UiCard): TranscriptItemStatus {
    if (item.kind == UiCardKind.Steer && item.title == "Queued") {
        return TranscriptItemStatus.Queued
    }
    match (item.state) {
        case "running" => TranscriptItemStatus.Running
        case "streaming" => TranscriptItemStatus.Streaming
        case "waiting" | "awaiting" | "awaiting_user" => TranscriptItemStatus.Awaiting
        case "warning" | "conflict" => TranscriptItemStatus.Conflict
        case "proposed" | "applying" => TranscriptItemStatus.Running
        case "completed" | "success" => TranscriptItemStatus.Done
        case "approved-once" | "approved-session" => TranscriptItemStatus.Approved
        case "failed" => TranscriptItemStatus.Failed
        case "timed_out" | "timeout" => TranscriptItemStatus.TimedOut
        case "expired" => TranscriptItemStatus.Expired
        case "cancelled" => TranscriptItemStatus.Cancelled
        case "rejected" | "denied" => TranscriptItemStatus.Rejected
        case _ => TranscriptItemStatus.Pending
    }
}

// Card type does not choose a color.  The event rail stays dim and the state
// marker in the title carries the small amount of status emphasis.
func productCardBorderColor(theme: ProductTheme, kind: UiCardKind): Color {
    if (kind == UiCardKind.Tool) {
        theme.toolBorder
    } else {
        theme.muted
    }
}

func productTranscriptCardTheme(
    theme: ProductTheme,
    item: UiCard
): TranscriptCardTheme {
    let isTool = item.kind == UiCardKind.Tool
    let isUser = item.kind == UiCardKind.User
    let isShell = isTool && isShellToolCard(item)
    let borderColor = productCardBorderColor(theme, item.kind)
    let titleColor = match (productTranscriptStatus(item)) {
        case TranscriptItemStatus.Failed | TranscriptItemStatus.TimedOut => theme.danger
        case TranscriptItemStatus.Expired => theme.warning
        case TranscriptItemStatus.Awaiting | TranscriptItemStatus.Rejected | TranscriptItemStatus.Conflict => theme
            .warning
        case TranscriptItemStatus.Running | TranscriptItemStatus.Streaming => theme.accent
        case TranscriptItemStatus.Done | TranscriptItemStatus.Approved => theme.success
        case _ => theme.text
    }
    // Non-shell tools keep the existing compact rail and interaction, but
    // their whole header must not become a bold success/running banner.  The
    // rail already communicates state textually; a secondary foreground is
    // enough for normal tool states, with failure remaining locally visible.
    let compactToolTitleColor = match (productTranscriptStatus(item)) {
        case TranscriptItemStatus.Failed | TranscriptItemStatus.TimedOut => theme.danger
        case TranscriptItemStatus.Expired | TranscriptItemStatus.Awaiting | TranscriptItemStatus.Rejected |
            TranscriptItemStatus.Conflict => theme.warning
        case _ => theme.secondary
    }
    let titleModifier = if (isTool) { Modifier.none() } else { Modifier.strong() }
    TranscriptCardTheme(
        style: Style(fg: theme.text, bg: theme.background),
        titleStyle: Style(
            fg: if (isTool) { compactToolTitleColor } else { theme.text },
            bg: theme.background,
            modifier: titleModifier
        ),
        mutedStyle: Style(
            fg: if (isTool) { theme.toolMetadata } else { theme.muted },
            bg: theme.background
        ),
        selectedStyle: Style(
            fg: theme.accent,
            bg: theme.background,
            modifier: Modifier.strong()
        ),
        bodyIndent: if (isShell || isUser) { 0 } else { 2 },
        bodyLimit: if (item.kind == UiCardKind.Error) {
            4
        } else {
            0
        },
        borderStyle: Style(
            fg: borderColor,
            bg: theme.background
        ),
        borderBackground: Style(bg: if (isUser) { theme.userMessageBg } else { theme.background }),
        topTitleStyle: Style(
            fg: if (isTool) { compactToolTitleColor } else { titleColor },
            bg: theme.background,
            modifier: titleModifier
        ),
        fullFrame: isShell,
        fillBackground: isUser,
        contentPadding: if (isUser) {
            Spacing.symmetric(horizontal: 2, vertical: 1)
        } else if (isShell) {
            Spacing.symmetric(horizontal: 1, vertical: 0)
        } else {
            Spacing.zero()
        }
    )
}

func productCardDetail(item: UiCard, width: Int64): String {
    if (item.kind == UiCardKind.Approval && !approvalCardIsWaiting(item.state)) {
        return ""
    }
    let detail = toolCardDetail(item.body, item.state)
    if (item.kind != UiCardKind.Error && item.collapsed && (item.kind == UiCardKind.Tool || item.title.startsWith("Tool")) &&
        looksStructured(detail)) {
        return ""
    }
    if ((item.kind == UiCardKind.Tool || item.title.startsWith("Tool")) && item.collapsed) {
        return compactToolPreview(detail, max(1, width - 2))
    }
    if (item.kind == UiCardKind.Tool || item.title.startsWith("Tool")) {
        // Expanded tool cards cap their body so a huge output cannot blow
        // up the transcript; the tail is summarized with a line count.
        return limitToolDetail(detail, 0)
    }
    detail
}

func productCardDuration(item: UiCard): String {
    let prefix = item.state + " · "
    if (!item.state.isEmpty() && item.body.startsWith(prefix)) {
        let firstLine = match (item.body.indexOf("\n")) {
            case Some(end) => item.body[..end]
            case None => item.body
        }
        if (firstLine.size > prefix.size) {
            return firstLine[prefix.size..]
        }
    }
    ""
}

func isShellToolCard(item: UiCard): Bool {
    match (agentCardRendererKind(item)) {
        case AgentCardRendererKind.Shell => true
        case _ => false
    }
}

func shellToolMetadata(item: UiCard, unicode: Bool): String {
    let open = if (unicode) { "〈" } else { "<" }
    let close = if (unicode) { "〉" } else { ">" }
    let running = item.state == "running" || item.state == "streaming"
    if (running) {
        let elapsed = match (item.toolStartedAt) {
            case Some(startedAt) => max(0, (MonoTime.now() - startedAt).toMilliseconds())
            case None => item.toolElapsedMillis
        }
        let separator = if (unicode) { " · " } else { " - " }
        return open + "Running" + separator + formatElapsedMillis(elapsed) + close
    }

    let fields = ArrayList<String>()
    if (item.toolElapsedMillis > 0) {
        fields.add("Wall: " + formatElapsedMillis(item.toolElapsedMillis))
    } else {
        let duration = productCardDuration(item)
        if (duration != "") {
            fields.add("Wall: " + duration)
        }
    }
    let result = if (item.toolResult != "") { item.toolResult } else { item.toolOutput }
    let exitCode = parseStringField(result, "exit_code")
    if (item.state == "timed_out" || item.state == "timeout") {
        fields.add("Timeout")
    }
    if (exitCode != "") {
        fields.add("Exit: " + exitCode)
    }
    let directArtifact = parseStringField(result, "artifact")
    let artifact = if (directArtifact != "") { directArtifact } else { parseStringField(result, "artifact_id") }
    if (artifact != "") {
        fields.add("Artifact: " + artifact)
    }
    if (item.footer != "") {
        fields.add(item.footer)
    }
    if (fields.isEmpty()) {
        return ""
    }
    var summary = ""
    for (index in 0..fields.size) {
        if (index > 0) { summary += " | " }
        summary += fields[index]
    }
    open + summary + close
}

func productMarkdownTheme(
    theme: ProductTheme,
    kind!: UiCardKind = UiCardKind.Assistant
): DocumentTheme {
    let bodyColor = if (kind == UiCardKind.Reasoning) {
        theme.reasoning
    } else if (kind == UiCardKind.User) {
        theme.userMessageText
    } else {
        theme.text
    }
    let background = if (kind == UiCardKind.User) { theme.userMessageBg } else { theme.background }
    let bodyModifier = if (kind == UiCardKind.Reasoning) {
        italicProductModifier()
    } else {
        Modifier.none()
    }
    DocumentTheme(
        paragraph: Style(
            fg: bodyColor,
            bg: background,
            modifier: bodyModifier
        ),
        heading: Style(
            fg: theme.accent,
            bg: background,
            modifier: Modifier.strong()
        ),
        heading2: Some(
            Style(
                fg: theme.secondary,
                bg: background,
                modifier: Modifier.strong()
            )
        ),
        heading3: Some(
            Style(
                fg: theme.text,
                bg: background,
                modifier: Modifier.strong()
            )
        ),
        list: Style(fg: theme.secondary, bg: background),
        quoteStyle: Style(
            fg: theme.reasoning,
            bg: background,
            modifier: italicProductModifier()
        ),
        code: Style(fg: theme.tool, bg: theme.raised),
        table: Style(fg: theme.secondary, bg: background),
        link: Style(
            fg: theme.secondary,
            bg: background,
            modifier: Modifier.strong()
        ),
        emphasis: Style(
            fg: bodyColor,
            bg: background,
            modifier: italicProductModifier()
        ),
        strong: Style(
            fg: bodyColor,
            bg: background,
            modifier: Modifier.strong()
        ),
        inlineCode: Style(fg: theme.tool, bg: theme.raised),
        diagnostic: Style(fg: theme.danger, bg: background),
        html: Style(fg: theme.muted, bg: background),
        strikethrough: Style(fg: theme.muted, bg: background),
        tableHeader: Style(
            fg: theme.accent,
            bg: background,
            modifier: Modifier.strong()
        )
    )
}

func italicProductModifier(): Modifier {
    var modifier = Modifier.none()
    modifier.italic = true
    modifier
}

func isApprovalRejectionToolCard(item: UiCard): Bool {
    item.title.startsWith("Tool result") && item.body.contains("tool.approval_rejected")
}

func looksStructured(value: String): Bool {
    let trimmed = value.trimAscii()
    trimmed.startsWith("{") || trimmed.startsWith("[")
}

func compactRunStatus(value: String): String {
    let trimmed = value.trimAscii()
    if (trimmed == "") {
        return "ready"
    }
    let lower = trimmed.toAsciiLower()
    if (lower.contains("approval_rejected") || lower.contains("approval rejected")) {
        return "rejected"
    }
    if (lower.contains("error") || lower.contains("failed")) {
        return "error"
    }
    if (displayWidth(trimmed) <= 36) {
        return trimmed
    }
    cut(trimmed, 35) + "…"
}

func toolCardDetail(body: String, state: String): String {
    if (body == state) {
        return ""
    }
    let prefix = state + "\n"
    if (state != "" && body.startsWith(prefix)) {
        return body[prefix.size..]
    }
    let timedPrefix = state + " · "
    if (state != "" && body.startsWith(timedPrefix)) {
        let lines = body.split("\n")
        if (lines.size <= 1) {
            return ""
        }
        var detail = ""
        for (index in 1..lines.size) {
            if (index > 1) {
                detail += "\n"
            }
            detail += lines[index]
        }
        return detail
    }
    body
}

// Human-readable tool-call summary for the card title, generated from the
// arguments JSON (never the raw object). Rules mirror the OMP tool card:
//   shell        -> Run <command>
//   file read    -> Read <file>
//   file modify  -> Edit <file>
//   search       -> Search "<pattern>" in <directory>
//   directory    -> List <directory>
//   network      -> <METHOD> <URL>
//   fallback     -> <tool name>
public func summarizeToolCall(name: String, arguments: String): String {
    let command = parseStringField(arguments, "command")
    if (command != "") {
        return "Run " + redactSensitiveText(command)
    }
    match (name) {
        case "read" =>
            let path = parseStringField(arguments, "path")
            if (path != "") {
                return "Read " + redactSensitiveText(path)
            }
        case "edit" =>
            let path = parseStringField(arguments, "path")
            if (path != "") {
                return "Edit " + redactSensitiveText(path)
            }
        case "write" =>
            let path = parseStringField(arguments, "path")
            if (path != "") {
                return "Create " + redactSensitiveText(path)
            }
        case "grep" =>
            let pattern = parseStringField(arguments, "pattern")
            let path = parseStringField(arguments, "path")
            if (pattern != "") {
                return "Search \"" + redactSensitiveText(pattern) + "\"" + if (path == "") {
                    ""
                } else {
                    " in " + redactSensitiveText(path)
                }
            }
        case "glob" =>
            let path = parseStringField(arguments, "path")
            if (path != "") {
                return "List " + redactSensitiveText(path)
            }
        case "hub" =>
            let op = parseStringField(arguments, "op")
            if (op != "") {
                return "Hub " + redactSensitiveText(op)
            }
        case "web_search" =>
            let query = parseStringField(arguments, "query")
            if (query != "") {
                return "Search web \"" + redactSensitiveText(query) + "\""
            }
        case "http" | "request" | "fetch" | "web_fetch" =>
            let method = parseStringField(arguments, "method")
            let url = fieldOr(parseStringField(arguments, "url"), parseStringField(arguments, "uri"))
            if (url != "") {
                return (if (method == "") {
                    "GET"
                } else {
                    method.toAsciiUpper()
                }) + " " + redactSensitiveText(url)
            }
        case _ => ()
    }
    if (name == "") { "Tool" } else { name }
}

// Extract a top-level string field from a flat JSON object without pulling
// in a JSON dependency. Handles "\n"-style escapes so summaries stay clean.
func parseStringField(json: String, field: String): String {
    let needle = "\"" + field + "\":"
    match (json.indexOf(needle)) {
        case Some(found) =>
            var pos = found + needle.size
            while (pos < json.size && (json[pos] == b' ' || json[pos] == b'\t')) {
                pos++
            }
            if (pos >= json.size) {
                return ""
            }
            if (json[pos] == b'"') {
                pos++
                let start = pos
                var end = pos
                while (pos < json.size) {
                    if (json[pos] == b'\\' && pos + 1 < json.size) {
                        pos += 2
                        continue
                    }
                    if (json[pos] == b'"') {
                        end = pos
                        break
                    }
                    pos++
                }
                if (end <= start) {
                    return ""
                }
                let raw = json[start..end]
                raw.replace("\\n", "\n").replace("\\t", "\t").replace("\\\"", "\"").replace("\\\\", "\\")
            } else {
                // Number / boolean / null literal: read until , or }.
                var end = pos
                while (end < json.size && json[end] != b',' && json[end] != b'}') {
                    end++
                }
                json[pos..end].trimAscii()
            }
        case None => ""
    }
}

// Strip ANSI escape sequences (colors/cursor moves) from terminal output so
// the card shows clean text instead of raw escape bytes.
func stripAnsi(text: String): String {
    var out = ""
    var i: Int64 = 0
    while (i < text.size) {
        if (text[i] == 0x1b) {
            if (i + 1 < text.size && text[i + 1] == b'[') {
                var j = i + 2
                while (j < text.size && !(text[j] >= b'@' && text[j] <= b'~')) {
                    j++
                }
                if (j < text.size) {
                    j++
                }
                i = j
            } else if (i + 1 < text.size && text[i + 1] == b']') {
                // OSC title/hyperlink sequences end at BEL or ST.  Do not
                // leak either the control bytes or the hyperlink payload.
                var j = i + 2
                while (j < text.size && text[j] != 0x07) {
                    if (text[j] == 0x1b && j + 1 < text.size && text[j + 1] == b'\\') {
                        j += 2
                        break
                    }
                    j++
                }
                if (j < text.size && text[j] == 0x07) {
                    j++
                }
                i = j
            } else {
                i = min(text.size, i + 2)
            }
        } else if (text[i] < 0x20 && text[i] != b'\n' && text[i] != b'\r' && text[i] != b'\t') {
            i++
        } else {
            let first = text[i]
            var width: Int64 = 1
            if ((first & 0b1110_0000) == 0b1100_0000) {
                width = 2
            } else if ((first & 0b1111_0000) == 0b1110_0000) {
                width = 3
            } else if ((first & 0b1111_1000) == 0b1111_0000) {
                width = 4
            }
            out += text[i..min(text.size, i + width)]
            i += width
        }
    }
    out
}

// Structured card body for a finished tool call: parameter area (path /
// command / pattern) then the result area (output or error + exit code).
// Terminal output keeps its line breaks and indentation; long output is
// truncated with a line count. ANSI is stripped.
func beautifyToolDetail(
    name: String,
    arguments: String,
    output: String,
    failed: Bool
): String {
    var body = ""
    var added = 0
    func addSection(title: String, content: String): Unit {
        if (content == "") {
            return
        }
        if (added > 0) {
            body += "\n\n"
        }
        body += title + "\n" + content
        added += 1
    }
    match (name) {
        case "bash" | "bash_readonly" =>
            let command = parseStringField(arguments, "command")
            addSection("command", redactSensitiveText(command))
            let stdout = parseStringField(output, "stdout")
            let stderr = parseStringField(output, "stderr")
            if (failed) {
                addSection("error", if (stderr.trimAscii() != "") {
                    stderr
                } else {
                    stdout
                })
            } else {
                addSection("result", stdout)
            }
        case "read" =>
            let path = parseStringField(arguments, "path")
            addSection("path", path)
            let content = parseStringField(output, "content")
            addSection("result", content)
        case "edit" | "write" | "glob" =>
            let path = parseStringField(arguments, "path")
            addSection("path", path)
            let payload = parseStringField(output, "paths")
            addSection("result", if (payload == "") {
                stripAnsi(output)
            } else {
                payload
            })
        case "grep" =>
            let pattern = parseStringField(arguments, "pattern")
            let path = parseStringField(arguments, "path")
            addSection("pattern", pattern)
            addSection("path", path)
            let matches = parseStringField(output, "matches")
            addSection("result", if (matches == "") {
                stripAnsi(output)
            } else {
                matches
            })
        case "hub" =>
            let op = parseStringField(arguments, "op")
            addSection("op", op)
            addSection("result", stripAnsi(output))
        case _ =>
            let clean = stripAnsi(output).replace("\r", "")
            if (failed) {
                addSection("error", clean)
            } else {
                addSection("result", clean)
            }
    }
    body
}

// Bottom rail summary for a finished tool call, derived from the structured
// output JSON: exit code + line count for shell, line/match/entry counts for
// read/grep/glob.
func toolFooter(name: String, output: String): String {
    match (name) {
        case "bash" | "bash_readonly" =>
            let exit = parseStringField(output, "exit_code")
            let stdout = parseStringField(output, "stdout")
            let lines = stdout.split("\n").size
            if (exit != "") {
                "exit " + exit + " · " + lines.toString() + " lines"
            } else {
                lines.toString() + " lines"
            }
        case "read" =>
            let content = parseStringField(output, "content")
            if (content == "") {
                ""
            } else {
                content.split("\n").size.toString() + " lines"
            }
        case "grep" =>
            let total = parseStringField(output, "total")
            if (total != "") {
                total + " matches"
            } else {
                let count = parseStringField(output, "count")
                if (count == "") {
                    ""
                } else {
                    count + " matches"
                }
            }
        case "glob" =>
            let count = parseStringField(output, "count")
            if (count == "") {
                ""
            } else {
                count + " entries"
            }
        case _ => ""
    }
}

func limitToolDetail(detail: String, _maxLines: Int64): String {
    let _ = _maxLines
    // OMP output windowing: under 12 lines show everything; 12-60 show the
    // first 6 and last 6; over 60 show the first 5 and last 8. The hidden
    // middle is summarized with a line count.
    let lines = detail.split("\n")
    if (lines.size <= 12) {
        return detail
    }
    let headCount: Int64 = if (lines.size > 60) {
        5
    } else {
        6
    }
    let tailCount: Int64 = if (lines.size > 60) {
        8
    } else {
        6
    }
    var out = ""
    for (index in 0..headCount) {
        if (out != "") {
            out += "\n"
        }
        out += lines[index]
    }
    out += "\n… " + (lines.size - headCount - tailCount).toString() + " lines hidden …"
    for (index in (lines.size - tailCount)..lines.size) {
        out += "\n" + lines[index]
    }
    out
}

func readableCardState(state: String): String {
    match (state) {
        case "running" => "running"
        case "queued" => "queued"
        case "waiting" => "waiting"
        case "streaming" => "streaming"
        case "completed" | "success" => "completed"
        case "proposed" => "proposed"
        case "applying" => "applying"
        case "applied" => "applied"
        case "failed" => "failed"
        case "timed_out" => "timed out"
        case "awaiting" | "awaiting_user" => "Awaiting your decision"
        case "approved-once" => "allowed once"
        case "approved-session" => "allowed for session"
        case "rejected" | "denied" => "denied"
        case _ => state
    }
}

func approvalCardIsWaiting(state: String): Bool {
    state == "awaiting" || state == "awaiting_user"
}

func approvalReviewCardBody(
    state: String,
    risk: String,
    reviewer: String,
    riskReason: String,
    reviewReason: String,
    failure: String
): String {
    if (state == "reviewing") {
        return "◐ Reviewing with AI…" + if (reviewer == "") {
            ""
        } else {
            "\nReviewer  " + reviewer
        }
    }
    var body = "Risk      " + risk
    if (reviewer != "") {
        body += "\nReviewer  " + reviewer
    }
    if (riskReason != "") {
        body += "\nReason    " + riskReason
    }
    if (failure != "") {
        body += "\nFailure   " + failure + if (reviewReason == "") {
            ""
        } else {
            " · " + reviewReason
        }
    } else if (reviewReason != "" && reviewReason != riskReason) {
        body += "\nReview    " + reviewReason
    }
    body
}

func compactToolPreview(value: String, width: Int64): String {
    let compact = value.replace("\r", "").replace("\\n", " ↵ ").replace("\n", " · ")
    if (displayWidth(compact) <= width) {
        return compact
    }
    cut(compact, max(1, width - 2)) + " …"
}
