package agent_tui

import core.*
import std.collection.*
import std.convert.*
import std.deriving.*

// Structured event cards deliberately use a small registry instead of making
// the transcript widget know about tool names.  Ordinary conversation keeps
// the plain transcript path; only these event kinds get the left rail.
@Derive[Equatable]
public enum AgentCardRendererKind {
    | Shell
    | Http
    | Git
    | Mcp
    | Read
    | Search
    | List
    | Create
    | Edit
    | Plan
    | Ask
    | Permission
    | Subagent
    | Advisor
    | Job
    | Error
    | Warning
    | Compaction
    | Summary
    | Generic
}

// The renderer registry is also the source of truth for the headless card
// gallery.  Match data and fixture data live together so adding a renderer
// cannot silently leave the visual/semantic contract uncovered.
public class AgentCardFixtureMetadata {
    public let key: String
    public let semanticKind: UiCardKind
    public let toolName: String
    public let title: String
    public let semanticNeedle: String

    public init(
        key: String,
        semanticKind: UiCardKind,
        toolName: String,
        title: String,
        semanticNeedle: String
    ) {
        this.key = key
        this.semanticKind = semanticKind
        this.toolName = toolName
        this.title = title
        this.semanticNeedle = semanticNeedle
    }
}

public class AgentCardRendererDescriptor {
    public let renderer: AgentCardRendererKind
    public let semanticKinds: Array<UiCardKind>
    public let toolAliases: Array<String>
    public let toolPrefixes: Array<String>
    public let toolContains: Array<String>
    public let titlePrefixes: Array<String>
    public let titleContains: Array<String>
    public let lifecycleStates: Array<String>
    public let fixture: AgentCardFixtureMetadata

    public init(
        renderer: AgentCardRendererKind,
        fixture: AgentCardFixtureMetadata,
        semanticKinds!: Array<UiCardKind> = [],
        toolAliases!: Array<String> = [],
        toolPrefixes!: Array<String> = [],
        toolContains!: Array<String> = [],
        titlePrefixes!: Array<String> = [],
        titleContains!: Array<String> = [],
        lifecycleStates!: Array<String> = ["completed"]
    ) {
        this.renderer = renderer
        this.fixture = fixture
        this.semanticKinds = semanticKinds
        this.toolAliases = toolAliases
        this.toolPrefixes = toolPrefixes
        this.toolContains = toolContains
        this.titlePrefixes = titlePrefixes
        this.titleContains = titleContains
        this.lifecycleStates = lifecycleStates
    }

    func matchesNormalized(kind: UiCardKind, tool: String, title: String): Bool {
        for (semanticKind in semanticKinds) {
            if (semanticKind == kind) {
                return true
            }
        }
        if (stringArrayContains(toolAliases, tool)) {
            return true
        }
        for (prefix in toolPrefixes) {
            if (tool.startsWith(prefix)) {
                return true
            }
        }
        for (fragment in toolContains) {
            if (tool.contains(fragment)) {
                return true
            }
        }
        for (prefix in titlePrefixes) {
            if (title.startsWith(prefix)) {
                return true
            }
        }
        for (fragment in titleContains) {
            if (title.contains(fragment)) {
                return true
            }
        }
        false
    }
}

let AGENT_CARD_RENDERER_REGISTRY: Array<AgentCardRendererDescriptor> = [
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Permission,
        AgentCardFixtureMetadata("approval", UiCardKind.Permission, "", "Approval · Write file", "MEDIUM RISK"),
        semanticKinds: [UiCardKind.Approval, UiCardKind.Permission],
        lifecycleStates: ["awaiting_user", "denied", "expired"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Ask,
        AgentCardFixtureMetadata("ask", UiCardKind.Ask, "", "Choose implementation", "Shared renderer"),
        semanticKinds: [UiCardKind.Ask],
        lifecycleStates: ["awaiting_user", "cancelled"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Plan,
        AgentCardFixtureMetadata("plan", UiCardKind.Plan, "", "Implementation plan", "Inspect renderer registry"),
        semanticKinds: [UiCardKind.Plan],
        lifecycleStates: ["pending", "completed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Subagent,
        AgentCardFixtureMetadata("subagent", UiCardKind.Subagent, "", "Subagent · Code review", "Inspecting approval ownership"),
        semanticKinds: [UiCardKind.Subagent],
        titlePrefixes: ["subagent"],
        lifecycleStates: ["queued", "running", "streaming", "completed", "failed", "cancelled", "timed_out"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Advisor,
        AgentCardFixtureMetadata("advisor", UiCardKind.Advisor, "", "Advisor · Permission review", "normalized path components"),
        semanticKinds: [UiCardKind.Advisor],
        titlePrefixes: ["advisor"],
        lifecycleStates: ["completed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Job,
        AgentCardFixtureMetadata("job", UiCardKind.Job, "", "Background · Build search index", "Building search index"),
        semanticKinds: [UiCardKind.Job],
        titlePrefixes: ["background"],
        lifecycleStates: ["queued", "running", "completed", "failed", "cancelled", "timed_out"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Error,
        AgentCardFixtureMetadata("error", UiCardKind.Error, "", "Build failed", "mismatched types"),
        semanticKinds: [UiCardKind.Error],
        titlePrefixes: ["error"],
        titleContains: ["failed"],
        lifecycleStates: ["failed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Warning,
        AgentCardFixtureMetadata("warning", UiCardKind.Warning, "", "Context usage is high", "924K"),
        semanticKinds: [UiCardKind.Warning],
        lifecycleStates: ["warning"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Compaction,
        AgentCardFixtureMetadata("compaction", UiCardKind.Compaction, "", "Context compacted", "messages summarized"),
        semanticKinds: [UiCardKind.Compaction],
        lifecycleStates: ["running", "completed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Summary,
        AgentCardFixtureMetadata("summary", UiCardKind.Summary, "", "Run summary", "Verified card registry"),
        semanticKinds: [UiCardKind.Summary],
        lifecycleStates: ["completed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Git,
        AgentCardFixtureMetadata("git", UiCardKind.Tool, "git", "Git status", "feat/approval-cards"),
        toolAliases: ["git", "github"],
        titlePrefixes: ["git "],
        lifecycleStates: ["completed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Mcp,
        AgentCardFixtureMetadata("mcp::create_issue", UiCardKind.Mcp, "mcp::create_issue", "MCP · GitHub · Create issue",
            "GitHub"),
        semanticKinds: [UiCardKind.Mcp],
        toolPrefixes: ["mcp"],
        toolContains: ["::"],
        lifecycleStates: ["streaming", "completed", "failed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Http,
        AgentCardFixtureMetadata("http", UiCardKind.Tool, "http", "HTTP request · POST api.example.com/v1/items",
            "POST https://api.example.com/v1/items"),
        toolAliases: ["http", "request", "fetch", "web_fetch"],
        lifecycleStates: ["pending", "running", "completed", "failed", "timed_out"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Shell,
        AgentCardFixtureMetadata("bash", UiCardKind.Tool, "bash", "Run cargo test -p cube", "$ cargo test -p cube"),
        toolContains: ["bash", "shell"],
        titlePrefixes: ["run "],
        lifecycleStates: ["queued", "running", "streaming", "completed", "failed", "cancelled", "timed_out"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Read,
        AgentCardFixtureMetadata("read", UiCardKind.Tool, "read", "Read src/魔方/cube_model.js", "export class Cube"),
        toolAliases: ["read"],
        titlePrefixes: ["read "],
        lifecycleStates: ["completed", "failed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Search,
        AgentCardFixtureMetadata("grep", UiCardKind.Tool, "grep", "Search \"ApprovalRequest\" in src", "ApprovalRequest"),
        toolAliases: ["grep"],
        toolContains: ["search"],
        titlePrefixes: ["search "],
        lifecycleStates: ["completed", "failed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.List,
        AgentCardFixtureMetadata("glob", UiCardKind.Tool, "glob", "List src", "src/a.cj"),
        toolAliases: ["glob", "list"],
        titlePrefixes: ["list "],
        lifecycleStates: ["completed", "failed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Edit,
        AgentCardFixtureMetadata("edit", UiCardKind.Tool, "edit", "Edit src/cube_model.js · +2 −1", "+new"),
        toolAliases: ["edit"],
        titlePrefixes: ["edit "],
        lifecycleStates: ["completed", "failed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Create,
        AgentCardFixtureMetadata("write", UiCardKind.Tool, "write", "Create src/cube_model.js", "src/cube_model.js"),
        toolAliases: ["write", "create"],
        titlePrefixes: ["write ", "create "],
        lifecycleStates: ["completed", "failed"]
    ),
    AgentCardRendererDescriptor(
        AgentCardRendererKind.Generic,
        AgentCardFixtureMetadata("custom_tool", UiCardKind.Tool, "custom_tool", "Custom tool", "Generic tool view"),
        lifecycleStates: ["completed"]
    )
]

public func agentCardRendererRegistry(): Array<AgentCardRendererDescriptor> {
    AGENT_CARD_RENDERER_REGISTRY
}

public func agentCardRendererDescriptor(item: UiCard): AgentCardRendererDescriptor {
    let kind = item.kind
    let rawTool = item.toolName.toAsciiLower()
    let title = item.title.toAsciiLower()
    let tool = if (rawTool == "") {
        title
    } else {
        rawTool
    }
    for (descriptor in AGENT_CARD_RENDERER_REGISTRY) {
        if (descriptor.renderer != AgentCardRendererKind.Generic && descriptor.matchesNormalized(kind, tool, title)) {
            return descriptor
        }
    }
    AGENT_CARD_RENDERER_REGISTRY[AGENT_CARD_RENDERER_REGISTRY.size - 1]
}

public func agentCardRendererDescriptorByFixtureKey(key: String): ?AgentCardRendererDescriptor {
    for (descriptor in AGENT_CARD_RENDERER_REGISTRY) {
        if (descriptor.fixture.key == key) {
            return Some(descriptor)
        }
    }
    None
}

// Public renderer names are part of gallery/diagnostic output.  Do not derive
// them from enum spelling, which is free to change independently.
public func agentCardRendererName(renderer: AgentCardRendererKind): String {
    match (renderer) {
        case AgentCardRendererKind.Shell => "shell"
        case AgentCardRendererKind.Http => "http"
        case AgentCardRendererKind.Git => "git"
        case AgentCardRendererKind.Mcp => "mcp"
        case AgentCardRendererKind.Read => "read"
        case AgentCardRendererKind.Search => "search"
        case AgentCardRendererKind.List => "list"
        case AgentCardRendererKind.Create => "create"
        case AgentCardRendererKind.Edit => "edit"
        case AgentCardRendererKind.Plan => "plan"
        case AgentCardRendererKind.Ask => "ask"
        case AgentCardRendererKind.Permission => "permission"
        case AgentCardRendererKind.Subagent => "subagent"
        case AgentCardRendererKind.Advisor => "advisor"
        case AgentCardRendererKind.Job => "job"
        case AgentCardRendererKind.Error => "error"
        case AgentCardRendererKind.Warning => "warning"
        case AgentCardRendererKind.Compaction => "compaction"
        case AgentCardRendererKind.Summary => "summary"
        case AgentCardRendererKind.Generic => "generic"
    }
}

func stringArrayContains(values: Array<String>, expected: String): Bool {
    for (value in values) {
        if (value == expected) {
            return true
        }
    }
    false
}

public class CardContentLimits {
    public let maxLines: Int64
    public let maxBytes: Int64
    public let maxFieldLength: Int64
    public let maxArrayItems: Int64

    public init(
        maxLines!: Int64 = 24,
        maxBytes!: Int64 = 4096,
        maxFieldLength!: Int64 = 1024,
        maxArrayItems!: Int64 = 12
    ) {
        this.maxLines = maxLines
        this.maxBytes = maxBytes
        this.maxFieldLength = maxFieldLength
        this.maxArrayItems = maxArrayItems
    }
}

public func agentCardRendererKind(item: UiCard): AgentCardRendererKind {
    agentCardRendererDescriptor(item).renderer
}

func isGenericCardRenderer(item: UiCard): Bool {
    match (agentCardRendererKind(item)) {
        case AgentCardRendererKind.Generic => true
        case _ => false
    }
}

// Structured tool payloads are not a safe place to echo credentials.  Keep
// the card useful while hiding the common secret-bearing JSON fields and
// bearer headers before any fallback renderer sees them.
func redactSensitiveText(value: String): String {
    var result = value
    for (key in [
        "api_key",
        "apiKey",
        "x-api-key",
        "token",
        "access_token",
        "refresh_token",
        "authorization",
        "cookie",
        "set-cookie",
        "password",
        "secret",
        "private_key",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY"
    ]) {
        result = redactSensitiveFields(result, key)
    }
    for (marker in ["Authorization:", "authorization:", "X-Api-Key:", "x-api-key:", "Cookie:", "Set-Cookie:"]) {
        result = redactHeaderValues(result, marker)
    }
    for (prefix in ["sk-", "ghp_", "github_pat_"]) {
        result = redactPrefixedSecrets(result, prefix)
    }
    result = redactPemBlocks(result)
    redactUrlCredentials(result)
}

func redactHeaderValues(value: String, marker: String): String {
    var result = value
    var offset: Int64 = 0
    while (offset < result.size) {
        match (result[offset..].indexOf(marker)) {
            case None => break
            case Some(relative) =>
                let start = offset + relative + marker.size
                var end = start
                while (end < result.size && result[end] != b'\n' && result[end] != b'\r') {
                    end++
                }
                result = result[..start] + " [REDACTED]" + result[end..]
                offset = start + 11
        }
    }
    result
}

func redactPrefixedSecrets(value: String, prefix: String): String {
    var result = value
    var offset: Int64 = 0
    while (offset < result.size) {
        match (result[offset..].indexOf(prefix)) {
            case None => break
            case Some(relative) =>
                let start = offset + relative
                var end = start + prefix.size
                while (end < result.size && !secretDelimiter(result[end])) {
                    end++
                }
                if (end - start >= prefix.size + 4) {
                    result = result[..start] + "[REDACTED]" + result[end..]
                    offset = start + 10
                } else {
                    offset = end
                }
        }
    }
    result
}

func secretDelimiter(value: Byte): Bool {
    value == b' ' || value == b'\t' || value == b'\n' || value == b'\r' || value == b'"' || value == b'\'' || value ==
        b',' || value == b'}' || value == b']' || value == b'&'
}

func redactPemBlocks(value: String): String {
    let begin = "-----BEGIN "
    match (value.indexOf(begin)) {
        case None => value
        case Some(start) => match (value[start..].indexOf("-----END ")) {
            case None => value[..start] + "[REDACTED PRIVATE KEY]"
            case Some(relativeEnd) =>
                let endStart = start + relativeEnd
                match (value[endStart..].indexOf("-----")) {
                    case None => value[..start] + "[REDACTED PRIVATE KEY]"
                    case Some(firstEnd) => match (value[endStart + firstEnd + 5..].indexOf("-----")) {
                        case None => value[..start] + "[REDACTED PRIVATE KEY]"
                        case Some(secondEnd) =>
                            let end = endStart + firstEnd + 5 + secondEnd + 5
                            value[..start] + "[REDACTED PRIVATE KEY]" + redactPemBlocks(value[end..])
                    }
                }
        }
    }
}

func redactUrlCredentials(value: String): String {
    match (value.indexOf("://")) {
        case None => value
        case Some(scheme) =>
            let start = scheme + 3
            match (value[start..].indexOf("@")) {
                case None => value
                case Some(relativeAt) =>
                    let at = start + relativeAt
                    if (!value[start..at].contains(":")) {
                        return value
                    }
                    value[..start] + "[REDACTED]@" + value[at + 1..]
            }
    }
}

func redactSensitiveFields(value: String, key: String): String {
    var result = value
    let needle = "\"" + key + "\""
    var offset: Int64 = 0
    while (offset < result.size) {
        let found = match (result[offset..].indexOf(needle)) {
            case Some(relative) => offset + relative
            case None => break
        }
        let restStart = found + needle.size
        let rest = result[restStart..]
        let colon = match (rest.indexOf(":")) {
            case Some(value) => value
            case None => break
        }
        var start = colon + 1
        while (start < rest.size && (rest[start] == b' ' || rest[start] == b'\t')) {
            start++
        }
        if (start >= rest.size) {
            break
        }
        let quoted = rest[start] == b'"'
        let valueStart = if (quoted) {
            start + 1
        } else {
            start
        }
        if (rest[valueStart..].startsWith("[REDACTED]")) {
            offset = restStart + valueStart + "[REDACTED]".size
            continue
        }
        var end = valueStart
        if (quoted) {
            while (end < rest.size) {
                if (rest[end] == b'\\') {
                    end += 2
                    continue
                }
                if (rest[end] == b'"') {
                    break
                }
                end++
            }
        } else {
            while (end < rest.size && rest[end] != b',' && rest[end] != b'}') {
                end++
            }
        }
        result = result[..restStart] + rest[..valueStart] + "[REDACTED]" + rest[end..]
        offset = restStart + valueStart + "[REDACTED]".size
    }
    result
}

// The ASCII status form is intentionally textual: it remains understandable
// when Unicode is unavailable and does not make color the only status cue.
func asciiStatusMark(status: TranscriptItemStatus): String {
    match (status) {
        case TranscriptItemStatus.Pending => "[ ]"
        case TranscriptItemStatus.Queued => "[ ]"
        case TranscriptItemStatus.Running | TranscriptItemStatus.Streaming => "[*]"
        case TranscriptItemStatus.Done | TranscriptItemStatus.Approved => "[+]"
        case TranscriptItemStatus.Failed | TranscriptItemStatus.TimedOut => "[x]"
        case TranscriptItemStatus.Cancelled => "[-]"
        case TranscriptItemStatus.Awaiting => "[?]"
        case TranscriptItemStatus.Rejected | TranscriptItemStatus.Expired => "[!]"
        case TranscriptItemStatus.Conflict => "[!]"
    }
}

func formatElapsedMillis(value: Int64): String {
    let safe = max(0, value)
    if (safe < 1000) {
        return safe.toString() + " ms"
    }
    let seconds = safe / 1000
    let tenths = (safe % 1000) / 100
    if (seconds < 60) {
        return seconds.toString() + "." + tenths.toString() + " s"
    }
    let minutes = seconds / 60
    let remainder = seconds % 60
    minutes.toString() + "m " + remainder.toString() + "s"
}

// Keep the action and the useful tail of a path/command.  All slicing uses
// grapheme clusters, so CJK, emoji and combining marks cannot split a cell.
func fitAgentCardTitle(
    title: String,
    budget: Int64,
    unicode: Bool
): String {
    if (budget <= 0) {
        return ""
    }
    if (displayWidth(title) <= budget) {
        return title
    }
    middleEllipsis(title, budget, unicode)
}

func middleEllipsis(value: String, budget: Int64, unicode: Bool): String {
    if (budget <= 0) {
        return ""
    }
    let ellipsis = if (unicode) {
        "…"
    } else {
        "..."
    }
    let ellipsisWidth = displayWidth(ellipsis)
    if (budget <= ellipsisWidth) {
        return cut(value, budget)
    }
    let clusters = graphemeClusters(value)
    var left = ""
    var leftWidth: Int64 = 0
    let leftBudget = (budget - ellipsisWidth + 1) / 2
    var leftIndex: Int64 = 0
    while (leftIndex < clusters.size && leftWidth + clusters[leftIndex].width <= leftBudget) {
        left += clusters[leftIndex].text
        leftWidth += clusters[leftIndex].width
        leftIndex++
    }
    var right = ""
    var rightWidth: Int64 = 0
    let rightBudget = budget - ellipsisWidth - leftWidth
    var rightIndex = clusters.size - 1
    while (rightIndex >= leftIndex && rightWidth + clusters[rightIndex].width <= rightBudget) {
        right = clusters[rightIndex].text + right
        rightWidth += clusters[rightIndex].width
        rightIndex--
    }
    if (left == "" && right == "") {
        return cut(value, budget)
    }
    left + ellipsis + right
}

func cardDocumentLines(text: String, style: Style): Array<DocumentLine> {
    let lines = ArrayList<DocumentLine>()
    for (line in text.replace("\r", "").split("\n")) {
        lines.add(DocumentLine(DocumentLineKind.Paragraph, line, style: style))
    }
    lines.toArray()
}

func addCardBlank(lines: ArrayList<DocumentLine>): Unit {
    if (!lines.isEmpty()) {
        lines.add(DocumentLine(DocumentLineKind.Blank, ""))
    }
}

func addCardLabel(lines: ArrayList<DocumentLine>, label: String, theme: ProductTheme): Unit {
    lines.add(
        DocumentLine(
            DocumentLineKind.Paragraph,
            [RichSpan(label, style: Style(fg: theme.muted, modifier: Modifier.strong()))]
        )
    )
}

func addCardText(
    lines: ArrayList<DocumentLine>,
    text: String,
    theme: ProductTheme,
    style!: Style = Style(fg: Color.Reset)
): Unit {
    let resolved = if (style == Style(fg: Color.Reset)) {
        Style(fg: theme.text)
    } else {
        style
    }
    for (line in cardDocumentLines(text, resolved)) {
        lines.add(line)
    }
}

func addCardSection(
    lines: ArrayList<DocumentLine>,
    label: String,
    value: String,
    theme: ProductTheme,
    style!: Style = Style(fg: Color.Reset)
): Unit {
    if (value.trimAscii() == "") {
        return
    }
    addCardBlank(lines)
    addCardLabel(lines, label, theme)
    addCardText(lines, value, theme, style: style)
}

func fieldOr(value: String, fallback: String): String {
    if (value == "") {
        fallback
    } else {
        value
    }
}

func safeCardField(value: String): String {
    redactSensitiveText(stripAnsi(value).replace("\r", ""))
}

func numericField(json: String, field: String, fallback: Int64): Int64 {
    let value = parseStringField(json, field)
    if (value == "") {
        return fallback
    }
    try {
        Int64.parse(value)
    } catch (_: Exception) {
        fallback
    }
}

func structuredOutput(item: UiCard): String {
    let explicit = if (item.toolOutput != "") {
        item.toolOutput
    } else {
        item.toolResult
    }
    if (explicit != "") {
        return redactSensitiveText(stripAnsi(explicit).replace("\r", ""))
    }
    // A running card starts with the structured invocation preview
    // (for example `command\nfind ...`).  That is already rendered by the
    // specialized parameter section and must not be mistaken for stdout.
    // Only recover output from the explicit streaming/result separator when
    // replaying an older snapshot that has no separate toolOutput field.
    let detail = toolCardDetail(item.body, item.state)
    let resultMarker = "\n\nresult\n"
    match (detail.indexOf(resultMarker)) {
        case Some(position) => redactSensitiveText(stripAnsi(detail[position + resultMarker.size..]).replace("\r", ""))
        case None => ""
    }
}

func cardVisibleText(item: UiCard, value: String): String {
    let clean = stripAnsi(value).replace("\r", "")
    let lines = clean.split("\n")
    if (item.bodyScroll <= 0 || lines.size <= 1) {
        return limitToolDetail(clean, 0)
    }
    let viewport = max(1, item.bodyViewport)
    let start = min(max(0, item.bodyScroll), max(0, lines.size - viewport))
    let end = min(lines.size, start + viewport)
    var output = ""
    for (index in start..end) {
        if (output != "") {
            output += "\n"
        }
        output += lines[index]
    }
    output
}

class StyledToolOutput {
    let lines: Array<DocumentLine>
    let visible: Bool

    init(lines: Array<DocumentLine>, visible: Bool) {
        this.lines = lines
        this.visible = visible
    }
}

func styledToolOutput(value: String, theme: ProductTheme): StyledToolOutput {
    let lines = ArrayList<DocumentLine>()
    let spans = ArrayList<RichSpan>()
    let base = Style(fg: theme.toolOutput, bg: theme.background)
    var style = base
    var text = ""
    var visible = false

    func flushText(): Unit {
        if (text == "") { return }
        spans.add(RichSpan(text, style: style))
        if (toolTextHasVisibleCell(text)) {
            visible = true
        }
        text = ""
    }

    func flushLine(): Unit {
        flushText()
        lines.add(DocumentLine(DocumentLineKind.Paragraph, spans.toArray()))
        spans.clear()
    }

    var index: Int64 = 0
    while (index < value.size) {
        if (value[index] == 0x1b) {
            flushText()
            if (index + 1 < value.size && value[index + 1] == b'[') {
                var end = index + 2
                while (end < value.size && !(value[end] >= b'@' && value[end] <= b'~')) {
                    end++
                }
                if (end >= value.size) {
                    break
                }
                if (value[end] == b'm') {
                    style = applyToolSgr(style, value[(index + 2)..end], base)
                }
                index = end + 1
                continue
            }
            if (index + 1 < value.size && value[index + 1] == b']') {
                var end = index + 2
                while (end < value.size && value[end] != 0x07) {
                    if (value[end] == 0x1b && end + 1 < value.size && value[end + 1] == b'\\') {
                        end += 2
                        break
                    }
                    end++
                }
                if (end < value.size && value[end] == 0x07) { end++ }
                index = end
                continue
            }
            index = min(value.size, index + 2)
            continue
        }
        if (value[index] == b'\n') {
            flushLine()
            index++
            continue
        }
        if (value[index] == b'\r') {
            index++
            continue
        }
        if (value[index] < 0x20 && value[index] != b'\t') {
            index++
            continue
        }
        let first = value[index]
        var bytes: Int64 = 1
        if ((first & 0b1110_0000) == 0b1100_0000) {
            bytes = 2
        } else if ((first & 0b1111_0000) == 0b1110_0000) {
            bytes = 3
        } else if ((first & 0b1111_1000) == 0b1111_0000) {
            bytes = 4
        }
        text += value[index..min(value.size, index + bytes)]
        index += bytes
    }
    flushText()
    if (!spans.isEmpty() || lines.isEmpty()) {
        lines.add(DocumentLine(DocumentLineKind.Paragraph, spans.toArray()))
    }
    // Preserve blank rows inside terminal output, but let the card own the
    // single intentional separation row before metadata.  Otherwise a
    // command ending in several newlines grows a random-looking gap.
    if (visible) {
        while (!lines.isEmpty() && !toolLineHasVisibleCell(lines[lines.size - 1])) {
            lines.remove(at: lines.size - 1)
        }
    }
    StyledToolOutput(lines.toArray(), visible)
}

func toolTextHasVisibleCell(value: String): Bool {
    for (cluster in graphemeClusters(value)) {
        if (displayWidth(cluster.text) > 0 && cluster.text.trimAscii() != "") {
            return true
        }
    }
    false
}

func toolLineHasVisibleCell(line: DocumentLine): Bool {
    for (span in line.spans) {
        if (toolTextHasVisibleCell(span.text)) {
            return true
        }
    }
    false
}

func applyToolSgr(current: Style, sequence: String, base: Style): Style {
    let params = ArrayList<Int64>()
    if (sequence == "") {
        params.add(0)
    } else {
        for (part in sequence.split(";")) {
            if (part == "") {
                params.add(0)
            } else {
                try {
                    params.add(Int64.parse(part))
                } catch (_: Exception) {
                    params.add(-1)
                }
            }
        }
    }
    var style = current
    var index: Int64 = 0
    while (index < params.size) {
        let value = params[index]
        if (value == 0) {
            style = base
        } else if (value == 1) {
            style.modifier.bold = true
        } else if (value == 3) {
            style.modifier.italic = true
        } else if (value == 4) {
            style.modifier.underline = true
        } else if (value == 7) {
            style.modifier.reversed = true
        } else if (value == 22) {
            style.modifier.bold = false
        } else if (value == 23) {
            style.modifier.italic = false
        } else if (value == 24) {
            style.modifier.underline = false
        } else if (value == 27) {
            style.modifier.reversed = false
        } else if (value == 39) {
            style.fg = base.fg
        } else if (value == 49) {
            style.bg = base.bg
        } else if (value >= 30 && value <= 37) {
            style.fg = terminalAnsiColor(value - 30, false)
        } else if (value >= 90 && value <= 97) {
            style.fg = terminalAnsiColor(value - 90, true)
        } else if (value >= 40 && value <= 47) {
            style.bg = terminalAnsiColor(value - 40, false)
        } else if (value >= 100 && value <= 107) {
            style.bg = terminalAnsiColor(value - 100, true)
        } else if ((value == 38 || value == 48) && index + 2 < params.size && params[index + 1] == 5) {
            let color = productColor(Color.Indexed(UInt8(min(255, max(0, params[index + 2])))), productColorLevel())
            if (value == 38) { style.fg = color } else { style.bg = color }
            index += 2
        } else if ((value == 38 || value == 48) && index + 4 < params.size && params[index + 1] == 2) {
            let color = productColor(
                Color.Rgb(
                    UInt8(min(255, max(0, params[index + 2]))),
                    UInt8(min(255, max(0, params[index + 3]))),
                    UInt8(min(255, max(0, params[index + 4])))
                ),
                productColorLevel()
            )
            if (value == 38) { style.fg = color } else { style.bg = color }
            index += 4
        }
        index++
    }
    style
}

func terminalAnsiColor(value: Int64, bright: Bool): Color {
    let color = if (bright) {
        Color.Indexed(UInt8(min(15, max(8, value + 8))))
    } else {
        match (value) {
            case 0 => Color.Black
            case 1 => Color.Red
            case 2 => Color.Green
            case 3 => Color.Yellow
            case 4 => Color.Blue
            case 5 => Color.Magenta
            case 6 => Color.Cyan
            case _ => Color.White
        }
    }
    productColor(color, productColorLevel())
}

func shellStructuredText(value: String): String {
    let structured = value.contains("\"stdout\"") || value.contains("\"stderr\"")
    if (!structured) { return value }
    let stdout = parseStringField(value, "stdout")
    let stderr = parseStringField(value, "stderr")
    if (stdout == "") { return stderr }
    if (stderr == "") { return stdout }
    stdout + if (stdout.endsWith("\n")) { "" } else { "\n" } + stderr
}

func shellCommandSpans(command: String, theme: ProductTheme): Array<RichSpan> {
    let spans = ArrayList<RichSpan>()
    var token = ""
    var executable = true

    func flushToken(): Unit {
        if (token == "") { return }
        let trimmed = token.trimAscii()
        let compound = trimmed.contains(" ") || trimmed.contains("\t") || trimmed.contains("|") ||
            trimmed.contains("&") || trimmed.contains(";") || trimmed.contains(">") || trimmed.contains("<")
        let quotedAtom = (trimmed.startsWith("\"") && trimmed.endsWith("\"") && trimmed.size >= 2) ||
            (trimmed.startsWith("'") && trimmed.endsWith("'") && trimmed.size >= 2)
        let pathLike = trimmed.contains("/") || trimmed.startsWith(".") || trimmed.startsWith("~")
        let color = if (executable && trimmed != "") {
            theme.toolExecutable
        } else if (!compound && (quotedAtom || pathLike)) {
            theme.toolPath
        } else {
            theme.text
        }
        spans.add(RichSpan(token, style: Style(fg: color, bg: theme.background)))
        if (trimmed != "") { executable = false }
        token = ""
    }

    for (cluster in graphemeClusters(command)) {
        let text = cluster.text
        if (text == " " || text == "\t" || text == "\n") {
            flushToken()
            spans.add(RichSpan(text, style: Style(fg: theme.text, bg: theme.background)))
        } else {
            token += text
        }
    }
    flushToken()
    spans.toArray()
}

func shellCommandLines(command: String, width: Int64, theme: ProductTheme): Array<DocumentLine> {
    let result = ArrayList<DocumentLine>()
    var line = ArrayList<RichSpan>()
    let promptStyle = Style(fg: theme.toolPrompt, bg: theme.background)
    let available = max(1, width)
    var used: Int64 = 0

    func beginLine(first: Bool): Unit {
        let prefix = if (first) { "$ " } else { "  " }
        line.add(RichSpan(prefix, style: promptStyle))
        used = min(available, displayWidth(prefix))
    }

    func flushLine(): Unit {
        result.add(DocumentLine(DocumentLineKind.Paragraph, line.toArray()))
        line.clear()
    }

    beginLine(true)
    for (span in shellCommandSpans(command, theme)) {
        for (cluster in graphemeClusters(span.text)) {
            if (cluster.text == "\n") {
                flushLine()
                beginLine(false)
                continue
            }
            let cellWidth = displayWidth(cluster.text)
            if (used + cellWidth > available && used > min(2, available)) {
                flushLine()
                beginLine(false)
            }
            if (used <= min(2, available) && cluster.text.trimAscii() == "") {
                continue
            }
            line.add(RichSpan(cluster.text, style: span.style))
            used += cellWidth
        }
    }
    flushLine()
    result.toArray()
}

func limitedStyledOutput(item: UiCard, output: StyledToolOutput, theme: ProductTheme): Array<DocumentLine> {
    let lines = output.lines
    if (item.bodyScroll > 0 && lines.size > 1) {
        let viewport = max(1, item.bodyViewport)
        let start = min(max(0, item.bodyScroll), max(0, lines.size - viewport))
        return lines[start..min(lines.size, start + viewport)]
    }
    if (lines.size <= 12) { return lines }
    let headCount: Int64 = if (lines.size > 60) { 5 } else { 6 }
    let tailCount: Int64 = if (lines.size > 60) { 8 } else { 6 }
    let result = ArrayList<DocumentLine>()
    for (index in 0..headCount) { result.add(lines[index]) }
    result.add(DocumentLine(
        DocumentLineKind.Paragraph,
        "… " + (lines.size - headCount - tailCount).toString() + " lines hidden …",
        style: Style(fg: theme.toolMetadata, bg: theme.background)
    ))
    for (index in (lines.size - tailCount)..lines.size) { result.add(lines[index]) }
    result.toArray()
}

func shellCardDocument(item: UiCard, width: Int64, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let command = redactSensitiveText(fieldOr(parseStringField(item.toolArguments, "command"), item.title))
    for (line in shellCommandLines(command, width, theme)) {
        lines.add(line)
    }
    let streamed = boundedTerminalPreview(shellStructuredText(item.toolOutput), maximumBytes: 8192,
        maximumLineBytes: 2048)
    var output = styledToolOutput(redactSensitiveText(streamed.text), theme)
    if (!output.visible) {
        let completed = boundedTerminalPreview(shellStructuredText(item.toolResult), maximumBytes: 8192,
            maximumLineBytes: 2048)
        output = styledToolOutput(redactSensitiveText(completed.text), theme)
    }
    if (output.visible) {
        lines.add(DocumentLine(
            DocumentLineKind.HorizontalRule,
            [RichSpan("Output", style: Style(fg: theme.toolPrompt, bg: theme.background))]
        ))
        for (line in limitedStyledOutput(item, output, theme)) {
            lines.add(line)
        }
        lines.add(DocumentLine(DocumentLineKind.Blank, "", style: Style(bg: theme.background)))
    }
    Document(lines.toArray())
}

func numberedReadText(content: String, start: Int64, theme: ProductTheme): Array<DocumentLine> {
    let lines = ArrayList<DocumentLine>()
    let raw = content.replace("\r", "").split("\n")
    var maximum = start + max(0, raw.size - 1)
    let numberWidth = maximum.toString().size
    var index: Int64 = 0
    for (line in raw) {
        let number = (start + index).toString()
        let padded = repeatString(" ", max(0, numberWidth - number.size)) + number
        lines.add(
            DocumentLine(
                DocumentLineKind.CodeBlock,
                [
                    RichSpan(padded + "  ", style: Style(fg: theme.muted)),
                    RichSpan(line, style: Style(fg: theme.text))
                ]
            )
        )
        index++
    }
    lines.toArray()
}

func readCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let path = safeCardField(fieldOr(parseStringField(item.toolArguments, "path"), item.title))
    addCardSection(lines, "file", path, theme)
    let output = structuredOutput(item)
    let content = fieldOr(parseStringField(output, "content"), output)
    if (content == "") {
        addCardText(lines, if (item.state == "running") {
            "◌ reading"
        } else {
            "No content"
        }, theme)
    } else {
        addCardBlank(lines)
        let numbered = numberedReadText(
            cardVisibleText(item, content),
            numericField(item.toolArguments, "start_line", numericField(item.toolArguments, "line_start", 1)),
            theme
        )
        for (line in numbered) {
            lines.add(line)
        }
    }
    Document(lines.toArray())
}

func searchCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let pattern = safeCardField(parseStringField(item.toolArguments, "pattern"))
    let directory = safeCardField(fieldOr(parseStringField(item.toolArguments, "path"),
        parseStringField(item.toolArguments, "directory")))
    if (pattern != "") {
        addCardSection(lines, "pattern", "\"" + pattern + "\"", theme)
    }
    if (directory != "") {
        addCardSection(lines, "directory", directory, theme)
    }
    let output = structuredOutput(item)
    let matches = fieldOr(parseStringField(output, "matches"), output)
    if (matches.trimAscii() == "") {
        addCardText(lines, "No matches", theme, style: Style(fg: theme.muted))
    } else {
        addCardBlank(lines)
        var previousFile = ""
        for (entry in cardVisibleText(item, matches).split("\n")) {
            let (file, line, content) = searchMatchParts(entry)
            let group = if (file == "") {
                ""
            } else {
                file + if (line == "") {
                    ""
                } else {
                    ":" + line
                }
            }
            if (group != "" && file != previousFile) {
                if (previousFile != "") {
                    lines.add(DocumentLine(DocumentLineKind.Blank, ""))
                }
                lines.add(DocumentLine(DocumentLineKind.Paragraph, group, style: Style(fg: theme.secondary)))
                previousFile = file
            }
            if (content == "") {
                lines.add(DocumentLine(DocumentLineKind.Paragraph, "  " + entry, style: Style(fg: theme.text)))
            } else {
                lines.add(
                    DocumentLine(
                        DocumentLineKind.Paragraph,
                        searchContentSpans(content, pattern, theme)
                    )
                )
            }
        }
    }
    Document(lines.toArray())
}

func normalizeDirectoryEntry(entry: String): String {
    let value = entry.trimAscii()
    if (value == "") {
        return ""
    }
    if (value.startsWith("[dir] ")) {
        return ensureDirectorySlash(value[6..])
    }
    if (value.startsWith("dir ")) {
        return ensureDirectorySlash(value[4..])
    }
    if (value.endsWith("\\")) {
        return value[..value.size - 1] + "/"
    }
    value
}

func ensureDirectorySlash(value: String): String {
    if (value == "") {
        return "/"
    }
    if (value.endsWith("/")) {
        value
    } else {
        value + "/"
    }
}

func listCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let directory = safeCardField(fieldOr(parseStringField(item.toolArguments, "path"), item.title))
    addCardSection(lines, "directory", directory, theme)
    let output = structuredOutput(item)
    let entries = fieldOr(parseStringField(output, "entries"), output)
    if (entries.trimAscii() == "") {
        addCardText(lines, "Empty directory", theme, style: Style(fg: theme.muted))
    } else {
        addCardBlank(lines)
        for (entry in cardVisibleText(item, entries).split("\n")) {
            let normalized = normalizeDirectoryEntry(entry)
            if (normalized != "") {
                lines.add(DocumentLine(DocumentLineKind.Paragraph, normalized, style: Style(fg: theme.text)))
            }
        }
    }
    Document(lines.toArray())
}

func diffLineStyle(line: String, theme: ProductTheme): Style {
    if (line.startsWith("@@")) {
        return Style(fg: theme.accent, modifier: Modifier.strong())
    }
    if (line.startsWith("+")) {
        return Style(fg: theme.success)
    }
    if (line.startsWith("-")) {
        return Style(fg: theme.danger)
    }
    Style(fg: theme.text)
}

func diffLineCounts(diff: String): (Int64, Int64) {
    var added: Int64 = 0
    var removed: Int64 = 0
    for (line in diff.split("\n")) {
        if (line.startsWith("+") && !line.startsWith("+++")) {
            added++
        }
        if (line.startsWith("-") && !line.startsWith("---")) {
            removed++
        }
    }
    (added, removed)
}

public func toolTitleWithStats(name: String, arguments: String, output: String): String {
    let base = summarizeToolCall(name, arguments)
    if (name.toAsciiLower() == "write") {
        let path = safeCardField(fieldOr(parseStringField(output, "path"), parseStringField(arguments, "path")))
        let action = parseStringField(output, "action")
        if (path != "") {
            return (if (action == "overwrite") {
                "Update "
            } else {
                "Create "
            }) + path
        }
    }
    if (name.toAsciiLower() != "edit") {
        return base
    }
    let encoded = fieldOr(
        parseStringField(output, "diff"),
        fieldOr(parseStringField(arguments, "diff"), output)
    )
    let (added, removed) = diffLineCounts(encoded)
    if (added == 0 && removed == 0) {
        return base
    }
    base + " · +" + added.toString() + " −" + removed.toString()
}

func editCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let output = structuredOutput(item)
    let diff = fieldOr(
        parseStringField(item.toolArguments, "diff"),
        fieldOr(parseStringField(output, "diff"), output)
    )
    if (diff.trimAscii() == "") {
        addCardText(lines, if (item.state == "running") {
            "◌ applying"
        } else {
            "No diff available"
        }, theme)
    } else {
        addCardBlank(lines)
        var currentFile = ""
        for (line in cardVisibleText(item, diff).split("\n")) {
            let file = diffFileMarker(line)
            if (file != "" && file != currentFile) {
                if (!lines.isEmpty()) {
                    lines.add(DocumentLine(DocumentLineKind.Blank, ""))
                }
                lines.add(
                    DocumentLine(
                        DocumentLineKind.Paragraph,
                        "file  " + file,
                        style: Style(fg: theme.secondary, modifier: Modifier.strong())
                    )
                )
                currentFile = file
            }
            lines.add(DocumentLine(DocumentLineKind.CodeBlock, line, style: diffLineStyle(line, theme)))
        }
    }
    if (item.state != "" && item.state != "completed") {
        addCardSection(lines, "status", readableCardState(item.state), theme)
    }
    Document(lines.toArray())
}

func createCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let path = safeCardField(fieldOr(parseStringField(item.toolArguments, "path"), item.title))
    addCardSection(lines, "file", path, theme)
    let output = structuredOutput(item)
    let fileType = fieldOr(parseStringField(output, "file_type"), parseStringField(output, "language"))
    let lineCount = parseStringField(output, "lines")
    let action = parseStringField(output, "action")
    let bytes = parseStringField(output, "bytes")
    let before = parseStringField(output, "before_bytes")
    if (action != "") {
        addCardSection(lines, "action", if (action == "overwrite") {
            "Updated existing file"
        } else {
            "Created file"
        }, theme)
    }
    if (before != "" && before != "0") {
        addCardSection(lines, "before", before + " bytes", theme)
    }
    if (bytes != "") {
        addCardSection(lines, "after", bytes + " bytes", theme)
    }
    if (fileType != "") {
        addCardSection(lines, "type", fileType, theme)
    }
    if (lineCount != "") {
        addCardSection(lines, "lines", lineCount, theme)
    }
    let description = fieldOr(parseStringField(output, "description"), "")
    if (description != "") {
        addCardSection(lines, "description", description, theme)
    }
    if (lines.isEmpty()) {
        addCardText(lines, "created", theme)
    }
    Document(lines.toArray())
}

func httpCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let method = fieldOr(parseStringField(item.toolArguments, "method"), "GET").toAsciiUpper()
    let url = fieldOr(
        parseStringField(item.toolArguments, "url"),
        parseStringField(item.toolArguments, "uri")
    )
    addCardSection(lines, "request", method + if (url == "") {
        ""
    } else {
        " " + redactSensitiveText(url)
    }, theme)
    let output = structuredOutput(item)
    let status = fieldOr(
        parseStringField(output, "status"),
        fieldOr(parseStringField(output, "status_code"), parseStringField(output, "http_status"))
    )
    if (status != "") {
        addCardSection(
            lines,
            "status",
            status,
            theme,
            style: if (status.startsWith("2") || status == "304") {
                Style(fg: theme.success)
            } else if (status.startsWith("4") || status.startsWith("5")) {
                Style(fg: theme.danger)
            } else {
                Style(fg: theme.secondary)
            }
        )
    }
    var response = fieldOr(
        parseStringField(output, "body"),
        fieldOr(parseStringField(output, "content"), parseStringField(output, "response"))
    )
    if (response == "" && output != "") {
        response = output
    }
    if (response == "" && item.state == "running") {
        response = "◌ waiting for response"
    }
    if (response != "") {
        addCardSection(lines, if (item.state == "failed") {
            "error"
        } else {
            "response"
        }, cardVisibleText(item, redactSensitiveText(response)), theme)
    }
    Document(lines.toArray())
}

func gitCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let operation = safeCardField(fieldOr(parseStringField(item.toolArguments, "action"), parseStringField(item.toolArguments, "op")))
    let repository = safeCardField(fieldOr(parseStringField(item.toolArguments, "repo"),
        parseStringField(item.toolArguments, "repository")))
    let branch = safeCardField(parseStringField(item.toolArguments, "branch"))
    let remote = safeCardField(parseStringField(item.toolArguments, "remote"))
    if (operation != "") {
        addCardSection(lines, "operation", operation.replace("_", " "), theme)
    }
    if (repository != "") {
        addCardSection(lines, "repository", repository, theme)
    }
    if (branch != "") {
        addCardSection(lines, "branch", branch, theme)
    }
    if (remote != "") {
        addCardSection(lines, "remote", remote, theme)
    }
    let output = structuredOutput(item)
    if (output != "") {
        addCardSection(lines, if (item.state == "failed") {
            "error"
        } else {
            "result"
        }, cardVisibleText(item, output), theme)
    }
    Document(lines.toArray())
}

func mcpCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let server = safeCardField(fieldOr(parseStringField(item.toolArguments, "server"),
        parseStringField(item.toolArguments, "server_name")))
    let tool = safeCardField(fieldOr(parseStringField(item.toolArguments, "tool"), item.toolName))
    let resource = safeCardField(fieldOr(parseStringField(item.toolArguments, "resource"), parseStringField(item.toolArguments, "uri")))
    if (server != "") {
        addCardSection(lines, "server", server, theme)
    }
    if (tool != "") {
        addCardSection(lines, "tool", tool, theme)
    }
    if (resource != "") {
        addCardSection(lines, "resource", redactSensitiveText(resource), theme)
    }
    let output = structuredOutput(item)
    if (output != "") {
        addCardSection(lines, if (item.state == "failed") {
            "error"
        } else {
            "result"
        }, limitGenericCardContent(output, CardContentLimits(maxLines: 12, maxBytes: 2048)), theme)
    }
    Document(lines.toArray())
}

func advisorCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    addCardLabel(lines, "concern", theme)
    addCardText(lines, limitGenericCardContent(toolCardDetail(item.body, item.state), CardContentLimits(maxLines: 12)),
        theme)
    Document(lines.toArray())
}

func jobCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    addCardSection(lines, "status", readableCardState(item.state), theme)
    let detail = toolCardDetail(item.body, item.state)
    if (detail != "") {
        addCardSection(lines, if (item.state == "failed") {
            "error"
        } else {
            "current"
        }, cardVisibleText(item, detail), theme)
    }
    Document(lines.toArray())
}

func askCardDocument(item: UiCard, theme: ProductTheme): Document {
    styledEventDocument(item, theme, UiCardKind.Ask)
}

func permissionCardDocument(item: UiCard, theme: ProductTheme): Document {
    styledEventDocument(item, theme, UiCardKind.Permission)
}

func subagentCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    let detail = toolCardDetail(item.body, item.state)
    let values = cardVisibleText(item, detail).split("\n")
    if (!values.isEmpty() && !(values.size == 1 && values[0].trimAscii() == "")) {
        addCardLabel(lines, if (item.state == "completed") {
            "result"
        } else {
            "current"
        }, theme)
        for (value in values) {
            lines.add(DocumentLine(DocumentLineKind.Paragraph, value, style: Style(fg: theme.text)))
        }
    }
    Document(lines.toArray())
}

func systemCardDocument(item: UiCard, theme: ProductTheme): Document {
    styledEventDocument(item, theme, item.kind)
}

func styledEventDocument(item: UiCard, theme: ProductTheme, mode: UiCardKind): Document {
    let lines = ArrayList<DocumentLine>()
    let detail = redactSensitiveText(toolCardDetail(item.body, item.state))
    // Ask choices are interactive controls, not log output. Windowing their
    // middle can hide selectable options behind a "lines hidden" marker.
    let visibleDetail = if (mode == UiCardKind.Ask) {
        detail
    } else {
        cardVisibleText(item, detail)
    }
    let values = visibleDetail.split("\n")
    for (value in values) {
        let trimmed = value.trimAscii()
        let style = if (trimmed.startsWith("›") || trimmed.startsWith("[x]")) {
            Style(fg: theme.accent, modifier: Modifier.strong())
        } else if (mode == UiCardKind.Permission && (trimmed.startsWith("RISK") || trimmed.startsWith("Target"))) {
            Style(fg: theme.warning, modifier: Modifier.strong())
        } else if (mode == UiCardKind.Error && (trimmed.startsWith("error") || trimmed.startsWith("fatal") || trimmed
            .startsWith("✗"))) {
            Style(fg: theme.danger, modifier: Modifier.strong())
        } else if (mode == UiCardKind.Warning || mode == UiCardKind.Compaction) {
            if (trimmed.startsWith("Before") || trimmed.startsWith("After") || trimmed.startsWith("Saved") ||
                trimmed.startsWith("Reason")) {
                Style(fg: theme.secondary)
            } else {
                Style(fg: theme.text)
            }
        } else if (trimmed.startsWith("  ") || trimmed.startsWith("preview:")) {
            Style(fg: theme.muted)
        } else {
            Style(fg: theme.text)
        }
        lines.add(DocumentLine(DocumentLineKind.Paragraph, value, style: style))
    }
    if (lines.isEmpty()) {
        addCardText(lines, readableCardState(item.state), theme)
    }
    Document(lines.toArray())
}

func searchMatchParts(entry: String): (String, String, String) {
    var position: Int64 = 0
    while (position < entry.size) {
        if (entry[position] != b':') {
            position++
            continue
        }
        var digit = position + 1
        while (digit < entry.size && entry[digit] >= b'0' && entry[digit] <= b'9') {
            digit++
        }
        if (digit > position + 1 && digit < entry.size && entry[digit] == b':') {
            return (entry[..position], entry[position + 1..digit], entry[digit + 1..])
        }
        position++
    }
    ("", "", entry)
}

func searchContentSpans(value: String, pattern: String, theme: ProductTheme): Array<RichSpan> {
    let spans = ArrayList<RichSpan>()
    if (pattern == "") {
        spans.add(RichSpan("  " + value, style: Style(fg: theme.text)))
        return spans.toArray()
    }
    match (value.indexOf(pattern)) {
        case Some(position) =>
            if (position > 0) {
                spans.add(RichSpan("  " + value[..position], style: Style(fg: theme.text)))
            }
            spans.add(RichSpan(pattern, style: Style(fg: theme.accent, modifier: Modifier.strong())))
            if (position + pattern.size < value.size) {
                spans.add(RichSpan(value[position + pattern.size..], style: Style(fg: theme.text)))
            }
        case None => spans.add(RichSpan("  " + value, style: Style(fg: theme.text)))
    }
    spans.toArray()
}

func diffFileMarker(line: String): String {
    if (line.startsWith("diff --git ")) {
        let parts = line.split(" ")
        if (parts.size >= 4) {
            let value = parts[parts.size - 1]
            if (value.startsWith("b/")) {
                return value[2..]
            }
            return value
        }
    }
    if (line.startsWith("+++ ")) {
        let value = line[4..]
        if (value.startsWith("b/")) {
            return value[2..]
        }
        return value
    }
    ""
}

func planCardDocument(item: UiCard, theme: ProductTheme): Document {
    let lines = ArrayList<DocumentLine>()
    for (value in stripAnsi(toolCardDetail(item.body, item.state)).split("\n")) {
        let trimmed = value.trimAscii()
        let style = if (trimmed.startsWith("✓")) {
            Style(fg: theme.success)
        } else if (trimmed.startsWith("●")) {
            Style(fg: theme.accent, modifier: Modifier.strong())
        } else if (trimmed.startsWith("✗")) {
            Style(fg: theme.danger)
        } else if (trimmed.startsWith("○") || trimmed.startsWith("–")) {
            Style(fg: theme.muted)
        } else {
            Style(fg: theme.text)
        }
        lines.add(DocumentLine(DocumentLineKind.Paragraph, value, style: style))
    }
    Document(lines.toArray())
}

func genericCardDocument(item: UiCard, theme: ProductTheme): Document {
    var detail = if (item.kind == UiCardKind.Tool) {
        productCardDetail(item, 120)
    } else {
        toolCardDetail(item.body, item.state)
    }
    // Unknown tools may not have a specialized body yet.  Keep their
    // structured arguments available as a last-resort, redacted detail;
    // known renderers never use this raw-argument fallback.
    if (item.kind == UiCardKind.Tool && isGenericCardRenderer(item) && item.toolArguments != "") {
        let arguments = boundedRawCardInput(item.toolArguments, 2048)
        detail = "Generic tool view\nArguments  " + genericArgumentCount(item.toolArguments).toString() + " fields\n\n" +
            redactSensitiveText(stripAnsi(arguments.text))
        if (arguments.truncated) {
            detail += "\n… arguments truncated …"
        }
        let explicitOutput = if (item.toolOutput != "") { item.toolOutput } else { item.toolResult }
        if (explicitOutput != "") {
            let output = boundedRawCardInput(explicitOutput, 2048)
            detail += "\n\nResult\n" + redactSensitiveText(stripAnsi(output.text))
            if (output.truncated) {
                detail += "\n… result truncated …"
            }
        }
    }
    if (detail == "") {
        return Document.plain("", style: Style(fg: theme.text))
    }
    Document.plain(limitGenericCardContent(redactSensitiveText(stripAnsi(detail).replace("\r", "")), CardContentLimits()),
        style: Style(fg: theme.text))
}

class BoundedRawCardInput {
    let text: String
    let truncated: Bool

    init(text: String, truncated: Bool) {
        this.text = text
        this.truncated = truncated
    }
}

func boundedRawCardInput(value: String, maximum: Int64): BoundedRawCardInput {
    if (value.size <= maximum) {
        return BoundedRawCardInput(value, false)
    }
    let bytes = unsafe { value.rawData() }
    var end = min(maximum, bytes.size)
    while (end > 0) {
        try {
            return BoundedRawCardInput(String.fromUtf8(bytes[..end]), true)
        } catch (_: Exception) {
            end--
        }
    }
    BoundedRawCardInput("", true)
}

func genericArgumentCount(value: String): Int64 {
    var count: Int64 = 0
    var depth: Int64 = 0
    var quoted = false
    var escaped = false
    for (byte in value.toArray()) {
        if (escaped) {
            escaped = false
            continue
        }
        if (byte == b'\\' && quoted) {
            escaped = true
            continue
        }
        if (byte == b'"') {
            quoted = !quoted
            continue
        }
        if (quoted) {
            continue
        }
        if (byte == b'{' || byte == b'[') {
            depth++
        }
        if (byte == b'}' || byte == b']') {
            depth--
        }
        if (byte == b':' && depth == 1) {
            count++
        }
    }
    count
}

func limitGenericCardContent(value: String, limits: CardContentLimits): String {
    let lines = value.split("\n")
    let lineLimit = min(lines.size, limits.maxLines)
    var result = ""
    var truncated = lines.size > limits.maxLines
    for (index in 0..lineLimit) {
        let line = truncateCardField(lines[index], limits.maxFieldLength)
        if (line != lines[index]) {
            truncated = true
        }
        if (result != "") {
            result += "\n"
        }
        result += line
        if (result.size >= limits.maxBytes) {
            result = truncateCardField(result, limits.maxBytes)
            truncated = true
            break
        }
    }
    if (truncated) {
        result += "\n… details truncated; expand/scroll for bounded detail …"
    }
    result
}

func truncateCardField(value: String, maximum: Int64): String {
    if (value.size <= maximum) {
        return value
    }
    var output = ""
    for (cluster in graphemeClusters(value)) {
        if (output.size + cluster.text.size > maximum - 1) {
            break
        }
        output += cluster.text
    }
    output + "…"
}

func agentCardBodyDocument(item: UiCard, width: Int64, theme: ProductTheme): Document {
    match (agentCardRendererKind(item)) {
        case AgentCardRendererKind.Shell => shellCardDocument(item, width, theme)
        case AgentCardRendererKind.Http => httpCardDocument(item, theme)
        case AgentCardRendererKind.Git => gitCardDocument(item, theme)
        case AgentCardRendererKind.Mcp => mcpCardDocument(item, theme)
        case AgentCardRendererKind.Read => readCardDocument(item, theme)
        case AgentCardRendererKind.Search => searchCardDocument(item, theme)
        case AgentCardRendererKind.List => listCardDocument(item, theme)
        case AgentCardRendererKind.Create => createCardDocument(item, theme)
        case AgentCardRendererKind.Edit => editCardDocument(item, theme)
        case AgentCardRendererKind.Plan => planCardDocument(item, theme)
        case AgentCardRendererKind.Ask => askCardDocument(item, theme)
        case AgentCardRendererKind.Permission => permissionCardDocument(item, theme)
        case AgentCardRendererKind.Subagent => subagentCardDocument(item, theme)
        case AgentCardRendererKind.Advisor => advisorCardDocument(item, theme)
        case AgentCardRendererKind.Job => jobCardDocument(item, theme)
        case AgentCardRendererKind.Error | AgentCardRendererKind.Warning | AgentCardRendererKind.Compaction
            | AgentCardRendererKind.Summary => systemCardDocument(item, theme)
        case AgentCardRendererKind.Generic => genericCardDocument(item, theme)
    }
}

func repeatString(value: String, count: Int64): String {
    var result = ""
    for (_ in 0..max(0, count)) {
        result += value
    }
    result
}
