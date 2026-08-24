package core

import std.collection.*
import std.env.*

public enum TranscriptItemKind {
    | Text
    | Code
    | Event
    | Error
    | Progress
    | Detail
}

public enum TranscriptItemStatus {
    | Pending
    | Queued
    | Running
    | Streaming
    | Done
    | Awaiting
    | Approved
    | Failed
    | Cancelled
    | Rejected
    | TimedOut
    | Expired
    | Conflict
}

public class TranscriptCardOption {
    public let label: String
    public let selected: Bool

    public init(label: String, selected!: Bool = false) {
        this.label = label
        this.selected = selected
    }
}

public class TranscriptCardTheme {
    public let style: Style
    public let titleStyle: Style
    public let mutedStyle: Style
    public let selectedStyle: Style
    public let bodyIndent: Int64
    public let bodyLimit: Int64
    public let borderStyle: Style
    public let borderBackground: Style
    public let topTitleStyle: Style
    // Transcript hosts can opt individual items into a complete terminal
    // frame or a borderless, full-width background block.  Defaults retain
    // the historical left-rail rendering for existing clients.
    public let fullFrame: Bool
    public let fillBackground: Bool
    public let contentPadding: Spacing

    public init(
        style!: Style = Style.default(),
        titleStyle!: Style = Style(modifier: Modifier.strong()),
        mutedStyle!: Style = Style(fg: Color.Indexed(8)),
        selectedStyle!: Style = Style(fg: Color.Cyan, modifier: Modifier.strong()),
        bodyIndent!: Int64 = 2,
        bodyLimit!: Int64 = 12,
        borderStyle!: Style = Style(fg: Color.Indexed(8)),
        borderBackground!: Style = Style.default(),
        topTitleStyle!: Style = Style(modifier: Modifier.strong()),
        fullFrame!: Bool = false,
        fillBackground!: Bool = false,
        contentPadding!: Spacing = Spacing.zero()
    ) {
        this.style = style
        this.titleStyle = titleStyle
        this.mutedStyle = mutedStyle
        this.selectedStyle = selectedStyle
        this.bodyIndent = max(0, bodyIndent)
        this.bodyLimit = max(0, bodyLimit)
        this.borderStyle = borderStyle
        this.borderBackground = borderBackground
        this.topTitleStyle = topTitleStyle
        this.fullFrame = fullFrame
        this.fillBackground = fillBackground
        this.contentPadding = contentPadding
    }
}

public class TranscriptItem {
    public let id: String
    public let kind: TranscriptItemKind
    public let title: String
    public let body: Document
    public let status: TranscriptItemStatus
    public var collapsed: Bool
    public let timestamp: String
    public let duration: String
    public let stateLabel: String
    public let activityFrame: Int64
    public let options: Array<TranscriptCardOption>
    public let footer: String

    public init(
        id: String,
        kind!: TranscriptItemKind = TranscriptItemKind.Text,
        title!: String = "",
        body!: Document = Document([]),
        status!: TranscriptItemStatus = TranscriptItemStatus.Done,
        collapsed!: Bool = false,
        timestamp!: String = "",
        duration!: String = "",
        stateLabel!: String = "",
        activityFrame!: Int64 = 0,
        options!: Array<TranscriptCardOption> = [],
        footer!: String = ""
    ) {
        this.id = id
        this.kind = kind
        this.title = title
        this.body = body
        this.status = status
        this.collapsed = collapsed
        this.timestamp = timestamp
        this.duration = duration
        this.stateLabel = stateLabel
        this.activityFrame = max(0, activityFrame)
        this.options = options
        this.footer = footer
    }
}

public class Transcript {
    private let items = ArrayList<TranscriptItem>()

    public init(items!: Array<TranscriptItem> = []) {
        for (item in items) { this.items.add(item) }
    }

    public func append(item: TranscriptItem): Unit {
        items.add(item)
    }

    public func size(): Int64 {
        items.size
    }

    public func get(index: Int64): ?TranscriptItem {
        if (index < 0 || index >= items.size) { None } else { Some(items[index]) }
    }

    public func toArray(): Array<TranscriptItem> {
        items.toArray()
    }

    public func toggleCollapsed(id: String): Bool {
        for (item in items) {
            if (item.id == id) {
                item.collapsed = !item.collapsed
                return true
            }
        }
        false
    }
}

public class TranscriptView <: Widget {
    private let transcript: Transcript
    public var offset: Int64
    public var selected: Int64
    private let block: ?Block
    private let style: Style
    private let selectedStyle: Style
    private let cardTheme: TranscriptCardTheme

    public init(
        transcript: Transcript,
        offset!: Int64 = 0,
        selected!: Int64 = 0,
        block!: ?Block = None,
        style!: Style = Style.default(),
        selectedStyle!: Style = Style(fg: Color.Black, bg: Color.White),
        cardTheme!: ?TranscriptCardTheme = None
    ) {
        this.transcript = transcript
        this.offset = max(0, offset)
        this.selected = max(0, selected)
        this.block = block
        this.style = style
        this.selectedStyle = selectedStyle
        this.cardTheme = match (cardTheme) {
            case Some(value) => value
            case None => TranscriptCardTheme(style: style)
        }
    }

    public func handle(key: KeyEvent, viewportHeight: Int64): Bool {
        let count = transcript.size()
        match (key.code) {
            case KeyCode.Up =>
                selected = max(0, selected - 1)
                ensureTranscriptVisible(max(1, viewportHeight))
                true
            case KeyCode.Down =>
                selected = min(max(0, count - 1), selected + 1)
                ensureTranscriptVisible(max(1, viewportHeight))
                true
            case KeyCode.PageUp =>
                selected = max(0, selected - max(1, viewportHeight))
                ensureTranscriptVisible(max(1, viewportHeight))
                true
            case KeyCode.PageDown =>
                selected = min(max(0, count - 1), selected + max(1, viewportHeight))
                ensureTranscriptVisible(max(1, viewportHeight))
                true
            case KeyCode.Enter | KeyCode.Char(r' ') =>
                match (transcript.get(selected)) {
                    case Some(item) => transcript.toggleCollapsed(item.id)
                    case None => false
                }
            case _ => false
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        if (target.width <= 0 || target.height <= 0) { return }
        ensureTranscriptVisible(target.height)
        var y = target.y
        var index = offset
        while (index < transcript.size() && y < target.bottom) {
            match (transcript.get(index)) {
                case Some(item) =>
                    let theme = if (index == selected) {
                        TranscriptCardTheme(
                            style: cardTheme.style,
                            titleStyle: selectedStyle,
                            mutedStyle: cardTheme.mutedStyle,
                            selectedStyle: cardTheme.selectedStyle,
                            bodyIndent: cardTheme.bodyIndent,
                            bodyLimit: cardTheme.bodyLimit
                        )
                    } else {
                        cardTheme
                    }
                    let document = transcriptCardDocument(item, theme: theme)
                    let height = min(target.bottom - y, max(1, document.lines.size))
                    DocumentView(document).render(
                        Rect(target.x, y, target.width, height),
                        buffer
                    )
                    y += height
                    if (y < target.bottom) { y++ }
                case None => ()
            }
            index++
        }
    }

    private func ensureTranscriptVisible(viewportHeight: Int64): Unit {
        if (selected < offset) {
            offset = selected
        } else if (selected >= offset + viewportHeight) {
            offset = selected - viewportHeight + 1
        }
    }
}

public class ComposerSubmit {
    public let text: String
    public init(text: String) {
        this.text = text
    }
}

class ComposerRetainedPaste {
    let marker: String
    let payload: String

    init(marker: String, payload: String) {
        this.marker = marker
        this.payload = payload
    }
}

class ComposerHistoryEntry {
    let text: String
    let pastes: Array<ComposerRetainedPaste>

    init(text: String, pastes: Array<ComposerRetainedPaste>) {
        this.text = text
        this.pastes = pastes
    }
}

public class Composer <: Widget {
    public let area: TextArea
    public var lastError: ?String = None
    private let history = ArrayList<ComposerHistoryEntry>()
    private let retainedPastes = ArrayList<ComposerRetainedPaste>()
    private let slashHints: Array<String>
    private var historyIndex: Int64 = -1
    private var historyDraft = ComposerHistoryEntry("", [])
    private var nextPasteId: Int64 = 1
    private var trackedValue: String
    private var visualScroll: Int64 = 0
    private let block: ?Block
    private var cachedWrapRevision: Int64 = -1
    private var cachedWrapWidth: Int64 = -1
    private var cachedWrapLines: Array<String> = []
    private var cachedCursorRevision: Int64 = -1
    private var cachedCursorWidth: Int64 = -1
    private var cachedCursorOffset: Int64 = -1
    private var cachedCursorRow: Int64 = 0
    private var cachedCursorColumn: Int64 = 0

    public init(value!: String = "", slashHints!: Array<String> = [], block!: ?Block = None) {
        this.area = TextArea(value: value, block: block, placeholder: "message")
        this.slashHints = slashHints
        this.block = block
        this.trackedValue = value
    }

    public func handle(key: KeyEvent): ?ComposerSubmit {
        synchronizeAreaValue()
        match (key.code) {
            case KeyCode.Enter =>
                if (key.modifiers.shift || key.modifiers.alt) {
                    handleAreaKey(key)
                    None
                } else {
                    submit()
                }
            case KeyCode.Up =>
                if (history.size > 0 &&
                    (historyIndex >= 0 || area.value.isEmpty())) {
                    if (historyIndex < 0) {
                        historyDraft = currentHistoryEntry(area.value)
                        historyIndex = history.size - 1
                    } else {
                        historyIndex = max(0, historyIndex - 1)
                    }
                    restoreHistoryEntry(history[historyIndex])
                    None
                } else {
                    handleAreaKey(key)
                    None
                }
            case KeyCode.Down =>
                if (historyIndex >= 0 && history.size > 0) {
                    if (historyIndex < history.size - 1) {
                        historyIndex++
                        restoreHistoryEntry(history[historyIndex])
                    } else {
                        historyIndex = -1
                        restoreHistoryEntry(historyDraft)
                    }
                    None
                } else {
                    handleAreaKey(key)
                    None
                }
            case _ =>
                handleAreaKey(key)
                None
        }
    }

    public func paste(text: String, collapseThreshold!: Int64 = 2000): Bool {
        synchronizeAreaValue()
        let before = area.value
        if (text.size > collapseThreshold) {
            let marker = "[pasted ${text.size} bytes #${nextPasteId}]"
            nextPasteId++
            retainedPastes.add(ComposerRetainedPaste(marker, text))
            area.paste(marker)
        } else {
            area.paste(text)
        }
        recordAreaChange(before)
        true
    }

    public func draftText(): ?String {
        synchronizeAreaValue()
        expandedSubmissionText(area.value)
    }

    public func restoreDraft(text: String): Unit {
        clearRetainedPastes()
        lastError = None
        _ = area.cancelCompletion()
        historyIndex = -1
        historyDraft = ComposerHistoryEntry("", [])
        area.setValue("")
        trackedValue = ""
        _ = paste(text)
    }

    public func currentSlashHints(): Array<String> {
        if (!area.value.startsWith("/")) { return [] }
        let out = ArrayList<String>()
        for (hint in slashHints) {
            if (hint.startsWith(area.value)) { out.add(hint) }
        }
        out.toArray()
    }

    public func completionVisible(): Bool {
        area.completionVisible()
    }

    public func cancelCompletion(): Bool {
        area.cancelCompletion()
    }

    public func visualHeight(width: Int64, maximum: Int64): Int64 {
        if (width <= 0 || maximum <= 0) { return 1 }
        let textRows = max(1, layoutLines(width).size)
        min(maximum, textRows + area.completionRows(
            maximum: max(0, maximum - textRows)
        ))
    }

    public func cursorPosition(areaRect: Rect): Position {
        var target = areaRect
        match (block) {
            case Some(value) => target = value.inner(areaRect)
            case None => ()
        }
        if (target.width <= 0 || target.height <= 0) {
            return Position(target.x, target.y)
        }
        let (row, column) = cursorLayout(target.width)
        visualScroll = max(0, row - target.height + 1)
        Position(
            target.x + min(column, target.width),
            target.y + clamp(
                row - visualScroll,
                0,
                max(0, target.height - 1)
            )
        )
    }

    public func render(areaRect: Rect, buffer: Buffer): Unit {
        synchronizeAreaValue()
        var target = areaRect
        match (block) {
            case Some(value) =>
                value.render(areaRect, buffer)
                target = value.inner(areaRect)
            case None => ()
        }
        if (target.width <= 0 || target.height <= 0) { return }
        if (area.value.isEmpty()) {
            buffer.setString(
                target.x,
                target.y,
                truncate("message", target.width),
                style: Style(fg: Color.Indexed(8))
            )
        } else {
            let lines = layoutLines(target.width)
            _ = cursorPosition(areaRect)
            for (row in 0..target.height) {
                let index = row + visualScroll
                if (index >= lines.size) { break }
                buffer.setString(
                    target.x,
                    target.y + row,
                    truncate(lines[index], target.width)
                )
            }
        }
        match (lastError) {
            case Some(message) =>
                if (areaRect.height > 1) {
                    buffer.setString(
                        areaRect.x + 1,
                        areaRect.bottom - 1,
                        truncate(message, max(0, areaRect.width - 2)),
                        style: Style(fg: Color.Red)
                    )
                }
            case None =>
                let hints = currentSlashHints()
                if (hints.size > 0 && areaRect.height > 1) {
                    buffer.setString(areaRect.x + 1, areaRect.bottom - 1, truncate(join(hints, "  "), max(0, areaRect.width - 2)), style: Style(fg: Color.Indexed(8)))
                }
        }
        area.renderCompletionOverlay(target, buffer)
    }

    private func layoutLines(width: Int64): Array<String> {
        if (width <= 0) { return [] }
        let revision = area.editRevision()
        if (cachedWrapRevision != revision || cachedWrapWidth != width) {
            cachedWrapRevision = revision
            cachedWrapWidth = width
            cachedWrapLines = wrapText(area.value, width, WrapMode.Character)
        }
        cachedWrapLines
    }

    private func cursorLayout(width: Int64): (Int64, Int64) {
        let revision = area.editRevision()
        if (cachedCursorRevision == revision && cachedCursorWidth == width && cachedCursorOffset == area.cursor) {
            return (cachedCursorRow, cachedCursorColumn)
        }
        let lines = if (area.cursor == area.value.size) {
            layoutLines(width)
        } else {
            wrapText(area.value[..area.cursor], width, WrapMode.Character)
        }
        cachedCursorRevision = revision
        cachedCursorWidth = width
        cachedCursorOffset = area.cursor
        cachedCursorRow = max(0, lines.size - 1)
        cachedCursorColumn = if (lines.isEmpty()) { 0 } else { displayWidth(lines[lines.size - 1]) }
        (cachedCursorRow, cachedCursorColumn)
    }

    private func submit(): ?ComposerSubmit {
        synchronizeAreaValue()
        let displayText = trimAsciiSpacesLocal(area.value)
        if (displayText.isEmpty()) { return None }
        let text = match (expandedSubmissionText(displayText)) {
            case Some(value) => value
            case None => return None
        }
        history.add(currentHistoryEntry(displayText))
        historyIndex = -1
        historyDraft = ComposerHistoryEntry("", [])
        clearRetainedPastes()
        lastError = None
        area.setValue("")
        trackedValue = ""
        Some(ComposerSubmit(text))
    }

    private func handleAreaKey(key: KeyEvent): Unit {
        let before = area.value
        _ = area.handle(key)
        recordAreaChange(before)
    }

    private func synchronizeAreaValue(): Unit {
        if (trackedValue != area.value) {
            reconcileRetainedPastes(trackedValue, area.value)
            trackedValue = area.value
        }
        refreshPasteError()
    }

    private func recordAreaChange(before: String): Unit {
        reconcileRetainedPastes(before, area.value)
        trackedValue = area.value
        refreshPasteError()
    }

    private func reconcileRetainedPastes(before: String, after: String): Unit {
        if (before == after || retainedPastes.size == 0) { return }
        let (removedStart, removedEnd) = composerChangedRange(before, after)
        var index: Int64 = 0
        while (index < retainedPastes.size) {
            let item = retainedPastes[index]
            let beforeStart = stringIndexOf(before, item.marker, 0)
            let beforeCount = composerMarkerCount(before, item.marker)
            let afterCount = composerMarkerCount(after, item.marker)
            if (afterCount == 0 && beforeCount == 1 &&
                removedStart <= beforeStart &&
                removedEnd >= beforeStart + item.marker.size) {
                retainedPastes.remove(at: index)
            } else {
                index++
            }
        }
    }

    private func refreshPasteError(): Unit {
        lastError = retainedPasteError(area.value)
    }

    private func retainedPasteError(text: String): ?String {
        for (item in retainedPastes) {
            if (composerMarkerCount(text, item.marker) != 1) {
                return Some("paste marker damaged; restore or delete the entire marker")
            }
        }
        None
    }

    private func expandedSubmissionText(displayText: String): ?String {
        match (retainedPasteError(displayText)) {
            case Some(message) =>
                lastError = Some(message)
                return None
            case None => ()
        }
        var offset: Int64 = 0
        var result = ""
        while (true) {
            var nextOffset: Int64 = -1
            var nextPaste: Int64 = -1
            for (index in 0..retainedPastes.size) {
                let candidate = stringIndexOf(displayText, retainedPastes[index].marker, offset)
                if (candidate >= 0 && (nextOffset < 0 || candidate < nextOffset)) {
                    nextOffset = candidate
                    nextPaste = index
                }
            }
            if (nextPaste < 0) { break }
            let item = retainedPastes[nextPaste]
            result += displayText[offset..nextOffset]
            result += item.payload
            offset = nextOffset + item.marker.size
        }
        result += displayText[offset..]
        Some(result)
    }

    private func currentHistoryEntry(text: String): ComposerHistoryEntry {
        let pastes = ArrayList<ComposerRetainedPaste>()
        for (item in retainedPastes) { pastes.add(item) }
        ComposerHistoryEntry(text, pastes.toArray())
    }

    private func restoreHistoryEntry(entry: ComposerHistoryEntry): Unit {
        clearRetainedPastes()
        for (item in entry.pastes) { retainedPastes.add(item) }
        area.setValue(entry.text)
        trackedValue = entry.text
        refreshPasteError()
    }

    private func clearRetainedPastes(): Unit {
        while (retainedPastes.size > 0) {
            retainedPastes.remove(at: retainedPastes.size - 1)
        }
    }
}

func composerMarkerCount(text: String, marker: String): Int64 {
    var count: Int64 = 0
    var offset: Int64 = 0
    while (true) {
        let index = stringIndexOf(text, marker, offset)
        if (index < 0) { break }
        count++
        offset = index + marker.size
    }
    count
}

func composerChangedRange(before: String, after: String): (Int64, Int64) {
    var prefix: Int64 = 0
    let prefixLimit = min(before.size, after.size)
    while (prefix < prefixLimit && before[prefix] == after[prefix]) { prefix++ }
    var suffix: Int64 = 0
    while (suffix < before.size - prefix && suffix < after.size - prefix &&
        before[before.size - suffix - 1] == after[after.size - suffix - 1]) {
        suffix++
    }
    (prefix, before.size - suffix)
}

public class ActivityStep {
    public let title: String
    public let status: TranscriptItemStatus
    public let detail: String
    public let duration: String

    public init(title: String, status!: TranscriptItemStatus = TranscriptItemStatus.Pending, detail!: String = "", duration!: String = "") {
        this.title = title
        this.status = status
        this.detail = detail
        this.duration = duration
    }
}

public class ActivityTimeline <: Widget {
    private let steps: Array<ActivityStep>
    private let block: ?Block

    public init(steps: Array<ActivityStep>, block!: ?Block = None) {
        this.steps = steps
        this.block = block
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        var target = area
        if (let Some(b) <- block) {
            b.render(area, buffer)
            target = b.inner(area)
        }
        let rows = min(target.height, steps.size)
        for (i in 0..rows) {
            let step = steps[i]
            let suffix = if (step.duration.isEmpty()) { "" } else { " " + step.duration }
            let detail = if (step.detail.isEmpty()) { "" } else { " - " + step.detail }
            buffer.setString(target.x, target.y + i, truncate(statusMark(step.status) + " " + step.title + detail + suffix, target.width), style: transcriptStatusStyle(step.status, Style.default()))
        }
    }
}

public class RequestDialog <: Widget {
    private let title: String
    private let body: String
    private let detail: Document
    private let risk: String
    private let buttons: Array<String>
    public var selected: Int64

    public init(title!: String = "Request", body!: String = "", detail!: Document = Document([]), risk!: String = "", buttons!: Array<String> = ["Cancel", "Confirm"], selected!: Int64 = 0) {
        this.title = title
        this.body = body
        this.detail = detail
        this.risk = risk
        this.buttons = buttons
        this.selected = clamp(selected, 0, max(0, buttons.size - 1))
    }

    public func handle(key: KeyEvent): ?String {
        let dialog = Dialog(title: title, body: body, buttons: buttons, selected: selected)
        match (dialog.handle(key)) {
            case Some(action) =>
                selected = dialog.selected
                Some(action)
            case None =>
                selected = dialog.selected
                None
        }
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        Dialog(title: title, body: if (risk.isEmpty()) { body } else { risk + "\n" + body }, buttons: buttons, selected: selected).render(area, buffer)
        if (detail.lines.size > 0 && area.width > 10 && area.height > 10) {
            let detailArea = Rect(area.x + area.width / 4, area.y + area.height / 2, area.width / 2, max(1, area.height / 3))
            DocumentView(detail).render(detailArea, buffer)
        }
    }
}

public type DecisionDialog = RequestDialog

public func statusMark(
    status: TranscriptItemStatus,
    activityFrame!: Int64 = 0
): String {
    match (status) {
        case TranscriptItemStatus.Pending => "○"
        case TranscriptItemStatus.Queued => "✓"
        case TranscriptItemStatus.Running => runningStatusMark(activityFrame)
        case TranscriptItemStatus.Streaming => streamingStatusMark(activityFrame)
        case TranscriptItemStatus.Done => "✓"
        case TranscriptItemStatus.Awaiting => "?"
        case TranscriptItemStatus.Approved => "✓"
        case TranscriptItemStatus.Failed => "✗"
        case TranscriptItemStatus.Cancelled => "–"
        case TranscriptItemStatus.Rejected => "⊘"
        case TranscriptItemStatus.TimedOut => "⌛"
        case TranscriptItemStatus.Expired => "⌛"
        case TranscriptItemStatus.Conflict => "!"
    }
}

func runningStatusMark(frame: Int64): String {
    match (frame % 4) {
        case 0 => "◐"
        case 1 => "◓"
        case 2 => "◑"
        case _ => "◒"
    }
}

func streamingStatusMark(frame: Int64): String {
    match (frame % 4) {
        case 0 => "⋮"
        case 1 => "⋰"
        case 2 => "⋯"
        case _ => "⋱"
    }
}

public func transcriptStatusStyle(status: TranscriptItemStatus, base: Style): Style {
    match (getVariable("NO_COLOR")) {
        case Some(_) => return base
        case None => ()
    }
    match (status) {
        case TranscriptItemStatus.Pending => base.patch(Style(fg: Color.Indexed(8)))
        case TranscriptItemStatus.Queued => base.patch(Style(fg: Color.Green))
        case TranscriptItemStatus.Running => base.patch(Style(fg: Color.Cyan))
        case TranscriptItemStatus.Streaming => base.patch(Style(fg: Color.Cyan))
        case TranscriptItemStatus.Done => base.patch(Style(fg: Color.Green))
        case TranscriptItemStatus.Awaiting => base.patch(Style(fg: Color.Yellow))
        case TranscriptItemStatus.Approved => base.patch(Style(fg: Color.Green))
        case TranscriptItemStatus.Failed => base.patch(Style(fg: Color.Red))
        case TranscriptItemStatus.Cancelled => base.patch(Style(fg: Color.Yellow))
        case TranscriptItemStatus.Rejected => base.patch(Style(fg: Color.Red))
        case TranscriptItemStatus.TimedOut => base.patch(Style(fg: Color.Red))
        case TranscriptItemStatus.Expired => base.patch(Style(fg: Color.Yellow))
        case TranscriptItemStatus.Conflict => base.patch(Style(fg: Color.Yellow))
    }
}

public func transcriptStatusLabel(status: TranscriptItemStatus): String {
    match (status) {
        case TranscriptItemStatus.Pending => "pending"
        case TranscriptItemStatus.Queued => "queued"
        case TranscriptItemStatus.Running => "running"
        case TranscriptItemStatus.Streaming => "streaming"
        case TranscriptItemStatus.Done => "completed"
        case TranscriptItemStatus.Awaiting => "awaiting approval"
        case TranscriptItemStatus.Approved => "approved"
        case TranscriptItemStatus.Failed => "failed"
        case TranscriptItemStatus.Cancelled => "cancelled"
        case TranscriptItemStatus.Rejected => "rejected"
        case TranscriptItemStatus.TimedOut => "timed out"
        case TranscriptItemStatus.Expired => "expired"
        case TranscriptItemStatus.Conflict => "conflict"
    }
}

public func transcriptCardDocument(
    item: TranscriptItem,
    theme!: TranscriptCardTheme = TranscriptCardTheme()
): Document {
    let lines = ArrayList<DocumentLine>()
    let title = if (item.title.isEmpty()) { item.id } else { item.title }
    let state = if (item.stateLabel.isEmpty()) {
        transcriptStatusLabel(item.status)
    } else {
        item.stateLabel
    }
    let header = ArrayList<RichSpan>()
    header.add(RichSpan(
        statusMark(item.status, activityFrame: item.activityFrame) + " ",
        style: transcriptStatusStyle(item.status, theme.style)
    ))
    header.add(RichSpan(title, style: theme.titleStyle))
    if (!state.isEmpty()) {
        header.add(RichSpan(" · " + state, style: theme.mutedStyle))
    }
    if (!item.duration.isEmpty()) {
        header.add(RichSpan(" · " + item.duration, style: theme.mutedStyle))
    }
    if (item.collapsed) {
        header.add(RichSpan("  ▸", style: theme.mutedStyle))
    }
    lines.add(DocumentLine(DocumentLineKind.Paragraph, header.toArray()))
    if (!item.collapsed) {
        let limit = if (theme.bodyLimit == 0) {
            item.body.lines.size
        } else {
            min(theme.bodyLimit, item.body.lines.size)
        }
        for (index in 0..limit) {
            lines.add(indentTranscriptLine(
                item.body.lines[index],
                theme.bodyIndent,
                theme.style
            ))
        }
        if (limit < item.body.lines.size) {
            lines.add(DocumentLine(
                DocumentLineKind.Paragraph,
                transcriptIndent(theme.bodyIndent) + "…",
                style: theme.mutedStyle
            ))
        }
        for (option in item.options) {
            lines.add(DocumentLine(
                DocumentLineKind.Paragraph,
                transcriptIndent(theme.bodyIndent) +
                    if (option.selected) { "› " } else { "  " } +
                    option.label,
                style: if (option.selected) {
                    theme.selectedStyle
                } else {
                    theme.style
                }
            ))
        }
        if (!item.footer.isEmpty()) {
            lines.add(DocumentLine(
                DocumentLineKind.Paragraph,
                transcriptIndent(theme.bodyIndent) + item.footer,
                style: theme.mutedStyle
            ))
        }
    }
    Document(lines.toArray())
}

func indentTranscriptLine(
    line: DocumentLine,
    width: Int64,
    style: Style
): DocumentLine {
    let spans = ArrayList<RichSpan>()
    spans.add(RichSpan(transcriptIndent(width), style: style))
    spans.add(all: line.spans)
    DocumentLine(
        line.kind,
        spans.toArray(),
        quoteDepth: line.quoteDepth,
        media: line.media,
        mediaFit: line.mediaFit,
        mediaHeight: line.mediaHeight
    )
}

func transcriptIndent(width: Int64): String {
    var result = ""
    for (_ in 0..max(0, width)) { result += " " }
    result
}

func insertPair(area: TextArea, left: String, right: String): Bool {
    let pos = area.cursor
    area.paste(left + right)
    area.cursor = pos + left.size
    true
}

func handleMarkdownEnter(area: TextArea): Bool {
    area.handle(KeyEvent(KeyCode.Enter))
}

func previousByteIs(area: TextArea, byte: UInt8): Bool {
    area.cursor > 0 && area.cursor <= area.value.size && area.value[area.cursor - 1] == byte
}

func closeRepeatedMarker(area: TextArea, marker: String): Bool {
    let start = area.cursor - 1
    area.select(start, area.cursor)
    area.paste(marker + marker)
    area.cursor = start + marker.size
    true
}

func wrapSelection(area: TextArea, left: String, right: String): Bool {
    match (area.selectedRange()) {
        case Some((start, end)) =>
            let text = area.value[start..end]
            area.paste(left + text + right)
            area.cursor = start + left.size + text.size
            area.clearSelection()
            true
        case None => false
    }
}

func wrapSelectionAsLink(area: TextArea): Bool {
    match (area.selectedRange()) {
        case Some((start, end)) =>
            let text = area.value[start..end]
            area.paste("[" + text + "]()")
            area.cursor = start + text.size + 3
            area.clearSelection()
            true
        case None => false
    }
}

func skipClosingDelimiter(area: TextArea, delimiter: String): Bool {
    if (area.cursor + delimiter.size <= area.value.size && area.value[area.cursor..area.cursor + delimiter.size] == delimiter) {
        area.cursor += delimiter.size
        area.clearSelection()
        return true
    }
    area.paste(delimiter)
    true
}

func wrapSelectionOrWord(area: TextArea, left: String, right: String): Bool {
    if (area.hasSelection()) { return wrapSelection(area, left, right) }
    let start = previousWordOffset(area.value, area.cursor)
    let end = nextWordOffset(area.value, area.cursor)
    area.select(start, end)
    wrapSelection(area, left, right)
}
