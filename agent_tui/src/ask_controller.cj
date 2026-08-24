package agent_tui

import core.*
import std.collection.*

enum AskEffect {
    Submit(TuiAskRequest, TuiAskResolution)
}

class AskTransition {
    let changed: Bool
    let cardChanged: Bool
    let effect: ?AskEffect

    init(changed!: Bool = false, cardChanged!: Bool = false, effect!: ?AskEffect = None) {
        this.changed = changed
        this.cardChanged = cardChanged
        this.effect = effect
    }
}

class AskCompletion {
    let request: TuiAskRequest
    let title: String
    let body: String
    let state: String
    let collapsed: Bool
    let footer: String

    init(
        request: TuiAskRequest,
        title: String,
        body: String,
        state: String,
        collapsed: Bool,
        footer: String
    ) {
        this.request = request
        this.title = title
        this.body = body
        this.state = state
        this.collapsed = collapsed
        this.footer = footer
    }
}

class AskCardPresentation {
    let request: TuiAskRequest
    let title: String
    let body: String
    let footer: String

    init(request: TuiAskRequest, title: String, body: String, footer: String) {
        this.request = request
        this.title = title
        this.body = body
        this.footer = footer
    }
}

class AskProbeSnapshot {
    let submissionAttempted: Bool
    let submissionAccepted: Bool
    let submissionNote: String
    let editorMode: String
    let active: Bool
    let cursor: Int64
    let status: String

    init(
        submissionAttempted: Bool,
        submissionAccepted: Bool,
        submissionNote: String,
        editorMode: String,
        active: Bool,
        cursor: Int64,
        status: String
    ) {
        this.submissionAttempted = submissionAttempted
        this.submissionAccepted = submissionAccepted
        this.submissionNote = submissionNote
        this.editorMode = editorMode
        this.active = active
        this.cursor = cursor
        this.status = status
    }
}

class AskProbeState {
    private let applyState: (AskController) -> Unit

    init(applyState: (AskController) -> Unit) {
        this.applyState = applyState
    }

    func restoreInto(controller: AskController): Unit {
        applyState(controller)
    }
}

class AskController {
    private var request: ?TuiAskRequest = None
    private var questionIndex: Int64 = 0
    private var cursor: Int64 = 0
    private let selected = ArrayList<String>()
    private let answers = ArrayList<TuiAskAnswer>()
    private var submissionAttempted = false
    private var submissionAccepted = false
    private var submissionNote = ""
    private var customInput: ?String = None
    private var note: ?String = None
    private var editorMode = ""
    private let editor = TextArea(
        block: Some(Block(title: "Ask response")),
        lineNumbers: false
    )
    private let customEditor = TextArea(lineNumbers: false)
    private var editorArea = Rect(0, 0, 0, 0)
    private var status = "ready"

    func isActive(): Bool {
        request.isSome()
    }

    func editorActive(): Bool {
        editorMode != ""
    }

    func inlineEditorActive(): Bool {
        editorMode == "custom"
    }

    func currentPresentation(): ?AskCardPresentation {
        match (request) {
            case Some(value) => Some(
                AskCardPresentation(
                    value,
                    askTitle(value, questionIndex),
                    askBody(
                        value,
                        questionIndex,
                        cursor,
                        selected.toArray(),
                        customInput,
                        note,
                        editingCustom: editorMode == "custom"
                    ),
                    if (editorMode == "custom") {
                        "type custom answer · Enter save · Esc cancel"
                    } else {
                        askProgress(value, questionIndex)
                    }
                )
            )
            case None => None
        }
    }

    func probeSnapshot(): AskProbeSnapshot {
        AskProbeSnapshot(
            submissionAttempted,
            submissionAccepted,
            submissionNote,
            editorMode,
            isActive(),
            cursor,
            status
        )
    }

    func captureProbeState(): AskProbeState {
        let savedRequest = request
        let savedQuestionIndex = questionIndex
        let savedCursor = cursor
        let savedSelected = selected.toArray()
        let savedAnswers = answers.toArray()
        let savedSubmissionAttempted = submissionAttempted
        let savedSubmissionAccepted = submissionAccepted
        let savedSubmissionNote = submissionNote
        let savedCustomInput = customInput
        let savedNote = note
        let savedEditorMode = editorMode
        let savedEditorValue = editor.value
        let savedEditorCursor = editor.cursor
        let savedCustomEditorValue = customEditor.value
        let savedCustomEditorCursor = customEditor.cursor
        let savedEditorArea = editorArea
        let savedStatus = status
        AskProbeState({controller =>
            controller.request = savedRequest
            controller.questionIndex = savedQuestionIndex
            controller.cursor = savedCursor
            controller.selected.clear()
            for (value in savedSelected) {
                controller.selected.add(value)
            }
            controller.answers.clear()
            for (value in savedAnswers) {
                controller.answers.add(value)
            }
            controller.submissionAttempted = savedSubmissionAttempted
            controller.submissionAccepted = savedSubmissionAccepted
            controller.submissionNote = savedSubmissionNote
            controller.customInput = savedCustomInput
            controller.note = savedNote
            controller.editorMode = savedEditorMode
            controller.editor.setValue(savedEditorValue, cursor: savedEditorCursor)
            controller.customEditor.setValue(savedCustomEditorValue, cursor: savedCustomEditorCursor)
            controller.editorArea = savedEditorArea
            controller.status = savedStatus
        })
    }

    func restoreProbeState(state: AskProbeState): Unit {
        state.restoreInto(this)
    }

    func statusText(): String {
        status
    }

    func begin(value: TuiAskRequest): Bool {
        if (value.questions.isEmpty()) {
            status = "ask rejected: no questions"
            return false
        }
        request = Some(value)
        questionIndex = 0
        answers.clear()
        submissionAttempted = false
        submissionAccepted = false
        submissionNote = ""
        closeEditor()
        resetQuestion(value.questions[0])
        status = askProgress(value, questionIndex)
        true
    }

    func paste(text: String): UpdateResult {
        if (!editorActive()) {
            return UpdateResult.unchanged()
        }
        if (editorMode == "custom") {
            _ = customEditor.paste(
                text.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
            )
        } else {
            _ = editor.paste(text)
        }
        UpdateResult.next()
    }

    func updateKey(key: KeyEvent): AskTransition {
        let value = match (request) {
            case Some(current) => current
            case None => return AskTransition()
        }
        let question = value.questions[questionIndex]
        let optionCount = question.options.size
        let maxCursor = askChoiceCount(value, questionIndex) - 1
        match (key.code) {
            case KeyCode.Esc | KeyCode.CtrlC => return finish(TuiAskResolution.Cancelled)
            case KeyCode.Up | KeyCode.Char(r'k') | KeyCode.Char(r'K') =>
                let previous = cursor
                cursor = max(0, cursor - 1)
                let changed = cursor != previous
                return AskTransition(changed: changed, cardChanged: changed)
            case KeyCode.Down | KeyCode.Char(r'j') | KeyCode.Char(r'J') =>
                let previous = cursor
                cursor = min(maxCursor, cursor + 1)
                let changed = cursor != previous
                return AskTransition(changed: changed, cardChanged: changed)
            case KeyCode.Left =>
                if (questionIndex > 0 && !answers.isEmpty()) {
                    questionIndex -= 1
                    let previous = answers[answers.size - 1]
                    answers.remove(at: answers.size - 1)
                    loadAnswer(value.questions[questionIndex], previous)
                    status = askProgress(value, questionIndex)
                    return AskTransition(changed: true, cardChanged: true)
                }
                return AskTransition()
            case KeyCode.Char(r' ') =>
                if (question.multi && cursor < optionCount) {
                    toggleOption(question.options[cursor].label)
                    return AskTransition(changed: true, cardChanged: true)
                }
                return AskTransition()
            case KeyCode.Tab =>
                cursor = optionCount
                return openCustomEditor()
            case KeyCode.Char(r'n') | KeyCode.Char(r'N') =>
                openEditor("note")
                editor.setValue(match (note) {
                    case Some(current) => current
                    case None => ""
                })
                status = "ask note · Ctrl+S save · Esc return"
                return AskTransition(changed: true)
            case KeyCode.Char(r'c') | KeyCode.Char(r'C') => return finish(TuiAskResolution.Chat)
            case KeyCode.Enter =>
                if (cursor < optionCount) {
                    let label = question.options[cursor].label
                    if (question.multi) {
                        toggleOption(label)
                        return AskTransition(changed: true, cardChanged: true)
                    }
                    selected.clear()
                    customInput = None
                    selected.add(label)
                    return advance(value)
                }
                if (cursor == optionCount) {
                    return openCustomEditor()
                }
                if (question.multi && cursor == optionCount + 1) {
                    if (!selected.isEmpty() || customInput.isSome()) {
                        return advance(value)
                    }
                    status = "select at least one option or choose Other"
                    return AskTransition(changed: true)
                }
                return finish(TuiAskResolution.Chat)
            case _ => return AskTransition()
        }
        AskTransition()
    }

    func updateEditor(key: KeyEvent): AskTransition {
        match (key.code) {
            case KeyCode.Esc =>
                let custom = editorMode == "custom"
                closeEditor()
                status = currentProgress()
                AskTransition(changed: true, cardChanged: custom)
            case KeyCode.Enter =>
                if (editorMode == "custom") {
                    saveCustomEditor()
                } else {
                    _ = editor.handle(key)
                    AskTransition(changed: true)
                }
            case KeyCode.Tab =>
                if (editorMode == "custom") {
                    AskTransition()
                } else {
                    _ = editor.handle(key)
                    AskTransition(changed: true)
                }
            case KeyCode.Char(r's') =>
                if (!key.modifiers.ctrl) {
                    _ = activeEditor().handle(key)
                    return AskTransition(changed: true)
                }
                if (editorMode == "note") {
                    let value = editor.value
                    note = if (value.trimAscii() == "") { None } else { Some(value) }
                    closeEditor()
                    status = currentProgress()
                    return AskTransition(changed: true, cardChanged: true)
                }
                saveCustomEditor()
            case _ =>
                _ = activeEditor().handle(key)
                AskTransition(changed: true)
        }
    }

    func updateMouse(mouse: MouseEvent): UpdateResult {
        if (!editorActive()) {
            return UpdateResult.unchanged()
        }
        match (mouse.kind) {
            case MouseKind.Scroll => return UpdateResult.unchanged()
            case _ => ()
        }
        if (!askPointInRect(mouse.x, mouse.y, editorArea)) {
            return UpdateResult.unchanged()
        }
        if (activeEditor().handleMouse(mouse, editorArea)) {
            UpdateResult.next()
        } else {
            UpdateResult.unchanged()
        }
    }

    func completeSubmission(accepted: Bool, resolution: TuiAskResolution): ?AskCompletion {
        let value = match (request) {
            case Some(current) => current
            case None => return None
        }
        submissionAccepted = accepted
        let completionTitle = askTitle(value, questionIndex)
        let completionBody = askBody(
            value,
            questionIndex,
            cursor,
            selected.toArray(),
            customInput,
            note
        )
        if (accepted) {
            let resolutionText = match (resolution) {
                case TuiAskResolution.Cancelled => "cancelled"
                case TuiAskResolution.Chat => "continuing in chat"
                case TuiAskResolution.Answers(_) => "answer submitted"
            }
            let resolutionState = match (resolution) {
                case TuiAskResolution.Cancelled => "cancelled"
                case _ => "completed"
            }
            let completion = AskCompletion(
                value,
                completionTitle,
                completionBody,
                resolutionState,
                true,
                resolutionText
            )
            request = None
            answers.clear()
            selected.clear()
            customInput = None
            note = None
            closeEditor()
            status = match (resolution) {
                case TuiAskResolution.Cancelled => "ask cancelled"
                case TuiAskResolution.Chat => "continuing in chat"
                case TuiAskResolution.Answers(_) => "answer submitted"
            }
            return Some(completion)
        }
        status = "ask answer was rejected"
        match (resolution) {
            case TuiAskResolution.Answers(_) =>
                while (answers.size > questionIndex) {
                    answers.remove(at: answers.size - 1)
                }
            case _ => ()
        }
        Some(
            AskCompletion(
                value,
                completionTitle,
                completionBody,
                "awaiting",
                false,
                "answer rejected · retry or edit"
            )
        )
    }

    func renderEditor(
        frame: Frame,
        theme: ProductTheme,
        cardArea!: ?Rect = None,
        fallbackArea!: ?Rect = None,
        unicode!: Bool = true
    ): Unit {
        if (!editorActive()) {
            editorArea = Rect(0, 0, 0, 0)
            return
        }
        if (editorMode == "custom") {
            var fallback = false
            editorArea = match (cardArea) {
                case Some(value) => customEditorRect(value, unicode)
                case None => Rect(0, 0, 0, 0)
            }
            if (editorArea.width <= 0 || editorArea.height <= 0) {
                fallback = true
                editorArea = match (cardArea) {
                    case Some(value) => customFallbackEditorRect(value, unicode)
                    case None => match (fallbackArea) {
                        case Some(value) => customFallbackEditorRect(value, unicode)
                        case None => Rect(0, 0, 0, 0)
                    }
                }
            }
            if (editorArea.width <= 0 || editorArea.height <= 0) {
                return
            }
            if (fallback) {
                let prefix = "› Other: "
                frame.canvas().drawText(
                    editorArea.x - displayWidth(prefix),
                    editorArea.y,
                    prefix,
                    Style(fg: theme.accent, bg: theme.background)
                )
            }
            frame.renderWidget(customEditor, editorArea)
            frame.setCursor(customEditor.cursorPosition(editorArea))
            return
        }
        let canvas = frame.canvas()
        let insetX = if (frame.area.width > 4) { 2 } else { 0 }
        let insetY = if (frame.area.height > 5) { 2 } else { 0 }
        editorArea = Rect(
            frame.area.x + insetX,
            frame.area.y + insetY,
            max(1, frame.area.width - insetX * 2),
            max(1, frame.area.height - insetY - 2)
        )
        canvas.fillRect(editorArea, Style(bg: Color.Rgb(28, 31, 39)))
        frame.renderWidget(editor, editorArea)
        canvas.drawText(
            editorArea.x,
            min(frame.area.bottom - 1, editorArea.bottom),
            cut(
                " Ctrl+S save · Esc return · optional answer note",
                editorArea.width
            ),
            Style(fg: theme.accent, bg: theme.background)
        )
        frame.setCursor(editor.cursorPosition(editorArea))
    }

    private func openEditor(mode: String): Unit {
        editorMode = mode
        editorArea = Rect(0, 0, 0, 0)
    }

    private func openCustomEditor(): AskTransition {
        openEditor("custom")
        customEditor.setValue(match (customInput) {
            case Some(current) => current
            case None => ""
        })
        status = "custom answer · Enter save · Esc cancel"
        AskTransition(changed: true, cardChanged: true)
    }

    private func closeEditor(): Unit {
        editorMode = ""
        editorArea = Rect(0, 0, 0, 0)
    }

    private func askPointInRect(x: Int64, y: Int64, area: Rect): Bool {
        area.width > 0 && area.height > 0 && x >= area.x && x < area.right && y >= area.y && y < area.bottom
    }

    private func activeEditor(): TextArea {
        if (editorMode == "custom") {
            customEditor
        } else {
            editor
        }
    }

    private func saveCustomEditor(): AskTransition {
        let value = customEditor.value
        let current = match (request) {
            case Some(active) => active
            case None => return AskTransition()
        }
        let question = current.questions[questionIndex]
        if (value.trimAscii() == "") {
            if (question.multi && !selected.isEmpty() && customInput.isSome()) {
                customInput = None
                closeEditor()
                status = currentProgress()
                return AskTransition(changed: true, cardChanged: true)
            }
            status = "custom answer must not be empty"
            return AskTransition(changed: true)
        }
        customInput = Some(value)
        closeEditor()
        if (question.multi) {
            status = currentProgress()
            return AskTransition(changed: true, cardChanged: true)
        }
        selected.clear()
        advance(current)
    }

    private func customEditorRect(cardArea: Rect, unicode: Bool): Rect {
        let current = match (request) {
            case Some(active) => active
            case None => return Rect(0, 0, 0, 0)
        }
        let visibleBody = limitToolDetail(
            askBody(
                current,
                questionIndex,
                cursor,
                selected.toArray(),
                customInput,
                note,
                editingCustom: true
            ),
            0
        )
        let lines = visibleBody.split("\n")
        var otherLine: Int64 = -1
        for (index in 0..lines.size) {
            if (lines[index].startsWith("› Other:") || lines[index].startsWith("  Other:")) {
                otherLine = index
                break
            }
        }
        if (otherLine < 0) {
            return Rect(0, 0, 0, 0)
        }
        let layoutWidth = max(1, cardArea.width - 2)
        var bodyRows: Int64 = 0
        var rowsAfter: Int64 = 0
        for (index in 0..lines.size) {
            let lineRows = max(
                1,
                DocumentView(
                    Document([
                        DocumentLine(DocumentLineKind.Paragraph, lines[index])
                    ])
                ).renderedLineCount(layoutWidth)
            )
            bodyRows += lineRows
            if (index > otherLine) {
                rowsAfter += lineRows
            }
        }
        // lastVisibleRanges reports only the visible slice. Refuse to use a
        // bottom-clipped slice as the card bottom; the screen first restores
        // follow-bottom so the compact active Ask card normally fits whole.
        if (cardArea.height != bodyRows + 2) {
            return Rect(0, 0, 0, 0)
        }
        let y = cardArea.bottom - 2 - rowsAfter
        let railWidth: Int64 = if (unicode) { 2 } else { 3 }
        let prefix = "› Other: "
        let x = cardArea.x + railWidth + displayWidth(prefix)
        let width = cardArea.right - x
        if (width <= 0 || y < cardArea.y || y >= cardArea.bottom) {
            Rect(0, 0, 0, 0)
        } else {
            Rect(x, y, width, 1)
        }
    }

    private func customFallbackEditorRect(area: Rect, unicode: Bool): Rect {
        let railWidth: Int64 = if (unicode) { 2 } else { 3 }
        let prefixWidth = displayWidth("› Other: ")
        let x = area.x + railWidth + prefixWidth
        let width = area.right - x
        if (area.height <= 0 || width <= 0) {
            Rect(0, 0, 0, 0)
        } else {
            // A long Ask card can be taller than the transcript viewport. In
            // that case its real Other row cannot be located from the clipped
            // range, so keep the edit visible on the last row of that Ask
            // slice instead of capturing input behind an invisible editor.
            Rect(x, area.bottom - 1, width, 1)
        }
    }

    private func advance(value: TuiAskRequest): AskTransition {
        let question = value.questions[questionIndex]
        answers.add(
            TuiAskAnswer(
                question.id,
                selectedOptions: selected.toArray(),
                customInput: customInput,
                note: note
            )
        )
        if (questionIndex + 1 >= value.questions.size) {
            return finish(TuiAskResolution.Answers(answers.toArray()))
        }
        questionIndex += 1
        resetQuestion(value.questions[questionIndex])
        status = askProgress(value, questionIndex)
        AskTransition(changed: true, cardChanged: true)
    }

    private func finish(resolution: TuiAskResolution): AskTransition {
        let value = match (request) {
            case Some(current) => current
            case None => return AskTransition()
        }
        submissionAttempted = true
        match (resolution) {
            case TuiAskResolution.Answers(values) =>
                if (!values.isEmpty()) {
                    submissionNote = match (values[0].note) {
                        case Some(current) => current
                        case None => ""
                    }
                }
            case _ => ()
        }
        AskTransition(changed: true, effect: Some(AskEffect.Submit(value, resolution)))
    }

    private func currentProgress(): String {
        match (request) {
            case Some(current) => askProgress(current, questionIndex)
            case None => "ready"
        }
    }

    private func resetQuestion(question: TuiAskQuestion): Unit {
        selected.clear()
        customInput = None
        note = None
        cursor = match (question.recommended) {
            case Some(value) => if (value >= 0 && value < question.options.size) { value } else { 0 }
            case None => 0
        }
    }

    private func loadAnswer(question: TuiAskQuestion, answer: TuiAskAnswer): Unit {
        selected.clear()
        for (value in answer.selectedOptions) {
            selected.add(value)
        }
        customInput = answer.customInput
        note = answer.note
        cursor = if (!answer.selectedOptions.isEmpty()) {
            askOptionIndex(question, answer.selectedOptions[0])
        } else if (answer.customInput.isSome()) {
            question.options.size
        } else {
            0
        }
    }

    private func toggleOption(label: String): Unit {
        for (index in 0..selected.size) {
            if (selected[index] == label) {
                selected.remove(at: index)
                return
            }
        }
        selected.add(label)
    }
}
